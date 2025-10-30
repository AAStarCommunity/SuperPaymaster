// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title MySBT with NFT Binding
 * @notice Soul Bound Token with community NFT binding for enhanced identity
 * @dev ERC721 with transfer restrictions + NFT binding mechanism
 *
 * v2.1-beta Features:
 * - Basic SBT functionality (lock 0.3 sGT, burn 0.1 GT mint fee)
 * - NFT binding for community membership
 * - Dual binding modes: Custodial (托管) vs Non-Custodial (保留)
 * - Binding limits: 10 free, 11+ requires 100 stGToken each
 * - 7-day unbinding cooldown period
 * - Burn protection: must unbind all NFTs first
 *
 * Identity System:
 * - Base Layer: MySBT (white-label, permissionless)
 * - Community Layer: Bound NFTs (community-issued, authorized)
 */
contract MySBTWithNFTBinding is ERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================================
    // Enums
    // ====================================

    /// @notice NFT binding mode
    enum NFTBindingMode {
        CUSTODIAL,      // NFT transferred to contract (safer)
        NON_CUSTODIAL   // NFT stays in user wallet (flexible)
    }

    // ====================================
    // Structs
    // ====================================

    /// @notice User's cross-community profile
    struct UserProfile {
        uint256[] ownedSBTs;
        uint256 reputationScore;
        string ensName;
    }

    /// @notice Per-community activity data
    struct CommunityData {
        address community;
        uint256 txCount;
        uint256 joinedAt;
        uint256 lastActiveTime;
        uint256 contributionScore;
    }

    /// @notice NFT binding record
    struct NFTBinding {
        address nftContract;
        uint256 nftTokenId;
        uint256 bindTime;
        bool isActive;
        NFTBindingMode mode;
    }

    /// @notice Unbind request (for cooldown period)
    struct UnbindRequest {
        uint256 requestTime;
        bool pending;
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice User profiles
    mapping(address => UserProfile) public userProfiles;

    /// @notice SBT data
    mapping(uint256 => CommunityData) public sbtData;

    /// @notice User-community-token mapping
    mapping(address => mapping(address => uint256)) public userCommunityToken;

    /// @notice NFT bindings: SBT tokenId => community => NFTBinding
    mapping(uint256 => mapping(address => NFTBinding)) public bindings;

    /// @notice Bound communities list: SBT tokenId => community addresses
    mapping(uint256 => address[]) public sbtCommunities;

    /// @notice NFT to SBT reverse mapping: NFT contract => NFT tokenId => SBT tokenId
    mapping(address => mapping(uint256 => uint256)) public nftToSBT;

    /// @notice Unbind requests: SBT tokenId => community => UnbindRequest
    mapping(uint256 => mapping(address => UnbindRequest)) public unbindRequests;

    /// @notice Extra locks for 11+ bindings: user => locked amount
    mapping(address => uint256) public extraLocks;

    /// @notice GToken contract
    address public immutable GTOKEN;

    /// @notice GTokenStaking contract
    address public immutable GTOKEN_STAKING;

    /// @notice SuperPaymaster address
    address public SUPERPAYMASTER;

    /// @notice Next token ID
    uint256 public nextTokenId = 1;

    /// @notice Contract creator
    address public creator;

    // ====================================
    // Configurable Parameters
    // ====================================

    /// @notice Lock amount for minting SBT (default 0.3 sGT)
    uint256 public minLockAmount = 0.3 ether;

    /// @notice Mint burn fee (default 0.1 GT)
    uint256 public mintFee = 0.1 ether;

    // ====================================
    // Constants
    // ====================================

    /// @notice Default binding limit (free)
    uint256 public constant DEFAULT_BINDING_LIMIT = 10;

    /// @notice Extra lock per binding beyond limit
    uint256 public constant EXTRA_LOCK_PER_BINDING = 1 ether; // 1 stGToken per extra binding

    /// @notice Unbind cooldown period
    uint256 public constant UNBIND_COOLDOWN = 7 days;

    // ====================================
    // Events
    // ====================================

    event SBTMinted(
        address indexed user,
        address indexed community,
        uint256 tokenId,
        uint256 stGTokenLocked,
        uint256 timestamp
    );

    event NFTBound(
        uint256 indexed sbtTokenId,
        address indexed community,
        address indexed nftContract,
        uint256 nftTokenId,
        NFTBindingMode mode,
        uint256 timestamp
    );

    event UnbindRequested(
        uint256 indexed sbtTokenId,
        address indexed community,
        uint256 executeTime
    );

    event NFTUnbound(
        uint256 indexed sbtTokenId,
        address indexed community,
        address indexed nftContract,
        uint256 nftTokenId,
        uint256 timestamp
    );

    event SBTBurned(
        address indexed user,
        uint256 tokenId,
        uint256 exitFeePaid,
        uint256 stGTokenReturned,
        uint256 timestamp
    );

    event ExtraLockAdded(
        address indexed user,
        uint256 amount,
        uint256 totalLocked
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
    error NFTAlreadyBound(address nftContract, uint256 nftTokenId);
    error CommunityAlreadyBound(uint256 sbtTokenId, address community);
    error NFTNotOwned(address user, address nftContract, uint256 nftTokenId);
    error UnbindCooldownNotFinished(uint256 remainingTime);
    error NoUnbindRequest(uint256 sbtTokenId, address community);
    error HasBoundNFTs(uint256 sbtTokenId, uint256 count);

    // ====================================
    // Constructor
    // ====================================

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
    // Core SBT Functions
    // ====================================

    /**
     * @notice Mint SBT for community membership
     * @param community Community address
     * @return tokenId Minted token ID
     */
    function mintSBT(address community) external nonReentrant returns (uint256 tokenId) {
        if (userCommunityToken[msg.sender][community] != 0) {
            revert AlreadyHasSBT(msg.sender, community);
        }

        if (community == address(0)) {
            revert InvalidAddress(community);
        }

        // CEI: Effects first
        tokenId = nextTokenId++;

        sbtData[tokenId] = CommunityData({
            community: community,
            txCount: 0,
            joinedAt: block.timestamp,
            lastActiveTime: block.timestamp,
            contributionScore: 0
        });

        userProfiles[msg.sender].ownedSBTs.push(tokenId);
        userCommunityToken[msg.sender][community] = tokenId;

        // CEI: Interactions last
        IGTokenStaking(GTOKEN_STAKING).lockStake(
            msg.sender,
            minLockAmount,
            "MySBT membership"
        );

        if (mintFee > 0) {
            IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), mintFee);
            IGToken(GTOKEN).burn(mintFee);
        }

        _mint(msg.sender, tokenId);

        emit SBTMinted(msg.sender, community, tokenId, minLockAmount, block.timestamp);
    }

    /**
     * @notice Burn SBT and unlock stGToken
     * @param tokenId Token ID to burn
     * @dev Must unbind all NFTs first
     */
    function burnSBT(uint256 tokenId) external nonReentrant {
        if (ownerOf(tokenId) != msg.sender) {
            revert NotSBTOwner(msg.sender, tokenId);
        }

        // Check if all NFTs are unbound
        address[] memory communities = sbtCommunities[tokenId];
        if (communities.length > 0) {
            revert HasBoundNFTs(tokenId, communities.length);
        }

        address community = sbtData[tokenId].community;

        // CEI: Effects first
        delete sbtData[tokenId];
        delete userCommunityToken[msg.sender][community];

        uint256[] storage ownedSBTs = userProfiles[msg.sender].ownedSBTs;
        for (uint256 i = 0; i < ownedSBTs.length; i++) {
            if (ownedSBTs[i] == tokenId) {
                ownedSBTs[i] = ownedSBTs[ownedSBTs.length - 1];
                ownedSBTs.pop();
                break;
            }
        }

        _burn(tokenId);

        // CEI: Interactions last
        uint256 netAmount = IGTokenStaking(GTOKEN_STAKING).unlockStake(
            msg.sender,
            minLockAmount
        );

        uint256 exitFee = minLockAmount - netAmount;

        emit SBTBurned(msg.sender, tokenId, exitFee, netAmount, block.timestamp);
    }

    // ====================================
    // NFT Binding Functions
    // ====================================

    /**
     * @notice Bind community NFT to SBT
     * @param sbtTokenId SBT token ID
     * @param community Community address
     * @param nftContract Community NFT contract
     * @param nftTokenId NFT token ID
     * @param mode Binding mode (CUSTODIAL or NON_CUSTODIAL)
     */
    function bindNFT(
        uint256 sbtTokenId,
        address community,
        address nftContract,
        uint256 nftTokenId,
        NFTBindingMode mode
    ) external nonReentrant {
        // Validation
        if (ownerOf(sbtTokenId) != msg.sender) {
            revert NotSBTOwner(msg.sender, sbtTokenId);
        }

        if (bindings[sbtTokenId][community].isActive) {
            revert CommunityAlreadyBound(sbtTokenId, community);
        }

        if (nftToSBT[nftContract][nftTokenId] != 0) {
            revert NFTAlreadyBound(nftContract, nftTokenId);
        }

        // Verify NFT ownership
        address nftOwner = IERC721(nftContract).ownerOf(nftTokenId);
        if (nftOwner != msg.sender) {
            revert NFTNotOwned(msg.sender, nftContract, nftTokenId);
        }

        // Check binding limit and lock extra if needed
        uint256 currentBindings = sbtCommunities[sbtTokenId].length;
        if (currentBindings >= DEFAULT_BINDING_LIMIT) {
            _lockExtraForBinding(msg.sender, currentBindings);
        }

        // Execute binding based on mode
        if (mode == NFTBindingMode.CUSTODIAL) {
            // Custodial: Transfer NFT to contract
            IERC721(nftContract).transferFrom(msg.sender, address(this), nftTokenId);
        } else {
            // Non-Custodial: Verify approval (NFT stays in wallet)
            require(
                IERC721(nftContract).isApprovedForAll(msg.sender, address(this)) ||
                IERC721(nftContract).getApproved(nftTokenId) == address(this),
                "NFT not approved"
            );
        }

        // Record binding
        bindings[sbtTokenId][community] = NFTBinding({
            nftContract: nftContract,
            nftTokenId: nftTokenId,
            bindTime: block.timestamp,
            isActive: true,
            mode: mode
        });

        sbtCommunities[sbtTokenId].push(community);
        nftToSBT[nftContract][nftTokenId] = sbtTokenId;

        emit NFTBound(sbtTokenId, community, nftContract, nftTokenId, mode, block.timestamp);
    }

    /**
     * @notice Request to unbind NFT (starts cooldown period)
     * @param sbtTokenId SBT token ID
     * @param community Community address
     */
    function requestUnbind(uint256 sbtTokenId, address community) external {
        if (ownerOf(sbtTokenId) != msg.sender) {
            revert NotSBTOwner(msg.sender, sbtTokenId);
        }

        if (!bindings[sbtTokenId][community].isActive) {
            revert NoSBTFound(msg.sender, community);
        }

        unbindRequests[sbtTokenId][community] = UnbindRequest({
            requestTime: block.timestamp,
            pending: true
        });

        emit UnbindRequested(sbtTokenId, community, block.timestamp + UNBIND_COOLDOWN);
    }

    /**
     * @notice Execute unbind after cooldown period
     * @param sbtTokenId SBT token ID
     * @param community Community address
     */
    function executeUnbind(uint256 sbtTokenId, address community) external nonReentrant {
        if (ownerOf(sbtTokenId) != msg.sender) {
            revert NotSBTOwner(msg.sender, sbtTokenId);
        }

        UnbindRequest memory request = unbindRequests[sbtTokenId][community];

        if (!request.pending) {
            revert NoUnbindRequest(sbtTokenId, community);
        }

        uint256 elapsed = block.timestamp - request.requestTime;
        if (elapsed < UNBIND_COOLDOWN) {
            revert UnbindCooldownNotFinished(UNBIND_COOLDOWN - elapsed);
        }

        // Execute unbind
        _unbindNFT(sbtTokenId, community);

        // Clear request
        delete unbindRequests[sbtTokenId][community];
    }

    /**
     * @notice Internal unbind logic
     * @param sbtTokenId SBT token ID
     * @param community Community address
     */
    function _unbindNFT(uint256 sbtTokenId, address community) internal {
        NFTBinding memory binding = bindings[sbtTokenId][community];

        // Return NFT if custodial mode
        if (binding.mode == NFTBindingMode.CUSTODIAL) {
            IERC721(binding.nftContract).transferFrom(
                address(this),
                ownerOf(sbtTokenId),
                binding.nftTokenId
            );
        }

        // Clean up mappings
        bindings[sbtTokenId][community].isActive = false;
        delete nftToSBT[binding.nftContract][binding.nftTokenId];

        // Remove from communities list
        address[] storage communities = sbtCommunities[sbtTokenId];
        for (uint256 i = 0; i < communities.length; i++) {
            if (communities[i] == community) {
                communities[i] = communities[communities.length - 1];
                communities.pop();
                break;
            }
        }

        emit NFTUnbound(sbtTokenId, community, binding.nftContract, binding.nftTokenId, block.timestamp);
    }

    /**
     * @notice Lock extra stGToken for 11+ bindings
     * @param user User address
     * @param currentBindings Current number of bindings
     */
    function _lockExtraForBinding(address user, uint256 currentBindings) internal {
        uint256 extraNeeded = (currentBindings - DEFAULT_BINDING_LIMIT + 1) * EXTRA_LOCK_PER_BINDING;
        uint256 currentExtra = extraLocks[user];

        if (extraNeeded > currentExtra) {
            uint256 toLock = extraNeeded - currentExtra;
            IGTokenStaking(GTOKEN_STAKING).lockStake(user, toLock, "Extra binding lock");
            extraLocks[user] = extraNeeded;

            emit ExtraLockAdded(user, toLock, extraNeeded);
        }
    }

    // ====================================
    // Verification Functions
    // ====================================

    /**
     * @notice Verify if user has active community membership
     * @param user User address
     * @param community Community address
     * @return True if user has active membership
     */
    function verifyCommunityMembership(address user, address community)
        external
        view
        returns (bool)
    {
        // MySBTWithNFTBinding: one SBT per community model
        // Simply check if user has an SBT for this community
        uint256 sbtTokenId = userCommunityToken[user][community];
        if (sbtTokenId == 0) return false;

        // Verify user still owns the SBT
        return ownerOf(sbtTokenId) == user;
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get all communities bound to an SBT
     * @param sbtTokenId SBT token ID
     * @return communities Array of community addresses
     */
    function getBoundCommunities(uint256 sbtTokenId)
        external
        view
        returns (address[] memory communities)
    {
        return sbtCommunities[sbtTokenId];
    }

    /**
     * @notice Get NFT binding info for a community
     * @param sbtTokenId SBT token ID
     * @param community Community address
     * @return binding NFT binding details
     */
    function getCommunityBinding(uint256 sbtTokenId, address community)
        external
        view
        returns (NFTBinding memory binding)
    {
        return bindings[sbtTokenId][community];
    }

    /**
     * @notice Preview exit cost
     * @param user User address
     * @return exitFee Exit fee in stGToken
     * @return netReturn Net stGToken returned
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

    // ====================================
    // Non-Transferable Logic
    // ====================================

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        if (from != address(0) && to != address(0)) {
            revert TransferNotAllowed();
        }

        return super._update(to, tokenId, auth);
    }

    // ====================================
    // Admin Functions
    // ====================================

    function setSuperPaymaster(address _superPaymaster) external {
        require(msg.sender == creator, "Only creator");
        if (_superPaymaster == address(0)) {
            revert InvalidAddress(_superPaymaster);
        }
        SUPERPAYMASTER = _superPaymaster;
    }

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

        sbtData[tokenId].txCount += 1;
        sbtData[tokenId].lastActiveTime = block.timestamp;
        sbtData[tokenId].contributionScore += txCost / 1e15;

        userProfiles[user].reputationScore += 1;
    }
}
