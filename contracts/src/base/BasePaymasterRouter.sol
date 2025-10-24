// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../../../src/interfaces/IPaymasterRouter.sol";

/// @title BasePaymasterRouter
/// @notice Base implementation for paymaster routing functionality
/// @dev Shared logic for all SuperPaymaster versions
abstract contract BasePaymasterRouter is IPaymasterRouter, Ownable, ReentrancyGuard {
    /// @notice Maximum fee rate (100% in basis points)
    uint256 public constant MAX_FEE_RATE = 10000;
    
    /// @notice Minimum fee rate (0% in basis points)
    uint256 public constant MIN_FEE_RATE = 0;

    /// @notice Mapping of paymaster address to pool information
    mapping(address => PaymasterPool) public paymasterPools;
    
    /// @notice Array of all registered paymaster addresses
    address[] public paymasterList;

    /// @notice Router fee rate (basis points taken by SuperPaymaster)
    uint256 public routerFeeRate;

    /// @notice Maximum number of paymasters to prevent gas limit issues
    uint256 public constant MAX_PAYMASTERS = 50;

    modifier onlyRegisteredPaymaster() {
        require(paymasterPools[msg.sender].paymaster != address(0), "Paymaster not registered");
        _;
    }

    modifier validFeeRate(uint256 _feeRate) {
        require(_feeRate <= MAX_FEE_RATE, "Fee rate exceeds maximum");
        _;
    }

    constructor(address _owner, uint256 _routerFeeRate) 
        Ownable(_owner) 
        validFeeRate(_routerFeeRate) 
    {
        routerFeeRate = _routerFeeRate;
    }

    /// @inheritdoc IPaymasterRouter
    function registerPaymaster(
        address _paymaster,
        uint256 _feeRate,
        string memory _name
    ) 
        external 
        validFeeRate(_feeRate)
        nonReentrant 
    {
        require(_paymaster != address(0), "Invalid paymaster address");
        require(paymasterPools[_paymaster].paymaster == address(0), "Paymaster already registered");
        require(paymasterList.length < MAX_PAYMASTERS, "Maximum paymasters reached");
        
        paymasterPools[_paymaster] = PaymasterPool({
            paymaster: _paymaster,
            feeRate: _feeRate,
            isActive: true,
            successCount: 0,
            totalAttempts: 0,
            name: _name
        });

        paymasterList.push(_paymaster);

        emit PaymasterRegistered(_paymaster, _feeRate, _name);
    }

    /// @inheritdoc IPaymasterRouter
    function updateFeeRate(uint256 _newFeeRate) 
        external 
        onlyRegisteredPaymaster 
        validFeeRate(_newFeeRate) 
    {
        uint256 oldFeeRate = paymasterPools[msg.sender].feeRate;
        paymasterPools[msg.sender].feeRate = _newFeeRate;
        
        emit FeeRateUpdated(msg.sender, oldFeeRate, _newFeeRate);
    }

    /// @inheritdoc IPaymasterRouter
    function setPaymasterStatus(address _paymaster, bool _isActive) 
        external 
        onlyOwner 
    {
        require(paymasterPools[_paymaster].paymaster != address(0), "Paymaster not registered");
        
        paymasterPools[_paymaster].isActive = _isActive;
        
        emit PaymasterStatusChanged(_paymaster, _isActive);
    }

    /// @inheritdoc IPaymasterRouter
    function getBestPaymaster() 
        external 
        view 
        returns (address paymaster, uint256 feeRate) 
    {
        uint256 lowestFeeRate = MAX_FEE_RATE + 1;
        address bestPaymaster = address(0);

        for (uint256 i = 0; i < paymasterList.length; i++) {
            address current = paymasterList[i];
            PaymasterPool memory pool = paymasterPools[current];

            if (pool.isActive && _isPaymasterAvailable(current)) {
                // Simple algorithm: choose lowest fee rate
                // In V2, we can add reputation scoring here
                if (pool.feeRate < lowestFeeRate) {
                    lowestFeeRate = pool.feeRate;
                    bestPaymaster = current;
                }
            }
        }

        require(bestPaymaster != address(0), "No available paymaster found");
        return (bestPaymaster, lowestFeeRate);
    }

    /// @inheritdoc IPaymasterRouter
    function getActivePaymasters() 
        external 
        view 
        returns (address[] memory paymasters) 
    {
        // Count active paymasters
        uint256 activeCount = 0;
        for (uint256 i = 0; i < paymasterList.length; i++) {
            if (paymasterPools[paymasterList[i]].isActive && 
                _isPaymasterAvailable(paymasterList[i])) {
                activeCount++;
            }
        }

        // Create array with active paymasters
        paymasters = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < paymasterList.length; i++) {
            address current = paymasterList[i];
            if (paymasterPools[current].isActive && _isPaymasterAvailable(current)) {
                paymasters[index] = current;
                index++;
            }
        }

        return paymasters;
    }

    /// @inheritdoc IPaymasterRouter
    function getPaymasterInfo(address _paymaster) 
        external 
        view 
        returns (PaymasterPool memory pool) 
    {
        require(paymasterPools[_paymaster].paymaster != address(0), "Paymaster not registered");
        return paymasterPools[_paymaster];
    }

    /// @inheritdoc IPaymasterRouter
    function getPaymasterCount() external view returns (uint256 count) {
        return paymasterList.length;
    }

    /// @inheritdoc IPaymasterRouter
    function updateStats(address _paymaster, bool _success) 
        external 
        onlyOwner 
    {
        require(paymasterPools[_paymaster].paymaster != address(0), "Paymaster not registered");
        
        paymasterPools[_paymaster].totalAttempts++;
        if (_success) {
            paymasterPools[_paymaster].successCount++;
        }

        emit StatsUpdated(
            _paymaster, 
            paymasterPools[_paymaster].successCount,
            paymasterPools[_paymaster].totalAttempts
        );
    }

    /// @notice Set router fee rate (only owner)
    /// @param _newFeeRate New router fee rate in basis points
    function setRouterFeeRate(uint256 _newFeeRate) 
        external 
        onlyOwner 
        validFeeRate(_newFeeRate) 
    {
        uint256 oldFeeRate = routerFeeRate;
        routerFeeRate = _newFeeRate;
        
        emit FeeRateUpdated(address(this), oldFeeRate, _newFeeRate);
    }

    /// @notice Check if a paymaster is available for routing
    /// @dev Override in child contracts to add version-specific checks
    /// @param _paymaster Address of the paymaster to check
    /// @return available Whether the paymaster is available
    function _isPaymasterAvailable(address _paymaster) 
        internal 
        view 
        virtual 
        returns (bool available) 
    {
        // Default implementation: just check if it's a contract
        return _paymaster.code.length > 0;
    }

    /// @notice Emergency function to remove a paymaster (only owner)
    /// @param _paymaster Address of the paymaster to remove
    function emergencyRemovePaymaster(address _paymaster) 
        external 
        onlyOwner 
    {
        require(paymasterPools[_paymaster].paymaster != address(0), "Paymaster not registered");
        
        // Mark as inactive
        paymasterPools[_paymaster].isActive = false;
        
        // Remove from list
        for (uint256 i = 0; i < paymasterList.length; i++) {
            if (paymasterList[i] == _paymaster) {
                paymasterList[i] = paymasterList[paymasterList.length - 1];
                paymasterList.pop();
                break;
            }
        }

        emit PaymasterStatusChanged(_paymaster, false);
    }

    /// @notice Get router statistics
    /// @return totalPaymasters Total number of registered paymasters
    /// @return activePaymasters Number of active paymasters
    /// @return totalSuccessfulRoutes Total successful routes across all paymasters
    /// @return totalRoutes Total route attempts across all paymasters
    function getRouterStats() 
        external 
        view 
        returns (
            uint256 totalPaymasters,
            uint256 activePaymasters,
            uint256 totalSuccessfulRoutes,
            uint256 totalRoutes
        ) 
    {
        totalPaymasters = paymasterList.length;
        
        for (uint256 i = 0; i < paymasterList.length; i++) {
            PaymasterPool memory pool = paymasterPools[paymasterList[i]];
            
            if (pool.isActive && _isPaymasterAvailable(paymasterList[i])) {
                activePaymasters++;
            }
            
            totalSuccessfulRoutes += pool.successCount;
            totalRoutes += pool.totalAttempts;
        }
    }
}