// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IGTokenStakingV3
 * @notice GTokenStaking v3 interface with role-based locking
 * @dev Updates v2 interface to use roleId instead of locker addresses
 */
interface IGTokenStakingV3 {
    // ====================================
    // Data Structures
    // ====================================

    /**
     * @notice Stake information for a user
     * @param amount Original staked GToken amount
     * @param stGTokenShares User's stGToken shares
     * @param slashedAmount Amount slashed from this user
     * @param stakedAt Stake timestamp
     * @param unstakeRequestedAt Unstake request timestamp (0 = not requested)
     */
    struct StakeInfo {
        uint256 amount;
        uint256 stGTokenShares;
        uint256 slashedAmount;
        uint256 stakedAt;
        uint256 unstakeRequestedAt;
    }

    /**
     * @notice Lock information for a specific role
     * @param roleId Role that created this lock
     * @param amount Locked stGToken amount
     * @param entryBurn Amount burned on entry
     * @param lockedAt Lock timestamp
     * @param metadata Additional role-specific data
     */
    struct RoleLock {
        bytes32 roleId;
        uint256 amount;
        uint256 entryBurn;
        uint256 lockedAt;
        bytes metadata;
    }

    // ====================================
    // Events
    // ====================================

    event StakeLocked(
        address indexed user,
        bytes32 indexed roleId,
        uint256 amount,
        uint256 entryBurn,
        uint256 timestamp
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
     * @notice Lock stake for a specific role
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
        uint256 entryBurn
    ) external returns (uint256 lockId);

    /**
     * @notice Unlock stake for a role
     * @param user User whose stake to unlock
     * @param roleId Role to unlock from
     * @return netAmount Amount returned after exit fee
     */
    function unlockStake(
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
    // Staking Functions
    // ====================================

    /**
     * @notice Stake GToken to receive stGToken shares
     * @param amount Amount to stake
     * @return shares stGToken shares received
     */
    function stake(uint256 amount) external returns (uint256 shares);

    /**
     * @notice Stake for another user
     * @param beneficiary User to stake for
     * @param amount Amount to stake
     * @return shares stGToken shares received
     */
    function stakeFor(
        address beneficiary,
        uint256 amount
    ) external returns (uint256 shares);

    /**
     * @notice Request unstake (starts cooldown)
     * @param shares Shares to unstake
     */
    function requestUnstake(uint256 shares) external;

    /**
     * @notice Complete unstake after cooldown
     * @return amount GToken amount returned
     */
    function completeUnstake() external returns (uint256 amount);

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
     * @notice Get user's stGToken shares
     * @param user User address
     * @return Number of shares
     */
    function sharesOf(address user) external view returns (uint256);

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

    /**
     * @notice Get total shares issued
     * @return Total stGToken shares
     */
    function totalShares() external view returns (uint256);

    /**
     * @notice Convert shares to GToken amount
     * @param shares Number of shares
     * @return Amount in GToken
     */
    function convertToAssets(uint256 shares) external view returns (uint256);

    /**
     * @notice Convert GToken amount to shares
     * @param amount GToken amount
     * @return Number of shares
     */
    function convertToShares(uint256 amount) external view returns (uint256);

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

    // ====================================
    // Backward Compatibility (v2 support)
    // ====================================

    /**
     * @notice Lock stake with locker address (v2 compatibility)
     * @param user User to lock for
     * @param amount Amount to lock
     * @param purpose Lock purpose
     */
    function lockStake(
        address user,
        uint256 amount,
        string calldata purpose
    ) external;

    /**
     * @notice Get locked amount by locker (v2 compatibility)
     * @param user User address
     * @param locker Locker address
     * @return Locked amount
     */
    function getLockedStake(address user, address locker)
        external
        view
        returns (uint256);
}