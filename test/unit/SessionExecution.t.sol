// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";

/// @notice Execution phase in isolation: `executeUserOp` called directly as the EntryPoint. This is where
/// the time-windowed spend limits live.
contract SessionExecutionTest is AgentWalletTestBase {
    function setUp() public override {
        super.setUp();
        addDefaultSession();
    }

    function exec(IAgentWallet.Call[] memory calls) internal {
        PackedUserOperation memory op = agentOp(calls);
        vm.prank(address(entryPoint));
        account.executeUserOp(op, bytes32(0));
    }

    function expectExecRevert(IAgentWallet.Call[] memory calls, bytes memory err) internal {
        PackedUserOperation memory op = agentOp(calls);
        vm.prank(address(entryPoint));
        vm.expectRevert(err);
        account.executeUserOp(op, bytes32(0));
    }

    function remaining(address asset) internal view returns (uint256 r) {
        (, r) = account.getSpendLimit(agent, asset);
    }

    function spendLimitExceeded(address asset, uint256 amount, uint256 left) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IAgentWallet.SpendLimitExceeded.selector, agent, asset, amount, left);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-20 DECODING
    //////////////////////////////////////////////////////////////*/

    function test_transferChargesLimit() public {
        uint64 window = uint64(block.timestamp / DAY);
        vm.expectEmit(true, true, false, true, address(account));
        emit IAgentWallet.SessionSpent(agent, address(token), 40e18, 40e18, window);
        exec(tokenTransfer(recipient, 40e18));

        assertEq(token.balanceOf(recipient), 40e18);
        assertEq(remaining(address(token)), TOKEN_LIMIT - 40e18);
    }

    function test_approveChargesLimit() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        calls[0] = approveCall(recipient, 30e18);
        exec(calls);
        assertEq(token.allowance(address(account), recipient), 30e18);
        assertEq(remaining(address(token)), TOKEN_LIMIT - 30e18);
    }

    function test_approveZeroIsFree() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        calls[0] = approveCall(recipient, 0);
        exec(calls);
        assertEq(remaining(address(token)), TOKEN_LIMIT);
    }

    function test_transferOverLimitReverts() public {
        expectExecRevert(
            tokenTransfer(recipient, TOKEN_LIMIT + 1), spendLimitExceeded(address(token), TOKEN_LIMIT + 1, TOKEN_LIMIT)
        );
    }

    function test_transferAtLimitSucceeds() public {
        exec(tokenTransfer(recipient, TOKEN_LIMIT));
        assertEq(remaining(address(token)), 0);
    }

    function test_limitIsCumulativeAcrossOps() public {
        exec(tokenTransfer(recipient, 60e18));
        expectExecRevert(tokenTransfer(recipient, 41e18), spendLimitExceeded(address(token), 41e18, 40e18));
        exec(tokenTransfer(recipient, 40e18));
        assertEq(token.balanceOf(recipient), TOKEN_LIMIT);
    }

    /// @dev Approve and transfer draw from the same budget, and batch entries are charged one by one.
    function test_batchChargesEachCall() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](3);
        calls[0] = transferCall(recipient, 50e18);
        calls[1] = approveCall(recipient, 30e18);
        calls[2] = transferCall(recipient, 30e18);
        expectExecRevert(calls, spendLimitExceeded(address(token), 30e18, 20e18));

        // Atomic: nothing from the rejected batch landed.
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(address(account), recipient), 0);
        assertEq(remaining(address(token)), TOKEN_LIMIT);
    }

    function test_batchWithDisallowedCallRevertsEverything() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](2);
        calls[0] = transferCall(recipient, 10e18);
        calls[1] = IAgentWallet.Call(address(target), 0, abi.encodeCall(MockTarget.other, ()));
        expectExecRevert(
            calls,
            abi.encodeWithSelector(
                IAgentWallet.CallNotAllowed.selector, agent, address(target), MockTarget.other.selector
            )
        );
        assertEq(token.balanceOf(recipient), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              NATIVE ETH
    //////////////////////////////////////////////////////////////*/

    function test_nativeValueChargesLimit() public {
        exec(ethTransfer(recipient, 0.5 ether));
        exec(one(address(target), 0.3 ether, abi.encodeCall(MockTarget.ping, (1))));
        assertEq(recipient.balance, 0.5 ether);
        assertEq(target.lastValue(), 0.3 ether);
        assertEq(remaining(address(0)), ETH_LIMIT - 0.8 ether);

        expectExecRevert(ethTransfer(recipient, 0.3 ether), spendLimitExceeded(address(0), 0.3 ether, 0.2 ether));
    }

    /*//////////////////////////////////////////////////////////////
                               PERIODS
    //////////////////////////////////////////////////////////////*/

    function test_limitResetsAtWindowBoundary() public {
        uint256 windowStart = (block.timestamp / DAY) * DAY;
        uint256 nextWindow = windowStart + DAY;

        exec(tokenTransfer(recipient, TOKEN_LIMIT));

        vm.warp(nextWindow - 1);
        expectExecRevert(tokenTransfer(recipient, 1), spendLimitExceeded(address(token), 1, 0));
        assertEq(remaining(address(token)), 0);

        vm.warp(nextWindow);
        assertEq(remaining(address(token)), TOKEN_LIMIT);
        exec(tokenTransfer(recipient, TOKEN_LIMIT));
        assertEq(token.balanceOf(recipient), 2 * TOKEN_LIMIT);
    }

    function test_unusedWindowsDoNotAccumulate() public {
        vm.warp(block.timestamp + 5 * DAY);
        expectExecRevert(
            tokenTransfer(recipient, TOKEN_LIMIT + 1), spendLimitExceeded(address(token), TOKEN_LIMIT + 1, TOKEN_LIMIT)
        );
    }

    function test_lifetimeLimitNeverResets() public {
        (address key, uint256 pk) = makeAddrAndKey("lifetime");
        IAgentWallet.SessionParams memory p = defaultSession(key);
        p.spendLimits[0].period = 0;
        addSession(p);

        PackedUserOperation memory op = sessionOp(key, pk, tokenTransfer(recipient, TOKEN_LIMIT));
        vm.prank(address(entryPoint));
        account.executeUserOp(op, bytes32(0));

        vm.warp(block.timestamp + 20 days);
        op = sessionOp(key, pk, tokenTransfer(recipient, 1));
        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.SpendLimitExceeded.selector, key, address(token), 1, 0));
        account.executeUserOp(op, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                    STATE CHANGED SINCE VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_revokedAfterValidationRejected() public {
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1e18));
        vm.prank(owner);
        account.revokeSession(agent);
        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.SessionNotActive.selector, agent));
        account.executeUserOp(op, bytes32(0));
    }

    function test_pausedAfterValidationRejected() public {
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1e18));
        vm.prank(guardian);
        account.pauseSessions();
        vm.prank(address(entryPoint));
        vm.expectRevert(IAgentWallet.SessionsArePaused.selector);
        account.executeUserOp(op, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /// @dev Owner operations may use executeUserOp too, with no policy applied.
    function test_ownerExecuteUserOpIsUnrestricted() public {
        address stranger = makeAddr("stranger");
        PackedUserOperation memory op = ownerOp(sessionCallData(ethTransfer(stranger, 5 ether)));
        vm.prank(address(entryPoint));
        account.executeUserOp(op, bytes32(0));
        assertEq(stranger.balance, 5 ether);
    }

    function test_sessionExecutedEvent() public {
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        vm.expectEmit(true, true, false, true, address(account));
        emit IAgentWallet.SessionExecuted(agent, bytes32(uint256(123)), 1);
        vm.prank(address(entryPoint));
        account.executeUserOp(op, bytes32(uint256(123)));
    }
}
