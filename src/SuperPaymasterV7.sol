// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEntryPoint {
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
    function withdrawTo(address payable withdrawAddress, uint256 amount) external;
}

/// @title SuperPaymasterV7
/// @notice A simple paymaster router for EntryPoint v0.7
/// @dev Routes user operations to registered paymasters for gas sponsorship
contract SuperPaymasterV7 {

    struct PaymasterPool {
        address paymaster;
        uint256 feeRate;
        bool isActive;
        uint256 successCount;
        uint256 totalAttempts;
        string name;
    }

    // State variables
    IEntryPoint public immutable entryPoint;
    mapping(address => PaymasterPool) public paymasterPools;
    address[] public paymasterList;
    uint256 public routerFeeRate;
    address public owner;

    // Events
    event PaymasterRegistered(address indexed paymaster, uint256 feeRate, string name);
    event PaymasterSelected(address indexed paymaster, address indexed user, uint256 feeRate);
    event RouterFeeUpdated(uint256 oldFeeRate, uint256 newFeeRate);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /// @notice Constructor
    /// @param _entryPoint Address of the EntryPoint contract
    /// @param _owner Address of the contract owner
    /// @param _routerFeeRate Fee rate for routing service (in basis points)
    constructor(
        address _entryPoint,
        address _owner,
        uint256 _routerFeeRate
    ) {
        require(_entryPoint != address(0), "Invalid EntryPoint address");
        require(_owner != address(0), "Invalid owner address");
        require(_routerFeeRate <= 10000, "Invalid fee rate");

        entryPoint = IEntryPoint(_entryPoint);
        owner = _owner;
        routerFeeRate = _routerFeeRate;
    }

    /// @notice Register a paymaster to the router
    /// @param _paymaster Address of the paymaster contract
    /// @param _feeRate Fee rate in basis points
    /// @param _name Human readable name for the paymaster
    function registerPaymaster(
        address _paymaster,
        uint256 _feeRate,
        string calldata _name
    ) external {
        require(_paymaster != address(0), "Invalid paymaster address");
        require(_feeRate <= 10000, "Invalid fee rate");
        require(bytes(_name).length > 0, "Name required");

        // If not already registered, add to list
        if (paymasterPools[_paymaster].paymaster == address(0)) {
            paymasterList.push(_paymaster);
        }

        paymasterPools[_paymaster] = PaymasterPool({
            paymaster: _paymaster,
            feeRate: _feeRate,
            isActive: true,
            successCount: 0,
            totalAttempts: 0,
            name: _name
        });

        emit PaymasterRegistered(_paymaster, _feeRate, _name);
    }

    /// @notice Get the best available paymaster
    /// @return paymaster Address of the best paymaster
    /// @return feeRate Fee rate of the selected paymaster
    function getBestPaymaster() external view returns (address paymaster, uint256 feeRate) {
        uint256 bestFeeRate = type(uint256).max;
        address bestPaymaster = address(0);

        for (uint256 i = 0; i < paymasterList.length; i++) {
            address pm = paymasterList[i];
            PaymasterPool memory pool = paymasterPools[pm];

            if (pool.isActive && pool.feeRate < bestFeeRate) {
                // Simple availability check - has contract code
                if (_isPaymasterAvailable(pm)) {
                    bestFeeRate = pool.feeRate;
                    bestPaymaster = pm;
                }
            }
        }

        require(bestPaymaster != address(0), "No paymaster available");
        return (bestPaymaster, bestFeeRate);
    }

    /// @notice Get list of active paymasters
    /// @return activePaymasters Array of active paymaster addresses
    function getActivePaymasters() external view returns (address[] memory activePaymasters) {
        // Count active paymasters
        uint256 activeCount = 0;
        for (uint256 i = 0; i < paymasterList.length; i++) {
            if (paymasterPools[paymasterList[i]].isActive) {
                activeCount++;
            }
        }

        // Build active paymasters array
        activePaymasters = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < paymasterList.length; i++) {
            if (paymasterPools[paymasterList[i]].isActive) {
                activePaymasters[index] = paymasterList[i];
                index++;
            }
        }

        return activePaymasters;
    }

    /// @notice Get paymaster information
    /// @param _paymaster Address of the paymaster
    /// @return feeRate Fee rate in basis points
    /// @return isActive Whether the paymaster is active
    /// @return successCount Number of successful operations
    /// @return totalAttempts Total number of attempts
    /// @return name Display name
    function getPaymasterInfo(address _paymaster) external view returns (
        uint256 feeRate,
        bool isActive,
        uint256 successCount,
        uint256 totalAttempts,
        string memory name
    ) {
        PaymasterPool memory pool = paymasterPools[_paymaster];
        return (pool.feeRate, pool.isActive, pool.successCount, pool.totalAttempts, pool.name);
    }

    /// @notice Check if a paymaster is registered and active
    /// @param paymaster Address to check
    /// @return True if registered and active
    function isPaymasterActive(address paymaster) external view returns (bool) {
        return paymasterPools[paymaster].isActive;
    }

    /// @notice Get router statistics
    /// @return totalPaymasters Total number of registered paymasters
    /// @return activePaymasters Number of active paymasters
    /// @return totalSuccessfulRoutes Total successful routes across all paymasters
    /// @return totalRoutes Total route attempts across all paymasters
    function getRouterStats() external view returns (
        uint256 totalPaymasters,
        uint256 activePaymasters,
        uint256 totalSuccessfulRoutes,
        uint256 totalRoutes
    ) {
        totalPaymasters = paymasterList.length;

        for (uint256 i = 0; i < paymasterList.length; i++) {
            PaymasterPool memory pool = paymasterPools[paymasterList[i]];

            if (pool.isActive) {
                activePaymasters++;
            }

            totalSuccessfulRoutes += pool.successCount;
            totalRoutes += pool.totalAttempts;
        }
    }

    /// @notice Get total number of registered paymasters
    /// @return count Total paymaster count
    function getPaymasterCount() external view returns (uint256 count) {
        return paymasterList.length;
    }

    /// @notice Update router fee rate (only owner)
    /// @param _newFeeRate New fee rate in basis points
    function updateFeeRate(uint256 _newFeeRate) external onlyOwner {
        require(_newFeeRate <= 10000, "Invalid fee rate");
        uint256 oldFeeRate = routerFeeRate;
        routerFeeRate = _newFeeRate;
        emit RouterFeeUpdated(oldFeeRate, _newFeeRate);
    }

    /// @notice Get contract version
    /// @return version Version string
    function getVersion() external pure returns (string memory version) {
        return "SuperPaymasterV7-1.0.0";
    }

    /// @notice Internal function to check if paymaster is available
    /// @param _paymaster Address of the paymaster to check
    /// @return available Whether the paymaster is available
    function _isPaymasterAvailable(address _paymaster) internal view returns (bool available) {
        // Simple check: has contract code
        uint256 size;
        assembly {
            size := extcodesize(_paymaster)
        }
        return size > 0;
    }

    /// @notice Deposit funds to EntryPoint for this router
    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @notice Withdraw funds from EntryPoint (only owner)
    /// @param withdrawAddress Address to receive the funds
    /// @param amount Amount to withdraw
    function withdrawTo(address payable withdrawAddress, uint256 amount)
        external
        onlyOwner
    {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    /// @notice Get deposit balance in EntryPoint
    /// @return balance Current deposit balance
    function getDeposit() external view returns (uint256 balance) {
        return entryPoint.balanceOf(address(this));
    }
}
