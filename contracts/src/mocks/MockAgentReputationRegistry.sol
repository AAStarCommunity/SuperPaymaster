// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/// @title MockAgentReputationRegistry
/// @notice Mock ERC-8004 Agent Reputation Registry for testing
/// @dev Implements IAgentReputationRegistry interface (getSummary, giveFeedback)
contract MockAgentReputationRegistry is Ownable {
    struct ReputationData {
        uint64 feedbackCount;
        int128 totalScore;
    }

    // agentId => ReputationData
    mapping(uint256 => ReputationData) public reputations;

    event FeedbackReceived(
        uint256 indexed agentId,
        int128 value,
        bytes32 tag1,
        bytes32 tag2
    );

    constructor() Ownable(msg.sender) {}

    /// @notice Set initial reputation for an agent (for testing)
    function setReputation(uint256 agentId, uint64 count, int128 totalScore) external onlyOwner {
        reputations[agentId] = ReputationData(count, totalScore);
    }

    /// @notice Get reputation summary for an agent
    function getSummary(
        uint256 agentId,
        address[] calldata, // clients (unused in mock)
        bytes32,            // tag1 (unused in mock)
        bytes32             // tag2 (unused in mock)
    ) external view returns (uint64 count, int128 avgScore) {
        ReputationData memory data = reputations[agentId];
        count = data.feedbackCount;
        avgScore = data.feedbackCount > 0
            ? data.totalScore / int128(int64(data.feedbackCount))
            : int128(0);
    }

    /// @notice Record feedback for an agent
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8,       // decimals
        bytes32 tag1,
        bytes32 tag2,
        string calldata, // endpoint
        string calldata, // feedbackURI
        bytes32          // fileHash
    ) external {
        ReputationData storage data = reputations[agentId];
        data.feedbackCount += 1;
        data.totalScore += value;
        emit FeedbackReceived(agentId, value, tag1, tag2);
    }
}
