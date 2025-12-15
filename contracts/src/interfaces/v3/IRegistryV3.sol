// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IRegistryV3
 * @notice Registry v3 interface with unified registerRole API
 * @dev Replaces v2's multiple registration functions with single unified entry point
 */
interface IRegistryV3 {
    // ====================================
    // Data Structures
    // ====================================

    /// @notice Node type (maintained for v2 compatibility)


    /**
     * @notice Role configuration parameters
     * @param minStake Minimum stake required for this role
     * @param entryBurn Amount burned on registration
     * @param exitFeePercent Exit fee percentage (basis points)
     * @param minExitFee Minimum exit fee amount
     * @param allowPermissionlessMint Allow users to mint without invitation
     * @param isActive Whether this role is currently active
     */
    struct RoleConfig {
        uint256 minStake;
        uint256 entryBurn;
        uint256 slashThreshold;
        uint256 slashBase;
        uint256 slashIncrement;
        uint256 slashMax;
        bool isActive;
        string description;
    }

    /**
     * @notice Burn record for tracking token burns
     * @param roleId Role associated with this burn
     * @param user User who performed the burn
     * @param amount Amount burned
     * @param timestamp When the burn occurred
     * @param reason Description of burn reason
     */
    struct BurnRecord {
        bytes32 roleId;
        address user;
        uint256 amount;
        uint256 timestamp;
        string reason;
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
    // View Functions
    // ====================================

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
     * @notice Get burn history for a user
     * @param user User address
     * @return Array of burn records
     */
    function getBurnHistory(address user) external view returns (BurnRecord[] memory);

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

}