// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
/**
 * @title ISuperPaymasterRegistry - SuperPaymaster Registry Interface
 * @notice Interface for checking if a Paymaster is registered in SuperPaymaster
 * @dev Used by Settlement contract and other components to validate Paymaster authorization
 * @custom:version 1.2.0
 */
interface ISuperPaymasterRegistry {
    /**
     * @notice Get paymaster information
     * @param paymaster Address of the paymaster to query
     * @return feeRate Fee rate in basis points (100 = 1%)
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

    /**
     * @notice Get the best available paymaster based on fee rate
     * @return paymaster Address of the best paymaster
     * @return feeRate Fee rate of the selected paymaster
     */
    function getBestPaymaster() external view returns (address paymaster, uint256 feeRate);

    /**
     * @notice Get list of active paymasters
     * @return activePaymasters Array of active paymaster addresses
     */
    function getActivePaymasters() external view returns (address[] memory activePaymasters);

    /**
     * @notice Get router statistics
     * @return totalPaymasters Total number of registered paymasters
     * @return activePaymasters Number of active paymasters
     * @return totalSuccessfulRoutes Total successful routes
     * @return totalRoutes Total route attempts
     */
    function getRouterStats()
        external
        view
        returns (
            uint256 totalPaymasters,
            uint256 activePaymasters,
            uint256 totalSuccessfulRoutes,
            uint256 totalRoutes
        );

    /**
     * @notice Deactivate the caller's paymaster
     * @dev Only callable by registered paymaster, sets isActive to false
     * @dev Deactivate means: stop accepting new requests, but continue settlement & unstake
     */
    function deactivate() external;

    /**
     * @notice Activate the caller's paymaster
     * @dev Only callable by registered paymaster, sets isActive to true
     * @dev Activation requires passing Registry's qualification checks
     */
    function activate() external;
}
