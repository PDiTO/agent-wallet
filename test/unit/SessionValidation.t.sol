// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AgentWallet} from "../../src/AgentWallet.sol";
import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";

/// @notice Validation phase in isolation: `validateUserOp` called directly as the EntryPoint.
contract SessionValidationTest is AgentWalletTestBase {
    uint256 internal constant SIG_FAILED = 1;

    function setUp() public override {
        super.setUp();
        addDefaultSession();
    }

    function validate(PackedUserOperation memory op) internal returns (uint256) {
        bytes32 hash = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        return account.validateUserOp(op, hash, 0);
    }

    function expectValidateRevert(PackedUserOperation memory op, bytes memory err) internal {
        bytes32 hash = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        vm.expectRevert(err);
        account.validateUserOp(op, hash, 0);
    }

    function expectedSessionData(address key) internal view returns (uint256) {
        IAgentWallet.Session memory s = account.getSession(key);
        return (uint256(s.validUntil) << 160) | (uint256(s.validAfter) << 208);
    }

    /*//////////////////////////////////////////////////////////////
                               SIGNATURES
    //////////////////////////////////////////////////////////////*/

    function test_ownerSignatureReturnsZero() public {
        assertEq(validate(ownerOp("")), 0);
    }

    function test_sessionSignatureReturnsValidityWindow() public {
        uint256 data = validate(agentOp(tokenTransfer(recipient, 1e18)));
        assertEq(data, expectedSessionData(agent));
        assertEq(uint160(data), 0, "authorizer must be 0 (valid signature)");
    }

    /// @dev Wrong signer must return SIG_VALIDATION_FAILED, not revert, so bundlers can simulate.
    function test_randomKeyAsOwnerReturnsSigFailed() public {
        (, uint256 randomKey) = makeAddrAndKey("random");
        PackedUserOperation memory op = baseOp(address(account), 0, "");
        op.signature = abi.encodePacked(uint8(0x00), sign(randomKey, op));
        assertEq(validate(op), SIG_FAILED);
    }

    function test_wrongSignerForSessionReturnsSigFailedWithWindow() public {
        (, uint256 randomKey) = makeAddrAndKey("random");
        PackedUserOperation memory op =
            baseOp(address(account), sessionNonce(agent), sessionCallData(tokenTransfer(recipient, 1)));
        signSession(op, agent, randomKey);
        assertEq(validate(op), expectedSessionData(agent) | SIG_FAILED);
    }

    function test_unknownSessionKeyReturnsSigFailed() public {
        (address stranger, uint256 strangerKey) = makeAddrAndKey("stranger");
        assertEq(validate(sessionOp(stranger, strangerKey, tokenTransfer(recipient, 1))), SIG_FAILED);
    }

    function test_revokedSessionKeyReturnsSigFailed() public {
        vm.prank(owner);
        account.revokeSession(agent);
        assertEq(validate(agentOp(tokenTransfer(recipient, 1))), SIG_FAILED);
    }

    function test_malformedSignaturesReturnSigFailed() public {
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        bytes memory good = op.signature;

        op.signature = "";
        assertEq(validate(op), SIG_FAILED, "empty");

        op.signature = abi.encodePacked(good, uint8(0));
        assertEq(validate(op), SIG_FAILED, "too long");

        op.signature = abi.encodePacked(uint8(0x02), agent, sign(agentKey, op));
        assertEq(validate(op), SIG_FAILED, "unknown mode");

        op.signature = abi.encodePacked(uint8(0x00), sign(ownerKey, op), uint8(0));
        assertEq(validate(op), SIG_FAILED, "owner wrong length");

        // High-s / junk (r, s, v) must not make ECDSA revert.
        op.signature = abi.encodePacked(uint8(0x00), bytes32(uint256(1)), bytes32(type(uint256).max), uint8(27));
        assertEq(validate(op), SIG_FAILED, "junk owner sig");
    }

    function test_paysMissingFunds() public {
        PackedUserOperation memory op = ownerOp("");
        bytes32 hash = entryPoint.getUserOpHash(op);
        uint256 before = address(entryPoint).balance;
        vm.prank(address(entryPoint));
        account.validateUserOp(op, hash, 0.01 ether);
        assertEq(address(entryPoint).balance, before + 0.01 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           SESSION POLICY RULES
    //////////////////////////////////////////////////////////////*/

    function test_pausedRejectsSession() public {
        vm.prank(guardian);
        account.pauseSessions();
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectValidateRevert(op, abi.encodeWithSelector(IAgentWallet.SessionsArePaused.selector));
    }

    function test_pausedStillAcceptsOwner() public {
        vm.prank(guardian);
        account.pauseSessions();
        assertEq(validate(ownerOp("")), 0);
    }

    function test_rejectsWrongNonceKey() public {
        PackedUserOperation memory op = baseOp(
            address(account), entryPoint.getNonce(address(account), 0), sessionCallData(tokenTransfer(recipient, 1))
        );
        signSession(op, agent, agentKey);
        expectValidateRevert(op, abi.encodeWithSelector(IAgentWallet.InvalidSessionNonceKey.selector, agent, 0));
    }

    /// @dev A session op must go through executeUserOp. Calling `execute`, admin functions or anything else
    /// directly would skip execution-phase enforcement.
    function test_rejectsNonExecuteUserOpCallData() public {
        bytes[] memory bad = new bytes[](4);
        bad[0] = abi.encodeCall(AgentWallet.execute, (recipient, 1 ether, ""));
        bad[1] = abi.encodeCall(AgentWallet.transferOwnership, (agent));
        bad[2] = abi.encodeCall(AgentWallet.unpauseSessions, ());
        bad[3] = hex"aabb";
        for (uint256 i; i < bad.length; ++i) {
            PackedUserOperation memory op = baseOp(address(account), sessionNonce(agent), bad[i]);
            signSession(op, agent, agentKey);
            bytes4 outer = bad[i].length >= 4 ? bytes4(bad[i]) : bytes4(0);
            expectValidateRevert(op, abi.encodeWithSelector(IAgentWallet.SessionCallDataNotAllowed.selector, outer));
        }
    }

    function test_rejectsEmptyBatch() public {
        PackedUserOperation memory op = agentOp(new IAgentWallet.Call[](0));
        expectValidateRevert(op, abi.encodeWithSelector(IAgentWallet.EmptyBatch.selector));
    }

    function test_rejectsWrongTarget() public {
        address other = makeAddr("otherToken");
        expectPolicyRevert(
            one(other, 0, abi.encodeWithSelector(TRANSFER, recipient, 1)),
            abi.encodeWithSelector(IAgentWallet.CallNotAllowed.selector, agent, other, TRANSFER)
        );
    }

    function test_rejectsWrongSelector() public {
        bytes4 otherSel = MockTarget.other.selector;
        expectPolicyRevert(
            one(address(target), 0, abi.encodeWithSelector(otherSel)),
            abi.encodeWithSelector(IAgentWallet.CallNotAllowed.selector, agent, address(target), otherSel)
        );
    }

    function test_rejectsEthToUnlistedAddress() public {
        address stranger = makeAddr("stranger");
        expectPolicyRevert(
            ethTransfer(stranger, 0.1 ether),
            abi.encodeWithSelector(IAgentWallet.CallNotAllowed.selector, agent, stranger, bytes4(0))
        );
    }

    function test_rejectsValueOverPerCallCap() public {
        uint256 value = MAX_VALUE_PER_CALL + 1;
        expectPolicyRevert(
            ethTransfer(recipient, value),
            abi.encodeWithSelector(IAgentWallet.ValuePerCallExceeded.selector, agent, value, MAX_VALUE_PER_CALL)
        );
    }

    function test_acceptsValueAtPerCallCap() public {
        assertEq(validate(agentOp(ethTransfer(recipient, MAX_VALUE_PER_CALL))), expectedSessionData(agent));
    }

    function test_rejectsValueWithoutNativeLimit() public {
        (address key, uint256 pk) = makeAddrAndKey("noEth");
        IAgentWallet.SessionParams memory p = defaultSession(key);
        IAgentWallet.SpendLimit[] memory limits = new IAgentWallet.SpendLimit[](1);
        limits[0] = p.spendLimits[0];
        p.spendLimits = limits;
        addSession(p);

        PackedUserOperation memory op =
            sessionOp(key, pk, one(address(target), 1, abi.encodeCall(MockTarget.ping, (1))));
        expectValidateRevert(op, abi.encodeWithSelector(IAgentWallet.NoSpendLimit.selector, key, address(0)));
    }

    function test_rejectsMalformedCallData() public {
        expectPolicyRevert(
            one(address(target), 0, hex"aabbcc"),
            abi.encodeWithSelector(IAgentWallet.MalformedCallData.selector, address(target))
        );
    }

    /// @dev Trailing bytes after a transfer would make "which word is the amount" ambiguous for weird tokens.
    function test_rejectsNonCanonicalTokenCall() public {
        bytes memory data = abi.encodePacked(abi.encodeWithSelector(TRANSFER, recipient, 1), uint256(0));
        expectPolicyRevert(
            one(address(token), 0, data),
            abi.encodeWithSelector(IAgentWallet.MalformedTokenCall.selector, address(token))
        );
    }

    function test_batchWithOneBadCallRejected() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](3);
        calls[0] = transferCall(recipient, 1e18);
        calls[1] = IAgentWallet.Call(address(target), 0, abi.encodeCall(MockTarget.other, ()));
        calls[2] = transferCall(recipient, 1e18);
        expectPolicyRevert(
            calls,
            abi.encodeWithSelector(
                IAgentWallet.CallNotAllowed.selector, agent, address(target), MockTarget.other.selector
            )
        );
        assertEq(account.getSession(agent).callsUsed, 0);
    }

    function test_countsCallsIncludingBatchEntries() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](3);
        calls[0] = transferCall(recipient, 1);
        calls[1] = transferCall(recipient, 1);
        calls[2] = approveCall(recipient, 1);
        validate(agentOp(calls));
        assertEq(account.getSession(agent).callsUsed, 3);
    }

    function test_rejectsOverMaxCalls() public {
        (address key, uint256 pk) = makeAddrAndKey("twoCalls");
        IAgentWallet.SessionParams memory p = defaultSession(key);
        p.maxCalls = 2;
        addSession(p);

        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](2);
        calls[0] = transferCall(recipient, 1);
        calls[1] = transferCall(recipient, 1);
        PackedUserOperation memory op = sessionOp(key, pk, calls);
        validate(op);

        op = sessionOp(key, pk, tokenTransfer(recipient, 1));
        expectValidateRevert(op, abi.encodeWithSelector(IAgentWallet.SessionCallLimitExceeded.selector, key, 3, 2));
    }

    function test_chargesWorstCaseGasToBudget() public {
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        validate(op);
        assertEq(account.getSession(agent).gasSpent, maxCost(op));
    }

    function test_rejectsOverGasBudget() public {
        (address key, uint256 pk) = makeAddrAndKey("smallBudget");
        IAgentWallet.SessionParams memory p = defaultSession(key);
        PackedUserOperation memory op = sessionOp(key, pk, tokenTransfer(recipient, 1));
        uint256 cost = maxCost(op);
        p.gasBudget = uint128(cost * 2 - 1);
        addSession(p);

        validate(sessionOp(key, pk, tokenTransfer(recipient, 1)));

        op = sessionOp(key, pk, tokenTransfer(recipient, 1));
        expectValidateRevert(
            op, abi.encodeWithSelector(IAgentWallet.SessionGasBudgetExceeded.selector, key, cost, cost - 1)
        );
    }

    /// @dev A leaked key could otherwise set a huge maxFeePerGas and burn the account's ETH through a
    /// colluding bundler.
    function test_rejectsHighFeeOpAgainstBudget() public {
        PackedUserOperation memory op =
            baseOp(address(account), sessionNonce(agent), sessionCallData(tokenTransfer(recipient, 1)));
        op.gasFees = packGas(1000 gwei, 1000 gwei);
        signSession(op, agent, agentKey);
        uint256 cost = maxCost(op);
        expectValidateRevert(
            op, abi.encodeWithSelector(IAgentWallet.SessionGasBudgetExceeded.selector, agent, cost, GAS_BUDGET)
        );
    }

    function test_paymasterOpDoesNotChargeBudget() public {
        PackedUserOperation memory op =
            baseOp(address(account), sessionNonce(agent), sessionCallData(tokenTransfer(recipient, 1)));
        op.paymasterAndData = abi.encodePacked(makeAddr("paymaster"), uint128(100_000), uint128(100_000));
        signSession(op, agent, agentKey);
        validate(op);
        assertEq(account.getSession(agent).gasSpent, 0);
    }

    /// @dev Expiry is enforced by the EntryPoint from validationData (TIMESTAMP is banned in validation),
    /// so validation itself succeeds outside the window and returns the bounds.
    function test_returnsWindowEvenWhenExpired() public {
        vm.warp(block.timestamp + 365 days);
        assertEq(validate(agentOp(tokenTransfer(recipient, 1))), expectedSessionData(agent));
    }

    function expectPolicyRevert(IAgentWallet.Call[] memory calls, bytes memory err) internal {
        expectValidateRevert(agentOp(calls), err);
    }
}
