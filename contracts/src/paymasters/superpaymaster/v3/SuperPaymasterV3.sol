// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasePaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../../interfaces/v3/IRegistryV3.sol";
import "../../../interfaces/IERC1363.sol";

/**
 * @dev Interface for the securely-upgraded xPNTsToken.
 */
interface IModernXPNTsToken {
    function burnFromWithOpHash(address from, uint256 amount, bytes32 userOpHash) external;
    function exchangeRate() external view returns (uint256);
    function getDebt(address user) external view returns (uint256);
    function recordDebt(address user, uint256 amountXPNTs) external;
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

    
    // Simpler Struct (Std Layout is often efficient enough)
    struct OperatorConfig {
        // Slot 0: Packed
        address xPNTsToken;     // 20 bytes
        bool isConfigured;      // 1 byte
        bool isPaused;          // 1 byte
        uint80 _reserved;       // 10 bytes
        
        // Slot 1: Packed
        address treasury;       // 20 bytes
        uint96 exchangeRate;    // 12 bytes (max 7.9e10 * 1e18)

        // Slot 2+
        uint256 aPNTsBalance;
        uint256 totalSpent;
        uint256 totalTxSponsored;
        uint256 reputation;
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
    address public treasury; // Protocol Treasury for fees

    // Operator Data Mapped by Address
    mapping(address => OperatorConfig) public operators;
    
    // Slash History
    // Slash History
    mapping(address => SlashRecord[]) public slashHistory;
    
    // V3.2: Debt Tracking (Moved to xPNTsToken)
    // mapping(address => uint256) public userDebts; // Removed in V3.2
    
    // Pricing Config
    
    // Pricing Config
    uint256 public constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 public constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    
    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)
    PriceCache private cachedPrice;

    // Protocol Fee (Basis Points)
    uint256 public protocolFeeBPS = 200; // 2%
    uint256 public constant BPS_DENOMINATOR = 10000;

    address public BLS_AGGREGATOR; // Trusted Aggregator for DVT Slash

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

    // V3.1: Credit & Reputation Events
    event UserReputationAccrued(address indexed user, uint256 aPNTsValue);
    // event DebtRecorded(address indexed user, uint256 amount); // Moved to token
    // event DebtRepaid(address indexed user, uint256 amount);   // Moved to token

    /**
     * @notice Emitted when validation is rejected with a specific reason code
     * @param user The user whose operation was rejected
     * @param operator The operator address
     * @param reasonCode Rejection reason: 1=Operator not registered, 2=User not verified, 3=Credit limit exceeded
     */
    event ValidationRejected(address indexed user, address indexed operator, uint8 reasonCode);

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
        treasury = _protocolTreasury != address(0) ? _protocolTreasury : _owner;
    }

    // ====================================
    // Operator Management
    // ====================================

    /**
     * @notice Configure billing settings (Operator only)
     * @param xPNTsToken Token to charge users
     * @param _opTreasury Address to receive payments
     * @param exchangeRate Rate (1e18 = 1:1)
     */
    function configureOperator(address xPNTsToken, address _opTreasury, uint256 exchangeRate) external {
        // Must be registered in Registry
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert("Operator not registered");
        }
        if (xPNTsToken == address(0) || _opTreasury == address(0) || exchangeRate == 0) {
            revert("Invalid configuration");
        }

        OperatorConfig storage config = operators[msg.sender];
        config.xPNTsToken = xPNTsToken;
        config.treasury = _opTreasury;
        config.exchangeRate = uint96(exchangeRate);
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
     * @notice Set the APNTS Price in USD (Owner Only)
     */
    function setAPNTSPrice(uint256 newPrice) external onlyOwner {
        aPNTsPriceUSD = newPrice;
    }

    /**
     * @notice Set the protocol fee basis points (Owner Only)
     */
    function setProtocolFee(uint256 newFeeBPS) external onlyOwner {
        protocolFeeBPS = newFeeBPS;
    }

    /**
     * @notice Set the protocol treasury address (Owner Only)
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }

    /**
     * @notice Pause/Unpause an operator (Owner Only)
     * @dev Used for security emergency stops
     */
    function setOperatorPaused(address operator, bool paused) external onlyOwner {
        operators[operator].isPaused = paused;
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
        
        // V3.1: Auto-Repay Debt
        _autoRepayDebt(msg.sender, amount);
    }
    
    function _autoRepayDebt(address user, uint256 depositedAmount) internal {
        // V3.2: Deprecated. Auto-Repayment is handled by xPNTsToken._update() hook.
    }



    /**
     * @notice Withdraw aPNTs
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (operators[msg.sender].aPNTsBalance < amount) {
            revert("Insufficient balance");
        }
        operators[msg.sender].aPNTsBalance -= amount;
        
        IERC20(APNTS_TOKEN).safeTransfer(msg.sender, amount);
        
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

    function getAvailableCredit(address user, address token) public view returns (uint256) {
        // Calculate Credit in APNTs
        uint256 creditLimitAPNTs = REGISTRY.getCreditLimit(user);
        
        // Get Debt from Token (in xPNTs)
        uint256 currentDebtXPNTs = IModernXPNTsToken(token).getDebt(user);
        
        // Convert Debt to APNTs for comparison
        // xPNTs = aPNTs * Rate / 1e18 => aPNTs = xPNTs * 1e18 / Rate
        uint256 rate = IModernXPNTsToken(token).exchangeRate();
        uint256 currentDebtAPNTs = (currentDebtXPNTs * 1e18) / rate;

        return creditLimitAPNTs > currentDebtAPNTs ? creditLimitAPNTs - currentDebtAPNTs : 0;
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

    /**
     * @notice Execute slash triggered by BLS consensus (DVT Module only)
     */
    function executeSlashWithBLS(address operator, SlashLevel level, bytes calldata proof) external {
        require(msg.sender == BLS_AGGREGATOR, "Only BLS Aggregator");
        
        // Logical penalty (Warning=0, Minor=10%, Major=Full & Pause)
        uint256 penalty = 0;
        if (level == SlashLevel.MINOR) {
            penalty = operators[operator].aPNTsBalance / 10;
        } else if (level == SlashLevel.MAJOR) {
            penalty = operators[operator].aPNTsBalance;
        }

        _slash(operator, level, penalty, "DVT BLS Slash", proof);
    }

    function _slash(address operator, SlashLevel level, uint256 penaltyAmount, string memory reason, bytes memory proof) internal {
        OperatorConfig storage config = operators[operator];
        
        uint256 reputationLoss = level == SlashLevel.WARNING ? 10 : (level == SlashLevel.MINOR ? 20 : 50);
        if (level == SlashLevel.MAJOR) config.isPaused = true;

        if (config.reputation > reputationLoss) config.reputation -= reputationLoss;
        else config.reputation = 0;

        if (penaltyAmount > 0) {
            config.aPNTsBalance -= penaltyAmount;
            protocolRevenue += penaltyAmount;
        }

        slashHistory[operator].push(SlashRecord({
            timestamp: block.timestamp,
            amount: penaltyAmount,
            reputationLoss: reputationLoss,
            reason: reason,
            level: level
        }));

        emit OperatorSlashed(operator, penaltyAmount, level);
    }

    function setBLSAggregator(address _bls) external onlyOwner {
        BLS_AGGREGATOR = _bls;
    }

    // ====================================
    // Slash Query Interfaces
    // ====================================

    /**
     * @notice Get complete slash history for an operator
     * @param operator Operator address
     * @return Array of slash records
     */
    function getSlashHistory(address operator) external view returns (SlashRecord[] memory) {
        return slashHistory[operator];
    }

    /**
     * @notice Get total number of times an operator has been slashed
     * @param operator Operator address
     * @return Total slash count
     */
    function getSlashCount(address operator) external view returns (uint256) {
        return slashHistory[operator].length;
    }

    /**
     * @notice Get the most recent slash record for an operator
     * @param operator Operator address
     * @return Most recent slash record (reverts if no history)
     */
    function getLatestSlash(address operator) external view returns (SlashRecord memory) {
        require(slashHistory[operator].length > 0, "No slash history");
        return slashHistory[operator][slashHistory[operator].length - 1];
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
            // Rejection code 1: Operator not registered
            emit ValidationRejected(userOp.sender, operator, 1);
            return ("", _packValidationData(true, 0, 0)); 
        }
        
        // 3. Validate User Role (Unified Verification)
        if (!REGISTRY.hasRole(keccak256("ENDUSER"), userOp.sender)) {
             // Rejection code 2: User not verified
             emit ValidationRejected(userOp.sender, operator, 2);
             return ("", _packValidationData(true, 0, 0)); 
        }

        OperatorConfig storage config = operators[operator];

        // 3. User Validation & Credit Check (V3.2 Credit System Redesign)
        // ----------------------------------------
        
        uint256 creditLimitAPNTs = REGISTRY.getCreditLimit(userOp.sender);
        
        // Get Debt from Token (xPNTs units)
        uint256 currentDebtXPNTs = IModernXPNTsToken(config.xPNTsToken).getDebt(userOp.sender);
        
        // Convert Debt to aPNTs units for comparison
        uint256 currentDebtAPNTs = (currentDebtXPNTs * 1e18) / config.exchangeRate;
        
        uint256 availableCreditAPNTs = creditLimitAPNTs > currentDebtAPNTs ? creditLimitAPNTs - currentDebtAPNTs : 0;
        
        // Billing Calculation (Standard Wei based)
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);
        uint256 xPNTsAmount = (aPNTsAmount * config.exchangeRate) / 1e18; // Est. xPNTs cost

        // Critical: If user has debt > limit, block them immediately
        if (currentDebtAPNTs >= creditLimitAPNTs && creditLimitAPNTs > 0) {
             // Rejection code 3: Credit Limit Exceeded
             emit ValidationRejected(userOp.sender, operator, 3);
             return ("", _packValidationData(true, 0, 0)); 
        }

        // V3.2 HYBRID APPROACH:
        // Use Credit if available, otherwise User MUST have balance to burn immediately.
        
        bool useCredit = aPNTsAmount <= availableCreditAPNTs;
        
        if (!useCredit) {
             // Attempt Immediate Burn (V3 Legacy Mode)
             // This ensures we don't pay for broke users
             IModernXPNTsToken(config.xPNTsToken).burnFromWithOpHash(userOp.sender, xPNTsAmount, userOpHash);
        }

        // ... Config Checks ...
        if (!config.isConfigured) {
             return ("", _packValidationData(true, 0, 0)); 
        }
        
        if (config.isPaused) {
             return ("", _packValidationData(true, 0, 0)); 
        }

        // 4. Billing Logic
        if (config.aPNTsBalance < aPNTsAmount) {
             return ("", _packValidationData(true, 0, 0)); 
        }

        // 5. Effects (Optimistic & Batch)
        config.aPNTsBalance -= aPNTsAmount;
        config.totalSpent += aPNTsAmount;
        protocolRevenue += aPNTsAmount;
        config.totalTxSponsored++;

        emit TransactionSponsored(operator, userOp.sender, aPNTsAmount, xPNTsAmount);
        
        // V3.1: Emit Reputation Accrual Signal
        emit UserReputationAccrued(userOp.sender, aPNTsAmount);

        // Context Construction
        if (useCredit) {
             return (abi.encode(config.xPNTsToken, xPNTsAmount, userOp.sender, aPNTsAmount), 0);
        } else {
             return ("", 0);
        }
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        // If context is empty, we already paid in validation (V3 Mode)
        if (context.length == 0) return;
        
        // Otherwise, Credit Mode active
        (address token, uint256 xPNTsAmount, address user, uint256 aPNTsAmount) = 
            abi.decode(context, (address, uint256, address, uint256));

        // Re-calculate actual cost if needed (optional optimization)
        // For now use the max estimated to ensure Paymaster safety
        
        if (mode == PostOpMode.opReverted) {
            // User Tx failed, but we still need to charge Gas
            // Proceed to charge
        }

        // Try to Burn
        // Note: We use a dummy hash or 0 here because postOp doesn't have the UserOpHash readily available 
        // in standard interface arguments without calldata inspection. 
        // BUT, IModernXPNTsToken expects a hash. 
        // Ideally we should pass the hash in context, but for Debt recording we might fall back 
        // to a trusted burn or just record debt if token supports it.
        // 
        // Wait, standard V3 token requires hash. 
        // If we are here, we are "Authorized" Paymaster. 
        // We should update Token Interface to allow "burnFrom" by trusted Paymaster without Hash?
        // Or we pass the hash in context!
        // 
        // Correct Approach: We need userOpHash in context.
        // BUT userOpHash is not available in validate() return context easily? 
        // Actually, it IS passed to validate(). So we can pack it.
        
        // REVISION: We need to pass userOpHash in context for this to work with verify userOpHash token.
        // However, if we resort to Debt, we don't need to burn now. 
        // We only burn if successful.
        
        // Let's assume for V3.1 we optimistically try standard `burnFrom` 
        // (which might need Token upgrade to allow Paymaster role to burn without hash?)
        // OR we record debt.
        
        // SIMPLIFICATION for V3.1 Prototype:
        // Just record DEBT for the *entire* amount in PostOp logic?
        // No, we want to try to burn first.
        
        // Since we didn't update Token Interface in this plan, let's assume we maintain `burnFromWithOpHash`.
        // I will need to update `validate` to pass `userOpHash` in context.
        
        // Implementation:
        // 1. Try Burn (using Hash from context) -- NOT POSSIBLE, Hash is sensitive? No, Hash is public.
        // 2. Catch -> Record Debt.

        // WARNING: hash is not in context yet. I will update step above.
        // But for now, let's just implement the "Record Debt" fallback logic assuming failure.
        
        // Since we can't easily change Token interface now, and we can't easily pass Hash (context size limit?),
        // Let's rely on the "Failed Burn" scenario implicitly:
        // If we are in `useCredit` mode, we deferred payment. 
        // So we MUST record debt or burn.
        // Let's just Record Debt 100% of the time for Credit users?
        // No, that's inefficient.
        
        // Proposed V3.2 Logic:
        // If Credit Mode: Record Debt in Token.
        
        IModernXPNTsToken(token).recordDebt(user, xPNTsAmount);
        // Note: No immediate burn logic here (handled by Token auto-repay on next transfer)
        
    }
    
    function repayDebt(address user, uint256 amount) external nonReentrant {
        // V3.2: Deprecated. Use Token transfer to repay.
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
        uint256 usdValue = (gasCostWei * priceUint * (10**(18 - decimals))) / 1e18;

        // To get aPNTs (18 decimals), we take usdValue (36 decimals) and divide by aPNTs price (18 decimals)
        return usdValue / aPNTsPriceUSD;
    }

    
}