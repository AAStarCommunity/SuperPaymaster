// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Registry
 * @notice Community metadata storage and routing system for SuperPaymaster v2.0
 * @dev Stores all community information (name, ENS, social links, token addresses)
 *      and routes users to appropriate Paymaster (INDEPENDENT or SUPER mode)
 */
contract Registry is Ownable {

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

    // ====================================
    // Storage
    // ====================================

    /// @notice Main storage: community address => profile
    mapping(address => CommunityProfile) public communities;

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
        PaymasterMode mode
    );

    event CommunityUpdated(
        address indexed community,
        string name
    );

    event CommunityDeactivated(
        address indexed community
    );

    event CommunityReactivated(
        address indexed community
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

    // ====================================
    // Constructor
    // ====================================

    constructor() Ownable(msg.sender) {}

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register a new community profile
     * @param profile Complete community profile data
     * @dev Caller becomes the community admin address
     */
    function registerCommunity(CommunityProfile memory profile) external {
        address communityAddress = msg.sender;

        // Validation
        if (communities[communityAddress].registeredAt != 0) {
            revert CommunityAlreadyRegistered(communityAddress);
        }

        if (bytes(profile.name).length == 0) {
            revert("Name cannot be empty");
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
            profile.mode
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

        emit CommunityDeactivated(communityAddress);
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
        returns (address[] memory communities)
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
        communities = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            communities[i] = communityList[offset + i];
        }
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
}
