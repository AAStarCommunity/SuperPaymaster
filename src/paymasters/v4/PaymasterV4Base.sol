// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { _packValidationData } from "@account-abstraction-v7/core/Helpers.sol";
import { UserOperationLib } from "@account-abstraction-v7/core/UserOperationLib.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { ISBT } from "../../interfaces/ISBT.sol";
import { PostOpMode } from "../../../singleton-paymaster/src/interfaces/PostOpMode.sol";
import { IxPNTsFactory } from "../../interfaces/IxPNTsFactory.sol";
import { IxPNTsToken } from "../../interfaces/IxPNTsToken.sol";

/// @notice Interface for GasToken price query (deprecated, use xPNTs)
interface IGasTokenPrice {
    function getEffectivePrice() external view returns (uint256);
}

using UserOperationLib for PackedUserOperation;
using SafeERC20 for IERC20;

/// @title PaymasterV4Base
/// @notice Base contract with shared business logic for v4.1 and v4.1i
/// @dev Abstract contract - use PaymasterV4_1 (direct) or PaymasterV4_1i (factory)
/// @dev CHANGED: immutable → storage variables for factory pattern support
/// @custom:security-contact security@aastar.community
abstract contract PaymasterV4Base is Ownable, ReentrancyGuard {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice EntryPoint contract address
    /// @dev CHANGED: immutable → storage for factory pattern
    IEntryPoint public entryPoint;

    /// @notice Chainlink ETH/USD price feed
    /// @dev CHANGED: immutable → storage for factory pattern
    AggregatorV3Interface public ethUsdPriceFeed;

    /// @notice xPNTs Factory for aPNTs price
    /// @dev CHANGED: immutable → storage for factory pattern
    IxPNTsFactory public xpntsFactory;

    /// @notice Paymaster data offset in paymasterAndData
    uint256 private constant PAYMASTER_DATA_OFFSET = 52;

    /// @notice Minimum paymasterAndData length
    uint256 private constant MIN_PAYMASTER_AND_DATA_LENGTH = 52;

    /// @notice Contract version
    string public constant VERSION = "PaymasterV4Base-v1.0.0";

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum service fee (10%)
    uint256 public constant MAX_SERVICE_FEE = 1000;

    /// @notice Maximum number of supported SBTs
    uint256 public constant MAX_SBTS = 5;

    /// @notice Maximum number of supported GasTokens
    uint256 public constant MAX_GAS_TOKENS = 10;

    /// @notice Price staleness threshold (15 minutes for L2)
    /// @dev L2 chains have faster block times and more frequent Chainlink updates
    ///      Reduced from 3600s (1 hour) to 900s (15 min) for better price accuracy
    uint256 public constant PRICE_STALENESS_THRESHOLD = 900;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Treasury address - service provider's collection account
    address public treasury;

    /// @notice Service fee rate in basis points (200 = 2%)
    uint256 public serviceFeeRate;

    /// @notice Maximum gas cost cap per transaction (in wei)
    uint256 public maxGasCostCap;

    /// @notice Emergency pause flag
    bool public paused;

    /// @notice Supported SBT contracts
    address[] public supportedSBTs;
    mapping(address => bool) public isSBTSupported;

    /// @notice Supported GasToken contracts (basePNTs, aPNTs, bPNTs)
    address[] public supportedGasTokens;
    mapping(address => bool) public isGasTokenSupported;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error PaymasterV4__OnlyEntryPoint();
    error PaymasterV4__Paused();
    error PaymasterV4__ZeroAddress();
    error PaymasterV4__InvalidTokenBalance();
    error PaymasterV4__NoValidSBT();
    error PaymasterV4__InsufficientPNT();
    error PaymasterV4__InvalidPaymasterData();
    error PaymasterV4__InvalidServiceFee();
    error PaymasterV4__EmptyArray();
    error PaymasterV4__AlreadyExists();
    error PaymasterV4__NotFound();
    error PaymasterV4__MaxLimitReached();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ServiceFeeUpdated(uint256 oldRate, uint256 newRate);
    event MaxGasCostCapUpdated(uint256 oldCap, uint256 newCap);
    event SBTAdded(address indexed sbt);
    event SBTRemoved(address indexed sbt);
    event GasTokenAdded(address indexed token);
    event GasTokenRemoved(address indexed token);
    event GasPaymentProcessed(
        address indexed user,
        address indexed gasToken,
        uint256 pntAmount,
        uint256 gasCostWei,
        uint256 actualGasCost
    );
    event PostOpProcessed(
        address indexed user,
        uint256 actualGasCost,
        uint256 pntCharged
    );

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        MODIFIERS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) {
            revert PaymasterV4__OnlyEntryPoint();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert PaymasterV4__Paused();
        }
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  INTERNAL INITIALIZATION                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Internal initialization function (called by subclasses)
    /// @dev CHANGED: constructor → internal function for factory pattern
    /// @param _entryPoint EntryPoint contract address
    /// @param _owner Contract owner address
    /// @param _treasury Treasury address for receiving PNT
    /// @param _ethUsdPriceFeed Chainlink ETH/USD price feed address
    /// @param _serviceFeeRate Service fee rate in basis points
    /// @param _maxGasCostCap Maximum gas cost cap (wei)
    /// @param _xpntsFactory xPNTs Factory contract address (for aPNTs price)
    function _initializeV4Base(
        address _entryPoint,
        address _owner,
        address _treasury,
        address _ethUsdPriceFeed,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        address _xpntsFactory
    ) internal {
        // Input validation
        if (_entryPoint == address(0)) revert PaymasterV4__ZeroAddress();
        if (_owner == address(0)) revert PaymasterV4__ZeroAddress();
        if (_treasury == address(0)) revert PaymasterV4__ZeroAddress();
        if (_ethUsdPriceFeed == address(0)) revert PaymasterV4__ZeroAddress();
        if (_xpntsFactory == address(0)) revert PaymasterV4__ZeroAddress();
        if (_serviceFeeRate > MAX_SERVICE_FEE) revert PaymasterV4__InvalidServiceFee();

        entryPoint = IEntryPoint(_entryPoint);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        xpntsFactory = IxPNTsFactory(_xpntsFactory);
        treasury = _treasury;
        serviceFeeRate = _serviceFeeRate;
        maxGasCostCap = _maxGasCostCap;
        paused = false;

        _transferOwnership(_owner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*        ENTRYPOINT V0.7 ERC-4337 PAYMASTER FUNCTIONS        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Validates paymaster operation and charges user upfront
    /// @dev Direct payment mode: transfers PNT to treasury immediately
    /// @param userOp The user operation
    /// @param maxCost Maximum cost for this userOp (in wei)
    /// @return context Empty context (not used in direct mode)
    /// @return validationData Always returns 0 (success) or reverts
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /* userOpHash */,
        uint256 maxCost
    )
        external
        onlyEntryPoint
        whenNotPaused
        nonReentrant
        returns (bytes memory context, uint256 validationData)
    {
        // Validate paymasterAndData length
        if (userOp.paymasterAndData.length < MIN_PAYMASTER_AND_DATA_LENGTH) {
            revert PaymasterV4__InvalidPaymasterData();
        }

        address sender = userOp.getSender();

        // Check if account is deployed (extcodesize check)
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(sender)
        }

        // Check 1: User must own at least one supported SBT (skip for undeployed accounts)
        if (codeSize > 0) {
            if (!_hasAnySBT(sender)) {
                revert PaymasterV4__NoValidSBT();
            }
        }

        // Apply gas cost cap
        uint256 cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;

        // Parse user-specified GasToken from paymasterData (v0.7 format)
        address specifiedGasToken = address(0);
        if (userOp.paymasterAndData.length >= 72) {
            specifiedGasToken = address(bytes20(userOp.paymasterAndData[52:72]));
        }

        // Find which GasToken user holds with sufficient balance and calculate amount
        (address userGasToken, uint256 tokenAmount) = _getUserGasToken(sender, cappedMaxCost, specifiedGasToken);
        if (userGasToken == address(0)) {
            revert PaymasterV4__InsufficientPNT();
        }

        // Direct transfer tokens to treasury (using SafeERC20 to handle non-compliant tokens)
        IERC20(userGasToken).safeTransferFrom(sender, treasury, tokenAmount);

        // Emit payment event
        emit GasPaymentProcessed(sender, userGasToken, tokenAmount, cappedMaxCost, maxCost);

        // Return empty context (no refund logic)
        return ("", 0);
    }

    /// @notice PostOp handler (minimal implementation)
    /// @dev Emits event for off-chain analysis only, no refund logic
    function postOp(
        PostOpMode /* mode */,
        bytes calldata /* context */,
        uint256 actualGasCost,
        uint256 /* actualUserOpFeePerGas */
    )
        external
        onlyEntryPoint
    {
        // Emit event for off-chain analysis (multi-pay without refund)
        // Context is empty, but we can emit actualGasCost for tracking
        emit PostOpProcessed(tx.origin, actualGasCost, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Check if user owns any supported SBT
    /// @param user User address to check
    /// @return True if user owns at least one SBT
    function _hasAnySBT(address user) internal view returns (bool) {
        uint256 length = supportedSBTs.length;
        for (uint256 i = 0; i < length; i++) {
            if (ISBT(supportedSBTs[i]).balanceOf(user) > 0) {
                return true;
            }
        }
        return false;
    }

    /// @notice Find which GasToken user can use for payment
    /// @param user User address
    /// @param gasCostWei Gas cost in wei
    /// @param specifiedToken User-specified token from paymasterData (0 = auto-select)
    /// @return token Address of GasToken, or address(0) if insufficient
    /// @return amount Required token amount
    function _getUserGasToken(address user, uint256 gasCostWei, address specifiedToken)
        internal
        view
        returns (address token, uint256 amount)
    {
        // If user specified a token and it's supported, try it first
        if (specifiedToken != address(0) && isGasTokenSupported[specifiedToken]) {
            uint256 requiredAmount = _calculatePNTAmount(gasCostWei, specifiedToken);
            uint256 balance = IERC20(specifiedToken).balanceOf(user);
            uint256 allowance = IERC20(specifiedToken).allowance(user, address(this));
            if (balance >= requiredAmount && allowance >= requiredAmount) {
                return (specifiedToken, requiredAmount);
            }
        }

        // Otherwise, auto-select from supported tokens
        uint256 length = supportedGasTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address _token = supportedGasTokens[i];
            uint256 requiredAmount = _calculatePNTAmount(gasCostWei, _token);
            uint256 balance = IERC20(_token).balanceOf(user);
            uint256 allowance = IERC20(_token).allowance(user, address(this));

            if (balance >= requiredAmount && allowance >= requiredAmount) {
                return (_token, requiredAmount);
            }
        }
        return (address(0), 0);
    }

    /// @notice Calculate required xPNTs amount for gas cost
    /// @dev Unified with SuperPaymaster V2 calculation flow:
    ///      1. gasCostWei → gasCostUSD (Chainlink ETH/USD)
    ///      2. gasCostUSD → aPNTsAmount (factory.getAPNTsPrice())
    ///      3. aPNTsAmount → xPNTsAmount (token.exchangeRate())
    /// @param gasCostWei Gas cost in wei
    /// @param xpntsToken xPNTs token contract address
    /// @return Required xPNTs token amount
    function _calculatePNTAmount(uint256 gasCostWei, address xpntsToken) internal view returns (uint256) {
        // Step 1: Get ETH/USD price from Chainlink with staleness check
        (, int256 ethUsdPrice,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();

        // ✅ FIXED: Use PRICE_STALENESS_THRESHOLD (900s / 15 min for L2)
        // Reduced from 3600s (1 hour) for better price accuracy on L2
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) {
            revert PaymasterV4__InvalidTokenBalance(); // Reuse error for simplicity
        }

        uint8 decimals = ethUsdPriceFeed.decimals();

        // Convert to 18 decimals: price * 1e18 / 10^decimals
        uint256 ethPriceUSD = uint256(ethUsdPrice) * 1e18 / (10 ** decimals);

        // Step 2: Convert gas cost (wei) to USD
        uint256 gasCostUSD = (gasCostWei * ethPriceUSD) / 1e18;

        // Step 3: Add service fee (same as SuperPaymaster V2)
        uint256 totalCostUSD = gasCostUSD * (BPS_DENOMINATOR + serviceFeeRate) / BPS_DENOMINATOR;

        // Step 4: Convert USD to aPNTs amount (using factory's aPNTs price)
        uint256 aPNTsPrice = xpntsFactory.getAPNTsPrice(); // Get dynamic aPNTs price
        uint256 aPNTsAmount = (totalCostUSD * 1e18) / aPNTsPrice;

        // Step 5: Convert aPNTs to xPNTs (using token's exchange rate)
        uint256 rate = IxPNTsToken(xpntsToken).exchangeRate();
        uint256 xPNTsAmount = (aPNTsAmount * rate) / 1e18;

        return xPNTsAmount;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Set treasury address
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert PaymasterV4__ZeroAddress();

        address oldTreasury = treasury;
        treasury = _treasury;

        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /// @notice Set service fee rate
    /// @param _serviceFeeRate New service fee rate in basis points
    function setServiceFeeRate(uint256 _serviceFeeRate) external onlyOwner {
        if (_serviceFeeRate > MAX_SERVICE_FEE) revert PaymasterV4__InvalidServiceFee();

        uint256 oldRate = serviceFeeRate;
        serviceFeeRate = _serviceFeeRate;

        emit ServiceFeeUpdated(oldRate, _serviceFeeRate);
    }

    /// @notice Set maximum gas cost cap
    /// @param _maxGasCostCap New max gas cost cap (wei)
    function setMaxGasCostCap(uint256 _maxGasCostCap) external onlyOwner {
        uint256 oldCap = maxGasCostCap;
        maxGasCostCap = _maxGasCostCap;

        emit MaxGasCostCapUpdated(oldCap, _maxGasCostCap);
    }

    /// @notice Internal helper to add supported SBT contract
    /// @param sbt SBT contract address
    function _addSBT(address sbt) internal {
        if (sbt == address(0)) revert PaymasterV4__ZeroAddress();
        if (isSBTSupported[sbt]) revert PaymasterV4__AlreadyExists();
        if (supportedSBTs.length >= MAX_SBTS) revert PaymasterV4__MaxLimitReached();

        supportedSBTs.push(sbt);
        isSBTSupported[sbt] = true;

        emit SBTAdded(sbt);
    }

    /// @notice Add supported SBT contract
    /// @param sbt SBT contract address
    function addSBT(address sbt) external onlyOwner {
        _addSBT(sbt);
    }

    /// @notice Remove supported SBT contract
    /// @param sbt SBT contract address
    function removeSBT(address sbt) external onlyOwner {
        if (!isSBTSupported[sbt]) revert PaymasterV4__NotFound();

        // Find and remove from array
        uint256 length = supportedSBTs.length;
        for (uint256 i = 0; i < length; i++) {
            if (supportedSBTs[i] == sbt) {
                supportedSBTs[i] = supportedSBTs[length - 1];
                supportedSBTs.pop();
                break;
            }
        }

        isSBTSupported[sbt] = false;

        emit SBTRemoved(sbt);
    }

    /// @notice Internal helper to add supported GasToken contract
    /// @param token GasToken contract address
    function _addGasToken(address token) internal {
        if (token == address(0)) revert PaymasterV4__ZeroAddress();
        if (isGasTokenSupported[token]) revert PaymasterV4__AlreadyExists();
        if (supportedGasTokens.length >= MAX_GAS_TOKENS) revert PaymasterV4__MaxLimitReached();

        supportedGasTokens.push(token);
        isGasTokenSupported[token] = true;

        emit GasTokenAdded(token);
    }

    /// @notice Add supported GasToken contract
    /// @param token GasToken contract address
    function addGasToken(address token) external onlyOwner {
        _addGasToken(token);
    }

    /// @notice Remove supported GasToken contract
    /// @param token GasToken contract address
    function removeGasToken(address token) external onlyOwner {
        if (!isGasTokenSupported[token]) revert PaymasterV4__NotFound();

        // Find and remove from array
        uint256 length = supportedGasTokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (supportedGasTokens[i] == token) {
                supportedGasTokens[i] = supportedGasTokens[length - 1];
                supportedGasTokens.pop();
                break;
            }
        }

        isGasTokenSupported[token] = false;

        emit GasTokenRemoved(token);
    }

    /// @notice Pause the paymaster
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the paymaster
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Withdraw PNT from paymaster to specified address
    /// @param to Recipient address
    /// @param token Token address
    /// @param amount Amount to withdraw
    function withdrawPNT(address to, address token, uint256 amount) external onlyOwner {
        if (to == address(0)) revert PaymasterV4__ZeroAddress();
        IERC20(token).transfer(to, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      VIEW FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Get all supported SBT contracts
    /// @return Array of SBT addresses
    function getSupportedSBTs() external view returns (address[] memory) {
        return supportedSBTs;
    }

    /// @notice Get all supported GasToken contracts
    /// @return Array of GasToken addresses
    function getSupportedGasTokens() external view returns (address[] memory) {
        return supportedGasTokens;
    }

    /// @notice Calculate token amount for gas cost (public view)
    /// @param gasCostWei Gas cost in wei
    /// @param gasToken GasToken contract address
    /// @return Required token amount
    function estimatePNTCost(uint256 gasCostWei, address gasToken) external view returns (uint256) {
        if (!isGasTokenSupported[gasToken]) revert PaymasterV4__NotFound();
        uint256 cappedCost = gasCostWei > maxGasCostCap ? maxGasCostCap : gasCostWei;
        return _calculatePNTAmount(cappedCost, gasToken);
    }

    /// @notice Check if user qualifies for paymaster service
    /// @param user User address
    /// @param estimatedGasCost Estimated gas cost
    /// @return qualified Whether user qualifies
    /// @return reason Reason if not qualified
    function checkUserQualification(address user, uint256 estimatedGasCost)
        external
        view
        returns (bool qualified, string memory reason)
    {
        // Check if account is deployed
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(user)
        }

        // Check SBT (skip for undeployed accounts)
        if (codeSize > 0) {
            if (!_hasAnySBT(user)) {
                return (false, "User does not own required SBT");
            }
        }

        // Calculate required token and check balance (auto-select token)
        uint256 cappedCost = estimatedGasCost > maxGasCostCap ? maxGasCostCap : estimatedGasCost;
        (address userToken, ) = _getUserGasToken(user, cappedCost, address(0));
        if (userToken == address(0)) {
            return (false, "Insufficient token balance or allowance");
        }

        return (true, "");
    }

    /// @notice Get deposit info from EntryPoint
    function getDeposit() external view returns (uint256) {
        return entryPoint.getDepositInfo(address(this)).deposit;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    ENTRYPOINT MANAGEMENT                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Add stake to EntryPoint
    /// @param unstakeDelaySec Unstake delay in seconds
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /// @notice Unlock stake from EntryPoint
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /// @notice Withdraw stake from EntryPoint
    /// @param withdrawAddress Address to receive stake
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    /// @notice Withdraw ETH from EntryPoint deposit
    /// @param withdrawAddress Address to receive ETH
    /// @param amount Amount to withdraw
    function withdrawTo(address payable withdrawAddress, uint256 amount) external onlyOwner {
        entryPoint.withdrawTo(withdrawAddress, amount);
    }

    /// @notice Add deposit to EntryPoint
    function addDeposit() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
    }

    /// @notice Receive ETH
    receive() external payable {}
}
