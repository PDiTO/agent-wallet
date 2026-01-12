// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AgentWallet} from "../../src/AgentWallet.sol";
import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";

/// @notice Owner, guardian and configuration paths, called directly rather than through the EntryPoint.
contract AgentWalletAdminTest is AgentWalletTestBase {
    /*//////////////////////////////////////////////////////////////
                               EXECUTION
    //////////////////////////////////////////////////////////////*/

    function test_ownerCanExecute() public {
        vm.prank(owner);
        account.execute(address(target), 0.1 ether, abi.encodeCall(MockTarget.ping, (3)));
        assertEq(target.pings(), 3);
        assertEq(target.lastValue(), 0.1 ether);
        assertEq(target.lastCaller(), address(account));
    }

    function test_entryPointCanExecute() public {
        vm.prank(address(entryPoint));
        account.execute(address(target), 0, abi.encodeCall(MockTarget.ping, (1)));
        assertEq(target.pings(), 1);
    }

    function test_ownerCanExecuteBatch() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](2);
        calls[0] = IAgentWallet.Call(address(target), 0, abi.encodeCall(MockTarget.ping, (2)));
        calls[1] = transferCall(recipient, 5e18);
        vm.prank(owner);
        account.executeBatch(calls);
        assertEq(target.pings(), 2);
        assertEq(token.balanceOf(recipient), 5e18);
    }

    function test_executeRejectsOthers() public {
        addDefaultSession();
        address[3] memory callers = [agent, guardian, makeAddr("stranger")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IAgentWallet.NotAuthorized.selector);
            account.execute(address(target), 0, abi.encodeCall(MockTarget.ping, (1)));

            vm.prank(callers[i]);
            vm.expectRevert(IAgentWallet.NotAuthorized.selector);
            account.executeBatch(tokenTransfer(recipient, 1));
        }
    }

    function test_executeBubblesRevertData() public {
        vm.prank(owner);
        vm.expectRevert(MockTarget.Nope.selector);
        account.execute(address(target), 0, abi.encodeCall(MockTarget.fail, ()));
    }

    function test_batchIsAtomic() public {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](2);
        calls[0] = transferCall(recipient, 5e18);
        calls[1] = IAgentWallet.Call(address(target), 0, abi.encodeCall(MockTarget.fail, ()));
        vm.prank(owner);
        vm.expectRevert(MockTarget.Nope.selector);
        account.executeBatch(calls);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_executeUserOpOnlyFromEntryPoint() public {
        addDefaultSession();
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.NotEntryPoint.selector);
        account.executeUserOp(op, bytes32(0));
    }

    function test_validateUserOpOnlyFromEntryPoint() public {
        PackedUserOperation memory op = ownerOp("");
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.NotEntryPoint.selector);
        account.validateUserOp(op, bytes32(0), 0);
    }

    function test_receivesEth() public {
        uint256 before = address(account).balance;
        (bool ok,) = address(account).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(account).balance, before + 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER ROTATION
    //////////////////////////////////////////////////////////////*/

    function test_transferOwnership() public {
        address next = makeAddr("next");
        vm.expectEmit(true, true, false, false, address(account));
        emit IAgentWallet.OwnerTransferred(owner, next);
        vm.prank(owner);
        account.transferOwnership(next);
        assertEq(account.owner(), next);

        // The old owner is locked out, the new one is in.
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.execute(address(target), 0, abi.encodeCall(MockTarget.ping, (1)));

        vm.prank(next);
        account.execute(address(target), 0, abi.encodeCall(MockTarget.ping, (1)));
        assertEq(target.pings(), 1);
    }

    function test_transferOwnershipRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.InvalidOwner.selector);
        account.transferOwnership(address(0));
    }

    function test_transferOwnershipRejectsSessionKey() public {
        addDefaultSession();
        vm.prank(owner);
        vm.expectRevert(IAgentWallet.InvalidOwner.selector);
        account.transferOwnership(agent);
    }

    function test_transferOwnershipOnlyOwner() public {
        vm.prank(guardian);
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.transferOwnership(guardian);
    }

    /*//////////////////////////////////////////////////////////////
                           GUARDIAN AND PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_setGuardian() public {
        address next = makeAddr("nextGuardian");
        vm.expectEmit(true, true, false, false, address(account));
        emit IAgentWallet.GuardianSet(guardian, next);
        vm.prank(owner);
        account.setGuardian(next);
        assertEq(account.guardian(), next);

        vm.prank(guardian);
        vm.expectRevert(IAgentWallet.NotOwnerOrGuardian.selector);
        account.pauseSessions();
    }

    function test_setGuardianOnlyOwner() public {
        vm.prank(guardian);
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.setGuardian(guardian);
    }

    function test_ownerPausesAndUnpauses() public {
        vm.expectEmit(true, false, false, false, address(account));
        emit IAgentWallet.SessionsPaused(owner);
        vm.prank(owner);
        account.pauseSessions();
        assertTrue(account.sessionsPaused());

        vm.expectEmit(true, false, false, false, address(account));
        emit IAgentWallet.SessionsUnpaused(owner);
        vm.prank(owner);
        account.unpauseSessions();
        assertFalse(account.sessionsPaused());
    }

    function test_guardianCanPauseButNothingElse() public {
        addDefaultSession();
        vm.prank(guardian);
        account.pauseSessions();
        assertTrue(account.sessionsPaused());

        vm.startPrank(guardian);
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.unpauseSessions();
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.execute(guardian, 1 ether, "");
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.addSession(defaultSession(guardian));
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.revokeSession(agent);
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.withdrawDepositTo(payable(guardian), 0);
        vm.stopPrank();
    }

    function test_strangerCannotPause() public {
        vm.prank(agent);
        vm.expectRevert(IAgentWallet.NotOwnerOrGuardian.selector);
        account.pauseSessions();
    }

    /*//////////////////////////////////////////////////////////////
                             SESSION SETUP
    //////////////////////////////////////////////////////////////*/

    function test_addSessionStoresPolicy() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);

        vm.expectEmit(true, false, false, true, address(account));
        emit IAgentWallet.SessionAdded(agent, p.validAfter, p.validUntil, p.maxCalls, p.maxValuePerCall, p.gasBudget);
        vm.expectEmit(true, true, false, true, address(account));
        emit IAgentWallet.SessionSpendLimitAdded(agent, address(token), TOKEN_LIMIT, uint48(DAY));
        vm.expectEmit(true, true, false, true, address(account));
        emit IAgentWallet.SessionSpendLimitAdded(agent, address(0), ETH_LIMIT, uint48(DAY));
        vm.expectEmit(true, true, false, true, address(account));
        emit IAgentWallet.SessionPermissionAdded(agent, address(token), TRANSFER);
        addSession(p);

        IAgentWallet.Session memory s = account.getSession(agent);
        assertEq(uint8(s.status), uint8(IAgentWallet.SessionStatus.Active));
        assertEq(s.validAfter, p.validAfter);
        assertEq(s.validUntil, p.validUntil);
        assertEq(s.maxCalls, MAX_CALLS);
        assertEq(s.callsUsed, 0);
        assertEq(s.maxValuePerCall, MAX_VALUE_PER_CALL);
        assertEq(s.gasBudget, GAS_BUDGET);
        assertEq(s.gasSpent, 0);

        assertTrue(account.isPermitted(agent, address(token), TRANSFER));
        assertTrue(account.isPermitted(agent, address(token), APPROVE));
        assertTrue(account.isPermitted(agent, address(target), PING));
        assertTrue(account.isPermitted(agent, recipient, bytes4(0)));
        assertFalse(account.isPermitted(agent, address(target), MockTarget.other.selector));

        (IAgentWallet.SpendState memory st, uint256 remaining) = account.getSpendLimit(agent, address(token));
        assertTrue(st.enabled);
        assertEq(st.limit, TOKEN_LIMIT);
        assertEq(st.period, DAY);
        assertEq(remaining, TOKEN_LIMIT);

        (st, remaining) = account.getSpendLimit(agent, makeAddr("unconfigured"));
        assertFalse(st.enabled);
        assertEq(remaining, 0);
    }

    function test_addSessionOnlyOwner() public {
        vm.prank(agent);
        vm.expectRevert(IAgentWallet.NotAuthorized.selector);
        account.addSession(defaultSession(agent));
    }

    function test_addSessionRejectsZeroKey() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.InvalidSessionKey.selector, address(0)));
        addSession(defaultSession(address(0)));
    }

    function test_addSessionRejectsOwnerAsKey() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.InvalidSessionKey.selector, owner));
        addSession(defaultSession(owner));
    }

    function test_addSessionRejectsActiveKey() public {
        addDefaultSession();
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.SessionKeyAlreadyUsed.selector, agent));
        addSession(defaultSession(agent));
    }

    /// @dev Keys are single use. Re-registering a revoked key would resurrect its counters and permissions.
    function test_addSessionRejectsRevokedKey() public {
        addDefaultSession();
        vm.prank(owner);
        account.revokeSession(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.SessionKeyAlreadyUsed.selector, agent));
        addSession(defaultSession(agent));
    }

    function test_addSessionRejectsEmptyWindow() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.validUntil = p.validAfter;
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.InvalidValidityWindow.selector, p.validAfter, p.validUntil));
        addSession(p);
    }

    function test_addSessionRejectsExpiredWindow() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.validAfter = uint48(block.timestamp - 2 days);
        p.validUntil = uint48(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.InvalidValidityWindow.selector, p.validAfter, p.validUntil));
        addSession(p);
    }

    function test_addSessionRejectsZeroMaxCalls() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.maxCalls = 0;
        vm.expectRevert(IAgentWallet.InvalidMaxCalls.selector);
        addSession(p);
    }

    function test_addSessionRejectsBadTargets() public {
        address[3] memory bad = [address(0), address(account), address(entryPoint)];
        for (uint256 i; i < bad.length; ++i) {
            IAgentWallet.SessionParams memory p = defaultSession(agent);
            p.permissions[1] = permission(bad[i], PING);
            vm.expectRevert(abi.encodeWithSelector(IAgentWallet.InvalidPermissionTarget.selector, bad[i]));
            addSession(p);
        }
    }

    function test_addSessionRejectsUnmeteredTransfer() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.permissions[1] = permission(address(target), TRANSFER);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentWallet.UnlimitedTokenPermission.selector, address(target), TRANSFER)
        );
        addSession(p);
    }

    function test_addSessionRejectsUnmeteredApprove() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.permissions[1] = permission(address(target), APPROVE);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentWallet.UnlimitedTokenPermission.selector, address(target), APPROVE)
        );
        addSession(p);
    }

    /// @dev On a metered token, anything besides transfer/approve (transferFrom, increaseAllowance, permit,
    /// ERC-677 transferAndCall...) could move funds without being charged.
    function test_addSessionRejectsOtherSelectorsOnMeteredToken() public {
        bytes4 transferFrom = 0x23b872dd;
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.permissions[0] = permission(address(token), TRANSFER, transferFrom);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentWallet.SelectorNotAllowedOnLimitedToken.selector, address(token), transferFrom)
        );
        addSession(p);
    }

    function test_addSessionRejectsBadSpendLimitTokens() public {
        address[2] memory bad = [address(account), address(entryPoint)];
        for (uint256 i; i < bad.length; ++i) {
            IAgentWallet.SessionParams memory p = defaultSession(agent);
            p.spendLimits[1].token = bad[i];
            vm.expectRevert(abi.encodeWithSelector(IAgentWallet.InvalidSpendLimitToken.selector, bad[i]));
            addSession(p);
        }
    }

    function test_addSessionRejectsDuplicateSpendLimit() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.spendLimits[1].token = address(token);
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.DuplicateSpendLimit.selector, address(token)));
        addSession(p);
    }

    function test_revokeSession() public {
        addDefaultSession();
        vm.expectEmit(true, false, false, false, address(account));
        emit IAgentWallet.SessionRevoked(agent);
        vm.prank(owner);
        account.revokeSession(agent);
        assertEq(uint8(account.getSession(agent).status), uint8(IAgentWallet.SessionStatus.Revoked));
    }

    function test_revokeRejectsUnknownAndRevoked() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.SessionNotActive.selector, agent));
        account.revokeSession(agent);

        addDefaultSession();
        vm.startPrank(owner);
        account.revokeSession(agent);
        vm.expectRevert(abi.encodeWithSelector(IAgentWallet.SessionNotActive.selector, agent));
        account.revokeSession(agent);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_depositAndWithdraw() public {
        account.addDeposit{value: 1 ether}();
        assertEq(account.getDeposit(), 1 ether);
        assertEq(entryPoint.balanceOf(address(account)), 1 ether);

        address payable to = payable(makeAddr("to"));
        vm.prank(owner);
        account.withdrawDepositTo(to, 0.4 ether);
        assertEq(to.balance, 0.4 ether);
        assertEq(account.getDeposit(), 0.6 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC-1271
    //////////////////////////////////////////////////////////////*/

    function test_isValidSignatureAcceptsOwnerOnReplaySafeHash() public view {
        bytes32 hash = keccak256("hello");
        assertEq(account.isValidSignature(hash, signDigest(ownerKey, account.replaySafeHash(hash))), bytes4(0x1626ba7e));
    }

    function test_isValidSignatureRejectsRawHash() public view {
        bytes32 hash = keccak256("hello");
        assertEq(account.isValidSignature(hash, signDigest(ownerKey, hash)), bytes4(0xffffffff));
    }

    /// @dev A session key must never produce ERC-1271 signatures, or it could sign permits around its limits.
    function test_isValidSignatureRejectsSessionKey() public {
        addDefaultSession();
        bytes32 hash = keccak256("permit");
        assertEq(account.isValidSignature(hash, signDigest(agentKey, account.replaySafeHash(hash))), bytes4(0xffffffff));
    }

    function test_isValidSignatureRejectsBadLength() public view {
        bytes32 hash = keccak256("hello");
        bytes memory sig = signDigest(ownerKey, account.replaySafeHash(hash));
        assertEq(account.isValidSignature(hash, abi.encodePacked(sig, uint8(0))), bytes4(0xffffffff));
        assertEq(account.isValidSignature(hash, ""), bytes4(0xffffffff));
    }

    /// @dev Same owner, two accounts: a signature made for one is not valid on the other.
    function test_isValidSignatureNotReplayableAcrossAccounts() public {
        AgentWallet second = factory.createAccount(owner, guardian, bytes32(uint256(1)));
        bytes32 hash = keccak256("order");
        bytes memory sig = signDigest(ownerKey, account.replaySafeHash(hash));
        assertEq(account.isValidSignature(hash, sig), bytes4(0x1626ba7e));
        assertEq(second.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    function signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
