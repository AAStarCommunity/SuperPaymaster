// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
/**
 * @title IVersioned
 * @notice Interface for contracts with version tracking
 * @dev All V3 contracts should implement this interface for version management
 */
interface IVersioned {
    /**
     * @notice Get human-readable version string
     * @return versionString The version string (e.g., "v3.1.0")
     */
    function version() external view returns (string memory);
}
