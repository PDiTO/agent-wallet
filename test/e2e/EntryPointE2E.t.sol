// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";

import {AgentWallet} from "../../src/AgentWallet.sol";
import {AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {IEntryPoint} from "../../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";

/// @notice Full flows through `EntryPoint.handleOps` with real signatures, the way a bundler would submit
/// them (minus the off-chain simulation).
contract EntryPointE2ETest is AgentWalletTestBase {
    /*//////////////////////////////////////////////////////////////
                           DEPLOYMENT AND OWNER
    //////////////////////////////////////////////////////////////*/

    function test_counterfactualDeployThroughInitCode() public {
        (address newOwner, uint256 newOwnerKey) = makeAddrAndKey("newOwner");
        bytes32 salt = keccak256("first");
        address predicted = factory.getAddress(newOwner, guardian, salt);
        vm.deal(predicted, 1 ether);

        PackedUserOperation memory op = baseOp(
            predicted,
            0,
            abi.encodeCall(AgentWallet.execute, (address(target), 0, abi.encodeCall(MockTarget.ping, (7))))
        );
        op.initCode = abi.encodePacked(
            address(factory), abi.encodeCall(AgentWalletFactory.createAccount, (newOwner, guardian, salt))
        );
        op.signature = abi.encodePacked(uint8(0x00), sign(newOwnerKey, op));

        vm.expectEmit(true, true, false, true, address(entryPoint));
        emit IEntryPoint.AccountDeployed(entryPoint.getUserOpHash(op), predicted, address(factory), address(0));
        handle(op);

        assertGt(predicted.code.length, 0);
        assertEq(AgentWallet(payable(predicted)).owner(), newOwner);
        assertEq(target.pings(), 7);
        assertEq(target.lastCaller(), predicted);
    }

    function test_ownerOpExecutes() public {
        OpResult memory r = handleAndRecord(ownerOp(abi.encodeCall(AgentWallet.execute, (recipient, 2 ether, ""))));
        assertTrue(r.success);
        assertEq(recipient.balance, 2 ether);
    }

    function test_ownerOpConfiguresSessionThenAgentSpends() public {
        OpResult memory r = handleAndRecord(ownerOp(abi.encodeCall(AgentWallet.addSession, (defaultSession(agent)))));
        assertTrue(r.success);

        r = handleAndRecord(agentOp(tokenTransfer(recipient, 25e18)));
        assertTrue(r.success);
        assertEq(token.balanceOf(recipient), 25e18);
    }

    function test_ownerRotationThroughUserOp() public {
        (address next, uint256 nextKey) = makeAddrAndKey("next");
        handle(ownerOp(abi.encodeCall(AgentWallet.transferOwnership, (next))));
        assertEq(account.owner(), next);

        // Old owner's signature no longer validates.
        PackedUserOperation memory op = ownerOp(abi.encodeCall(AgentWallet.execute, (recipient, 1 ether, "")));
        expectFailedOp("AA24 signature error");
        handle(op);

        op = baseOp(
            address(account),
            entryPoint.getNonce(address(account), 0),
            abi.encodeCall(AgentWallet.execute, (recipient, 1 ether, ""))
        );
        op.signature = abi.encodePacked(uint8(0x00), sign(nextKey, op));
        handle(op);
        assertEq(recipient.balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              SESSION KEYS
    //////////////////////////////////////////////////////////////*/

    function test_sessionTransfer() public {
        addDefaultSession();
        uint256 ownerNonce = entryPoint.getNonce(address(account), 0);

        OpResult memory r = handleAndRecord(agentOp(tokenTransfer(recipient, 10e18)));

        assertTrue(r.found && r.success);
        assertEq(token.balanceOf(recipient), 10e18);
        assertEq(sessionNonce(agent) & type(uint64).max, 1, "session lane advanced");
        assertEq(entryPoint.getNonce(address(account), 0), ownerNonce, "owner lane untouched");
        assertEq(account.getSession(agent).callsUsed, 1);
    }

    function test_sessionBatch() public {
        addDefaultSession();
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](3);
        calls[0] = transferCall(recipient, 10e18);
        calls[1] = IAgentWallet.Call(address(target), 0.2 ether, abi.encodeCall(MockTarget.ping, (1)));
        calls[2] = IAgentWallet.Call(recipient, 0.1 ether, "");

        OpResult memory r = handleAndRecord(agentOp(calls));
        assertTrue(r.success);
        assertEq(token.balanceOf(recipient), 10e18);
        assertEq(recipient.balance, 0.1 ether);
        assertEq(target.pings(), 1);
        (, uint256 ethLeft) = account.getSpendLimit(agent, address(0));
        assertEq(ethLeft, ETH_LIMIT - 0.3 ether);
    }

    function test_sessionBatchWithOneBadCallRejectedEntirely() public {
        addDefaultSession();
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](2);
        calls[0] = transferCall(recipient, 10e18);
        calls[1] = IAgentWallet.Call(address(target), 0, abi.encodeCall(MockTarget.fail, ()));
        PackedUserOperation memory op = agentOp(calls);

        expectValidationRevert(
            abi.encodeWithSelector(
                IAgentWallet.CallNotAllowed.selector, agent, address(target), MockTarget.fail.selector
            )
        );
        handle(op);
        assertEq(token.balanceOf(recipient), 0);
    }

    /// @dev The wrong key yields SIG_VALIDATION_FAILED, which the EntryPoint reports as AA24, not AA23.
    function test_randomKeyFailsSignatureValidation() public {
        addDefaultSession();
        (, uint256 randomKey) = makeAddrAndKey("random");
        PackedUserOperation memory op =
            baseOp(address(account), sessionNonce(agent), sessionCallData(tokenTransfer(recipient, 1e18)));
        signSession(op, agent, randomKey);
        expectFailedOp("AA24 signature error");
        handle(op);
    }

    function test_randomKeyAsOwnerFailsSignatureValidation() public {
        (, uint256 randomKey) = makeAddrAndKey("random");
        PackedUserOperation memory op =
            baseOp(address(account), 0, abi.encodeCall(AgentWallet.execute, (recipient, 1 ether, "")));
        op.signature = abi.encodePacked(uint8(0x00), sign(randomKey, op));
        expectFailedOp("AA24 signature error");
        handle(op);
    }

    /// @dev A session key cannot claim the owner signature mode.
    function test_sessionKeyCannotSignAsOwner() public {
        addDefaultSession();
        PackedUserOperation memory op =
            baseOp(address(account), 0, abi.encodeCall(AgentWallet.execute, (agent, 1 ether, "")));
        op.signature = abi.encodePacked(uint8(0x00), sign(agentKey, op));
        expectFailedOp("AA24 signature error");
        handle(op);
    }

    function test_sessionCannotReachAdminFunctions() public {
        addDefaultSession();
        PackedUserOperation memory op =
            agentOp(one(address(account), 0, abi.encodeCall(AgentWallet.transferOwnership, (agent))));
        expectValidationRevert(
            abi.encodeWithSelector(
                IAgentWallet.CallNotAllowed.selector, agent, address(account), AgentWallet.transferOwnership.selector
            )
        );
        handle(op);
    }

    /*//////////////////////////////////////////////////////////////
                             VALIDITY WINDOW
    //////////////////////////////////////////////////////////////*/

    function test_expiredSessionRejected() public {
        addDefaultSession();
        uint48 validUntil = account.getSession(agent).validUntil;

        vm.warp(validUntil);
        handle(agentOp(tokenTransfer(recipient, 1)));

        vm.warp(uint256(validUntil) + 1);
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectFailedOp("AA22 expired or not due");
        handle(op);
    }

    function test_notYetValidSessionRejected() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.validAfter = uint48(block.timestamp + 1 hours);
        addSession(p);

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectFailedOp("AA22 expired or not due");
        handle(op);

        vm.warp(p.validAfter);
        handle(agentOp(tokenTransfer(recipient, 1)));
        assertEq(token.balanceOf(recipient), 1);
    }

    function test_revokedSessionRejected() public {
        addDefaultSession();
        handle(agentOp(tokenTransfer(recipient, 1)));
        vm.prank(owner);
        account.revokeSession(agent);

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectFailedOp("AA24 signature error");
        handle(op);
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE SWITCH
    //////////////////////////////////////////////////////////////*/

    function test_pauseRejectsSessionsButOwnerStillWorks() public {
        addDefaultSession();
        vm.prank(owner);
        account.pauseSessions();

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectValidationRevert(abi.encodeWithSelector(IAgentWallet.SessionsArePaused.selector));
        handle(op);

        OpResult memory r = handleAndRecord(ownerOp(abi.encodeCall(AgentWallet.execute, (recipient, 1 ether, ""))));
        assertTrue(r.success);

        handle(ownerOp(abi.encodeCall(AgentWallet.unpauseSessions, ())));
        r = handleAndRecord(agentOp(tokenTransfer(recipient, 1)));
        assertTrue(r.success);
    }

    function test_guardianPauseStopsAgent() public {
        addDefaultSession();
        vm.prank(guardian);
        account.pauseSessions();

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectValidationRevert(abi.encodeWithSelector(IAgentWallet.SessionsArePaused.selector));
        handle(op);
    }

    /// @dev Validation of every op in a bundle happens before any execution. An owner op that pauses must
    /// still stop a session op that was validated before the pause landed.
    function test_pauseInSameBundleStopsLaterSessionOp() public {
        addDefaultSession();
        PackedUserOperation memory pause = ownerOp(abi.encodeCall(AgentWallet.pauseSessions, ()));
        PackedUserOperation memory spend = agentOp(tokenTransfer(recipient, 10e18));

        vm.recordLogs();
        handle(pause, spend);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(resultOf(logs, entryPoint.getUserOpHash(pause)).success);
        OpResult memory r = resultOf(logs, entryPoint.getUserOpHash(spend));
        assertTrue(r.found);
        assertFalse(r.success);
        assertEq(r.revertReason, abi.encodeWithSelector(IAgentWallet.SessionsArePaused.selector));
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_revokeInSameBundleStopsLaterSessionOp() public {
        addDefaultSession();
        PackedUserOperation memory revoke = ownerOp(abi.encodeCall(AgentWallet.revokeSession, (agent)));
        PackedUserOperation memory spend = agentOp(tokenTransfer(recipient, 10e18));

        vm.recordLogs();
        handle(revoke, spend);
        OpResult memory r = resultOf(vm.getRecordedLogs(), entryPoint.getUserOpHash(spend));
        assertFalse(r.success);
        assertEq(r.revertReason, abi.encodeWithSelector(IAgentWallet.SessionNotActive.selector, agent));
        assertEq(token.balanceOf(recipient), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         EXECUTION-PHASE FAILURES
    //////////////////////////////////////////////////////////////*/

    /// @dev Spend limits are checked in execution, so an over-limit op is included, reverts, and still pays
    /// for gas. The gas budget bounds how much of that a leaked key can cause.
    function test_overLimitFailsInExecutionAndPaysGas() public {
        addDefaultSession();
        handle(agentOp(tokenTransfer(recipient, 90e18)));
        uint256 beneficiaryBefore = beneficiary.balance;

        OpResult memory r = handleAndRecord(agentOp(tokenTransfer(recipient, 20e18)));

        assertTrue(r.found);
        assertFalse(r.success);
        assertEq(
            r.revertReason,
            abi.encodeWithSelector(IAgentWallet.SpendLimitExceeded.selector, agent, address(token), 20e18, 10e18)
        );
        assertEq(token.balanceOf(recipient), 90e18);
        assertGt(r.actualGasCost, 0);
        assertEq(beneficiary.balance - beneficiaryBefore, r.actualGasCost);
        assertEq(account.getSession(agent).callsUsed, 2, "failed op still counted");
        assertEq(sessionNonce(agent) & type(uint64).max, 2, "failed op still consumed its nonce");
    }

    function test_gasBudgetExhaustedRejected() public {
        PackedUserOperation memory probe = agentOp(tokenTransfer(recipient, 1));
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.gasBudget = uint128(maxCost(probe));
        addSession(p);

        handle(agentOp(tokenTransfer(recipient, 1)));

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectValidationRevert(
            abi.encodeWithSelector(IAgentWallet.SessionGasBudgetExceeded.selector, agent, maxCost(op), 0)
        );
        handle(op);
    }

    function test_maxCallsExhaustedRejected() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        p.maxCalls = 1;
        addSession(p);
        handle(agentOp(tokenTransfer(recipient, 1)));

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1));
        expectValidationRevert(abi.encodeWithSelector(IAgentWallet.SessionCallLimitExceeded.selector, agent, 2, 1));
        handle(op);
    }

    /*//////////////////////////////////////////////////////////////
                           PREFUND AND NONCES
    //////////////////////////////////////////////////////////////*/

    /// @dev With no deposit the account sends the full worst-case prefund; the EntryPoint keeps the unused
    /// part as the account's deposit and pays the beneficiary the actual cost.
    function test_prefundFromAccountBalance() public {
        addDefaultSession();
        assertEq(account.getDeposit(), 0);
        uint256 balanceBefore = address(account).balance;

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1e18));
        uint256 prefund = maxCost(op);
        OpResult memory r = handleAndRecord(op);

        assertTrue(r.success);
        assertEq(address(account).balance, balanceBefore - prefund);
        assertEq(account.getDeposit(), prefund - r.actualGasCost);
        assertEq(beneficiary.balance, r.actualGasCost);
    }

    function test_prefundFromExistingDeposit() public {
        addDefaultSession();
        account.addDeposit{value: 1 ether}();
        uint256 balanceBefore = address(account).balance;

        OpResult memory r = handleAndRecord(agentOp(tokenTransfer(recipient, 1e18)));

        assertTrue(r.success);
        assertEq(address(account).balance, balanceBefore, "no ETH moved from the account");
        assertEq(account.getDeposit(), 1 ether - r.actualGasCost);
    }

    function test_insufficientFundsForPrefundRejected() public {
        addDefaultSession();
        vm.deal(address(account), 0);
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1e18));
        expectFailedOp("AA21 didn't pay prefund");
        handle(op);
    }

    function test_replayRejected() public {
        addDefaultSession();
        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1e18));
        handle(op);
        expectFailedOp("AA25 invalid account nonce");
        handle(op);
        assertEq(token.balanceOf(recipient), 1e18);
    }

    function test_ownerReplayRejected() public {
        PackedUserOperation memory op = ownerOp(abi.encodeCall(AgentWallet.execute, (recipient, 1 ether, "")));
        handle(op);
        expectFailedOp("AA25 invalid account nonce");
        handle(op);
        assertEq(recipient.balance, 1 ether);
    }

    /// @dev Owner and session each have their own nonce lane, so both can have an op in the same bundle.
    function test_ownerAndSessionLanesAreIndependent() public {
        addDefaultSession();
        PackedUserOperation memory a = ownerOp(abi.encodeCall(AgentWallet.execute, (recipient, 1 ether, "")));
        PackedUserOperation memory b = agentOp(tokenTransfer(recipient, 1e18));
        handle(a, b);
        assertEq(recipient.balance, 1 ether);
        assertEq(token.balanceOf(recipient), 1e18);
    }

    function test_sessionSignatureNotValidOnOtherAccount() public {
        addDefaultSession();
        AgentWallet second = factory.createAccount(owner, guardian, bytes32(uint256(1)));
        vm.deal(address(second), 1 ether);
        vm.prank(owner);
        second.addSession(defaultSession(agent));

        PackedUserOperation memory op = agentOp(tokenTransfer(recipient, 1e18));
        op.sender = address(second);
        // Signature was made over the first account's userOpHash.
        expectFailedOp("AA24 signature error");
        handle(op);
    }
}
