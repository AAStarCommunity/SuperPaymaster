// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@account-abstraction-v6/interfaces/IPaymaster.sol";
import "@account-abstraction-v6/interfaces/IEntryPoint.sol";
import "./base/BasePaymasterRouter.sol";

/// @title SuperPaymasterV6
/// @notice Paymaster router for EntryPoint v0.6
/// @dev Routes user operations to the most suitable registered paymaster
contract SuperPaymasterV6 is BasePaymasterRouter, IPaymaster {
    /// @notice EntryPoint contract address
    IEntryPoint public immutable entryPoint;

    /// @notice Only allow calls from the EntryPoint
    modifier onlyEntryPoint() {
        require(msg.sender == address(entryPoint), "Only EntryPoint can call");
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
    ) BasePaymasterRouter(_owner, _routerFeeRate) {
        require(_entryPoint != address(0), "Invalid EntryPoint address");
        entryPoint = IEntryPoint(_entryPoint);
    }

    /// @inheritdoc IPaymaster
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // Get the best available paymaster
        (address selectedPaymaster, uint256 feeRate) = this.getBestPaymaster();
        
        // Record routing attempt
        paymasterPools[selectedPaymaster].totalAttempts++;

        // Prepare context for postOp
        context = abi.encode(selectedPaymaster, userOp.sender, maxCost, feeRate);

        // Call the selected paymaster's validation
        try IPaymaster(selectedPaymaster).validatePaymasterUserOp(userOp, userOpHash, maxCost) 
            returns (bytes memory paymasterContext, uint256 paymasterValidationData) {
            
            // Success - update stats and emit event
            paymasterPools[selectedPaymaster].successCount++;
            emit PaymasterSelected(selectedPaymaster, userOp.sender, feeRate);
            
            // Combine contexts if needed
            if (paymasterContext.length > 0) {
                context = abi.encode(selectedPaymaster, userOp.sender, maxCost, feeRate, paymasterContext);
            }
            
            return (context, paymasterValidationData);
            
        } catch Error(string memory reason) {
            // Paymaster validation failed
            revert(string(abi.encodePacked("Selected paymaster failed: ", reason)));
        } catch {
            revert("Selected paymaster validation failed");
        }
    }

    /// @inheritdoc IPaymaster
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external onlyEntryPoint {
        // Decode context
        (address selectedPaymaster, address sender, uint256 maxCost, uint256 feeRate) = 
            abi.decode(context, (address, address, uint256, uint256));

        // Calculate router fee
        uint256 routerFee = (actualGasCost * routerFeeRate) / 10000;

        // Call the selected paymaster's postOp if it exists
        try IPaymaster(selectedPaymaster).postOp(mode, context, actualGasCost) {
            // Paymaster postOp succeeded
        } catch {
            // Paymaster postOp failed, but we don't revert to avoid breaking the flow
        }

        // Handle router fee collection here if needed
        // For V1, we keep it simple and don't collect fees
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

    /// @notice Add stake for this router (only owner)
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

    /// @inheritdoc BasePaymasterRouter
    function _isPaymasterAvailable(address _paymaster) 
        internal 
        view 
        override 
        returns (bool available) 
    {
        if (_paymaster.code.length == 0) {
            return false;
        }

        // Check if paymaster has sufficient balance in EntryPoint
        try entryPoint.balanceOf(_paymaster) returns (uint256 balance) {
            // Require at least 0.01 ETH for routing
            return balance >= 0.01 ether;
        } catch {
            return false;
        }
    }

    /// @notice Route a user operation to the best paymaster
    /// @param userOp The user operation to route
    /// @return selectedPaymaster Address of the selected paymaster
    /// @return estimatedCost Estimated cost for the operation
    function routeUserOperation(UserOperation calldata userOp) 
        external 
        view 
        returns (address selectedPaymaster, uint256 estimatedCost) 
    {
        (selectedPaymaster,) = this.getBestPaymaster();
        
        // Simple cost estimation based on gas limits
        estimatedCost = userOp.callGasLimit + userOp.verificationGasLimit + userOp.preVerificationGas;
        
        return (selectedPaymaster, estimatedCost);
    }

    /// @notice Emergency pause functionality (only owner)
    /// @param _paused Whether to pause the router
    function setPaused(bool _paused) external onlyOwner {
        // In V1, we keep this simple - could be enhanced later
        if (_paused) {
            // Emergency pause: deactivate all paymasters
            for (uint256 i = 0; i < paymasterList.length; i++) {
                paymasterPools[paymasterList[i]].isActive = false;
            }
        }
    }

    /// @notice Get router version
    /// @return version Version string
    function getVersion() external pure returns (string memory version) {
        return "SuperPaymasterV6-1.0.0";
    }
}