// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title Registry v2.1
 * @notice Community metadata storage, staking management, and slash system for SuperPaymaster
 * @dev Stores all community information and enforces reputation through stGToken locks
 *
 * Key Features:
 * - Atomic registration: metadata + stGToken lock in one transaction
 * - Failure monitoring and progressive slash system (2%-10%)
 * - Support for 4 node types: AOA, Super, ANode, KMS
 * - Configurable stake requirements per node type (governance)
 *
 * Architecture:
 * - Registry stores metadata and triggers slash
 * - GTokenStaking executes lock and slash operations
 * - Oracle reports failures for monitoring
 *
 * @custom:version 2.1
 * @custom:changes Added configurable node types and progressive slash
 */
contract Registry is Ownable, ReentrancyGuard {

    /// @notice Node type (replaces PaymasterMode for extensibility)
    enum NodeType {
        PAYMASTER_AOA,      // 0: AOA (Asset Oriented Abstraction) independent Paymaster
        PAYMASTER_SUPER,    // 1: SuperPaymaster v2 shared mode
        ANODE,              // 2: Community computation node
        KMS                 // 3: Key Management Service node
    }

    /// @notice Node type configuration (governance adjustable)
    struct NodeTypeConfig {
        uint256 minStake;           // Minimum stGToken stake required
        uint256 slashThreshold;     // Failure count to trigger slash
        uint256 slashBase;          // Base slash percentage (e.g., 2 = 2%)
        uint256 slashIncrement;     // Increment per failure (e.g., 1 = +1% per failure)
        uint256 slashMax;           // Maximum slash percentage (e.g., 10 = 10%)
    }

    /// @notice Legacy enum for backward compatibility (mapped to NodeType)
    enum PaymasterMode {
        INDEPENDENT,  // Maps to PAYMASTER_AOA
        SUPER         // Maps to PAYMASTER_SUPER
    }

    /// @notice Complete community profile with metadata and configuration
    struct CommunityProfile {
        // Basic information
        string name;                    // Community name
        string ensName;                 // ENS domain (e.g., "community.eth")
        string description;             // Community description
        string website;                 // Official website URL
        string logoURI;                 // Logo image URI

        // Social links
        string twitterHandle;           // Twitter @handle
        string githubOrg;               // GitHub organization
        string telegramGroup;           // Telegram group invite link

        // Token & SBT
        address xPNTsToken;             // Community points token address
        address[] supportedSBTs;        // List of supported SBT contracts

        // Node configuration
        PaymasterMode mode;             // Legacy: INDEPENDENT or SUPER (backward compat)
        NodeType nodeType;              // v2.1: Actual node type (AOA/SUPER/ANODE/KMS)
        address paymasterAddress;       // Paymaster/Node contract address
        address community;              // Community admin address

        // Metadata
        uint256 registeredAt;           // Registration timestamp
        uint256 lastUpdatedAt;          // Last update timestamp
        bool isActive;                  // Active status
        uint256 memberCount;            // Number of members (optional)

        // MySBT Integration (v2.1.1)
        bool allowPermissionlessMint;   // Allow users to mint MySBT without invitation
    }

    /// @notice Community staking and reputation tracking
    struct CommunityStake {
        uint256 stGTokenLocked;         // Current locked stGToken amount
        uint256 failureCount;           // Consecutive failure count
        uint256 lastFailureTime;        // Last failure timestamp
        uint256 totalSlashed;           // Total slashed amount (historical)
        bool isActive;                  // Active status (deactivated if stake too low)
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice GTokenStaking contract
    IGTokenStaking public immutable GTOKEN_STAKING;

    /// @notice Oracle address (can report failures)
    address public oracle;

    /// @notice SuperPaymaster v2 contract address (for Super mode communities)
    address public superPaymasterV2;

    /// @notice Node type configurations (governance adjustable)
    mapping(NodeType => NodeTypeConfig) public nodeTypeConfigs;

    /// @notice Main storage: community address => profile
    mapping(address => CommunityProfile) public communities;

    /// @notice Community staking info
    mapping(address => CommunityStake) public communityStakes;

    /// @notice Index by name: lowercase name => community address
    mapping(string => address) public communityByName;

    /// @notice Index by ENS: ENS name => community address
    mapping(string => address) public communityByENS;

    /// @notice Index by SBT: SBT address => community address
    mapping(address => address) public communityBySBT;

    /// @notice List of all registered community addresses
    address[] public communityList;

    // ====================================
    // Events
    // ====================================

    event CommunityRegistered(
        address indexed community,
        string name,
        string ensName,
        PaymasterMode mode,
        NodeType indexed nodeType,
        uint256 stGTokenLocked
    );

    event CommunityUpdated(
        address indexed community,
        string name
    );

    event CommunityDeactivated(
        address indexed community,
        string reason
    );

    event CommunityReactivated(
        address indexed community
    );

    event CommunityOwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner,
        uint256 timestamp
    );

    event FailureReported(
        address indexed community,
        uint256 failureCount,
        uint256 timestamp
    );

    event CommunitySlashed(
        address indexed community,
        uint256 amount,
        uint256 newStake,
        uint256 timestamp
    );

    event FailureCountReset(
        address indexed community,
        uint256 timestamp
    );

    event OracleUpdated(
        address indexed oldOracle,
        address indexed newOracle
    );

    event SuperPaymasterV2Updated(
        address indexed newSuperPaymasterV2
    );

    event NodeTypeConfigured(
        NodeType indexed nodeType,
        uint256 minStake,
        uint256 slashThreshold
    );

    event PermissionlessMintToggled(
        address indexed community,
        bool enabled,
        uint256 timestamp
    );

    // ====================================
    // Errors
    // ====================================

    error CommunityAlreadyRegistered(address community);
    error CommunityNotRegistered(address community);
    error NameAlreadyTaken(string name);
    error ENSAlreadyTaken(string ensName);
    error InvalidAddress(address addr);
    error InvalidParameter(string message);
    error CommunityNotActive(address community);
    error InsufficientStake(uint256 provided, uint256 required);
    error UnauthorizedOracle(address caller);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize Registry v2.1 with GTokenStaking contract
     * @param _gtokenStaking GTokenStaking contract address
     * @dev Initializes default node type configurations (governance adjustable later)
     */
    constructor(address _gtokenStaking) Ownable(msg.sender) {
        if (_gtokenStaking == address(0)) {
            revert InvalidAddress(_gtokenStaking);
        }
        GTOKEN_STAKING = IGTokenStaking(_gtokenStaking);

        // Initialize default node type configurations
        // PAYMASTER_AOA: 30 GT stake, 10 failures → 2% base, +1% per failure, max 10%
        nodeTypeConfigs[NodeType.PAYMASTER_AOA] = NodeTypeConfig({
            minStake: 30 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10
        });

        // PAYMASTER_SUPER: 50 GT stake, 10 failures → 2% base, +1% per failure, max 10%
        nodeTypeConfigs[NodeType.PAYMASTER_SUPER] = NodeTypeConfig({
            minStake: 50 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10
        });

        // ANODE: 20 GT stake (lower for computation), 15 failures → 1% base, +1%, max 5%
        nodeTypeConfigs[NodeType.ANODE] = NodeTypeConfig({
            minStake: 20 ether,
            slashThreshold: 15,
            slashBase: 1,
            slashIncrement: 1,
            slashMax: 5
        });

        // KMS: 100 GT stake (higher for security), 5 failures → 5% base, +2%, max 20%
        nodeTypeConfigs[NodeType.KMS] = NodeTypeConfig({
            minStake: 100 ether,
            slashThreshold: 5,
            slashBase: 5,
            slashIncrement: 2,
            slashMax: 20
        });
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register a new community with stGToken lock (AOA mode)
     * @param profile Complete community profile data
     * @param stGTokenAmount Amount of stGToken to lock (30-100 recommended)
     * @dev Atomic operation: locks stGToken via GTokenStaking + stores metadata
     *      For Super mode communities, this can be called with stGTokenAmount=0
     *      if they already locked via SuperPaymaster.registerOperator()
     */
    function registerCommunity(
        CommunityProfile memory profile,
        uint256 stGTokenAmount
    ) external nonReentrant {
        address communityAddress = msg.sender;

        // Validation
        if (communities[communityAddress].registeredAt != 0) {
            revert CommunityAlreadyRegistered(communityAddress);
        }

        if (bytes(profile.name).length == 0) {
            revert("Name cannot be empty");
        }

        // Map legacy PaymasterMode to NodeType (backward compatibility)
        NodeType nodeType = profile.mode == PaymasterMode.INDEPENDENT
            ? NodeType.PAYMASTER_AOA
            : NodeType.PAYMASTER_SUPER;

        // Get config for this node type
        NodeTypeConfig memory config = nodeTypeConfigs[nodeType];

        // Check minimum stake requirement
        if (profile.mode == PaymasterMode.INDEPENDENT) {
            // AOA mode MUST lock stGToken here
            if (stGTokenAmount < config.minStake) {
                revert InsufficientStake(stGTokenAmount, config.minStake);
            }

            // Lock stGToken via GTokenStaking (atomic)
            GTOKEN_STAKING.lockStake(
                msg.sender,
                stGTokenAmount,
                "Registry community registration"
            );
        } else {
            // Super mode: either lock here or already locked via SuperPaymaster
            if (stGTokenAmount > 0) {
                // If providing stake, check minimum
                if (stGTokenAmount < config.minStake) {
                    revert InsufficientStake(stGTokenAmount, config.minStake);
                }

                // Lock stGToken
                GTOKEN_STAKING.lockStake(
                    msg.sender,
                    stGTokenAmount,
                    "Registry community registration (Super mode)"
                );
            } else {
                // Verify already locked via SuperPaymaster
                uint256 existingLock = GTOKEN_STAKING.getLockedStake(msg.sender, msg.sender);
                if (existingLock < config.minStake) {
                    revert InsufficientStake(existingLock, config.minStake);
                }
            }
        }

        // Set nodeType in profile
        profile.nodeType = nodeType;

        // Check name uniqueness (case-insensitive)
        string memory lowercaseName = _toLowercase(profile.name);
        if (communityByName[lowercaseName] != address(0)) {
            revert NameAlreadyTaken(profile.name);
        }

        // Check ENS uniqueness (if provided)
        if (bytes(profile.ensName).length > 0) {
            if (communityByENS[profile.ensName] != address(0)) {
                revert ENSAlreadyTaken(profile.ensName);
            }
        }

        // Set admin and timestamps
        profile.community = communityAddress;
        profile.registeredAt = block.timestamp;
        profile.lastUpdatedAt = block.timestamp;
        profile.isActive = true;

        // Store profile
        communities[communityAddress] = profile;

        // Store staking info
        communityStakes[communityAddress] = CommunityStake({
            stGTokenLocked: stGTokenAmount > 0 ? stGTokenAmount : GTOKEN_STAKING.getLockedStake(msg.sender, msg.sender),
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
            address sbtAddress = profile.supportedSBTs[i];
            if (sbtAddress != address(0)) {
                communityBySBT[sbtAddress] = communityAddress;
            }
        }

        communityList.push(communityAddress);

        emit CommunityRegistered(
            communityAddress,
            profile.name,
            profile.ensName,
            profile.mode,
            profile.nodeType,
            communityStakes[communityAddress].stGTokenLocked
        );
    }

    /**
     * @notice Update community profile
     * @param profile Updated profile data
     * @dev Can only be called by community admin
     */
    function updateCommunityProfile(CommunityProfile memory profile) external {
        address communityAddress = msg.sender;

        if (communities[communityAddress].registeredAt == 0) {
            revert CommunityNotRegistered(communityAddress);
        }

        CommunityProfile storage existing = communities[communityAddress];

        // Update name if changed
        if (keccak256(bytes(profile.name)) != keccak256(bytes(existing.name))) {
            string memory oldName = _toLowercase(existing.name);
            string memory newName = _toLowercase(profile.name);

            // Check new name availability
            if (communityByName[newName] != address(0) &&
                communityByName[newName] != communityAddress) {
                revert NameAlreadyTaken(profile.name);
            }

            // Update index
            delete communityByName[oldName];
            communityByName[newName] = communityAddress;
        }

        // Update ENS if changed
        if (keccak256(bytes(profile.ensName)) != keccak256(bytes(existing.ensName))) {
            // Check new ENS availability
            if (bytes(profile.ensName).length > 0) {
                if (communityByENS[profile.ensName] != address(0) &&
                    communityByENS[profile.ensName] != communityAddress) {
                    revert ENSAlreadyTaken(profile.ensName);
                }
            }

            // Update index
            if (bytes(existing.ensName).length > 0) {
                delete communityByENS[existing.ensName];
            }
            if (bytes(profile.ensName).length > 0) {
                communityByENS[profile.ensName] = communityAddress;
            }
        }

        // Update SBT indices if changed
        // Remove old SBTs
        for (uint256 i = 0; i < existing.supportedSBTs.length; i++) {
            if (communityBySBT[existing.supportedSBTs[i]] == communityAddress) {
                delete communityBySBT[existing.supportedSBTs[i]];
            }
        }
        // Add new SBTs
        for (uint256 i = 0; i < profile.supportedSBTs.length; i++) {
            address sbtAddress = profile.supportedSBTs[i];
            if (sbtAddress != address(0)) {
                communityBySBT[sbtAddress] = communityAddress;
            }
        }

        // Update profile (preserve immutable fields)
        existing.name = profile.name;
        existing.ensName = profile.ensName;
        existing.description = profile.description;
        existing.website = profile.website;
        existing.logoURI = profile.logoURI;
        existing.twitterHandle = profile.twitterHandle;
        existing.githubOrg = profile.githubOrg;
        existing.telegramGroup = profile.telegramGroup;
        existing.xPNTsToken = profile.xPNTsToken;
        existing.supportedSBTs = profile.supportedSBTs;
        existing.mode = profile.mode;
        existing.paymasterAddress = profile.paymasterAddress;
        existing.memberCount = profile.memberCount;
        existing.lastUpdatedAt = block.timestamp;

        emit CommunityUpdated(communityAddress, profile.name);
    }

    /**
     * @notice Deactivate community (admin only)
     */
    function deactivateCommunity() external {
        address communityAddress = msg.sender;

        if (communities[communityAddress].registeredAt == 0) {
            revert CommunityNotRegistered(communityAddress);
        }

        communities[communityAddress].isActive = false;
        communities[communityAddress].lastUpdatedAt = block.timestamp;

        emit CommunityDeactivated(communityAddress, "Manual deactivation by admin");
    }

    /**
     * @notice Reactivate community (admin only)
     */
    function reactivateCommunity() external {
        address communityAddress = msg.sender;

        if (communities[communityAddress].registeredAt == 0) {
            revert CommunityNotRegistered(communityAddress);
        }

        communities[communityAddress].isActive = true;
        communities[communityAddress].lastUpdatedAt = block.timestamp;

        emit CommunityReactivated(communityAddress);
    }

    /**
     * @notice Transfer community ownership to new address
     * @dev Allows community owner to transfer ownership from EOA to multisig (e.g., Gnosis Safe)
     *      - Updates community address in mapping
     *      - Updates all index mappings (name, ENS, SBT)
     *      - Preserves all community data
     *      - New owner must not have an existing community
     * @param newOwner New community owner address (e.g., Gnosis Safe multisig)
     */
    function transferCommunityOwnership(address newOwner) external nonReentrant {
        address currentOwner = msg.sender;

        // Verify current owner has a registered community
        if (communities[currentOwner].registeredAt == 0) {
            revert CommunityNotRegistered(currentOwner);
        }

        // Verify new owner is valid
        if (newOwner == address(0)) {
            revert InvalidParameter("New owner cannot be zero address");
        }
        if (newOwner == currentOwner) {
            revert InvalidParameter("New owner same as current");
        }
        if (communities[newOwner].registeredAt != 0) {
            revert InvalidParameter("New owner already has a community");
        }

        // Get community profile
        CommunityProfile storage profile = communities[currentOwner];

        // Update community.community field to new owner
        profile.community = newOwner;
        profile.lastUpdatedAt = block.timestamp;

        // Transfer community data to new owner mapping
        communities[newOwner] = profile;

        // Update name index
        string memory lowerName = _toLowercase(profile.name);
        if (bytes(lowerName).length > 0) {
            communityByName[lowerName] = newOwner;
        }

        // Update ENS index
        if (bytes(profile.ensName).length > 0) {
            communityByENS[profile.ensName] = newOwner;
        }

        // Update SBT indices
        for (uint256 i = 0; i < profile.supportedSBTs.length; i++) {
            address sbtAddress = profile.supportedSBTs[i];
            if (sbtAddress != address(0)) {
                communityBySBT[sbtAddress] = newOwner;
            }
        }

        // Clear old owner's community data
        delete communities[currentOwner];

        emit CommunityOwnershipTransferred(currentOwner, newOwner, block.timestamp);
    }

    /**
     * @notice Toggle permissionless MySBT minting for this community
     * @param enabled True to allow users to mint without invitation, false to require invitation
     */
    function setPermissionlessMint(bool enabled) external nonReentrant {
        address communityAddress = msg.sender;

        if (communities[communityAddress].registeredAt == 0) {
            revert CommunityNotRegistered(communityAddress);
        }

        communities[communityAddress].allowPermissionlessMint = enabled;
        communities[communityAddress].lastUpdatedAt = block.timestamp;

        emit PermissionlessMintToggled(communityAddress, enabled, block.timestamp);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get complete community profile
     * @param communityAddress Community admin address
     * @return profile Complete profile data
     */
    function getCommunityProfile(address communityAddress)
        external
        view
        returns (CommunityProfile memory profile)
    {
        profile = communities[communityAddress];
        if (profile.registeredAt == 0) {
            revert CommunityNotRegistered(communityAddress);
        }
    }

    /**
     * @notice Get community address by name (case-insensitive)
     * @param name Community name
     * @return communityAddress Community admin address
     */
    function getCommunityByName(string memory name)
        external
        view
        returns (address communityAddress)
    {
        string memory lowercaseName = _toLowercase(name);
        communityAddress = communityByName[lowercaseName];
        if (communityAddress == address(0)) {
            revert("Community not found");
        }
    }

    /**
     * @notice Get community address by ENS
     * @param ensName ENS domain name
     * @return communityAddress Community admin address
     */
    function getCommunityByENS(string memory ensName)
        external
        view
        returns (address communityAddress)
    {
        communityAddress = communityByENS[ensName];
        if (communityAddress == address(0)) {
            revert("Community not found");
        }
    }

    /**
     * @notice Get community address by SBT contract
     * @param sbtAddress SBT contract address
     * @return communityAddress Community admin address
     */
    function getCommunityBySBT(address sbtAddress)
        external
        view
        returns (address communityAddress)
    {
        communityAddress = communityBySBT[sbtAddress];
        if (communityAddress == address(0)) {
            revert("Community not found");
        }
    }

    /**
     * @notice Get total number of registered communities
     * @return count Total communities
     */
    function getCommunityCount() external view returns (uint256 count) {
        return communityList.length;
    }

    /**
     * @notice Get paginated community list
     * @param offset Start index
     * @param limit Number of communities to return
     * @return communities Array of community addresses
     */
    function getCommunities(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        uint256 total = communityList.length;

        if (offset >= total) {
            return new address[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 size = end - offset;
        address[] memory result = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            result[i] = communityList[offset + i];
        }

        return result;
    }

    /**
     * @notice Check if community is registered and active
     * @param communityAddress Community admin address
     * @return isRegistered True if registered
     * @return isActive True if active
     */
    function getCommunityStatus(address communityAddress)
        external
        view
        returns (bool isRegistered, bool isActive)
    {
        isRegistered = communities[communityAddress].registeredAt != 0;
        isActive = communities[communityAddress].isActive;
    }

    /**
     * @notice Check if a community is registered in the Registry
     * @param communityAddress Community address to check
     * @return registered True if community is registered (used by MySBT v2.3.1+)
     * @dev Returns true if registeredAt timestamp is not zero
     */
    function isRegisteredCommunity(address communityAddress)
        external
        view
        returns (bool registered)
    {
        return communities[communityAddress].registeredAt != 0;
    }

    /**
     * @notice Check if a community allows permissionless MySBT minting
     * @param communityAddress Community address to check
     * @return allowed True if users can mint without invitation, false otherwise
     */
    function isPermissionlessMintAllowed(address communityAddress)
        external
        view
        returns (bool allowed)
    {
        return communities[communityAddress].allowPermissionlessMint;
    }

    // ====================================
    // Slash Functions
    // ====================================

    /**
     * @notice Report failure for a community (called by oracle or owner)
     * @param community Community address to report
     * @dev Increments failure count and triggers slash if threshold reached
     */
    function reportFailure(address community) external {
        if (msg.sender != oracle && msg.sender != owner()) {
            revert UnauthorizedOracle(msg.sender);
        }

        CommunityStake storage stake = communityStakes[community];

        if (!stake.isActive) {
            revert CommunityNotActive(community);
        }

        stake.failureCount++;
        stake.lastFailureTime = block.timestamp;

        emit FailureReported(community, stake.failureCount, block.timestamp);

        // Get node type config for threshold
        NodeType nodeType = communities[community].nodeType;
        NodeTypeConfig memory config = nodeTypeConfigs[nodeType];

        // Trigger slash if threshold reached (configurable per node type)
        if (stake.failureCount >= config.slashThreshold) {
            _slashCommunity(community);
        }
    }

    /**
     * @notice Internal function to slash community's stGToken (progressive slash)
     * @param community Community address to slash
     * @dev v2.1: Implements progressive slash (2%-10%) based on failure count
     *      Example: 10 failures → 2% + (10-10)*1% = 2%
     *               11 failures → 2% + (11-10)*1% = 3%
     *               20 failures → 2% + (20-10)*1% = 12% capped at 10%
     */
    function _slashCommunity(address community) internal {
        CommunityStake storage stake = communityStakes[community];
        NodeType nodeType = communities[community].nodeType;
        NodeTypeConfig memory config = nodeTypeConfigs[nodeType];

        // Calculate progressive slash percentage
        uint256 excessFailures = stake.failureCount > config.slashThreshold
            ? stake.failureCount - config.slashThreshold
            : 0;
        uint256 slashPercentage = config.slashBase + (excessFailures * config.slashIncrement);

        // Cap at maximum
        if (slashPercentage > config.slashMax) {
            slashPercentage = config.slashMax;
        }

        // Calculate slash amount
        uint256 slashAmount = stake.stGTokenLocked * slashPercentage / 100;

        // Execute slash via GTokenStaking
        uint256 slashed = GTOKEN_STAKING.slash(
            community,
            slashAmount,
            string(abi.encodePacked(
                "Registry v2.1 progressive slash: ",
                _toString(stake.failureCount),
                " failures, ",
                _toString(slashPercentage),
                "% penalty"
            ))
        );

        // Update state
        stake.stGTokenLocked -= slashed;
        stake.totalSlashed += slashed;
        stake.failureCount = 0;  // Reset counter after slash

        // Deactivate if stake too low (50% of minimum)
        if (stake.stGTokenLocked < config.minStake / 2) {
            stake.isActive = false;
            communities[community].isActive = false;
            emit CommunityDeactivated(community, "Insufficient stake after slash");
        }

        emit CommunitySlashed(community, slashed, stake.stGTokenLocked, block.timestamp);
    }

    /**
     * @notice Reset failure count for a community (governance function)
     * @param community Community address
     * @dev Can only be called by contract owner
     */
    function resetFailureCount(address community) external onlyOwner {
        communityStakes[community].failureCount = 0;
        emit FailureCountReset(community, block.timestamp);
    }

    /**
     * @notice Set oracle address for failure reporting
     * @param _oracle New oracle address
     * @dev Can only be called by contract owner
     */
    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) {
            revert InvalidAddress(_oracle);
        }
        address oldOracle = oracle;
        oracle = _oracle;
        emit OracleUpdated(oldOracle, _oracle);
    }

    /**
     * @notice Set SuperPaymaster v2 contract address (for Super mode)
     * @param _superPaymasterV2 New SuperPaymaster v2 contract address
     * @dev Can only be called by contract owner
     */
    function setSuperPaymasterV2(address _superPaymasterV2) external onlyOwner {
        if (_superPaymasterV2 == address(0)) {
            revert InvalidAddress(_superPaymasterV2);
        }
        superPaymasterV2 = _superPaymasterV2;
        emit SuperPaymasterV2Updated(_superPaymasterV2);
    }

    /**
     * @notice Configure node type settings (governance)
     * @param nodeType Node type to configure
     * @param config Configuration for this node type
     * @dev Can only be called by contract owner
     *      Allows adjusting min stake, slash thresholds, and penalties
     */
    function configureNodeType(
        NodeType nodeType,
        NodeTypeConfig calldata config
    ) external onlyOwner {
        require(config.minStake > 0, "Min stake must be > 0");
        require(config.slashThreshold > 0, "Slash threshold must be > 0");
        require(config.slashMax >= config.slashBase, "Max must be >= base");

        nodeTypeConfigs[nodeType] = config;
        emit NodeTypeConfigured(nodeType, config.minStake, config.slashThreshold);
    }

    // ====================================
    // Internal Helpers
    // ====================================

    /**
     * @notice Convert string to lowercase (ASCII only)
     * @param str Input string
     * @return Lowercase string
     */
    function _toLowercase(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(strBytes.length);

        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] >= 0x41 && strBytes[i] <= 0x5A) {
                // Convert A-Z to a-z
                result[i] = bytes1(uint8(strBytes[i]) + 32);
            } else {
                result[i] = strBytes[i];
            }
        }

        return string(result);
    }

    /**
     * @notice Convert uint256 to string
     * @param value Input number
     * @return String representation of the number
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
