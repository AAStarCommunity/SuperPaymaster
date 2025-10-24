// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PaymasterV4 } from "./PaymasterV4.sol";
import { ISuperPaymasterRegistry } from "../interfaces/ISuperPaymasterRegistry.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/**
 * @title PaymasterV4_1
 * @notice PaymasterV4 with Registry management capabilities
 * @dev Extends PaymasterV4 with deactivateFromRegistry() for lifecycle management
 * @dev Version: v4.1 - Adds Registry deactivation support
 * @custom:security-contact security@aastar.community
 */
contract PaymasterV4_1 is PaymasterV4 {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice SuperPaymaster Registry contract for deactivation management
    ISuperPaymasterRegistry public registry;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Registry address not set
    error PaymasterV4_1__RegistryNotSet();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Emitted when Registry address is updated
    /// @param registry New registry address
    event RegistryUpdated(address indexed registry);

    /// @notice Emitted when Paymaster is deactivated from Registry
    /// @param paymaster Address of the deactivated Paymaster
    event DeactivatedFromRegistry(address indexed paymaster);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Initialize PaymasterV4_1
     * @param _entryPoint EntryPoint contract address (v0.7)
     * @param _owner Initial owner address
     * @param _treasury Treasury address for fee collection
     * @param _gasToUSDRate Gas to USD conversion rate (18 decimals)
     * @param _pntPriceUSD PNT price in USD (18 decimals)
     * @param _serviceFeeRate Service fee in basis points (max 1000 = 10%)
     * @param _maxGasCostCap Maximum gas cost cap per transaction (wei)
     * @param _minTokenBalance Minimum token balance required (wei)
     */
    constructor(
        address _entryPoint,
        address _owner,
        address _treasury,
        uint256 _gasToUSDRate,
        uint256 _pntPriceUSD,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _minTokenBalance
    )
        PaymasterV4(
            _entryPoint,
            _owner,
            _treasury,
            _gasToUSDRate,
            _pntPriceUSD,
            _serviceFeeRate,
            _maxGasCostCap,
            _minTokenBalance
        )
    {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    REGISTRY MANAGEMENT                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Set Registry contract address
     * @dev Only owner can call
     * @dev Must be called before deactivateFromRegistry()
     * @param _registry Address of SuperPaymasterRegistry contract
     */
    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert PaymasterV4__ZeroAddress();
        registry = ISuperPaymasterRegistry(_registry);
        emit RegistryUpdated(_registry);
    }

    /**
     * @notice Deactivate this Paymaster from Registry
     * @dev Only owner can call
     * @dev Deactivate means:
     *      - Stop accepting new gas payment requests
     *      - Continue processing existing transactions (settlement)
     *      - Continue unstake process if initiated
     * @dev Complete exit flow:
     *      1. deactivate() → isActive = false
     *      2. Wait for all transactions to settle
     *      3. unstake() → unlock stake
     *      4. withdrawStake() → withdraw ETH, complete exit
     * @dev Note: Reactivation is controlled by Registry (requires qualification check)
     */
    function deactivateFromRegistry() external onlyOwner {
        if (address(registry) == address(0)) {
            revert PaymasterV4_1__RegistryNotSet();
        }

        // Call Registry.deactivate()
        // msg.sender will be this Paymaster contract address
        // Registry will set paymasters[msg.sender].isActive = false
        registry.deactivate();

        emit DeactivatedFromRegistry(address(this));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VIEW FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Get contract version
     * @return Version string
     */
    function version() external pure returns (string memory) {
        return "PaymasterV4.1-Registry-v1.1.0";
    }

    /**
     * @notice Check if Registry is set
     * @return True if registry address is configured
     */
    function isRegistrySet() external view returns (bool) {
        return address(registry) != address(0);
    }

    /**
     * @notice Get active status from Registry
     * @dev Returns false if Registry not set or Paymaster not registered
     * @return True if Paymaster is active in Registry
     */
    function isActiveInRegistry() external view returns (bool) {
        if (address(registry) == address(0)) {
            return false;
        }

        try registry.isPaymasterActive(address(this)) returns (bool active) {
            return active;
        } catch {
            return false;
        }
    }
}
