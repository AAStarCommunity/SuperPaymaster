// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPaymasterRouter
/// @notice Interface for paymaster routing functionality
/// @dev Common interface for all SuperPaymaster versions
interface IPaymasterRouter {
    /// @notice Information about registered paymasters
    struct PaymasterPool {
        address paymaster;      // Address of the actual paymaster contract
        uint256 feeRate;       // Fee rate in basis points (100 = 1%)
        bool isActive;         // Whether the paymaster is currently active
        uint256 successCount;  // Number of successful transactions (simple reputation)
        uint256 totalAttempts; // Total number of routing attempts
        string name;           // Optional display name
    }

    /// @notice Emitted when a paymaster is registered
    event PaymasterRegistered(
        address indexed paymaster,
        uint256 feeRate,
        string name
    );

    /// @notice Emitted when a paymaster updates their fee rate
    event FeeRateUpdated(
        address indexed paymaster,
        uint256 oldFeeRate,
        uint256 newFeeRate
    );

    /// @notice Emitted when a paymaster is activated/deactivated
    event PaymasterStatusChanged(
        address indexed paymaster,
        bool isActive
    );

    /// @notice Emitted when a paymaster is selected for routing
    event PaymasterSelected(
        address indexed paymaster,
        address indexed user,
        uint256 feeRate
    );

    /// @notice Emitted when routing statistics are updated
    event StatsUpdated(
        address indexed paymaster,
        uint256 successCount,
        uint256 totalAttempts
    );

    /// @notice Register a paymaster in the router
    /// @param _paymaster Address of the paymaster contract
    /// @param _feeRate Fee rate in basis points (100 = 1%)
    /// @param _name Display name for the paymaster
    function registerPaymaster(
        address _paymaster,
        uint256 _feeRate,
        string memory _name
    ) external;

    /// @notice Update fee rate for registered paymaster
    /// @param _newFeeRate New fee rate in basis points
    function updateFeeRate(uint256 _newFeeRate) external;

    /// @notice Activate/deactivate a paymaster (only owner)
    /// @param _paymaster Address of the paymaster
    /// @param _isActive New active status
    function setPaymasterStatus(address _paymaster, bool _isActive) external;

    /// @notice Get the best available paymaster
    /// @return paymaster Address of the selected paymaster
    /// @return feeRate Fee rate of the selected paymaster
    function getBestPaymaster() external view returns (address paymaster, uint256 feeRate);

    /// @notice Get all active paymasters
    /// @return paymasters Array of active paymaster addresses
    function getActivePaymasters() external view returns (address[] memory paymasters);

    /// @notice Get paymaster information
    /// @param _paymaster Address of the paymaster
    /// @return pool PaymasterPool struct with all information
    function getPaymasterInfo(address _paymaster) external view returns (PaymasterPool memory pool);

    /// @notice Get total number of registered paymasters
    /// @return count Total paymaster count
    function getPaymasterCount() external view returns (uint256 count);

    /// @notice Update routing statistics (internal use)
    /// @param _paymaster Address of the paymaster
    /// @param _success Whether the routing was successful
    function updateStats(address _paymaster, bool _success) external;
}