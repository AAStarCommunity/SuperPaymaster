// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PaymasterBase } from "./PaymasterBase.sol";
import { ISuperPaymasterRegistry } from "../../interfaces/ISuperPaymasterRegistry.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { Initializable } from "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";

/**
 * @title Paymaster
 * @notice Paymaster with Registry management capabilities
 * @dev Extends PaymasterBase with deactivateFromRegistry() for lifecycle management
 * @dev Version: Standard - Adds Registry deactivation support
 * @dev For direct deployment (constructor-based)
 * @custom:security-contact security@aastar.community
 */
contract Paymaster is PaymasterBase, Initializable {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice SuperPaymaster Registry contract (immutable, set at deployment)
    ISuperPaymasterRegistry public immutable registry;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Registry address not set
    error Paymaster__RegistryNotSet();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Emitted when Paymaster is deactivated from Registry
    /// @param paymaster Address of the deactivated Paymaster
    event DeactivatedFromRegistry(address indexed paymaster);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Constructor for Implementation Contract
     * @dev Sets immutable registry and disables initializers
     * @param _registry SuperPaymasterRegistry contract address (immutable)
     */
    constructor(address _registry) {
        // 1. Set immutable Registry
        if (_registry == address(0)) revert Paymaster__ZeroAddress();
        registry = ISuperPaymasterRegistry(_registry);

        // 2. Disable initializers to prevent Implementation takeover
        _disableInitializers();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    REGISTRY MANAGEMENT                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
            revert Paymaster__RegistryNotSet();
        }

        // Call Registry.deactivate()
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
    function version() external pure override returns (string memory) {
        return "Paymaster-Standard-1.0.2";
    }

    /**
     * @notice External initializer for Factory Clones
     * @param _entryPoint EntryPoint contract address (v0.7)
     * @param _owner Initial owner address
     * @param _treasury Treasury address for fee collection
     * @param _ethUsdPriceFeed Chainlink ETH/USD price feed address
     * @param _serviceFeeRate Service fee in basis points (max 1000 = 10%)
     * @param _maxGasCostCap Maximum gas cost cap per transaction (wei)
     * @param _minTokenBalance Minimum token balance (for compatibility)
     * @param _xpntsFactory xPNTs Factory contract address (for aPNTs price)
     * @param _initialSBT Initial SBT contract address (optional, use address(0) to skip)
     * @param _initialGasToken Initial GasToken contract address (optional, use address(0) to skip)
     * @dev Must be called by Factory via initData during cloning
     */
    function initialize(
        address _entryPoint,
        address _owner,
        address _treasury,
        address _ethUsdPriceFeed,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _minTokenBalance, // for compatibility
        address _xpntsFactory,
        address _initialSBT,
        address _initialGasToken
    ) external initializer {
        // Call base initialization
        _initializePaymasterBase(
            _entryPoint,
            _owner,
            _treasury,
            _ethUsdPriceFeed,
            _serviceFeeRate,
            _maxGasCostCap,
            _xpntsFactory
        );

        // Add initial SBT if provided
        if (_initialSBT != address(0)) {
            _addSBT(_initialSBT);
        }

        // Add initial GasToken if provided
        if (_initialGasToken != address(0)) {
            _addGasToken(_initialGasToken);
        }
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