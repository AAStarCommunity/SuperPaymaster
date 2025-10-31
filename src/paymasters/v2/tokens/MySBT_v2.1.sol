// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/Interfaces.sol";
import "../interfaces/IMySBT.sol";
import "../interfaces/IReputationCalculator.sol";

/**
 * @title MySBT v2.1 - White-label Soul Bound Token
 * @notice One SBT per user, multiple community memberships
 * @dev Based on MySBTWithNFTBinding but with improved architecture
 *
 * Key Features:
 * - Idempotent mint: First call creates SBT, subsequent calls add community memberships
 * - Registry integration: Only registered communities can mint
 * - NFT binding: Communities can require NFT ownership for enhanced membership
 * - Reputation system: Default + pluggable external calculator
 * - Avatar system: Three-tier priority (custom > auto > community default)
 * - Activity tracking: Weekly activity records for reputation calculation
 * - DAO governance: Multi-sig control for parameters
 *
 * Architecture:
 * - One user = one SBT (not one per community)
 * - First community is immutably recorded
 * - Each community can add membership record
 * - NFT bindings are per-community
 * - Reputation is calculated per-community and globally
 */
contract MySBT_v2_1 is ERC721, ReentrancyGuard, IMySBT {
    using SafeERC20 for IERC20;

    // ====================================
    // Storage
    // ====================================

    /// @notice User to SBT token ID mapping (one SBT per user)
    mapping(address => uint256) public userToSBT;

    /// @notice SBT data (holder, first community, mint time, total communities)
    mapping(uint256 => SBTData) public sbtData;

    /// @notice Community memberships: tokenId => CommunityMembership[]
    mapping(uint256 => CommunityMembership[]) private _memberships;

    /// @notice Membership index: tokenId => community => array index
    mapping(uint256 => mapping(address => uint256)) public membershipIndex;

    /// @notice NFT bindings: tokenId => community => NFTBinding
    mapping(uint256 => mapping(address => NFTBinding)) public nftBindings;

    /// @notice SBT avatars: tokenId => AvatarSetting
    mapping(uint256 => AvatarSetting) public sbtAvatars;

    /// @notice Community default avatars: community => avatar URI
    mapping(address => string) public communityDefaultAvatar;

    /// @notice Weekly activity: DEPRECATED - Now using event-based tracking
    /// @dev This mapping is kept for backward compatibility but no longer updated
    mapping(uint256 => mapping(address => mapping(uint256 => bool))) public weeklyActivity;

    /// @notice Avatar delegation: nftContract => nftTokenId => delegatee => bool
    mapping(address => mapping(uint256 => mapping(address => bool))) public avatarDelegation;

    /// @notice NFT to SBT reverse mapping: nftContract => nftTokenId => tokenId
    mapping(address => mapping(uint256 => uint256)) public nftToSBT;

    // ====================================
    // Immutable Configuration
    // ====================================

    /// @notice GToken contract
    address public immutable GTOKEN;

    /// @notice GTokenStaking contract
    address public immutable GTOKEN_STAKING;

    // ====================================
    // Mutable Configuration
    // ====================================

    /// @notice Registry v2.1 contract (for community validation)
    address public REGISTRY;

    /// @notice DAO multisig address
    address public daoMultisig;

    /// @notice Reputation calculator (0 = use default)
    address public reputationCalculator;

    /// @notice Next token ID
    uint256 public nextTokenId = 1;

    /// @notice Minimum lock amount (default 0.3 sGToken)
    uint256 public minLockAmount = 0.3 ether;

    /// @notice Mint fee (default 0.1 GToken, burned)
    uint256 public mintFee = 0.1 ether;

    // ====================================
    // Constants
    // ====================================

    /// @notice Base reputation score
    uint256 public constant BASE_REPUTATION = 20;

    /// @notice NFT bonus per bound NFT
    uint256 public constant NFT_BONUS = 3;

    /// @notice Activity bonus per active week
    uint256 public constant ACTIVITY_BONUS = 1;

    /// @notice Activity tracking window (4 weeks)
    uint256 public constant ACTIVITY_WINDOW = 4;

    // ====================================
    // Errors
    // ====================================

    error Unauthorized(address caller);
    error InvalidAddress(address addr);
    error InvalidParameter(string param);
    error CommunityNotRegistered(address community);
    error MembershipNotFound(uint256 tokenId, address community);
    error MembershipAlreadyExists(uint256 tokenId, address community);
    error NFTAlreadyBound(address nftContract, uint256 nftTokenId);
    error NFTNotOwned(address user, address nftContract, uint256 nftTokenId);
    error NotAuthorizedForNFT(address user, address nftContract, uint256 nftTokenId);
    error TransferNotAllowed();
    error NoSBTFound(address user);

    // ====================================
    // Modifiers
    // ====================================

    modifier onlyDAO() {
        if (msg.sender != daoMultisig) revert Unauthorized(msg.sender);
        _;
    }

    modifier onlyRegisteredCommunity() {
        if (!_isValidCommunity(msg.sender)) {
            revert CommunityNotRegistered(msg.sender);
        }
        _;
    }

    // ====================================
    // Constructor
    // ====================================

    constructor(
        address _gtoken,
        address _staking,
        address _registry,
        address _dao
    ) ERC721("Mycelium Soul Bound Token", "MySBT") {
        if (_gtoken == address(0) || _staking == address(0)) {
            revert InvalidAddress(address(0));
        }
        if (_registry == address(0) || _dao == address(0)) {
            revert InvalidAddress(address(0));
        }

        GTOKEN = _gtoken;
        GTOKEN_STAKING = _staking;
        REGISTRY = _registry;
        daoMultisig = _dao;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Mint SBT or add community membership (idempotent)
     * @dev First call creates SBT + locks/burns tokens
     *      Subsequent calls just add community membership
     * @param user User address to mint for
     * @param metadata IPFS URI for community-specific metadata
     * @return tokenId SBT token ID (new or existing)
     * @return isNewMint True if new SBT was created
     */
    function mintOrAddMembership(address user, string memory metadata)
        external
        override
        nonReentrant
        onlyRegisteredCommunity
        returns (uint256 tokenId, bool isNewMint)
    {
        if (user == address(0)) revert InvalidAddress(user);

        tokenId = userToSBT[user];

        if (tokenId == 0) {
            // FIRST MINT: Create SBT
            tokenId = nextTokenId++;
            isNewMint = true;

            // Set SBT data
            sbtData[tokenId] = SBTData({
                holder: user,
                firstCommunity: msg.sender,  // Immutable record
                mintedAt: block.timestamp,
                totalCommunities: 1
            });

            // Map user to SBT
            userToSBT[user] = tokenId;

            // Add first community membership
            _memberships[tokenId].push(CommunityMembership({
                community: msg.sender,
                joinedAt: block.timestamp,
                lastActiveTime: block.timestamp,
                isActive: true,
                metadata: metadata
            }));

            membershipIndex[tokenId][msg.sender] = 0;

            // Lock stGToken (from user's staked balance)
            IGTokenStaking(GTOKEN_STAKING).lockStake(user, minLockAmount, "MySBT");

            // Burn GToken mint fee (user must approve first)
            IERC20(GTOKEN).safeTransferFrom(user, address(this), mintFee);
            IGToken(GTOKEN).burn(mintFee);

            // Mint SBT
            _mint(user, tokenId);

            emit SBTMinted(user, tokenId, msg.sender, block.timestamp);
        } else {
            // IDEMPOTENT: Add community membership
            isNewMint = false;

            // Check if membership already exists
            uint256 idx = membershipIndex[tokenId][msg.sender];
            if (idx < _memberships[tokenId].length &&
                _memberships[tokenId][idx].community == msg.sender) {
                revert MembershipAlreadyExists(tokenId, msg.sender);
            }

            // Add new membership
            _memberships[tokenId].push(CommunityMembership({
                community: msg.sender,
                joinedAt: block.timestamp,
                lastActiveTime: block.timestamp,
                isActive: true,
                metadata: metadata
            }));

            membershipIndex[tokenId][msg.sender] = _memberships[tokenId].length - 1;

            // Increment community count
            sbtData[tokenId].totalCommunities++;

            emit MembershipAdded(tokenId, msg.sender, metadata, block.timestamp);
        }

        return (tokenId, isNewMint);
    }

    /**
     * @notice Verify user has active membership in community
     * @param user User address
     * @param community Community address
     * @return isValid True if user has active membership
     */
    function verifyCommunityMembership(address user, address community)
        external
        view
        override
        returns (bool isValid)
    {
        uint256 tokenId = userToSBT[user];
        if (tokenId == 0) return false;

        uint256 idx = membershipIndex[tokenId][community];
        if (idx >= _memberships[tokenId].length) return false;

        CommunityMembership memory membership = _memberships[tokenId][idx];
        return membership.community == community && membership.isActive;
    }

    /**
     * @notice Get user's SBT token ID
     * @param user User address
     * @return tokenId Token ID (0 if no SBT)
     */
    function getUserSBT(address user) external view override returns (uint256 tokenId) {
        return userToSBT[user];
    }

    /**
     * @notice Get SBT data
     * @param tokenId Token ID
     * @return data SBT data struct
     */
    function getSBTData(uint256 tokenId) external view override returns (SBTData memory data) {
        return sbtData[tokenId];
    }

    /**
     * @notice Get all community memberships for an SBT
     * @param tokenId Token ID
     * @return memberships Array of community memberships
     */
    function getMemberships(uint256 tokenId)
        external
        view
        override
        returns (CommunityMembership[] memory memberships)
    {
        return _memberships[tokenId];
    }

    /**
     * @notice Get specific community membership
     * @param tokenId Token ID
     * @param community Community address
     * @return membership Community membership data
     */
    function getCommunityMembership(uint256 tokenId, address community)
        external
        view
        override
        returns (CommunityMembership memory membership)
    {
        uint256 idx = membershipIndex[tokenId][community];
        if (idx >= _memberships[tokenId].length) {
            revert MembershipNotFound(tokenId, community);
        }

        membership = _memberships[tokenId][idx];
        if (membership.community != community) {
            revert MembershipNotFound(tokenId, community);
        }

        return membership;
    }

    // ====================================
    // NFT Binding Functions
    // ====================================

    /**
     * @notice Bind community NFT to SBT
     * @dev User must own the NFT
     * @param community Community address
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     */
    function bindCommunityNFT(
        address community,
        address nftContract,
        uint256 nftTokenId
    ) external override nonReentrant {
        uint256 tokenId = userToSBT[msg.sender];
        if (tokenId == 0) revert NoSBTFound(msg.sender);

        // Verify community membership
        uint256 idx = membershipIndex[tokenId][community];
        if (idx >= _memberships[tokenId].length ||
            _memberships[tokenId][idx].community != community ||
            !_memberships[tokenId][idx].isActive) {
            revert MembershipNotFound(tokenId, community);
        }

        // Check NFT not already bound
        if (nftToSBT[nftContract][nftTokenId] != 0) {
            revert NFTAlreadyBound(nftContract, nftTokenId);
        }

        // Verify NFT ownership
        try IERC721(nftContract).ownerOf(nftTokenId) returns (address owner) {
            if (owner != msg.sender) {
                revert NFTNotOwned(msg.sender, nftContract, nftTokenId);
            }
        } catch {
            revert NFTNotOwned(msg.sender, nftContract, nftTokenId);
        }

        // Bind NFT
        nftBindings[tokenId][community] = NFTBinding({
            nftContract: nftContract,
            nftTokenId: nftTokenId,
            bindTime: block.timestamp,
            isActive: true
        });

        // Reverse mapping
        nftToSBT[nftContract][nftTokenId] = tokenId;

        // Auto-set avatar if no avatar set yet
        if (sbtAvatars[tokenId].nftContract == address(0)) {
            sbtAvatars[tokenId] = AvatarSetting({
                nftContract: nftContract,
                nftTokenId: nftTokenId,
                isCustom: false  // Auto-set
            });

            emit AvatarSet(tokenId, nftContract, nftTokenId, false, block.timestamp);
        }

        emit NFTBound(tokenId, community, nftContract, nftTokenId, block.timestamp);
    }

    /**
     * @notice Unbind community NFT from SBT
     * @param community Community address
     */
    function unbindCommunityNFT(address community) external nonReentrant {
        uint256 tokenId = userToSBT[msg.sender];
        if (tokenId == 0) revert NoSBTFound(msg.sender);

        NFTBinding memory binding = nftBindings[tokenId][community];
        if (!binding.isActive) {
            revert MembershipNotFound(tokenId, community);
        }

        // Deactivate binding
        nftBindings[tokenId][community].isActive = false;

        // Clear reverse mapping
        delete nftToSBT[binding.nftContract][binding.nftTokenId];

        // If this was the avatar and it was auto-set, clear it
        if (sbtAvatars[tokenId].nftContract == binding.nftContract &&
            sbtAvatars[tokenId].nftTokenId == binding.nftTokenId &&
            !sbtAvatars[tokenId].isCustom) {
            delete sbtAvatars[tokenId];
        }

        emit NFTUnbound(tokenId, community, binding.nftContract, binding.nftTokenId, block.timestamp);
    }

    /**
     * @notice Get NFT binding for community
     * @param tokenId Token ID
     * @param community Community address
     * @return binding NFT binding data
     */
    function getNFTBinding(uint256 tokenId, address community)
        external
        view
        returns (NFTBinding memory binding)
    {
        return nftBindings[tokenId][community];
    }

    /**
     * @notice Get all NFT bindings (v2.4.0+ interface compatibility)
     * @dev Not supported in v2.1 (community-level binding model)
     * @return bindings Empty array
     */
    function getAllNFTBindings(uint256 /* tokenId */)
        external
        pure
        returns (NFTBinding[] memory bindings)
    {
        return new NFTBinding[](0);
    }

    // ====================================
    // Avatar Functions
    // ====================================

    /**
     * @notice Set custom avatar
     * @dev User must own NFT or have delegation
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     */
    function setAvatar(address nftContract, uint256 nftTokenId) external override nonReentrant {
        uint256 tokenId = userToSBT[msg.sender];
        if (tokenId == 0) revert NoSBTFound(msg.sender);

        // Check authorization (owner or delegated)
        address nftOwner;
        try IERC721(nftContract).ownerOf(nftTokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            revert NFTNotOwned(msg.sender, nftContract, nftTokenId);
        }

        if (nftOwner != msg.sender &&
            !avatarDelegation[nftContract][nftTokenId][msg.sender]) {
            revert NotAuthorizedForNFT(msg.sender, nftContract, nftTokenId);
        }

        // Set custom avatar
        sbtAvatars[tokenId] = AvatarSetting({
            nftContract: nftContract,
            nftTokenId: nftTokenId,
            isCustom: true
        });

        emit AvatarSet(tokenId, nftContract, nftTokenId, true, block.timestamp);
    }

    /**
     * @notice Delegate avatar usage to another address
     * @dev Allows cross-account avatar usage (Account A owns NFT, Account B owns SBT)
     * @param nftContract NFT contract address
     * @param nftTokenId NFT token ID
     * @param delegatee Address to delegate to
     */
    function delegateAvatarUsage(
        address nftContract,
        uint256 nftTokenId,
        address delegatee
    ) external {
        // Verify ownership
        address nftOwner;
        try IERC721(nftContract).ownerOf(nftTokenId) returns (address owner) {
            nftOwner = owner;
        } catch {
            revert NFTNotOwned(msg.sender, nftContract, nftTokenId);
        }

        if (nftOwner != msg.sender) {
            revert NFTNotOwned(msg.sender, nftContract, nftTokenId);
        }

        // Set delegation
        avatarDelegation[nftContract][nftTokenId][delegatee] = true;
    }

    /**
     * @notice Get avatar URI for SBT
     * @dev Priority: Custom > Auto (first NFT) > Community Default
     * @param tokenId Token ID
     * @return uri Avatar URI
     */
    function getAvatarURI(uint256 tokenId) external view override returns (string memory uri) {
        // Priority 1: Custom avatar
        if (sbtAvatars[tokenId].isCustom && sbtAvatars[tokenId].nftContract != address(0)) {
            try IERC721Metadata(sbtAvatars[tokenId].nftContract).tokenURI(
                sbtAvatars[tokenId].nftTokenId
            ) returns (string memory nftUri) {
                return nftUri;
            } catch {
                // Fall through to next priority
            }
        }

        // Priority 2: Auto-set first bound NFT
        if (!sbtAvatars[tokenId].isCustom && sbtAvatars[tokenId].nftContract != address(0)) {
            try IERC721Metadata(sbtAvatars[tokenId].nftContract).tokenURI(
                sbtAvatars[tokenId].nftTokenId
            ) returns (string memory nftUri) {
                return nftUri;
            } catch {
                // Fall through to next priority
            }
        }

        // Priority 3: First community default avatar
        address firstCommunity = sbtData[tokenId].firstCommunity;
        return communityDefaultAvatar[firstCommunity];
    }

    /**
     * @notice Set community default avatar
     * @dev Called by community to set their default avatar
     * @param avatarURI Default avatar URI (IPFS or HTTP)
     */
    function setCommunityDefaultAvatar(string memory avatarURI)
        external
        override
        onlyRegisteredCommunity
    {
        communityDefaultAvatar[msg.sender] = avatarURI;
    }

    // ====================================
    // Reputation Functions
    // ====================================

    /**
     * @notice Record user activity (called by PaymasterV4 or community)
     * @dev Non-critical operation, doesn't revert transaction
     * @dev v2.2: Event-driven architecture - 65k gas → ~5k gas (92% reduction)
     * @dev Activity tracking moved to off-chain indexer (The Graph)
     * @param user User address
     */
    function recordActivity(address user) external override {
        // Silently skip if community not registered (non-critical operation)
        if (!_isValidCommunity(msg.sender)) return;

        uint256 tokenId = userToSBT[user];
        if (tokenId == 0) return;  // No SBT, silently skip

        // Check membership exists
        uint256 idx = membershipIndex[tokenId][msg.sender];
        if (idx >= _memberships[tokenId].length ||
            _memberships[tokenId][idx].community != msg.sender) {
            return;  // No membership, silently skip
        }

        // ✅ Event-driven: Only emit event, no storage writes (saves ~60k gas)
        // Activity data is indexed off-chain by The Graph for reputation calculation
        uint256 currentWeek = block.timestamp / 1 weeks;
        emit ActivityRecorded(tokenId, msg.sender, currentWeek, block.timestamp);
    }

    /**
     * @notice Get community reputation score
     * @param user User address
     * @param community Community address
     * @return score Reputation score
     */
    function getCommunityReputation(address user, address community)
        external
        view
        override
        returns (uint256 score)
    {
        uint256 tokenId = userToSBT[user];
        if (tokenId == 0) return 0;

        // Use external calculator if set
        if (reputationCalculator != address(0)) {
            try IReputationCalculator(reputationCalculator).calculateReputation(
                user,
                community,
                tokenId
            ) returns (uint256 communityScore, uint256 /* globalScore */) {
                return communityScore;
            } catch {
                // Fall back to default
            }
        }

        // Default calculation
        return _calculateDefaultReputation(tokenId, community);
    }

    /**
     * @notice Get global reputation score
     * @param user User address
     * @return score Global reputation score
     */
    function getGlobalReputation(address user)
        external
        view
        override
        returns (uint256 score)
    {
        uint256 tokenId = userToSBT[user];
        if (tokenId == 0) return 0;

        // Use external calculator if set
        if (reputationCalculator != address(0)) {
            try IReputationCalculator(reputationCalculator).calculateReputation(
                user,
                address(0),  // Global query
                tokenId
            ) returns (uint256 /* communityScore */, uint256 globalScore) {
                return globalScore;
            } catch {
                // Fall back to default
            }
        }

        // Default: sum of all community reputations
        uint256 totalScore = 0;
        CommunityMembership[] memory memberships = _memberships[tokenId];

        for (uint256 i = 0; i < memberships.length; i++) {
            if (memberships[i].isActive) {
                totalScore += _calculateDefaultReputation(tokenId, memberships[i].community);
            }
        }

        return totalScore;
    }

    /**
     * @notice Default reputation calculation
     * @dev Base (20) + NFT (+3) + Activity (+1 per week, max 4 weeks)
     * @param tokenId Token ID
     * @param community Community address
     * @return score Calculated score
     */
    function _calculateDefaultReputation(uint256 tokenId, address community)
        internal
        view
        returns (uint256 score)
    {
        // Verify membership
        uint256 idx = membershipIndex[tokenId][community];
        if (idx >= _memberships[tokenId].length ||
            _memberships[tokenId][idx].community != community ||
            !_memberships[tokenId][idx].isActive) {
            return 0;
        }

        // Base score
        score = BASE_REPUTATION;

        // NFT bonus
        if (nftBindings[tokenId][community].isActive) {
            score += NFT_BONUS;
        }

        // Activity bonus: REMOVED in v2.2 (event-driven)
        // Activity data now tracked off-chain via The Graph
        // Use external reputation calculator for activity-based scoring

        return score;
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set reputation calculator contract
     * @param calculator Calculator contract address (0 = use default)
     */
    function setReputationCalculator(address calculator) external override onlyDAO {
        address oldCalculator = reputationCalculator;
        reputationCalculator = calculator;
        emit ReputationCalculatorUpdated(oldCalculator, calculator, block.timestamp);
    }

    /**
     * @notice Set minimum lock amount
     * @param amount Amount in wei
     */
    function setMinLockAmount(uint256 amount) external override onlyDAO {
        if (amount == 0) revert InvalidParameter("minLockAmount");
        minLockAmount = amount;
    }

    /**
     * @notice Set mint fee
     * @param fee Fee amount in wei
     */
    function setMintFee(uint256 fee) external override onlyDAO {
        mintFee = fee;
    }

    /**
     * @notice Set DAO multisig address
     * @param newDAO New DAO address
     */
    function setDAOMultisig(address newDAO) external override onlyDAO {
        if (newDAO == address(0)) revert InvalidAddress(newDAO);
        daoMultisig = newDAO;
    }

    /**
     * @notice Set Registry contract address
     * @param registry Registry contract address
     */
    function setRegistry(address registry) external override onlyDAO {
        if (registry == address(0)) revert InvalidAddress(registry);
        REGISTRY = registry;
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Validate community is registered in Registry
     * @param community Community address
     * @return isValid True if community is registered and active
     */
    function _isValidCommunity(address community) internal view returns (bool isValid) {
        if (REGISTRY == address(0)) return false;

        // Call Registry to check community status
        // Note: This requires Registry v2.1 interface
        // For now, we'll use a simple try-catch pattern
        try IRegistryV2_1(REGISTRY).isRegisteredCommunity(community) returns (bool registered) {
            return registered;
        } catch {
            return false;
        }
    }

    /**
     * @notice Override transfer to make SBT non-transferable
     * @dev SBTs are bound to soul, cannot be transferred
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // Allow minting (from == 0) but not transfers
        if (from != address(0) && to != address(0)) {
            revert TransferNotAllowed();
        }

        return super._update(to, tokenId, auth);
    }
}
