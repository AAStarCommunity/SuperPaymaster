// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { _packValidationData } from "@account-abstraction-v7/core/Helpers.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";

using SafeERC20 for IERC20;

/// @title PaymasterBase
/// @notice V4 Deposit-Only Paymaster with Community Pricing
/// @custom:security-contact security@aastar.community
abstract contract PaymasterBase is Ownable, ReentrancyGuard, IVersioned {
    /// @notice Constructor for abstract base
    /// @dev Initializes Ownable with msg.sender, actual owner set in _initializePaymasterBase
    constructor() Ownable(msg.sender) {}

    /// @notice Contract version
    function version() external pure override virtual returns (string memory) {
        return "PaymasterV4-4.3.1";
    }
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice EntryPoint contract address
    IEntryPoint public entryPoint;

    /// @notice Chainlink ETH/USD price feed
    /// @notice Chainlink ETH/USD price feed
    AggregatorV3Interface public ethUsdPriceFeed;
    
    /// @notice Cached oracle decimals to avoid external call in validate
    uint8 public oracleDecimals;

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum service fee (10%)
    uint256 public constant MAX_SERVICE_FEE = 1000;

    /// @notice Maximum number of supported SBTs
    uint256 public constant MAX_SBTS = 5;

    /// @notice Maximum number of supported GasTokens
    uint256 public constant MAX_GAS_TOKENS = 10;

    /// @notice Grace window for keeper-pushed timestamps (seconds).
    /// @dev Ethereum block.timestamp can lag real wall-clock by up to ~12 s.
    ///      A keeper that reads its system clock to stamp a price may arrive
    ///      slightly ahead of the on-chain timestamp.  15 s (> 12 s slot upper
    ///      bound) prevents spurious rejections without meaningfully weakening
    ///      the future-timestamp guard.
    uint256 public constant TIMESTAMP_GRACE_SECONDS = 15;

    /// @notice P0-11: bounds for `setCachedPrice` (ETH/USD, 8 decimals).
    ///         $100 floor guards the crash-to-zero attack where an owner
    ///         could set price=1 making every UserOp appear free. $1M ceiling
    ///         rules out off-by-1e8 typos. ±30% per-tx delta reflects ETH
    ///         intraday extremes while blocking multi-step manipulation.
    uint256 public constant CACHED_PRICE_MIN = 100e8;    // $100 / ETH
    uint256 public constant CACHED_PRICE_MAX = 1_000_000e8; // $1M / ETH
    uint256 public constant CACHED_PRICE_DELTA_BPS = 3000;  // 30%

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

    /// @notice User Internal Balances: User -> Token -> Amount (Deposit-Only Model)
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Token Price in USD (8 decimals) set by Admin/Keeper
    /// @dev If price is 0, token is not supported.
    mapping(address => uint256) public tokenPrices;

    /// @notice Ordered list of supported token addresses
    address[] private _supportedTokens;

    /// @notice Quick lookup: token address => index+1 in _supportedTokens (0 = not in list)
    mapping(address => uint256) private _tokenIndex;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error Paymaster__OnlyEntryPoint();
    error Paymaster__Paused();
    error Paymaster__ZeroAddress();
    error Paymaster__InvalidTokenBalance();
    error Paymaster__InsufficientBalance(); 
    error Paymaster__InvalidPaymasterData();
    error Paymaster__InvalidServiceFee();
    error Paymaster__InvalidOraclePrice();
    error Paymaster__TokenNotSupported();
    error Paymaster__PriceNotInitialized();
    error Paymaster__MaxTokensReached();
    error Paymaster__TokenNotInList();
    error Paymaster__TokenDecimalsTooLarge();
    error Paymaster__InvalidGasCostCap();
    error Paymaster__InvalidStalenessThreshold();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ServiceFeeUpdated(uint256 oldRate, uint256 newRate);
    event MaxGasCostCapUpdated(uint256 oldCap, uint256 newCap);
    
    event FundsDeposited(address indexed user, address indexed token, uint256 amount);
    event FundsWithdrawn(address indexed user, address indexed token, uint256 amount);
    event TokenPriceUpdated(address indexed token, uint256 price);
    event TokenRemoved(address indexed token);
    
    event PostOpProcessed(
        address indexed user,
        address indexed token,
        uint256 actualGasCostWei,
        uint256 tokenCost,
        uint256 protocolRevenue
    );
    event PriceUpdated(uint256 price, uint256 updatedAt);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Minimum acceptable ETH/USD price from oracle ($100)
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;
    
    /// @notice Validation price buffer in basis points (10%)
    uint256 private constant VALIDATION_BUFFER_BPS = 1000;

    /// @notice Maximum acceptable ETH/USD price from oracle ($100,000)
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

    function _initializePaymasterBase(
        address _entryPoint,
        address _owner,
        address _treasury,
        address _ethUsdPriceFeed,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _priceStalenessThreshold
    ) internal {
        // Input validation
        if (_entryPoint == address(0)) revert Paymaster__ZeroAddress();
        if (_owner == address(0)) revert Paymaster__ZeroAddress();
        if (_treasury == address(0)) revert Paymaster__ZeroAddress();
        if (_ethUsdPriceFeed == address(0)) revert Paymaster__ZeroAddress();
        if (_serviceFeeRate > MAX_SERVICE_FEE) revert Paymaster__InvalidServiceFee();

        entryPoint = IEntryPoint(_entryPoint);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        
        // Cache decimals
        try ethUsdPriceFeed.decimals() returns (uint8 d) {
             oracleDecimals = d;
        } catch {
             oracleDecimals = 8; // Default
        }

        // xpntsFactory removed
        treasury = _treasury;
        serviceFeeRate = _serviceFeeRate;
        maxGasCostCap = _maxGasCostCap;
        priceStalenessThreshold = _priceStalenessThreshold > 0 ? _priceStalenessThreshold : 3600; // Default 1 hour
        paused = false;

        _transferOwnership(_owner);
    }

    /// @notice Get the Paymaster data offset (version specific)
    function _getPaymasterDataOffset() internal virtual view returns (uint256);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*        ENTRYPOINT V0.7 ERC-4337 PAYMASTER FUNCTIONS        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Validates paymaster operation and deducts internal balance
    /// @dev Deposit-Only mode: Checks internal balance, NO external calls.
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
        uint256 offset = _getPaymasterDataOffset();
        // length check
        if (userOp.paymasterAndData.length < offset) {
            revert Paymaster__InvalidPaymasterData();
        }

        address sender = userOp.sender;

        // Apply gas cost cap
        uint256 cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;

        // Parse user-specified Payment Token from paymasterData
        // Format: [paymaster(20)] [validUntil(6)] [validAfter(6)] [token(20)]
        // Using strict offset 52 for token per user request
        address paymentToken = address(0);
        if (userOp.paymasterAndData.length >= offset + 20) {
            paymentToken = address(bytes20(userOp.paymasterAndData[offset:offset+20]));
        } else {
             // Fallback or Revert? Without token we cannot price.
             // Let's require it.
             revert Paymaster__InvalidPaymasterData();
        }

        // Calculate Cost in Token
        // Mode: Validation (False for realtime)
        uint256 requiredTokenAmount = _calculateTokenCost(cappedMaxCost, paymentToken, false);

        // CHECK INTERNAL BALANCE
        if (balances[sender][paymentToken] < requiredTokenAmount) {
            revert Paymaster__InsufficientBalance();
        }

        // DEDUCT IMMEDIATELY (Escrow logic)
        balances[sender][paymentToken] -= requiredTokenAmount;

        // V4 Security: Check price cache is initialized
        if (cachedPrice.updatedAt == 0) {
            revert Paymaster__PriceNotInitialized();
        }

        // V4 Fix: Return validUntil based on price staleness to prevent arbitrage
        uint48 validUntil = uint48(cachedPrice.updatedAt + priceStalenessThreshold);

        // Context: user, token, AmountCharged
        return (abi.encode(sender, paymentToken, requiredTokenAmount), _packValidationData(false, validUntil, 0));
    }

    /// @notice PostOp handler with refund logic
    /// @dev Intentionally NOT guarded by whenNotPaused — UserOps that already
    ///      passed validatePaymasterUserOp must be allowed to settle; blocking
    ///      postOp would strand the EntryPoint and waste the bundler's gas.
    ///      Pause semantics: no new ops (validate blocked) + no withdrawals;
    ///      existing in-flight ops complete normally.
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 /* actualUserOpFeePerGas */
    )
        public
        virtual
        onlyEntryPoint
        nonReentrant
    {
        if (context.length == 0) return;

        (address user, address token, uint256 preChargedAmount) = 
            abi.decode(context, (address, address, uint256));
            
        // 1. Gas Optimization: Hybrid Cache Strategy
        bool useRealtime = false;
        // Check staleness (if > threshold, attempt cache refresh + force realtime read).
        // P0-16: defensive — if the cache somehow holds a future timestamp
        // (write-time guards in setCachedPrice/updatePrice should have rejected
        // it, but this catches any pre-fix proxy state), treat as stale rather
        // than letting `block.timestamp - cachedPrice.updatedAt` revert with
        // arithmetic underflow on every postOp call.
        if (
            cachedPrice.updatedAt == 0 ||
            cachedPrice.updatedAt > block.timestamp ||
            block.timestamp - cachedPrice.updatedAt > priceStalenessThreshold
        ) {
             try this.updatePrice() {} catch {}
             useRealtime = true;
        }

        // 2. Calculate Actual Cost (try/catch needed for safety — keep external wrapper)
        uint256 actualTokenCost;
        try this.calculateCost(actualGasCost, token, useRealtime) returns (uint256 cost) {
             actualTokenCost = cost;
        } catch {
             actualTokenCost = preChargedAmount;
        }

        // 3. Cap at pre-charged
        if (actualTokenCost > preChargedAmount) {
            actualTokenCost = preChargedAmount;
        }

        // 4. Process Refund to Internal Balance
        uint256 refund = preChargedAmount - actualTokenCost;
        if (refund > 0) {
            balances[user][token] += refund;
        }

        // 5. Protocol Revenue Accounting
        if (actualTokenCost > 0) {
             balances[treasury][token] += actualTokenCost;
        }

        emit PostOpProcessed(user, token, actualGasCost, actualTokenCost, actualTokenCost);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Calculate required Token amount for gas cost
    /// @param gasCostWei Gas cost in wei
    /// @param token Payment Token address
    /// @param useRealtime If true, fetches live ETH price; otherwise uses cache
    /// @return Required Token amount
    function _calculateTokenCost(uint256 gasCostWei, address token, bool useRealtime) internal view returns (uint256) {
        // 1. Get Token Price (USD)
        uint256 tokenPriceUSD = tokenPrices[token];
        if (tokenPriceUSD == 0) revert Paymaster__TokenNotSupported();

        // 2. Get ETH Price (USD)
        int256 ethUsdPrice;
        uint256 updatedAt;
        bool applyBuffer = false;
        
        if (useRealtime) {
            // PostOp: Get Realtime Price
            (uint80 roundId, int256 _price,, uint256 _updatedAt, uint80 answeredInRound) = ethUsdPriceFeed.latestRoundData();
            if (answeredInRound < roundId) revert Paymaster__InvalidOraclePrice();
            ethUsdPrice = _price;
            updatedAt = _updatedAt;
            if (updatedAt == 0) revert Paymaster__InvalidOraclePrice();
        } else {
            // Validation: Get Cached Price
            PriceCache memory cache = cachedPrice;
            if (cache.price == 0) revert Paymaster__InvalidOraclePrice();
            
            ethUsdPrice = int256(uint256(cache.price));
            updatedAt = uint256(cache.updatedAt);
            applyBuffer = true; 
        }
        
        if (ethUsdPrice <= 0) revert Paymaster__InvalidOraclePrice();
        if (ethUsdPrice < MIN_ETH_USD_PRICE || ethUsdPrice > MAX_ETH_USD_PRICE) revert Paymaster__InvalidOraclePrice();
        
        // Use cached decimals
        uint8 ethDecimals = oracleDecimals; 
        
        // 3. Calc Gas Cost in USD (18 decimals)
        // ethPriceUSD = ethUsdPrice * 1e18 / 10^ethDecimals
        // gasCostUSD = gasCostWei * ethPriceUSD / 1e18
        // Combined: gasCostUSD = gasCostWei * ethUsdPrice / 10^ethDecimals
        
        // 4. Apply Fee & Buffer
        uint256 totalRate = BPS_DENOMINATOR + serviceFeeRate;
        if (applyBuffer) {
            totalRate += VALIDATION_BUFFER_BPS;
        }
        
        // totalCostUSD = gasCostWei * ethUsdPrice * totalRate / (BPS_DENOMINATOR * 10^ethDecimals)
        
        // 5. Convert USD to Token
        // TokenPrice is 8 decimals (USD per Token Unit?) NO.
        // Chainlink standard: Token Price is USD value of 1 Unit of Token.
        // e.g. WBTC ($100k) = 100000 * 1e8.
        // USDC ($1) = 1 * 1e8.
        // 
        // TokenAmount = CostUSD / TokenPriceUSD
        // But units must match.
        // CostUSD is 18 decimals? No, let's track decimals.
        // gasCostWei (0) * ethUsdPrice (8) * totalRate (0) = 8 decimals.
        // Denominator: BPS (0) * 10^ethDec (8) = 8 decimals.
        // Result: 0 decimals (Wei USD).
        
        // Let's use Math.mulDiv to preserve precision.
        // numerator = gasCostWei * ethUsdPrice * totalRate * (10^tokenDecimals)
        // denominator = BPS_DENOMINATOR * (10^ethDecimals) * (tokenPriceUSD) * (??? 10^(18-8) adjustment?)
        
        // Let's re-derive carefully.
        // Value(Wei) = gasCostWei * EthPrice ($/Wei)
        // EthPrice ($/Wei) = (ethUsdPrice / 10^ethDecimals) / 1e18 ? No.
        // EthPrice ($/Eth) = ethUsdPrice / 10^ethDecimals. (e.g. 3000 * 1e8 / 1e8 = 3000).
        // EthPrice ($/Wei) = EthPrice($/Eth) / 1e18.
        // Cost($) = gasCostWei * (ethUsdPrice / 10^ethDec) / 1e18.
        
        // TokenAmount = Cost($) / TokenPrice($/TokenUnit)
        // TokenPrice($/TokenUnit) = tokenPriceUSD / 1e8 ???
        // Wait, Chainlink Convention for Token/USD is 8 decimals. 
        // 1 BTC = $100000. Price = 100000e8.
        // 1 Token = $X. Price = X * 1e8.
        // So TokenAmount = Cost($) / (tokenPriceUSD / 1e8).
        // 
        // Putting it together:
        // TokenAmount = [ gasCostWei * ethUsdPrice / (1e18 * 10^ethDec) ] / [ tokenPriceUSD / 1e8 ] * totalRate/BPS
        // TokenAmount = [ gasCostWei * ethUsdPrice * 1e8 * totalRate ] / [ 1e18 * 10^ethDec * tokenPriceUSD * BPS ]
        
        // But we want output in Token Units (which has tokenDecimals).
        // The above formula gives "Number of Tokens". 
        // If we want "Raw Token Amount" (integer), we need to multiply by 10^tokenDecimals?
        // No, "1 Token" usually means 1e18 or 1e6 units.
        // The TokenPrice is "Price per 1e(tokenDecimals) Units".
        // So `TokenAmount` above is "Number of Whole Tokens".
        // To get Raw Amount: * 10^tokenDecimals.
        
        // RawAmount = [ gasCostWei * ethUsdPrice * 1e8 * totalRate * 10^tokenDecimals ] / [ 1e18 * 10^ethDec * tokenPriceUSD * BPS ]
        
        // Simplify:
        // 1e18 * 10^ethDec = 10^(18+ethDec).  (usually 18+8=26)
        // Numerator has 1e8.
        // Cancel 1e8: Denominator becomes 10^(10+ethDec).
        
        // RawAmount = (gasCostWei * ethUsdPrice * totalRate * 10^tokenDecimals) / (tokenPriceUSD * BPS * 10^(10 + ethDec))
        
        uint8 tDecimals = tokenDecimals[token];

        // Split multiplication to leverage Math.mulDiv's 512-bit intermediate precision.
        // partA fits in ~124 bits (67+43+14), safe in uint256.
        uint256 partA = gasCostWei * uint256(ethUsdPrice) * totalRate;
        uint256 denominator = tokenPriceUSD * BPS_DENOMINATOR * (10 ** (10 + ethDecimals));

        return Math.mulDiv(partA, 10 ** tDecimals, denominator);
    }

    /// @notice External wrapper that respects the Realtime Flag (New Optimization)
    function calculateCost(uint256 gasCost, address token, bool useRealtime) external view returns (uint256) {
        if (msg.sender != address(this)) revert Paymaster__InvalidPaymasterData();
        return _calculateTokenCost(gasCost, token, useRealtime);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Update cached price from Oracle (Keeper only)
    function updatePrice() external {
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) = ethUsdPriceFeed.latestRoundData();
        if (answeredInRound < roundId) revert Paymaster__InvalidOraclePrice();
        if (price <= 0) revert Paymaster__InvalidOraclePrice();
        if (updatedAt == 0) revert Paymaster__InvalidOraclePrice();
        if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert Paymaster__InvalidOraclePrice();
        if (block.timestamp > priceStalenessThreshold && updatedAt < block.timestamp - priceStalenessThreshold) revert Paymaster__InvalidOraclePrice();
        cachedPrice = PriceCache({ price: uint208(uint256(price)), updatedAt: uint48(updatedAt) });
        emit PriceUpdated(uint256(price), updatedAt);
    }
    /// @notice Direct Cache Update (Operator/Keeper Pushed Price)
    /// @param price ETH/USD price (8 decimals)
    /// @param timestamp Timestamp of the price
    /// @dev P0-16 (Codex B-N1): reject future timestamps. A future `updatedAt`
    ///      bypasses staleness checks and underflows the postOp staleness
    ///      subtraction in `_postOp`, bricking that path until the cache is
    ///      overwritten with a valid (past) timestamp.
    ///      A 15-second grace window (TIMESTAMP_GRACE_SECONDS) accommodates the
    ///      ~12 s maximum drift between a keeper's wall-clock and block.timestamp,
    ///      preventing spurious rejections of honest keepers.
    /// @dev P0-11 (B2-N3 / V4): three guards stack on top of the P0-16
    ///      future-timestamp check:
    ///      - absolute MIN/MAX: prevent $0 / typo / crash-to-zero attacks
    ///      - ±30% per-tx delta (vs current cache): limits blast of a
    ///        misclick or partially-compromised owner key; skipped when
    ///        cachedPrice is uninitialised (first push).
    function setCachedPrice(uint256 price, uint48 timestamp) external onlyOwner {
        if (price == 0) revert Paymaster__InvalidOraclePrice();
        if (price < CACHED_PRICE_MIN || price > CACHED_PRICE_MAX) revert Paymaster__InvalidOraclePrice();
        if (timestamp > block.timestamp) revert Paymaster__InvalidOraclePrice(); // admin: no grace period
        uint256 oldPrice = cachedPrice.price;
        if (oldPrice != 0) {
            uint256 lower = oldPrice * (BPS_DENOMINATOR - CACHED_PRICE_DELTA_BPS) / BPS_DENOMINATOR;
            uint256 upper = oldPrice * (BPS_DENOMINATOR + CACHED_PRICE_DELTA_BPS) / BPS_DENOMINATOR;
            if (price < lower || price > upper) revert Paymaster__InvalidOraclePrice();
        }
        cachedPrice = PriceCache({ price: uint208(price), updatedAt: timestamp });
        emit PriceUpdated(price, timestamp);
    }


    /// @notice Set supported token price (enable or update token)
    /// @param token ERC20 token address
    /// @param price USD price with 8 decimals (e.g. 1e8 = $1.00)
    function setTokenPrice(address token, uint256 price) external onlyOwner {
        if (token == address(0)) revert Paymaster__ZeroAddress();
        if (price == 0) revert Paymaster__InvalidOraclePrice();

        // Add to tracking list if new token
        if (_tokenIndex[token] == 0) {
            if (_supportedTokens.length >= MAX_GAS_TOKENS) revert Paymaster__MaxTokensReached();
            _supportedTokens.push(token);
            _tokenIndex[token] = _supportedTokens.length; // 1-based index
        }

        // Cache decimals to avoid external call during validation
        uint8 decimals = 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            // default 18
        }
        if (decimals > 24) revert Paymaster__TokenDecimalsTooLarge();
        tokenDecimals[token] = decimals;
        tokenPrices[token] = price;
        emit TokenPriceUpdated(token, price);
    }

    /// @notice Remove a supported token
    /// @param token ERC20 token address to remove
    function removeToken(address token) external onlyOwner {
        if (_tokenIndex[token] == 0) revert Paymaster__TokenNotInList();

        // Swap-and-pop from _supportedTokens
        uint256 idx = _tokenIndex[token] - 1; // convert to 0-based
        uint256 lastIdx = _supportedTokens.length - 1;
        if (idx != lastIdx) {
            address lastToken = _supportedTokens[lastIdx];
            _supportedTokens[idx] = lastToken;
            _tokenIndex[lastToken] = idx + 1; // keep 1-based
        }
        _supportedTokens.pop();
        delete _tokenIndex[token];

        // Clear price and decimals
        delete tokenPrices[token];
        delete tokenDecimals[token];

        emit TokenRemoved(token);
    }

    /// @notice Get all supported token addresses
    function getSupportedTokens() external view returns (address[] memory) {
        return _supportedTokens;
    }

    /// @notice Check if a token is supported
    function isTokenSupported(address token) external view returns (bool) {
        return _tokenIndex[token] != 0;
    }

    /// @notice Get full info for all supported tokens
    /// @return tokens Array of token addresses
    /// @return prices Array of USD prices (8 decimals)
    /// @return decimalsArr Array of token decimals
    function getSupportedTokensInfo()
        external
        view
        returns (address[] memory tokens, uint256[] memory prices, uint8[] memory decimalsArr)
    {
        uint256 len = _supportedTokens.length;
        tokens = new address[](len);
        prices = new uint256[](len);
        decimalsArr = new uint8[](len);
        for (uint256 i = 0; i < len; i++) {
            address t = _supportedTokens[i];
            tokens[i] = t;
            prices[i] = tokenPrices[t];
            decimalsArr[i] = tokenDecimals[t];
        }
    }

    /// @notice Deposit funds for user (Push Model)
    function depositFor(address user, address token, uint256 amount) external nonReentrant {
        if (tokenPrices[token] == 0) revert Paymaster__TokenNotSupported();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[user][token] += amount;
        emit FundsDeposited(user, token, amount);
    }

    /// @notice Withdraw funds
    /// @dev whenNotPaused: during a security incident we must prevent fund
    ///      drain while still allowing new deposits (depositFor is unguarded
    ///      because adding funds is never dangerous).
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (balances[msg.sender][token] < amount) revert Paymaster__InsufficientBalance();
        balances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsWithdrawn(msg.sender, token, amount);
    }

    // Boilerplate Setters (Treasury, etc.)
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert Paymaster__ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }
    function setServiceFeeRate(uint256 _serviceFeeRate) external onlyOwner {
        if (_serviceFeeRate > MAX_SERVICE_FEE) revert Paymaster__InvalidServiceFee();
        emit ServiceFeeUpdated(serviceFeeRate, _serviceFeeRate);
        serviceFeeRate = _serviceFeeRate;
    }
    function setMaxGasCostCap(uint256 _maxGasCostCap) external onlyOwner {
        if (_maxGasCostCap == 0 || _maxGasCostCap > 100 ether) revert Paymaster__InvalidGasCostCap();
        emit MaxGasCostCapUpdated(maxGasCostCap, _maxGasCostCap);
        maxGasCostCap = _maxGasCostCap;
    }
    function setPriceStalenessThreshold(uint256 _priceStalenessThreshold) external onlyOwner {
        if (_priceStalenessThreshold < 60 || _priceStalenessThreshold > 86400) revert Paymaster__InvalidStalenessThreshold();
        priceStalenessThreshold = _priceStalenessThreshold;
    }

    // ====================================
    // P0-6: Emergency pause controls
    // ====================================

    /// @notice Halt sponsorship locally — `whenNotPaused` modifier on
    ///         validatePaymasterUserOp will revert all new userOps.
    /// @dev    The original code shipped `paused`, `whenNotPaused`, and the
    ///         Paused/Unpaused events, but no setter — the modifier could
    ///         never become true, leaving operators with no on-chain stop.
    ///         Combined with P0-5 (Registry exitRole) this gives V4 paymasters
    ///         a fast local halt and a coordinated registry-level deactivation.
    function pause() external onlyOwner {
        if (paused) return; // idempotent
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        if (!paused) return;
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ====================================
    // EntryPoint Management
    // ====================================
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner { entryPoint.addStake{value: msg.value}(unstakeDelaySec); }
    function unlockStake() external onlyOwner { entryPoint.unlockStake(); }
    function withdrawStake(address payable withdrawAddress) external onlyOwner { entryPoint.withdrawStake(withdrawAddress); }
    function withdrawTo(address payable withdrawAddress, uint256 amount) external onlyOwner { entryPoint.withdrawTo(withdrawAddress, amount); }
    function addDeposit() external payable onlyOwner { entryPoint.depositTo{value: msg.value}(address(this)); }
    receive() external payable {}

    // Missing Interface helper
    mapping(address => uint8) public tokenDecimals;
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}