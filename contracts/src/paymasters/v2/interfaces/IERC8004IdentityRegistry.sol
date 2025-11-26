// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IERC8004IdentityRegistry
 * @notice ERC-8004 Identity Registry interface for agent identification
 * @dev Based on ERC-721 with metadata extensions
 *      See: https://eips.ethereum.org/EIPS/eip-8004
 */
interface IERC8004IdentityRegistry {
    // ====================================
    // Data Structures
    // ====================================

    /// @notice Metadata entry for agent registration
    struct MetadataEntry {
        string key;
        bytes value;
    }

    // ====================================
    // Events
    // ====================================

    /// @notice Emitted when an agent is registered
    event Registered(uint256 indexed agentId, string tokenURI, address indexed owner);

    /// @notice Emitted when metadata is set
    event MetadataSet(uint256 indexed agentId, string indexed indexedKey, string key, bytes value);

    // ====================================
    // Registration Functions
    // ====================================

    /**
     * @notice Register a new agent with token URI and metadata
     * @param tokenURI URI pointing to agent registration JSON
     * @param metadata Array of metadata entries
     * @return agentId The newly registered agent ID
     */
    function register(string calldata tokenURI, MetadataEntry[] calldata metadata) external returns (uint256 agentId);

    /**
     * @notice Register a new agent with token URI only
     * @param tokenURI URI pointing to agent registration JSON
     * @return agentId The newly registered agent ID
     */
    function register(string calldata tokenURI) external returns (uint256 agentId);

    /**
     * @notice Register a new agent with default settings
     * @return agentId The newly registered agent ID
     */
    function register() external returns (uint256 agentId);

    // ====================================
    // Metadata Functions
    // ====================================

    /**
     * @notice Get metadata value for agent
     * @param agentId The agent token ID
     * @param key The metadata key
     * @return value The metadata value as bytes
     */
    function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory value);

    /**
     * @notice Set metadata for agent
     * @param agentId The agent token ID
     * @param key The metadata key
     * @param value The metadata value as bytes
     */
    function setMetadata(uint256 agentId, string calldata key, bytes calldata value) external;

    // ====================================
    // View Functions (inherited from ERC-721)
    // ====================================

    /**
     * @notice Get agent owner
     * @param agentId The agent token ID
     * @return owner The owner address
     */
    function ownerOf(uint256 agentId) external view returns (address owner);

    /**
     * @notice Get token URI for agent
     * @param agentId The agent token ID
     * @return uri The token URI
     */
    function tokenURI(uint256 agentId) external view returns (string memory uri);
}
