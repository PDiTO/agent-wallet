// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAgentWallet
/// @notice Types, events and errors for the AgentWallet ERC-4337 account.
interface IAgentWallet {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice A single call made by the account.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Function selectors a session key may call on one target.
    /// @dev `bytes4(0)` permits calls with empty calldata, which is how a plain ETH transfer is expressed.
    struct Permission {
        address target;
        bytes4[] selectors;
    }

    /// @notice Spend limit for one asset.
    /// @param token ERC-20 address, or `address(0)` for native ETH.
    /// @param limit Maximum amount spent per period.
    /// @param period Window length in seconds. Windows are aligned to `block.timestamp / period`.
    /// Zero means one window for the whole life of the session.
    struct SpendLimit {
        address token;
        uint128 limit;
        uint48 period;
    }

    /// @notice Everything the owner specifies when granting a session key.
    /// @param key Address of the session signer.
    /// @param validAfter First timestamp the key can be used at (inclusive).
    /// @param validUntil Last timestamp the key can be used at (inclusive). Must be set.
    /// @param maxCalls Total number of calls the key may make over its life. Each call in a batch counts.
    /// @param maxValuePerCall Maximum native value attached to any single call.
    /// @param gasBudget Total worst-case gas cost, in wei, the account will prefund for this key.
    /// @param permissions Allowed (target, selector) pairs.
    /// @param spendLimits Per-asset limits. Native ETH can only be spent if there is a limit for `address(0)`.
    struct SessionParams {
        address key;
        uint48 validAfter;
        uint48 validUntil;
        uint32 maxCalls;
        uint128 maxValuePerCall;
        uint128 gasBudget;
        Permission[] permissions;
        SpendLimit[] spendLimits;
    }

    /// @notice Lifecycle of a session key. A key goes None -> Active -> Revoked and never back.
    enum SessionStatus {
        None,
        Active,
        Revoked
    }

    /// @notice Stored session state.
    struct Session {
        SessionStatus status;
        uint48 validAfter;
        uint48 validUntil;
        uint32 maxCalls;
        uint32 callsUsed;
        uint128 maxValuePerCall;
        uint128 gasBudget;
        uint128 gasSpent;
    }

    /// @notice Stored spend limit state for one (session, asset) pair.
    /// @param limit Maximum spend per window.
    /// @param period Window length in seconds, zero for a single lifetime window.
    /// @param window Index of the window `spent` belongs to.
    /// @param enabled True if the owner configured a limit for this asset.
    /// @param spent Amount spent in `window`.
    struct SpendState {
        uint128 limit;
        uint48 period;
        uint64 window;
        bool enabled;
        uint128 spent;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AccountInitialized(address indexed entryPoint, address indexed owner, address indexed guardian);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event SessionsPaused(address indexed by);
    event SessionsUnpaused(address indexed by);

    event SessionAdded(
        address indexed key,
        uint48 validAfter,
        uint48 validUntil,
        uint32 maxCalls,
        uint128 maxValuePerCall,
        uint128 gasBudget
    );
    event SessionPermissionAdded(address indexed key, address indexed target, bytes4 selector);
    event SessionSpendLimitAdded(address indexed key, address indexed token, uint128 limit, uint48 period);
    event SessionRevoked(address indexed key);

    /// @notice Emitted when a session key's operation executes.
    event SessionExecuted(address indexed key, bytes32 indexed userOpHash, uint256 calls);
    /// @notice Emitted for every amount charged against a spend limit.
    event SessionSpent(
        address indexed key, address indexed token, uint256 amount, uint256 spentInWindow, uint64 window
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    // Access control
    error NotEntryPoint();
    error NotAuthorized();
    error NotOwnerOrGuardian();

    // Configuration
    error InvalidOwner();
    error InvalidSessionKey(address key);
    error SessionKeyAlreadyUsed(address key);
    error InvalidValidityWindow(uint48 validAfter, uint48 validUntil);
    error InvalidMaxCalls();
    error InvalidPermissionTarget(address target);
    error UnlimitedTokenPermission(address target, bytes4 selector);
    error SelectorNotAllowedOnLimitedToken(address target, bytes4 selector);
    error InvalidSpendLimitToken(address token);
    error DuplicateSpendLimit(address token);

    // Session enforcement
    error SessionNotActive(address key);
    error SessionsArePaused();
    error InvalidSessionNonceKey(address key, uint256 nonceKey);
    error SessionCallDataNotAllowed(bytes4 selector);
    error EmptyBatch();
    error SessionCallLimitExceeded(address key, uint256 requested, uint256 maxCalls);
    error SessionGasBudgetExceeded(address key, uint256 required, uint256 remaining);
    error CallNotAllowed(address key, address target, bytes4 selector);
    error ValuePerCallExceeded(address key, uint256 value, uint256 maxValuePerCall);
    error MalformedCallData(address target);
    error MalformedTokenCall(address target);
    error NoSpendLimit(address key, address token);
    error SpendLimitExceeded(address key, address token, uint256 amount, uint256 remaining);
}
