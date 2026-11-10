// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title IAgentIdentityRegistry - ERC-8004 Agent Identity
/// @notice Interface for ERC-8004 compliant agent identity registries
/// @dev SuperPaymaster may call isRegisteredAgent(account) inside validatePaymasterUserOp when
///      governance configures a nonzero identity registry. That configured implementation MUST be
///      independently opcode- and storage-verified for ERC-7562 compliance before configuration:
///      (1) no banned opcodes (TIMESTAMP, NUMBER, BLOCKHASH, ORIGIN, COINBASE, etc.)
///      (2) isRegisteredAgent() must read only sender-associated storage slots.
///      A standard ERC-721 balance mapping can satisfy (2), but neither the interface nor
///      configuration proves either condition.
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
