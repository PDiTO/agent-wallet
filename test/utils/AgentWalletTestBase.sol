// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {AgentWallet} from "../../src/AgentWallet.sol";
import {AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {IAccountExecute} from "../../src/interfaces/IAccountExecute.sol";
import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {IEntryPoint} from "../../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockTarget} from "../mocks/MockTarget.sol";

/// @notice Shared fixture: a real EntryPoint v0.7.0, the factory, one funded account and helpers to build,
/// sign and submit user operations.
abstract contract AgentWalletTestBase is Test {
    bytes4 internal constant TRANSFER = 0xa9059cbb;
    bytes4 internal constant APPROVE = 0x095ea7b3;
    bytes4 internal constant PING = MockTarget.ping.selector;
    bytes4 internal constant EXECUTE_USER_OP = IAccountExecute.executeUserOp.selector;

    uint256 internal constant START_TIME = 1_750_000_000;
    uint256 internal constant DAY = 1 days;

    uint128 internal constant TOKEN_LIMIT = 100e18;
    uint128 internal constant ETH_LIMIT = 1 ether;
    uint128 internal constant MAX_VALUE_PER_CALL = 0.5 ether;
    uint128 internal constant GAS_BUDGET = 1 ether;
    uint32 internal constant MAX_CALLS = 50;

    // Gas fields used for every operation unless a test overrides them.
    uint128 internal constant VERIFICATION_GAS = 600_000;
    uint128 internal constant CALL_GAS = 600_000;
    uint256 internal constant PRE_VERIFICATION_GAS = 60_000;
    uint128 internal constant FEE_PER_GAS = 1 gwei;

    IEntryPoint internal entryPoint;
    AgentWalletFactory internal factory;
    AgentWallet internal account;
    MockERC20 internal token;
    MockTarget internal target;

    address internal owner;
    uint256 internal ownerKey;
    address internal guardian;
    address internal agent;
    uint256 internal agentKey;
    address internal recipient;
    address payable internal beneficiary;

    function setUp() public virtual {
        vm.warp(START_TIME);

        entryPoint = IEntryPoint(deployEntryPoint());
        factory = new AgentWalletFactory(entryPoint);
        token = new MockERC20("Test USD", "TUSD");
        target = new MockTarget();

        (owner, ownerKey) = makeAddrAndKey("owner");
        (agent, agentKey) = makeAddrAndKey("agent");
        guardian = makeAddr("guardian");
        recipient = makeAddr("recipient");
        beneficiary = payable(makeAddr("beneficiary"));

        account = factory.createAccount(owner, guardian, bytes32(0));
        vm.deal(address(account), 10 ether);
        token.mint(address(account), 1000e18);

        vm.label(address(entryPoint), "EntryPoint");
        vm.label(address(account), "AgentWallet");
        vm.label(address(token), "TUSD");
        vm.label(address(target), "MockTarget");
    }

    function deployEntryPoint() internal returns (address) {
        return deployCode("lib/account-abstraction/contracts/core/EntryPoint.sol:EntryPoint");
    }

    /*//////////////////////////////////////////////////////////////
                             SESSION SETUP
    //////////////////////////////////////////////////////////////*/

    /// @dev Default policy: TUSD transfer/approve up to 100 per day, 1 ETH per day to `recipient`, `ping` on
    /// the mock target, 0.5 ETH per call, 50 calls, 1 ETH gas budget, valid for 30 days from now.
    function defaultSession(address key) internal view returns (IAgentWallet.SessionParams memory p) {
        p.key = key;
        p.validAfter = uint48(block.timestamp);
        p.validUntil = uint48(block.timestamp + 30 days);
        p.maxCalls = MAX_CALLS;
        p.maxValuePerCall = MAX_VALUE_PER_CALL;
        p.gasBudget = GAS_BUDGET;

        p.permissions = new IAgentWallet.Permission[](3);
        p.permissions[0] = permission(address(token), TRANSFER, APPROVE);
        p.permissions[1] = permission(address(target), PING);
        p.permissions[2] = permission(recipient, bytes4(0));

        p.spendLimits = new IAgentWallet.SpendLimit[](2);
        p.spendLimits[0] = IAgentWallet.SpendLimit({token: address(token), limit: TOKEN_LIMIT, period: uint48(DAY)});
        p.spendLimits[1] = IAgentWallet.SpendLimit({token: address(0), limit: ETH_LIMIT, period: uint48(DAY)});
    }

    function permission(address to, bytes4 selector) internal pure returns (IAgentWallet.Permission memory p) {
        p.target = to;
        p.selectors = new bytes4[](1);
        p.selectors[0] = selector;
    }

    function permission(address to, bytes4 a, bytes4 b) internal pure returns (IAgentWallet.Permission memory p) {
        p.target = to;
        p.selectors = new bytes4[](2);
        p.selectors[0] = a;
        p.selectors[1] = b;
    }

    function addSession(IAgentWallet.SessionParams memory p) internal {
        vm.prank(owner);
        account.addSession(p);
    }

    function addDefaultSession() internal {
        addSession(defaultSession(agent));
    }

    /*//////////////////////////////////////////////////////////////
                                 CALLS
    //////////////////////////////////////////////////////////////*/

    function one(address to, uint256 value, bytes memory data) internal pure returns (IAgentWallet.Call[] memory c) {
        c = new IAgentWallet.Call[](1);
        c[0] = IAgentWallet.Call({target: to, value: value, data: data});
    }

    function transferCall(address to, uint256 amount) internal view returns (IAgentWallet.Call memory) {
        return IAgentWallet.Call({target: address(token), value: 0, data: abi.encodeWithSelector(TRANSFER, to, amount)});
    }

    function approveCall(address spender, uint256 amount) internal view returns (IAgentWallet.Call memory) {
        return
            IAgentWallet.Call({
                target: address(token), value: 0, data: abi.encodeWithSelector(APPROVE, spender, amount)
            });
    }

    function tokenTransfer(address to, uint256 amount) internal view returns (IAgentWallet.Call[] memory c) {
        c = new IAgentWallet.Call[](1);
        c[0] = transferCall(to, amount);
    }

    function ethTransfer(address to, uint256 amount) internal pure returns (IAgentWallet.Call[] memory) {
        return one(to, amount, "");
    }

    function sessionCallData(IAgentWallet.Call[] memory calls) internal pure returns (bytes memory) {
        return abi.encodePacked(EXECUTE_USER_OP, abi.encode(calls));
    }

    /*//////////////////////////////////////////////////////////////
                            USER OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function baseOp(address sender, uint256 nonce, bytes memory callData)
        internal
        pure
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = packGas(VERIFICATION_GAS, CALL_GAS);
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = packGas(FEE_PER_GAS, FEE_PER_GAS);
    }

    function packGas(uint128 high, uint128 low) internal pure returns (bytes32) {
        return bytes32((uint256(high) << 128) | uint256(low));
    }

    function maxCost(PackedUserOperation memory op) internal pure returns (uint256) {
        uint256 gasFees = uint256(op.gasFees);
        uint256 limits = uint256(op.accountGasLimits);
        return ((limits >> 128) + uint128(limits) + op.preVerificationGas) * uint128(gasFees);
    }

    function sessionNonce(address key) internal view returns (uint256) {
        return entryPoint.getNonce(address(account), uint192(uint160(key)));
    }

    function ownerOp(bytes memory callData) internal view returns (PackedUserOperation memory op) {
        op = baseOp(address(account), entryPoint.getNonce(address(account), 0), callData);
        signOwner(op);
    }

    function sessionOp(address key, uint256 pk, IAgentWallet.Call[] memory calls)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = baseOp(address(account), sessionNonce(key), sessionCallData(calls));
        signSession(op, key, pk);
    }

    function agentOp(IAgentWallet.Call[] memory calls) internal view returns (PackedUserOperation memory) {
        return sessionOp(agent, agentKey, calls);
    }

    function signOwner(PackedUserOperation memory op) internal view {
        op.signature = abi.encodePacked(uint8(0x00), sign(ownerKey, op));
    }

    function signSession(PackedUserOperation memory op, address key, uint256 pk) internal view {
        op.signature = abi.encodePacked(uint8(0x01), key, sign(pk, op));
    }

    function sign(uint256 pk, PackedUserOperation memory op) internal view returns (bytes memory) {
        bytes32 digest = toEthSignedMessageHash(entryPoint.getUserOpHash(op));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /*//////////////////////////////////////////////////////////////
                               SUBMISSION
    //////////////////////////////////////////////////////////////*/

    function handle(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        entryPoint.handleOps(ops, beneficiary);
    }

    function handle(PackedUserOperation memory a, PackedUserOperation memory b) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = a;
        ops[1] = b;
        entryPoint.handleOps(ops, beneficiary);
    }

    struct OpResult {
        bool found;
        bool success;
        uint256 actualGasCost;
        bytes revertReason;
    }

    /// @dev Submit one operation and pull its outcome out of the EntryPoint's events.
    function handleAndRecord(PackedUserOperation memory op) internal returns (OpResult memory r) {
        vm.recordLogs();
        handle(op);
        r = resultOf(vm.getRecordedLogs(), entryPoint.getUserOpHash(op));
    }

    function resultOf(Vm.Log[] memory logs, bytes32 userOpHash) internal view returns (OpResult memory r) {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(entryPoint) || log.topics.length < 2 || log.topics[1] != userOpHash) continue;
            if (log.topics[0] == IEntryPoint.UserOperationEvent.selector) {
                (, r.success, r.actualGasCost,) = abi.decode(log.data, (uint256, bool, uint256, uint256));
                r.found = true;
            } else if (log.topics[0] == IEntryPoint.UserOperationRevertReason.selector) {
                (, r.revertReason) = abi.decode(log.data, (uint256, bytes));
            }
        }
    }

    function expectFailedOp(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, reason));
    }

    function expectValidationRevert(bytes memory inner) internal {
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOpWithRevert.selector, 0, "AA23 reverted", inner));
    }
}
