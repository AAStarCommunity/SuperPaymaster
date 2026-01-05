// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasePaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../../interfaces/v3/IRegistry.sol";
import "../../../interfaces/IxPNTsToken.sol";
import "../../../interfaces/IxPNTsFactory.sol";
import "../../../interfaces/ISuperPaymaster.sol";



/**
 * @title SuperPaymaster
 * @notice SuperPaymaster - Unified Registry based Multi-Operator Paymaster
 * @dev Optimized for Gas and Security (CEI, Packing, Batch Updates).
 */
contract SuperPaymaster is BasePaymaster, ReentrancyGuard, ISuperPaymaster {
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

    IRegistry public immutable REGISTRY;
    address public APNTS_TOKEN;            // aPNTs (AAStar Token) - Mutable to allow updates
    address public xpntsFactory;           // xPNTs Factory for dynamic pricing
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;
    address public treasury; // Protocol Treasury for fees

    // --- Mappings ---
    mapping(address => ISuperPaymaster.OperatorConfig) public operators;
    mapping(address => mapping(address => bool)) public blockedUsers; // operator => user => isBlocked
    mapping(address => mapping(address => uint48)) public lastUserOpTimestamp; // operator => user => timestamp
    mapping(address => ISuperPaymaster.SlashRecord[]) public slashHistory;

    function version() external pure override returns (string memory) {
        return "SuperPaymaster-3.2.2";
    }

    uint256 public constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 public constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    
    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)

    PriceCache public cachedPrice; // Make public for easy verification
    uint256 public constant PRICE_STALENESS_THRESHOLD = 1 hours; // Maximum allowed age for price

    // V3.2.1 SECURITY: Enforce max rate in Validation
    uint256 public constant PAYMASTER_DATA_OFFSET = 52; // ERC-4337 v0.7
    uint256 public constant RATE_OFFSET = 72; // After Operator (20 bytes)

    // Protocol Fee (Basis Points)
    uint256 public protocolFeeBPS = 1000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    address public BLS_AGGREGATOR; // Trusted Aggregator for DVT Slash

    // State Variables (Restored)
    uint256 public totalTrackedBalance;
    uint256 public protocolRevenue;

    // V3.1: Credit & Reputation Events
    event UserReputationAccrued(address indexed user, uint256 aPNTsValue);

    /**
     * @notice Emitted when aPNTs token is updated
     */
    event APNTsTokenUpdated(address indexed oldToken, address indexed newToken);
    event OperatorPaused(address indexed operator);
    event OperatorUnpaused(address indexed operator);
    event OperatorMinTxIntervalUpdated(address indexed operator, uint48 minTxInterval);
    event UserBlockedStatusUpdated(address indexed operator, address indexed user, bool isBlocked);

    error Unauthorized();
    error InvalidAddress();
    error InvalidConfiguration();
    error InsufficientBalance();
    error DepositNotVerified();
    error OracleError();
    error NoSlashHistory();
    error InsufficientRevenue();

    // ====================================
    // Constructor
    // ====================================

    constructor(
        IEntryPoint _entryPoint,
        address _owner,
        IRegistry _registry,
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
        if (!REGISTRY.hasRole(REGISTRY.ROLE_PAYMASTER_SUPER(), msg.sender)) {
            revert Unauthorized();
        }
        // BUS-RULE: Must be Community to be Paymaster
         if (!REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), msg.sender)) {
            revert Unauthorized();
        }
        if (xPNTsToken == address(0) || _opTreasury == address(0) || exchangeRate == 0) {
            revert InvalidConfiguration();
        }

        OperatorConfig storage config = operators[msg.sender];
        config.xPNTsToken = xPNTsToken;
        config.treasury = _opTreasury;
        config.exchangeRate = uint96(exchangeRate);
        config.isConfigured = true;

        emit OperatorConfigured(msg.sender, xPNTsToken, _opTreasury, exchangeRate);
    }

    /**
     * @notice Set the APNTS Token address (Owner Only)
     */
    function setAPNTsToken(address newAPNTsToken) external onlyOwner {
        if (newAPNTsToken == address(0)) revert InvalidAddress();
        address oldToken = APNTS_TOKEN;
        APNTS_TOKEN = newAPNTsToken;
        emit APNTsTokenUpdated(oldToken, newAPNTsToken);
    }

    /**
     * @notice Set the APNTS Price in USD (Owner Only)
     */
    function setAPNTSPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidConfiguration();
        aPNTsPriceUSD = newPrice;
    }

    /**
     * @notice Set the protocol fee basis points (Owner Only)
     */
    function setProtocolFee(uint256 newFeeBPS) external onlyOwner {
        if (newFeeBPS > BPS_DENOMINATOR) revert InvalidConfiguration();
        protocolFeeBPS = newFeeBPS;
    }

    /**
     * @notice Set the protocol treasury address (Owner Only)
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    function setXPNTsFactory(address _factory) external onlyOwner {
        xpntsFactory = _factory;
    }

    /**
     * @notice Pause/Unpause an operator (Owner Only)
     * @dev Used for security emergency stops
     */
    function setOperatorPaused(address operator, bool paused) external onlyOwner {
        operators[operator].isPaused = paused;
        if (paused) {
            emit OperatorPaused(operator);
        } else {
            emit OperatorUnpaused(operator);
        }
    }

    /**
     * @notice Set operator limits (e.g. Rate Limiting)
     */
    function setOperatorLimits(uint48 _minTxInterval) external {
        if (!REGISTRY.hasRole(REGISTRY.ROLE_PAYMASTER_SUPER(), msg.sender)) revert Unauthorized();
        operators[msg.sender].minTxInterval = _minTxInterval;
        emit OperatorMinTxIntervalUpdated(msg.sender, _minTxInterval);
    }

    /**
     * @notice Batch update blocked status for users (Called by Registry via DVT)
     * @dev Allows DVT to sync credit-exhausted users to Paymaster blacklist
     */
    function updateBlockedStatus(address operator, address[] calldata users, bool[] calldata statuses) external {
        if (msg.sender != address(REGISTRY)) revert Unauthorized();
        if (users.length != statuses.length) revert InvalidConfiguration();

        for (uint256 i = 0; i < users.length; i++) {
            blockedUsers[operator][users[i]] = statuses[i];
            emit UserBlockedStatusUpdated(operator, users[i], statuses[i]);
        }
    }

    /**
     * @notice Update price via DVT signature (Future Proofing)
     * @dev Currently restricted to Owner, can be expanded to BLS Aggregator later
     */
    function updatePriceDVT(int256 price, uint256 updatedAt, bytes calldata /* proof */) external onlyOwner {
         // In future: verify proof from BLS_AGGREGATOR
         if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();
         
         cachedPrice = PriceCache({
            price: price,
            updatedAt: updatedAt,
            roundId: 0, // DVT doesn't have Chainlink RoundID
            decimals: 8 // Assuming DVT normalizes to 8 decimals
        });
    }

    /**
     * @notice Deposit aPNTs
     */
    /**
     * @notice Deposit aPNTs (Legacy Pull Mode)
     * @dev Only works if APNTS_TOKEN allows transferFrom (e.g. old token or whitelisted)
     */
    function deposit(uint256 amount) external nonReentrant {
        if (!REGISTRY.hasRole(REGISTRY.ROLE_PAYMASTER_SUPER(), msg.sender)) {
            revert Unauthorized();
        }
        
        // This might revert if Token blocks transferFrom (Secure Token)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        // Check overflow for uint128
        if (amount > type(uint128).max) revert("Amount exceeds uint128");
        operators[msg.sender].aPNTsBalance += uint128(amount);
        
        // Fix: Update tracked balance to prevent double counting in notifyDeposit
        totalTrackedBalance += amount;
        
        emit OperatorDeposited(msg.sender, amount);
    }

    // ====================================
    // Push Deposit & Views (Restored)
    // ====================================

    /**
     * @notice Handle ERC1363 transferAndCall (Push Mode)
     * @dev Safe deposit mechanism for tokens blocking transferFrom
     */
    function onTransferReceived(address, address from, uint256 value, bytes calldata) external returns (bytes4) {
        if (msg.sender != APNTS_TOKEN) revert Unauthorized();

        // Ensure operator is registered
        if (!REGISTRY.hasRole(REGISTRY.ROLE_PAYMASTER_SUPER(), from)) {
             revert Unauthorized();
        }


        if (value > type(uint128).max) revert("Amount exceeds uint128");
        operators[from].aPNTsBalance += uint128(value);
        // Update tracked balance to keep sync with manual transfers
        totalTrackedBalance += value;
        
        emit OperatorDeposited(from, value);

        return this.onTransferReceived.selector;
    }

    /**
     * @notice Notify contract of a direct transfer (Ad-hoc Push Mode)
     * @dev Fallback for tokens that don't support ERC1363.
     *      User must transfer tokens first, then call this.
     */
    /**
     * @notice Deposit aPNTs for a specific operator (Secure Push Mode)
     * @param targetOperator The operator to credit the deposit to
     * @param amount Amount of aPNTs
     */
    function depositFor(address targetOperator, uint256 amount) external nonReentrant {
        if (!REGISTRY.hasRole(REGISTRY.ROLE_PAYMASTER_SUPER(), targetOperator)) {
            revert Unauthorized();
        }
        
        // Transfer from sender (must approve first)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        
        if (amount > type(uint128).max) revert("Amount exceeds uint128");
        operators[targetOperator].aPNTsBalance += uint128(amount);
        totalTrackedBalance += amount;
        
        emit OperatorDeposited(targetOperator, amount);
    }




    /**
     * @notice Withdraw aPNTs
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (operators[msg.sender].aPNTsBalance < amount) {
            revert InsufficientBalance();
        }
        operators[msg.sender].aPNTsBalance -= uint128(amount);
        // Fix: Reduce tracked balance to prevent underflow in notifyDeposit
        totalTrackedBalance -= amount;
        
        IERC20(APNTS_TOKEN).safeTransfer(msg.sender, amount);
        
        emit OperatorWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Withdraw accumulated Protocol Revenue
     * @param amount Amount of aPNTs to withdraw
     * @param to Address to receive funds (usually treasury)
     */
    function withdrawProtocolRevenue(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount > protocolRevenue) revert InsufficientRevenue();
        
        protocolRevenue -= amount;
        // Fix: Reduce tracked balance
        totalTrackedBalance -= amount;
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
    function slashOperator(address operator, ISuperPaymaster.SlashLevel level, uint256 penaltyAmount, string calldata reason) external onlyOwner {
        ISuperPaymaster.OperatorConfig storage config = operators[operator];
        
        uint256 reputationLoss = 0;
        if (level == ISuperPaymaster.SlashLevel.WARNING) {
            reputationLoss = 10;
        } else if (level == ISuperPaymaster.SlashLevel.MINOR) {
            reputationLoss = 20;
        } else if (level == ISuperPaymaster.SlashLevel.MAJOR) {
            reputationLoss = 50;
            config.isPaused = true;
            emit OperatorPaused(operator);
        }

        // Apply Reputation Loss
        if (config.reputation > reputationLoss) {
            config.reputation -= uint32(reputationLoss);
        } else {
            config.reputation = 0;
        }

        // Apply Financial Penalty (Burn aPNTs to Protocol Revenue)
        if (penaltyAmount > 0) {
            if (config.aPNTsBalance >= penaltyAmount) {
                config.aPNTsBalance -= uint128(penaltyAmount);
                // Fix: Move slashed funds to Protocol Revenue
                protocolRevenue += penaltyAmount;
            } else {
                // Slash all remaining
                uint256 actualBurn = config.aPNTsBalance;
                config.aPNTsBalance = 0;
                protocolRevenue += actualBurn;
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
        if (newScore > type(uint32).max) revert("Score exceeds uint32");
        operators[operator].reputation = uint32(newScore);
        emit ReputationUpdated(operator, newScore);
    }



    /**
     * @notice Execute slash triggered by BLS consensus (DVT Module only)
     */
    function executeSlashWithBLS(address operator, ISuperPaymaster.SlashLevel level, bytes calldata proof) external override {
        if (msg.sender != BLS_AGGREGATOR) revert Unauthorized();
        
        // Logical penalty (Warning=0, Minor=10%, Major=Full & Pause)
        uint256 penalty = 0;
        if (level == ISuperPaymaster.SlashLevel.MINOR) {
            penalty = operators[operator].aPNTsBalance / 10;
        } else if (level == ISuperPaymaster.SlashLevel.MAJOR) {
            penalty = operators[operator].aPNTsBalance;
        }

        _slash(operator, level, penalty, "DVT BLS Slash", proof);
    }

    function _slash(address operator, ISuperPaymaster.SlashLevel level, uint256 penaltyAmount, string memory reason, bytes memory proof) internal {
        ISuperPaymaster.OperatorConfig storage config = operators[operator];
        
        uint256 reputationLoss = level == ISuperPaymaster.SlashLevel.WARNING ? 10 : (level == ISuperPaymaster.SlashLevel.MINOR ? 20 : 50);
        if (level == ISuperPaymaster.SlashLevel.MAJOR) config.isPaused = true;

        if (config.reputation > reputationLoss) config.reputation -= uint32(reputationLoss);
        else config.reputation = 0;

        if (penaltyAmount > 0) {
            config.aPNTsBalance -= uint128(penaltyAmount);
            protocolRevenue += penaltyAmount;
        }

        slashHistory[operator].push(ISuperPaymaster.SlashRecord({
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

    function getSlashHistory(address operator) external view returns (ISuperPaymaster.SlashRecord[] memory) {
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
    function getLatestSlash(address operator) external view returns (ISuperPaymaster.SlashRecord memory) {
        if (slashHistory[operator].length == 0) revert NoSlashHistory();
        return slashHistory[operator][slashHistory[operator].length - 1];
    }

    // ====================================
    // Paymaster Implementation
    // ====================================

    function updatePrice() public {
        // 1. Get Price from Chainlink (External Call)
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            
        ) = ETH_USD_PRICE_FEED.latestRoundData();

        if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();
        if (updatedAt < block.timestamp - PRICE_STALENESS_THRESHOLD) revert OracleError(); // Too stale

        // 2. Update Cache
        cachedPrice = PriceCache({
            price: price,
            updatedAt: updatedAt,
            roundId: roundId,
            decimals: ETH_USD_PRICE_FEED.decimals()
        });
    }
    function _calculateAPNTsAmount(uint256 ethAmountWei) internal view returns (uint256) {
        // Use Cached Price (Pure Storage Read)
        PriceCache memory cache = cachedPrice;
        
        // Safety:
        if (cache.price <= 0) revert OracleError();
        // aPNTs Price = $0.02 (approx) - Fixed for now or fetchable? 
        // Hardcoded aPNTs price at $0.02 for this V3 implementation as per line 60.
        
        // Value in USD = ethAmountWei * price / 10^decimals
        // aPNTs Amount = Value in USD / aPNTsPriceUSD
        
        // Calculation:
        // (ethAmount * price * 10^18) / (10^decimals * aPNTsPriceUSD)
        
        return (ethAmountWei * uint256(cache.price) * 1e18) / (10**cache.decimals * aPNTsPriceUSD);
    }

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint nonReentrant returns (bytes memory context, uint256 validationData) {
        // 1. Extract Operator
        address operator = _extractOperator(userOp);
        
        ISuperPaymaster.OperatorConfig storage config = operators[operator];

        // 2. Validate Operator Role & Config (Pure Storage)
        // Check 1: Must be Configured (implies registered/valid)
        if (!config.isConfigured) {
             return ("", _packValidationData(true, 0, 0)); 
        }
        
        // Check 2: Must not be Paused
        if (config.isPaused) {
             return ("", _packValidationData(true, 0, 0)); 
        }

        // V3.2 Security: Check Blocklist & Rate Limit
        if (blockedUsers[operator][userOp.sender]) {
             return ("", _packValidationData(true, 0, 0));
        }

        if (config.minTxInterval > 0) {
            uint48 lastTime = lastUserOpTimestamp[operator][userOp.sender];
            uint48 currentTime = uint48(block.timestamp);
            
            // Optimization: Allow multiple ops in same block (support Bundles)
            // Only check interval if time has advanced since last op
            if (currentTime > lastTime) {
                if (currentTime < lastTime + config.minTxInterval) {
                     return ("", _packValidationData(true, 0, 0));
                }
            }
            lastUserOpTimestamp[operator][userOp.sender] = currentTime;
        }

        // 2.1 Validate Rate Commitment (Rug Pull Protection)
        // paymasterAndData: [paymaster(20)] [gasLimits(32)] [operator(20)] [maxRate(32)]
        uint256 maxRate = type(uint256).max;
        if (userOp.paymasterAndData.length >= 104) {
             maxRate = abi.decode(userOp.paymasterAndData[RATE_OFFSET:RATE_OFFSET+32], (uint256));
        }
        
        // Cast uint96 to uint256 for comparison
        if (uint256(config.exchangeRate) > maxRate) {
             emit ValidationRejected(userOp.sender, operator, 4);
             return ("", _packValidationData(true, 0, 0)); 
        }
        
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);

        // 4. Solvency Check (Pure Storage)
        if (uint256(config.aPNTsBalance) < aPNTsAmount) {
             return ("", _packValidationData(true, 0, 0)); 
        }

        // 5. Accounting (Optimistic)
        config.aPNTsBalance -= uint128(aPNTsAmount); // Safe cast due to check above
        config.totalSpent += aPNTsAmount;
        protocolRevenue += aPNTsAmount;
        config.totalTxSponsored++;

        // 6. Return Context
        uint256 xPNTsAmount = (aPNTsAmount * uint256(config.exchangeRate)) / 1e18;
        
        emit TransactionSponsored(operator, userOp.sender, aPNTsAmount, xPNTsAmount);
        
        // Use Empty Context to save gas (PostOp can re-read or we assume optimistic success)
        // Or if we need PostOp refund, we pass data.
        return (abi.encode(config.xPNTsToken, xPNTsAmount, userOp.sender, aPNTsAmount, userOpHash, operator), 0);
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        if (context.length == 0) return;
        
        (
            address token, 
            uint256 estimatedXPNTs, 
            address user, 
            uint256 initialAPNTs, 
            bytes32 userOpHash, 
            address operator
        ) = abi.decode(context, (address, uint256, address, uint256, bytes32, address));

        // 1. Calculate Actual Cost in aPNTs
        // actualGasCost is in Wei. We convert to aPNTs using the same oracle logic (or cached)
        uint256 actualAPNTsCost = _calculateAPNTsAmount(actualGasCost);

        // 2. Apply Protocol Fee Markup (e.g. 10%)
        // We want the final deduction to be Actual + 10%.
        uint256 finalCharge = (actualAPNTsCost * (BPS_DENOMINATOR + protocolFeeBPS)) / BPS_DENOMINATOR;

        // 3. Process Refund
        // We initially deducted `initialAPNTs` (Max) and credited it ALL to `protocolRevenue`.
        // Now we need to adjust:
        // - If finalCharge < initialAPNTs: Refund the difference.
        // - Funds move: Revenue -> Operator Balance.
        if (finalCharge < initialAPNTs) {
            uint256 refund = initialAPNTs - finalCharge;
            
            if (refund > type(uint128).max) refund = type(uint128).max; // Cap refund at uint128 max (unlikely)
            operators[operator].aPNTsBalance += uint128(refund);
            protocolRevenue -= refund;
            // totalTrackedBalance remains unchanged (funds just moved pockets)
            
            // Recalculate User Debt based on Final Charge
            uint256 exchangeRate = operators[operator].exchangeRate;
            uint256 finalXPNTsDebt = (finalCharge * exchangeRate) / 1e18;
            
            IxPNTsToken(token).recordDebt(user, finalXPNTsDebt);
            
            emit TransactionSponsored(operator, user, finalCharge, finalXPNTsDebt);
        } else {
             // Should rarely happen (Actual > Max), just cap at Max
             IxPNTsToken(token).recordDebt(user, estimatedXPNTs);
        }
    }
    

    // ====================================
    // Internal & View
    // ====================================

    function _extractOperator(PackedUserOperation calldata userOp) internal pure returns (address) {
        // paymasterAndData: [paymaster(20)] [gasLimits(32)] [operator(20)] ...
        // Fix: Read from offset 52 (standard ERC-4337 v0.7 layout)
        if (userOp.paymasterAndData.length < 72) return address(0);
        return address(bytes20(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET+20]));
    }




}