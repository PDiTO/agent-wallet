// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {AgentWallet} from "./AgentWallet.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";

/// @title AgentWalletFactory
/// @author Paul Davis
/// @notice Deploys AgentWallet accounts as EIP-1167 minimal proxies at CREATE2 addresses that can be
/// computed before deployment, so an account can receive funds and be used through `initCode` on its first
/// user operation.
/// @dev The CREATE2 salt commits to the owner and guardian. Without that, anyone could front-run the first
/// deployment of a funded counterfactual address with a different owner. The factory holds no storage and
/// needs no stake under ERC-7562.
contract AgentWalletFactory {
    /// @notice The implementation every account delegates to.
    AgentWallet public immutable ACCOUNT_IMPLEMENTATION;

    event AccountCreated(address indexed account, address indexed owner, address indexed guardian, bytes32 salt);

    /// @param entryPoint The EntryPoint v0.7 instance deployed accounts will trust.
    constructor(IEntryPoint entryPoint) {
        ACCOUNT_IMPLEMENTATION = new AgentWallet(entryPoint);
    }

    /// @notice Deploy and initialize an account, or return it if it already exists.
    /// @dev Returning the existing account instead of reverting is what the EntryPoint expects from a
    /// factory, and it makes the call idempotent.
    /// @param owner ECDSA owner of the new account.
    /// @param guardian Optional pause-only guardian, zero for none.
    /// @param salt Caller-chosen salt, so one owner can have several accounts.
    function createAccount(address owner, address guardian, bytes32 salt) external returns (AgentWallet account) {
        bytes32 fullSalt = _salt(owner, guardian, salt);
        address predicted = Clones.predictDeterministicAddress(address(ACCOUNT_IMPLEMENTATION), fullSalt);
        if (predicted.code.length != 0) return AgentWallet(payable(predicted));

        account = AgentWallet(payable(Clones.cloneDeterministic(address(ACCOUNT_IMPLEMENTATION), fullSalt)));
        account.initialize(owner, guardian);
        emit AccountCreated(address(account), owner, guardian, salt);
    }

    /// @notice Counterfactual address of the account `createAccount` would deploy with these arguments.
    function getAddress(address owner, address guardian, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(address(ACCOUNT_IMPLEMENTATION), _salt(owner, guardian, salt));
    }

    function _salt(address owner, address guardian, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, guardian, salt));
    }
}
