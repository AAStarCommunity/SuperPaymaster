// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IReputationCalculator
 * @notice External reputation calculator interface for MySBT v2.1
 * @dev Allows upgrading reputation calculation logic without changing main contract
 *
 * Default Implementation (if not set):
 * - Base: 20 points for having SBT membership
 * - NFT Bonus: +3 points per bound NFT
 * - Activity: +1 point per active week (last 4 weeks)
 *
 * Advanced implementations can include:
 * - Transaction volume weighting
 * - Cross-community reputation aggregation
 * - Time-decay factors
 * - Community-specific multipliers
 */
interface IReputationCalculator {
    /**
     * @notice Calculate reputation scores for a user
     * @param user User address
     * @param community Community address (for community-specific scoring)
     * @param sbtTokenId User's SBT token ID
     * @return communityScore Community-specific reputation score
     * @return globalScore Global cross-community reputation score
     *
     * @dev Implementation must be view/pure (no state changes)
     * @dev Should not revert - return 0 if user has no reputation
     * @dev Can call back to MySBT contract for membership/activity data
     */
    function calculateReputation(
        address user,
        address community,
        uint256 sbtTokenId
    ) external view returns (uint256 communityScore, uint256 globalScore);

    /**
     * @notice Get reputation breakdown for transparency
     * @param user User address
     * @param community Community address
     * @param sbtTokenId User's SBT token ID
     * @return baseScore Base score from membership
     * @return nftBonus Bonus from bound NFTs
     * @return activityBonus Bonus from recent activity
     * @return multiplier Community-specific multiplier (100 = 1x)
     *
     * @dev Optional - for UI display and debugging
     */
    function getReputationBreakdown(
        address user,
        address community,
        uint256 sbtTokenId
    ) external view returns (
        uint256 baseScore,
        uint256 nftBonus,
        uint256 activityBonus,
        uint256 multiplier
    );
}
