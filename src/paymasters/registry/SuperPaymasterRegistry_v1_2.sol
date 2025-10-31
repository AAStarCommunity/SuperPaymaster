// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";

/// @title SuperPaymasterRegistry v1.2
/// @notice Central registry for managing multiple Paymaster nodes with staking and reputation
/// @dev Combines multi-tenant management, reputation tracking, and routing capabilities
/// @custom:version 1.2.0
/// @custom:security-contact security@aastar.community
contract SuperPaymasterRegistry is Ownable, ReentrancyGuard {

    /*//////////////////////////////////////////////////////////////
                            TYPE DEFINITIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Paymaster information structure
    /// @param paymasterAddress Address of the paymaster contract
    /// @param name Human-readable name for identification
    /// @param feeRate Fee rate in basis points (100 = 1%)
    /// @param stakedAmount ETH staked by this paymaster
    /// @param reputation Reputation score (0-10000)
    /// @param isActive Whether the paymaster is currently active
    /// @param successCount Number of successful operations
    /// @param totalAttempts Total number of operation attempts
    /// @param registeredAt Timestamp when registered
    /// @param lastActiveAt Timestamp of last activity
    struct PaymasterInfo {
        address paymasterAddress;
        string name;
        uint256 feeRate;
        uint256 stakedAmount;
        uint256 reputation;
        bool isActive;
        uint256 successCount;
        uint256 totalAttempts;
        uint256 registeredAt;
        uint256 lastActiveAt;
    }

    /// @notice Bid information for paymaster auction
    /// @param bidAmount Bid amount in wei
    /// @param bidTime Timestamp of the bid
    /// @param isActive Whether bid is still active
    struct PaymasterBid {
        uint256 bidAmount;
        uint256 bidTime;
        bool isActive;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version
    string public constant VERSION = "SuperPaymasterRegistry-v1.2.0";

    /// @notice Minimum stake required to register as paymaster
    uint256 public minStakeAmount;

    /// @notice Router fee rate in basis points
    uint256 public routerFeeRate;

    /// @notice Slash percentage when paymaster misbehaves (basis points)
    uint256 public slashPercentage;

    /// @notice Treasury address for collecting fees
    address public treasury;

    /// @notice Mapping of paymaster address to info
    mapping(address => PaymasterInfo) public paymasters;

    /// @notice Array of all registered paymaster addresses
    address[] public paymasterList;

    /// @notice Mapping of paymaster to their current bid
    mapping(address => PaymasterBid) public paymasterBids;

    /// @notice Total ETH staked across all paymasters
    uint256 public totalStaked;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PaymasterRegistered(
        address indexed paymaster,
        string name,
        uint256 feeRate,
        uint256 stakedAmount
    );

    event PaymasterStakeAdded(
        address indexed paymaster,
        uint256 amount,
        uint256 newTotalStake
    );

    event PaymasterStakeWithdrawn(
        address indexed paymaster,
        uint256 amount,
        uint256 remainingStake
    );

    event PaymasterSlashed(
        address indexed paymaster,
        uint256 slashedAmount,
        string reason
    );

    event PaymasterActivated(address indexed paymaster);
    event PaymasterDeactivated(address indexed paymaster);

    event PaymasterFeeRateUpdated(
        address indexed paymaster,
        uint256 oldFeeRate,
        uint256 newFeeRate
    );

    event PaymasterReputationUpdated(
        address indexed paymaster,
        uint256 oldReputation,
        uint256 newReputation
    );

    event PaymasterBidPlaced(
        address indexed paymaster,
        uint256 bidAmount
    );

    event PaymasterSelected(
        address indexed paymaster,
        address indexed user,
        uint256 feeRate
    );

    event RouterFeeUpdated(uint256 oldFeeRate, uint256 newFeeRate);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event MinStakeUpdated(uint256 oldMinStake, uint256 newMinStake);
    event SlashPercentageUpdated(uint256 oldPercentage, uint256 newPercentage);

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error SuperPaymasterRegistry__ZeroAddress();
    error SuperPaymasterRegistry__InvalidFeeRate();
    error SuperPaymasterRegistry__InsufficientStake();
    error SuperPaymasterRegistry__PaymasterNotRegistered();
    error SuperPaymasterRegistry__PaymasterAlreadyRegistered();
    error SuperPaymasterRegistry__PaymasterNotActive();
    error SuperPaymasterRegistry__NoPaymasterAvailable();
    error SuperPaymasterRegistry__InvalidReputation();
    error SuperPaymasterRegistry__InsufficientBalance();
    error SuperPaymasterRegistry__InvalidName();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the SuperPaymaster Registry
    /// @param _owner Owner address
    /// @param _treasury Treasury address for fees
    /// @param _minStakeAmount Minimum stake required
    /// @param _routerFeeRate Router fee rate in basis points
    /// @param _slashPercentage Slash percentage in basis points
    constructor(
        address _owner,
        address _treasury,
        uint256 _minStakeAmount,
        uint256 _routerFeeRate,
        uint256 _slashPercentage
    ) Ownable(_owner) {
        if (_treasury == address(0)) revert SuperPaymasterRegistry__ZeroAddress();
        if (_routerFeeRate > 10000) revert SuperPaymasterRegistry__InvalidFeeRate();
        if (_slashPercentage > 10000) revert SuperPaymasterRegistry__InvalidFeeRate();

        treasury = _treasury;
        minStakeAmount = _minStakeAmount;
        routerFeeRate = _routerFeeRate;
        slashPercentage = _slashPercentage;
    }

    /*//////////////////////////////////////////////////////////////
                        PAYMASTER MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a new paymaster with stake
    /// @param _name Human-readable name
    /// @param _feeRate Fee rate in basis points
    function registerPaymaster(
        string calldata _name,
        uint256 _feeRate
    ) external payable nonReentrant {
        if (bytes(_name).length == 0) revert SuperPaymasterRegistry__InvalidName();
        if (_feeRate > 10000) revert SuperPaymasterRegistry__InvalidFeeRate();
        if (msg.value < minStakeAmount) revert SuperPaymasterRegistry__InsufficientStake();
        if (paymasters[msg.sender].paymasterAddress != address(0)) {
            revert SuperPaymasterRegistry__PaymasterAlreadyRegistered();
        }

        // Add to list if new
        paymasterList.push(msg.sender);

        // Create paymaster info
        paymasters[msg.sender] = PaymasterInfo({
            paymasterAddress: msg.sender,
            name: _name,
            feeRate: _feeRate,
            stakedAmount: msg.value,
            reputation: 5000, // Start with 50% reputation
            isActive: true,
            successCount: 0,
            totalAttempts: 0,
            registeredAt: block.timestamp,
            lastActiveAt: block.timestamp
        });

        totalStaked += msg.value;

        emit PaymasterRegistered(msg.sender, _name, _feeRate, msg.value);
    }

    /// @notice Add more stake to existing paymaster
    function addStake() external payable nonReentrant {
        PaymasterInfo storage pm = paymasters[msg.sender];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }

        pm.stakedAmount += msg.value;
        totalStaked += msg.value;

        emit PaymasterStakeAdded(msg.sender, msg.value, pm.stakedAmount);
    }

    /// @notice Withdraw stake (only if above minimum)
    /// @param _amount Amount to withdraw
    function withdrawStake(uint256 _amount) external nonReentrant {
        PaymasterInfo storage pm = paymasters[msg.sender];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }

        uint256 remainingStake = pm.stakedAmount - _amount;
        if (remainingStake < minStakeAmount) {
            revert SuperPaymasterRegistry__InsufficientStake();
        }

        pm.stakedAmount = remainingStake;
        totalStaked -= _amount;

        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "ETH transfer failed");

        emit PaymasterStakeWithdrawn(msg.sender, _amount, remainingStake);
    }

    /// @notice Update paymaster fee rate
    /// @param _newFeeRate New fee rate in basis points
    function updateFeeRate(uint256 _newFeeRate) external {
        PaymasterInfo storage pm = paymasters[msg.sender];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }
        if (_newFeeRate > 10000) revert SuperPaymasterRegistry__InvalidFeeRate();

        uint256 oldFeeRate = pm.feeRate;
        pm.feeRate = _newFeeRate;

        emit PaymasterFeeRateUpdated(msg.sender, oldFeeRate, _newFeeRate);
    }

    /// @notice Activate paymaster
    function activate() external {
        PaymasterInfo storage pm = paymasters[msg.sender];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }

        pm.isActive = true;
        pm.lastActiveAt = block.timestamp;

        emit PaymasterActivated(msg.sender);
    }

    /// @notice Deactivate paymaster
    function deactivate() external {
        PaymasterInfo storage pm = paymasters[msg.sender];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }

        pm.isActive = false;

        emit PaymasterDeactivated(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        BIDDING MECHANISM
    //////////////////////////////////////////////////////////////*/

    /// @notice Place a bid for routing priority
    /// @param _bidAmount Bid amount in wei
    function placeBid(uint256 _bidAmount) external {
        PaymasterInfo storage pm = paymasters[msg.sender];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }
        if (!pm.isActive) revert SuperPaymasterRegistry__PaymasterNotActive();

        paymasterBids[msg.sender] = PaymasterBid({
            bidAmount: _bidAmount,
            bidTime: block.timestamp,
            isActive: true
        });

        emit PaymasterBidPlaced(msg.sender, _bidAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        ROUTING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the best available paymaster based on fee rate
    /// @return paymaster Address of the best paymaster
    /// @return feeRate Fee rate of the selected paymaster
    function getBestPaymaster() external view returns (address paymaster, uint256 feeRate) {
        uint256 bestFeeRate = type(uint256).max;
        address bestPaymaster = address(0);

        for (uint256 i = 0; i < paymasterList.length; i++) {
            address pm = paymasterList[i];
            PaymasterInfo memory info = paymasters[pm];

            if (info.isActive && info.feeRate < bestFeeRate) {
                bestFeeRate = info.feeRate;
                bestPaymaster = pm;
            }
        }

        if (bestPaymaster == address(0)) {
            revert SuperPaymasterRegistry__NoPaymasterAvailable();
        }

        return (bestPaymaster, bestFeeRate);
    }

    /// @notice Get paymaster with lowest bid
    /// @return paymaster Address of the lowest bidder
    function getLowestBidPaymaster() external view returns (address paymaster) {
        uint256 lowestBid = type(uint256).max;
        address lowestBidder = address(0);

        for (uint256 i = 0; i < paymasterList.length; i++) {
            address pm = paymasterList[i];
            PaymasterInfo memory info = paymasters[pm];
            PaymasterBid memory bid = paymasterBids[pm];

            if (info.isActive && bid.isActive && bid.bidAmount < lowestBid) {
                lowestBid = bid.bidAmount;
                lowestBidder = pm;
            }
        }

        if (lowestBidder == address(0)) {
            revert SuperPaymasterRegistry__NoPaymasterAvailable();
        }

        return lowestBidder;
    }

    /// @notice Get list of active paymasters
    /// @return activePaymasters Array of active paymaster addresses
    function getActivePaymasters() external view returns (address[] memory activePaymasters) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < paymasterList.length; i++) {
            if (paymasters[paymasterList[i]].isActive) {
                activeCount++;
            }
        }

        activePaymasters = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < paymasterList.length; i++) {
            if (paymasters[paymasterList[i]].isActive) {
                activePaymasters[index] = paymasterList[i];
                index++;
            }
        }

        return activePaymasters;
    }

    /*//////////////////////////////////////////////////////////////
                    REPUTATION & STATS MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Update paymaster reputation (only owner)
    /// @param _paymaster Paymaster address
    /// @param _newReputation New reputation score (0-10000)
    function updateReputation(
        address _paymaster,
        uint256 _newReputation
    ) external onlyOwner {
        PaymasterInfo storage pm = paymasters[_paymaster];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }
        if (_newReputation > 10000) revert SuperPaymasterRegistry__InvalidReputation();

        uint256 oldReputation = pm.reputation;
        pm.reputation = _newReputation;

        emit PaymasterReputationUpdated(_paymaster, oldReputation, _newReputation);
    }

    /// @notice Record successful operation
    /// @param _paymaster Paymaster address
    function recordSuccess(address _paymaster) external onlyOwner {
        PaymasterInfo storage pm = paymasters[_paymaster];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }

        pm.successCount++;
        pm.totalAttempts++;
        pm.lastActiveAt = block.timestamp;

        // Auto-update reputation based on success rate
        if (pm.totalAttempts > 0) {
            uint256 successRate = (pm.successCount * 10000) / pm.totalAttempts;
            pm.reputation = successRate;
        }
    }

    /// @notice Record failed operation
    /// @param _paymaster Paymaster address
    function recordFailure(address _paymaster) external onlyOwner {
        PaymasterInfo storage pm = paymasters[_paymaster];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }

        pm.totalAttempts++;
        pm.lastActiveAt = block.timestamp;

        // Auto-update reputation based on success rate
        if (pm.totalAttempts > 0) {
            uint256 successRate = (pm.successCount * 10000) / pm.totalAttempts;
            pm.reputation = successRate;
        }
    }

    /// @notice Slash paymaster stake for misbehavior (only owner)
    /// @param _paymaster Paymaster address
    /// @param _reason Reason for slashing
    function slashPaymaster(
        address _paymaster,
        string calldata _reason
    ) external onlyOwner nonReentrant {
        PaymasterInfo storage pm = paymasters[_paymaster];
        if (pm.paymasterAddress == address(0)) {
            revert SuperPaymasterRegistry__PaymasterNotRegistered();
        }

        uint256 slashAmount = (pm.stakedAmount * slashPercentage) / 10000;
        pm.stakedAmount -= slashAmount;
        totalStaked -= slashAmount;

        // Deactivate if stake falls below minimum (CEI: State modification before external call)
        if (pm.stakedAmount < minStakeAmount) {
            pm.isActive = false;
        }

        emit PaymasterSlashed(_paymaster, slashAmount, _reason);

        // Send slashed amount to treasury (CEI: External call last)
        (bool success, ) = treasury.call{value: slashAmount}("");
        require(success, "ETH transfer failed");
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get paymaster information (ISuperPaymasterRegistry interface)
    /// @param paymaster Address of the paymaster
    /// @return feeRate Fee rate in basis points
    /// @return isActive Whether the paymaster is active
    /// @return successCount Number of successful operations
    /// @return totalAttempts Total number of attempts
    /// @return name Display name
    function getPaymasterInfo(address paymaster)
        external
        view
        returns (
            uint256 feeRate,
            bool isActive,
            uint256 successCount,
            uint256 totalAttempts,
            string memory name
        )
    {
        PaymasterInfo memory pm = paymasters[paymaster];
        return (pm.feeRate, pm.isActive, pm.successCount, pm.totalAttempts, pm.name);
    }

    /// @notice Check if a paymaster is registered and active
    /// @param paymaster Address to check
    /// @return True if registered and active
    function isPaymasterActive(address paymaster) external view returns (bool) {
        return paymasters[paymaster].isActive;
    }

    /// @notice Get complete paymaster information
    /// @param _paymaster Paymaster address
    /// @return info Complete PaymasterInfo struct
    function getPaymasterFullInfo(address _paymaster)
        external
        view
        returns (PaymasterInfo memory info)
    {
        return paymasters[_paymaster];
    }

    /// @notice Get router statistics
    /// @return totalPaymasters Total number of registered paymasters
    /// @return activePaymasters Number of active paymasters
    /// @return totalSuccessfulRoutes Total successful routes
    /// @return totalRoutes Total route attempts
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
            PaymasterInfo memory pm = paymasters[paymasterList[i]];

            if (pm.isActive) {
                activePaymasters++;
            }

            totalSuccessfulRoutes += pm.successCount;
            totalRoutes += pm.totalAttempts;
        }
    }

    /// @notice Get total number of registered paymasters
    /// @return count Total paymaster count
    function getPaymasterCount() external view returns (uint256 count) {
        return paymasterList.length;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update router fee rate (only owner)
    /// @param _newFeeRate New fee rate in basis points
    function updateRouterFeeRate(uint256 _newFeeRate) external onlyOwner {
        if (_newFeeRate > 10000) revert SuperPaymasterRegistry__InvalidFeeRate();

        uint256 oldFeeRate = routerFeeRate;
        routerFeeRate = _newFeeRate;

        emit RouterFeeUpdated(oldFeeRate, _newFeeRate);
    }

    /// @notice Update treasury address (only owner)
    /// @param _newTreasury New treasury address
    function updateTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert SuperPaymasterRegistry__ZeroAddress();

        address oldTreasury = treasury;
        treasury = _newTreasury;

        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    /// @notice Update minimum stake amount (only owner)
    /// @param _newMinStake New minimum stake amount
    function updateMinStake(uint256 _newMinStake) external onlyOwner {
        uint256 oldMinStake = minStakeAmount;
        minStakeAmount = _newMinStake;

        emit MinStakeUpdated(oldMinStake, _newMinStake);
    }

    /// @notice Update slash percentage (only owner)
    /// @param _newPercentage New slash percentage in basis points
    function updateSlashPercentage(uint256 _newPercentage) external onlyOwner {
        if (_newPercentage > 10000) revert SuperPaymasterRegistry__InvalidFeeRate();

        uint256 oldPercentage = slashPercentage;
        slashPercentage = _newPercentage;

        emit SlashPercentageUpdated(oldPercentage, _newPercentage);
    }

    /// @notice Receive ETH
    receive() external payable {}
}
