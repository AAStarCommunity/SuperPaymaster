// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "../../interfaces/v3/IRegistryV3.sol";

/**
 * @title ReputationSystemV3
 * @notice Advanced reputation calculation and management for the Mycelium Ecosystem.
 * @dev Decoupled scoring logic from storage (Registry V3 holds the final scores).
 */
contract ReputationSystemV3 is Ownable {

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

    // NFT Boosts: collection address => bonus points
    mapping(address => uint256) public nftCollectionBoost;
    address[] public boostedCollections;

    event RuleUpdated(address indexed community, bytes32 indexed ruleId, uint256 base, uint256 bonus);
    event EntropyFactorUpdated(address indexed community, uint256 factor);
    event ReputationComputed(address indexed user, uint256 score);
    event NFTBoostAdded(address indexed collection, uint256 boost);

    constructor(address _registry) Ownable(msg.sender) {
        REGISTRY = IRegistryV3(_registry);
        defaultRule = Rule(10, 1, 100, "Default");
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
     * @notice Community admins can set their own scoring rules.
     * @dev Restricted to the owner of the community role in the Registry.
     */
    function setRule(bytes32 ruleId, uint256 base, uint256 bonus, uint256 max, string calldata desc) external {
        address community = msg.sender; 
        // Verify msg.sender has the community role in Registry
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
        address[] calldata communities, 
        bytes32[][] calldata ruleIds, 
        uint256[][] calldata activities
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
        address[] calldata communities, 
        bytes32[][] calldata ruleIds, 
        uint256[][] calldata activities, 
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
}
