// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
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
     * @param minStake Minimum stake required (0 = ticket-only role, >0 = staking role)
     * @param ticketPrice Ticket price — transferred to treasury on registration (was entryBurn in v3)
     * @param slashThreshold Slash trigger threshold (ONLY for operator roles)
     * @param slashBase Base slash amount
     * @param slashIncrement Slash increment per violation
     * @param slashMax Maximum slash amount
     * @param exitFeePercent Exit fee percentage in basis points (ONLY for operator roles)
     * @param isActive Whether this role is currently active
     * @param minExitFee Minimum exit fee amount (ONLY for operator roles)
     * @param description Role description
     * @param owner Role owner address
     * @param roleLockDuration Minimum lock duration before exit (ONLY for operator roles)
     */
    struct RoleConfig {
        uint256 minStake;
        uint256 ticketPrice;

        // PACKED SLOT 1
        uint32 slashThreshold;
        uint32 slashBase;
        uint32 slashInc;
        uint32 slashMax;
        uint16 exitFeePercent;
        bool isActive;
        // 13 bytes left

        uint256 minExitFee;
        string description;
        address owner;
        uint256 roleLockDuration;
    }




    // ====================================
    // Events
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

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

    /// @notice L-04: Emitted when burnSBT fails during exitRole (failure is non-fatal)
    event SBTBurnFailed(address indexed user, bytes32 indexed roleId);


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
     * @notice Exit from a role
     * @param roleId Role to exit from
     */
    function exitRole(bytes32 roleId) external;

    /**
     * @notice Configure or create a role
     * @param roleId Role to configure
     * @param config New configuration (must include owner)
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
        uint256 proposalId,
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
     * @notice Mark a BLS proposal as executed (called by BLSAggregator for slash-only proposals)
     */
    function markProposalExecuted(uint256 proposalId) external;

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
     * @notice Get total users with a specific role
     * @param roleId Role identifier
     * @return Total count
     */
    function getRoleUserCount(bytes32 roleId) external view returns (uint256);

    function ROLE_PAYMASTER_SUPER() external view returns (bytes32);
    function ROLE_PAYMASTER_AOA() external view returns (bytes32);
    function ROLE_KMS() external view returns (bytes32);
    function ROLE_DVT() external view returns (bytes32);
    function ROLE_ANODE() external view returns (bytes32);
    function ROLE_COMMUNITY() external view returns (bytes32);
    function ROLE_ENDUSER() external view returns (bytes32);

    /**
     * @notice Push a fresh stake snapshot from Staking into Registry's
     *         per-role cache.
     * @dev    P0-14: only callable by the configured GTOKEN_STAKING. Used
     *         by `slashByDVT` / `unlockAndTransfer` / topUp paths so that
     *         Registry never drifts from Staking (INV-12).
     */
    function syncStakeFromStaking(address user, bytes32 roleId, uint256 newAmount) external;

    /**
     * @notice Effective stake read directly from Staking (source of truth).
     * @dev    P0-14: consumers that cannot tolerate any drift should use
     *         this rather than reading `roleStakes` directly.
     */
    function getEffectiveStake(address user, bytes32 roleId) external view returns (uint256);
}