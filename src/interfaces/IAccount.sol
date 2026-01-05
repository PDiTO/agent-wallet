// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/// @notice ERC-4337 account validation entry point, as called by the v0.7 EntryPoint.
interface IAccount {
    /// @notice Validate a user operation and pay the EntryPoint what it is missing for the prefund.
    /// @param userOp The operation being validated.
    /// @param userOpHash Hash of the operation, the EntryPoint address and the chain id.
    /// @param missingAccountFunds Amount the account must transfer to the EntryPoint to cover the prefund.
    /// @return validationData `authorizer` (low 160 bits, 0 = ok, 1 = signature failure), `validUntil`
    /// (next 48 bits, 0 = forever) and `validAfter` (high 48 bits).
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        returns (uint256 validationData);
}
