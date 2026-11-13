// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "src/interfaces/v3/IRegistry.sol";
import "../../interfaces/v3/IReputationCalculator.sol";
import "src/interfaces/IVersioned.sol";

/**
 * @title ReputationSystem
 * @notice Advanced reputation calculation and management for the Mycelium Ecosystem.
 * @dev Decoupled scoring logic from storage (Registry V3 holds the final scores).
 */
contract ReputationSystem is Ownable, IReputationCalculator {
    struct Rule {
        uint256 baseScore;
        uint256 activityBonus;
        uint256 maxBonus;
        string description;
    }

    IRegistry public immutable REGISTRY;

    // community => ruleId => Rule
    mapping(address => mapping(bytes32 => Rule)) public communityRules;
    // community => list of active rule IDs
    mapping(address => bytes32[]) public communityActiveRules;

    Rule public defaultRule;

    // Entropy Factor: community => factor (scaled by 1e18, 1.0 = baseline)
    mapping(address => uint256) public entropyFactors;

    // Future Extensibility: Explicit storage for community sub-reputation
    // community => user => score
    mapping(address => mapping(address => uint256)) public communityReputations;

    // NFT Boosts: collection address => bonus points
    mapping(address => uint256) public nftCollectionBoost;
    mapping(address => mapping(address => uint256)) public nftHoldStart; // user => collection => timestamp
    address[] public boostedCollections;
    mapping(address => mapping(bytes32 => bool)) private _ruleListed;
    mapping(address => bool) private _collectionListed;
    mapping(address => mapping(bytes32 => bool)) private _ruleActive;
    uint256 public constant MAX_BOOSTED_COLLECTIONS = 50;
    // One-based position in communityActiveRules; zero means absent. Append-only storage.
    mapping(address => mapping(bytes32 => uint256)) private _activeRuleIndex;

    error Unauthorized();
    error NotAuthorized();
    error MaxBoostedReached();
    error DoesNotHoldNFT();
    error StillHoldsNFT();
    error InvalidCollection();
    error InvalidAddress();
    error InvalidInput();

    event RuleUpdated(address indexed community, bytes32 indexed ruleId, uint256 base, uint256 bonus);
    event EntropyFactorUpdated(address indexed community, uint256 factor);
    event CommunityReputationUpdated(address indexed community, address indexed user, uint256 score);
    event ReputationComputed(address indexed user, uint256 score);
    event NFTBoostAdded(address indexed collection, uint256 boost);
    event NFTHoldStartReset(address indexed user, address indexed collection);

    constructor(address _registry) Ownable(msg.sender) {
        REGISTRY = IRegistry(_registry);
        defaultRule = Rule(10, 1, 100, "Default");
    }

    function version() external pure override returns (string memory) {
        return "Reputation-0.6.0";
    }

    /**
     * @notice Governance sets the Entropy Factor for a community.
     * @dev 1e18 = 1.0. Lower factor increases "resistance" to reputation gain.
     */
    function setEntropyFactor(address community, uint256 factor) external onlyOwner {
        entropyFactors[community] = factor;
        emit EntropyFactorUpdated(community, factor);
    }

    /**
     * @notice Set specific community reputation score (called by DVT/Trusted Source)
     * @dev Allows off-chain calculation results to be stored on-chain for specific communities.
     *      Authorized callers: contract owner OR addresses whitelisted via Registry.isReputationSource().
     */
    function setCommunityReputation(address community, address user, uint256 score) external {
        // Reuse Registry's reputation source whitelist for access control
        if (msg.sender != owner() && !REGISTRY.isReputationSource(msg.sender)) revert Unauthorized();
        communityReputations[community][user] = score;
        emit CommunityReputationUpdated(community, user, score);
    }

    /**
     * @notice Community admins can set their own scoring rules.
     * @dev Restricted to the owner of the community role in the Registry.
     */
    function setRule(bytes32 ruleId, uint256 base, uint256 bonus, uint256 max, string calldata desc) external {
        address community = msg.sender;
        // Verify msg.sender has the COMMUNITY role (multi-tenant: each community manages its own rules)
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender) && owner() != msg.sender) revert NotAuthorized();
        // Upper bounds prevent unbounded score inflation and arithmetic overflow in computeScore.
        // base/bonus capped at 10_000 points per rule; max capped at 100_000 (max cumulative bonus).
        if (base > 10_000 || bonus > 10_000 || max > 100_000) revert InvalidInput();

        _ruleListed[community][ruleId] = true;
        bytes32[] storage activeRules = communityActiveRules[community];
        uint256 index = _activeRuleIndex[community][ruleId];
        if (base > 0 && index == 0) {
            activeRules.push(ruleId);
            _activeRuleIndex[community][ruleId] = activeRules.length;
        } else if (base == 0 && index != 0) {
            uint256 last = activeRules.length;
            if (index != last) {
                bytes32 moved = activeRules[last - 1];
                activeRules[index - 1] = moved;
                _activeRuleIndex[community][moved] = index;
            }
            activeRules.pop();
            delete _activeRuleIndex[community][ruleId];
        }
        _ruleActive[community][ruleId] = base > 0;
        communityRules[community][ruleId] = Rule(base, bonus, max, desc);
        emit RuleUpdated(community, ruleId, base, bonus);
    }

    function setNFTBoost(address collection, uint256 boost) external onlyOwner {
        if (collection == address(0)) revert InvalidAddress();
        if (!_collectionListed[collection]) {
            if (boostedCollections.length >= MAX_BOOSTED_COLLECTIONS) revert MaxBoostedReached();
            _collectionListed[collection] = true;
            boostedCollections.push(collection);
        }
        nftCollectionBoost[collection] = boost;
        emit NFTBoostAdded(collection, boost);
    }

    /**
     * @notice Compute reputation for a user based on their community activities.
     * @dev Activities are now mapped to rules.
     */
    function computeScore(
        address user,
        address[] memory communities,
        bytes32[][] memory ruleIds,
        uint256[][] memory activities
    ) public view returns (uint256 totalScore) {
        if (ruleIds.length != communities.length || activities.length != communities.length) revert InvalidInput();
        for (uint256 i = 0; i < communities.length; i++) {
            address community = communities[i];
            uint256 communityScore = 0;

            for (uint256 j = 0; j < ruleIds[i].length; j++) {
                bytes32 rId = ruleIds[i][j];
                Rule memory r = communityRules[community][rId];

                // A configured zero-base rule is disabled, not missing.
                if (_ruleListed[community][rId] && !_ruleActive[community][rId]) continue;

                // If rule was never configured, use the default for the first rule.
                // P1-26 resolved: fallback uses defaultRule (configurable), not a hardcoded score
                if (!_ruleListed[community][rId] && j == 0) {
                    r = defaultRule;
                }

                uint256 bonus = activities[i][j] * r.activityBonus;
                if (bonus > r.maxBonus) bonus = r.maxBonus;
                communityScore += r.baseScore + bonus;
            }

            // Apply Entropy Factor (1e18 = 1.0)
            uint256 factor = entropyFactors[community];
            if (factor == 0) factor = 1e18; // Default to 1.0

            totalScore += (communityScore * factor) / 1e18;
        }

        // Global NFT Boosts
        for (uint256 i = 0; i < boostedCollections.length; i++) {
            address collection = boostedCollections[i];
            if (_nftBoostEligible(user, collection)) totalScore += nftCollectionBoost[collection];
        }
    }

    /**
     * @notice Sync computed reputation score to the Registry for the given user.
     * @dev Computes score via computeScore then calls Registry.batchUpdateGlobalReputation.
     *      The proposalId is derived deterministically from (user, epoch) to ensure uniqueness.
     */
    function syncToRegistry(
        address user,
        address[] memory communities,
        bytes32[][] memory ruleIds,
        uint256[][] memory activities,
        uint256 epoch,
        bytes calldata proof
    ) external {
        uint256 score = computeScore(user, communities, ruleIds, activities);
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory scores = new uint256[](1);
        scores[0] = score;

        // Derive a non-zero proposalId from (user, epoch) — unique per sync call since
        // epoch is monotonically increasing per user in Registry.
        // P1-27 resolved: security delegated to REGISTRY.batchUpdateGlobalReputation BLS proof verification
        // P1-23: "RS" domain prefix prevents namespace collision with BLSAggregator proposalIds.
        // BLSAggregator uses externally-provided uint256 IDs (sequential or off-chain hashed without
        // this prefix), so ReputationSystem IDs are guaranteed distinguishable in Registry storage.
        uint256 proposalId = uint256(keccak256(abi.encode("RS", user, epoch)));
        REGISTRY.batchUpdateGlobalReputation(proposalId, users, scores, epoch, proof);
        emit ReputationComputed(user, score);
    }

    /**
     * @notice IReputationCalculator implementation for MySBT v2.1+
     */
    function calculateReputation(
        address user,
        address community,
        uint256 /* sbtTokenId */
    )
        external
        view
        override
        returns (uint256 communityScore, uint256 globalScore)
    {
        // Find community rule
        bytes32[] memory rules = communityActiveRules[community];
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = rules;

        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](rules.length); // Assuming 1 activity for each rule if we don't know

        address[] memory communities = new address[](1);
        communities[0] = community;

        communityScore = computeScore(user, communities, ruleIds, activities);
        globalScore = communityScore; // Simplification for now
    }

    function getReputationBreakdown(
        address user,
        address community,
        uint256 /* sbtTokenId */
    )
        external
        view
        override
        returns (uint256 baseScore, uint256 nftBonus, uint256 activityBonus, uint256 multiplier)
    {
        // Mirror calculateReputation: all active rules, zero activity inputs,
        // then the community multiplier and global NFT boosts.
        bytes32[] memory rules = communityActiveRules[community];
        for (uint256 i = 0; i < rules.length; i++) {
            baseScore += communityRules[community][rules[i]].baseScore;
        }

        multiplier = entropyFactors[community];
        if (multiplier == 0) multiplier = 1e18;
        baseScore = (baseScore * multiplier) / 1e18;
        activityBonus = 0;

        // Apply the same registration-age and current-ownership predicate as computeScore.
        for (uint256 i = 0; i < boostedCollections.length; i++) {
            address collection = boostedCollections[i];
            if (_nftBoostEligible(user, collection)) nftBonus += nftCollectionBoost[collection];
        }
    }

    /// @dev Eligibility is registration age plus current ownership. Strict
    ///      continuity cannot be proven without hooks from third-party NFTs.
    function _nftBoostEligible(address user, address collection) internal view returns (bool) {
        uint256 registeredAt = nftHoldStart[user][collection];
        if (registeredAt == 0 || block.timestamp < registeredAt + 7 days) return false;
        try IERC721(collection).balanceOf(user) returns (uint256 balance) {
            return balance > 0;
        } catch {
            return false;
        }
    }

    /**
     * @notice Get all active rule IDs for a community
     * @param community The community address
     * @return ruleIds Array of active rule identifiers; order may change on removal
     */
    function getActiveRules(address community) external view returns (bytes32[] memory ruleIds) {
        return communityActiveRules[community];
    }

    /**
     * @notice Register the waiting period for an NFT reputation boost.
     * @dev Eligibility starts seven days later and also requires current ownership.
     *      This records registration age, not continuous ownership history.
     */
    function updateNFTHoldStart(address collection) external {
        try IERC721(collection).balanceOf(msg.sender) returns (uint256 balance) {
            if (balance == 0) revert DoesNotHoldNFT();
            if (nftHoldStart[msg.sender][collection] == 0) {
                nftHoldStart[msg.sender][collection] = block.timestamp;
            }
        } catch {
            revert InvalidCollection();
        }
    }

    /// @notice Clear a user's registration age after they no longer own the boosted NFT.
    /// @dev Permissionless watcher resets improve freshness but cannot prove strict
    ///      continuity for third-party collections without transfer hooks.
    function resetNFTHoldStart(address user, address collection) external {
        try IERC721(collection).balanceOf(user) returns (uint256 balance) {
            if (balance != 0) revert StillHoldsNFT();
            if (nftHoldStart[user][collection] == 0) return;
            delete nftHoldStart[user][collection];
            emit NFTHoldStartReset(user, collection);
        } catch {
            revert InvalidCollection();
        }
    }
}
