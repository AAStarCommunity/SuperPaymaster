// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/// @title MockAgentIdentityRegistry
/// @notice Minimal ERC-721-like mock for ERC-8004 Agent Identity testing
/// @dev Implements IAgentIdentityRegistry interface (balanceOf, ownerOf)
contract MockAgentIdentityRegistry is Ownable {
    uint256 private _nextId = 1;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;

    event AgentRegistered(address indexed agent, uint256 indexed agentId);
    event AgentRevoked(uint256 indexed agentId);

    constructor() Ownable(msg.sender) {}

    /// @notice Register an address as an agent (mint agent NFT)
    function registerAgent(address agent) external onlyOwner returns (uint256 agentId) {
        agentId = _nextId++;
        _owners[agentId] = agent;
        _balances[agent] += 1;
        emit AgentRegistered(agent, agentId);
    }

    /// @notice Revoke agent status (burn agent NFT)
    function revokeAgent(uint256 agentId) external onlyOwner {
        address agent = _owners[agentId];
        require(agent != address(0), "Agent not found");
        delete _owners[agentId];
        _balances[agent] -= 1;
        emit AgentRevoked(agentId);
    }

    /// @notice Check if address holds agent NFT(s)
    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    /// @notice Get owner of agent ID
    function ownerOf(uint256 agentId) external view returns (address) {
        address owner = _owners[agentId];
        require(owner != address(0), "Agent not found");
        return owner;
    }

    function nextId() external view returns (uint256) {
        return _nextId;
    }
}
