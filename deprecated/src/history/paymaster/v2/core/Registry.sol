// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title Registry v2.2.1 (Auto-Register + Duplicate Prevention)
 * @notice Community metadata storage with auto-stake registration
 * @dev v2.2.0: Added MySBT-style auto-stake pattern: approve + stake + lock + register in one transaction
 * @dev v2.2.1: Added isRegistered mapping to prevent duplicate entries in communityList
 */
contract Registry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Node type
    enum NodeType {
        PAYMASTER_AOA,      // 0: AOA independent Paymaster
        PAYMASTER_SUPER,    // 1: SuperPaymaster v2 shared mode
        ANODE,              // 2: Community computation node
        KMS                 // 3: Key Management Service node
    }

    /// @notice Node type configuration
    struct NodeTypeConfig {
        uint256 minStake;
        uint256 slashThreshold;
        uint256 slashBase;
        uint256 slashIncrement;
        uint256 slashMax;
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

    // ====================================
    // Constants
    // ====================================

    uint256 public constant MAX_SUPPORTED_SBTS = 10;
    uint256 public constant MAX_NAME_LENGTH = 100;
    string public constant VERSION = "2.2.1";
    uint256 public constant VERSION_CODE = 20201;

    // ====================================
    // Storage
    // ====================================

    IERC20 public immutable GTOKEN;
    IGTokenStaking public immutable GTOKEN_STAKING;
    address public oracle;
    address public superPaymasterV2;
    mapping(NodeType => NodeTypeConfig) public nodeTypeConfigs;
    mapping(address => CommunityProfile) public communities;
    mapping(address => CommunityStake) public communityStakes;
    mapping(string => address) public communityByName;
    mapping(string => address) public communityByENS;
    mapping(address => address) public communityBySBT;
    address[] public communityList;

    /// @notice Track registered communities to prevent duplicates
    /// @dev v2.2.1: Added to solve duplicate entries in communityList
    mapping(address => bool) public isRegistered;

    // ====================================
    // Events
    // ====================================

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
    error NameEmpty();
    error NotFound();
    error InsufficientGTokenBalance(uint256 available, uint256 required);
    error AutoStakeFailed(string reason);

    // ====================================
    // Constructor
    // ====================================

    constructor(address _gtoken, address _gtokenStaking) Ownable(msg.sender) {
        if (_gtoken == address(0)) revert InvalidAddress(_gtoken);
        if (_gtokenStaking == address(0)) revert InvalidAddress(_gtokenStaking);
        GTOKEN = IERC20(_gtoken);
        GTOKEN_STAKING = IGTokenStaking(_gtokenStaking);

        // PAYMASTER_AOA: 30 GT, 10 failures, 2%-10%
        nodeTypeConfigs[NodeType.PAYMASTER_AOA] = NodeTypeConfig(30 ether, 10, 2, 1, 10);
        // PAYMASTER_SUPER: 50 GT, 10 failures, 2%-10%
        nodeTypeConfigs[NodeType.PAYMASTER_SUPER] = NodeTypeConfig(50 ether, 10, 2, 1, 10);
        // ANODE: 20 GT, 15 failures, 1%-5%
        nodeTypeConfigs[NodeType.ANODE] = NodeTypeConfig(20 ether, 15, 1, 1, 5);
        // KMS: 100 GT, 5 failures, 5%-20%
        nodeTypeConfigs[NodeType.KMS] = NodeTypeConfig(100 ether, 5, 5, 2, 20);
    }

    // ====================================
    // Core Functions
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

        NodeTypeConfig memory config = nodeTypeConfigs[profile.nodeType];

        // Check stake requirement
        if (stGTokenAmount > 0) {
            if (stGTokenAmount < config.minStake) revert InsufficientStake(stGTokenAmount, config.minStake);
            GTOKEN_STAKING.lockStake(msg.sender, stGTokenAmount, "Registry registration");
        } else {
            uint256 existingLock = GTOKEN_STAKING.getLockedStake(msg.sender, address(this));
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
        communityStakes[communityAddress] = CommunityStake({
            stGTokenLocked: stGTokenAmount > 0 ? stGTokenAmount : GTOKEN_STAKING.getLockedStake(msg.sender, address(this)),
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

        NodeTypeConfig memory config = nodeTypeConfigs[communities[community].nodeType];
        if (stake.failureCount >= config.slashThreshold) {
            _slashCommunity(community);
        }
    }

    function _slashCommunity(address community) internal {
        CommunityStake storage stake = communityStakes[community];
        NodeType nodeType = communities[community].nodeType;
        NodeTypeConfig memory config = nodeTypeConfigs[nodeType];

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

    function configureNodeType(NodeType nodeType, NodeTypeConfig calldata config) external onlyOwner {
        require(config.minStake > 0, "Min stake must be > 0");
        require(config.slashThreshold > 0, "Threshold must be > 0");
        require(config.slashMax >= config.slashBase, "Max >= base");
        nodeTypeConfigs[nodeType] = config;
        emit NodeTypeConfigured(nodeType, config.minStake, config.slashThreshold);
    }

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

    /**
     * @notice Register community with auto-stake (one transaction)
     * @param profile Community profile
     * @param stakeAmount Amount to stake and lock
     * @dev User must approve this contract for GToken first
     *      This function will:
     *      1. Check user's available balance
     *      2. If insufficient, pull GToken from user and stake for them
     *      3. Register community (which locks the stake)
     *
     * IMPORTANT: This function combines auto-stake + register logic inline
     * to avoid external call issues and maintain proper msg.sender context
     */
    function registerCommunityWithAutoStake(
        CommunityProfile memory profile,
        uint256 stakeAmount
    ) external nonReentrant {
        address communityAddress = msg.sender;

        // === Validation checks (same as registerCommunity) ===
        // v2.2.1: Check isRegistered mapping to prevent duplicates
        if (isRegistered[communityAddress]) revert CommunityAlreadyRegistered(communityAddress);
        if (communities[communityAddress].registeredAt != 0) revert CommunityAlreadyRegistered(communityAddress);
        if (bytes(profile.name).length == 0) revert NameEmpty();
        if (bytes(profile.name).length > MAX_NAME_LENGTH) revert InvalidParameter("Name too long");
        if (profile.supportedSBTs.length > MAX_SUPPORTED_SBTS) revert InvalidParameter("Too many SBTs");

        NodeTypeConfig memory config = nodeTypeConfigs[profile.nodeType];
        if (stakeAmount < config.minStake) revert InsufficientStake(stakeAmount, config.minStake);

        // === Auto-stake logic ===
        uint256 autoStaked = _autoStakeForUser(msg.sender, stakeAmount);

        // === Lock stake ===
        GTOKEN_STAKING.lockStake(msg.sender, stakeAmount, "Registry registration");

        // === Name and ENS uniqueness checks ===
        string memory lowercaseName = _toLowercase(profile.name);
        if (communityByName[lowercaseName] != address(0)) revert NameAlreadyTaken(profile.name);

        if (bytes(profile.ensName).length > 0) {
            if (communityByENS[profile.ensName] != address(0)) revert ENSAlreadyTaken(profile.ensName);
        }

        // === Set profile data ===
        profile.community = communityAddress;
        profile.registeredAt = block.timestamp;
        profile.lastUpdatedAt = block.timestamp;
        profile.isActive = true;
        profile.allowPermissionlessMint = true;

        communities[communityAddress] = profile;
        communityStakes[communityAddress] = CommunityStake({
            stGTokenLocked: stakeAmount,
            failureCount: 0,
            lastFailureTime: 0,
            totalSlashed: 0,
            isActive: true
        });

        // === Update indices ===
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

        // === Emit events ===
        emit CommunityRegistered(communityAddress, profile.name, profile.nodeType, stakeAmount);
        emit CommunityRegisteredWithAutoStake(
            msg.sender,
            profile.name,
            stakeAmount,
            autoStaked
        );
    }
}
