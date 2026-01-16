// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "../interfaces/IMySBT.sol";

/**
 * @title MySBTReputationAccumulator
 * @notice External reputation accumulation for MySBT (v2.4.5+ extension)
 * @dev Minimal external contract to handle reputation calculation and tracking
 *      Keeps MySBT contract size small while providing flexible reputation system
 *
 * Features:
 * - Activity-based reputation accumulation
 * - Time-weighted scoring
 * - Community-specific reputation
 * - Global reputation aggregation
 * - Configurable scoring rules
 *
 * Architecture:
 * - MySBT: Only stores lastActivityTime per user/community
 * - This contract: Full reputation logic and scoring
 * - Reputation calculated on-demand (view functions)
 * - Activity recording via MySBT.recordActivity()
 */
contract MySBTReputationAccumulator is Ownable {

    // ====================================
    // Data Structures
    // ====================================

    struct ReputationScore {
        uint256 communityScore;
        uint256 globalScore;
        uint256 activityCount;
        uint256 lastCalculated;
    }

    struct ScoringRules {
        uint256 baseScore;          // Base reputation score (e.g., 20)
        uint256 activityBonus;      // Bonus per activity (e.g., 1)
        uint256 activityWindow;     // Time window to count activities (e.g., 4 weeks)
        uint256 maxActivities;      // Max activities to count (e.g., 10)
        uint256 timeDecayFactor;    // Decay factor per week (basis points, e.g., 100 = 1%)
        uint256 minInterval;        // Min time between activities (e.g., 5 minutes)
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice MySBT contract address
    IMySBT public immutable MYSBT;

    /// @notice Default scoring rules
    ScoringRules public defaultRules;

    /// @notice Community-specific scoring rules (optional)
    mapping(address => ScoringRules) public communityRules;

    /// @notice Whether community has custom rules
    mapping(address => bool) public hasCustomRules;

    /// @notice Cached reputation scores (optional optimization)
    mapping(uint256 => mapping(address => ReputationScore)) private _cachedScores;

    /// @notice Enable score caching (gas optimization vs real-time accuracy)
    bool public cachingEnabled = false;

    /// @notice Cache validity period (seconds)
    uint256 public cacheValidityPeriod = 1 hours;

    // ====================================
    // Events
    // ====================================

    event ScoringRulesUpdated(address indexed community, ScoringRules rules, uint256 timestamp);
    event ReputationCalculated(uint256 indexed tokenId, address indexed community, uint256 score, uint256 timestamp);
    event CachingConfigured(bool enabled, uint256 validityPeriod, uint256 timestamp);

    // ====================================
    // Constructor
    // ====================================

    constructor(address _mysbt) Ownable(msg.sender) {
        require(_mysbt != address(0), "Invalid MySBT address");
        MYSBT = IMySBT(_mysbt);

        // Set default scoring rules
        defaultRules = ScoringRules({
            baseScore: 20,
            activityBonus: 1,
            activityWindow: 4 weeks,
            maxActivities: 10,
            timeDecayFactor: 100, // 1% decay per week
            minInterval: 5 minutes
        });
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Calculate community reputation for user
     * @param user User address
     * @param community Community address
     * @return score Community reputation score
     */
    function getCommunityReputation(address user, address community) external view returns (uint256 score) {
        uint256 tokenId = MYSBT.getUserSBT(user);
        if (tokenId == 0) return 0;

        // Check cache if enabled
        if (cachingEnabled) {
            ReputationScore memory cached = _cachedScores[tokenId][community];
            if (cached.lastCalculated > 0 &&
                block.timestamp - cached.lastCalculated < cacheValidityPeriod) {
                return cached.communityScore;
            }
        }

        // Calculate real-time score
        score = _calculateCommunityScore(tokenId, community);
    }

    /**
     * @notice Calculate global reputation for user
     * @param user User address
     * @return score Global reputation score (sum of all communities)
     */
    function getGlobalReputation(address user) external view returns (uint256 score) {
        uint256 tokenId = MYSBT.getUserSBT(user);
        if (tokenId == 0) return 0;

        // Get all community memberships
        IMySBT.CommunityMembership[] memory memberships = MYSBT.getMemberships(tokenId);

        for (uint256 i = 0; i < memberships.length; i++) {
            if (memberships[i].isActive) {
                score += _calculateCommunityScore(tokenId, memberships[i].community);
            }
        }
    }

    /**
     * @notice Get detailed reputation breakdown
     * @param user User address
     * @param community Community address (address(0) for global)
     * @return communityScore Community-specific score
     * @return activityCount Number of activities
     * @return timeWeightedScore Time-weighted score component
     * @return baseScore Base score component
     */
    function getReputationBreakdown(address user, address community)
        external
        view
        returns (
            uint256 communityScore,
            uint256 activityCount,
            uint256 timeWeightedScore,
            uint256 baseScore
        )
    {
        uint256 tokenId = MYSBT.getUserSBT(user);
        if (tokenId == 0) return (0, 0, 0, 0);

        ScoringRules memory rules = _getRules(community);

        if (community != address(0)) {
            // Verify membership
            (IMySBT.CommunityMembership memory mem, bool exists) = _getMembership(tokenId, community);
            if (!exists || !mem.isActive) return (0, 0, 0, 0);

            // Calculate activity-based score
            activityCount = _countRecentActivities(tokenId, community, rules.activityWindow);
            if (activityCount > rules.maxActivities) activityCount = rules.maxActivities;

            timeWeightedScore = _calculateTimeWeight(mem.joinedAt, rules.timeDecayFactor);
            baseScore = rules.baseScore;
            communityScore = baseScore + (activityCount * rules.activityBonus) + timeWeightedScore;
        }
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set scoring rules for community
     * @param community Community address (address(0) for default)
     * @param rules Scoring rules
     */
    function setScoringRules(address community, ScoringRules memory rules) external onlyOwner {
        require(rules.baseScore > 0, "Invalid base score");

        if (community == address(0)) {
            defaultRules = rules;
        } else {
            communityRules[community] = rules;
            hasCustomRules[community] = true;
        }

        emit ScoringRulesUpdated(community, rules, block.timestamp);
    }

    /**
     * @notice Configure caching
     * @param enabled Enable/disable caching
     * @param validityPeriod Cache validity period in seconds
     */
    function configureCaching(bool enabled, uint256 validityPeriod) external onlyOwner {
        cachingEnabled = enabled;
        cacheValidityPeriod = validityPeriod;
        emit CachingConfigured(enabled, validityPeriod, block.timestamp);
    }

    /**
     * @notice Update cached score (called by off-chain indexer or keeper)
     * @param tokenId SBT token ID
     * @param community Community address
     */
    function updateCachedScore(uint256 tokenId, address community) external {
        uint256 score = _calculateCommunityScore(tokenId, community);

        _cachedScores[tokenId][community] = ReputationScore({
            communityScore: score,
            globalScore: 0, // Calculated separately
            activityCount: _countRecentActivities(tokenId, community, defaultRules.activityWindow),
            lastCalculated: block.timestamp
        });

        emit ReputationCalculated(tokenId, community, score, block.timestamp);
    }

    /**
     * @notice Batch update cached scores (gas optimization)
     * @param tokenIds Array of SBT token IDs
     * @param communities Array of community addresses
     */
    function batchUpdateCachedScores(uint256[] calldata tokenIds, address[] calldata communities) external {
        require(tokenIds.length == communities.length, "Length mismatch");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 score = _calculateCommunityScore(tokenIds[i], communities[i]);

            _cachedScores[tokenIds[i]][communities[i]] = ReputationScore({
                communityScore: score,
                globalScore: 0,
                activityCount: _countRecentActivities(tokenIds[i], communities[i], defaultRules.activityWindow),
                lastCalculated: block.timestamp
            });
        }
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Calculate community score for token
     * @param tokenId SBT token ID
     * @param community Community address
     * @return score Calculated score
     */
    function _calculateCommunityScore(uint256 tokenId, address community) internal view returns (uint256 score) {
        ScoringRules memory rules = _getRules(community);

        // Verify membership
        (IMySBT.CommunityMembership memory mem, bool exists) = _getMembership(tokenId, community);
        if (!exists || !mem.isActive) return 0;

        // Base score
        score = rules.baseScore;

        // Activity bonus
        uint256 activityCount = _countRecentActivities(tokenId, community, rules.activityWindow);
        if (activityCount > rules.maxActivities) activityCount = rules.maxActivities;
        score += activityCount * rules.activityBonus;

        // Time-weighted bonus
        score += _calculateTimeWeight(mem.joinedAt, rules.timeDecayFactor);
    }

    /**
     * @notice Count recent activities within time window
     * @param tokenId SBT token ID
     * @param community Community address
     * @param timeWindow Time window to count (seconds)
     * @return count Number of activities
     */
    function _countRecentActivities(
        uint256 tokenId,
        address community,
        uint256 timeWindow
    ) internal view returns (uint256 count) {
        // Note: MySBT only stores lastActivityTime, not full activity history
        // For accurate counting, need off-chain indexer to track activities
        // This is a simplified version using weekly activity flags

        uint256 currentWeek = block.timestamp / 1 weeks;
        uint256 startWeek = currentWeek - (timeWindow / 1 weeks);

        // This requires MySBT to expose weeklyActivity mapping
        // Simplified: return 0 here, actual implementation needs MySBT storage access
        // or off-chain event indexing

        return 0; // Placeholder - implement with activity tracking
    }

    /**
     * @notice Calculate time-weighted score
     * @param joinTime Membership join timestamp
     * @param decayFactor Decay factor (basis points per week)
     * @return weight Time-weighted score
     */
    function _calculateTimeWeight(uint256 joinTime, uint256 decayFactor) internal view returns (uint256 weight) {
        uint256 weeksPassed = (block.timestamp - joinTime) / 1 weeks;
        if (weeksPassed == 0) return 0;

        // Apply decay: score = weeks * (1 - decay)^weeks
        // Simplified: linear growth with cap
        weight = weeksPassed;
        if (weight > 52) weight = 52; // Cap at 1 year
    }

    /**
     * @notice Get scoring rules for community
     * @param community Community address
     * @return rules Scoring rules
     */
    function _getRules(address community) internal view returns (ScoringRules memory) {
        if (hasCustomRules[community]) {
            return communityRules[community];
        }
        return defaultRules;
    }

    /**
     * @notice Get membership for token and community
     * @param tokenId SBT token ID
     * @param community Community address
     * @return mem Membership data
     * @return exists Whether membership exists
     */
    function _getMembership(uint256 tokenId, address community)
        internal
        view
        returns (IMySBT.CommunityMembership memory mem, bool exists)
    {
        // Get all memberships and find the matching one
        IMySBT.CommunityMembership[] memory memberships = MYSBT.getMemberships(tokenId);
        exists = false;

        for (uint256 i = 0; i < memberships.length; i++) {
            if (memberships[i].community == community) {
                mem = memberships[i];
                exists = true;
                break;
            }
        }
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get scoring rules for community
     * @param community Community address (address(0) for default)
     * @return rules Scoring rules
     */
    function getScoringRules(address community) external view returns (ScoringRules memory) {
        return _getRules(community);
    }

    /**
     * @notice Check if score is cached
     * @param tokenId SBT token ID
     * @param community Community address
     * @return isCached True if valid cache exists
     * @return cacheAge Age of cache in seconds
     */
    function isCachedScoreValid(uint256 tokenId, address community)
        external
        view
        returns (bool isCached, uint256 cacheAge)
    {
        ReputationScore memory cached = _cachedScores[tokenId][community];
        if (cached.lastCalculated == 0) return (false, 0);

        cacheAge = block.timestamp - cached.lastCalculated;
        isCached = cacheAge < cacheValidityPeriod;
    }
}
