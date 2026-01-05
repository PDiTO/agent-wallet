// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/// @notice Optional v0.7 execution hook. When `userOp.callData` starts with this function's selector, the
/// EntryPoint calls it with the whole user operation instead of forwarding `callData` as is.
interface IAccountExecute {
    /// @param userOp The operation that passed validation.
    /// @param userOpHash Hash of the operation.
    function executeUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external;
}
