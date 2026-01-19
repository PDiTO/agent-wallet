// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";
import {SessionHandler} from "./SessionHandler.sol";

/// @notice Stateful properties of the session key system under random interleavings of owner actions,
/// guardian pauses, time warps and session operations through the EntryPoint.
contract SessionInvariantTest is AgentWalletTestBase {
    SessionHandler internal handler;
    uint256 internal initialEth;
    uint256 internal initialTokens;

    function setUp() public override {
        super.setUp();
        handler = new SessionHandler(account, entryPoint, token, target, owner, guardian, beneficiary);

        // Start every run with two live sessions so short runs still exercise the session paths.
        handler.addSession(1);
        handler.addSession(2);

        initialEth = address(account).balance;
        initialTokens = token.balanceOf(address(account));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = SessionHandler.addSession.selector;
        selectors[1] = SessionHandler.revokeSession.selector;
        selectors[2] = SessionHandler.pause.selector;
        selectors[3] = SessionHandler.unpause.selector;
        selectors[4] = SessionHandler.ownerSweep.selector;
        selectors[5] = SessionHandler.warp.selector;
        selectors[6] = SessionHandler.sessionTransfer.selector;
        selectors[7] = SessionHandler.sessionApprove.selector;
        selectors[8] = SessionHandler.sessionSendEth.selector;
        selectors[9] = SessionHandler.sessionBatch.selector;
        selectors[10] = SessionHandler.sessionForbidden.selector;
        selectors[11] = SessionHandler.strangerOp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Total a session key spent of an asset inside any one window never exceeds that asset's limit.
    /// Uses the handler's independent record of successful operations.
    function invariant_spendPerWindowWithinLimit() public view {
        uint256 n = handler.bucketCount();
        for (uint256 i; i < n; ++i) {
            SessionHandler.Bucket memory b = handler.bucket(i);
            (IAgentWallet.SpendState memory st,) = account.getSpendLimit(b.key, b.asset);
            assertLe(handler.ghostSpent(handler.bucketId(i)), st.limit, "window spend over limit");
        }
    }

    /// @notice The contract's own spend counters agree with the limit too.
    function invariant_storedSpendWithinLimit() public view {
        for (uint256 i; i < handler.keyCount(); ++i) {
            address key = handler.sessionKeys(i);
            (IAgentWallet.SpendState memory st,) = account.getSpendLimit(key, address(token));
            assertLe(st.spent, st.limit);
            (st,) = account.getSpendLimit(key, address(0));
            assertLe(st.spent, st.limit);
        }
    }

    /// @notice A revoked, expired, not-yet-valid or paused key never gets an operation through, and no
    /// session operation outside its policy (or from an unregistered key) ever succeeds.
    function invariant_unusableKeysNeverExecute() public view {
        assertEq(handler.violations(), 0);
    }

    /// @notice Tokens only leave the account to allowed recipients (via sessions) or to the owner's sink.
    function invariant_tokensOnlyLeaveThroughAllowedPaths() public view {
        address r0 = handler.recipients(0);
        address r1 = handler.recipients(1);
        address sink = handler.OWNER_SINK();

        assertEq(token.balanceOf(r0) + token.balanceOf(r1), handler.ghostTokenToRecipients());
        assertEq(token.balanceOf(sink), handler.ghostTokenToOwnerSink());
        assertEq(
            token.balanceOf(address(account)) + handler.ghostTokenToRecipients() + handler.ghostTokenToOwnerSink(),
            initialTokens
        );
        assertEq(token.balanceOf(handler.FORBIDDEN()), 0);
        assertEq(token.allowance(address(account), handler.FORBIDDEN()), 0);
    }

    /// @notice ETH only goes to allowed session destinations, the owner's sink, or to the bundler as gas.
    function invariant_ethOnlyLeavesThroughAllowedPaths() public view {
        uint256 toAllowed = handler.recipients(0).balance + handler.recipients(1).balance + address(target).balance;
        assertEq(toAllowed, handler.ghostEthToAllowed());
        assertEq(handler.OWNER_SINK().balance, handler.ghostEthToOwnerSink());
        assertEq(handler.FORBIDDEN().balance, 0);
        assertEq(
            address(account).balance + entryPoint.balanceOf(address(account)) + beneficiary.balance + toAllowed
                + handler.OWNER_SINK().balance,
            initialEth
        );
    }

    /// @notice Call counts and gas budgets are never overrun, and the owner never changes.
    function invariant_countersWithinBounds() public view {
        for (uint256 i; i < handler.keyCount(); ++i) {
            IAgentWallet.Session memory s = account.getSession(handler.sessionKeys(i));
            assertLe(s.callsUsed, s.maxCalls);
            assertLe(s.gasSpent, s.gasBudget);
        }
        assertEq(account.owner(), owner);
    }

    function afterInvariant() external view {
        console.log("session ops succeeded:            ", handler.sessionOpsSucceeded());
        console.log("session ops reverted in execution:", handler.sessionOpsRevertedInExecution());
        console.log("session ops rejected in validation:", handler.sessionOpsRejectedInValidation());
        console.log("spend windows tracked:            ", handler.bucketCount());
        console.log("keys added:                       ", handler.keysAdded());
    }
}
