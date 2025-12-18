// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasePaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../../interfaces/v3/IRegistryV3.sol";

/**
 * @dev Interface for the securely-upgraded xPNTsToken.
 */
interface IModernXPNTsToken {
    function burnFromWithOpHash(address from, uint256 amount, bytes32 userOpHash) external;
}

/**
 * @dev Interface for ERC1363Receiver for push-based deposits
 */
interface IERC1363Receiver {
    function onTransferReceived(address operator, address from, uint256 value, bytes calldata data) external returns (bytes4);
}

/**
 * @title SuperPaymasterV3
 * @notice V3 SuperPaymaster - Unified Registry based Multi-Operator Paymaster
 * @dev Inherits V2.3 capabilities (Billing, Oracle, Treasury) with V3 Registry integration.
 *      Optimized for Gas and Security (CEI, Packing, Batch Updates).
 */
contract SuperPaymasterV3 is BasePaymaster, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================================
    // Structs (Optimized Layout)
    // ====================================

    struct OperatorData {
        // Slot 0 (Packed)
        address xPNTsToken;     // Community points token
        bool isConfigured;      // Config status
        uint88 _reserved0;      // Reserve for fit
        
        // Slot 1 (Packed)
        address treasury;       // Treasury for receiving xPNTs
        uint96 exchangeRate;    // xPNTs <-> aPNTs rate (18 decimals). Max 7.9e10 units if 18 dec.
                                // If exchangeRate is > 79 billion, this overflows. 
                                // Standard 1:1 is 1e18. 
                                // Let's use uint256 for safety on exchangeRate to avoid limits.
        
        // Slot 2
        uint256 exchangeRateFull; 

        // Slot 3
        uint256 aPNTsBalance;       // Operator's aPNTs Balance (Deducted here)
        
        // Slot 4
        uint256 totalSpent;
        
        // Slot 5
        uint256 totalTxSponsored;
    }
    
    // Simpler Struct (Std Layout is often efficient enough)
    struct OperatorConfig {
        address xPNTsToken;
        address treasury;
        bool isConfigured;
        bool isPaused;         // Added for Slash/Pause logic
        uint256 exchangeRate;
        uint256 aPNTsBalance;
        uint256 totalSpent;
        uint256 totalTxSponsored;
        uint256 reputation;    // Restored Reputation Score
    }

    struct SlashRecord {
        uint256 timestamp;
        uint256 amount;        // Penalty amount (if any, e.g. aPNTs burned)
        uint256 reputationLoss;
        string reason;
        SlashLevel level;
    }

    enum SlashLevel {
        WARNING,
        MINOR,
        MAJOR
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
    address public APNTS_TOKEN;            // aPNTs (AAStar Token) - Mutable to allow updates
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;
    address public immutable SUPER_PAYMASTER_TREASURY; // Protocol Treasury for fees

    // Operator Data Mapped by Address
    mapping(address => OperatorConfig) public operators;
    
    // Slash History
    mapping(address => SlashRecord[]) public slashHistory;
    
    // Pricing Config
    uint256 public constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 public constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    
    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)
    PriceCache private cachedPrice;

    // Protocol Fee (Basis Points)
    uint256 public constant SERVICE_FEE_BPS = 200; // 2%
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ====================================
    // Events
    // ====================================

    event OperatorDeposited(address indexed operator, uint256 amount);
    event OperatorWithdrawn(address indexed operator, uint256 amount);
    event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury, uint256 exchangeRate);
    event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 xPNTsCost);
    event APNTsTokenUpdated(address indexed oldToken, address indexed newToken);
    
    // Restored Events
    event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level);
    event ReputationUpdated(address indexed operator, uint256 newScore);
    event OperatorPaused(address indexed operator);
    event OperatorUnpaused(address indexed operator);

    // ====================================
    // Constructor
    // ====================================

    constructor(
        IEntryPoint _entryPoint,
        address _owner,
        IRegistryV3 _registry,
        address _apntsToken,
        address _ethUsdPriceFeed,
        address _protocolTreasury
    ) BasePaymaster(_entryPoint, _owner) {
        REGISTRY = _registry;
        APNTS_TOKEN = _apntsToken;
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethUsdPriceFeed);
        SUPER_PAYMASTER_TREASURY = _protocolTreasury != address(0) ? _protocolTreasury : _owner;
    }

    // ====================================
    // Operator Management
    // ====================================

    /**
     * @notice Configure billing settings (Operator only)
     * @param xPNTsToken Token to charge users
     * @param treasury Address to receive payments
     * @param exchangeRate Rate (1e18 = 1:1)
     */
    function configureOperator(address xPNTsToken, address treasury, uint256 exchangeRate) external {
        // Must be registered in Registry
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert("Operator not registered");
        }
        if (xPNTsToken == address(0) || treasury == address(0) || exchangeRate == 0) {
            revert("Invalid configuration");
        }

        OperatorConfig storage config = operators[msg.sender];
        config.xPNTsToken = xPNTsToken;
        config.treasury = treasury;
        config.exchangeRate = exchangeRate;
        config.isConfigured = true;

        emit OperatorConfigured(msg.sender, xPNTsToken, treasury, exchangeRate);
    }

    /**
     * @notice Set the APNTS Token address (Owner Only)
     */
    function setAPNTsToken(address newAPNTsToken) external onlyOwner {
        require(newAPNTsToken != address(0), "Invalid address");
        address oldToken = APNTS_TOKEN;
        APNTS_TOKEN = newAPNTsToken;
        emit APNTsTokenUpdated(oldToken, newAPNTsToken);
    }

    /**
     * @notice Deposit aPNTs
     */
    /**
     * @notice Deposit aPNTs (Legacy Pull Mode)
     * @dev Only works if APNTS_TOKEN allows transferFrom (e.g. old token or whitelisted)
     */
    function deposit(uint256 amount) external nonReentrant {
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert("Operator not registered");
        }
        
        // This might revert if Token blocks transferFrom (Secure Token)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        operators[msg.sender].aPNTsBalance += amount;
        
        emit OperatorDeposited(msg.sender, amount);
    }

    /**
     * @notice Handle ERC1363 transferAndCall (Push Mode)
     * @dev Safe deposit mechanism for tokens blocking transferFrom
     */
    function onTransferReceived(address, address from, uint256 value, bytes calldata) external returns (bytes4) {
        require(msg.sender == APNTS_TOKEN, "Only APNTS_TOKEN");

        // Ensure operator is registered
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), from)) {
             revert("Operator not registered");
        }

        operators[from].aPNTsBalance += value;
        // Update tracked balance to keep sync with manual transfers
        totalTrackedBalance += value;
        
        emit OperatorDeposited(from, value);

        return this.onTransferReceived.selector;
    }



    // Track total balance for notifyDeposit pattern
    uint256 public totalTrackedBalance;
    // Track total accumulated protocol revenue (burnt aPNTs from operators)
    uint256 public protocolRevenue;

    /**
     * @notice Notify contract of a direct transfer (Ad-hoc Push Mode)
     * @dev Fallback for tokens that don't support ERC1363.
     *      User must transfer tokens first, then call this.
     */
    function notifyDeposit(uint256 amount) external nonReentrant {
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert("Operator not registered");
        }

        uint256 currentBalance = IERC20(APNTS_TOKEN).balanceOf(address(this));
        uint256 untracked = currentBalance - totalTrackedBalance;
        
        if (amount > untracked) {
            revert("Deposit not verified");
        }

        operators[msg.sender].aPNTsBalance += amount;
        totalTrackedBalance += amount;

        emit OperatorDeposited(msg.sender, amount);
    }

    /**
     * @notice Withdraw aPNTs
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (operators[msg.sender].aPNTsBalance < amount) {
            revert("Insufficient balance");
        }
        operators[msg.sender].aPNTsBalance -= amount;
        emit OperatorWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Withdraw accumulated Protocol Revenue
     * @param amount Amount of aPNTs to withdraw
     * @param to Address to receive funds (usually treasury)
     */
    function withdrawProtocolRevenue(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert("Invalid address");
        if (amount > protocolRevenue) revert("Insufficient revenue");
        
        protocolRevenue -= amount;
        IERC20(APNTS_TOKEN).safeTransfer(to, amount);
        
        // Note: No event needed for internal transfers? Or reuse Withdrawn?
        // Let's rely on ERC20 Transfer event.
    }

    // ====================================
    // Reputation & Slash Management (Restored)
    // ====================================

    /**
     * @notice Slash an operator (Admin/Governance only)
     * @dev Reduces reputation and optionally pauses operator
     */
    function slashOperator(address operator, SlashLevel level, uint256 penaltyAmount, string calldata reason) external onlyOwner {
        OperatorConfig storage config = operators[operator];
        
        uint256 reputationLoss = 0;
        if (level == SlashLevel.WARNING) {
            reputationLoss = 10;
        } else if (level == SlashLevel.MINOR) {
            reputationLoss = 20;
        } else if (level == SlashLevel.MAJOR) {
            reputationLoss = 50;
            config.isPaused = true;
            emit OperatorPaused(operator);
        }

        // Apply Reputation Loss
        if (config.reputation > reputationLoss) {
            config.reputation -= reputationLoss;
        } else {
            config.reputation = 0;
        }

        // Apply Financial Penalty (Burn aPNTs)
        if (penaltyAmount > 0) {
            if (config.aPNTsBalance >= penaltyAmount) {
                config.aPNTsBalance -= penaltyAmount;
            } else {
                config.aPNTsBalance = 0;
            }
        }

        slashHistory[operator].push(SlashRecord({
            timestamp: block.timestamp,
            amount: penaltyAmount,
            reputationLoss: reputationLoss,
            reason: reason,
            level: level
        }));

        emit OperatorSlashed(operator, penaltyAmount, level);
        emit ReputationUpdated(operator, config.reputation);
    }

    /**
     * @notice Update Operator Reputation (External Credit Manager)
     */
    function updateReputation(address operator, uint256 newScore) external onlyOwner {
        operators[operator].reputation = newScore;
        emit ReputationUpdated(operator, newScore);
    }

    function setOperatorPause(address operator, bool paused) external onlyOwner {
        operators[operator].isPaused = paused;
        if (paused) {
            emit OperatorPaused(operator);
        } else {
            emit OperatorUnpaused(operator);
        }
    }

    // ====================================
    // Paymaster Implementation
    // ====================================

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint nonReentrant returns (bytes memory context, uint256 validationData) {
        // 1. Extract Operator
        address operator = _extractOperator(userOp);
        
        // 2. Validate Operator Role
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), operator)) {
            return ("", _packValidationData(true, 0, 0)); // Reject: Not registered
        }
        
        // 3. Validate User Role (Unified Verification)
        if (!REGISTRY.hasRole(keccak256("ENDUSER"), userOp.sender)) {
             return ("", _packValidationData(true, 0, 0)); // Reject: User not verified
        }

        OperatorConfig storage config = operators[operator];
        if (!config.isConfigured) {
             return ("", _packValidationData(true, 0, 0)); // Reject: Not configured
        }
        
        if (config.isPaused) {
             return ("", _packValidationData(true, 0, 0)); // Reject: Operator Paused
        }

        // 4. Billing Logic
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);
        
        if (config.aPNTsBalance < aPNTsAmount) {
             return ("", _packValidationData(true, 0, 0)); // Reject: Insufficient aPNTs
        }

        uint256 xPNTsAmount = (aPNTsAmount * config.exchangeRate) / 1e18;

        // 5. Effects (Optimistic & Batch)
        config.aPNTsBalance -= aPNTsAmount;
        config.totalSpent += aPNTsAmount;
        config.totalTxSponsored++;

        // Accumulate revenue for the protocol
        // Since V3 burns user xPNTs, the "profit" comes from the consuming the operator's aPNTs deposit.
        protocolRevenue += aPNTsAmount;

        emit TransactionSponsored(operator, userOp.sender, aPNTsAmount, xPNTsAmount);

        // 6. Interactions: Charge User xPNTs via Secure Hash-Locked Burn
        // This is the new, secure way to charge the user. It calls the special
        // function in the xPNTsToken which verifies the userOpHash.
        IModernXPNTsToken(config.xPNTsToken).burnFromWithOpHash(userOp.sender, xPNTsAmount, userOpHash);

        // The old, insecure transferFrom calls are now disabled at the token level.
        // uint256 protocolFee = (xPNTsAmount * SERVICE_FEE_BPS) / BPS_DENOMINATOR;
        // uint256 operatorAmount = xPNTsAmount - protocolFee;
        // if (protocolFee > 0) {
        //     IERC20(config.xPNTsToken).safeTransferFrom(userOp.sender, SUPER_PAYMASTER_TREASURY, protocolFee);
        // }
        // if (operatorAmount > 0) {
        //     IERC20(config.xPNTsToken).safeTransferFrom(userOp.sender, config.treasury, operatorAmount);
        // }

        return ("", 0);
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        // No refund logic (pre-charged based on maxCost with no refund, per V2 model)
    }

    // ====================================
    // Internal & View
    // ====================================

    function _extractOperator(PackedUserOperation calldata userOp) internal pure returns (address) {
        // paymasterAndData: [paymaster(20)] [gasLimits(32)] [operator(20)]
        // Fix: Read from offset 52 (standard ERC-4337 v0.7 layout)
        if (userOp.paymasterAndData.length < 72) return address(0);
        return address(bytes20(userOp.paymasterAndData[52:72]));
    }

    function _calculateAPNTsAmount(uint256 gasCostWei) internal returns (uint256) {
        int256 ethUsdPrice;
        
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

        uint256 priceUint = uint256(ethUsdPrice);
        uint8 decimals = cachedPrice.decimals;
        uint256 usdValue = gasCostWei * priceUint * (10 ** (18 - decimals));
        return (usdValue * 1e18) / aPNTsPriceUSD;
    }

    
}