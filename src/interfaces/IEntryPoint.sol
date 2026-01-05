// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PackedUserOperation} from "./PackedUserOperation.sol";

/// @notice The subset of the ERC-4337 v0.7 EntryPoint interface this project uses.
/// @dev Signatures match eth-infinitism/account-abstraction v0.7.0. Kept minimal and MIT licensed so the
/// account talks to the EntryPoint over its ABI without importing GPL-3.0 sources.
interface IEntryPoint {
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );

    event UserOperationRevertReason(
        bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason
    );

    event AccountDeployed(bytes32 indexed userOpHash, address indexed sender, address factory, address paymaster);

    error FailedOp(uint256 opIndex, string reason);
    error FailedOpWithRevert(uint256 opIndex, string reason, bytes inner);

    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;

    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);

    function getNonce(address sender, uint192 key) external view returns (uint256 nonce);

    function balanceOf(address account) external view returns (uint256);

    function depositTo(address account) external payable;

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external;
}
