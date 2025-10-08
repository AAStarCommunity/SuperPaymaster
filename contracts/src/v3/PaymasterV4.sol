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
import { PostOpMode } from "../../../singleton-paymaster/src/interfaces/PostOpMode.sol";

using UserOperationLib for PackedUserOperation;

/// @title PaymasterV4
/// @notice Direct payment mode without Settlement - gas optimized
/// @dev Based on V3.2, removes Settlement dependency for ~79% gas savings
/// @dev Treasury receives PNT immediately in validatePaymasterUserOp
/// @dev Supports multiple SBTs and GasTokens for flexibility
/// @custom:security-contact security@aastar.community
contract PaymasterV4 is Ownable, ReentrancyGuard {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice EntryPoint contract address (immutable for security)
    IEntryPoint public immutable entryPoint;

    /// @notice Paymaster data offset in paymasterAndData
    uint256 private constant PAYMASTER_DATA_OFFSET = 52;

    /// @notice Minimum paymasterAndData length
    uint256 private constant MIN_PAYMASTER_AND_DATA_LENGTH = 52;

    /// @notice Contract version
    string public constant VERSION = "PaymasterV4-Direct-v1.0.0";

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum service fee (10%)
    uint256 public constant MAX_SERVICE_FEE = 1000;

    /// @notice Maximum number of supported SBTs
    uint256 public constant MAX_SBTS = 5;

    /// @notice Maximum number of supported GasTokens
    uint256 public constant MAX_GAS_TOKENS = 10;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Treasury address - service provider's collection account
    address public treasury;

    /// @notice Gas to USD conversion rate (18 decimals), e.g., 4500e18 = $4500/ETH
    uint256 public gasToUSDRate;

    /// @notice PNT price in USD (18 decimals), e.g., 0.02 USD = 0.02e18
    uint256 public pntPriceUSD;

    /// @notice Service fee rate in basis points (200 = 2%)
    uint256 public serviceFeeRate;

    /// @notice Maximum gas cost cap per transaction (in wei)
    uint256 public maxGasCostCap;

    /// @notice Minimum token balance required for qualification
    uint256 public minTokenBalance;

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
    event GasToUSDRateUpdated(uint256 oldRate, uint256 newRate);
    event PntPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event ServiceFeeUpdated(uint256 oldRate, uint256 newRate);
    event MaxGasCostCapUpdated(uint256 oldCap, uint256 newCap);
    event MinTokenBalanceUpdated(uint256 oldBalance, uint256 newBalance);
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
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Initializes PaymasterV4
    /// @param _entryPoint EntryPoint contract address
    /// @param _owner Contract owner address
    /// @param _treasury Treasury address for receiving PNT
    /// @param _gasToUSDRate Gas to USD conversion rate (18 decimals)
    /// @param _pntPriceUSD PNT price in USD (18 decimals)
    /// @param _serviceFeeRate Service fee rate in basis points
    /// @param _maxGasCostCap Maximum gas cost cap (wei)
    /// @param _minTokenBalance Minimum token balance required
    constructor(
        address _entryPoint,
        address _owner,
        address _treasury,
        uint256 _gasToUSDRate,
        uint256 _pntPriceUSD,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _minTokenBalance
    ) Ownable(_owner) {
        // Input validation
        if (_entryPoint == address(0)) revert PaymasterV4__ZeroAddress();
        if (_owner == address(0)) revert PaymasterV4__ZeroAddress();
        if (_treasury == address(0)) revert PaymasterV4__ZeroAddress();
        if (_gasToUSDRate == 0) revert PaymasterV4__InvalidTokenBalance();
        if (_pntPriceUSD == 0) revert PaymasterV4__InvalidTokenBalance();
        if (_serviceFeeRate > MAX_SERVICE_FEE) revert PaymasterV4__InvalidServiceFee();
        if (_minTokenBalance == 0) revert PaymasterV4__InvalidTokenBalance();

        entryPoint = IEntryPoint(_entryPoint);
        treasury = _treasury;
        gasToUSDRate = _gasToUSDRate;
        pntPriceUSD = _pntPriceUSD;
        serviceFeeRate = _serviceFeeRate;
        maxGasCostCap = _maxGasCostCap;
        minTokenBalance = _minTokenBalance;
        paused = false;
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

        // Calculate required PNT amount
        uint256 pntAmount = _calculatePNTAmount(cappedMaxCost);

        // Parse user-specified GasToken from paymasterData (v0.7 format)
        address specifiedGasToken = address(0);
        if (userOp.paymasterAndData.length >= 72) {
            specifiedGasToken = address(bytes20(userOp.paymasterAndData[52:72]));
        }

        // Find which GasToken user holds with sufficient balance
        address userGasToken = _getUserGasToken(sender, pntAmount, specifiedGasToken);
        if (userGasToken == address(0)) {
            revert PaymasterV4__InsufficientPNT();
        }

        // Direct transfer PNT to treasury
        IERC20(userGasToken).transferFrom(sender, treasury, pntAmount);

        // Emit payment event
        emit GasPaymentProcessed(sender, userGasToken, pntAmount, cappedMaxCost, maxCost);

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
    /// @param requiredAmount Required PNT amount
    /// @param specifiedToken User-specified token from paymasterData (0 = auto-select)
    /// @return Address of GasToken, or address(0) if insufficient
    function _getUserGasToken(address user, uint256 requiredAmount, address specifiedToken)
        internal
        view
        returns (address)
    {
        // If user specified a token and it's supported, try it first
        if (specifiedToken != address(0) && isGasTokenSupported[specifiedToken]) {
            uint256 balance = IERC20(specifiedToken).balanceOf(user);
            uint256 allowance = IERC20(specifiedToken).allowance(user, address(this));
            if (balance >= requiredAmount && allowance >= requiredAmount) {
                return specifiedToken;
            }
        }

        // Otherwise, auto-select from supported tokens
        uint256 length = supportedGasTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = supportedGasTokens[i];
            uint256 balance = IERC20(token).balanceOf(user);
            uint256 allowance = IERC20(token).allowance(user, address(this));

            if (balance >= requiredAmount && allowance >= requiredAmount) {
                return token;
            }
        }
        return address(0);
    }

    /// @notice Calculate required PNT amount for gas cost
    /// @dev Uses dual-parameter system: gasToUSDRate (fixed) + pntPriceUSD (variable)
    /// @dev Formula: gasCostUSD = gasCostWei * gasToUSDRate / 1e18
    /// @dev         totalCostUSD = gasCostUSD * (1 + serviceFeeRate/10000)
    /// @dev         pntAmount = totalCostUSD / pntPriceUSD
    /// @param gasCostWei Gas cost in wei
    /// @return Required PNT amount
    function _calculatePNTAmount(uint256 gasCostWei) internal view returns (uint256) {
        // Step 1: Convert gas cost to USD using gasToUSDRate
        // e.g., 1 ETH = 4500 USD, so gasCostWei * 4500e18 / 1e18
        uint256 gasCostUSD = (gasCostWei * gasToUSDRate) / 1e18;

        // Step 2: Add service fee
        // e.g., serviceFeeRate = 200 (2%), so multiply by 10200/10000
        uint256 totalCostUSD = gasCostUSD * (BPS_DENOMINATOR + serviceFeeRate) / BPS_DENOMINATOR;

        // Step 3: Convert USD to PNT amount
        // e.g., pntPriceUSD = 0.02e18, so totalCostUSD * 1e18 / 0.02e18
        // When pntPriceUSD changes, this step automatically affects PNT collection
        uint256 pntAmount = (totalCostUSD * 1e18) / pntPriceUSD;

        return pntAmount;
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

    /// @notice Set gas to USD conversion rate
    /// @param _gasToUSDRate New gas to USD rate (18 decimals)
    function setGasToUSDRate(uint256 _gasToUSDRate) external onlyOwner {
        if (_gasToUSDRate == 0) revert PaymasterV4__InvalidTokenBalance();

        uint256 oldRate = gasToUSDRate;
        gasToUSDRate = _gasToUSDRate;

        emit GasToUSDRateUpdated(oldRate, _gasToUSDRate);
    }

    /// @notice Set PNT price in USD
    /// @param _pntPriceUSD New PNT price (18 decimals)
    function setPntPriceUSD(uint256 _pntPriceUSD) external onlyOwner {
        if (_pntPriceUSD == 0) revert PaymasterV4__InvalidTokenBalance();

        uint256 oldPrice = pntPriceUSD;
        pntPriceUSD = _pntPriceUSD;

        emit PntPriceUpdated(oldPrice, _pntPriceUSD);
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

    /// @notice Set minimum token balance
    /// @param _minTokenBalance New minimum token balance
    function setMinTokenBalance(uint256 _minTokenBalance) external onlyOwner {
        if (_minTokenBalance == 0) revert PaymasterV4__InvalidTokenBalance();

        uint256 oldBalance = minTokenBalance;
        minTokenBalance = _minTokenBalance;

        emit MinTokenBalanceUpdated(oldBalance, _minTokenBalance);
    }

    /// @notice Add supported SBT contract
    /// @param sbt SBT contract address
    function addSBT(address sbt) external onlyOwner {
        if (sbt == address(0)) revert PaymasterV4__ZeroAddress();
        if (isSBTSupported[sbt]) revert PaymasterV4__AlreadyExists();
        if (supportedSBTs.length >= MAX_SBTS) revert PaymasterV4__MaxLimitReached();

        supportedSBTs.push(sbt);
        isSBTSupported[sbt] = true;

        emit SBTAdded(sbt);
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

    /// @notice Add supported GasToken contract
    /// @param token GasToken contract address
    function addGasToken(address token) external onlyOwner {
        if (token == address(0)) revert PaymasterV4__ZeroAddress();
        if (isGasTokenSupported[token]) revert PaymasterV4__AlreadyExists();
        if (supportedGasTokens.length >= MAX_GAS_TOKENS) revert PaymasterV4__MaxLimitReached();

        supportedGasTokens.push(token);
        isGasTokenSupported[token] = true;

        emit GasTokenAdded(token);
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

    /// @notice Calculate PNT amount for gas cost (public view)
    /// @param gasCostWei Gas cost in wei
    /// @return Required PNT amount
    function estimatePNTCost(uint256 gasCostWei) external view returns (uint256) {
        uint256 cappedCost = gasCostWei > maxGasCostCap ? maxGasCostCap : gasCostWei;
        return _calculatePNTAmount(cappedCost);
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

        // Calculate required PNT
        uint256 cappedCost = estimatedGasCost > maxGasCostCap ? maxGasCostCap : estimatedGasCost;
        uint256 requiredPNT = _calculatePNTAmount(cappedCost);

        // Check PNT balance (auto-select token)
        address userToken = _getUserGasToken(user, requiredPNT, address(0));
        if (userToken == address(0)) {
            return (false, "Insufficient PNT balance or allowance");
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
