// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "../singleton-paymaster/src/interfaces/IPaymasterV7.sol";
import "../singleton-paymaster/src/interfaces/PostOpMode.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/// @title SimplePaymasterV7
/// @notice A simple paymaster template for EntryPoint v0.7
/// @dev Provides basic gas sponsorship functionality for all users
contract SimplePaymasterV7 is IPaymasterV7, Ownable {
    IEntryPoint public immutable entryPoint;
    
    /// @notice Sponsored operation events
    event UserOperationSponsored(
        address indexed sender,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    );

    /// @notice Deposit events
    event DepositReceived(address indexed from, uint256 amount);
    event WithdrawalMade(address indexed to, uint256 amount);

    /// @notice Only allow calls from the EntryPoint
    modifier onlyEntryPoint() {
        require(msg.sender == address(entryPoint), "Only EntryPoint can call");
        _;
    }

    /// @notice Constructor
    /// @param _entryPoint Address of the EntryPoint contract
    /// @param _owner Address of the contract owner
    constructor(address _entryPoint, address _owner) Ownable(_owner) {
        require(_entryPoint != address(0), "Invalid EntryPoint address");
        entryPoint = IEntryPoint(_entryPoint);
    }

    /// @notice Validate paymaster user operation
    /// @dev This simple paymaster sponsors all operations (be careful in production!)
    /// @param userOp The user operation to validate
    /// @param userOpHash Hash of the user operation
    /// @param requiredPreFund Required prefund for the operation
    /// @return context Context for postOp (empty in this simple implementation)
    /// @return validationData Validation result (0 = success)
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // Simple validation: sponsor all operations
        // In production, you'd add:
        // - Whitelist checks
        // - Rate limiting
        // - Balance checks
        // - Fee calculations
        
        // Check if we have enough balance
        require(
            entryPoint.balanceOf(address(this)) >= requiredPreFund,
            "Insufficient paymaster balance"
        );

        // Return success with context for postOp
        context = abi.encode(userOp.sender, requiredPreFund);
        validationData = 0; // Success
    }

    /// @notice Post-operation handler
    /// @param mode The mode (see PostOpMode enum)
    /// @param context Context from validatePaymasterUserOp
    /// @param actualGasCost Actual gas cost of the operation
    /// @param actualUserOpFeePerGas Actual fee per gas used
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external onlyEntryPoint {
        // Decode context
        (address sender, uint256 requiredPreFund) = abi.decode(context, (address, uint256));
        
        // Emit event for tracking
        emit UserOperationSponsored(sender, actualGasCost, actualUserOpFeePerGas);
        
        // In a production paymaster, you might:
        // - Charge the user in tokens
        // - Update usage statistics
        // - Apply rate limits
        // - Handle failed operations differently
    }

    /// @notice Deposit ETH to the EntryPoint for this paymaster
    function deposit() external payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit DepositReceived(msg.sender, msg.value);
    }

    /// @notice Get the current balance of this paymaster in the EntryPoint
    /// @return balance Current balance
    function getDeposit() external view returns (uint256 balance) {
        return entryPoint.balanceOf(address(this));
    }

    /// @notice Withdraw ETH from the EntryPoint (only owner)
    /// @param withdrawAddress Address to receive the withdrawn ETH
    /// @param amount Amount to withdraw
    function withdrawTo(address payable withdrawAddress, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(withdrawAddress, amount);
        emit WithdrawalMade(withdrawAddress, amount);
    }

    /// @notice Emergency withdraw all ETH (only owner)
    /// @param withdrawAddress Address to receive all ETH
    function emergencyWithdraw(address payable withdrawAddress) external onlyOwner {
        uint256 balance = entryPoint.balanceOf(address(this));
        if (balance > 0) {
            entryPoint.withdrawTo(withdrawAddress, balance);
            emit WithdrawalMade(withdrawAddress, balance);
        }
    }

    /// @notice Add stake to the EntryPoint (only owner)
    /// @param unstakeDelaySec Unstake delay in seconds
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @notice Start unstake process (only owner)
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /// @notice Withdraw stake (only owner)
    /// @param withdrawAddress Address to receive the stake
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    /// @notice Get paymaster information
    /// @return name Human readable name
    /// @return version Version string
    /// @return balance Current balance in EntryPoint
    /// @return owner Contract owner
    function getPaymasterInfo() external view returns (
        string memory name,
        string memory version,
        uint256 balance,
        address owner
    ) {
        return (
            "Simple Paymaster V7",
            "1.0.0",
            entryPoint.balanceOf(address(this)),
            owner()
        );
    }

    /// @notice Check if this paymaster can sponsor a user operation
    /// @param requiredGas Estimated gas required
    /// @return canSponsor Whether the paymaster can sponsor this operation
    function canSponsorOperation(uint256 requiredGas) external view returns (bool canSponsor) {
        uint256 balance = entryPoint.balanceOf(address(this));
        // Simple check: can we cover the gas cost plus some buffer?
        return balance >= requiredGas * tx.gasprice * 12 / 10; // 20% buffer
    }

    /// @notice Receive ETH directly (will be deposited to EntryPoint)
    receive() external payable {
        if (msg.value > 0) {
            entryPoint.depositTo{value: msg.value}(address(this));
            emit DepositReceived(msg.sender, msg.value);
        }
    }
}