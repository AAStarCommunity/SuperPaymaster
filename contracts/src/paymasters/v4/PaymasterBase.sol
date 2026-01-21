// SPDX-License-Identifier: MIT
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
contract PaymasterBase is Ownable, ReentrancyGuard, IVersioned {
    /// @notice Constructor for abstract base
    /// @dev Initializes Ownable with msg.sender, actual owner set in _initializePaymasterBase
    constructor() Ownable(msg.sender) {}

    /// @notice Contract version
    function version() external pure override virtual returns (string memory) {
        return "PaymasterV4-4.3.0";
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

    /// @notice Paymaster data offset in paymasterAndData
    uint256 private constant PAYMASTER_DATA_OFFSET = 52;

    /// @notice Minimum paymasterAndData length
    uint256 private constant MIN_PAYMASTER_AND_DATA_LENGTH = 52;

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

    /// @notice User Internal Balances: User -> Token -> Amount (Deposit-Only Model)
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Token Price in USD (8 decimals) set by Admin/Keeper
    /// @dev If price is 0, token is not supported.
    mapping(address => uint256) public tokenPrices;

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
        // length check
        if (userOp.paymasterAndData.length < MIN_PAYMASTER_AND_DATA_LENGTH) {
            revert Paymaster__InvalidPaymasterData();
        }

        address sender = userOp.sender;

        // Apply gas cost cap
        uint256 cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;

        // Parse user-specified Payment Token from paymasterData
        // Format: [paymaster(20)] [validUntil(6)] [validAfter(6)] [token(20)]
        // Using strict offset 52 for token per user request
        address paymentToken = address(0);
        if (userOp.paymasterAndData.length >= 72) {
            paymentToken = address(bytes20(userOp.paymasterAndData[52:72]));
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

        // Context: user, token, AmountCharged
        return (abi.encode(sender, paymentToken, requiredTokenAmount), 0);
    }

    /// @notice PostOp handler with refund logic
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
        // Check staleness (if > threshold, force update)
        if (block.timestamp - cachedPrice.updatedAt > priceStalenessThreshold) {
             try this.updatePrice() {} catch {}
             // If manual update failed or price still old, force realtime read to be safe
             // or assume Keeper failed and we stick to old price if updatePrice reverts?
             // Safest: useRealtime = true if we suspect cache is bad.
             useRealtime = true;
        }

        // 2. Calculate Actual Cost
        // 2. Calculate Actual Cost
        uint256 actualTokenCost;
        // Optimization: Use 'calculateCost' wrapper to pass 'useRealtime' flag.
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
            (, ethUsdPrice,, updatedAt,) = ethUsdPriceFeed.latestRoundData();
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
        
        uint256 numerator = gasCostWei * uint256(ethUsdPrice) * totalRate * (10 ** tDecimals);
        uint256 denominatorLimit = 10 ** (10 + ethDecimals);
        uint256 denominator = tokenPriceUSD * BPS_DENOMINATOR * denominatorLimit;
        
        return Math.mulDiv(numerator, 1, denominator);
    }

    /// @notice External wrapper for try/catch in postOp (Legacy)
    function getRealtimeTokenCost(uint256 gasCost, address token) external view returns (uint256) {
        if (msg.sender != address(this)) revert Paymaster__InvalidPaymasterData(); 
        return _calculateTokenCost(gasCost, token, true);
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
        (, int256 price,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();
        if (price <= 0) revert Paymaster__InvalidOraclePrice();
        cachedPrice = PriceCache({ price: uint208(uint256(price)), updatedAt: uint48(updatedAt) });
        emit PriceUpdated(uint256(price), updatedAt);
    }
    /// @notice Direct Cache Update (Operator/Keeper Pushed Price)
    /// @param price ETH/USD price (8 decimals)
    /// @param timestamp Timestamp of the price
    function setCachedPrice(uint256 price, uint48 timestamp) external onlyOwner {
        if (price == 0) revert Paymaster__InvalidOraclePrice();
        cachedPrice = PriceCache({ price: uint208(price), updatedAt: timestamp });
        emit PriceUpdated(price, timestamp);
    }


    /// @notice Set supported token price (enable token)
    function setTokenPrice(address token, uint256 price) external onlyOwner {
        // Cache decimals to avoid external call during validation
        uint8 decimals = 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            // default 18
        }
        tokenDecimals[token] = decimals;
        tokenPrices[token] = price;
        emit TokenPriceUpdated(token, price);
    }

    /// @notice Deposit funds for user (Push Model)
    function depositFor(address user, address token, uint256 amount) external nonReentrant {
        if (tokenPrices[token] == 0) revert Paymaster__TokenNotSupported();
        
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[user][token] += amount;
        emit FundsDeposited(user, token, amount);
    }

    /// @notice Withdraw funds
    function withdraw(address token, uint256 amount) external nonReentrant {
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
        emit MaxGasCostCapUpdated(maxGasCostCap, _maxGasCostCap);
        maxGasCostCap = _maxGasCostCap;
    }
    function setPriceStalenessThreshold(uint256 _priceStalenessThreshold) external onlyOwner {
        priceStalenessThreshold = _priceStalenessThreshold;
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