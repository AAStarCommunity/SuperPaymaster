// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ISuperPaymasterRegistry - SuperPaymaster Registry Interface
 * @notice Interface for checking if a Paymaster is registered in SuperPaymaster
 * @dev Used by Settlement contract to validate Paymaster authorization
 */
interface ISuperPaymasterRegistry {
    /**
     * @notice Get paymaster information
     * @param paymaster Address of the paymaster to query
     * @return feeRate Fee rate in basis points
     * @return isActive Whether the paymaster is active
     * @return successCount Number of successful operations
     * @return totalAttempts Total number of attempts
     * @return name Display name
     */
    function getPaymasterInfo(address paymaster)
        external
        view
        returns (
            uint256 feeRate,
            bool isActive,
            uint256 successCount,
            uint256 totalAttempts,
            string memory name
        );

    /**
     * @notice Check if a paymaster is registered and active
     * @param paymaster Address to check
     * @return True if registered and active
     */
    function isPaymasterActive(address paymaster) external view returns (bool);
}
