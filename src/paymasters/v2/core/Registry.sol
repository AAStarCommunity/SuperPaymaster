// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title Registry
 * @notice Community metadata storage, staking management, and slash system for SuperPaymaster v2.0
 * @dev Stores all community information and enforces reputation through stGToken locks
 *
 * Key Features:
 * - Atomic registration: metadata + stGToken lock in one transaction
 * - Failure monitoring and automatic slash triggers
 * - Support for both AOA (INDEPENDENT) and Super mode
 *
 * Architecture:
 * - Registry stores metadata and triggers slash
 * - GTokenStaking executes lock and slash operations
 * - Oracle reports failures for monitoring
 */
contract Registry is Ownable, ReentrancyGuard {

    /// @notice Paymaster operation mode
    enum PaymasterMode {
        INDEPENDENT,  // Traditional独立Paymaster
        SUPER         // SuperPaymaster v2.0共享模式
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

        // Paymaster configuration
        PaymasterMode mode;             // INDEPENDENT or SUPER
        address paymasterAddress;       // Paymaster contract address
        address community;              // Community admin address

        // Metadata
        uint256 registeredAt;           // Registration timestamp
        uint256 lastUpdatedAt;          // Last update timestamp
        bool isActive;                  // Active status
        uint256 memberCount;            // Number of members (optional)
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
    // Constants
    // ====================================

    /// @notice Minimum stGToken stake for AOA (INDEPENDENT) mode
    uint256 public constant MIN_STAKE_AOA = 30 ether;

    /// @notice Minimum stGToken stake for Super mode
    uint256 public constant MIN_STAKE_SUPER = 50 ether;

    /// @notice Failure threshold to trigger slash
    uint256 public constant SLASH_THRESHOLD = 10;

    /// @notice Slash percentage (10%)
    uint256 public constant SLASH_PERCENTAGE = 10;

    // ====================================
    // Storage
    // ====================================

    /// @notice GTokenStaking contract
    IGTokenStaking public immutable GTOKEN_STAKING;

    /// @notice Oracle address (can report failures)
    address public oracle;

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

    // ====================================
    // Errors
    // ====================================

    error CommunityAlreadyRegistered(address community);
    error CommunityNotRegistered(address community);
    error NameAlreadyTaken(string name);
    error ENSAlreadyTaken(string ensName);
    error InvalidAddress(address addr);
    error CommunityNotActive(address community);
    error InsufficientStake(uint256 provided, uint256 required);
    error UnauthorizedOracle(address caller);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize Registry with GTokenStaking contract
     * @param _gtokenStaking GTokenStaking contract address
     */
    constructor(address _gtokenStaking) Ownable(msg.sender) {
        if (_gtokenStaking == address(0)) {
            revert InvalidAddress(_gtokenStaking);
        }
        GTOKEN_STAKING = IGTokenStaking(_gtokenStaking);
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

        // Check minimum stake requirement (except for Super mode with existing lock)
        if (profile.mode == PaymasterMode.INDEPENDENT) {
            // AOA mode MUST lock stGToken here
            if (stGTokenAmount < MIN_STAKE_AOA) {
                revert InsufficientStake(stGTokenAmount, MIN_STAKE_AOA);
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
                if (stGTokenAmount < MIN_STAKE_SUPER) {
                    revert InsufficientStake(stGTokenAmount, MIN_STAKE_SUPER);
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
                if (existingLock < MIN_STAKE_SUPER) {
                    revert InsufficientStake(existingLock, MIN_STAKE_SUPER);
                }
            }
        }

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

        // Trigger slash if threshold reached
        if (stake.failureCount >= SLASH_THRESHOLD) {
            _slashCommunity(community);
        }
    }

    /**
     * @notice Internal function to slash community's stGToken
     * @param community Community address to slash
     * @dev Slashes SLASH_PERCENTAGE of locked stake and resets failure count
     */
    function _slashCommunity(address community) internal {
        CommunityStake storage stake = communityStakes[community];

        // Calculate slash amount (10% of locked stake)
        uint256 slashAmount = stake.stGTokenLocked * SLASH_PERCENTAGE / 100;

        // Execute slash via GTokenStaking
        uint256 slashed = GTOKEN_STAKING.slash(
            community,
            slashAmount,
            string(abi.encodePacked(
                "Registry slash: ",
                _toString(stake.failureCount),
                " consecutive failures"
            ))
        );

        // Update state
        stake.stGTokenLocked -= slashed;
        stake.totalSlashed += slashed;
        stake.failureCount = 0;  // Reset counter after slash

        // Deactivate if stake too low
        if (stake.stGTokenLocked < MIN_STAKE_AOA / 2) {
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
