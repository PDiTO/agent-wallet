// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {AgentWallet} from "../../src/AgentWallet.sol";
import {IAccountExecute} from "../../src/interfaces/IAccountExecute.sol";
import {IAgentWallet} from "../../src/interfaces/IAgentWallet.sol";
import {IEntryPoint} from "../../src/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../../src/interfaces/PackedUserOperation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockTarget} from "../mocks/MockTarget.sol";

/// @notice Drives the account with a random mix of owner actions, guardian pauses, time warps and session
/// key operations submitted through the real EntryPoint. Keeps its own model of what should have been
/// allowed so the invariants do not just read back the contract's own bookkeeping.
contract SessionHandler is CommonBase, StdCheats, StdUtils {
    bytes4 internal constant TRANSFER = 0xa9059cbb;
    bytes4 internal constant APPROVE = 0x095ea7b3;
    uint256 internal constant KEYS = 24;

    AgentWallet public immutable account;
    IEntryPoint public immutable entryPoint;
    MockERC20 public immutable token;
    MockTarget public immutable target;

    address internal immutable owner;
    address internal immutable guardian;
    address payable internal immutable beneficiary;

    /// @notice Addresses sessions are allowed to pay.
    address[2] public recipients = [address(0xBEEF01), address(0xBEEF02)];
    /// @notice Where the owner sweeps funds to.
    address public constant OWNER_SINK = address(0xD00D);
    /// @notice An address no session is ever allowed to pay.
    address public constant FORBIDDEN = address(0xBAD);

    uint256[KEYS] internal sessionPks;
    address[KEYS] public sessionKeys;
    /// @notice Keys are handed out in order; this many have been registered so far.
    uint256 public keysAdded;
    mapping(address key => mapping(address asset => uint48)) public periodOf;

    // ---- Ghost state ----

    struct Bucket {
        address key;
        address asset;
        uint64 window;
    }

    Bucket[] internal _buckets;
    mapping(bytes32 id => uint256) public ghostSpent;

    /// @notice Session ops that succeeded while the key should have been unusable, or that did something
    /// no policy allows. Must stay zero.
    uint256 public violations;
    uint256 public ghostTokenToRecipients;
    uint256 public ghostEthToAllowed;
    uint256 public ghostTokenToOwnerSink;
    uint256 public ghostEthToOwnerSink;

    // Counters, so a run that silently fails every op is visible.
    uint256 public sessionOpsSucceeded;
    uint256 public sessionOpsRejectedInValidation;
    uint256 public sessionOpsRevertedInExecution;

    constructor(
        AgentWallet account_,
        IEntryPoint entryPoint_,
        MockERC20 token_,
        MockTarget target_,
        address owner_,
        address guardian_,
        address payable beneficiary_
    ) {
        account = account_;
        entryPoint = entryPoint_;
        token = token_;
        target = target_;
        owner = owner_;
        guardian = guardian_;
        beneficiary = beneficiary_;
        for (uint256 i; i < KEYS; ++i) {
            sessionPks[i] = uint256(keccak256(abi.encode("session", i)));
            sessionKeys[i] = vm.addr(sessionPks[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function addSession(uint256 seed) external {
        if (keysAdded == KEYS) return;
        address key = sessionKeys[keysAdded++];

        IAgentWallet.SessionParams memory p;
        p.key = key;
        // One key in four starts an hour in the future; lifetimes run from one to three days.
        p.validAfter = uint48(block.timestamp + (_pick(seed, 0, 3) == 0 ? 1 hours : 0));
        p.validUntil = uint48(uint256(p.validAfter) + 1 days + _pick(seed, 1, 2 days));
        p.maxCalls = uint32(1 + _pick(seed, 2, 40));
        p.maxValuePerCall = uint128(_pick(seed, 3, 1 ether));
        // Enough for a handful to a few dozen ops at the default gas settings.
        p.gasBudget = uint128(_pick(seed, 4, 0.05 ether));

        uint48[3] memory periods = [uint48(0), uint48(1 hours), uint48(1 days)];
        p.spendLimits = new IAgentWallet.SpendLimit[](2);
        p.spendLimits[0] =
            IAgentWallet.SpendLimit(address(token), uint128(_pick(seed, 5, 100e18)), periods[_pick(seed, 6, 2)]);
        p.spendLimits[1] =
            IAgentWallet.SpendLimit(address(0), uint128(_pick(seed, 7, 2 ether)), periods[_pick(seed, 8, 2)]);

        p.permissions = new IAgentWallet.Permission[](4);
        p.permissions[0] = _permission(address(token), TRANSFER, APPROVE);
        p.permissions[1] = _permission(address(target), MockTarget.ping.selector, MockTarget.ping.selector);
        p.permissions[2] = _permission(recipients[0], bytes4(0), bytes4(0));
        p.permissions[3] = _permission(recipients[1], bytes4(0), bytes4(0));

        vm.prank(owner);
        account.addSession(p);
        periodOf[key][address(token)] = p.spendLimits[0].period;
        periodOf[key][address(0)] = p.spendLimits[1].period;
    }

    /// @dev Only acts one time in three so live keys are not revoked as fast as they are added.
    function revokeSession(uint256 keySeed) external {
        if (_mix(keySeed) % 3 != 0) return;
        address key = sessionKeys[_keyIndex(keySeed)];
        if (account.getSession(key).status != IAgentWallet.SessionStatus.Active) return;
        vm.prank(owner);
        account.revokeSession(key);
    }

    /// @dev Only acts one time in four so the account is not paused for most of a run.
    function pause(uint256 seed) external {
        seed = _mix(seed);
        if (seed % 4 != 0) return;
        vm.prank(seed % 8 == 0 ? guardian : owner);
        account.pauseSessions();
    }

    function unpause() external {
        vm.prank(owner);
        account.unpauseSessions();
    }

    function ownerSweep(uint256 amount, bool eth) external {
        if (eth) {
            amount = bound(amount, 0, address(account).balance / 10);
            vm.prank(owner);
            account.execute(OWNER_SINK, amount, "");
            ghostEthToOwnerSink += amount;
        } else {
            amount = bound(amount, 0, token.balanceOf(address(account)) / 10);
            vm.prank(owner);
            account.execute(address(token), 0, abi.encodeWithSelector(TRANSFER, OWNER_SINK, amount));
            ghostTokenToOwnerSink += amount;
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 6 hours));
    }

    /*//////////////////////////////////////////////////////////////
                             SESSION ACTIONS
    //////////////////////////////////////////////////////////////*/

    function sessionTransfer(uint256 keySeed, uint256 to, uint256 amount) external {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        calls[0] = _tokenCall(TRANSFER, recipients[to % 2], bound(amount, 0, 120e18));
        _submit(_keyIndex(keySeed), calls, true);
    }

    function sessionApprove(uint256 keySeed, uint256 spender, uint256 amount) external {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        calls[0] = _tokenCall(APPROVE, recipients[spender % 2], bound(amount, 0, 120e18));
        _submit(_keyIndex(keySeed), calls, true);
    }

    function sessionSendEth(uint256 keySeed, uint256 to, uint256 value, bool viaPing) external {
        value = bound(value, 0, 1.2 ether);
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        calls[0] = viaPing
            ? IAgentWallet.Call(address(target), value, abi.encodeCall(MockTarget.ping, (1)))
            : IAgentWallet.Call(recipients[to % 2], value, "");
        _submit(_keyIndex(keySeed), calls, true);
    }

    function sessionBatch(uint256 keySeed, uint256 a, uint256 b, uint256 value) external {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](3);
        calls[0] = _tokenCall(TRANSFER, recipients[0], bound(a, 0, 60e18));
        calls[1] = IAgentWallet.Call(recipients[1], bound(value, 0, 0.6 ether), "");
        calls[2] = _tokenCall(APPROVE, recipients[1], bound(b, 0, 60e18));
        _submit(_keyIndex(keySeed), calls, true);
    }

    /// @notice Attempts that no policy allows. Any success is a violation.
    function sessionForbidden(uint256 keySeed, uint256 which, uint256 amount) external {
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        which = which % 5;
        if (which == 0) {
            calls[0] = IAgentWallet.Call(
                address(token), 0, abi.encodeWithSelector(0x23b872dd, address(account), FORBIDDEN, amount)
            );
        } else if (which == 1) {
            calls[0] = _tokenCall(TRANSFER, FORBIDDEN, 0);
            calls[0].target = FORBIDDEN;
        } else if (which == 2) {
            calls[0] = IAgentWallet.Call(FORBIDDEN, bound(amount, 0, 0.1 ether), "");
        } else if (which == 3) {
            calls[0] = IAgentWallet.Call(address(target), 0, abi.encodeCall(MockTarget.other, ()));
        } else {
            calls[0] =
                IAgentWallet.Call(address(account), 0, abi.encodeCall(AgentWallet.transferOwnership, (FORBIDDEN)));
        }
        _submit(_keyIndex(keySeed), calls, false);
    }

    /// @notice A key the owner never registered.
    function strangerOp(uint256 amount) external {
        uint256 pk = uint256(keccak256("stranger"));
        IAgentWallet.Call[] memory calls = new IAgentWallet.Call[](1);
        calls[0] = _tokenCall(TRANSFER, recipients[0], bound(amount, 0, 10e18));
        if (_send(vm.addr(pk), pk, calls)) violations++;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Mostly one of the three most recently added keys, which are likely still live. One time in
    /// eight, any key in the pool, which is usually expired, revoked or never registered.
    function _keyIndex(uint256 seed) internal view returns (uint256) {
        seed = _mix(seed);
        if (keysAdded == 0 || seed % 8 == 0) return (seed >> 8) % KEYS;
        uint256 recent = keysAdded < 3 ? keysAdded : 3;
        return keysAdded - 1 - ((seed >> 8) % recent);
    }

    function _submit(uint256 idx, IAgentWallet.Call[] memory calls, bool permitted) internal {
        address key = sessionKeys[idx];
        // Judged before submission; validation and execution happen at this same timestamp.
        bool usable = _usable(key);
        bool success = _send(key, sessionPks[idx], calls);
        if (!success) return;

        if (!usable || !permitted) {
            violations++;
            return;
        }
        for (uint256 i; i < calls.length; ++i) {
            IAgentWallet.Call memory c = calls[i];
            if (c.value != 0) {
                _record(key, address(0), c.value);
                ghostEthToAllowed += c.value;
            }
            if (c.target == address(token)) {
                (bytes4 selector, uint256 amount) = _decodeTokenCall(c.data);
                _record(key, address(token), amount);
                if (selector == TRANSFER) ghostTokenToRecipients += amount;
            }
        }
    }

    function _send(address key, uint256 pk, IAgentWallet.Call[] memory calls) internal returns (bool success) {
        PackedUserOperation memory op;
        op.sender = address(account);
        op.nonce = entryPoint.getNonce(address(account), uint192(uint160(key)));
        op.callData = abi.encodePacked(IAccountExecute.executeUserOp.selector, abi.encode(calls));
        op.accountGasLimits = bytes32((uint256(600_000) << 128) | 600_000);
        op.preVerificationGas = 60_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | 1 gwei);
        bytes32 hash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)));
        op.signature = abi.encodePacked(uint8(0x01), key, r, s, v);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.recordLogs();
        try entryPoint.handleOps(ops, beneficiary) {
            success = _succeeded(vm.getRecordedLogs(), hash);
            if (success) sessionOpsSucceeded++;
            else sessionOpsRevertedInExecution++;
        } catch {
            sessionOpsRejectedInValidation++;
        }
    }

    function _succeeded(Vm.Log[] memory logs, bytes32 hash) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(entryPoint) && logs[i].topics.length > 1
                    && logs[i].topics[0] == IEntryPoint.UserOperationEvent.selector && logs[i].topics[1] == hash
            ) {
                (, bool success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                return success;
            }
        }
        return false;
    }

    function _usable(address key) internal view returns (bool) {
        IAgentWallet.Session memory s = account.getSession(key);
        return s.status == IAgentWallet.SessionStatus.Active && !account.sessionsPaused()
            && block.timestamp >= s.validAfter && block.timestamp <= s.validUntil;
    }

    function _record(address key, address asset, uint256 amount) internal {
        uint48 period = periodOf[key][asset];
        uint64 window = period == 0 ? 0 : uint64(block.timestamp / period);
        bytes32 id = keccak256(abi.encode(key, asset, window));
        if (ghostSpent[id] == 0 && amount != 0) _buckets.push(Bucket(key, asset, window));
        ghostSpent[id] += amount;
    }

    function _tokenCall(bytes4 selector, address to, uint256 amount) internal view returns (IAgentWallet.Call memory) {
        return IAgentWallet.Call(address(token), 0, abi.encodeWithSelector(selector, to, amount));
    }

    function _decodeTokenCall(bytes memory data) internal pure returns (bytes4 selector, uint256 amount) {
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
            amount := mload(add(data, 68))
        }
    }

    function _permission(address to, bytes4 a, bytes4 b) internal pure returns (IAgentWallet.Permission memory p) {
        p.target = to;
        p.selectors = new bytes4[](a == b ? 1 : 2);
        p.selectors[0] = a;
        if (a != b) p.selectors[1] = b;
    }

    /// @dev The fuzzer favours small and boundary values; hash seeds used for branching so "one time in N"
    /// really is one time in N.
    function _mix(uint256 seed) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed)));
    }

    /// @dev Uniform-ish value in [0, max] derived from one seed, so addSession needs few parameters.
    function _pick(uint256 seed, uint256 salt, uint256 max) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt))) % (max + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function bucketCount() external view returns (uint256) {
        return _buckets.length;
    }

    function bucket(uint256 i) external view returns (Bucket memory) {
        return _buckets[i];
    }

    function bucketId(uint256 i) external view returns (bytes32) {
        Bucket memory b = _buckets[i];
        return keccak256(abi.encode(b.key, b.asset, b.window));
    }

    function keyCount() external pure returns (uint256) {
        return KEYS;
    }
}
