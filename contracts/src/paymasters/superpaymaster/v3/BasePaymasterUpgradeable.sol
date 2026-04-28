// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/core/Helpers.sol";

/**
 * @title BasePaymasterUpgradeable
 * @notice UUPS-compatible base paymaster for ERC-4337 v0.7
 * @dev Keeps entryPoint as immutable (stored in implementation bytecode).
 *      On upgrade, deploy new implementation with same entryPoint address.
 */
abstract contract BasePaymasterUpgradeable is IPaymaster, Ownable, Initializable, UUPSUpgradeable {
    /// @notice The EntryPoint contract (immutable for gas savings on hot path)
    IEntryPoint public immutable entryPoint;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IEntryPoint _entryPoint) Ownable(msg.sender) {
        if (address(_entryPoint) == address(0)) {
            revert("Invalid EntryPoint");
        }
        entryPoint = _entryPoint;
        _disableInitializers();
    }

    /**
     * @notice Initialize the upgradeable paymaster
     * @param _owner The owner address
     */
    function __BasePaymaster_init(address _owner) internal onlyInitializing {
        _transferOwnership(_owner);
    }

    // ====================================
    // UUPS Authorization
    // ====================================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ====================================
    // EntryPoint Stake Management
    // ====================================

    function deposit() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    function withdrawTo(address payable to, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(to, amount);
    }

    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    function withdrawStake(address payable to) external onlyOwner {
        entryPoint.withdrawStake(to);
    }

    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // ====================================
    // IPaymaster (abstract)
    // ====================================

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external virtual returns (bytes memory context, uint256 validationData);

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external virtual;

    modifier onlyEntryPoint() {
        require(msg.sender == address(entryPoint), "BasePaymaster: caller is not EntryPoint");
        _;
    }
}
