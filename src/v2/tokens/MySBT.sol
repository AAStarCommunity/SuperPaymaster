// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title MySBT
 * @notice Soul Bound Token for community identity and activity tracking
 * @dev ERC721 with transfer restrictions (non-transferable except mint/burn)
 *
 * Key Features:
 * - Non-transferable (Soul Bound)
 * - Per-community identity tracking
 * - Activity and contribution scoring
 * - 0.2 GT stake + 0.1 GT burn fee for minting
 *
 * Architecture:
 * - UserProfile: Cross-community user data
 * - CommunityData: Per-community activity (community field, not operator!)
 * - Mint requires: 0.3 GT total (0.2 stake + 0.1 burn)
 *
 * Use Cases:
 * - Community membership verification
 * - Access control for SuperPaymaster
 * - Reputation and contribution tracking
 * - Multi-community user profiles
 */
contract MySBT is ERC721 {

    // ====================================
    // Structs
    // ====================================

    /// @notice User's cross-community profile
    struct UserProfile {
        uint256[] ownedSBTs;            // List of SBT token IDs
        uint256 reputationScore;        // Total reputation score
        string ensName;                 // User's ENS name (optional)
    }

    /// @notice Per-community activity data
    struct CommunityData {
        address community;              // Community address (NOT operator!)
        uint256 txCount;                // Transaction count in this community
        uint256 joinedAt;               // Join timestamp
        uint256 lastActiveTime;         // Last activity timestamp
        uint256 contributionScore;      // Contribution score
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice User profiles mapping
    mapping(address => UserProfile) public userProfiles;

    /// @notice SBT data: tokenId => community data
    mapping(uint256 => CommunityData) public sbtData;

    /// @notice User-community-token mapping: user => community => tokenId
    mapping(address => mapping(address => uint256)) public userCommunityToken;

    /// @notice GToken contract address
    address public immutable GTOKEN;

    /// @notice GTokenStaking contract address
    address public immutable GTOKEN_STAKING;

    /// @notice SuperPaymaster address (for updateActivity)
    address public SUPERPAYMASTER;

    /// @notice Next token ID
    uint256 public nextTokenId = 1;

    /// @notice Mint stake amount: 0.2 GT
    uint256 public constant MINT_STAKE = 0.2 ether;

    /// @notice Mint burn fee: 0.1 GT
    uint256 public constant MINT_FEE = 0.1 ether;

    // ====================================
    // Events
    // ====================================

    event SBTMinted(
        address indexed user,
        address indexed community,
        uint256 tokenId,
        uint256 timestamp
    );

    event ActivityUpdated(
        address indexed user,
        address indexed community,
        uint256 txCount,
        uint256 contributionScore
    );

    event SBTBurned(
        address indexed user,
        uint256 tokenId,
        uint256 timestamp
    );

    event SuperPaymasterSet(
        address indexed oldAddress,
        address indexed newAddress
    );

    // ====================================
    // Errors
    // ====================================

    error AlreadyHasSBT(address user, address community);
    error NoSBTFound(address user, address community);
    error NotSBTOwner(address caller, uint256 tokenId);
    error TransferNotAllowed();
    error Unauthorized(address caller);
    error InvalidAddress(address addr);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize MySBT contract
     * @param _gtoken GToken ERC20 address
     * @param _staking GTokenStaking address
     */
    constructor(address _gtoken, address _staking)
        ERC721("Community Soul Bound Token", "MySBT")
    {
        if (_gtoken == address(0) || _staking == address(0)) {
            revert InvalidAddress(address(0));
        }

        GTOKEN = _gtoken;
        GTOKEN_STAKING = _staking;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Mint SBT for community membership
     * @param community Community address
     * @return tokenId Minted token ID
     * @dev Requires 0.3 GT total: 0.2 GT stake + 0.1 GT burn
     */
    function mintSBT(address community) external returns (uint256 tokenId) {
        if (userCommunityToken[msg.sender][community] != 0) {
            revert AlreadyHasSBT(msg.sender, community);
        }

        if (community == address(0)) {
            revert InvalidAddress(community);
        }

        // Transfer 0.3 GT from user
        IERC20(GTOKEN).transferFrom(
            msg.sender,
            address(this),
            MINT_STAKE + MINT_FEE
        );

        // Stake 0.2 GT
        IERC20(GTOKEN).approve(GTOKEN_STAKING, MINT_STAKE);
        IGTokenStaking(GTOKEN_STAKING).stake(MINT_STAKE);

        // Burn 0.1 GT
        IGToken(GTOKEN).burn(MINT_FEE);

        // Mint SBT
        tokenId = nextTokenId++;
        _mint(msg.sender, tokenId);

        // Initialize community data
        sbtData[tokenId] = CommunityData({
            community: community,
            txCount: 0,
            joinedAt: block.timestamp,
            lastActiveTime: block.timestamp,
            contributionScore: 0
        });

        // Update user profile
        userProfiles[msg.sender].ownedSBTs.push(tokenId);
        userCommunityToken[msg.sender][community] = tokenId;

        emit SBTMinted(msg.sender, community, tokenId, block.timestamp);
    }

    /**
     * @notice Update user activity (only SuperPaymaster)
     * @param user User address
     * @param community Community address
     * @param txCost Transaction cost in wei
     * @dev Called by SuperPaymaster after each sponsored transaction
     */
    function updateActivity(
        address user,
        address community,
        uint256 txCost
    ) external {
        if (msg.sender != SUPERPAYMASTER) {
            revert Unauthorized(msg.sender);
        }

        uint256 tokenId = userCommunityToken[user][community];
        if (tokenId == 0) {
            revert NoSBTFound(user, community);
        }

        // Update community data
        sbtData[tokenId].txCount += 1;
        sbtData[tokenId].lastActiveTime = block.timestamp;
        sbtData[tokenId].contributionScore += txCost / 1e15; // Scale: 1e15 = 1 point

        // Update user reputation
        userProfiles[user].reputationScore += 1;

        emit ActivityUpdated(
            user,
            community,
            sbtData[tokenId].txCount,
            sbtData[tokenId].contributionScore
        );
    }

    /**
     * @notice Burn SBT (owner only)
     * @param tokenId Token ID to burn
     * @dev User loses community membership but keeps reputation score
     */
    function burnSBT(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) {
            revert NotSBTOwner(msg.sender, tokenId);
        }

        address community = sbtData[tokenId].community;

        // Clean up mappings
        delete sbtData[tokenId];
        delete userCommunityToken[msg.sender][community];

        // Remove from user's owned SBTs
        uint256[] storage ownedSBTs = userProfiles[msg.sender].ownedSBTs;
        for (uint256 i = 0; i < ownedSBTs.length; i++) {
            if (ownedSBTs[i] == tokenId) {
                ownedSBTs[i] = ownedSBTs[ownedSBTs.length - 1];
                ownedSBTs.pop();
                break;
            }
        }

        _burn(tokenId);

        emit SBTBurned(msg.sender, tokenId, block.timestamp);
    }

    // ====================================
    // Non-Transferable Logic
    // ====================================

    /**
     * @notice Override _update to prevent transfers (Soul Bound)
     * @dev Only allows mint (from=0) and burn (to=0)
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow mint (from == address(0))
        // Allow burn (to == address(0))
        // Disallow all other transfers
        if (from != address(0) && to != address(0)) {
            revert TransferNotAllowed();
        }

        return super._update(to, tokenId, auth);
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set SuperPaymaster address (owner only)
     * @param _superPaymaster SuperPaymaster address
     */
    function setSuperPaymaster(address _superPaymaster) external {
        // Simple owner check: deployer is initial owner
        // In production, should use Ownable pattern
        require(msg.sender == _getInitialOwner(), "Only owner");

        if (_superPaymaster == address(0)) {
            revert InvalidAddress(_superPaymaster);
        }

        address oldAddress = SUPERPAYMASTER;
        SUPERPAYMASTER = _superPaymaster;

        emit SuperPaymasterSet(oldAddress, _superPaymaster);
    }

    /**
     * @notice Set user ENS name
     * @param ensName ENS domain name
     */
    function setENSName(string memory ensName) external {
        userProfiles[msg.sender].ensName = ensName;
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get user's community data
     * @param user User address
     * @param community Community address
     * @return data Community data
     */
    function getCommunityData(address user, address community)
        external
        view
        returns (CommunityData memory data)
    {
        uint256 tokenId = userCommunityToken[user][community];
        if (tokenId == 0) {
            revert NoSBTFound(user, community);
        }

        return sbtData[tokenId];
    }

    /**
     * @notice Get all SBT token IDs owned by user
     * @param user User address
     * @return tokenIds Array of token IDs
     */
    function getUserSBTs(address user)
        external
        view
        returns (uint256[] memory tokenIds)
    {
        return userProfiles[user].ownedSBTs;
    }

    /**
     * @notice Get user profile
     * @param user User address
     * @return profile User profile
     */
    function getUserProfile(address user)
        external
        view
        returns (UserProfile memory profile)
    {
        return userProfiles[user];
    }

    /**
     * @notice Check if user has SBT for community
     * @param user User address
     * @param community Community address
     * @return hasSBT True if user has SBT
     */
    function hasSBT(address user, address community)
        external
        view
        returns (bool)
    {
        return userCommunityToken[user][community] != 0;
    }

    /**
     * @notice Get SBT metadata
     * @param tokenId Token ID
     * @return owner Token owner
     * @return data Community data
     */
    function getSBTMetadata(uint256 tokenId)
        external
        view
        returns (address owner, CommunityData memory data)
    {
        owner = ownerOf(tokenId);
        data = sbtData[tokenId];
    }

    /**
     * @notice Get total supply
     * @return supply Total minted SBTs
     */
    function totalSupply() external view returns (uint256 supply) {
        return nextTokenId - 1;
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Get initial contract owner (deployer)
     * @return owner Deployer address
     */
    function _getInitialOwner() internal view returns (address owner) {
        // Simplified: In production, use proper Ownable pattern
        // For now, we'll need to track deployer in constructor
        // This is a placeholder
        assembly {
            // Return first storage slot or implement proper ownership
            owner := sload(0)
        }
    }
}
