// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PaymasterV4Base } from "./PaymasterV4Base.sol";
import { ISuperPaymasterRegistry } from "../../interfaces/ISuperPaymasterRegistry.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { Initializable } from "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";

/**
 * @title PaymasterV4_1i
 * @notice Initializable version of PaymasterV4_1 for factory deployment
 * @dev Extends PaymasterV4Base with Registry management + Initializable pattern
 * @dev Version: v4.1i - "i" = initializable for EIP-1167 proxy deployment
 * @dev For factory deployment (initialize-based)
 * @custom:security-contact security@aastar.community
 */
contract PaymasterV4_1i is PaymasterV4Base, Initializable {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice SuperPaymaster Registry contract
    ISuperPaymasterRegistry public registry;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error PaymasterV4_1i__RegistryNotSet();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event DeactivatedFromRegistry(address indexed paymaster);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               CONSTRUCTOR (Implementation)                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Implementation contract constructor
     * @dev Disables initializers to prevent implementation contract from being initialized
     * @dev Only proxy instances (created via factory) can be initialized
     */
    constructor() {
        _disableInitializers();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       INITIALIZATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Initialize Paymaster (for proxy instances)
     * @dev Same parameters as PaymasterV4_1 constructor
     * @param _entryPoint EntryPoint contract address (v0.7)
     * @param _owner Initial owner address
     * @param _treasury Treasury address for fee collection
     * @param _ethUsdPriceFeed Chainlink ETH/USD price feed address
     * @param _serviceFeeRate Service fee in basis points (max 1000 = 10%)
     * @param _maxGasCostCap Maximum gas cost cap per transaction (wei)
     * @param _minTokenBalance Minimum token balance (for compatibility, not used)
     * @param _xpntsFactory xPNTs Factory contract address
     * @param _initialSBT Initial SBT contract address (optional)
     * @param _initialGasToken Initial GasToken contract address (optional)
     * @param _registry SuperPaymasterRegistry contract address
     */
    function initialize(
        address _entryPoint,
        address _owner,
        address _treasury,
        address _ethUsdPriceFeed,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _minTokenBalance, // for compatibility with registry deployment
        address _xpntsFactory,
        address _initialSBT,
        address _initialGasToken,
        address _registry
    ) external initializer {
        // Call base initialization
        _initializeV4Base(
            _entryPoint,
            _owner,
            _treasury,
            _ethUsdPriceFeed,
            _serviceFeeRate,
            _maxGasCostCap,
            _xpntsFactory
        );

        // Initialize Registry
        if (_registry == address(0)) revert PaymasterV4__ZeroAddress();
        registry = ISuperPaymasterRegistry(_registry);

        // Add initial SBT if provided
        if (_initialSBT != address(0)) {
            _addSBT(_initialSBT);
        }

        // Add initial GasToken if provided
        if (_initialGasToken != address(0)) {
            _addGasToken(_initialGasToken);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    REGISTRY MANAGEMENT                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Deactivate this Paymaster from Registry
     * @dev Only owner can call
     */
    function deactivateFromRegistry() external onlyOwner {
        if (address(registry) == address(0)) {
            revert PaymasterV4_1i__RegistryNotSet();
        }

        registry.deactivate();
        emit DeactivatedFromRegistry(address(this));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VIEW FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "PaymasterV4.1i-v1.0.0";
    }

    /**
     * @notice Check if Registry is set
     */
    function isRegistrySet() external view returns (bool) {
        return address(registry) != address(0);
    }

    /**
     * @notice Get active status from Registry
     * @dev Returns false if Registry not set or Paymaster not registered
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
