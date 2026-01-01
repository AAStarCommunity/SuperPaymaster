// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "../../interfaces/v3/IRegistryV3.sol";
import "../../interfaces/v3/IReputationCalculator.sol";
import "src/interfaces/IVersioned.sol";

/**
 * @title ReputationSystemV3
 * @notice Advanced reputation calculation and management for the Mycelium Ecosystem.
 * @dev Decoupled scoring logic from storage (Registry V3 holds the final scores).
 */
contract ReputationSystemV3 is Ownable, IReputationCalculator {

    struct Rule {
        uint256 baseScore;
        uint256 activityBonus;
        uint256 maxBonus;
        string description;
    }

    IRegistryV3 public immutable REGISTRY;
    
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
    address[] public boostedCollections;

    event RuleUpdated(address indexed community, bytes32 indexed ruleId, uint256 base, uint256 bonus);
    event EntropyFactorUpdated(address indexed community, uint256 factor);
    event CommunityReputationUpdated(address indexed community, address indexed user, uint256 score);
    event ReputationComputed(address indexed user, uint256 score);
    event NFTBoostAdded(address indexed collection, uint256 boost);

    constructor(address _registry) Ownable(msg.sender) {
        REGISTRY = IRegistryV3(_registry);
        defaultRule = Rule(10, 1, 100, "Default");
    }

    function version() external pure override returns (string memory) {
        return "Reputation-0.3.0";
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
     */
    function setCommunityReputation(address community, address user, uint256 score) external {
        // Reuse Registry's reputation source whitelist for access control
        require(msg.sender == owner() || REGISTRY.isReputationSource(msg.sender), "Unauthorized");
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
        require(REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), msg.sender) || owner() == msg.sender, "Not Authorized");

        
        if (communityRules[community][ruleId].baseScore == 0 && base > 0) {
            communityActiveRules[community].push(ruleId);
        }
        
        communityRules[community][ruleId] = Rule(base, bonus, max, desc);
        emit RuleUpdated(community, ruleId, base, bonus);
    }

    function setNFTBoost(address collection, uint256 boost) external onlyOwner {
        if (nftCollectionBoost[collection] == 0) {
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
        for (uint i = 0; i < communities.length; i++) {
            address community = communities[i];
            uint256 communityScore = 0;
            
            for (uint j = 0; j < ruleIds[i].length; j++) {
                bytes32 rId = ruleIds[i][j];
                Rule memory r = communityRules[community][rId];
                
                // If rule not found, use a subset of default if it's the first rule
                if (r.baseScore == 0 && j == 0) {
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
        for (uint i = 0; i < boostedCollections.length; i++) {
            address collection = boostedCollections[i];
            try IERC721(collection).balanceOf(user) returns (uint256 balance) {
                if (balance > 0) {
                    totalScore += nftCollectionBoost[collection];
                }
            } catch {}
        }
    }

    /**
     * @notice Trigger Registry update
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
        
        REGISTRY.batchUpdateGlobalReputation(users, scores, epoch, proof);
        emit ReputationComputed(user, score);
    }

    /**
     * @notice IReputationCalculator implementation for MySBT v2.1+
     */
    function calculateReputation(
        address user,
        address community,
        uint256 /* sbtTokenId */
    ) external view override returns (uint256 communityScore, uint256 globalScore) {
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
    ) external view override returns (
        uint256 baseScore,
        uint256 nftBonus,
        uint256 activityBonus,
        uint256 multiplier
    ) {
        // Return first active rule's base as hint
        bytes32[] memory rules = communityActiveRules[community];
        if (rules.length > 0) {
            Rule memory r = communityRules[community][rules[0]];
            baseScore = r.baseScore;
            activityBonus = r.activityBonus;
        } else {
            baseScore = defaultRule.baseScore;
            activityBonus = defaultRule.activityBonus;
        }
        
        multiplier = entropyFactors[community];
        if (multiplier == 0) multiplier = 1e18;
        
        // Calculate total NFT bonus
        for (uint i = 0; i < boostedCollections.length; i++) {
            try IERC721(boostedCollections[i]).balanceOf(user) returns (uint256 balance) {
                if (balance > 0) {
                    nftBonus += nftCollectionBoost[boostedCollections[i]];
                }
            } catch {}
        }
    }
}
