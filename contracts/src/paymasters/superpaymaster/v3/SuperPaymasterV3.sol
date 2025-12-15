// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasePaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../../interfaces/v3/IRegistryV3.sol";

/**
 * @title SuperPaymasterV3
 * @notice V3 SuperPaymaster - Unified Registry based Multi-Operator Paymaster
 * @dev Features:
 *      - Registry Integration for Operator Status (COMMUNITY Role)
 *      - Internal Billing Engine (aPNTs deduction, xPNTs charge)
 *      - Chainlink Oracle Pricing
 *      - Operator Treasury Management
 */
contract SuperPaymasterV3 is BasePaymaster, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================================
    // Structs
    // ====================================

    struct OperatorConfig {
        address xPNTsToken;     // Community points token
        address treasury;       // Treasury for receiving xPNTs
        bool isConfigured;      // Check if config exists
    }

    struct PriceCache {
        int256 price;
        uint256 updatedAt;
        uint80 roundId;
        uint8 decimals;
    }

    // ====================================
    // Storage
    // ====================================

    IRegistryV3 public immutable REGISTRY;
    address public immutable APNTS_TOKEN;            // aPNTs (AAStar Token)
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;

    // Operator Data
    mapping(address => uint256) public operatorBalances; // aPNTs Balance
    mapping(address => OperatorConfig) public operatorConfigs; // Billing Config
    
    // Stats
    mapping(address => uint256) public totalSpent;       // Total aPNTs consumed
    mapping(address => uint256) public totalTxSponsored;

    // Pricing Config
    uint256 public constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 public constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    
    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)
    PriceCache private cachedPrice;

    // ====================================
    // Events
    // ====================================

    event OperatorDeposited(address indexed operator, uint256 amount);
    event OperatorWithdrawn(address indexed operator, uint256 amount);
    event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury);
    event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 xPNTsCost);

    // ====================================
    // Constructor
    // ====================================

    constructor(
        IEntryPoint _entryPoint,
        address _owner,
        IRegistryV3 _registry,
        address _apntsToken,
        address _ethUsdPriceFeed
    ) BasePaymaster(_entryPoint, _owner) {
        REGISTRY = _registry;
        APNTS_TOKEN = _apntsToken;
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethUsdPriceFeed);
    }

    // ====================================
    // Operator Management
    // ====================================

    /**
     * @notice Configure billing settings (Operator only)
     * @param xPNTsToken Token to charge users
     * @param treasury Address to receive payments
     */
    function configureOperator(address xPNTsToken, address treasury) external {
        // Must be registered in Registry
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert("Operator not registered");
        }
        if (xPNTsToken == address(0) || treasury == address(0)) {
            revert("Invalid configuration");
        }

        operatorConfigs[msg.sender] = OperatorConfig({
            xPNTsToken: xPNTsToken,
            treasury: treasury,
            isConfigured: true
        });

        emit OperatorConfigured(msg.sender, xPNTsToken, treasury);
    }

    /**
     * @notice Deposit aPNTs
     */
    function deposit(uint256 amount) external nonReentrant {
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert("Operator not registered");
        }
        
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        operatorBalances[msg.sender] += amount;
        
        emit OperatorDeposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw aPNTs
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (operatorBalances[msg.sender] < amount) {
            revert("Insufficient balance");
        }
        operatorBalances[msg.sender] -= amount;
        IERC20(APNTS_TOKEN).safeTransfer(msg.sender, amount);
        
        emit OperatorWithdrawn(msg.sender, amount);
    }

    // ====================================
    // Paymaster Implementation
    // ====================================

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // 1. Extract Operator
        address operator = _extractOperator(userOp);
        
        // 2. Validate Operator Role & Config
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), operator)) {
            return ("", _packValidationData(true, 0, 0)); // Reject: Not registered
        }
        OperatorConfig memory config = operatorConfigs[operator];
        if (!config.isConfigured) {
             return ("", _packValidationData(true, 0, 0)); // Reject: Not configured
        }

        // 3. Billing Logic
        // Calculate aPNTs cost (based on Oracle)
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);
        
        // Check Operator Balance
        if (operatorBalances[operator] < aPNTsAmount) {
             return ("", _packValidationData(true, 0, 0)); // Reject: Insufficient aPNTs
        }

        // Calculate User xPNTs Cost
        uint256 xPNTsAmount = aPNTsAmount; // Simply 1:1 for MVP, or use exchange rate if V2 had it? 
        // V2 had exchangeRate. For now, 1:1 or logic:
        // xPNTsAmount = aPNTsAmount (if 1:1)

        // 4. Effects (Optimistic)
        operatorBalances[operator] -= aPNTsAmount;
        totalSpent[operator] += aPNTsAmount;
        totalTxSponsored[operator]++;

        emit TransactionSponsored(operator, userOp.sender, aPNTsAmount, xPNTsAmount);

        // 5. Interactions: Charge User xPNTs -> Treasury
        // Note: Contract must be approved by user for xPNTsToken
        IERC20(config.xPNTsToken).safeTransferFrom(userOp.sender, config.treasury, xPNTsAmount);

        return ("", 0);
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        // No refund logic for now (pre-charged based on maxCost)
    }

    // ====================================
    // Internal & View
    // ====================================

    function _extractOperator(PackedUserOperation calldata userOp) internal pure returns (address) {
        // paymasterAndData: [paymaster(20)] [operator(20)]
        if (userOp.paymasterAndData.length < 40) return address(0);
        return address(bytes20(userOp.paymasterAndData[20:40]));
    }

    function _calculateAPNTsAmount(uint256 gasCostWei) internal returns (uint256) {
        int256 ethUsdPrice;
        
        // Oracle Logic
        if (block.timestamp - cachedPrice.updatedAt <= PRICE_CACHE_DURATION && cachedPrice.price > 0) {
            ethUsdPrice = cachedPrice.price;
        } else {
            (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = ETH_USD_PRICE_FEED.latestRoundData();
            if (answeredInRound < roundId || block.timestamp - updatedAt > 3600 || price <= MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) {
                 revert("Oracle error");
            }
            cachedPrice = PriceCache({
                price: price,
                updatedAt: block.timestamp,
                roundId: roundId,
                decimals: ETH_USD_PRICE_FEED.decimals()
            });
            ethUsdPrice = price;
        }

        // Calculation: (gasCostWei * ethPrice) / aPNTsPrice
        // ethPrice is 8 decimals usually. aPNTsPrice is 18 decimals ($0.02e18).
        // Result should be 18 decimals (aPNTs amount).
        // (Wei * PriceUSD) / aPNTsPriceUSD
        // (1e18 * 1e8) / 1e18 = 1e8? 
        // We need to handle decimals carefully.
        // ValueUSD = gasCostWei * ethUsdPrice / 1e8 (assuming Oracle 8 decimals) ? No.
        // ValueUSD (18 decimals) = gasCostWei * ethUsdPrice * 1e10 (raise to 18) / 1e18?
        
        // Standard:
        // USD Value (Ref 18 decimals) = gasCostWei * ethUsdPrice * 10^(18 - priceDecimals)
        // aPNTs = USD Value / aPNTsPriceUSD * 1e18?
        
        // V2 implements:
        // uint256 usdValue = gasCost * uint256(price) * (10 ** (18 - decimals));
        // return usdValue * 1e18 / aPNTsPriceUSD;
        
        uint256 priceUint = uint256(ethUsdPrice);
        uint8 decimals = cachedPrice.decimals;
        uint256 usdValue = gasCostWei * priceUint * (10 ** (18 - decimals));
        return (usdValue * 1e18) / aPNTsPriceUSD;
    }

    function _packValidationData(bool sigFailed, uint48 validUntil, uint48 validAfter) internal pure returns (uint256) {
        return (sigFailed ? 1 : 0) | (uint256(validUntil) << 160) | (uint256(validAfter) << (160 + 48));
    }
}
