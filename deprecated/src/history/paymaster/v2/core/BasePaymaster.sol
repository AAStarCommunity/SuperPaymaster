// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title BasePaymaster
 * @notice Helper class for creating a paymaster
 * @dev Provides common functionality for paymasters:
 *      - EntryPoint integration (deposit, withdraw, stake)
 *      - Owner-only functions for managing funds
 *      - Standardized access control
 */
abstract contract BasePaymaster is IPaymaster, Ownable {
    /// @notice The EntryPoint contract (immutable for gas savings)
    IEntryPoint public immutable entryPoint;

    /**
     * @notice Constructor
     * @param _entryPoint The EntryPoint contract address
     * @param _owner The owner of this paymaster
     */
    constructor(IEntryPoint _entryPoint, address _owner) Ownable(_owner) {
        if (address(_entryPoint) == address(0)) {
            revert InvalidAddress(address(_entryPoint));
        }
        entryPoint = _entryPoint;
    }

    // ====================================
    // EntryPoint Management Functions
    // ====================================

    /**
     * @notice Deposit ETH to the EntryPoint on behalf of this paymaster
     * @dev Owner can deposit to fund gas payments
     */
    function deposit() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /**
     * @notice Withdraw ETH from EntryPoint
     * @param to Address to receive the withdrawn ETH
     * @param amount Amount of ETH to withdraw (in wei)
     */
    function withdrawTo(
        address payable to,
        uint256 amount
    ) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    /**
     * @notice Add stake to the EntryPoint
     * @param unstakeDelaySec Unstake delay in seconds
     */
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /**
     * @notice Unlock the stake (must wait for unstake delay)
     */
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /**
     * @notice Withdraw the stake
     * @param to Address to receive the withdrawn stake
     */
    function withdrawStake(address payable to) external onlyOwner {
        entryPoint.withdrawStake(to);
    }

    /**
     * @notice Get the current deposit balance in the EntryPoint
     * @return balance The current deposit balance
     */
    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // ====================================
    // Abstract Functions (must be implemented by derived contracts)
    // ====================================

    /**
     * @notice Validate a user operation (called by EntryPoint)
     * @dev Must be implemented by derived contracts
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external virtual returns (bytes memory context, uint256 validationData);

    /**
     * @notice Post-operation handler (called by EntryPoint after execution)
     * @dev Must be implemented by derived contracts
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external virtual;

    // ====================================
    // Modifiers
    // ====================================

    /**
     * @notice Ensure the caller is the EntryPoint
     */
    modifier onlyEntryPoint() {
        require(msg.sender == address(entryPoint), "BasePaymaster: caller is not EntryPoint");
        _;
    }

    // ====================================
    // Errors
    // ====================================

    error InvalidAddress(address addr);
}
