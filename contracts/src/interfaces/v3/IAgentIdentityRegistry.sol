// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title IAgentIdentityRegistry - ERC-8004 Agent Identity
/// @notice Interface for ERC-8004 compliant agent identity registries
/// @dev SuperPaymaster calls isRegisteredAgent(account) inside validatePaymasterUserOp.
///      Implementing contracts MUST be ERC-7562 compliant:
///      (1) no banned opcodes (TIMESTAMP, NUMBER, BLOCKHASH, ORIGIN, COINBASE, etc.)
///      (2) isRegisteredAgent() must read only sender-associated storage slots.
///      Standard ERC-721 balanceOf(_balances[account]) satisfies (2); implementors
///      must ensure (1) by avoiding environment-dependent opcodes in their logic.
interface IAgentIdentityRegistry {
    /// @notice Check if an address is a registered ERC-8004 agent
    /// @param account The address to query
    /// @return True if the address holds a valid agent identity
    function isRegisteredAgent(address account) external view returns (bool);

    /// @notice ERC-721 compatibility: token balance for an owner
    function balanceOf(address owner) external view returns (uint256);

    /// @notice ERC-721 compatibility: owner of a specific token
    function ownerOf(uint256 agentId) external view returns (address);
}
