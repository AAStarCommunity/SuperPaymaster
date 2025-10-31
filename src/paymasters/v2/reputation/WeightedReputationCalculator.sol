// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../interfaces/IReputationCalculator.sol";
import "../interfaces/IMySBT.sol";
import "./NFTRatingRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";

/**
 * @title WeightedReputationCalculator
 * @notice Advanced reputation calculator with NFT rating integration
 * @dev Version: 1.0.0
 *
 * Reputation Formula:
 * - Base Score: 20 points (for having active membership)
 * - NFT Bonus: Time-weighted score × rating multiplier
 *   - Time Weight: min(holdingMonths, 12) points (1 point/month, max 12)
 *   - Rating Multiplier: From NFTRatingRegistry
 *     - Unverified: 0.1x (100 basis points) → max 1.2 points
 *     - Verified: 0.7x - 1.3x (700-1300 basis points) → max 8.4-15.6 points
 *
 * Example:
 * - User holds 1 verified NFT (1.0x rating) for 6 months
 * - Time weight: 6 points
 * - NFT bonus: 6 × 1000 / 1000 = 6 points
 * - Total: 20 (base) + 6 (NFT) = 26 points
 *
 * Anti-Gaming:
 * - Query-time verification: NFT ownership checked on each reputation call
 * - Unverified NFTs: Minimal value (0.1x multiplier)
 * - Community voting: Prevents single-party rating manipulation
 */
contract WeightedReputationCalculator is IReputationCalculator {
    // ====================================
    // Constants
    // ====================================

    /// @notice Base reputation for active membership
    uint256 public constant BASE_REPUTATION = 20;

    /// @notice NFT time unit (30 days = 1 month)
    uint256 public constant NFT_TIME_UNIT = 30 days;

    /// @notice NFT base score per month (1 point)
    uint256 public constant NFT_BASE_SCORE_PER_MONTH = 1;

    /// @notice NFT max holding months for scoring (12 months)
    uint256 public constant NFT_MAX_MONTHS = 12;

    /// @notice Basis points divisor (1000 = 1.0x)
    uint256 public constant BASIS_POINTS = 1000;

    // ====================================
    // State Variables
    // ====================================

    /// @notice MySBT contract for membership and NFT binding data
    IMySBT public immutable mysbt;

    /// @notice NFT Rating Registry for collection ratings
    NFTRatingRegistry public immutable ratingRegistry;

    // ====================================
    // Errors
    // ====================================

    error InvalidAddress(address addr);

    // ====================================
    // Constructor
    // ====================================

    constructor(address _mysbt, address _ratingRegistry) {
        if (_mysbt == address(0)) revert InvalidAddress(_mysbt);
        if (_ratingRegistry == address(0)) revert InvalidAddress(_ratingRegistry);

        mysbt = IMySBT(_mysbt);
        ratingRegistry = NFTRatingRegistry(_ratingRegistry);
    }

    // ====================================
    // IReputationCalculator Implementation
    // ====================================

    /**
     * @notice Calculate reputation scores for a user
     * @param user User address
     * @param community Community address (for community-specific scoring)
     * @param sbtTokenId User's SBT token ID
     * @return communityScore Community-specific reputation score
     * @return globalScore Global cross-community reputation score
     */
    function calculateReputation(
        address user,
        address community,
        uint256 sbtTokenId
    ) external view override returns (uint256 communityScore, uint256 globalScore) {
        // 1. Verify active membership
        bool hasActiveMembership = mysbt.verifyCommunityMembership(user, community);
        if (!hasActiveMembership) {
            return (0, 0);
        }

        // 2. Calculate base score
        uint256 baseScore = BASE_REPUTATION;

        // 3. Calculate NFT bonus
        uint256 nftBonus = _calculateNFTBonus(sbtTokenId, user);

        // 4. Community score = base + NFT bonus
        communityScore = baseScore + nftBonus;

        // 5. Global score (simplified: same as community for now)
        // Future: aggregate across all communities
        globalScore = communityScore;

        return (communityScore, globalScore);
    }

    /**
     * @notice Get reputation breakdown for transparency
     * @param user User address
     * @param community Community address
     * @param sbtTokenId User's SBT token ID
     * @return baseScore Base score from membership
     * @return nftBonus Bonus from bound NFTs (weighted)
     * @return activityBonus Activity bonus (future feature)
     * @return multiplier Community multiplier (always 100 = 1x for now)
     */
    function getReputationBreakdown(
        address user,
        address community,
        uint256 sbtTokenId
    ) external view override returns (
        uint256 baseScore,
        uint256 nftBonus,
        uint256 activityBonus,
        uint256 multiplier
    ) {
        // Verify active membership
        bool hasActiveMembership = mysbt.verifyCommunityMembership(user, community);
        if (!hasActiveMembership) {
            return (0, 0, 0, 0);
        }

        baseScore = BASE_REPUTATION;
        nftBonus = _calculateNFTBonus(sbtTokenId, user);
        activityBonus = 0; // Future: activity-based bonus
        multiplier = 100; // 1.0x (future: community-specific multipliers)

        return (baseScore, nftBonus, activityBonus, multiplier);
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Calculate time-weighted NFT bonus with rating multipliers
     * @param tokenId SBT token ID
     * @param holder Expected NFT holder address
     * @return totalBonus Total NFT bonus points
     *
     * @dev Formula for each NFT:
     *      1. Time weight = min(holdingMonths, 12) points
     *      2. Rating multiplier = from NFTRatingRegistry (basis points)
     *      3. Bonus = timeWeight × multiplier / BASIS_POINTS
     *
     * Example:
     * - NFT held for 6 months with 1.0x rating (1000 bp)
     * - Bonus = 6 × 1000 / 1000 = 6 points
     *
     * - NFT held for 3 months with 0.1x rating (100 bp, unverified)
     * - Bonus = 3 × 100 / 1000 = 0.3 points
     */
    function _calculateNFTBonus(
        uint256 tokenId,
        address holder
    ) internal view returns (uint256 totalBonus) {
        // Get all NFT bindings for this SBT
        IMySBT.NFTBinding[] memory bindings = mysbt.getAllNFTBindings(tokenId);

        for (uint256 i = 0; i < bindings.length; i++) {
            IMySBT.NFTBinding memory binding = bindings[i];
            if (!binding.isActive) continue;

            // Query-time ownership verification (caller pays gas)
            address currentOwner;
            try IERC721(binding.nftContract).ownerOf(binding.nftTokenId) returns (address owner) {
                currentOwner = owner;
            } catch {
                continue; // Skip if NFT query fails
            }

            if (currentOwner != holder) continue;

            // Calculate time weight (1 point per month, max 12)
            uint256 holdingTime = block.timestamp - binding.bindTime;
            uint256 holdingMonths = holdingTime / NFT_TIME_UNIT;
            uint256 timeWeight = holdingMonths * NFT_BASE_SCORE_PER_MONTH;
            if (timeWeight > NFT_MAX_MONTHS) {
                timeWeight = NFT_MAX_MONTHS;
            }

            // Get rating multiplier from registry
            uint256 multiplier = ratingRegistry.getMultiplier(binding.nftContract);

            // Calculate weighted bonus: timeWeight × multiplier / BASIS_POINTS
            uint256 bonus = (timeWeight * multiplier) / BASIS_POINTS;

            totalBonus += bonus;
        }

        return totalBonus;
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get detailed NFT bonus breakdown for a user
     * @param tokenId SBT token ID
     * @param holder Expected NFT holder address
     * @return nftContracts Array of NFT contract addresses
     * @return nftTokenIds Array of NFT token IDs
     * @return timeWeights Array of time weights (months held)
     * @return multipliers Array of rating multipliers (basis points)
     * @return bonuses Array of calculated bonuses
     */
    function getNFTBonusBreakdown(
        uint256 tokenId,
        address holder
    ) external view returns (
        address[] memory nftContracts,
        uint256[] memory nftTokenIds,
        uint256[] memory timeWeights,
        uint256[] memory multipliers,
        uint256[] memory bonuses
    ) {
        IMySBT.NFTBinding[] memory bindings = mysbt.getAllNFTBindings(tokenId);

        // Count valid NFTs
        uint256 validCount = 0;
        for (uint256 i = 0; i < bindings.length; i++) {
            if (!bindings[i].isActive) continue;
            try IERC721(bindings[i].nftContract).ownerOf(bindings[i].nftTokenId) returns (address owner) {
                if (owner == holder) validCount++;
            } catch {
                // Skip
            }
        }

        // Allocate arrays
        nftContracts = new address[](validCount);
        nftTokenIds = new uint256[](validCount);
        timeWeights = new uint256[](validCount);
        multipliers = new uint256[](validCount);
        bonuses = new uint256[](validCount);

        // Populate arrays
        uint256 index = 0;
        for (uint256 i = 0; i < bindings.length; i++) {
            IMySBT.NFTBinding memory binding = bindings[i];
            if (!binding.isActive) continue;

            address currentOwner;
            try IERC721(binding.nftContract).ownerOf(binding.nftTokenId) returns (address owner) {
                currentOwner = owner;
            } catch {
                continue;
            }

            if (currentOwner != holder) continue;

            // Calculate time weight
            uint256 holdingTime = block.timestamp - binding.bindTime;
            uint256 holdingMonths = holdingTime / NFT_TIME_UNIT;
            uint256 timeWeight = holdingMonths * NFT_BASE_SCORE_PER_MONTH;
            if (timeWeight > NFT_MAX_MONTHS) {
                timeWeight = NFT_MAX_MONTHS;
            }

            // Get multiplier
            uint256 multiplier = ratingRegistry.getMultiplier(binding.nftContract);

            // Calculate bonus
            uint256 bonus = (timeWeight * multiplier) / BASIS_POINTS;

            nftContracts[index] = binding.nftContract;
            nftTokenIds[index] = binding.nftTokenId;
            timeWeights[index] = timeWeight;
            multipliers[index] = multiplier;
            bonuses[index] = bonus;

            index++;
        }

        return (nftContracts, nftTokenIds, timeWeights, multipliers, bonuses);
    }
}
