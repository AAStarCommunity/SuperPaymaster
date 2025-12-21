// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasePaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../../interfaces/v3/IRegistryV3.sol";
import "../../../interfaces/IxPNTsToken.sol";
import "../../../interfaces/ISuperPaymasterV3.sol";



/**
 * @title SuperPaymasterV3
 * @notice V3 SuperPaymaster - Unified Registry based Multi-Operator Paymaster
 * @dev Inherits V2.3 capabilities (Billing, Oracle, Treasury) with V3 Registry integration.
 *      Optimized for Gas and Security (CEI, Packing, Batch Updates).
 */
contract SuperPaymasterV3 is BasePaymaster, ReentrancyGuard, ISuperPaymasterV3 {
    using SafeERC20 for IERC20;



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
    mapping(address => ISuperPaymasterV3.OperatorConfig) public operators;
    
    // Slash History
    mapping(address => ISuperPaymasterV3.SlashRecord[]) public slashHistory;
    
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


    // V3.1: Credit & Reputation Events
    event UserReputationAccrued(address indexed user, uint256 aPNTsValue);

    /**
     * @notice Emitted when aPNTs token is updated
     */
    event APNTsTokenUpdated(address indexed oldToken, address indexed newToken);
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
        if (!REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), msg.sender)) {
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
        config.treasury = _opTreasury; // Use operator's treasury

        emit OperatorConfigured(msg.sender, xPNTsToken, _opTreasury, exchangeRate);
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
        if (!REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), msg.sender)) {
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
        if (!REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), from)) {
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
        if (!REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), msg.sender)) {
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
        uint256 currentDebtXPNTs = IxPNTsToken(token).getDebt(user);
        
        // Convert Debt to APNTs for comparison
        // xPNTs = aPNTs * Rate / 1e18 => aPNTs = xPNTs * 1e18 / Rate
        uint256 rate = IxPNTsToken(token).exchangeRate();
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
    function slashOperator(address operator, ISuperPaymasterV3.SlashLevel level, uint256 penaltyAmount, string calldata reason) external onlyOwner {
        ISuperPaymasterV3.OperatorConfig storage config = operators[operator];
        
        uint256 reputationLoss = 0;
        if (level == ISuperPaymasterV3.SlashLevel.WARNING) {
            reputationLoss = 10;
        } else if (level == ISuperPaymasterV3.SlashLevel.MINOR) {
            reputationLoss = 20;
        } else if (level == ISuperPaymasterV3.SlashLevel.MAJOR) {
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
    function executeSlashWithBLS(address operator, ISuperPaymasterV3.SlashLevel level, bytes calldata proof) external override {
        require(msg.sender == BLS_AGGREGATOR, "Only BLS Aggregator");
        
        // Logical penalty (Warning=0, Minor=10%, Major=Full & Pause)
        uint256 penalty = 0;
        if (level == ISuperPaymasterV3.SlashLevel.MINOR) {
            penalty = operators[operator].aPNTsBalance / 10;
        } else if (level == ISuperPaymasterV3.SlashLevel.MAJOR) {
            penalty = operators[operator].aPNTsBalance;
        }

        _slash(operator, level, penalty, "DVT BLS Slash", proof);
    }

    function _slash(address operator, ISuperPaymasterV3.SlashLevel level, uint256 penaltyAmount, string memory reason, bytes memory proof) internal {
        ISuperPaymasterV3.OperatorConfig storage config = operators[operator];
        
        uint256 reputationLoss = level == ISuperPaymasterV3.SlashLevel.WARNING ? 10 : (level == ISuperPaymasterV3.SlashLevel.MINOR ? 20 : 50);
        if (level == ISuperPaymasterV3.SlashLevel.MAJOR) config.isPaused = true;

        if (config.reputation > reputationLoss) config.reputation -= reputationLoss;
        else config.reputation = 0;

        if (penaltyAmount > 0) {
            config.aPNTsBalance -= penaltyAmount;
            protocolRevenue += penaltyAmount;
        }

        slashHistory[operator].push(ISuperPaymasterV3.SlashRecord({
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

    function getSlashHistory(address operator) external view returns (ISuperPaymasterV3.SlashRecord[] memory) {
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
    function getLatestSlash(address operator) external view returns (ISuperPaymasterV3.SlashRecord memory) {
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
        if (!REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), operator)) {
            // Rejection code 1: Operator not registered
            emit ValidationRejected(userOp.sender, operator, 1);
            return ("", _packValidationData(true, 0, 0)); 
        }
        
        // 3. Validate User Role (Unified Verification)
        if (!REGISTRY.hasRole(REGISTRY.ROLE_ENDUSER(), userOp.sender)) {
             // Rejection code 2: User not verified
             emit ValidationRejected(userOp.sender, operator, 2);
             return ("", _packValidationData(true, 0, 0)); 
        }

        ISuperPaymasterV3.OperatorConfig storage config = operators[operator];

        // 3. User Validation & Credit Check (V3.2 Credit System Redesign)
        // ----------------------------------------
        
        uint256 creditLimitAPNTs = REGISTRY.getCreditLimit(userOp.sender);
        
        // Get Debt from Token (xPNTs units)
        uint256 currentDebtXPNTs = IxPNTsToken(config.xPNTsToken).getDebt(userOp.sender);
        
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
             IxPNTsToken(config.xPNTsToken).burnFromWithOpHash(userOp.sender, xPNTsAmount, userOpHash);
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
             return (abi.encode(config.xPNTsToken, xPNTsAmount, userOp.sender, aPNTsAmount, userOpHash), 0);
        } else {
             return (bytes(""), 0);
        }
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        if (context.length == 0) return;
        
        (address token, uint256 xPNTsAmount, address user, , ) = 
            abi.decode(context, (address, uint256, address, uint256, bytes32));

        // V3.2: Record debt regardless of tx success (User already optimized away in validate)
        IxPNTsToken(token).recordDebt(user, xPNTsAmount);
        
        // Optional: Log actual cost if it differs significantly from estimate
        // (Not implemented for gas efficiency)
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