// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {IEntryPoint} from "../../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";

/// @notice Property tests over amounts, timestamps, selectors and gas fields.
contract SessionFuzzTest is AgentWalletTestBase {
    function setUp() public override {
        super.setUp();
        token.mint(address(account), 1_000_000e18);
        vm.deal(address(account), 1000 ether);
    }

    function tryHandle(PackedUserOperation memory op) internal returns (bool ok, bytes memory err) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        try entryPoint.handleOps(ops, beneficiary) {
            ok = true;
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    function execDirect(IAgentWallet.Call[] memory calls) internal returns (bool ok, bytes memory err) {
        PackedUserOperation memory op = agentOp(calls);
        vm.prank(address(entryPoint));
        try account.executeUserOp(op, bytes32(0)) {
            ok = true;
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                AMOUNTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_transferSucceedsIffWithinLimit(uint256 amount) public {
        addDefaultSession();
        amount = bound(amount, 0, uint256(TOKEN_LIMIT) * 3);

        OpResult memory r = handleAndRecord(agentOp(tokenTransfer(recipient, amount)));

        assertEq(r.success, amount <= TOKEN_LIMIT);
        assertEq(token.balanceOf(recipient), amount <= TOKEN_LIMIT ? amount : 0);
    }

    /// @dev Amounts above uint128 must be rejected, not truncated into the limit.
    function testFuzz_hugeAmountsNeverWrap(uint256 amount) public {
        addDefaultSession();
        amount = bound(amount, uint256(TOKEN_LIMIT) + 1, type(uint256).max);
        (bool ok, bytes memory err) = execDirect(tokenTransfer(recipient, amount));
        assertFalse(ok);
        assertEq(
            err,
            abi.encodeWithSelector(IAgentWallet.SpendLimitExceeded.selector, agent, address(token), amount, TOKEN_LIMIT)
        );
    }

    function testFuzz_approveDecodedAndCharged(uint256 amount) public {
        addDefaultSession();
        amount = bound(amount, 0, TOKEN_LIMIT);
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        calls[0] = approveCall(recipient, amount);
        (bool ok,) = execDirect(calls);
        assertTrue(ok);
        assertEq(token.allowance(address(account), recipient), amount);
        (, uint256 left) = account.getSpendLimit(agent, address(token));
        assertEq(left, TOKEN_LIMIT - amount);
    }

    function testFuzz_batchSucceedsIffSumWithinLimit(uint256 seed, uint8 n) public {
        addDefaultSession();
        n = uint8(bound(n, 1, 8));
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](n);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 amount = uint256(keccak256(abi.encode(seed, i))) % (uint256(TOKEN_LIMIT) / 2);
            sum += amount;
            calls[i] = i % 2 == 0 ? transferCall(recipient, amount) : approveCall(recipient, amount);
        }
        (bool ok,) = execDirect(calls);
        assertEq(ok, sum <= TOKEN_LIMIT);
    }

    function testFuzz_valueCapAndNativeLimit(uint256 value) public {
        addDefaultSession();
        value = bound(value, 0, 2 ether);

        PackedUserOperation memory op = agentOp(ethTransfer(recipient, value));
        vm.recordLogs();
        (bool included, bytes memory err) = tryHandle(op);

        if (value > MAX_VALUE_PER_CALL) {
            // Rejected in validation, so never included and no gas charged to the account.
            assertFalse(included);
            assertEq(
                err,
                abi.encodeWithSelector(
                    IEntryPoint.FailedOpWithRevert.selector,
                    0,
                    "AA23 reverted",
                    abi.encodeWithSelector(IAgentWallet.ValuePerCallExceeded.selector, agent, value, MAX_VALUE_PER_CALL)
                )
            );
        } else {
            assertTrue(included);
            assertTrue(resultOf(vm.getRecordedLogs(), entryPoint.getUserOpHash(op)).success);
            assertEq(recipient.balance, value);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               TIMESTAMPS
    //////////////////////////////////////////////////////////////*/

    /// @dev The EntryPoint accepts the op iff validAfter <= now <= validUntil, from the packed validationData.
    function testFuzz_validityWindow(uint48 startOffset, uint48 duration, uint256 at) public {
        uint256 validAfter = block.timestamp + bound(startOffset, 0, 30 days);
        uint256 validUntil = validAfter + bound(duration, 1, 30 days);
        at = bound(at, block.timestamp, validUntil + 30 days);

        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.validAfter = uint48(validAfter);
        p.validUntil = uint48(validUntil);
        addSession(p);

        vm.warp(at);
        (bool ok, bytes memory err) = tryHandle(agentOp(tokenTransfer(recipient, 1)));

        bool inWindow = at >= validAfter && at <= validUntil;
        assertEq(ok, inWindow);
        if (!inWindow) {
            assertEq(err, abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA22 expired or not due"));
        }
    }

    /// @dev Spend resets exactly when block.timestamp crosses into a new period, and not before.
    function testFuzz_windowBoundary(uint48 period, uint256 start, uint256 elapsed) public {
        period = uint48(bound(period, 1 minutes, 30 days));
        start = bound(start, START_TIME, START_TIME + 365 days);
        elapsed = bound(elapsed, 0, 3 * uint256(period));
        vm.warp(start);

        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.spendLimits[0].period = period;
        p.validUntil = uint48(start + 10 * uint256(period) + 1);
        addSession(p);

        (bool ok,) = execDirect(tokenTransfer(recipient, TOKEN_LIMIT));
        assertTrue(ok);

        vm.warp(start + elapsed);
        bool newWindow = (start + elapsed) / period != start / period;
        (ok,) = execDirect(tokenTransfer(recipient, 1));
        assertEq(ok, newWindow);
        (, uint256 left) = account.getSpendLimit(agent, address(token));
        assertEq(left, newWindow ? TOKEN_LIMIT - 1 : 0);
    }

    /*//////////////////////////////////////////////////////////////
                               SELECTORS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_unlistedSelectorRejected(bytes4 selector, bytes memory args) public {
        vm.assume(selector != PING);
        addDefaultSession();
        bytes memory data = abi.encodePacked(selector, args);
        PackedUserOperation memory op = agentOp(one(address(target), 0, data));

        expectValidationRevert(
            abi.encodeWithSelector(IAgentWallet.CallNotAllowed.selector, agent, address(target), selector)
        );
        handle(op);
    }

    function testFuzz_unlistedTokenSelectorRejected(bytes4 selector) public {
        vm.assume(selector != TRANSFER && selector != APPROVE);
        addDefaultSession();
        bytes memory data = abi.encodeWithSelector(selector, recipient, uint256(1));
        PackedUserOperation memory op = agentOp(one(address(token), 0, data));

        expectValidationRevert(
            abi.encodeWithSelector(IAgentWallet.CallNotAllowed.selector, agent, address(token), selector)
        );
        handle(op);
    }

    function testFuzz_unlistedTargetRejected(address to) public {
        vm.assume(to != address(token) && to != address(target) && to != recipient);
        addDefaultSession();
        PackedUserOperation memory op = agentOp(one(to, 0, abi.encodeCall(MockTarget.ping, (1))));

        expectValidationRevert(abi.encodeWithSelector(IAgentWallet.CallNotAllowed.selector, agent, to, PING));
        handle(op);
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_gasBudgetBoundsWorstCase(uint128 maxFee, uint128 callGas) public {
        addDefaultSession();
        maxFee = uint128(bound(maxFee, 1, 10_000 gwei));
        callGas = uint128(bound(callGas, 50_000, 5_000_000));

        PackedUserOperation memory op =
            baseOp(address(account), sessionNonce(agent), sessionCallData(tokenTransfer(recipient, 1)));
        op.accountGasLimits = packGas(VERIFICATION_GAS, callGas);
        op.gasFees = packGas(maxFee, maxFee);
        signSession(op, agent, agentKey);

        uint256 cost = maxCost(op);
        bytes32 hash = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        try account.validateUserOp(op, hash, 0) {
            assertLe(cost, GAS_BUDGET);
            assertEq(account.getSession(agent).gasSpent, cost);
        } catch (bytes memory err) {
            assertGt(cost, GAS_BUDGET);
            assertEq(
                err, abi.encodeWithSelector(IAgentWallet.SessionGasBudgetExceeded.selector, agent, cost, GAS_BUDGET)
            );
        }
    }
}
