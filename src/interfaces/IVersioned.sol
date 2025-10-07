// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IVersioned
 * @notice Interface for contracts with version tracking
 * @dev All V3 contracts should implement this interface for version management
 */
interface IVersioned {
    /**
     * @notice Get contract version number
     * @dev Version format: MAJOR * 1000000 + MINOR * 1000 + PATCH
     *      Example: v1.2.3 => 1002003
     * @return version The semantic version as a uint256
     */
    function version() external pure returns (uint256);

    /**
     * @notice Get human-readable version string
     * @return versionString The version in "vX.Y.Z" format
     */
    function versionString() external pure returns (string memory);
}
