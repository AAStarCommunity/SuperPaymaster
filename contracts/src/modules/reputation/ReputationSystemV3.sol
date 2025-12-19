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

    struct ScoringRules {
        uint256 baseScore;
        uint256 activityBonus;
        uint256 maxBonus;
    }

    IRegistryV3 public immutable REGISTRY;
    mapping(address => ScoringRules) public communityRules;
    ScoringRules public defaultRules;

    // NFT Boosts: collection address => bonus points
    mapping(address => uint256) public nftCollectionBoost;
    address[] public boostedCollections;

    event RulesUpdated(address indexed community, uint256 base, uint256 bonus);
    event ReputationComputed(address indexed user, uint256 score);
    event NFTBoostAdded(address indexed collection, uint256 boost);

    constructor(address _registry) Ownable(msg.sender) {
        REGISTRY = IRegistryV3(_registry);
        defaultRules = ScoringRules(10, 1, 100);
    }

    function setRules(address community, uint256 base, uint256 bonus, uint256 max) external onlyOwner {
        communityRules[community] = ScoringRules(base, bonus, max);
        emit RulesUpdated(community, base, bonus);
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
     * @dev Simple linear model for prototype.
     */
    function computeScore(address user, address[] calldata communities, uint256[] calldata activities) public view returns (uint256 totalScore) {
        // 1. Community Activity Scoring
        for (uint i = 0; i < communities.length; i++) {
            ScoringRules memory r = communityRules[communities[i]].baseScore > 0 ? communityRules[communities[i]] : defaultRules;
            uint256 bonus = activities[i] * r.activityBonus;
            if (bonus > r.maxBonus) bonus = r.maxBonus;
            totalScore += r.baseScore + bonus;
        }

        // 2. Global NFT Boosts
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
     * @notice Trigger Registry update (if authorized)
     */
    function syncToRegistry(address user, address[] calldata communities, uint256[] calldata activities, uint256 epoch) external {
        uint256 score = computeScore(user, communities, activities);
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory scores = new uint256[](1);
        scores[0] = score;
        
        REGISTRY.batchUpdateGlobalReputation(users, scores, epoch, "");
        emit ReputationComputed(user, score);
    }
}
