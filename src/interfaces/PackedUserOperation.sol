// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice ERC-4337 v0.7 user operation, as passed to the EntryPoint and the account.
/// @dev Field layout matches `PackedUserOperation` in eth-infinitism/account-abstraction v0.7.0 so the
/// ABI encoding is identical. It is redeclared here so the account does not compile in any GPL-3.0 code.
/// @param sender The account making the operation.
/// @param nonce 192-bit key in the high bits, 64-bit sequence in the low bits. Managed by the EntryPoint.
/// @param initCode Factory address followed by factory calldata, only set on the first operation.
/// @param callData The data the EntryPoint passes to the account during execution.
/// @param accountGasLimits `verificationGasLimit` (high 128 bits) and `callGasLimit` (low 128 bits).
/// @param preVerificationGas Gas paid to the bundler for overhead not measured on chain.
/// @param gasFees `maxPriorityFeePerGas` (high 128 bits) and `maxFeePerGas` (low 128 bits).
/// @param paymasterAndData Paymaster address, its gas limits and data. Empty when the account pays.
/// @param signature Account-defined signature. Not covered by the user operation hash.
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits;
    uint256 preVerificationGas;
    bytes32 gasFees;
    bytes paymasterAndData;
    bytes signature;
}
