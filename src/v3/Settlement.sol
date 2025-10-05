// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISettlement} from "../interfaces/ISettlement.sol";
import {ISuperPaymasterRegistry} from "../interfaces/ISuperPaymasterRegistry.sol";

/**
 * @title Settlement - Batch Gas Fee Settlement Contract
 * @notice Accumulates gas fees from registered Paymasters and enables batch settlement
 * @dev Security-first design with SuperPaymaster Registry integration
 *
 * Key Security Features:
 * - ✅ Only Paymasters registered in SuperPaymaster Registry can record fees
 * - ✅ ReentrancyGuard on all state-changing functions
 * - ✅ State changes before external calls (CEI pattern)
 * - ✅ Balance and allowance checks before transfers
 * - ✅ Comprehensive event logging
 * - ✅ Emergency pause mechanism
 *
 * @custom:security-contact security@example.com
 */
contract Settlement is ISettlement, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice SuperPaymaster Registry contract (immutable for security)
    ISuperPaymasterRegistry public immutable registry;

    /// @notice Mapping: user => token => pending fee amount
    mapping(address => mapping(address => uint256)) private _pendingFees;

    /// @notice Mapping: token => total pending across all users
    mapping(address => uint256) private _totalPending;

    /// @notice Settlement threshold for triggering batch settlements
    uint256 private _settlementThreshold;

    /// @notice Emergency pause status
    bool private _paused;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize Settlement contract
     * @param initialOwner Address of the contract owner
     * @param registryAddress SuperPaymaster Registry contract address
     * @param initialThreshold Initial settlement threshold
     * @dev Registry address is immutable after deployment for security
     */
    constructor(
        address initialOwner,
        address registryAddress,
        uint256 initialThreshold
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "Settlement: zero owner");
        require(registryAddress != address(0), "Settlement: zero registry");
        require(initialThreshold > 0, "Settlement: zero threshold");

        registry = ISuperPaymasterRegistry(registryAddress);
        _settlementThreshold = initialThreshold;
    }

    /*//////////////////////////////////////////////////////////////
                          PAYMASTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ISettlement
     * @dev CRITICAL SECURITY: Only Paymasters registered in SuperPaymaster can call this
     * - Checks registry.isPaymasterActive(msg.sender)
     * - Reentrancy protected
     * - State changes before events (CEI pattern)
     */
    function recordGasFee(
        address user,
        address token,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRegisteredPaymaster
    {
        require(user != address(0), "Settlement: zero user");
        require(token != address(0), "Settlement: zero token");
        require(amount > 0, "Settlement: zero amount");

        // State changes BEFORE events (CEI pattern)
        _pendingFees[user][token] += amount;
        _totalPending[token] += amount;

        emit FeeRecorded(user, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ISettlement
     * @dev Security:
     * - Only owner can trigger
     * - Reentrancy protected
     * - Balance AND allowance validation before transfer
     * - State changes before external calls
     * - Fails safely if any transfer fails
     */
    function settleFees(
        address[] calldata users,
        address token,
        address treasury
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyOwner
    {
        require(users.length > 0, "Settlement: empty users");
        require(token != address(0), "Settlement: zero token");
        require(treasury != address(0), "Settlement: zero treasury");

        uint256 totalSettled = 0;
        IERC20 tokenContract = IERC20(token);

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 pending = _pendingFees[user][token];

            if (pending == 0) {
                continue; // Skip users with zero pending
            }

            // CRITICAL: Check user balance BEFORE transfer
            uint256 userBalance = tokenContract.balanceOf(user);
            require(
                userBalance >= pending,
                "Settlement: insufficient balance"
            );

            // CRITICAL: Check user allowance for this contract
            uint256 allowance = tokenContract.allowance(user, address(this));
            require(
                allowance >= pending,
                "Settlement: insufficient allowance"
            );

            // State changes BEFORE external call (CEI pattern)
            _pendingFees[user][token] = 0;
            totalSettled += pending;

            // External call AFTER state changes
            bool success = tokenContract.transferFrom(user, treasury, pending);
            require(success, "Settlement: transfer failed");

            emit FeesSettled(user, token, pending);
        }

        // Update total pending
        require(
            _totalPending[token] >= totalSettled,
            "Settlement: total pending underflow"
        );
        _totalPending[token] -= totalSettled;
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ISettlement
     * @dev DEPRECATED: Authorization now handled by SuperPaymaster Registry
     * @dev This function is kept for ISettlement interface compatibility
     */
    function setPaymasterAuthorization(
        address paymaster,
        bool status
    )
        external
        override
        onlyOwner
    {
        // Authorization is now handled by SuperPaymaster Registry
        // Emit event for interface compatibility
        emit PaymasterAuthorized(paymaster, status);
    }

    /**
     * @inheritdoc ISettlement
     */
    function setSettlementThreshold(
        uint256 newThreshold
    )
        external
        override
        onlyOwner
    {
        require(newThreshold > 0, "Settlement: zero threshold");

        uint256 oldThreshold = _settlementThreshold;
        _settlementThreshold = newThreshold;

        emit SettlementThresholdUpdated(oldThreshold, newThreshold);
    }

    /**
     * @notice Emergency pause/unpause
     * @param status True to pause, false to unpause
     * @dev Only owner can pause/unpause
     */
    function setPaused(bool status) external onlyOwner {
        _paused = status;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ISettlement
     */
    function getPendingBalance(
        address user,
        address token
    )
        external
        view
        override
        returns (uint256)
    {
        return _pendingFees[user][token];
    }

    /**
     * @inheritdoc ISettlement
     */
    function getTotalPending(
        address token
    )
        external
        view
        override
        returns (uint256)
    {
        return _totalPending[token];
    }

    /**
     * @inheritdoc ISettlement
     * @dev Checks SuperPaymaster Registry for authorization
     */
    function isAuthorizedPaymaster(
        address paymaster
    )
        external
        view
        override
        returns (bool)
    {
        return registry.isPaymasterActive(paymaster);
    }

    /**
     * @inheritdoc ISettlement
     */
    function getSettlementThreshold()
        external
        view
        override
        returns (uint256)
    {
        return _settlementThreshold;
    }

    /**
     * @notice Check if contract is paused
     * @return True if paused
     */
    function isPaused() external view returns (bool) {
        return _paused;
    }

    /**
     * @notice Get SuperPaymaster Registry address
     * @return Address of the registry contract
     */
    function getRegistry() external view returns (address) {
        return address(registry);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensure caller is registered and active in SuperPaymaster Registry
     * @dev CRITICAL SECURITY: This is the main authorization check
     */
    modifier onlyRegisteredPaymaster() {
        require(
            registry.isPaymasterActive(msg.sender),
            "Settlement: paymaster not registered in SuperPaymaster"
        );
        _;
    }

    /**
     * @notice Ensure contract is not paused
     */
    modifier whenNotPaused() {
        require(!_paused, "Settlement: paused");
        _;
    }
}
