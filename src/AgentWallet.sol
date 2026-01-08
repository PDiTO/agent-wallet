// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IAccount} from "./interfaces/IAccount.sol";
import {IAccountExecute} from "./interfaces/IAccountExecute.sol";
import {IAgentWallet} from "./interfaces/IAgentWallet.sol";
import {IEntryPoint} from "./interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "./interfaces/PackedUserOperation.sol";

/// @title AgentWallet
/// @author Paul Davis
/// @notice ERC-4337 (EntryPoint v0.7) smart account for handing an AI agent narrowly scoped, revocable
/// session keys. The owner can do anything. A session key can only make the calls its policy allows, up to
/// its spend limits, inside its validity window, and only while sessions are not paused.
///
/// @dev Deployed as EIP-1167 clones by `AgentWalletFactory`. There is no upgrade path and the account
/// never delegatecalls, so the implementation cannot be taken over or destroyed.
///
/// Signature format (`userOp.signature`):
///   owner:   0x00 || r || s || v                      (66 bytes)
///   session: 0x01 || sessionKey (20 bytes) || r || s || v   (86 bytes)
/// Both sign the EIP-191 personal-sign digest of the user operation hash.
///
/// Session operations must use the v0.7 `executeUserOp` path:
///   userOp.callData = executeUserOp.selector || abi.encode(Call[])
///   userOp.nonce    = uint256(uint160(sessionKey)) << 64 | sequence
/// The EntryPoint then hands the whole operation, including the signature, to `executeUserOp`, which is
/// how the execution phase knows which session key it is enforcing.
///
/// Where each check runs:
///   Validation (ERC-7562 rules: no TIMESTAMP opcode, storage access limited to the account's own
///   storage) runs every check that does not need the clock: signer, status, pause flag, nonce key,
///   call shape, target/selector allowlist, value cap, call count and gas budget. The validity window is
///   returned in `validationData` and the EntryPoint compares it with `block.timestamp`.
///   Execution re-runs the checks that depend on mutable state (status, pause, allowlist) because the
///   owner can change that state between validation and execution of the same bundle, then charges the
///   time-windowed spend limits, which need `block.timestamp` and so cannot run in validation.
contract AgentWallet is IAccount, IAccountExecute, IAgentWallet, IERC1271, EIP712, Initializable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Signature mode byte for the owner.
    uint8 public constant MODE_OWNER = 0x00;
    /// @notice Signature mode byte for a session key.
    uint8 public constant MODE_SESSION = 0x01;

    /// @notice Asset id used for native ETH in spend limits.
    address public constant NATIVE = address(0);

    /// @dev ERC-20 `transfer(address,uint256)`.
    bytes4 internal constant TRANSFER_SELECTOR = 0xa9059cbb;
    /// @dev ERC-20 `approve(address,uint256)`.
    bytes4 internal constant APPROVE_SELECTOR = 0x095ea7b3;
    /// @dev Length of ABI encoded `transfer` / `approve` calldata: selector + two words.
    uint256 internal constant TOKEN_CALL_LENGTH = 68;

    uint256 internal constant SIG_VALIDATION_SUCCESS = 0;
    uint256 internal constant SIG_VALIDATION_FAILED = 1;

    /// @dev EIP-712 type used to bind ERC-1271 signatures to this account and chain.
    bytes32 internal constant MESSAGE_TYPEHASH = keccak256("AgentWalletMessage(bytes32 hash)");

    /// @notice The EntryPoint this account trusts.
    IEntryPoint public immutable ENTRY_POINT;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice ECDSA owner. Full control of the account.
    address public owner;
    /// @notice When true, every session key is rejected in validation and execution. The owner is unaffected.
    bool public sessionsPaused;
    /// @notice Optional address that can pause sessions and do nothing else.
    address public guardian;

    mapping(address key => Session) internal _sessions;
    mapping(address key => mapping(address target => mapping(bytes4 selector => bool))) internal _allowed;
    mapping(address key => mapping(address token => SpendState)) internal _spend;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyEntryPoint() {
        if (msg.sender != address(ENTRY_POINT)) revert NotEntryPoint();
        _;
    }

    /// @dev The EntryPoint only calls into the account with arbitrary calldata for owner-signed operations:
    /// session operations are forced through `executeUserOp` in validation. Self-calls come from `execute*`,
    /// which are themselves owner-only, and session policies cannot target the account.
    modifier onlyOwnerOrEntryPoint() {
        if (msg.sender != owner && msg.sender != address(ENTRY_POINT) && msg.sender != address(this)) {
            revert NotAuthorized();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param entryPoint The EntryPoint v0.7 instance clones of this implementation will trust.
    constructor(IEntryPoint entryPoint) EIP712("AgentWallet", "1") {
        ENTRY_POINT = entryPoint;
        _disableInitializers();
    }

    /// @notice Set the owner and optional guardian. Called once by the factory in the deploying transaction.
    /// @param owner_ ECDSA owner, must be non-zero.
    /// @param guardian_ Address allowed to pause sessions, or zero for none.
    function initialize(address owner_, address guardian_) external initializer {
        if (owner_ == address(0)) revert InvalidOwner();
        owner = owner_;
        guardian = guardian_;
        emit AccountInitialized(address(ENTRY_POINT), owner_, guardian_);
    }

    /// @notice Accept native ETH.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               VALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccount
    /// @dev Returns SIG_VALIDATION_FAILED (never reverts) when the signature does not come from the owner or
    /// an active session key. Reverts with a specific error when a correctly signed session operation breaks
    /// its policy, which the EntryPoint surfaces as "AA23 reverted".
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds)
        external
        onlyEntryPoint
        returns (uint256 validationData)
    {
        validationData = _validateUserOp(userOp, userOpHash);
        _payPrefund(missingAccountFunds);
    }

    function _validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) internal returns (uint256) {
        bytes calldata sig = userOp.signature;
        if (sig.length == 0) return SIG_VALIDATION_FAILED;

        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        uint8 mode = uint8(sig[0]);

        if (mode == MODE_OWNER) {
            if (sig.length != 66) return SIG_VALIDATION_FAILED;
            return _recover(digest, sig[1:]) == owner ? SIG_VALIDATION_SUCCESS : SIG_VALIDATION_FAILED;
        }

        if (mode == MODE_SESSION) {
            if (sig.length != 86) return SIG_VALIDATION_FAILED;
            address key = address(bytes20(sig[1:21]));
            Session storage session = _sessions[key];
            // Unknown and revoked keys are not signers for this account.
            if (session.status != SessionStatus.Active) return SIG_VALIDATION_FAILED;

            bool sigFailed = _recover(digest, sig[21:]) != key;
            // Policy checks run even when the signature is wrong, so a bundler estimating gas with a dummy
            // signature walks the same path. Any state written here is discarded when the EntryPoint rejects
            // the failed signature.
            _validateSessionOp(key, session, userOp);
            return _packValidationData(sigFailed, session.validUntil, session.validAfter);
        }

        return SIG_VALIDATION_FAILED;
    }

    /// @dev Validation-phase policy. Reads and writes only this account's storage and does not read the
    /// clock, so it is legal under ERC-7562 for an unstaked account.
    function _validateSessionOp(address key, Session storage session, PackedUserOperation calldata userOp) internal {
        if (sessionsPaused) revert SessionsArePaused();

        // Each session gets its own EntryPoint nonce key. Its sequence number doubles as a per-session usage
        // counter, and a session's pending operations never block the owner's or another session's.
        uint256 nonceKey = userOp.nonce >> 64;
        if (nonceKey != uint256(uint160(key))) revert InvalidSessionNonceKey(key, nonceKey);

        bytes calldata callData = userOp.callData;
        bytes4 outer = callData.length >= 4 ? bytes4(callData[:4]) : bytes4(0);
        if (outer != IAccountExecute.executeUserOp.selector) revert SessionCallDataNotAllowed(outer);

        Call[] memory calls = abi.decode(callData[4:], (Call[]));
        uint256 n = calls.length;
        if (n == 0) revert EmptyBatch();

        uint256 used = uint256(session.callsUsed) + n;
        if (used > session.maxCalls) revert SessionCallLimitExceeded(key, used, session.maxCalls);
        // Counted at validation, so calls that later revert in execution still use up the allowance.
        session.callsUsed = uint32(used);

        uint128 maxValue = session.maxValuePerCall;
        for (uint256 i; i < n; ++i) {
            _checkCall(key, maxValue, calls[i]);
        }

        // With no paymaster the account pays for gas. Charge the worst case the EntryPoint can take so a
        // leaked key cannot drain the account through fees, even with operations that revert in execution.
        if (userOp.paymasterAndData.length == 0) {
            uint256 maxCost = _maxGasCost(userOp);
            uint256 spent = session.gasSpent;
            uint256 budget = session.gasBudget;
            if (maxCost > budget - spent) revert SessionGasBudgetExceeded(key, maxCost, budget - spent);
            session.gasSpent = uint128(spent + maxCost);
        }
    }

    /// @dev Checks that do not depend on time. Used in both phases. Returns the call's selector.
    function _checkCall(address key, uint128 maxValuePerCall, Call memory c) internal view returns (bytes4 selector) {
        if (c.value > maxValuePerCall) revert ValuePerCallExceeded(key, c.value, maxValuePerCall);

        selector = _selectorOf(c.target, c.data);
        if (!_allowed[key][c.target][selector]) revert CallNotAllowed(key, c.target, selector);

        if (c.value != 0 && !_spend[key][NATIVE].enabled) revert NoSpendLimit(key, NATIVE);

        // `addSession` only permits these selectors on targets that have a spend limit, so the amount
        // decoded in execution is always charged against one. Insist on the canonical encoding so there is
        // no ambiguity about which word is the amount.
        if ((selector == TRANSFER_SELECTOR || selector == APPROVE_SELECTOR) && c.data.length != TOKEN_CALL_LENGTH) {
            revert MalformedTokenCall(c.target);
        }
    }

    /// @dev Worst-case prefund the EntryPoint computes for an operation without a paymaster.
    function _maxGasCost(PackedUserOperation calldata userOp) internal pure returns (uint256) {
        uint256 verificationGasLimit = uint128(bytes16(userOp.accountGasLimits));
        uint256 callGasLimit = uint128(uint256(userOp.accountGasLimits));
        uint256 maxFeePerGas = uint128(uint256(userOp.gasFees));
        // Each term is at most 2^128, so this cannot overflow unless preVerificationGas is absurd, and then
        // checked arithmetic reverts.
        return (verificationGasLimit + callGasLimit + userOp.preVerificationGas) * maxFeePerGas;
    }

    function _payPrefund(uint256 missingAccountFunds) internal {
        if (missingAccountFunds != 0) {
            // Explicit gas avoids the GAS opcode, which ERC-7562 bans in validation. The EntryPoint verifies
            // the deposit itself, so the result is deliberately ignored.
            (bool success,) = payable(msg.sender).call{value: missingAccountFunds, gas: type(uint256).max}("");
            (success);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAccountExecute
    /// @dev Only reached for operations that passed `validateUserOp` on this account, so the signature
    /// bytes are authenticated: the mode byte and session key read here are the ones that were verified.
    function executeUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash) external onlyEntryPoint {
        Call[] memory calls = abi.decode(userOp.callData[4:], (Call[]));

        if (uint8(userOp.signature[0]) == MODE_SESSION) {
            address key = address(bytes20(userOp.signature[1:21]));
            _enforceSessionExecution(key, calls);
            emit SessionExecuted(key, userOpHash, calls.length);
        }

        for (uint256 i; i < calls.length; ++i) {
            _call(calls[i].target, calls[i].value, calls[i].data);
        }
    }

    /// @notice Make a single call. Owner or EntryPoint (owner-signed operation) only.
    function execute(address target, uint256 value, bytes calldata data) external onlyOwnerOrEntryPoint {
        _call(target, value, data);
    }

    /// @notice Make several calls atomically. Owner or EntryPoint (owner-signed operation) only.
    function executeBatch(Call[] calldata calls) external onlyOwnerOrEntryPoint {
        for (uint256 i; i < calls.length; ++i) {
            _call(calls[i].target, calls[i].value, calls[i].data);
        }
    }

    /// @dev Execution-phase policy. Status and pause are rechecked because an owner operation earlier in the
    /// same bundle may have revoked the key or paused sessions after this operation was validated.
    function _enforceSessionExecution(address key, Call[] memory calls) internal {
        Session storage session = _sessions[key];
        if (session.status != SessionStatus.Active) revert SessionNotActive(key);
        if (sessionsPaused) revert SessionsArePaused();

        uint128 maxValue = session.maxValuePerCall;
        for (uint256 i; i < calls.length; ++i) {
            Call memory c = calls[i];
            bytes4 selector = _checkCall(key, maxValue, c);
            if (c.value != 0) _chargeSpend(key, NATIVE, c.value);
            if (selector == TRANSFER_SELECTOR || selector == APPROVE_SELECTOR) {
                _chargeSpend(key, c.target, _tokenAmount(c.data));
            }
        }
    }

    /// @dev Charge `amount` of `token` against the session's limit for the current window.
    function _chargeSpend(address key, address token, uint256 amount) internal {
        SpendState storage state = _spend[key][token];
        if (!state.enabled) revert NoSpendLimit(key, token);

        uint64 window = _windowOf(state.period);
        uint256 spent = state.window == window ? state.spent : 0;
        uint256 remaining = state.limit - spent;
        if (amount > remaining) revert SpendLimitExceeded(key, token, amount, remaining);

        spent += amount;
        state.window = window;
        state.spent = uint128(spent);
        emit SessionSpent(key, token, amount, spent, window);
    }

    function _call(address target, uint256 value, bytes memory data) internal {
        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Grant a new session key. A key can only ever be registered once.
    /// @dev Rejects policies that would be unsafe or meaningless: the account and the EntryPoint cannot be
    /// targets, `transfer`/`approve` need a spend limit on that token, and a token with a spend limit can
    /// only be called through `transfer`/`approve` so there is no unmetered way to move it.
    function addSession(SessionParams calldata params) external onlyOwnerOrEntryPoint {
        address key = params.key;
        if (key == address(0) || key == owner) revert InvalidSessionKey(key);
        Session storage session = _sessions[key];
        if (session.status != SessionStatus.None) revert SessionKeyAlreadyUsed(key);
        if (params.validUntil <= params.validAfter || params.validUntil <= block.timestamp) {
            revert InvalidValidityWindow(params.validAfter, params.validUntil);
        }
        if (params.maxCalls == 0) revert InvalidMaxCalls();

        session.status = SessionStatus.Active;
        session.validAfter = params.validAfter;
        session.validUntil = params.validUntil;
        session.maxCalls = params.maxCalls;
        session.maxValuePerCall = params.maxValuePerCall;
        session.gasBudget = params.gasBudget;
        emit SessionAdded(
            key, params.validAfter, params.validUntil, params.maxCalls, params.maxValuePerCall, params.gasBudget
        );

        // Limits first so permission checks can see which targets are metered tokens.
        for (uint256 i; i < params.spendLimits.length; ++i) {
            SpendLimit calldata sl = params.spendLimits[i];
            if (sl.token == address(this) || sl.token == address(ENTRY_POINT)) revert InvalidSpendLimitToken(sl.token);
            SpendState storage state = _spend[key][sl.token];
            if (state.enabled) revert DuplicateSpendLimit(sl.token);
            state.enabled = true;
            state.limit = sl.limit;
            state.period = sl.period;
            emit SessionSpendLimitAdded(key, sl.token, sl.limit, sl.period);
        }

        for (uint256 i; i < params.permissions.length; ++i) {
            Permission calldata p = params.permissions[i];
            if (p.target == address(0) || p.target == address(this) || p.target == address(ENTRY_POINT)) {
                revert InvalidPermissionTarget(p.target);
            }
            bool metered = _spend[key][p.target].enabled;
            for (uint256 j; j < p.selectors.length; ++j) {
                bytes4 selector = p.selectors[j];
                bool tokenMove = selector == TRANSFER_SELECTOR || selector == APPROVE_SELECTOR;
                if (tokenMove && !metered) revert UnlimitedTokenPermission(p.target, selector);
                if (!tokenMove && metered) revert SelectorNotAllowedOnLimitedToken(p.target, selector);
                _allowed[key][p.target][selector] = true;
                emit SessionPermissionAdded(key, p.target, selector);
            }
        }
    }

    /// @notice Permanently revoke a session key. Takes effect for operations already validated in the
    /// current bundle as well, because execution rechecks the status.
    function revokeSession(address key) external onlyOwnerOrEntryPoint {
        Session storage session = _sessions[key];
        if (session.status != SessionStatus.Active) revert SessionNotActive(key);
        session.status = SessionStatus.Revoked;
        emit SessionRevoked(key);
    }

    /// @notice Stop every session key. Callable by the owner or the guardian.
    function pauseSessions() external {
        if (
            msg.sender != owner && msg.sender != guardian && msg.sender != address(ENTRY_POINT)
                && msg.sender != address(this)
        ) {
            revert NotOwnerOrGuardian();
        }
        sessionsPaused = true;
        emit SessionsPaused(msg.sender);
    }

    /// @notice Resume session keys. Owner only; the guardian can pause but not unpause.
    function unpauseSessions() external onlyOwnerOrEntryPoint {
        sessionsPaused = false;
        emit SessionsUnpaused(msg.sender);
    }

    /// @notice Hand the account to a new ECDSA owner. Session keys are left as they are.
    function transferOwnership(address newOwner) external onlyOwnerOrEntryPoint {
        if (newOwner == address(0) || _sessions[newOwner].status != SessionStatus.None) revert InvalidOwner();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Set or clear the guardian.
    function setGuardian(address newGuardian) external onlyOwnerOrEntryPoint {
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Add to this account's EntryPoint deposit.
    function addDeposit() external payable {
        ENTRY_POINT.depositTo{value: msg.value}(address(this));
    }

    /// @notice Withdraw from this account's EntryPoint deposit.
    function withdrawDepositTo(address payable to, uint256 amount) external onlyOwnerOrEntryPoint {
        ENTRY_POINT.withdrawTo(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                ERC-1271
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-1271 signature check. Owner signatures only.
    /// @dev Session keys are deliberately excluded. A session key that could produce ERC-1271 signatures
    /// could sign Permit2 or EIP-2612 permits and move tokens without going through the spend limits.
    /// The owner signs `replaySafeHash(hash)` rather than `hash`, which ties the signature to this account
    /// and chain so it cannot be replayed on another account with the same owner.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length == 65 && _recover(replaySafeHash(hash), signature) == owner) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }

    /// @notice The EIP-712 digest the owner signs for an ERC-1271 check of `hash`.
    function replaySafeHash(bytes32 hash) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(MESSAGE_TYPEHASH, hash)));
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stored state for a session key.
    function getSession(address key) external view returns (Session memory) {
        return _sessions[key];
    }

    /// @notice Whether `key` may call `selector` on `target`.
    function isPermitted(address key, address target, bytes4 selector) external view returns (bool) {
        return _allowed[key][target][selector];
    }

    /// @notice Spend limit state for a session key and asset.
    /// @return state The stored state.
    /// @return remaining What can still be spent in the current window.
    function getSpendLimit(address key, address token)
        external
        view
        returns (SpendState memory state, uint256 remaining)
    {
        state = _spend[key][token];
        if (state.enabled) {
            uint256 spent = state.window == _windowOf(state.period) ? state.spent : 0;
            remaining = state.limit - spent;
        }
    }

    /// @notice This account's EntryPoint deposit.
    function getDeposit() external view returns (uint256) {
        return ENTRY_POINT.balanceOf(address(this));
    }

    /// @notice Current EntryPoint nonce for a session key's nonce lane.
    function getSessionNonce(address key) external view returns (uint256) {
        return ENTRY_POINT.getNonce(address(this), uint192(uint160(key)));
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Recover a 65-byte (r, s, v) signature. Returns zero instead of reverting on malformed input.
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address signer) {
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        (signer,,) = ECDSA.tryRecover(digest, v, r, s);
    }

    /// @dev Selector of a call. Empty calldata maps to `bytes4(0)`; one to three bytes is malformed.
    function _selectorOf(address target, bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length == 0) return bytes4(0);
        if (data.length < 4) revert MalformedCallData(target);
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }

    /// @dev Amount argument of a canonically encoded `transfer(address,uint256)` or `approve(address,uint256)`.
    function _tokenAmount(bytes memory data) internal pure returns (uint256 amount) {
        assembly ("memory-safe") {
            // 0x20 length prefix + 4 selector bytes + 32 bytes for the address argument.
            amount := mload(add(data, 68))
        }
    }

    /// @dev Index of the current spend window. Period zero is a single window for the life of the key.
    function _windowOf(uint48 period) internal view returns (uint64) {
        return period == 0 ? 0 : uint64(block.timestamp / period);
    }

    /// @dev Pack validation data as the EntryPoint expects: authorizer | validUntil << 160 | validAfter << 208.
    function _packValidationData(bool sigFailed, uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return (sigFailed ? SIG_VALIDATION_FAILED : SIG_VALIDATION_SUCCESS) | (uint256(validUntil) << 160)
            | (uint256(validAfter) << 208);
    }
}
