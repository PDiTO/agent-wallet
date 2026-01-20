// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AgentWallet} from "../../src/AgentWallet.sol";
import {AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {AgentWalletTestBase} from "../utils/AgentWalletTestBase.sol";

/// @notice Gas for common flows, written to snapshots/Gas.json. Each measurement is the gas of the
/// outer call (usually `handleOps`) with storage cooled first so it resembles a fresh transaction. It does
/// not include the 21,000 base cost or calldata; the anvil demo prints full receipts for that.
contract Gas is AgentWalletTestBase {
    function setUp() public override {
        super.setUp();
        // Give recipients a balance so transfers are not paying for a zero-to-nonzero write.
        token.mint(recipient, 1);
        vm.deal(recipient, 1);
    }

    function cool() internal {
        vm.cool(address(account));
        vm.cool(address(factory.ACCOUNT_IMPLEMENTATION()));
        vm.cool(address(entryPoint));
        vm.cool(address(token));
        vm.cool(recipient);
        vm.cool(beneficiary);
    }

    function measure(string memory name, PackedUserOperation memory op) internal {
        cool();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.startSnapshotGas("handleOps", name);
        entryPoint.handleOps(ops, beneficiary);
        vm.stopSnapshotGas();
    }

    function test_gas_eoaTokenTransferBaseline() public {
        address eoa = makeAddr("eoa");
        token.mint(eoa, 10e18);
        cool();
        vm.prank(eoa);
        vm.startSnapshotGas("baseline", "eoaTokenTransfer");
        token.transfer(recipient, 1e18);
        vm.stopSnapshotGas();
    }

    function test_gas_deployAndFirstOwnerOp() public {
        (address newOwner, uint256 newOwnerKey) = makeAddrAndKey("newOwner");
        address predicted = factory.getAddress(newOwner, guardian, bytes32(0));
        vm.deal(predicted, 1 ether);
        PackedUserOperation memory op =
            baseOp(predicted, 0, abi.encodeCall(AgentWallet.execute, (recipient, 0.01 ether, "")));
        op.initCode = abi.encodePacked(
            address(factory), abi.encodeCall(AgentWalletFactory.createAccount, (newOwner, guardian, bytes32(0)))
        );
        op.signature = abi.encodePacked(uint8(0x00), sign(newOwnerKey, op));
        vm.cool(address(factory));
        measure("deployAndOwnerEthTransfer", op);
    }

    /// @dev One owner op first so the nonce, deposit and beneficiary slots are already non-zero, as they
    /// would be for any account past its first operation.
    function warmOwner() internal {
        handle(ownerOp(abi.encodeCall(AgentWallet.execute, (recipient, 1, ""))));
    }

    /// @dev Same idea for a session key: its nonce lane, counters and spend windows already hold values.
    function warmSession() internal {
        addDefaultSession();
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](2);
        calls[0] = transferCall(recipient, 1);
        calls[1] = IAgentWallet.Call(recipient, 1, "");
        handle(agentOp(calls));
    }

    function test_gas_ownerTokenTransfer() public {
        warmOwner();
        measure(
            "ownerTokenTransfer",
            ownerOp(
                abi.encodeCall(
                    AgentWallet.execute, (address(token), 0, abi.encodeWithSelector(TRANSFER, recipient, 1e18))
                )
            )
        );
    }

    function test_gas_ownerEthTransfer() public {
        warmOwner();
        measure("ownerEthTransfer", ownerOp(abi.encodeCall(AgentWallet.execute, (recipient, 0.01 ether, ""))));
    }

    function test_gas_sessionTokenTransferFirstOp() public {
        addDefaultSession();
        measure("sessionTokenTransferFirstOp", agentOp(tokenTransfer(recipient, 1e18)));
    }

    function test_gas_sessionTokenTransfer() public {
        warmSession();
        measure("sessionTokenTransfer", agentOp(tokenTransfer(recipient, 1e18)));
    }

    function test_gas_sessionTokenTransferNewWindow() public {
        warmSession();
        vm.warp(block.timestamp + DAY);
        measure("sessionTokenTransferNewWindow", agentOp(tokenTransfer(recipient, 1e18)));
    }

    function test_gas_sessionEthTransfer() public {
        warmSession();
        measure("sessionEthTransfer", agentOp(ethTransfer(recipient, 0.01 ether)));
    }

    function test_gas_sessionBatchOfThree() public {
        warmSession();
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](3);
        calls[0] = transferCall(recipient, 1e18);
        calls[1] = transferCall(recipient, 1e18);
        calls[2] = transferCall(recipient, 1e18);
        measure("sessionBatchOfThreeTransfers", agentOp(calls));
    }

    function test_gas_addSession() public {
        IAgentWallet.SessionParams memory p = defaultSession(agent);
        cool();
        vm.prank(owner);
        vm.startSnapshotGas("admin", "addSessionDefaultPolicy");
        account.addSession(p);
        vm.stopSnapshotGas();
    }

    function test_gas_revokeSession() public {
        addDefaultSession();
        cool();
        vm.prank(owner);
        vm.startSnapshotGas("admin", "revokeSession");
        account.revokeSession(agent);
        vm.stopSnapshotGas();
    }

    function test_gas_pauseSessions() public {
        cool();
        vm.prank(guardian);
        vm.startSnapshotGas("admin", "pauseSessions");
        account.pauseSessions();
        vm.stopSnapshotGas();
    }

    function test_gas_createAccount() public {
        vm.cool(address(factory));
        vm.startSnapshotGas("factory", "createAccount");
        factory.createAccount(agent, guardian, bytes32(uint256(99)));
        vm.stopSnapshotGas();
    }
}
