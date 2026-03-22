// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title IAgentIdentityRegistry - ERC-8004 Agent Identity
/// @notice Minimal interface for checking agent registration status
interface IAgentIdentityRegistry {
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 agentId) external view returns (address);
}
