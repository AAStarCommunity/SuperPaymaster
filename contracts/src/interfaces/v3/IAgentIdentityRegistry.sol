// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title IAgentIdentityRegistry - Minimal ERC-8004 Identity Registry interface (ERC-721 based)
/// @notice Used by SuperPaymaster to verify agent identity via NFT ownership
interface IAgentIdentityRegistry {
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 agentId) external view returns (address);
}
