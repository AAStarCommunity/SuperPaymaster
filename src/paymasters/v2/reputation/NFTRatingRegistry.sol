// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NFTRatingRegistry
 * @notice Decentralized NFT collection rating registry with community voting
 * @dev Version: 1.0.0
 *
 * Architecture:
 * - Community-maintained on-chain NFT collection ratings
 * - Anti-gaming: Unverified NFTs get 0.1x multiplier (100 basis points)
 * - Verified NFTs: 0.7x - 1.3x multiplier range (700-1300 basis points)
 * - Basis points system: 1000 = 1.0x multiplier
 *
 * Voting Mechanism:
 * - Only registered communities can propose and vote
 * - Requires minimum voting threshold to activate rating
 * - Rating = weighted average of community votes
 */
contract NFTRatingRegistry is Ownable, ReentrancyGuard {
    // ====================================
    // Constants
    // ====================================

    /// @notice Basis points for multipliers (1000 = 1.0x)
    uint256 public constant BASIS_POINTS = 1000;

    /// @notice Default multiplier for unverified NFTs (0.1x)
    uint256 public constant UNVERIFIED_MULTIPLIER = 100;

    /// @notice Minimum multiplier for verified NFTs (0.7x)
    uint256 public constant MIN_VERIFIED_MULTIPLIER = 700;

    /// @notice Maximum multiplier for verified NFTs (1.3x)
    uint256 public constant MAX_VERIFIED_MULTIPLIER = 1300;

    /// @notice Minimum votes required to activate a rating
    uint256 public constant MIN_VOTES_THRESHOLD = 3;

    // ====================================
    // Structs
    // ====================================

    struct NFTRating {
        uint256 totalVotes;           // Total number of votes
        uint256 weightedSum;          // Sum of (multiplier × voter weight)
        uint256 totalWeight;          // Sum of all voter weights
        uint256 currentMultiplier;    // Current effective multiplier (basis points)
        bool isVerified;              // Whether rating is active (>= MIN_VOTES_THRESHOLD)
        mapping(address => Vote) votes; // Community => Vote
    }

    struct Vote {
        uint256 multiplier;           // Voted multiplier (basis points)
        uint256 weight;               // Vote weight (1 for now, future: reputation-based)
        uint256 timestamp;            // When vote was cast
    }

    struct NFTRatingView {
        address nftContract;
        uint256 totalVotes;
        uint256 currentMultiplier;
        bool isVerified;
    }

    // ====================================
    // State Variables
    // ====================================

    /// @notice Registry contract for community verification
    address public registry;

    /// @notice NFT collection ratings: nftContract => NFTRating
    mapping(address => NFTRating) private _ratings;

    /// @notice List of all rated NFT contracts
    address[] private _ratedNFTs;

    /// @notice Quick lookup: nftContract => index in _ratedNFTs (1-based, 0 = not exists)
    mapping(address => uint256) private _ratedNFTIndex;

    // ====================================
    // Events
    // ====================================

    event VoteCast(
        address indexed nftContract,
        address indexed community,
        uint256 multiplier,
        uint256 weight,
        uint256 timestamp
    );

    event RatingUpdated(
        address indexed nftContract,
        uint256 totalVotes,
        uint256 newMultiplier,
        bool isVerified,
        uint256 timestamp
    );

    event RegistryUpdated(
        address indexed oldRegistry,
        address indexed newRegistry,
        uint256 timestamp
    );

    // ====================================
    // Errors
    // ====================================

    error InvalidAddress(address addr);
    error MultiplierOutOfRange(uint256 multiplier);
    error UnauthorizedCommunity(address community);
    error AlreadyVoted(address community, address nftContract);

    // ====================================
    // Constructor
    // ====================================

    constructor(address _registry, address initialOwner) Ownable(initialOwner) {
        if (_registry == address(0)) revert InvalidAddress(_registry);
        registry = _registry;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Vote for an NFT collection's rating
     * @param nftContract NFT contract address
     * @param multiplier Proposed multiplier (700-1300 basis points)
     * @dev Only registered communities can vote
     */
    function voteForRating(
        address nftContract,
        uint256 multiplier
    ) external nonReentrant {
        if (nftContract == address(0)) revert InvalidAddress(nftContract);
        if (multiplier < MIN_VERIFIED_MULTIPLIER || multiplier > MAX_VERIFIED_MULTIPLIER) {
            revert MultiplierOutOfRange(multiplier);
        }

        // Verify caller is registered community
        if (!_isRegisteredCommunity(msg.sender)) {
            revert UnauthorizedCommunity(msg.sender);
        }

        NFTRating storage rating = _ratings[nftContract];

        // Check if already voted
        if (rating.votes[msg.sender].timestamp != 0) {
            revert AlreadyVoted(msg.sender, nftContract);
        }

        // Add to rated NFTs list if first vote
        if (rating.totalVotes == 0) {
            _ratedNFTs.push(nftContract);
            _ratedNFTIndex[nftContract] = _ratedNFTs.length; // 1-based index
        }

        // Cast vote with weight = 1 (future: reputation-based weighting)
        uint256 weight = 1;
        rating.votes[msg.sender] = Vote({
            multiplier: multiplier,
            weight: weight,
            timestamp: block.timestamp
        });

        // Update weighted sum and total weight
        rating.totalVotes++;
        rating.weightedSum += multiplier * weight;
        rating.totalWeight += weight;

        // Recalculate current multiplier (weighted average)
        rating.currentMultiplier = rating.weightedSum / rating.totalWeight;

        // Update verification status
        bool wasVerified = rating.isVerified;
        rating.isVerified = rating.totalVotes >= MIN_VOTES_THRESHOLD;

        emit VoteCast(nftContract, msg.sender, multiplier, weight, block.timestamp);

        if (!wasVerified && rating.isVerified) {
            emit RatingUpdated(
                nftContract,
                rating.totalVotes,
                rating.currentMultiplier,
                true,
                block.timestamp
            );
        }
    }

    /**
     * @notice Get multiplier for an NFT collection
     * @param nftContract NFT contract address
     * @return multiplier Multiplier in basis points (100 for unverified, 700-1300 for verified)
     */
    function getMultiplier(address nftContract) external view returns (uint256 multiplier) {
        NFTRating storage rating = _ratings[nftContract];

        if (!rating.isVerified) {
            return UNVERIFIED_MULTIPLIER; // 0.1x for unverified
        }

        return rating.currentMultiplier; // 0.7x - 1.3x for verified
    }

    /**
     * @notice Get rating details for an NFT collection
     * @param nftContract NFT contract address
     * @return totalVotes Total number of votes
     * @return currentMultiplier Current multiplier (basis points)
     * @return isVerified Whether rating is verified (>= MIN_VOTES_THRESHOLD)
     */
    function getRating(address nftContract) external view returns (
        uint256 totalVotes,
        uint256 currentMultiplier,
        bool isVerified
    ) {
        NFTRating storage rating = _ratings[nftContract];
        return (
            rating.totalVotes,
            rating.isVerified ? rating.currentMultiplier : UNVERIFIED_MULTIPLIER,
            rating.isVerified
        );
    }

    /**
     * @notice Get vote details for a specific community
     * @param nftContract NFT contract address
     * @param community Community address
     * @return multiplier Voted multiplier
     * @return weight Vote weight
     * @return timestamp Vote timestamp
     */
    function getVote(
        address nftContract,
        address community
    ) external view returns (
        uint256 multiplier,
        uint256 weight,
        uint256 timestamp
    ) {
        Vote storage vote = _ratings[nftContract].votes[community];
        return (vote.multiplier, vote.weight, vote.timestamp);
    }

    /**
     * @notice Get all rated NFT contracts
     * @return nfts Array of rated NFT contract addresses
     */
    function getAllRatedNFTs() external view returns (address[] memory nfts) {
        return _ratedNFTs;
    }

    /**
     * @notice Get paginated rated NFTs with details
     * @param offset Starting index
     * @param limit Number of items to return
     * @return ratings Array of NFT ratings
     * @return total Total number of rated NFTs
     */
    function getRatedNFTsPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (
        NFTRatingView[] memory ratings,
        uint256 total
    ) {
        total = _ratedNFTs.length;
        if (offset >= total) {
            return (new NFTRatingView[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        ratings = new NFTRatingView[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            address nftContract = _ratedNFTs[i];
            NFTRating storage rating = _ratings[nftContract];
            ratings[i - offset] = NFTRatingView({
                nftContract: nftContract,
                totalVotes: rating.totalVotes,
                currentMultiplier: rating.isVerified ? rating.currentMultiplier : UNVERIFIED_MULTIPLIER,
                isVerified: rating.isVerified
            });
        }

        return (ratings, total);
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set Registry contract address
     * @param newRegistry New Registry address
     */
    function setRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert InvalidAddress(newRegistry);
        address oldRegistry = registry;
        registry = newRegistry;
        emit RegistryUpdated(oldRegistry, newRegistry, block.timestamp);
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Check if address is a registered community
     * @param community Community address
     * @return isRegistered True if community is registered
     */
    function _isRegisteredCommunity(address community) internal view returns (bool) {
        // Call Registry.isRegisteredCommunity()
        (bool success, bytes memory data) = registry.staticcall(
            abi.encodeWithSignature("isRegisteredCommunity(address)", community)
        );

        if (!success || data.length == 0) {
            return false;
        }

        return abi.decode(data, (bool));
    }
}
