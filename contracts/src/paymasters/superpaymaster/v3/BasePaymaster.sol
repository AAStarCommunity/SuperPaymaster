// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/core/Helpers.sol";

/**
 * @title BasePaymaster
 * @notice Helper class for creating a paymaster (V3)
 */
abstract contract BasePaymaster is IPaymaster, Ownable {
    /// @notice The EntryPoint contract (immutable for gas savings)
    IEntryPoint public immutable entryPoint;

    constructor(IEntryPoint _entryPoint, address _owner) Ownable(_owner) {
        if (address(_entryPoint) == address(0)) {
            revert("Invalid EntryPoint");
        }
        entryPoint = _entryPoint;
    }

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
