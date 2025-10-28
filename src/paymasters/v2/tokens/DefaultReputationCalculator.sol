// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../interfaces/IReputationCalculator.sol";
import "../interfaces/IMySBT.sol";

/**
 * @title DefaultReputationCalculator
 * @notice Default implementation of reputation calculator for MySBT v2.1
 * @dev Can be upgraded/replaced by DAO
 *
 * Calculation Formula:
 * Community Score = Base (20) + NFT Bonus (3) + Activity Bonus (1 per week, max 4)
 * Global Score = Sum of all active community scores
 *
 * This is a simple implementation. Advanced versions could include:
 * - Transaction volume weighting
 * - Time-decay factors
 * - Community-specific multipliers
 * - Cross-community synergy bonuses
 */
contract DefaultReputationCalculator is IReputationCalculator {
    // ====================================
    // Constants
    // ====================================

    /// @notice Base reputation score for active membership
    uint256 public constant BASE_REPUTATION = 20;

    /// @notice NFT bonus per bound NFT
    uint256 public constant NFT_BONUS = 3;

    /// @notice Activity bonus per active week
    uint256 public constant ACTIVITY_BONUS = 1;

    /// @notice Activity tracking window (4 weeks)
    uint256 public constant ACTIVITY_WINDOW = 4;

    // ====================================
    // Storage
    // ====================================

    /// @notice MySBT contract address
    address public immutable MYSBT;

    // ====================================
    // Constructor
    // ====================================

    constructor(address _mysbt) {
        require(_mysbt != address(0), "Invalid MySBT address");
        MYSBT = _mysbt;
    }

    // ====================================
    // External Functions
    // ====================================

    /**
     * @notice Calculate reputation scores for a user
     * @param user User address
     * @param community Community address (0 for global query)
     * @param sbtTokenId User's SBT token ID
     * @return communityScore Community-specific reputation score
     * @return globalScore Global cross-community reputation score
     */
    function calculateReputation(
        address user,
        address community,
        uint256 sbtTokenId
    ) external view override returns (uint256 communityScore, uint256 globalScore) {
        IMySBT sbt = IMySBT(MYSBT);

        // Validate SBT ownership
        if (sbt.getUserSBT(user) != sbtTokenId) {
            return (0, 0);
        }

        // Calculate community score if specified
        if (community != address(0)) {
            communityScore = _calculateCommunityScore(sbt, sbtTokenId, community);
        }

        // Calculate global score
        globalScore = _calculateGlobalScore(sbt, sbtTokenId);

        return (communityScore, globalScore);
    }

    /**
     * @notice Get reputation breakdown for transparency
     * @param user User address
     * @param community Community address
     * @param sbtTokenId User's SBT token ID
     * @return baseScore Base score from membership
     * @return nftBonus Bonus from bound NFTs
     * @return activityBonus Bonus from recent activity
     * @return multiplier Community-specific multiplier (100 = 1x)
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
        IMySBT sbt = IMySBT(MYSBT);

        // Validate SBT ownership
        if (sbt.getUserSBT(user) != sbtTokenId) {
            return (0, 0, 0, 100);
        }

        // Verify membership
        if (!sbt.verifyCommunityMembership(user, community)) {
            return (0, 0, 0, 100);
        }

        // Base score
        baseScore = BASE_REPUTATION;

        // NFT bonus
        IMySBT.NFTBinding memory binding = sbt.getNFTBinding(sbtTokenId, community);
        if (binding.isActive) {
            nftBonus = NFT_BONUS;
        }

        // Activity bonus (would need access to weeklyActivity mapping)
        // For now, we'll estimate based on last active time
        IMySBT.CommunityMembership memory membership = sbt.getCommunityMembership(sbtTokenId, community);
        uint256 weeksSinceActive = (block.timestamp - membership.lastActiveTime) / 1 weeks;
        if (weeksSinceActive < ACTIVITY_WINDOW) {
            // Simplified: assume user was active in weeks since last activity
            activityBonus = (ACTIVITY_WINDOW - weeksSinceActive) * ACTIVITY_BONUS;
        }

        // Default multiplier (no community-specific boost in v1)
        multiplier = 100;  // 100 = 1x (no change)

        return (baseScore, nftBonus, activityBonus, multiplier);
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Calculate community-specific reputation score
     * @param sbt MySBT contract interface
     * @param tokenId Token ID
     * @param community Community address
     * @return score Community reputation score
     */
    function _calculateCommunityScore(
        IMySBT sbt,
        uint256 tokenId,
        address community
    ) internal view returns (uint256 score) {
        // Verify active membership
        IMySBT.CommunityMembership memory membership;
        try sbt.getCommunityMembership(tokenId, community) returns (
            IMySBT.CommunityMembership memory m
        ) {
            membership = m;
        } catch {
            return 0;
        }

        if (!membership.isActive) {
            return 0;
        }

        // Base score
        score = BASE_REPUTATION;

        // NFT bonus
        IMySBT.NFTBinding memory binding = sbt.getNFTBinding(tokenId, community);
        if (binding.isActive) {
            score += NFT_BONUS;
        }

        // Activity bonus (estimate based on last active time)
        uint256 weeksSinceActive = (block.timestamp - membership.lastActiveTime) / 1 weeks;
        if (weeksSinceActive < ACTIVITY_WINDOW) {
            score += (ACTIVITY_WINDOW - weeksSinceActive) * ACTIVITY_BONUS;
        }

        return score;
    }

    /**
     * @notice Calculate global cross-community reputation score
     * @param sbt MySBT contract interface
     * @param tokenId Token ID
     * @return score Global reputation score
     */
    function _calculateGlobalScore(
        IMySBT sbt,
        uint256 tokenId
    ) internal view returns (uint256 score) {
        // Get all memberships
        IMySBT.CommunityMembership[] memory memberships;
        try sbt.getMemberships(tokenId) returns (
            IMySBT.CommunityMembership[] memory m
        ) {
            memberships = m;
        } catch {
            return 0;
        }

        // Sum scores from all active memberships
        uint256 totalScore = 0;
        for (uint256 i = 0; i < memberships.length; i++) {
            if (memberships[i].isActive) {
                totalScore += _calculateCommunityScore(
                    sbt,
                    tokenId,
                    memberships[i].community
                );
            }
        }

        return totalScore;
    }
}
