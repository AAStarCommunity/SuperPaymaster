// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IEntryPointV6 {
    function balanceOf(address account) external view returns (uint256);
    function depositTo(address account) external payable;
    function withdrawTo(address payable withdrawAddress, uint256 amount) external;
}

/// @title SuperPaymasterV6
/// @notice A simple paymaster router for EntryPoint v0.6
/// @dev Routes user operations to registered paymasters for gas sponsorship
contract SuperPaymasterV6 {

    struct PaymasterPool {
        address paymaster;
        uint256 feeRate;
        bool isActive;
        uint256 successCount;
        uint256 totalAttempts;
        string name;
    }

    // State variables
    IEntryPointV6 public immutable entryPoint;
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
    constructor(
        address _entryPoint,
        address _owner,
        uint256 _routerFeeRate
    ) {
        require(_entryPoint != address(0), "Invalid EntryPoint address");
        require(_owner != address(0), "Invalid owner address");
        require(_routerFeeRate <= 10000, "Invalid fee rate");

        entryPoint = IEntryPointV6(_entryPoint);
        owner = _owner;
        routerFeeRate = _routerFeeRate;
    }

    /// @notice Register a paymaster to the router
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
    function getBestPaymaster() external view returns (address paymaster, uint256 feeRate) {
        uint256 bestFeeRate = type(uint256).max;
        address bestPaymaster = address(0);

        for (uint256 i = 0; i < paymasterList.length; i++) {
            address pm = paymasterList[i];
            PaymasterPool memory pool = paymasterPools[pm];

            if (pool.isActive && pool.feeRate < bestFeeRate) {
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
    function getActivePaymasters() external view returns (address[] memory activePaymasters) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < paymasterList.length; i++) {
            if (paymasterPools[paymasterList[i]].isActive) {
                activeCount++;
            }
        }

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
    function getPaymasterInfo(address _paymaster) external view returns (PaymasterPool memory pool) {
        return paymasterPools[_paymaster];
    }

    /// @notice Check if a paymaster is registered and active
    /// @param paymaster Address to check
    /// @return True if registered and active
    function isPaymasterActive(address paymaster) external view returns (bool) {
        return paymasterPools[paymaster].isActive;
    }

    /// @notice Get router statistics
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
    function getPaymasterCount() external view returns (uint256 count) {
        return paymasterList.length;
    }

    /// @notice Update router fee rate (only owner)
    function updateFeeRate(uint256 _newFeeRate) external onlyOwner {
        require(_newFeeRate <= 10000, "Invalid fee rate");
        uint256 oldFeeRate = routerFeeRate;
        routerFeeRate = _newFeeRate;
        emit RouterFeeUpdated(oldFeeRate, _newFeeRate);
    }

    /// @notice Get contract version
    function getVersion() external pure returns (string memory version) {
        return "SuperPaymasterV6-1.0.0";
    }

    /// @notice Internal function to check if paymaster is available
    function _isPaymasterAvailable(address _paymaster) internal view returns (bool available) {
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
    function withdrawTo(address payable withdrawAddress, uint256 amount)
        external
        onlyOwner
    {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    /// @notice Get deposit balance in EntryPoint
    function getDeposit() external view returns (uint256 balance) {
        return entryPoint.balanceOf(address(this));
    }
}
