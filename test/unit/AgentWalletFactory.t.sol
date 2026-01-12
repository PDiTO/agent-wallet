// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import {AgentWallet} from "../../src/AgentWallet.sol";
import {AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";

contract AgentWalletFactoryTest is AgentWalletTestBase {
    function test_getAddressMatchesDeployment() public {
        address predicted = factory.getAddress(owner, guardian, bytes32(uint256(7)));
        assertEq(predicted.code.length, 0);

        vm.expectEmit(true, true, true, true, address(factory));
        emit AgentWalletFactory.AccountCreated(predicted, owner, guardian, bytes32(uint256(7)));
        AgentWallet deployed = factory.createAccount(owner, guardian, bytes32(uint256(7)));

        assertEq(address(deployed), predicted);
        assertEq(deployed.owner(), owner);
        assertEq(deployed.guardian(), guardian);
        assertEq(address(deployed.ENTRY_POINT()), address(entryPoint));
    }

    function test_createAccountIsIdempotent() public {
        AgentWallet a = factory.createAccount(owner, guardian, bytes32(uint256(1)));
        vm.recordLogs();
        AgentWallet b = factory.createAccount(owner, guardian, bytes32(uint256(1)));
        assertEq(address(a), address(b));
        assertEq(vm.getRecordedLogs().length, 0, "second call must not redeploy or reinitialize");
    }

    /// @dev The salt commits to owner and guardian, so nobody can claim someone else's counterfactual
    /// address with a different owner.
    function test_saltBindsOwnerAndGuardian() public view {
        bytes32 salt = bytes32(uint256(1));
        address base = factory.getAddress(owner, guardian, salt);
        assertTrue(base != factory.getAddress(agent, guardian, salt));
        assertTrue(base != factory.getAddress(owner, address(0), salt));
        assertTrue(base != factory.getAddress(owner, guardian, bytes32(uint256(2))));
    }

    function test_createAccountRejectsZeroOwner() public {
        vm.expectRevert(IAgentWallet.InvalidOwner.selector);
        factory.createAccount(address(0), guardian, bytes32(0));
    }

    function test_accountCannotBeReinitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        account.initialize(agent, address(0));
    }

    function test_implementationCannotBeInitialized() public {
        AgentWallet impl = factory.ACCOUNT_IMPLEMENTATION();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(agent, address(0));
        assertEq(impl.owner(), address(0));
    }
}
