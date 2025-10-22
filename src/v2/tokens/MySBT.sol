// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title MySBT with sGToken Lock Mechanism
 * @notice Soul Bound Token for community identity using sGToken lock architecture
 * @dev ERC721 with transfer restrictions (non-transferable except mint/burn)
 *
 * v2.0-beta Changes:
 * - Uses GTokenStaking.lockStake() instead of directly holding GT
 * - Configurable lock amount and mint fee
 * - Creator governance for parameter adjustment
 * - Exit fee paid when burning SBT (0.1 sGToken default)
 *
 * Key Features:
 * - Non-transferable (Soul Bound)
 * - Per-community identity tracking
 * - Activity and contribution scoring
 * - sGToken lock for membership (default 0.3 sGT)
 * - GT burn fee for minting (default 0.1 GT)
 *
 * Architecture:
 * - UserProfile: Cross-community user data
 * - CommunityData: Per-community activity
 * - Lock via GTokenStaking: User's sGToken is locked, not GT
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

    /// @notice Contract creator (deployer, later transferred to multisig)
    address public creator;

    // ====================================
    // Configurable Parameters
    // ====================================

    /// @notice Lock amount: sGToken shares to lock (default 0.3 sGT)
    uint256 public minLockAmount = 0.3 ether;

    /// @notice Mint burn fee: GT to burn when minting (default 0.1 GT)
    uint256 public mintFee = 0.1 ether;

    // ====================================
    // Events
    // ====================================

    event SBTMinted(
        address indexed user,
        address indexed community,
        uint256 tokenId,
        uint256 sGTokenLocked,
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
        uint256 exitFeePaid,
        uint256 sGTokenReturned,
        uint256 timestamp
    );

    event SuperPaymasterSet(
        address indexed oldAddress,
        address indexed newAddress
    );

    event MinLockAmountUpdated(
        uint256 oldAmount,
        uint256 newAmount
    );

    event MintFeeUpdated(
        uint256 oldFee,
        uint256 newFee
    );

    event CreatorTransferred(
        address indexed oldCreator,
        address indexed newCreator
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
    error InvalidParameter(string param);

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
        creator = msg.sender;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Mint SBT for community membership
     * @param community Community address
     * @return tokenId Minted token ID
     * @dev v2.0-beta: Locks sGToken via GTokenStaking instead of holding GT
     *      Requires user to have staked GT and obtained sGToken first
     */
    function mintSBT(address community) external returns (uint256 tokenId) {
        if (userCommunityToken[msg.sender][community] != 0) {
            revert AlreadyHasSBT(msg.sender, community);
        }

        if (community == address(0)) {
            revert InvalidAddress(community);
        }

        // ✅ NEW: Lock sGToken via GTokenStaking
        IGTokenStaking(GTOKEN_STAKING).lockStake(
            msg.sender,
            minLockAmount,
            "MySBT membership"
        );

        // Burn mint fee (in GT, not sGToken)
        if (mintFee > 0) {
            IERC20(GTOKEN).transferFrom(msg.sender, address(this), mintFee);
            IGToken(GTOKEN).burn(mintFee);
        }

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

        emit SBTMinted(msg.sender, community, tokenId, minLockAmount, block.timestamp);
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
     * @notice Burn SBT and unlock sGToken
     * @param tokenId Token ID to burn
     * @dev v2.0-beta: Unlocks sGToken via GTokenStaking (pays exit fee)
     *      User loses community membership but keeps reputation score
     */
    function burnSBT(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) {
            revert NotSBTOwner(msg.sender, tokenId);
        }

        address community = sbtData[tokenId].community;

        // ✅ NEW: Unlock sGToken (pays exit fee to treasury)
        uint256 netAmount = IGTokenStaking(GTOKEN_STAKING).unlockStake(
            msg.sender,
            minLockAmount
        );

        uint256 exitFee = minLockAmount - netAmount;

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

        emit SBTBurned(msg.sender, tokenId, exitFee, netAmount, block.timestamp);
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
    // Governance Functions
    // ====================================

    /**
     * @notice Set minimum lock amount (only creator)
     * @param newAmount New lock amount in sGToken shares
     */
    function setMinLockAmount(uint256 newAmount) external {
        if (msg.sender != creator) {
            revert Unauthorized(msg.sender);
        }

        if (newAmount < 0.01 ether || newAmount > 10 ether) {
            revert InvalidParameter("minLockAmount");
        }

        uint256 oldAmount = minLockAmount;
        minLockAmount = newAmount;

        emit MinLockAmountUpdated(oldAmount, newAmount);
    }

    /**
     * @notice Set mint fee (only creator)
     * @param newFee New mint fee in GT
     */
    function setMintFee(uint256 newFee) external {
        if (msg.sender != creator) {
            revert Unauthorized(msg.sender);
        }

        if (newFee > 1 ether) {
            revert InvalidParameter("mintFee");
        }

        uint256 oldFee = mintFee;
        mintFee = newFee;

        emit MintFeeUpdated(oldFee, newFee);
    }

    /**
     * @notice Transfer creator role (only creator)
     * @param newCreator New creator address
     * @dev Use this to transfer to community multisig
     */
    function transferCreator(address newCreator) external {
        if (msg.sender != creator) {
            revert Unauthorized(msg.sender);
        }

        if (newCreator == address(0)) {
            revert InvalidAddress(newCreator);
        }

        address oldCreator = creator;
        creator = newCreator;

        emit CreatorTransferred(oldCreator, newCreator);
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set SuperPaymaster address (owner only)
     * @param _superPaymaster SuperPaymaster address
     */
    function setSuperPaymaster(address _superPaymaster) external {
        // Simple creator check
        require(msg.sender == creator, "Only creator");

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
        returns (CommunityData memory)
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
        returns (uint256[] memory)
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
        returns (UserProfile memory)
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
    function totalSupply() external view returns (uint256) {
        return nextTokenId - 1;
    }

    /**
     * @notice Preview exit cost when burning SBT
     * @param user User address
     * @return exitFee Exit fee in sGToken shares
     * @return netReturn Net sGToken returned after fee
     */
    function previewExit(address user) external view returns (
        uint256 exitFee,
        uint256 netReturn
    ) {
        (exitFee, netReturn) = IGTokenStaking(GTOKEN_STAKING).previewExitFee(
            user,
            address(this)
        );
    }
}
