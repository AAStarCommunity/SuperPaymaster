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
    // ====================================
    // V3 Role Data Structures
    // ====================================

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
    /// @dev 设计说明: AOA和SUPER使用不同的roleId (PAYMASTER_AOA, PAYMASTER_SUPER)
    ///      以支持不同的 stake requirements 和 slashing 参数
    struct PaymasterRoleData {
        address paymasterContract;  // Required
        string name;                // Required
        string apiEndpoint;         // Optional
        uint256 stakeAmount;        // Optional (0 = use minStake)
    }

    /// @notice V3: KMS (Key Management Service) role metadata
    struct KMSRoleData {
        address kmsContract;        // Required (KMS合约地址)
        string name;                // Required
        string apiEndpoint;         // Required (KMS API endpoint)
        bytes32[] supportedAlgos;   // Required (支持的加密算法,如"RSA","ECDSA")
        uint256 maxKeysPerUser;     // Required (每用户最大密钥数)
        uint256 stakeAmount;        // Optional (0 = use minStake)
    }

    /// @notice V3: Generic role metadata (for custom roles)
    /// @dev Used when role doesn't have a predefined struct
    struct GenericRoleData {
        string name;                // Required
        bytes extraData;            // Optional (ABI-encoded custom data)
        uint256 stakeAmount;        // Optional (0 = use minStake)
    }

    /// @notice Community profile (v3: removed supportedSBTs, only MySBT supported)
    struct CommunityProfile {
        string name;
        string ensName;
        address xPNTsToken;
        // REMOVED in v3: supportedSBTs[] - only MySBT is supported
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

    // REMOVED in v3: MAX_SUPPORTED_SBTS - only MySBT is supported
    uint256 public constant MAX_NAME_LENGTH = 100;
    string public constant VERSION = "3.0.0";
    uint256 public constant VERSION_CODE = 30000;

    // V3: Role constants (gas optimization - avoid repeated keccak256 calls)
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 public constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant ROLE_KMS = keccak256("KMS");

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
    // REMOVED in v3: communityBySBT - only MySBT is supported
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

    // V3: Dynamic role registration
    mapping(bytes32 => string) public proposedRoleNames;    // roleId -> role name (for proposed roles)
    mapping(bytes32 => address) public roleOwners;          // roleId -> owner address (who can configure this role)

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
    event RoleProposed(bytes32 indexed roleId, address indexed proposer, string roleName);
    event RoleActivated(bytes32 indexed roleId, string roleName);
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
     *      Sets registry owner as default role owner for system roles
     */
    function _initializeDefaultRoles() internal {
        // Convert NodeType to roleId
        roleConfigs[ROLE_PAYMASTER_AOA] = nodeTypeConfigs[NodeType.PAYMASTER_AOA];
        roleConfigs[ROLE_PAYMASTER_SUPER] = nodeTypeConfigs[NodeType.PAYMASTER_SUPER];
        roleConfigs[keccak256("ANODE")] = nodeTypeConfigs[NodeType.ANODE];
        roleConfigs[ROLE_KMS] = nodeTypeConfigs[NodeType.KMS];

        // V3: Set registry owner as default owner for system roles
        // This allows DAO/Multisig to manage system role configurations
        address registryOwner = owner();
        roleOwners[ROLE_COMMUNITY] = registryOwner;
        roleOwners[ROLE_ENDUSER] = registryOwner;
        roleOwners[ROLE_PAYMASTER_AOA] = registryOwner;
        roleOwners[ROLE_PAYMASTER_SUPER] = registryOwner;
        roleOwners[keccak256("ANODE")] = registryOwner;
        roleOwners[ROLE_KMS] = registryOwner;
    }

    // ====================================
    // v3.0.0 - Unified Role Management
    // ====================================

    /**
     * @notice Configure a role (role owner or registry admin)
     * @param roleId Role identifier (e.g., keccak256("VALIDATOR"))
     * @param config Role configuration
     * @dev Can be called by:
     *      - Role owner (e.g., Paymaster owner can configure ROLE_PAYMASTER parameters)
     *      - Registry admin (DAO/Multisig for system-level config)
     */
    function configureRole(bytes32 roleId, RoleConfig calldata config) external {
        // V3: Permission check - allow role owner OR registry admin
        address roleOwner = roleOwners[roleId];
        if (msg.sender != roleOwner && msg.sender != owner()) {
            revert Unauthorized();
        }

        if (config.minStake == 0) revert InvalidParameter("Min stake must be > 0");
        if (config.slashThreshold == 0) revert InvalidParameter("Threshold must be > 0");
        if (config.slashMax < config.slashBase) revert InvalidParameter("Max must be >= base");

        roleConfigs[roleId] = config;
        emit RoleConfigured(roleId, config.minStake, config.slashThreshold, config.description);
    }

    /**
     * @notice Propose a new custom role (owner only)
     * @param roleName Human-readable role name (e.g., "VIP_MEMBER", "KMS", "PAYMASTER_SUPER")
     * @param config Role configuration (stake requirements, slashing params, etc.)
     * @param roleOwner Address that will own this role (can configure it later)
     * @return roleId The computed roleId (keccak256 of roleName)
     * @dev Owner (多签) can propose new roles, then activate them via activateRole()
     *      This allows for a two-step review process for new role types
     *      roleOwner can later call configureRole() to update role parameters
     */
    function proposeNewRole(
        string calldata roleName,
        RoleConfig calldata config,
        address roleOwner
    ) external onlyOwner returns (bytes32 roleId) {
        // Validate role name
        if (bytes(roleName).length == 0) revert InvalidParameter("Role name required");
        if (bytes(roleName).length > 32) revert InvalidParameter("Role name too long");
        if (roleOwner == address(0)) revert InvalidParameter("Invalid role owner");

        // Compute roleId
        roleId = keccak256(bytes(roleName));

        // Check if role already exists
        if (roleConfigs[roleId].isActive) revert InvalidParameter("Role already active");
        if (bytes(proposedRoleNames[roleId]).length > 0) revert InvalidParameter("Role already proposed");

        // Validate config
        if (config.minStake == 0) revert InvalidParameter("Min stake must be > 0");
        if (config.slashThreshold == 0) revert InvalidParameter("Threshold must be > 0");
        if (config.slashMax < config.slashBase) revert InvalidParameter("Max must be >= base");

        // Store proposed role (inactive)
        RoleConfig memory proposedConfig = config;
        proposedConfig.isActive = false;  // Needs owner activation
        roleConfigs[roleId] = proposedConfig;
        proposedRoleNames[roleId] = roleName;

        // V3: Set role owner (who can configure this role)
        roleOwners[roleId] = roleOwner;

        emit RoleProposed(roleId, msg.sender, roleName);
    }

    /**
     * @notice Activate a proposed role (owner only)
     * @param roleId Role identifier to activate
     * @dev Once activated, users can register for this role via registerRole()
     */
    function activateRole(bytes32 roleId) external onlyOwner {
        // Check if role exists and is not yet active
        if (roleConfigs[roleId].minStake == 0) revert InvalidParameter("Role not configured");
        if (roleConfigs[roleId].isActive) revert InvalidParameter("Role already active");

        // Activate role
        roleConfigs[roleId].isActive = true;

        emit RoleActivated(roleId, proposedRoleNames[roleId]);
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

        // V3: Role-specific validation and stake extraction
        uint256 stakeAmount = _validateAndExtractStake(roleId, user, roleData);

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

        // V3: Store role metadata
        roleMetadata[roleId][user] = roleData;

        // === Interactions ===
        // V3: Use roleId-based lockStake with entryBurn tracking
        GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);

        // V3: Mint SBT for user (self-service registration)
        // MySBT.mintForRole() creates/updates user's SBT with role data
        (uint256 sbtTokenId, ) = MYSBT.mintForRole(user, roleId, roleData);

        // Store SBT tokenId for this role registration
        roleSBTTokenIds[roleId][user] = sbtTokenId;

        // V3: Role-specific post-registration (update indices, etc.)
        _postRegisterRole(roleId, user, roleData);

        emit RoleGranted(roleId, user, stakeAmount);
        emit RoleMetadataUpdated(roleId, user);
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
        // V3 SECURITY FIX: unlockAndTransfer automatically transfers to user
        // This prevents users from unstaking while keeping active roles
        uint256 netAmount = GTOKEN_STAKING.unlockAndTransfer(msg.sender, roleId);

        // SECURITY: Tokens are now in user's wallet (transferred by unlockAndTransfer)
        // Burn from user's balance
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

        // Verify caller is registered community (v2 compatibility check)
        // Gas optimization: Use contract constant instead of keccak256
        if (!hasRole[ROLE_COMMUNITY][msg.sender]) {
            // Fallback: check legacy communities mapping
            if (communities[msg.sender].registeredAt == 0) {
                revert CommunityNotRegistered(msg.sender);
            }
            if (!communities[msg.sender].isActive) {
                revert CommunityNotActive(msg.sender);
            }
        }

        // V3: Role-specific validation and stake extraction
        uint256 stakeAmount = _validateAndExtractStake(roleId, user, data);

        if (stakeAmount < config.minStake) {
            revert InsufficientStake(stakeAmount, config.minStake);
        }

        // Auto-stake for user if needed
        uint256 autoStaked = _autoStakeForUser(user, stakeAmount);

        // === Effects ===
        hasRole[roleId][user] = true;
        roleStakes[roleId][user] = stakeAmount;
        roleMembers[roleId].push(user);

        // V3: Store role metadata
        roleMetadata[roleId][user] = data;

        // === Interactions ===
        // V3: Role-based lockStake for airdrop
        GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);

        // V3: Admin airdrop - community pays for user's SBT
        // MySBT.airdropMint() creates/updates user's SBT (community covers costs)
        (uint256 sbtTokenId, ) = MYSBT.airdropMint(user, roleId, data);

        // Store SBT tokenId for this role registration
        roleSBTTokenIds[roleId][user] = sbtTokenId;

        // V3: Role-specific post-registration (update indices, etc.)
        _postRegisterRole(roleId, user, data);

        emit RoleGranted(roleId, user, stakeAmount);
        emit RoleMintedByCommunity(roleId, user, msg.sender, stakeAmount);
        emit RoleMetadataUpdated(roleId, user);
    }

    // ====================================
    // v3.0.0 - Role Update Functions
    // ====================================

    /**
     * @notice Update community role metadata
     * @param newData New community role data
     * @dev Caller must be the community owner (msg.sender)
     */
    function updateCommunityRole(CommunityRoleData memory newData) external nonReentrant {
        // Gas optimization: Use contract constant

        // Verify caller has COMMUNITY role
        if (!hasRole[ROLE_COMMUNITY][msg.sender]) {
            revert RoleNotGranted(ROLE_COMMUNITY, msg.sender);
        }

        // Validate new data
        if (bytes(newData.name).length == 0) revert InvalidParameter("Community name required");

        // Decode existing metadata
        bytes memory existingBytes = roleMetadata[ROLE_COMMUNITY][msg.sender];
        CommunityRoleData memory existing = abi.decode(existingBytes, (CommunityRoleData));

        // Check if name changed and new name is available
        if (keccak256(bytes(newData.name)) != keccak256(bytes(existing.name))) {
            if (communityByNameV3[newData.name] != address(0)) {
                revert InvalidParameter("Community name already taken");
            }
            // Update name index
            delete communityByNameV3[existing.name];
            communityByNameV3[newData.name] = msg.sender;
        }

        // Check if ENS changed and new ENS is available
        if (bytes(newData.ensName).length > 0 &&
            keccak256(bytes(newData.ensName)) != keccak256(bytes(existing.ensName))) {
            if (communityByENSV3[newData.ensName] != address(0)) {
                revert InvalidParameter("Community ENS already taken");
            }
            // Update ENS index
            if (bytes(existing.ensName).length > 0) {
                delete communityByENSV3[existing.ensName];
            }
            communityByENSV3[newData.ensName] = msg.sender;
        }

        // Store updated metadata
        roleMetadata[ROLE_COMMUNITY][msg.sender] = abi.encode(newData);

        emit RoleMetadataUpdated(ROLE_COMMUNITY, msg.sender);
    }

    /**
     * @notice Update end user role metadata
     * @param newData New end user role data
     * @dev Caller must have ENDUSER role
     */
    function updateEndUserRole(EndUserRoleData memory newData) external nonReentrant {
        // Gas optimization: Use contract constant

        // Verify caller has ENDUSER role
        if (!hasRole[ROLE_ENDUSER][msg.sender]) {
            revert RoleNotGranted(ROLE_ENDUSER, msg.sender);
        }

        // Validate new data
        if (newData.account == address(0)) revert InvalidParameter("Account address required");
        if (newData.community == address(0)) revert InvalidParameter("Community required");

        // Decode existing metadata
        bytes memory existingBytes = roleMetadata[ROLE_ENDUSER][msg.sender];
        EndUserRoleData memory existing = abi.decode(existingBytes, (EndUserRoleData));

        // Check if account changed
        if (newData.account != existing.account) {
            // Check if new account is available
            if (accountToUser[newData.account] != address(0) &&
                accountToUser[newData.account] != msg.sender) {
                revert InvalidParameter("Account already registered");
            }
            // Update account mapping
            delete accountToUser[existing.account];
            accountToUser[newData.account] = msg.sender;
        }

        // Store updated metadata
        roleMetadata[ROLE_ENDUSER][msg.sender] = abi.encode(newData);

        emit RoleMetadataUpdated(ROLE_ENDUSER, msg.sender);
    }

    /**
     * @notice Update paymaster role metadata
     * @param newData New paymaster role data
     * @dev Caller must have PAYMASTER role
     */
    function updatePaymasterRole(PaymasterRoleData memory newData) external nonReentrant {
        bytes32 ROLE_PAYMASTER = keccak256("PAYMASTER");

        // Verify caller has PAYMASTER role
        if (!hasRole[ROLE_PAYMASTER][msg.sender]) {
            revert RoleNotGranted(ROLE_PAYMASTER, msg.sender);
        }

        // Validate new data
        if (newData.paymasterContract == address(0)) revert InvalidParameter("Paymaster contract required");
        if (bytes(newData.name).length == 0) revert InvalidParameter("Paymaster name required");

        // Store updated metadata (no index updates needed for Paymaster)
        roleMetadata[ROLE_PAYMASTER][msg.sender] = abi.encode(newData);

        emit RoleMetadataUpdated(ROLE_PAYMASTER, msg.sender);
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
     * @notice Get user's SBT tokenId for a specific role
     * @param roleId Role identifier
     * @param user User address
     * @return SBT token ID (0 if no SBT)
     */
    function getRoleSBTTokenId(bytes32 roleId, address user) external view returns (uint256) {
        return roleSBTTokenIds[roleId][user];
    }

    /**
     * @notice Get user's role metadata
     * @param roleId Role identifier
     * @param user User address
     * @return ABI-encoded role metadata
     */
    function getRoleMetadata(bytes32 roleId, address user) external view returns (bytes memory) {
        return roleMetadata[roleId][user];
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
        // REMOVED in v3: supportedSBTs validation - only MySBT is supported

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
        // REMOVED in v3: supportedSBTs loop - only MySBT is supported
        communityList.push(communityAddress);

        // v2.2.1: Mark as registered to prevent duplicates
        isRegistered[communityAddress] = true;

        emit CommunityRegistered(communityAddress, profile.name, profile.nodeType, communityStakes[communityAddress].stGTokenLocked);
    }

    function updateCommunityProfile(CommunityProfile memory profile) external {
        address communityAddress = msg.sender;
        if (communities[communityAddress].registeredAt == 0) revert CommunityNotRegistered(communityAddress);
        if (bytes(profile.name).length > MAX_NAME_LENGTH) revert InvalidParameter("Name too long");
        // REMOVED in v3: supportedSBTs validation - only MySBT is supported

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

        // REMOVED in v3: SBT indices update loops - only MySBT is supported

        // Update profile
        existing.name = profile.name;
        existing.ensName = profile.ensName;
        existing.xPNTsToken = profile.xPNTsToken;
        // REMOVED in v3: supportedSBTs assignment - only MySBT is supported
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
        // REMOVED in v3: supportedSBTs loop - only MySBT is supported

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

    // REMOVED in v3: getCommunityBySBT() - only MySBT is supported, no multi-SBT tracking

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

    // ====================================
    // V3 Internal Helper Functions
    // ====================================

    /**
     * @notice Validate role-specific data and extract stake amount
     * @param roleId Role identifier
     * @param user User address
     * @param roleData ABI-encoded role-specific data
     * @return stakeAmount Stake amount to lock
     */
    function _validateAndExtractStake(
        bytes32 roleId,
        address user,
        bytes calldata roleData
    ) internal view returns (uint256 stakeAmount) {
        // Gas optimization: Use contract constants instead of repeated keccak256 calls
        // Saves ~200-300 gas per function call (5 keccak256 operations avoided)

        if (roleId == ROLE_COMMUNITY) {
            // Decode CommunityRoleData
            CommunityRoleData memory data = abi.decode(roleData, (CommunityRoleData));

            // Validate required fields
            if (bytes(data.name).length == 0) revert InvalidParameter("Community name required");

            // Check if name/ENS already taken
            if (communityByNameV3[data.name] != address(0)) {
                revert InvalidParameter("Community name already taken");
            }
            if (bytes(data.ensName).length > 0 && communityByENSV3[data.ensName] != address(0)) {
                revert InvalidParameter("Community ENS already taken");
            }

            stakeAmount = data.stakeAmount;

        } else if (roleId == ROLE_ENDUSER) {
            // Decode EndUserRoleData
            EndUserRoleData memory data = abi.decode(roleData, (EndUserRoleData));

            // Validate required fields
            if (data.account == address(0)) revert InvalidParameter("Account address required");
            if (data.community == address(0)) revert InvalidParameter("Community required");

            // Verify community is active
            if (!hasRole[ROLE_COMMUNITY][data.community]) {
                revert InvalidParameter("Community not registered");
            }

            // Check if account already mapped
            if (accountToUser[data.account] != address(0) && accountToUser[data.account] != user) {
                revert InvalidParameter("Account already registered");
            }

            stakeAmount = data.stakeAmount;

        } else if (roleId == ROLE_PAYMASTER_AOA || roleId == ROLE_PAYMASTER_SUPER) {
            // Decode PaymasterRoleData (同样的数据结构,不同的stake requirements)
            PaymasterRoleData memory data = abi.decode(roleData, (PaymasterRoleData));

            // Validate required fields
            if (data.paymasterContract == address(0)) revert InvalidParameter("Paymaster contract required");
            if (bytes(data.name).length == 0) revert InvalidParameter("Paymaster name required");

            stakeAmount = data.stakeAmount;

        } else if (roleId == ROLE_KMS) {
            // Decode KMSRoleData
            KMSRoleData memory data = abi.decode(roleData, (KMSRoleData));

            // Validate required fields
            if (data.kmsContract == address(0)) revert InvalidParameter("KMS contract required");
            if (bytes(data.name).length == 0) revert InvalidParameter("KMS name required");
            if (bytes(data.apiEndpoint).length == 0) revert InvalidParameter("KMS API endpoint required");
            if (data.supportedAlgos.length == 0) revert InvalidParameter("At least one algorithm required");
            if (data.maxKeysPerUser == 0) revert InvalidParameter("maxKeysPerUser must be > 0");

            stakeAmount = data.stakeAmount;

        } else {
            // Generic role: try to decode as GenericRoleData
            if (roleData.length > 0) {
                try this._tryDecodeGenericRole(roleData) returns (GenericRoleData memory data) {
                    stakeAmount = data.stakeAmount;
                } catch {
                    // Fallback: assume roleData is just uint256 stakeAmount
                    stakeAmount = abi.decode(roleData, (uint256));
                }
            } // else stakeAmount remains 0, will use minStake below
        }

        // Gas optimization: Load minStake once instead of twice (lines 1166, 1172)
        // Use minStake if stakeAmount is 0
        if (stakeAmount == 0) {
            RoleConfig memory config = roleConfigs[roleId];
            stakeAmount = config.minStake;
        }
    }

    /// @notice Helper function to decode GenericRoleData (public for try/catch)
    function _tryDecodeGenericRole(bytes calldata roleData) external pure returns (GenericRoleData memory) {
        return abi.decode(roleData, (GenericRoleData));
    }

    /**
     * @notice Post-registration hook for role-specific logic
     * @param roleId Role identifier
     * @param user User address
     * @param roleData ABI-encoded role-specific data
     */
    function _postRegisterRole(
        bytes32 roleId,
        address user,
        bytes calldata roleData
    ) internal {
        // Gas optimization: Use contract constants

        if (roleId == ROLE_COMMUNITY) {
            // Update community indices
            CommunityRoleData memory data = abi.decode(roleData, (CommunityRoleData));

            communityByNameV3[data.name] = user;
            if (bytes(data.ensName).length > 0) {
                communityByENSV3[data.ensName] = user;
            }

        } else if (roleId == ROLE_ENDUSER) {
            // Update account mapping
            EndUserRoleData memory data = abi.decode(roleData, (EndUserRoleData));

            accountToUser[data.account] = user;
        }

        // PAYMASTER and other roles: no special post-registration logic needed
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
