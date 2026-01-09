// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "src/interfaces/IVersioned.sol";

/**
 * @title IRegistry
 * @notice Registry v3 interface with unified registerRole API
 * @dev Replaces v2's multiple registration functions with single unified entry point
 */
interface IRegistry is IVersioned {
    // ====================================
    // Data Structures
    // ====================================

    /// @notice Node type (maintained for v2 compatibility)


    /**
     * @notice Role configuration parameters
     * @param minStake Minimum stake required for this role
     * @param entryBurn Amount burned on registration
     * @param slashThreshold Slash trigger threshold (e.g., error count)
     * @param slashBase Base slash amount
     * @param slashIncrement Slash increment per violation
     * @param slashMax Maximum slash amount
     * @param exitFeePercent Exit fee percentage in basis points (100 = 1%)
     * @param minExitFee Minimum exit fee amount
     * @param isActive Whether this role is currently active
     * @param description Role description
     */
    struct RoleConfig {
        uint256 minStake;
        uint256 entryBurn;
        uint256 slashThreshold;
        uint256 slashBase;
        uint256 slashIncrement;
        uint256 slashMax;
        uint256 exitFeePercent;
        uint256 minExitFee;
        bool isActive;
        string description;
    }




    // ====================================
    // Events
    // ====================================

    event RoleRegistered(
        bytes32 indexed roleId,
        address indexed user,
        uint256 burnAmount,
        uint256 timestamp
    );

    event RoleExited(
        bytes32 indexed roleId,
        address indexed user,
        uint256 exitFee,
        uint256 timestamp
    );

    event RoleConfigured(
        bytes32 indexed roleId,
        RoleConfig config,
        uint256 timestamp
    );

    event BurnExecuted(
        address indexed user,
        bytes32 indexed roleId,
        uint256 amount,
        string reason
    );

    event RoleLockDurationUpdated(
        bytes32 indexed roleId, 
        uint256 duration
    );

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register a user for a specific role (unified API)
     * @param roleId Role identifier (e.g., ROLE_COMMUNITY, ROLE_PAYMASTER)
     * @param user User address to register
     * @param roleData Encoded role-specific data
     */
    function registerRole(
        bytes32 roleId,
        address user,
        bytes calldata roleData
    ) external;

    /**
     * @notice Register self for a role (convenience wrapper)
     * @param roleId Role identifier
     * @param roleData Encoded role-specific data
     * @return sbtTokenId Token ID if SBT was minted
     */
    function registerRoleSelf(
        bytes32 roleId,
        bytes calldata roleData
    ) external returns (uint256 sbtTokenId);

    /**
     * @notice Exit from a role
     * @param roleId Role to exit from
     */
    function exitRole(bytes32 roleId) external;

    /**
     * @notice Configure role parameters (DAO only)
     * @param roleId Role to configure
     * @param config New configuration
     */
    function configureRole(bytes32 roleId, RoleConfig calldata config) external;
    
    /**
     * @notice Admin-only role configuration with full parameter control
     */
    function adminConfigureRole(
        bytes32 roleId,
        uint256 minStake,
        uint256 entryBurn,
        uint256 exitFeePercent,
        uint256 minExitFee
    ) external;
    
    /**
     * @notice Create a new role (Owner only)
     * @param roleId Unique role identifier
     * @param config Role configuration
     * @param roleOwner Address that will own this role
     */
    function createNewRole(bytes32 roleId, RoleConfig calldata config, address roleOwner) external;

    /**
     * @notice Transfer role ownership (Admin only)
     * @param roleId Role to transfer
     * @param newOwner New owner address
     */
    function setRoleOwner(bytes32 roleId, address newOwner) external;

    /**
     * @notice Set lock duration for a role
     * @param roleId Role identifier
     * @param duration Lock duration in seconds
     */
    function setRoleLockDuration(bytes32 roleId, uint256 duration) external;

    /**
     * @notice Mint SBT for multiple users in a role (admin function)
     * @param roleId Role for minting
     * @param user User to mint for
     * @param roleData Role-specific data
     * @return tokenId Minted token ID
     */
    function safeMintForRole(
        bytes32 roleId,
        address user,
        bytes calldata roleData
    ) external returns (uint256 tokenId);

    // ====================================
    // V3.1: Reputation & Credit Management
    // ====================================

    /**
     * @notice Batch update global reputation
     * @param users Users to update
     * @param newScores New scores
     * @param epoch Update epoch
     * @param proof DVT signature proof
     */
    function batchUpdateGlobalReputation(
        address[] calldata users,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes calldata proof
    ) external;

    /**
     * @notice Update operator blacklist (via DVT consensus)
     * @dev Forwards the update to SuperPaymaster
     * @param operator The operator/community address
     * @param users List of users to update
     * @param statuses Blocked status (true = blocked)
     * @param proof DVT signature proof
     */
    function updateOperatorBlacklist(
        address operator,
        address[] calldata users,
        bool[] calldata statuses,
        bytes calldata proof
    ) external;

    /**
     * @notice Authorize or revoke a reputation source
     */
    function setReputationSource(address source, bool isActive) external;

    /**
     * @notice Configure credit limit for a level
     */
    function setCreditTier(uint256 level, uint256 limit) external;

    /**
     * @notice Get credit limit for user based on reputation
     * @param user User address
     * @return Credit limit in aPNTs (18 decimals)
     */
    function getCreditLimit(address user) external view returns (uint256);
    
    // ====================================
    // View Functions
    // ====================================

    function isReputationSource(address source) external view returns (bool);

    /**
     * @notice Check if user has a specific role
     * @param roleId Role to check
     * @param user User address
     * @return True if user has the role
     */
    function hasRole(bytes32 roleId, address user) external view returns (bool);

    /**
     * @notice Get role configuration
     * @param roleId Role identifier
     * @return Role configuration
     */
    function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory);

    /**
     * @notice Get all roles for a user
     * @param user User address
     * @return Array of role IDs
     */
    function getUserRoles(address user) external view returns (bytes32[] memory);

    /**
     * @notice Calculate exit fee for a role
        external
        view
        returns (uint256 exitFee);



    /**
     * @notice Calculate exit fee for a role
     * @param roleId Role identifier
     * @param lockedAmount Amount locked
     * @return exitFee Calculated exit fee
     */
    function calculateExitFee(bytes32 roleId, uint256 lockedAmount)
        external
        view
        returns (uint256 exitFee);

    /**
     * @notice Get total users with a specific role
     * @param roleId Role identifier
     * @return Total count
     */
    function getRoleUserCount(bytes32 roleId) external view returns (uint256);

    /**
     * @notice Get role owner
     * @param roleId Role identifier
     * @return Owner address
     */
    function roleOwners(bytes32 roleId) external view returns (address);
    
    function ROLE_PAYMASTER_SUPER() external view returns (bytes32);
    function ROLE_PAYMASTER_AOA() external view returns (bytes32);
    function ROLE_KMS() external view returns (bytes32);
    function ROLE_DVT() external view returns (bytes32);
    function ROLE_ANODE() external view returns (bytes32);
    function ROLE_COMMUNITY() external view returns (bytes32);
    function ROLE_ENDUSER() external view returns (bytes32);


}