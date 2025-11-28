// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/Interfaces.sol";
import "../../v3/interfaces/IGTokenStakingV3.sol";
import "../../v3/interfaces/IMySBTV3.sol";

/**
 * @title Registry v3.0.0 - Unified Role Management System
 * @notice Community metadata storage with unified role-based registration
 * @dev Key improvements over v2.2.1:
 *      - Unified role management: registerRole(), exitRole(), safeMintForRole()
 *      - Dynamic RoleConfig mapping instead of hardcoded NodeType enum
 *      - Complete burn history tracking with BurnRecord struct
 *      - Backward compatible: existing v2 functions (registerCommunity, etc.) maintained
 *      - Enhanced security: CEI pattern, nonReentrant guards, comprehensive validation
 *
 * Architecture:
 * - RoleConfig: Define stake requirements and slash parameters for any role
 * - CommunityProfile: Metadata for each registered community
 * - CommunityStake: Staking and slash tracking per community
 * - BurnRecord: Historical tracking of all role exits and burns
 */
contract Registry_v3_0_0 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================================
    // Type Definitions
    // ====================================

    /// @notice Node type (maintained for v2 compatibility)
    enum NodeType {
        PAYMASTER_AOA,      // 0: AOA independent Paymaster
        PAYMASTER_SUPER,    // 1: SuperPaymaster v2 shared mode
        ANODE,              // 2: Community computation node
        KMS                 // 3: Key Management Service node
    }

    /// @notice Role configuration (v3.0.0 - dynamic role system)
    struct RoleConfig {
        uint256 minStake;           // Minimum stake required
        uint256 entryBurn;          // Entry burn amount (v3.0.0)
        uint256 slashThreshold;     // Failure count before slashing
        uint256 slashBase;          // Base slash percentage
        uint256 slashIncrement;     // Slash increment per excess failure
        uint256 slashMax;           // Maximum slash percentage
        bool isActive;              // Whether this role is active
        string description;         // Role description
    }

    /// @notice V3: Community role metadata (纯v3,移除supportedSBTs)
    struct CommunityRoleData {
        string name;              // Required
        string ensName;           // Optional
        string website;           // Optional
        string description;       // Optional
        string logoURI;           // Optional (IPFS)
        uint256 stakeAmount;      // Optional (0 = use minStake)
    }

    /// @notice V3: End user role metadata
    struct EndUserRoleData {
        address account;          // Required (用户的AA account地址)
        address community;        // Required (加入的社区)
        string avatarURI;         // Optional (IPFS)
        string ensName;           // Optional
        uint256 stakeAmount;      // Optional (0 = use minStake)
    }

    /// @notice V3: Paymaster role metadata
    struct PaymasterRoleData {
        address paymasterContract;  // Required
        string name;                // Required
        string apiEndpoint;         // Optional
        uint256 stakeAmount;        // Optional (0 = use minStake)
    }

    /// @notice Community profile (optimized)
    struct CommunityProfile {
        string name;
        string ensName;
        address xPNTsToken;
        address[] supportedSBTs;
        NodeType nodeType;
        address paymasterAddress;
        address community;
        uint256 registeredAt;
        uint256 lastUpdatedAt;
        bool isActive;
        bool allowPermissionlessMint;
    }

    /// @notice Community staking
    struct CommunityStake {
        uint256 stGTokenLocked;
        uint256 failureCount;
        uint256 lastFailureTime;
        uint256 totalSlashed;
        bool isActive;
    }

    /// @notice Burn record for history tracking (v3.0.0)
    struct BurnRecord {
        bytes32 roleId;             // Role identifier
        address user;               // User who burned
        uint256 amount;             // Amount burned
        uint256 timestamp;          // When burned
        string reason;              // Reason for burn
    }

    // ====================================
    // Constants
    // ====================================

    uint256 public constant MAX_SUPPORTED_SBTS = 10;
    uint256 public constant MAX_NAME_LENGTH = 100;
    string public constant VERSION = "3.0.0";
    uint256 public constant VERSION_CODE = 30000;

    // ====================================
    // Storage
    // ====================================

    // Core contract dependencies
    IERC20 public immutable GTOKEN;
    IGTokenStakingV3 public immutable GTOKEN_STAKING;  // V3: Using roleId-based interface
    IMySBTV3 public immutable MYSBT;  // V3: MySBT contract for role SBT minting
    address public oracle;
    address public superPaymasterV2;

    // v2 legacy storage (maintained for backward compatibility)
    mapping(NodeType => RoleConfig) public nodeTypeConfigs;
    mapping(address => CommunityProfile) public communities;
    mapping(address => CommunityStake) public communityStakes;
    mapping(string => address) public communityByName;
    mapping(string => address) public communityByENS;
    mapping(address => address) public communityBySBT;
    address[] public communityList;
    mapping(address => bool) public isRegistered;

    // v3.0.0 - Unified role management
    mapping(bytes32 => RoleConfig) public roleConfigs;
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    mapping(bytes32 => mapping(address => uint256)) public roleStakes;
    mapping(bytes32 => address[]) public roleMembers;
    mapping(bytes32 => mapping(address => uint256)) public roleSBTTokenIds;  // V3: role => user => sbtTokenId
    mapping(bytes32 => mapping(address => bytes)) public roleMetadata;       // V3: role => user => metadata bytes

    // V3: Index mappings (替代legacy mappings)
    mapping(string => address) public communityByNameV3;    // name -> community address
    mapping(string => address) public communityByENSV3;     // ENS -> community address
    mapping(address => address) public accountToUser;       // AA account -> user EOA

    // v3.0.0 - Burn history tracking
    BurnRecord[] public burnHistory;
    mapping(address => uint256[]) public userBurnHistory; // user => burnHistory indices

    // ====================================
    // Events
    // ====================================

    // v2 legacy events (maintained for backward compatibility)
    event CommunityRegistered(address indexed community, string name, NodeType indexed nodeType, uint256 staked);
    event CommunityUpdated(address indexed community, string name);
    event CommunityDeactivated(address indexed community);
    event CommunityReactivated(address indexed community);
    event CommunityOwnershipTransferred(address indexed oldOwner, address indexed newOwner, uint256 timestamp);
    event FailureReported(address indexed community, uint256 failureCount);
    event CommunitySlashed(address indexed community, uint256 amount, uint256 newStake);
    event FailureCountReset(address indexed community);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event SuperPaymasterV2Updated(address indexed newSuperPaymasterV2);
    event NodeTypeConfigured(NodeType indexed nodeType, uint256 minStake, uint256 slashThreshold);
    event PermissionlessMintToggled(address indexed community, bool enabled);
    event CommunityRegisteredWithAutoStake(address indexed community, string name, uint256 staked, uint256 autoStaked);
    event PaymasterRegisteredWithAutoStake(address indexed paymaster, address indexed owner, NodeType indexed nodeType, uint256 staked, uint256 autoStaked);

    // v3.0.0 - New events for unified role system
    event RoleConfigured(bytes32 indexed roleId, uint256 minStake, uint256 slashThreshold, string description);
    event RoleGranted(bytes32 indexed roleId, address indexed user, uint256 stakeAmount);  // TODO: add sbtTokenId
    event RoleRevoked(bytes32 indexed roleId, address indexed user, uint256 burnedAmount);
    event RoleMintedByCommunity(bytes32 indexed roleId, address indexed user, address indexed community, uint256 amount);
    event RoleBurned(bytes32 indexed roleId, address indexed user, uint256 amount, string reason);
    event RoleMetadataUpdated(bytes32 indexed roleId, address indexed user);

    // ====================================
    // Errors
    // ====================================

    // v2 legacy errors
    error CommunityAlreadyRegistered(address community);
    error CommunityNotRegistered(address community);
    error NameAlreadyTaken(string name);
    error ENSAlreadyTaken(string ensName);
    error InvalidAddress(address addr);
    error InvalidParameter(string message);
    error CommunityNotActive(address community);
    error InsufficientStake(uint256 provided, uint256 required);
    error UnauthorizedOracle(address caller);
    error NameEmpty();
    error NotFound();
    error InsufficientGTokenBalance(uint256 available, uint256 required);
    error AutoStakeFailed(string reason);

    // v3.0.0 - New errors for role system
    error RoleNotConfigured(bytes32 roleId);
    error RoleAlreadyGranted(bytes32 roleId, address user);
    error RoleNotGranted(bytes32 roleId, address user);
    error Unauthorized(address caller);
    error InsufficientRoleStake(uint256 available, uint256 required);

    // ====================================
    // Constructor
    // ====================================

    constructor(address _gtoken, address _gtokenStaking, address _mysbt) Ownable(msg.sender) {
        if (_gtoken == address(0)) revert InvalidAddress(_gtoken);
        if (_gtokenStaking == address(0)) revert InvalidAddress(_gtokenStaking);
        if (_mysbt == address(0)) revert InvalidAddress(_mysbt);
        GTOKEN = IERC20(_gtoken);
        GTOKEN_STAKING = IGTokenStakingV3(_gtokenStaking);
        MYSBT = IMySBTV3(_mysbt);

        // Initialize default NodeType configs (v2 backward compatibility)
        // PAYMASTER_AOA: 30 GT, 3 GT entry burn, 10 failures, 2%-10%
        nodeTypeConfigs[NodeType.PAYMASTER_AOA] = RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,  // 10% of minStake
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            isActive: true,
            description: "AOA Independent Paymaster"
        });

        // PAYMASTER_SUPER: 50 GT, 5 GT entry burn, 10 failures, 2%-10%
        nodeTypeConfigs[NodeType.PAYMASTER_SUPER] = RoleConfig({
            minStake: 50 ether,
            entryBurn: 5 ether,  // 10% of minStake
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            isActive: true,
            description: "SuperPaymaster v2 Shared Mode"
        });

        // ANODE: 20 GT, 2 GT entry burn, 15 failures, 1%-5%
        nodeTypeConfigs[NodeType.ANODE] = RoleConfig({
            minStake: 20 ether,
            entryBurn: 2 ether,  // 10% of minStake
            slashThreshold: 15,
            slashBase: 1,
            slashIncrement: 1,
            slashMax: 5,
            isActive: true,
            description: "Community Computation Node"
        });

        // KMS: 100 GT, 10 GT entry burn, 5 failures, 5%-20%
        nodeTypeConfigs[NodeType.KMS] = RoleConfig({
            minStake: 100 ether,
            entryBurn: 10 ether,  // 10% of minStake
            slashThreshold: 5,
            slashBase: 5,
            slashIncrement: 2,
            slashMax: 20,
            isActive: true,
            description: "Key Management Service Node"
        });

        // Initialize corresponding role configs for v3.0.0
        _initializeDefaultRoles();
    }

    /**
     * @notice Initialize default role configs (v3.0.0)
     * @dev Maps NodeType enum to bytes32 roleIds for unified system
     */
    function _initializeDefaultRoles() internal {
        // Convert NodeType to roleId
        roleConfigs[keccak256("PAYMASTER_AOA")] = nodeTypeConfigs[NodeType.PAYMASTER_AOA];
        roleConfigs[keccak256("PAYMASTER_SUPER")] = nodeTypeConfigs[NodeType.PAYMASTER_SUPER];
        roleConfigs[keccak256("ANODE")] = nodeTypeConfigs[NodeType.ANODE];
        roleConfigs[keccak256("KMS")] = nodeTypeConfigs[NodeType.KMS];
    }

    // ====================================
    // v3.0.0 - Unified Role Management
    // ====================================

    /**
     * @notice Configure a role (owner only)
     * @param roleId Role identifier (e.g., keccak256("VALIDATOR"))
     * @param config Role configuration
     */
    function configureRole(bytes32 roleId, RoleConfig calldata config) external onlyOwner {
        if (config.minStake == 0) revert InvalidParameter("Min stake must be > 0");
        if (config.slashThreshold == 0) revert InvalidParameter("Threshold must be > 0");
        if (config.slashMax < config.slashBase) revert InvalidParameter("Max must be >= base");

        roleConfigs[roleId] = config;
        emit RoleConfigured(roleId, config.minStake, config.slashThreshold, config.description);
    }

    /**
     * @notice Register for a role (unified entry point)
     * @param roleId Role identifier
     * @param user User address to grant role to
     * @param roleData Additional role-specific data (ABI-encoded)
     * @dev Checks-Effects-Interactions pattern:
     *      1. Checks: role config exists, user doesn't have role, sufficient stake
     *      2. Effects: update hasRole, roleStakes, roleMembers mappings
     *      3. Interactions: lock stake in GTokenStaking contract
     */
    function registerRole(
        bytes32 roleId,
        address user,
        bytes calldata roleData
    ) external nonReentrant {
        // === Checks ===
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId);
        if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);

        // Decode roleData to get stake amount
        uint256 stakeAmount;
        if (roleData.length > 0) {
            stakeAmount = abi.decode(roleData, (uint256));
        } else {
            stakeAmount = config.minStake; // Default to minimum
        }

        if (stakeAmount < config.minStake) {
            revert InsufficientStake(stakeAmount, config.minStake);
        }

        // Check user has sufficient available balance
        uint256 available = GTOKEN_STAKING.availableBalance(user);
        if (available < stakeAmount) {
            revert InsufficientRoleStake(available, stakeAmount);
        }

        // === Effects ===
        hasRole[roleId][user] = true;
        roleStakes[roleId][user] = stakeAmount;
        roleMembers[roleId].push(user);

        // === Interactions ===
        // V3: Use roleId-based lockStake with entryBurn tracking
        GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);

        // V3: Mint SBT for user (self-service registration)
        // MySBT.mintForRole() creates/updates user's SBT with role data
        MYSBT.mintForRole(user, roleId, roleData);

        emit RoleGranted(roleId, user, stakeAmount);
    }

    /**
     * @notice Exit a role and burn staked tokens
     * @param roleId Role identifier
     * @dev Checks-Effects-Interactions pattern:
     *      1. Checks: user has role, stake exists
     *      2. Effects: update hasRole, record burn history
     *      3. Interactions: unlock and burn tokens
     */
    function exitRole(bytes32 roleId) external nonReentrant {
        // === Checks ===
        if (!hasRole[roleId][msg.sender]) revert RoleNotGranted(roleId, msg.sender);

        uint256 stakedAmount = roleStakes[roleId][msg.sender];
        if (stakedAmount == 0) revert InvalidParameter("No stake to exit");

        // === Effects ===
        hasRole[roleId][msg.sender] = false;
        roleStakes[roleId][msg.sender] = 0;

        // Record burn history
        BurnRecord memory record = BurnRecord({
            roleId: roleId,
            user: msg.sender,
            amount: stakedAmount,
            timestamp: block.timestamp,
            reason: "User initiated exit"
        });

        burnHistory.push(record);
        userBurnHistory[msg.sender].push(burnHistory.length - 1);

        // === Interactions ===
        // V3: Unlock stake by roleId (may have exit fee)
        uint256 netAmount = GTOKEN_STAKING.unlockStake(msg.sender, roleId);

        // Burn the unlocked tokens
        GTOKEN.safeTransferFrom(msg.sender, address(this), netAmount);
        IGToken(address(GTOKEN)).burn(netAmount);

        emit RoleRevoked(roleId, msg.sender, netAmount);
        emit RoleBurned(roleId, msg.sender, netAmount, "User initiated exit");
    }

    /**
     * @notice Community airdrops role to user (safe mint pattern)
     * @param roleId Role identifier
     * @param user User to receive the role
     * @param data Additional data (ABI-encoded stake amount)
     * @dev Community must be registered and caller must be community owner
     *      Checks-Effects-Interactions pattern enforced
     */
    function safeMintForRole(
        bytes32 roleId,
        address user,
        bytes calldata data
    ) external nonReentrant {
        // === Checks ===
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId);
        if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);

        // Verify caller is registered community
        if (communities[msg.sender].registeredAt == 0) {
            revert CommunityNotRegistered(msg.sender);
        }
        if (!communities[msg.sender].isActive) {
            revert CommunityNotActive(msg.sender);
        }

        // Decode stake amount
        uint256 stakeAmount = config.minStake; // Default
        if (data.length > 0) {
            stakeAmount = abi.decode(data, (uint256));
        }

        if (stakeAmount < config.minStake) {
            revert InsufficientStake(stakeAmount, config.minStake);
        }

        // Auto-stake for user if needed
        uint256 autoStaked = _autoStakeForUser(user, stakeAmount);

        // === Effects ===
        hasRole[roleId][user] = true;
        roleStakes[roleId][user] = stakeAmount;
        roleMembers[roleId].push(user);

        // === Interactions ===
        // V3: Role-based lockStake for airdrop
        GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);

        // V3: Admin airdrop - community pays for user's SBT
        // MySBT.airdropMint() creates/updates user's SBT (community covers costs)
        MYSBT.airdropMint(user, roleId, data);

        emit RoleGranted(roleId, user, stakeAmount);
        emit RoleMintedByCommunity(roleId, user, msg.sender, stakeAmount);
    }

    // ====================================
    // v3.0.0 - Role View Functions
    // ====================================

    /**
     * @notice Check if user has a specific role
     * @param roleId Role identifier
     * @param user User address
     * @return True if user has the role
     */
    function checkRole(bytes32 roleId, address user) external view returns (bool) {
        return hasRole[roleId][user];
    }

    /**
     * @notice Get user's stake for a role
     * @param roleId Role identifier
     * @param user User address
     * @return Staked amount
     */
    function getRoleStake(bytes32 roleId, address user) external view returns (uint256) {
        return roleStakes[roleId][user];
    }

    /**
     * @notice Get all members of a role
     * @param roleId Role identifier
     * @return Array of member addresses
     */
    function getRoleMembers(bytes32 roleId) external view returns (address[] memory) {
        return roleMembers[roleId];
    }

    /**
     * @notice Get role member count
     * @param roleId Role identifier
     * @return Number of members
     */
    function getRoleMemberCount(bytes32 roleId) external view returns (uint256) {
        return roleMembers[roleId].length;
    }

    /**
     * @notice Get user's burn history
     * @param user User address
     * @return Array of burn record indices
     */
    function getUserBurnHistory(address user) external view returns (uint256[] memory) {
        return userBurnHistory[user];
    }

    /**
     * @notice Get burn record by index
     * @param index Burn history index
     * @return Burn record
     */
    function getBurnRecord(uint256 index) external view returns (BurnRecord memory) {
        if (index >= burnHistory.length) revert InvalidParameter("Invalid index");
        return burnHistory[index];
    }

    /**
     * @notice Get total burn history count
     * @return Total number of burn records
     */
    function getBurnHistoryCount() external view returns (uint256) {
        return burnHistory.length;
    }

    // ====================================
    // v2 Legacy Functions (Backward Compatibility)
    // ====================================

    function registerCommunity(
        CommunityProfile memory profile,
        uint256 stGTokenAmount
    ) external nonReentrant {
        address communityAddress = msg.sender;

        // v2.2.1: Check isRegistered mapping to prevent duplicates
        if (isRegistered[communityAddress]) revert CommunityAlreadyRegistered(communityAddress);
        if (communities[communityAddress].registeredAt != 0) revert CommunityAlreadyRegistered(communityAddress);
        if (bytes(profile.name).length == 0) revert NameEmpty();
        if (bytes(profile.name).length > MAX_NAME_LENGTH) revert InvalidParameter("Name too long");
        if (profile.supportedSBTs.length > MAX_SUPPORTED_SBTS) revert InvalidParameter("Too many SBTs");

        RoleConfig memory config = nodeTypeConfigs[profile.nodeType];

        // Check stake requirement
        bytes32 communityRole = keccak256("COMMUNITY");
        if (stGTokenAmount > 0) {
            if (stGTokenAmount < config.minStake) revert InsufficientStake(stGTokenAmount, config.minStake);
            // V3: Use roleId-based lockStake
            GTOKEN_STAKING.lockStake(msg.sender, communityRole, stGTokenAmount, config.entryBurn);
        } else {
            // Check existing locked stake for COMMUNITY role
            uint256 existingLock = GTOKEN_STAKING.getLockedStake(msg.sender, communityRole);
            if (existingLock < config.minStake) revert InsufficientStake(existingLock, config.minStake);
        }

        // Check name uniqueness
        string memory lowercaseName = _toLowercase(profile.name);
        if (communityByName[lowercaseName] != address(0)) revert NameAlreadyTaken(profile.name);

        // Check ENS uniqueness
        if (bytes(profile.ensName).length > 0) {
            if (communityByENS[profile.ensName] != address(0)) revert ENSAlreadyTaken(profile.ensName);
        }

        // Set admin and timestamps
        profile.community = communityAddress;
        profile.registeredAt = block.timestamp;
        profile.lastUpdatedAt = block.timestamp;
        profile.isActive = true;
        profile.allowPermissionlessMint = true; // Default: allow permissionless minting

        communities[communityAddress] = profile;

        // V3: Reuse communityRole bytes32 from line 518
        uint256 recordedStake = stGTokenAmount > 0 ? stGTokenAmount : GTOKEN_STAKING.getLockedStake(msg.sender, communityRole);

        communityStakes[communityAddress] = CommunityStake({
            stGTokenLocked: recordedStake,
            failureCount: 0,
            lastFailureTime: 0,
            totalSlashed: 0,
            isActive: true
        });

        // Update indices
        communityByName[lowercaseName] = communityAddress;
        if (bytes(profile.ensName).length > 0) {
            communityByENS[profile.ensName] = communityAddress;
        }
        for (uint256 i = 0; i < profile.supportedSBTs.length; i++) {
            if (profile.supportedSBTs[i] != address(0)) {
                communityBySBT[profile.supportedSBTs[i]] = communityAddress;
            }
        }
        communityList.push(communityAddress);

        // v2.2.1: Mark as registered to prevent duplicates
        isRegistered[communityAddress] = true;

        emit CommunityRegistered(communityAddress, profile.name, profile.nodeType, communityStakes[communityAddress].stGTokenLocked);
    }

    function updateCommunityProfile(CommunityProfile memory profile) external {
        address communityAddress = msg.sender;
        if (communities[communityAddress].registeredAt == 0) revert CommunityNotRegistered(communityAddress);
        if (bytes(profile.name).length > MAX_NAME_LENGTH) revert InvalidParameter("Name too long");
        if (profile.supportedSBTs.length > MAX_SUPPORTED_SBTS) revert InvalidParameter("Too many SBTs");

        CommunityProfile storage existing = communities[communityAddress];

        // Update name if changed
        if (keccak256(bytes(profile.name)) != keccak256(bytes(existing.name))) {
            string memory oldName = _toLowercase(existing.name);
            string memory newName = _toLowercase(profile.name);
            if (communityByName[newName] != address(0) && communityByName[newName] != communityAddress) {
                revert NameAlreadyTaken(profile.name);
            }
            delete communityByName[oldName];
            communityByName[newName] = communityAddress;
        }

        // Update ENS if changed
        if (keccak256(bytes(profile.ensName)) != keccak256(bytes(existing.ensName))) {
            if (bytes(profile.ensName).length > 0) {
                if (communityByENS[profile.ensName] != address(0) && communityByENS[profile.ensName] != communityAddress) {
                    revert ENSAlreadyTaken(profile.ensName);
                }
            }
            if (bytes(existing.ensName).length > 0) delete communityByENS[existing.ensName];
            if (bytes(profile.ensName).length > 0) communityByENS[profile.ensName] = communityAddress;
        }

        // Update SBT indices
        for (uint256 i = 0; i < existing.supportedSBTs.length; i++) {
            if (communityBySBT[existing.supportedSBTs[i]] == communityAddress) {
                delete communityBySBT[existing.supportedSBTs[i]];
            }
        }
        for (uint256 i = 0; i < profile.supportedSBTs.length; i++) {
            if (profile.supportedSBTs[i] != address(0)) {
                communityBySBT[profile.supportedSBTs[i]] = communityAddress;
            }
        }

        // Update profile
        existing.name = profile.name;
        existing.ensName = profile.ensName;
        existing.xPNTsToken = profile.xPNTsToken;
        existing.supportedSBTs = profile.supportedSBTs;
        existing.paymasterAddress = profile.paymasterAddress;
        existing.lastUpdatedAt = block.timestamp;

        emit CommunityUpdated(communityAddress, profile.name);
    }

    function deactivateCommunity() external {
        if (communities[msg.sender].registeredAt == 0) revert CommunityNotRegistered(msg.sender);
        communities[msg.sender].isActive = false;
        communities[msg.sender].lastUpdatedAt = block.timestamp;
        emit CommunityDeactivated(msg.sender);
    }

    function reactivateCommunity() external {
        if (communities[msg.sender].registeredAt == 0) revert CommunityNotRegistered(msg.sender);
        communities[msg.sender].isActive = true;
        communities[msg.sender].lastUpdatedAt = block.timestamp;
        emit CommunityReactivated(msg.sender);
    }

    function transferCommunityOwnership(address newOwner) external nonReentrant {
        address currentOwner = msg.sender;
        if (communities[currentOwner].registeredAt == 0) revert CommunityNotRegistered(currentOwner);
        if (newOwner == address(0)) revert InvalidParameter("Zero address");
        if (newOwner == currentOwner) revert InvalidParameter("Same owner");
        if (communities[newOwner].registeredAt != 0) revert InvalidParameter("Already has community");

        CommunityProfile storage profile = communities[currentOwner];
        profile.community = newOwner;
        profile.lastUpdatedAt = block.timestamp;
        communities[newOwner] = profile;

        string memory lowerName = _toLowercase(profile.name);
        if (bytes(lowerName).length > 0) communityByName[lowerName] = newOwner;
        if (bytes(profile.ensName).length > 0) communityByENS[profile.ensName] = newOwner;
        for (uint256 i = 0; i < profile.supportedSBTs.length; i++) {
            if (profile.supportedSBTs[i] != address(0)) communityBySBT[profile.supportedSBTs[i]] = newOwner;
        }

        delete communities[currentOwner];
        emit CommunityOwnershipTransferred(currentOwner, newOwner, block.timestamp);
    }

    function setPermissionlessMint(bool enabled) external nonReentrant {
        if (communities[msg.sender].registeredAt == 0) revert CommunityNotRegistered(msg.sender);
        communities[msg.sender].allowPermissionlessMint = enabled;
        communities[msg.sender].lastUpdatedAt = block.timestamp;
        emit PermissionlessMintToggled(msg.sender, enabled);
    }

    // ====================================
    // View Functions
    // ====================================

    function getCommunityProfile(address communityAddress) external view returns (CommunityProfile memory profile) {
        profile = communities[communityAddress];
        if (profile.registeredAt == 0) revert CommunityNotRegistered(communityAddress);
    }

    function getCommunityByName(string memory name) external view returns (address communityAddress) {
        communityAddress = communityByName[_toLowercase(name)];
        if (communityAddress == address(0)) revert NotFound();
    }

    function getCommunityByENS(string memory ensName) external view returns (address communityAddress) {
        communityAddress = communityByENS[ensName];
        if (communityAddress == address(0)) revert NotFound();
    }

    function getCommunityBySBT(address sbtAddress) external view returns (address communityAddress) {
        communityAddress = communityBySBT[sbtAddress];
        if (communityAddress == address(0)) revert NotFound();
    }

    function getCommunityCount() external view returns (uint256) {
        return communityList.length;
    }

    function getCommunities(uint256 offset, uint256 limit) external view returns (address[] memory) {
        uint256 total = communityList.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 size = end - offset;
        address[] memory result = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            result[i] = communityList[offset + i];
        }
        return result;
    }

    function getCommunityStatus(address communityAddress) external view returns (bool registered, bool isActive) {
        registered = communities[communityAddress].registeredAt != 0;
        isActive = communities[communityAddress].isActive;
    }

    function isRegisteredCommunity(address communityAddress) external view returns (bool) {
        return communities[communityAddress].registeredAt != 0;
    }

    function isPermissionlessMintAllowed(address communityAddress) external view returns (bool) {
        return communities[communityAddress].allowPermissionlessMint;
    }

    // ====================================
    // Slash Functions
    // ====================================

    function reportFailure(address community) external {
        if (msg.sender != oracle && msg.sender != owner()) revert UnauthorizedOracle(msg.sender);
        CommunityStake storage stake = communityStakes[community];
        if (!stake.isActive) revert CommunityNotActive(community);

        stake.failureCount++;
        stake.lastFailureTime = block.timestamp;
        emit FailureReported(community, stake.failureCount);

        RoleConfig memory config = nodeTypeConfigs[communities[community].nodeType];
        if (stake.failureCount >= config.slashThreshold) {
            _slashCommunity(community);
        }
    }

    function _slashCommunity(address community) internal {
        CommunityStake storage stake = communityStakes[community];
        NodeType nodeType = communities[community].nodeType;
        RoleConfig memory config = nodeTypeConfigs[nodeType];

        uint256 excessFailures = stake.failureCount > config.slashThreshold ? stake.failureCount - config.slashThreshold : 0;
        uint256 slashPercentage = config.slashBase + (excessFailures * config.slashIncrement);
        if (slashPercentage > config.slashMax) slashPercentage = config.slashMax;

        uint256 slashAmount = stake.stGTokenLocked * slashPercentage / 100;
        stake.stGTokenLocked -= slashAmount;
        stake.totalSlashed += slashAmount;
        stake.failureCount = 0;

        if (stake.stGTokenLocked < config.minStake / 2) {
            stake.isActive = false;
            communities[community].isActive = false;
            emit CommunityDeactivated(community);
        }

        emit CommunitySlashed(community, slashAmount, stake.stGTokenLocked);

        uint256 slashed = GTOKEN_STAKING.slash(community, slashAmount, "Progressive slash");
        require(slashed == slashAmount, "Slash mismatch");
    }

    function resetFailureCount(address community) external onlyOwner {
        communityStakes[community].failureCount = 0;
        emit FailureCountReset(community);
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress(_oracle);
        address oldOracle = oracle;
        oracle = _oracle;
        emit OracleUpdated(oldOracle, _oracle);
    }

    function setSuperPaymasterV2(address _superPaymasterV2) external onlyOwner {
        if (_superPaymasterV2 == address(0)) revert InvalidAddress(_superPaymasterV2);
        superPaymasterV2 = _superPaymasterV2;
        emit SuperPaymasterV2Updated(_superPaymasterV2);
    }

    // REMOVED: configureNodeType() - Use configureRole(keccak256("ROLE_NAME"), config) instead
    // V3: Dynamic role system replaces fixed NodeType enum

    // ====================================
    // Internal Helpers
    // ====================================

    function _toLowercase(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(strBytes.length);
        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] >= 0x41 && strBytes[i] <= 0x5A) {
                result[i] = bytes1(uint8(strBytes[i]) + 32);
            } else {
                result[i] = strBytes[i];
            }
        }
        return string(result);
    }

    /**
     * @notice Convert bytes32 to string (for logging/events)
     * @param data Bytes32 data
     * @return String representation
     */
    function _bytes32ToString(bytes32 data) internal pure returns (string memory) {
        bytes memory bytesArray = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            bytesArray[i] = data[i];
        }
        return string(bytesArray);
    }

    /**
     * @notice Internal helper: Auto-stake for user if needed (MySBT pattern)
     * @param user User address
     * @param stakeAmount Required stake amount
     * @return autoStaked Amount auto-staked (0 if already sufficient)
     */
    function _autoStakeForUser(address user, uint256 stakeAmount) internal returns (uint256 autoStaked) {
        // Check user's available balance
        uint256 available = GTOKEN_STAKING.availableBalance(user);

        // Calculate how much we need to stake
        uint256 need = available < stakeAmount ? stakeAmount - available : 0;

        if (need > 0) {
            // Check user's wallet balance
            uint256 walletBalance = GTOKEN.balanceOf(user);
            if (walletBalance < need) {
                revert InsufficientGTokenBalance(walletBalance, need);
            }

            // Transfer GToken from user to this contract
            GTOKEN.safeTransferFrom(user, address(this), need);

            // Approve GTokenStaking to spend
            GTOKEN.approve(address(GTOKEN_STAKING), need);

            // Stake for user
            try GTOKEN_STAKING.stakeFor(user, need) returns (uint256) {
                autoStaked = need;
            } catch Error(string memory reason) {
                revert AutoStakeFailed(reason);
            } catch {
                revert AutoStakeFailed("Unknown error during stakeFor");
            }
        }

        return autoStaked;
    }

    // ====================================
    // Auto-Register Functions (v2.2.0)
    // ====================================

    // REMOVED: registerCommunityWithAutoStake() - Use registerCommunity() instead
    // V3: registerRole() provides cleaner auto-stake via _autoStakeForUser() internally
}
