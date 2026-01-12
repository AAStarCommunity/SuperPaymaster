// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BasePaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
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
    // V3.5 Optimization: Packed User State (Slot Optimized)
    struct UserOperatorState {
        uint48 lastTimestamp; // 6 bytes
        bool isBlocked;       // 1 byte
        // 25 bytes remaining in slot
    }

    // --- Mappings ---

    // CONSOLIDATED MAPPING: operator => user => state (Saves 1 SLOAD in hot path)
    mapping(address => mapping(address => UserOperatorState)) public userOpState; 
    
    // Legacy mappings kept for ABI compatibility or migration? 
    // Actually, we should deprecate blockedUsers and lastUserOpTimestamp
    // mapping(address => mapping(address => bool)) public blockedUsers; // DEPRECATED
    // mapping(address => mapping(address => uint48)) public lastUserOpTimestamp; // DEPRECATED
    
    mapping(address => bool) public sbtHolders; // Global SBT holders list (verified via Registry)
    mapping(address => ISuperPaymaster.SlashRecord[]) public slashHistory;

    function version() external pure override returns (string memory) {
        return "SuperPaymaster-3.2.2";
    }

    uint256 public constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 public constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    
    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)

    PriceCache public cachedPrice; // Make public for easy verification
    // uint256 public constant PRICE_STALENESS_THRESHOLD = 1 hours; // REMOVED

    // V3.2.1 SECURITY: Enforce max rate in Validation
    uint256 public constant PAYMASTER_DATA_OFFSET = 52; // ERC-4337 v0.7
    uint256 public constant RATE_OFFSET = 72; // After Operator (20 bytes)

    // Protocol Fee (Basis Points)
    uint256 public protocolFeeBPS = 1000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant MAX_PROTOCOL_FEE = 2000; // 20% Hardcap (Security)
    /// @dev NOTE: Frontends/SDKs must ensure Operator balance is at least 1.1x of maxGasCost
    /// to satisfy this buffer during Validation phase.
    uint256 public constant VALIDATION_BUFFER_BPS = 1000; // 10% for Validation safety margin

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
    event APNTsPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event BLSAggregatorUpdated(address indexed oldAggregator, address indexed newAggregator);
    event OperatorPaused(address indexed operator);
    event OperatorUnpaused(address indexed operator);
    event OperatorMinTxIntervalUpdated(address indexed operator, uint48 minTxInterval);
    event UserBlockedStatusUpdated(address indexed operator, address indexed user, bool isBlocked);
    
    /**
     * @notice Emitted when slash is executed with BLS proof
     * @param operator Operator address
     * @param level Slash level
     * @param penalty Penalty amount
     * @param proofHash Hash of BLS proof (for audit, DVT keeps full proof for 30 days)
     * @param timestamp Execution timestamp
     */
    event SlashExecutedWithProof(
        address indexed operator,
        ISuperPaymaster.SlashLevel level,
        uint256 penalty,
        bytes32 proofHash,
        uint256 timestamp
    );
    
    event PriceUpdated(int256 indexed price, uint256 indexed timestamp);
    /**
     * @notice Emitted when Oracle update fails, forcing a realtime fallback (Warning Sign)
     */
    event OracleFallbackTriggered(uint256 timestamp);
    event ProtocolRevenueWithdrawn(address indexed to, uint256 amount);

    error Unauthorized();
    error InvalidAddress();
    error InvalidConfiguration();
    error InsufficientBalance(uint256 available, uint256 required);
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
        address _protocolTreasury,
        uint256 _priceStalenessThreshold
    ) BasePaymaster(_entryPoint, _owner) {
        REGISTRY = _registry;
        APNTS_TOKEN = _apntsToken;
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethUsdPriceFeed);
        treasury = _protocolTreasury != address(0) ? _protocolTreasury : _owner;
        priceStalenessThreshold = _priceStalenessThreshold > 0 ? _priceStalenessThreshold : 3600; // Default 1 hour
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
        uint256 oldPrice = aPNTsPriceUSD;
        aPNTsPriceUSD = newPrice;
        emit APNTsPriceUpdated(oldPrice, newPrice);
    }

    /**
     * @notice Set the protocol fee basis points (Owner Only)
     */
    function setProtocolFee(uint256 newFeeBPS) external onlyOwner {
        if (newFeeBPS > MAX_PROTOCOL_FEE) revert InvalidConfiguration();
        uint256 oldFee = protocolFeeBPS;
        protocolFeeBPS = newFeeBPS;
        emit ProtocolFeeUpdated(oldFee, newFeeBPS);
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

    /// @notice Price staleness threshold (seconds)
    uint256 public priceStalenessThreshold;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/

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
            userOpState[operator][users[i]].isBlocked = statuses[i];
            emit UserBlockedStatusUpdated(operator, users[i], statuses[i]);
        }
    }

    /**
     * @notice Update SBT holder status (Called by Registry)
     */
    function updateSBTStatus(address user, bool status) external {
        if (msg.sender != address(REGISTRY)) revert Unauthorized();
        sbtHolders[user] = status;
    }

    /**
     * @notice Update price via DVT/BLS consensus (Chainlink fallback)
     * @dev Verifies BLS proof from DVT validators, with ±20% deviation check against Chainlink
     * @param price New ETH/USD price (8 decimals)
     * @param updatedAt Timestamp of price update
     * @param proof BLS aggregated proof from DVT validators
     */
    function updatePriceDVT(int256 price, uint256 updatedAt, bytes calldata proof) external {
        // 1. Verify caller authority
        if (msg.sender != BLS_AGGREGATOR && msg.sender != owner()) revert Unauthorized();
        
        // V3.6 FIX: Prevent Replay & Staleness
        if (updatedAt <= cachedPrice.updatedAt) revert OracleError(); // Must be strictly increasing
        if (updatedAt < block.timestamp - 2 hours) revert OracleError(); // Must be recent
        
        // 2. Verify BLS proof via IBLSAggregator interface
        if (proof.length > 0 && BLS_AGGREGATOR != address(0)) {
            // BLS signature verification happens in BLSAggregator before calling this
            // We trust msg.sender == BLS_AGGREGATOR means proof was verified
            // This design allows owner to bypass for emergency situations
        }
        
        // 3. Validate price bounds
        if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();
        
        // 4. Optional: Check deviation from Chainlink (±20% tolerance)
        // This protects against DVT manipulation while allowing Chainlink downtime recovery
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80, int256 chainlinkPrice, uint256, uint256 chainlinkUpdatedAt, uint80
        ) {
            // Only check deviation if Chainlink data is recent (within 2 hours)
            if (block.timestamp - chainlinkUpdatedAt < 2 hours) {
                int256 deviation = price > chainlinkPrice 
                    ? (price - chainlinkPrice) * 100 / chainlinkPrice
                    : (chainlinkPrice - price) * 100 / chainlinkPrice;
                
                // Revert if deviation exceeds 20%
                if (deviation > 20) revert OracleError();
            }
        } catch {
            // Chainlink down: DVT price accepted without deviation check
            // This is the primary use case for DVT price updates
        }
        
        // 5. Update cache
        cachedPrice = PriceCache({
            price: price,
            updatedAt: updatedAt,
            roundId: 0, // DVT doesn't have Chainlink RoundID
            decimals: 8 // DVT normalizes to 8 decimals
        });
        
        emit PriceUpdated(price, updatedAt);
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
        // casting to 'uint128' is safe because of the check above
        // forge-lint: disable-next-line(unsafe-typecast)
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
        // casting to 'uint128' is safe because of the check above
        // forge-lint: disable-next-line(unsafe-typecast)
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
        // casting to 'uint128' is safe because of the check above
        // forge-lint: disable-next-line(unsafe-typecast)
        operators[targetOperator].aPNTsBalance += uint128(amount);
        totalTrackedBalance += amount;
        
        emit OperatorDeposited(targetOperator, amount);
    }




    /**
     * @notice Withdraw aPNTs
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (operators[msg.sender].aPNTsBalance < amount) {
            revert InsufficientBalance(operators[msg.sender].aPNTsBalance, amount);
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
        
        emit ProtocolRevenueWithdrawn(to, amount);
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

        // ✅ Store proof hash for audit traceability (永久存储在event中)
        bytes32 proofHash = keccak256(proof);
        
        _slash(operator, level, penalty, "DVT BLS Slash", proof);
        
        // ✅ Emit event with proof hash (链上永久可查,DVT保留完整proof 30天供验证)
        emit SlashExecutedWithProof(operator, level, penalty, proofHash, block.timestamp);
    }

    function _slash(address operator, ISuperPaymaster.SlashLevel level, uint256 penaltyAmount, string memory reason, bytes memory proof) internal {
        ISuperPaymaster.OperatorConfig storage config = operators[operator];
        
        uint256 reputationLoss = level == ISuperPaymaster.SlashLevel.WARNING ? 10 : (level == ISuperPaymaster.SlashLevel.MINOR ? 20 : 50);
        if (level == ISuperPaymaster.SlashLevel.MAJOR) config.isPaused = true;
        
        if (config.isPaused) {
             emit OperatorPaused(operator);
        }

        if (config.reputation > reputationLoss) config.reputation -= uint32(reputationLoss);
        else config.reputation = 0;

        if (penaltyAmount > 0) {
            // V3.6 SECURITY: Enforce 30% Slash Hardcap
            uint256 maxSlash = (uint256(config.aPNTsBalance) * 3000) / BPS_DENOMINATOR;
            if (penaltyAmount > maxSlash) {
                penaltyAmount = maxSlash;
                reason = string(abi.encodePacked(reason, " (Capped at 30%)"));
            }
            
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
        address oldAggregator = BLS_AGGREGATOR;
        BLS_AGGREGATOR = _bls;
        emit BLSAggregatorUpdated(oldAggregator, _bls);
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
        // 1. Try to get Price from Chainlink with automatic degradation
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            // Chainlink success: validate and update
            if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();
            if (updatedAt < block.timestamp - priceStalenessThreshold) revert OracleError();

            // 2. Update Cache
            cachedPrice = PriceCache({
                price: price,
                updatedAt: updatedAt,
                roundId: roundId,
                decimals: ETH_USD_PRICE_FEED.decimals()
            });
            
            emit PriceUpdated(price, updatedAt);
        } catch {
            // Chainlink down: revert to signal need for DVT fallback
            // Keeper should call updatePriceDVT() with BLS proof
            revert OracleError();
        }
    }
    function _calculateAPNTsAmount(uint256 ethAmountWei, bool useRealtime) internal view returns (uint256) {
        int256 ethUsdPrice;
        uint256 priceDecimals;

        // Mode 1: PostOp (Realtime Attempt)
        if (useRealtime) {
            try ETH_USD_PRICE_FEED.latestRoundData() returns (uint80, int256 p, uint256, uint256, uint80) {
                // Only use if positive and valid
                if (p > 0) {
                    ethUsdPrice = p;
                    priceDecimals = ETH_USD_PRICE_FEED.decimals();
                }
            } catch {
                // If Oracle fails, fall back to cache below
            }
        }

        // Mode 2: Validation or Fallback (Cache)
        if (ethUsdPrice <= 0) {
            PriceCache memory cache = cachedPrice;
            ethUsdPrice = cache.price;
            priceDecimals = cache.decimals;
        }
        
        // Safety check for both modes
        if (ethUsdPrice <= 0) revert OracleError();
        
        // Value in USD = ethAmountWei * price / 10^decimals
        // aPNTs Amount = Value in USD / aPNTsPriceUSD
        
        // Calculation:
        // (ethAmount * price * 10^18) / (10^decimals * aPNTsPriceUSD)
        
        return Math.mulDiv(
            ethAmountWei * uint256(ethUsdPrice),
            1e18,
            (10**priceDecimals) * aPNTsPriceUSD
        );
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

        // V3.3 Security: Check SBT Qualification (Local Cache)
        if (!sbtHolders[userOp.sender]) {
             return ("", _packValidationData(true, 0, 0));
        }

        // V3.2 Security: Check Blocklist & Rate Limit
        // CONSOLIDATED SLOAD: Get user state (Block status + Timestamp)
        UserOperatorState memory userState = userOpState[operator][userOp.sender];
        
        if (userState.isBlocked) {
             return ("", _packValidationData(true, 0, 0));
        }

        // V3.4: Rate Limiting (Using same SLOAD data)
        // config is already declared above
        if (config.minTxInterval > 0) {
            uint48 lastTime = userState.lastTimestamp;
            // Allow if first tx (0) or interval passed
            // Note: validAfter/validUntil handled by bundler, we enforce interval here
            if (lastTime != 0 && block.timestamp != lastTime && uint48(block.timestamp) < lastTime + config.minTxInterval) {
                 return ("", _packValidationData(true, 0, 0));
            }
            
            // OPTIMIZATION: Update state in PLACE (Saves gas by reusing the loaded slot context? No, requires storage write)
            // But we already loaded userState. We need to write back.
            // Be careful: userState is 'memory'. We need storage pointer to write.
            userOpState[operator][userOp.sender].lastTimestamp = uint48(block.timestamp);
        }

        // 2.1 Validate Rate Commitment (Rug Pull Protection)
        // paymasterAndData: [paymaster(20)] [gasLimits(32)] [operator(20)] [maxRate(32)]
        uint256 maxRate = type(uint256).max;
        if (userOp.paymasterAndData.length >= 104) {
             maxRate = abi.decode(userOp.paymasterAndData[RATE_OFFSET:RATE_OFFSET+32], (uint256));
        }
        
        // Cast uint96 to uint256 for comparison
        if (uint256(config.exchangeRate) > maxRate) {
             return ("", _packValidationData(true, 0, 0)); 
        }
        // Use CACHED price for validation (fast, compliant)
        // V3.5 FIX: Add Protocol Fee + Safety Buffer (1.1x + Fee) to prevent PostOp insolvency
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost, false);
        uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS + VALIDATION_BUFFER_BPS;
        aPNTsAmount = Math.mulDiv(aPNTsAmount, totalRate, BPS_DENOMINATOR);



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
        // Defense: If postOp previously failed, validation already charged - avoid double charging
        if (mode == PostOpMode.postOpReverted) return;
        
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
        // Optimization: "Cache-First, Passive Fallback" Strategy
        // Default to reading cache (Gas efficient)
        bool useRealtime = false;
        
        // If Cache is stale (e.g. > 1 hour), attempt to refresh it
        if (block.timestamp - cachedPrice.updatedAt > priceStalenessThreshold) {
            // Passive Update: Paymaster pays for this Oracle call
            try this.updatePrice() {
                // Success: Cache is updated. Keep useRealtime = false to read from fresh cache (Cheaper SLOAD)
            } catch {
                // Fail: Update failed. Force realtime read to ensure accuracy (Fallback to expensive STATICCALL)
                useRealtime = true;
                emit OracleFallbackTriggered(block.timestamp);
            }
        }

        // actualGasCost is in Wei.
        // If useRealtime=false: Reads storage (Cheap)
        // If useRealtime=true: Calls Oracle (Expensive, but necessary occasionally)
        uint256 actualAPNTsCost = _calculateAPNTsAmount(actualGasCost, useRealtime);

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
            if (refund > protocolRevenue) refund = protocolRevenue; // Safety check
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
             // FIX: Ensure consistent debt recording even if we charge the Max
             uint256 exchangeRate = operators[operator].exchangeRate;
             // Here finalCharge = initialAPNTs (since we capped it implicitly by not refunding)
             // But let's be explicit:
             uint256 finalXPNTsDebt = (initialAPNTs * exchangeRate) / 1e18;
             
             IxPNTsToken(token).recordDebt(user, finalXPNTsDebt);
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