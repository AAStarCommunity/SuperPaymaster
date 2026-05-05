// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import { PaymasterBase } from "./PaymasterBase.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
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

    /// @notice V3 Registry contract (immutable, set at deployment via factory)
    IRegistry public immutable registry;

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

    /// @notice Emitted when Paymaster is re-activated in Registry
    /// @param paymaster Address of the re-activated Paymaster
    event ActivatedInRegistry(address indexed paymaster);

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
        registry = IRegistry(_registry);

        // Lock the implementation contract to prevent direct initialization
        _disableInitializers();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    REGISTRY MANAGEMENT                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Remove this paymaster from the active discovery listing.
    /// @dev    "deactivate" is a listing notification, NOT an exitRole.
    ///         ROLE_PAYMASTER_AOA stays on the operator EOA throughout so the
    ///         operator can re-activate later with activateInRegistry().
    ///         Pausing the contract is the authoritative "not accepting UserOps"
    ///         signal; discovery consumers check !paused AND hasRole(owner).
    function deactivateFromRegistry() external onlyOwner {
        if (paused) return; // idempotent
        paused = true;
        emit Paused(msg.sender);
        emit DeactivatedFromRegistry(address(this));
    }

    /// @notice Re-list this paymaster in the active discovery listing.
    /// @dev    Sets paused=false so validatePaymasterUserOp accepts new UserOps
    ///         again and isActiveInRegistry() returns true (assuming the owner
    ///         still holds ROLE_PAYMASTER_AOA in Registry).
    function activateInRegistry() external onlyOwner {
        if (!paused) return; // idempotent
        paused = false;
        emit Unpaused(msg.sender);
        emit ActivatedInRegistry(address(this));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VIEW FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function version() external pure override returns (string memory) {
        return "PMV4-Deposit-4.5.0";
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
    /// @notice True iff this paymaster is in the active discovery listing.
    /// @dev    Two conditions must both hold:
    ///           1. The operator EOA (owner()) still holds ROLE_PAYMASTER_AOA.
    ///           2. The paymaster has not been deactivated (paused == false).
    ///         ROLE_PAYMASTER_AOA is on the operator EOA, NOT on address(this) —
    ///         querying address(this) (the old bug) always returned false.
    function isActiveInRegistry() external view returns (bool) {
        if (paused) return false;
        try registry.hasRole(registry.ROLE_PAYMASTER_AOA(), owner()) returns (bool active) {
            return active;
        } catch {
            return false;
        }
    }
}