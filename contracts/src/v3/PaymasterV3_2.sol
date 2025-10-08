// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { _packValidationData } from "@account-abstraction-v7/core/Helpers.sol";
import { UserOperationLib } from "@account-abstraction-v7/core/UserOperationLib.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

import { ISBT } from "../interfaces/ISBT.sol";
import { ISettlement } from "../interfaces/ISettlement.sol";
import { ISuperPaymasterV3 } from "../interfaces/ISuperPaymasterV3.sol";
import { PostOpMode } from "../../../singleton-paymaster/src/interfaces/PostOpMode.sol";

using UserOperationLib for PackedUserOperation;

/// @title PaymasterV3_2
/// @notice V3.2 for OP Mainnet with SettlementV3_2 (L2-optimized)
/// @dev Uses L2-optimized Settlement that retains mappings for better UX
/// @custom:security-contact security@aastar.community
contract PaymasterV3_2 is ISuperPaymasterV3, Ownable, ReentrancyGuard {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice EntryPoint contract address (immutable for security)
    IEntryPoint public immutable entryPoint;

    /// @notice Paymaster data offset in paymasterAndData
    uint256 private constant PAYMASTER_DATA_OFFSET = 52; // 20 (paymaster) + 16 (verificationGas) + 16 (postOpGas)

    /// @notice Minimum paymasterAndData length
    uint256 private constant MIN_PAYMASTER_AND_DATA_LENGTH = 52;

    /// @notice Contract version for tracking deployments
    string public constant VERSION = "PaymasterV3.2-OP-Mainnet";

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Soul-Bound Token contract for user qualification
    address public sbtContract;

    /// @notice ERC20 token used for gas payment
    address public gasToken;

    /// @notice Settlement contract for batch fee recording
    address public settlementContract;

    /// @notice Minimum token balance required for qualification
    uint256 public minTokenBalance;

    /// @notice Emergency pause flag
    bool public paused;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error PaymasterV3__OnlyEntryPoint();
    error PaymasterV3__Paused();
    error PaymasterV3__ZeroAddress();
    error PaymasterV3__InvalidTokenBalance();
    error PaymasterV3__NoSBT();
    error PaymasterV3__InsufficientPNT();
    error PaymasterV3__InvalidPaymasterData();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        MODIFIERS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) {
            revert PaymasterV3__OnlyEntryPoint();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert PaymasterV3__Paused();
        }
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Initializes PaymasterV3
    /// @param _entryPoint EntryPoint contract address
    /// @param _owner Contract owner address
    /// @param _sbtContract Soul-Bound Token contract address
    /// @param _gasToken ERC20 token for gas payment
    /// @param _settlementContract Settlement contract address
    /// @param _minTokenBalance Minimum token balance required
    constructor(
        address _entryPoint,
        address _owner,
        address _sbtContract,
        address _gasToken,
        address _settlementContract,
        uint256 _minTokenBalance
    ) Ownable(_owner) {
        // Input validation
        if (_entryPoint == address(0)) revert PaymasterV3__ZeroAddress();
        if (_owner == address(0)) revert PaymasterV3__ZeroAddress();
        if (_sbtContract == address(0)) revert PaymasterV3__ZeroAddress();
        if (_gasToken == address(0)) revert PaymasterV3__ZeroAddress();
        if (_settlementContract == address(0)) revert PaymasterV3__ZeroAddress();
        if (_minTokenBalance == 0) revert PaymasterV3__InvalidTokenBalance();

        entryPoint = IEntryPoint(_entryPoint);
        sbtContract = _sbtContract;
        gasToken = _gasToken;
        settlementContract = _settlementContract;
        minTokenBalance = _minTokenBalance;
        paused = false;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*        ENTRYPOINT V0.7 ERC-4337 PAYMASTER FUNCTIONS        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Validates a userOperation and decides whether to sponsor it
    /// @dev Called by EntryPoint during userOp validation phase
    /// @param userOp The user operation to validate
    /// @param userOpHash Hash of the user operation
    /// @param maxCost Maximum cost the paymaster will pay for this userOp
    /// @return context Context data to pass to postOp
    /// @return validationData Validation result packed with time range
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        external
        onlyEntryPoint
        whenNotPaused
        nonReentrant
        returns (bytes memory context, uint256 validationData)
    {
        return _validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    /// @notice Handles post-operation gas payment recording
    /// @dev Called by EntryPoint after userOp execution
    /// @param mode Execution mode (opSucceeded, opReverted, postOpReverted)
    /// @param context Context data from validatePaymasterUserOp
    /// @param actualGasCost Actual gas cost in wei
    /// @param actualUserOpFeePerGas Actual gas price used
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    )
        external
        onlyEntryPoint
        nonReentrant
    {
        _postOp(mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Internal validation logic with on-chain checks
    /// @dev Removes all signature verification, uses SBT and token balance checks
    /// @param userOp The user operation
    /// @param userOpHash Hash of the user operation
    /// @param maxCost Maximum cost for this userOp
    /// @return context Encoded context for postOp (user address + maxCost + userOpHash)
    /// @return validationData Always returns 0 (success) or reverts
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    )
        internal
        returns (bytes memory context, uint256 validationData)
    {
        // Validate paymasterAndData length
        if (userOp.paymasterAndData.length < MIN_PAYMASTER_AND_DATA_LENGTH) {
            revert PaymasterV3__InvalidPaymasterData();
        }

        address sender = userOp.getSender();

        // Check 1: User must own at least one SBT (Soul-Bound Token)
        uint256 sbtBalance = ISBT(sbtContract).balanceOf(sender);
        if (sbtBalance == 0) {
            revert PaymasterV3__NoSBT();
        }

        // Check 2: User must have sufficient PNT token balance
        uint256 pntBalance = IERC20(gasToken).balanceOf(sender);
        if (pntBalance < minTokenBalance) {
            revert PaymasterV3__InsufficientPNT();
        }

        // Encode context for postOp: sender + maxCost + userOpHash
        context = abi.encode(sender, maxCost, userOpHash);

        // Return success (no time restrictions)
        validationData = 0;

        emit GasSponsored(sender, maxCost, gasToken);
    }

    /// @notice Internal postOp logic for gas fee recording
    /// @dev Records gas fee to Settlement contract instead of immediate transfer
    /// @param context Encoded context from validation
    /// @param actualGasCost Actual gas cost in wei
    function _postOp(
        PostOpMode /* mode */,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /* actualUserOpFeePerGas */
    )
        internal
    {
        // Decode context (includes userOpHash for Settlement tracking)
        (address user, , bytes32 userOpHash) = abi.decode(context, (address, uint256, bytes32));

        // Note: We record fee regardless of mode (even if op failed)
        // This ensures users pay for gas even if their operation reverts

        // Calculate actual gas cost (already in wei from EntryPoint)
        uint256 gasCostInWei = actualGasCost;

        // Convert wei to Gwei for Settlement record (L2 gas optimization)
        // Keeper will use: PNT = (gasGwei * 1e9 / 1e18 * ethPriceUSD) / 0.02
        uint256 gasGwei = gasCostInWei / 1e9;

        // Record fee to Settlement contract for batch processing
        // Settlement will:
        // 1. Generate key = keccak256(this, userOpHash)
        // 2. Create FeeRecord with Pending status
        // 3. Update user's pending balance
        // Note: Use try-catch to ensure postOp doesn't fail if Settlement reverts
        try ISettlement(settlementContract).recordGasFee(
            user,
            gasToken,
            gasGwei,
            userOpHash
        ) {
            // Success - fee recorded in Settlement
            emit GasRecorded(user, gasCostInWei, gasToken);
        } catch Error(string memory) {
            // Settlement call failed with reason
            emit GasRecorded(user, gasCostInWei, gasToken);
            // TODO: Add event for Settlement failure
        } catch (bytes memory) {
            // Settlement call failed without reason
            emit GasRecorded(user, gasCostInWei, gasToken);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @inheritdoc ISuperPaymasterV3
    function setSBTContract(address _sbtContract) external override onlyOwner {
        if (_sbtContract == address(0)) revert PaymasterV3__ZeroAddress();

        address oldSBT = sbtContract;
        sbtContract = _sbtContract;

        emit SBTContractUpdated(oldSBT, _sbtContract);
    }

    /// @inheritdoc ISuperPaymasterV3
    function setGasToken(address _gasToken) external override onlyOwner {
        if (_gasToken == address(0)) revert PaymasterV3__ZeroAddress();

        address oldToken = gasToken;
        gasToken = _gasToken;

        emit GasTokenUpdated(oldToken, _gasToken);
    }

    /// @inheritdoc ISuperPaymasterV3
    function setSettlementContract(address _settlementContract) external override onlyOwner {
        if (_settlementContract == address(0)) revert PaymasterV3__ZeroAddress();

        address oldSettlement = settlementContract;
        settlementContract = _settlementContract;

        emit SettlementContractUpdated(oldSettlement, _settlementContract);
    }

    /// @notice Updates minimum token balance requirement
    /// @param _minTokenBalance New minimum token balance
    function setMinTokenBalance(uint256 _minTokenBalance) external onlyOwner {
        if (_minTokenBalance == 0) revert PaymasterV3__InvalidTokenBalance();

        uint256 oldBalance = minTokenBalance;
        minTokenBalance = _minTokenBalance;

        emit MinTokenBalanceUpdated(oldBalance, _minTokenBalance);
    }

    /// @notice Pauses paymaster operations
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses paymaster operations
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Allows owner to withdraw ETH from contract
    /// @param to Address to withdraw to
    /// @param amount Amount to withdraw
    function withdrawETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert PaymasterV3__ZeroAddress();

        (bool success, ) = to.call{value: amount}("");
        require(success, "PaymasterV3: ETH withdrawal failed");
    }

    /// @notice Deposits ETH to EntryPoint for gas sponsorship
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @notice Unlocks stake from EntryPoint
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /// @notice Withdraws stake from EntryPoint
    /// @param withdrawAddress Address to withdraw to
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      VIEW FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @inheritdoc ISuperPaymasterV3
    function isUserQualified(address user)
        external
        view
        override
        returns (bool qualified, uint8 reason)
    {
        // Check SBT ownership
        uint256 sbtBalance = ISBT(sbtContract).balanceOf(user);
        if (sbtBalance == 0) {
            return (false, 1); // Reason 1: No SBT
        }

        // Check PNT token balance
        uint256 pntBalance = IERC20(gasToken).balanceOf(user);
        if (pntBalance < minTokenBalance) {
            return (false, 2); // Reason 2: Insufficient PNT
        }

        return (true, 0); // Qualified
    }

    /// @notice Returns current configuration
    function getConfig() external view returns (
        address _sbtContract,
        address _gasToken,
        address _settlementContract,
        uint256 _minTokenBalance,
        bool _paused
    ) {
        return (sbtContract, gasToken, settlementContract, minTokenBalance, paused);
    }

    /// @notice Allows contract to receive ETH
    receive() external payable {}
}
