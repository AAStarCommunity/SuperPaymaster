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
import { PostOpMode } from "../../../../singleton-paymaster/src/interfaces/PostOpMode.sol";
import { IxPNTsFactory } from "../../interfaces/IxPNTsFactory.sol";
import { IxPNTsToken } from "../../interfaces/IxPNTsToken.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";

/// @notice Interface for GasToken price query (deprecated, use xPNTs)
interface IGasTokenPrice {
    function getEffectivePrice() external view returns (uint256);
}

using UserOperationLib for PackedUserOperation;
using SafeERC20 for IERC20;

/// @title PaymasterBase
/// @notice Base contract with shared business logic
/// @dev Abstract contract
/// @custom:security-contact security@aastar.community
abstract contract PaymasterBase is Ownable, ReentrancyGuard, IVersioned {
    /// @notice Constructor for abstract base
    /// @dev Initializes Ownable with msg.sender, actual owner set in _initializePaymasterBase
    constructor() Ownable(msg.sender) {}
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice EntryPoint contract address
    IEntryPoint public entryPoint;

    /// @notice Chainlink ETH/USD price feed
    AggregatorV3Interface public ethUsdPriceFeed;

    /// @notice xPNTs Factory for aPNTs price
    IxPNTsFactory public xpntsFactory;

    /// @notice Paymaster data offset in paymasterAndData
    uint256 private constant PAYMASTER_DATA_OFFSET = 52;

    /// @notice Minimum paymasterAndData length
    uint256 private constant MIN_PAYMASTER_AND_DATA_LENGTH = 52;

    /// @notice Contract version
    function version() external virtual pure returns (string memory) {
        return "PMBase-1.0.0";
    }

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum service fee (10%)
    uint256 public constant MAX_SERVICE_FEE = 1000;

    /// @notice Maximum number of supported SBTs
    uint256 public constant MAX_SBTS = 5;

    /// @notice Maximum number of supported GasTokens
    uint256 public constant MAX_GAS_TOKENS = 10;

    /// @notice Price staleness threshold (seconds)
    /// @dev Default to 3600s (1 hour) to cover Mainnet/Testnet heartbeats
    uint256 public priceStalenessThreshold;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct PriceCache {
        uint208 price; // 8 decimals (Chainlink)
        uint48 updatedAt;
    }

    /// @notice Cached ETH/USD price for validation
    PriceCache public cachedPrice;

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
    mapping(address => uint256) public gasTokenIndex; // 1-based index
    mapping(address => uint256) public sbtIndex;      // 1-based index

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error Paymaster__OnlyEntryPoint();
    error Paymaster__Paused();
    error Paymaster__ZeroAddress();
    error Paymaster__InvalidTokenBalance();
    error Paymaster__NoValidSBT();
    error Paymaster__InsufficientPNT();
    error Paymaster__InvalidPaymasterData();
    error Paymaster__InvalidServiceFee();
    error Paymaster__EmptyArray();
    error Paymaster__AlreadyExists();
    error Paymaster__NotFound();
    error Paymaster__MaxLimitReached();
    error Paymaster__AccountNotDeployed();
    error Paymaster__InvalidTokenOrigin();
    error Paymaster__InvalidOraclePrice();
    error Paymaster__StaleOraclePrice();

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
    event SBTContractUpdated(address indexed oldContract, address indexed newContract);
    event PriceUpdated(uint256 price, uint256 updatedAt);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Minimum acceptable ETH/USD price from oracle ($100)
    /// @dev Protects against oracle manipulation or extreme market anomalies
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;
    
    /// @notice Validation price buffer in basis points (10%)
    /// @dev Adds safety margin when using cached price to prevent loss from price volatility
    uint256 private constant VALIDATION_BUFFER_BPS = 1000;

    /// @notice Maximum acceptable ETH/USD price from oracle ($100,000)
    /// @dev Protects against oracle manipulation or extreme market anomalies
    int256 public constant MAX_ETH_USD_PRICE = 100_000 * 1e8;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        MODIFIERS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) {
            revert Paymaster__OnlyEntryPoint();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) {
            revert Paymaster__Paused();
        }
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  INTERNAL INITIALIZATION                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Internal initialization function (called by subclasses)
    /// @param _entryPoint EntryPoint contract address
    /// @param _owner Contract owner address
    /// @param _treasury Treasury address for receiving PNT
    /// @param _ethUsdPriceFeed Chainlink ETH/USD price feed address
    /// @param _serviceFeeRate Service fee rate in basis points
    /// @param _maxGasCostCap Maximum gas cost cap (wei)
    /// @param _xpntsFactory xPNTs Factory contract address (for aPNTs price)
    function _initializePaymasterBase(
        address _entryPoint,
        address _owner,
        address _treasury,
        address _ethUsdPriceFeed,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        address _xpntsFactory,
        uint256 _priceStalenessThreshold
    ) internal {
        // Input validation
        if (_entryPoint == address(0)) revert Paymaster__ZeroAddress();
        if (_owner == address(0)) revert Paymaster__ZeroAddress();
        if (_treasury == address(0)) revert Paymaster__ZeroAddress();
        if (_ethUsdPriceFeed == address(0)) revert Paymaster__ZeroAddress();
        if (_xpntsFactory == address(0)) revert Paymaster__ZeroAddress();
        if (_serviceFeeRate > MAX_SERVICE_FEE) revert Paymaster__InvalidServiceFee();

        entryPoint = IEntryPoint(_entryPoint);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        xpntsFactory = IxPNTsFactory(_xpntsFactory);
        treasury = _treasury;
        serviceFeeRate = _serviceFeeRate;
        maxGasCostCap = _maxGasCostCap;
        priceStalenessThreshold = _priceStalenessThreshold > 0 ? _priceStalenessThreshold : 3600; // Default 1 hour
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
    /// @return context Encoded sender for postOp attribution
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
            revert Paymaster__InvalidPaymasterData();
        }

        address sender = userOp.getSender();

        // Check if account is deployed (extcodesize check)
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(sender)
        }

        // Check 1: User must own at least one supported SBT
        // Exception: Allow undeployed accounts if they have initCode (first-time deployment scenario)
        if (codeSize > 0) {
            // Already deployed -> require SBT
            if (!_hasAnySBT(sender)) {
                revert Paymaster__NoValidSBT();
            }
        } else {
            // Not deployed -> require initCode (will be deployed in this UserOp)
            if (userOp.initCode.length == 0) {
                revert Paymaster__AccountNotDeployed();
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
            revert Paymaster__InsufficientPNT();
        }

        // Transfer tokens to Paymaster (escrow) instead of treasury
        IERC20(userGasToken).safeTransferFrom(sender, address(this), tokenAmount);

        // GasPaymentProcessed moved to postOp or removed from validation for 4337 compliance

        // Context: user, token, maxAmount, cappedMaxCost
        return (abi.encode(sender, userGasToken, tokenAmount, cappedMaxCost), 0);
    }

    /// @notice PostOp handler with refund logic
    /// @dev Calculates actual cost and refunds the difference to the user
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    )
        public
        virtual
        onlyEntryPoint
        nonReentrant
    {
        if (context.length == 0) return;

        (address user, address token, uint256 maxTokenAmount, uint256 cappedMaxCost) = 
            abi.decode(context, (address, address, uint256, uint256));

        // 1. Calculate Actual Cost in PNT (using realtime logic)
        // Note: actualGasCost is in wei
        uint256 actualTokenAmount = _calculatePNTAmount(actualGasCost, token, true);

        // 2. Cap with what was actually pre-charged if actual > estimate (safety cap)
        if (actualTokenAmount > maxTokenAmount) {
            actualTokenAmount = maxTokenAmount;
        }

        // 3. Process Refund
        uint256 refund = maxTokenAmount > actualTokenAmount ? maxTokenAmount - actualTokenAmount : 0;
        
        if (refund > 0) {
            IERC20(token).safeTransfer(user, refund);
        }

        // 4. Transfer net amount to treasury
        if (actualTokenAmount > 0) {
            IERC20(token).safeTransfer(treasury, actualTokenAmount);
        }

        // Emit event for off-chain analysis
        emit PostOpProcessed(user, actualGasCost, actualTokenAmount);
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
            // ✅ Security: Verify token is from xPNTsFactory (ensures expected properties)
            _verifyTokenFromFactory(specifiedToken);
            
            // Use cached price for validation
            uint256 requiredAmount = _calculatePNTAmount(gasCostWei, specifiedToken, false);
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
            
            // ✅ Security: Verify token is from xPNTsFactory
            _verifyTokenFromFactory(_token);
            
            // Use cached price for validation
            uint256 requiredAmount = _calculatePNTAmount(gasCostWei, _token, false);
            uint256 balance = IERC20(_token).balanceOf(user);
            uint256 allowance = IERC20(_token).allowance(user, address(this));

            if (balance >= requiredAmount && allowance >= requiredAmount) {
                return (_token, requiredAmount);
            }
        }
        return (address(0), 0);
    }

    /// @notice Calculate required xPNTs amount for gas cost
    /// @param gasCostWei Gas cost in wei
    /// @param xpntsToken xPNTs token contract address
    /// @param useRealtime If true, fetches live price; otherwise uses cache
    /// @return Required xPNTs token amount
    function _calculatePNTAmount(uint256 gasCostWei, address xpntsToken, bool useRealtime) internal view returns (uint256) {
        int256 ethUsdPrice;
        bool applyBuffer = false;
        
        if (useRealtime) {
            // PostOp: Get Realtime Price
            (, ethUsdPrice,,,) = ethUsdPriceFeed.latestRoundData();
        } else {
            // Validation: Get Cached Price
            PriceCache memory cache = cachedPrice;
            if (cache.price == 0) revert Paymaster__InvalidOraclePrice();
            
            // Note: intentionally skipping timestamp verification during validation 
            // to avoid Bundler banning or dropped userOps.
            // We rely on Keepers to update price and the validation buffer for safety.

            ethUsdPrice = int256(uint256(cache.price));
            applyBuffer = true; // Apply buffer only for validation with cached price
        }
        
        // ✅ CRITICAL: Oracle price validation (防止恶意/异常喂价攻击)
        // 1. Prevent negative or zero price (would cause uint256 overflow)
        if (ethUsdPrice <= 0) revert Paymaster__InvalidOraclePrice();
        
        // 2. Check price bounds ($100 - $100,000) to prevent extreme manipulation
        if (ethUsdPrice < MIN_ETH_USD_PRICE || ethUsdPrice > MAX_ETH_USD_PRICE) {
            revert Paymaster__InvalidOraclePrice();
        }
        
        uint8 decimals = ethUsdPriceFeed.decimals();

        // Convert to 18 decimals: price * 1e18 / 10^decimals
        uint256 ethPriceUSD = uint256(ethUsdPrice) * 1e18 / (10 ** decimals);

        // Step 2: Convert gas cost (wei) to USD
        uint256 gasCostUSD = (gasCostWei * ethPriceUSD) / 1e18;

        // Step 3: Add service fee AND validation buffer (if applicable)
        uint256 totalRate = BPS_DENOMINATOR + serviceFeeRate;
        if (applyBuffer) {
            totalRate += VALIDATION_BUFFER_BPS;
        }
        
        uint256 totalCostUSD = gasCostUSD * totalRate / BPS_DENOMINATOR;

        // Step 4: Convert USD to aPNTs amount (using factory's aPNTs price)
        uint256 aPNTsPrice = xpntsFactory.getAPNTsPrice(); // Get dynamic aPNTs price
        uint256 aPNTsAmount = (totalCostUSD * 1e18) / aPNTsPrice;

        // Step 5: Convert aPNTs to xPNTs (using token's exchange rate)
        uint256 rate = IxPNTsToken(xpntsToken).exchangeRate();
        uint256 xPNTsAmount = (aPNTsAmount * rate) / 1e18;

        return xPNTsAmount;
    }

    
    /// @notice Verify token is from xPNTsFactory
    /// @dev Ensures only tokens with expected properties (no fee-on-transfer, no blacklist) are accepted
    /// @param token Token address to verify
    function _verifyTokenFromFactory(address token) internal view {
        // Check if factory has this token registered for any community
        // This proves the token was created by xPNTsFactory and has expected properties
        try IxPNTsToken(token).FACTORY() returns (address factory) {
            if (factory != address(xpntsFactory)) {
                revert Paymaster__InvalidTokenOrigin();
            }
        } catch {
            revert Paymaster__InvalidTokenOrigin();
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Update cached price from Oracle (Keeper only)
    function updatePrice() external {
        (, int256 price,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();
        
        // Basic validation
        if (price <= 0) revert Paymaster__InvalidOraclePrice();
        
        cachedPrice = PriceCache({
            price: uint208(uint256(price)),
            updatedAt: uint48(updatedAt)
        });
        
        emit PriceUpdated(uint256(price), updatedAt);
    }

    /// @notice Set treasury address
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert Paymaster__ZeroAddress();

        address oldTreasury = treasury;
        treasury = _treasury;

        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /// @notice Set service fee rate
    /// @param _serviceFeeRate New service fee rate in basis points
    function setServiceFeeRate(uint256 _serviceFeeRate) external onlyOwner {
        if (_serviceFeeRate > MAX_SERVICE_FEE) revert Paymaster__InvalidServiceFee();

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

    /// @notice Set price staleness threshold
    /// @param _priceStalenessThreshold New threshold in seconds
    function setPriceStalenessThreshold(uint256 _priceStalenessThreshold) external onlyOwner {
        priceStalenessThreshold = _priceStalenessThreshold;
    }

    /// @notice Internal helper to add supported SBT contract
    /// @param sbt SBT contract address
    function _addSBT(address sbt) internal {
        if (sbt == address(0)) revert Paymaster__ZeroAddress();
        if (isSBTSupported[sbt]) revert Paymaster__AlreadyExists();
        if (supportedSBTs.length >= MAX_SBTS) revert Paymaster__MaxLimitReached();

        supportedSBTs.push(sbt);
        isSBTSupported[sbt] = true;
        sbtIndex[sbt] = supportedSBTs.length;

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
        if (!isSBTSupported[sbt]) revert Paymaster__NotFound();

        // Find and remove from array O(1)
        uint256 idx = sbtIndex[sbt];
        uint256 lastIdx = supportedSBTs.length;
        
        if (idx != lastIdx) {
            address lastSbt = supportedSBTs[lastIdx - 1];
            supportedSBTs[idx - 1] = lastSbt;
            sbtIndex[lastSbt] = idx;
        }
        
        supportedSBTs.pop();
        delete sbtIndex[sbt];

        isSBTSupported[sbt] = false;

        emit SBTRemoved(sbt);
    }

    /// @notice Internal helper to add supported GasToken contract
    /// @param token GasToken contract address
    function _addGasToken(address token) internal {
        if (token == address(0)) revert Paymaster__ZeroAddress();
        if (isGasTokenSupported[token]) revert Paymaster__AlreadyExists();
        if (supportedGasTokens.length >= MAX_GAS_TOKENS) revert Paymaster__MaxLimitReached();

        supportedGasTokens.push(token);
        isGasTokenSupported[token] = true;
        gasTokenIndex[token] = supportedGasTokens.length;

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
        if (!isGasTokenSupported[token]) revert Paymaster__NotFound();

        // O(1) removal
        uint256 idx = gasTokenIndex[token];
        uint256 lastIdx = supportedGasTokens.length;
        
        if (idx != lastIdx) {
            address lastToken = supportedGasTokens[lastIdx - 1];
            supportedGasTokens[idx - 1] = lastToken;
            gasTokenIndex[lastToken] = idx;
        }
        
        supportedGasTokens.pop();
        delete gasTokenIndex[token];

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
        if (to == address(0)) revert Paymaster__ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
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
        if (!isGasTokenSupported[gasToken]) revert Paymaster__NotFound();
        uint256 cappedCost = gasCostWei > maxGasCostCap ? maxGasCostCap : gasCostWei;
        // Use cache for estimation to consistent with validation requirements
        return _calculatePNTAmount(cappedCost, gasToken, false);
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