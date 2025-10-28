// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IMySBT
 * @notice Interface for MySBT v2.1 - White-label Soul Bound Token
 * @dev One SBT per user, multiple community memberships
 */
interface IMySBT {
    // ====================================
    // Structs
    // ====================================

    struct SBTData {
        address holder;
        address firstCommunity;    // Immutable, first issuing community
        uint256 mintedAt;
        uint256 totalCommunities;
    }

    struct CommunityMembership {
        address community;
        uint256 joinedAt;
        uint256 lastActiveTime;   // DEPRECATED in v2.2: Use The Graph to query ActivityRecorded events
        bool isActive;
        string metadata;          // IPFS URI for community data
    }

    struct NFTBinding {
        address nftContract;
        uint256 nftTokenId;
        uint256 bindTime;
        bool isActive;
    }

    struct AvatarSetting {
        address nftContract;
        uint256 nftTokenId;
        bool isCustom;  // true=manual, false=auto
    }

    // ====================================
    // Events
    // ====================================

    event SBTMinted(
        address indexed user,
        uint256 indexed tokenId,
        address indexed firstCommunity,
        uint256 timestamp
    );

    event MembershipAdded(
        uint256 indexed tokenId,
        address indexed community,
        string metadata,
        uint256 timestamp
    );

    event MembershipDeactivated(
        uint256 indexed tokenId,
        address indexed community,
        uint256 timestamp
    );

    event NFTBound(
        uint256 indexed tokenId,
        address indexed community,
        address nftContract,
        uint256 nftTokenId,
        uint256 timestamp
    );

    event NFTUnbound(
        uint256 indexed tokenId,
        address indexed community,
        address nftContract,
        uint256 nftTokenId,
        uint256 timestamp
    );

    event AvatarSet(
        uint256 indexed tokenId,
        address nftContract,
        uint256 nftTokenId,
        bool isCustom,
        uint256 timestamp
    );

    event ActivityRecorded(
        uint256 indexed tokenId,
        address indexed community,
        uint256 week,
        uint256 timestamp
    );

    event ReputationCalculatorUpdated(
        address indexed oldCalculator,
        address indexed newCalculator,
        uint256 timestamp
    );

    // ✅ v2.3: Enhanced admin events
    event ContractPaused(address indexed by, uint256 timestamp);
    event ContractUnpaused(address indexed by, uint256 timestamp);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry, uint256 timestamp);
    event MinLockAmountUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee, uint256 timestamp);
    event DAOMultisigUpdated(address indexed oldDAO, address indexed newDAO, uint256 timestamp);

    // ====================================
    // Errors (v2.3)
    // ====================================

    error ActivityTooFrequent(uint256 tokenId, address community, uint256 nextAllowedTime);

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Mint SBT or add community membership (idempotent)
     * @param user User address to mint for
     * @param metadata IPFS URI for community-specific metadata
     * @return tokenId SBT token ID (new or existing)
     * @return isNewMint True if new SBT was created, false if membership added
     */
    function mintOrAddMembership(address user, string memory metadata)
        external
        returns (uint256 tokenId, bool isNewMint);

    /**
     * @notice Verify user has active membership in community
     * @param user User address
     * @param community Community address
     * @return isValid True if user has active membership
     */
    function verifyCommunityMembership(address user, address community)
        external
        view
        returns (bool isValid);

    /**
     * @notice Get user's SBT token ID
     * @param user User address
     * @return tokenId Token ID (0 if no SBT)
     */
    function getUserSBT(address user) external view returns (uint256 tokenId);

    /**
     * @notice Get SBT data
     * @param tokenId Token ID
     * @return data SBT data struct
     */
    function getSBTData(uint256 tokenId) external view returns (SBTData memory data);

    /**
     * @notice Get all community memberships for an SBT
     * @param tokenId Token ID
     * @return memberships Array of community memberships
     */
    function getMemberships(uint256 tokenId)
        external
        view
        returns (CommunityMembership[] memory memberships);

    /**
     * @notice Get specific community membership
     * @param tokenId Token ID
     * @param community Community address
     * @return membership Community membership data
     */
    function getCommunityMembership(uint256 tokenId, address community)
        external
        view
        returns (CommunityMembership memory membership);

    // ====================================
    // NFT Binding Functions
    // ====================================

    /**
     * @notice Bind community NFT to SBT
     * @param community Community address
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     */
    function bindCommunityNFT(
        address community,
        address nftContract,
        uint256 nftTokenId
    ) external;

    /**
     * @notice Unbind community NFT from SBT
     * @param community Community address
     */
    function unbindCommunityNFT(address community) external;

    /**
     * @notice Get NFT binding for community
     * @param tokenId Token ID
     * @param community Community address
     * @return binding NFT binding data
     */
    function getNFTBinding(uint256 tokenId, address community)
        external
        view
        returns (NFTBinding memory binding);

    // ====================================
    // Avatar Functions
    // ====================================

    /**
     * @notice Set custom avatar
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     */
    function setAvatar(address nftContract, uint256 nftTokenId) external;

    /**
     * @notice Get avatar URI for SBT
     * @param tokenId Token ID
     * @return uri Avatar URI (from NFT or community default)
     */
    function getAvatarURI(uint256 tokenId) external view returns (string memory uri);

    /**
     * @notice Set community default avatar
     * @param avatarURI Default avatar URI
     */
    function setCommunityDefaultAvatar(string memory avatarURI) external;

    // ====================================
    // Reputation Functions
    // ====================================

    /**
     * @notice Record user activity (called by PaymasterV4)
     * @param user User address
     */
    function recordActivity(address user) external;

    /**
     * @notice Get community reputation score
     * @param user User address
     * @param community Community address
     * @return score Reputation score
     */
    function getCommunityReputation(address user, address community)
        external
        view
        returns (uint256 score);

    /**
     * @notice Get global reputation score
     * @param user User address
     * @return score Global reputation score
     */
    function getGlobalReputation(address user)
        external
        view
        returns (uint256 score);

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set reputation calculator contract
     * @param calculator Calculator contract address (0 = use default)
     */
    function setReputationCalculator(address calculator) external;

    /**
     * @notice Set minimum lock amount
     * @param amount Amount in wei
     */
    function setMinLockAmount(uint256 amount) external;

    /**
     * @notice Set mint fee
     * @param fee Fee amount in wei
     */
    function setMintFee(uint256 fee) external;

    /**
     * @notice Set DAO multisig address
     * @param newDAO New DAO address
     */
    function setDAOMultisig(address newDAO) external;

    /**
     * @notice Set Registry contract address
     * @param registry Registry contract address
     */
    function setRegistry(address registry) external;
}
