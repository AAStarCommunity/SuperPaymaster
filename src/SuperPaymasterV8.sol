// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Note: Using v7 EntryPoint interface since v8 requires Solidity ^0.8.28
// import "@account-abstraction-v8/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "../singleton-paymaster/src/interfaces/PostOpMode.sol";
import "./SuperPaymasterV7.sol";

/// @title SuperPaymasterV8
/// @notice Paymaster router for EntryPoint v0.8 with EIP-7702 support
/// @dev Extends SuperPaymasterV7 since v7 and v8 share the same PackedUserOperation structure
contract SuperPaymasterV8 is SuperPaymasterV7 {
    /// @notice EIP-7702 support flag
    bool public eip7702Enabled;

    /// @notice Event emitted when EIP-7702 status changes
    event EIP7702StatusChanged(bool enabled);

    /// @notice EIP-7702 delegation information
    struct DelegationInfo {
        address delegatee;      // Address to delegate to
        uint256 nonce;         // Delegation nonce
        bool isActive;         // Whether delegation is active
    }

    /// @notice Mapping of account to delegation information
    mapping(address => DelegationInfo) public delegations;

    /// @notice Constructor
    /// @param _entryPoint Address of the EntryPoint v0.8 contract
    /// @param _owner Address of the contract owner
    /// @param _routerFeeRate Fee rate for routing service (in basis points)
    constructor(
        address _entryPoint,
        address _owner,
        uint256 _routerFeeRate
    ) SuperPaymasterV7(_entryPoint, _owner, _routerFeeRate) {
        eip7702Enabled = true; // Enable EIP-7702 by default for v0.8
    }

    /// @notice Enable or disable EIP-7702 support (only owner)
    /// @param _enabled Whether to enable EIP-7702 support
    function setEIP7702Enabled(bool _enabled) external onlyOwner {
        eip7702Enabled = _enabled;
        emit EIP7702StatusChanged(_enabled);
    }

    /// @notice Register account delegation for EIP-7702 (only owner)
    /// @param _account Account address
    /// @param _delegatee Address to delegate to
    /// @param _nonce Delegation nonce
    function setAccountDelegation(
        address _account,
        address _delegatee,
        uint256 _nonce
    ) external onlyOwner {
        delegations[_account] = DelegationInfo({
            delegatee: _delegatee,
            nonce: _nonce,
            isActive: true
        });
    }

    /// @notice Remove account delegation (only owner)
    /// @param _account Account address
    function removeAccountDelegation(address _account) external onlyOwner {
        delegations[_account].isActive = false;
    }

    /// @inheritdoc SuperPaymasterV7
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // Check for EIP-7702 delegation if enabled
        if (eip7702Enabled && delegations[userOp.sender].isActive) {
            // Handle EIP-7702 delegated accounts
            return _validateDelegatedUserOp(userOp, userOpHash, requiredPreFund);
        }

        // Standard validation for non-delegated accounts - call parent implementation directly
        return _validateStandardUserOp(userOp, userOpHash, requiredPreFund);
    }

    /// @notice Validate standard (non-delegated) user operation
    /// @param userOp The packed user operation
    /// @param userOpHash Hash of the user operation
    /// @param requiredPreFund Required pre-fund amount
    /// @return context Context for postOp
    /// @return validationData Validation result
    function _validateStandardUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) internal returns (bytes memory context, uint256 validationData) {
        // Get the best available paymaster
        (address selectedPaymaster, uint256 feeRate) = this.getBestPaymaster();
        
        // Record routing attempt
        paymasterPools[selectedPaymaster].totalAttempts++;

        // Prepare context for postOp
        context = abi.encode(selectedPaymaster, userOp.sender, requiredPreFund, feeRate);

        // Call the selected paymaster's validation
        try IPaymasterV7(selectedPaymaster).validatePaymasterUserOp(userOp, userOpHash, requiredPreFund) 
            returns (bytes memory paymasterContext, uint256 paymasterValidationData) {
            
            // Success - update stats and emit event
            paymasterPools[selectedPaymaster].successCount++;
            emit PaymasterSelected(selectedPaymaster, userOp.sender, feeRate);
            
            // Combine contexts if needed
            if (paymasterContext.length > 0) {
                context = abi.encode(selectedPaymaster, userOp.sender, requiredPreFund, feeRate, paymasterContext);
            }
            
            return (context, paymasterValidationData);
            
        } catch Error(string memory reason) {
            // Paymaster validation failed
            revert(string(abi.encodePacked("Selected paymaster failed: ", reason)));
        } catch {
            revert("Selected paymaster validation failed");
        }
    }

    /// @notice Validate user operation for delegated accounts (EIP-7702)
    /// @param userOp The packed user operation
    /// @param userOpHash Hash of the user operation
    /// @param requiredPreFund Required pre-fund amount
    /// @return context Context for postOp
    /// @return validationData Validation result
    function _validateDelegatedUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) internal returns (bytes memory context, uint256 validationData) {
        DelegationInfo memory delegation = delegations[userOp.sender];
        
        // Get the best available paymaster
        (address selectedPaymaster, uint256 feeRate) = this.getBestPaymaster();
        
        // Record routing attempt
        paymasterPools[selectedPaymaster].totalAttempts++;

        // Prepare context with delegation info
        context = abi.encode(
            selectedPaymaster, 
            userOp.sender, 
            requiredPreFund, 
            feeRate,
            delegation.delegatee,
            delegation.nonce
        );

        // For EIP-7702 accounts, we might need special validation
        // This is a simplified implementation - real EIP-7702 would need more complex validation
        try IPaymasterV7(selectedPaymaster).validatePaymasterUserOp(userOp, userOpHash, requiredPreFund) 
            returns (bytes memory paymasterContext, uint256 paymasterValidationData) {
            
            // Success - update stats and emit event
            paymasterPools[selectedPaymaster].successCount++;
            emit PaymasterSelected(selectedPaymaster, userOp.sender, feeRate);
            
            // Combine contexts if needed
            if (paymasterContext.length > 0) {
                context = abi.encode(
                    selectedPaymaster, 
                    userOp.sender, 
                    requiredPreFund, 
                    feeRate,
                    delegation.delegatee,
                    delegation.nonce,
                    paymasterContext
                );
            }
            
            return (context, paymasterValidationData);
            
        } catch Error(string memory reason) {
            // Paymaster validation failed
            revert(string(abi.encodePacked("Selected paymaster failed for delegated account: ", reason)));
        } catch {
            revert("Selected paymaster validation failed for delegated account");
        }
    }

    /// @notice Check if an account has active delegation
    /// @param _account Account address to check
    /// @return hasDelegate Whether account has active delegation
    /// @return delegatee Address of the delegatee (if active)
    function getAccountDelegation(address _account) 
        external 
        view 
        returns (bool hasDelegate, address delegatee) 
    {
        DelegationInfo memory delegation = delegations[_account];
        return (delegation.isActive, delegation.delegatee);
    }

    /// @notice Simulate paymaster selection for EIP-7702 delegated accounts
    /// @param userOp The user operation to simulate
    /// @return selectedPaymaster Address of the paymaster that would be selected
    /// @return feeRate Fee rate of the selected paymaster
    /// @return available Whether the paymaster is available
    /// @return isDelegated Whether the account is using EIP-7702 delegation
    function simulateEIP7702PaymasterSelection(PackedUserOperation calldata userOp) 
        external 
        view 
        returns (
            address selectedPaymaster, 
            uint256 feeRate, 
            bool available,
            bool isDelegated
        ) 
    {
        isDelegated = eip7702Enabled && delegations[userOp.sender].isActive;
        
        try this.getBestPaymaster() returns (address paymaster, uint256 rate) {
            selectedPaymaster = paymaster;
            feeRate = rate;
            available = _isPaymasterAvailable(paymaster);
        } catch {
            selectedPaymaster = address(0);
            feeRate = 0;
            available = false;
        }
    }

    /// @inheritdoc SuperPaymasterV7
    function _isPaymasterAvailable(address _paymaster) 
        internal 
        view 
        override 
        returns (bool available) 
    {
        // Enhanced availability check for v0.8
        if (_paymaster.code.length == 0) {
            return false;
        }

        // Check if paymaster has sufficient balance in EntryPoint
        try entryPoint.balanceOf(_paymaster) returns (uint256 balance) {
            // Require at least 0.01 ETH for routing
            if (balance < 0.01 ether) {
                return false;
            }

            // For v0.8, also check if paymaster supports EIP-7702 if needed
            if (eip7702Enabled) {
                // Additional checks for EIP-7702 compatibility could go here
                // For now, we assume all paymasters are compatible
                return true;
            }

            return true;
        } catch {
            return false;
        }
    }

    /// @notice Get router version
    /// @return version Version string
    function getVersion() external pure override returns (string memory version) {
        return "SuperPaymasterV8-1.0.0";
    }

    /// @notice Get EIP-7702 capabilities
    /// @return enabled Whether EIP-7702 is enabled
    /// @return delegatedAccounts Number of accounts with active delegations
    function getEIP7702Info() 
        external 
        view 
        returns (bool enabled, uint256 delegatedAccounts) 
    {
        enabled = eip7702Enabled;
        
        // Count delegated accounts - this is inefficient for large numbers
        // In production, you'd want to maintain a counter
        delegatedAccounts = 0;
        // Note: This would need to be implemented differently in production
        // as we can't iterate over all possible addresses
    }

    /// @notice Batch operation for managing multiple delegations (only owner)
    /// @param _accounts Array of account addresses
    /// @param _delegatees Array of delegatee addresses
    /// @param _nonces Array of nonces
    function batchSetDelegations(
        address[] memory _accounts,
        address[] memory _delegatees,
        uint256[] memory _nonces
    ) external onlyOwner {
        require(
            _accounts.length == _delegatees.length && 
            _accounts.length == _nonces.length, 
            "Array lengths must match"
        );

        for (uint256 i = 0; i < _accounts.length; i++) {
            delegations[_accounts[i]] = DelegationInfo({
                delegatee: _delegatees[i],
                nonce: _nonces[i],
                isActive: true
            });
        }
    }
}