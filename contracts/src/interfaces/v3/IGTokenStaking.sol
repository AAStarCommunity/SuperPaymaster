// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "src/interfaces/IVersioned.sol";

/**
 * @title IGTokenStaking
 * @notice GTokenStaking v4 interface — Ticket Model
 * @dev v4: Replace Stake+Burn with Ticket Model (burn to treasury, not destroy)
 *      Regular users: burnTicket (transfer to treasury, no stake)
 *      Operators: lockStakeWithTicket (ticket to treasury + stake locked)
 */
interface IGTokenStaking is IVersioned {
    // ====================================
    // Data Structures
    // ====================================

    /**
     * @notice Stake information for a user
     * @param amount Original staked GToken amount
     * @param slashedAmount Amount slashed from this user
     * @param stakedAt Stake timestamp
     * @param unstakeRequestedAt Unstake request timestamp (0 = not requested)
     */
    struct StakeInfo {
        uint256 amount;
        uint256 slashedAmount;
        uint256 stakedAt;
        uint256 unstakeRequestedAt;
    }

    /**
     * @notice Lock information for a specific role
     * @param roleId Role that created this lock
     * @param amount Locked stGToken amount
     * @param ticketPrice Ticket price paid to treasury on entry (was entryBurn in v3)
     * @param lockedAt Lock timestamp
     * @param metadata Additional role-specific data
     */
    struct RoleLock {
        // Slot 1: Packed
        uint128 amount;
        uint128 ticketPrice;
        // Slot 2: Packed
        uint48 lockedAt;
        // 25 bytes left
        bytes32 roleId; // Redundant if used as mapping key? But useful for views. Kept.
        bytes metadata; // Dynamic (Slot 3)
    }

    // ====================================
    // Events
    // ====================================

    event StakeLocked(
        address indexed user,
        bytes32 indexed roleId,
        uint256 amount,
        uint256 ticketPrice,
        uint256 timestamp
    );

    event TicketBurned(
        address indexed user,
        bytes32 indexed roleId,
        uint256 ticketPrice,
        address indexed payer
    );

    event StakeUnlocked(
        address indexed user,
        bytes32 indexed roleId,
        uint256 grossAmount,
        uint256 exitFee,
        uint256 netAmount,
        uint256 timestamp
    );

    event TokensBurned(
        address indexed user,
        bytes32 indexed roleId,
        uint256 amount,
        string purpose
    );

    event UserSlashed(
        address indexed user,
        uint256 amount,
        string reason,
        uint256 timestamp
    );

    // ====================================
    // Core Functions - Role-based Locking
    // ====================================

    /**
     * @notice Lock stake for a specific role (Registry only)
     * @dev DEPRECATED — kept for backward compatibility. New registrations should use
     *      burnTicket() for regular users or lockStakeWithTicket() for operators.
     * @param user User whose stake to lock
     * @param roleId Role identifier
     * @param stakeAmount Amount to stake (if new stake)
     * @param entryBurn Amount to burn on entry
     * @return lockId Unique lock identifier
     */
    function lockStake(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 entryBurn,
        address payer
    ) external returns (uint256 lockId);

    /**
     * @notice Burn ticket for a regular user role (Registry only)
     * @dev Transfers ticketPrice from payer to treasury. No stake, no lock.
     *      For ENDUSER and COMMUNITY roles — lifetime membership, no exit.
     * @param user User registering for the role
     * @param roleId Role identifier
     * @param ticketPrice Amount to transfer to treasury
     * @param payer Address providing the tokens
     */
    function burnTicket(
        address user,
        bytes32 roleId,
        uint256 ticketPrice,
        address payer
    ) external;

    /**
     * @notice Lock stake with ticket for an operator role (Registry only)
     * @dev Transfers (stakeAmount + ticketPrice) from payer.
     *      ticketPrice goes to treasury, stakeAmount stays locked in contract.
     *      For DVT, KMS, PAYMASTER_*, ANODE roles.
     * @param user User registering for the role
     * @param roleId Role identifier
     * @param stakeAmount Amount to lock as security deposit
     * @param ticketPrice Amount to transfer to treasury
     * @param payer Address providing the tokens
     * @return lockId Unique lock identifier
     */
    function lockStakeWithTicket(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 ticketPrice,
        address payer
    ) external returns (uint256 lockId);

    /**
     * @notice Top up stake for an existing role (Registry only)
     * @param user User address
     * @param roleId Role identifier
     * @param stakeAmount Amount to add
     * @param payer Address providing the tokens
     */
    function topUpStake(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        address payer
    ) external;

    /**
     * @notice Unlock stake for a role and transfer to user (Registry only)
     * @dev SECURITY: Automatically transfers unlocked tokens to prevent re-lock attacks
     *      MUST be called only by authorized Registry contract
     *      Implementation should have onlyRegistry modifier
     *
     * Why auto-transfer?
     *   - If we just unlock without transfer, user could call lockStake() again
     *   - This would bypass the exitRole() flow and keep role active with no stake
     *   - Auto-transfer ensures user gets tokens immediately, can't re-lock
     *
     * @param user User whose stake to unlock
     * @param roleId Role to unlock from
     * @return netAmount Amount transferred to user after exit fee
     */
    function unlockAndTransfer(
        address user,
        bytes32 roleId
    ) external returns (uint256 netAmount);

    /**
     * @notice Slash a user's stake
     * @param user User to slash
     * @param amount Amount to slash
     * @param reason Slash reason
     * @return slashedAmount Actual amount slashed
     */
    function slash(
        address user,
        uint256 amount,
        string calldata reason
    ) external returns (uint256 slashedAmount);

    // ====================================
    // REMOVED: User-callable staking functions
    // ====================================
    // REMOVED: function stake(uint256 amount) external returns (uint256 shares);
    // REMOVED: function stakeFor(address beneficiary, uint256 amount) external returns (uint256 shares);
    //
    // Reason: All staking must go through Registry.registerRole()
    //         This ensures stake is always locked for a specific role
    //         Prevents users from staking without commitment
    //
    // Internal staking is handled by Registry via lockStake()

    // ====================================
    // SECURITY FIX: Removed user-callable unstake functions
    // ====================================
    // REMOVED: function requestUnstake(uint256 shares) external;
    // REMOVED: function completeUnstake() external returns (uint256);
    //
    // Reason: Security vulnerability - users could unstake while keeping active roles,
    //         enabling zero-stake attacks and Sybil attacks
    //
    // New behavior: Unstake is automatically handled by Registry.exitRole()
    //               via unlockAndTransfer() function below

    // ====================================
    // View Functions - Role Queries
    // ====================================

    /**
     * @notice Get locked stake amount for a role
     * @param user User address
     * @param roleId Role identifier
     * @return Locked amount for this role
     */
    function getLockedStake(
        address user,
        bytes32 roleId
    ) external view returns (uint256);

    /**
     * @notice Get all role locks for a user
     * @param user User address
     * @return Array of role locks
     */
    function getUserRoleLocks(address user)
        external
        view
        returns (RoleLock[] memory);

    /**
     * @notice Check if user has lock for a role
     * @param user User address
     * @param roleId Role identifier
     * @return True if user has lock for this role
     */
    function hasRoleLock(address user, bytes32 roleId)
        external
        view
        returns (bool);

    /**
     * @notice Get role lock details
     * @param user User address
     * @param roleId Role identifier
     * @return amount Locked stGToken amount
     * @return ticketPrice Ticket price paid to treasury on entry
     * @return lockedAt Lock timestamp
     * @return roleId_ The role ID
     * @return metadata Additional role-specific data
     */
    function roleLocks(address user, bytes32 roleId)
        external
        view
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata);

    // ====================================
    // View Functions - Balances
    // ====================================

    /**
     * @notice Get user's total staked balance
     * @param user User address
     * @return Total staked GToken value
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Get available (unlocked) balance
     * @param user User address
     * @return Available balance for unstaking
     */
    function availableBalance(address user) external view returns (uint256);

    /**
     * @notice Preview exit fee for a role
     * @param user User address
     * @param roleId Role to exit
     * @return fee Exit fee amount
     * @return netAmount Amount after fee
     */
    function previewExitFee(address user, bytes32 roleId)
        external
        view
        returns (uint256 fee, uint256 netAmount);

    // ====================================
    // View Functions - Protocol State
    // ====================================

    /**
     * @notice Get total staked in protocol
     * @return Total GToken staked
     */
    function totalStaked() external view returns (uint256);


    // ====================================
    // Configuration Functions
    // ====================================

    /**
     * @notice Set exit fee configuration for a role
     * @param roleId Role identifier
     * @param feePercent Fee percentage (basis points)
     * @param minFee Minimum fee amount
     */
    function setRoleExitFee(
        bytes32 roleId,
        uint256 feePercent,
        uint256 minFee
    ) external;

    /**
     * @notice Set authorized slasher
     * @param slasher Address to authorize
     * @param authorized Authorization status
     */
    function setAuthorizedSlasher(address slasher, bool authorized) external;
}