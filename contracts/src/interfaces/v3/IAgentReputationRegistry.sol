// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title IAgentReputationRegistry - Minimal ERC-8004 Reputation Registry interface
/// @notice Used by SuperPaymaster to query agent reputation and submit sponsorship feedback
interface IAgentReputationRegistry {
    function getSummary(
        uint256 agentId,
        address[] calldata clients,
        bytes32 tag1,
        bytes32 tag2
    ) external view returns (uint64 count, int128 avgScore);

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 decimals,
        bytes32 tag1,
        bytes32 tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 fileHash
    ) external;
}
