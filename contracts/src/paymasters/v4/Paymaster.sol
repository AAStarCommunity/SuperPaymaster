// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import { PaymasterBase } from "./PaymasterBase.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISuperPaymasterRegistry } from "../../interfaces/ISuperPaymasterRegistry.sol";
import { IRegistry } from "../../interfaces/v3/IRegistry.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { Initializable } from "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";

/**
 * @title Paymaster
 * @notice Paymaster with Registry management capabilities
 * @dev Extends PaymasterBase with deactivateFromRegistry() for lifecycle management
 * @dev Version: Standard - Adds Registry deactivation support
 * @dev Version: Standard - Adds Registry deactivation support
 * @dev For Proxy deployment only (EIP-1167) via PaymasterFactory
 * @dev NOTE: Direct deployment is NOT supported as initializers are disabled in constructor.
 * @custom:security-contact security@aastar.community
 */
contract Paymaster is PaymasterBase, Initializable {
    using SafeERC20 for IERC20;
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
     * @notice Implementation contract constructor
     * @dev ⚠️ This is the implementation contract for EIP-1167 minimal proxies
     * @dev ❌ DO NOT deploy this contract directly - use PaymasterFactory instead!
     * @dev All configuration parameters must be set via initialize() after proxy deployment
     * @param _registry SuperPaymaster Registry address (immutable, set at deployment)
     */
    constructor(address _registry) {
        if (_registry == address(0)) revert Paymaster__ZeroAddress();
        registry = ISuperPaymasterRegistry(_registry);

        // Lock the implementation contract to prevent direct initialization
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
    /// @notice Exit the PAYMASTER_AOA role on the V3 Registry.
    /// @dev    P0-5 (B5-H1): the original implementation called
    ///         `ISuperPaymasterRegistry.deactivate()`, a V2 router method that
    ///         the deployed V3 Registry does not expose. Every call reverted,
    ///         so an AOA-mode operator had no on-chain way to leave the role
    ///         during an incident — they had to drain deposits manually. The
    ///         V3 equivalent is `exitRole(ROLE_PAYMASTER_AOA)`. Cast at the
    ///         call site (rather than retyping the immutable `registry` field)
    ///         keeps the legacy view methods on `ISuperPaymasterRegistry`
    ///         available for any consumer still on the V2 interface.
    function deactivateFromRegistry() external onlyOwner {
        if (address(registry) == address(0)) {
            revert Paymaster__RegistryNotSet();
        }

        IRegistry v3 = IRegistry(address(registry));
        v3.exitRole(v3.ROLE_PAYMASTER_AOA());

        emit DeactivatedFromRegistry(address(this));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VIEW FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Get contract version
     * @return Version string
     */
    /// @notice Get contract version
    /// @return Version string
    function version() external pure override returns (string memory) {
        return "PMV4-Deposit-4.4.0";
    }

    /// @notice Get the Paymaster data offset (version specific)
    function _getPaymasterDataOffset() internal pure override returns (uint256) {
        return 52;
    }

    /**
     * @notice Initialize Paymaster (for proxy instances or direct constructor)
     * @param _entryPoint EntryPoint contract address
     * @param _owner Initial owner address
     * @param _treasury Treasury address for fee collection
     * @param _ethUsdPriceFeed Chainlink ETH/USD price feed address
     * @param _serviceFeeRate Service fee in basis points
     * @param _maxGasCostCap Maximum gas cost cap
     * @param _priceStalenessThreshold Staleness threshold
     */
    function initialize(
        address _entryPoint,
        address _owner,
        address _treasury,
        address _ethUsdPriceFeed,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _priceStalenessThreshold
    ) public initializer {
        // Call base initialization
        _initializePaymasterBase(
            _entryPoint,
            _owner,
            _treasury,
            _ethUsdPriceFeed,
            _serviceFeeRate,
            _maxGasCostCap,
            _priceStalenessThreshold
        );

        if (_owner != address(0) && _owner != msg.sender) {
            _transferOwnership(_owner);
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
    /// @notice Check whether this paymaster currently holds the V3 PAYMASTER_AOA role.
    /// @dev    P0-5: `isPaymasterActive` is the legacy V2 router check; V3
    ///         tracks role membership via `hasRole(roleId, address)`. Wrapped
    ///         in try/catch so callers do not break if the registry pointer
    ///         is stale or unconfigured.
    function isActiveInRegistry() external view returns (bool) {
        if (address(registry) == address(0)) {
            return false;
        }

        IRegistry v3 = IRegistry(address(registry));
        try v3.hasRole(v3.ROLE_PAYMASTER_AOA(), address(this)) returns (bool active) {
            return active;
        } catch {
            return false;
        }
    }
}