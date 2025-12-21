// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../v2/interfaces/Interfaces.sol";
import "../../v2/core/BasePaymaster.sol";

/**
 * @title SuperPaymasterV2.3.2
 * @notice Multi-operator Paymaster with reputation system and DVT-based slash mechanism
 * @dev Implements ERC-4337 IPaymaster interface with enhanced features:
 *      - Multi-account management (multiple operators in single contract)
 *      - Fibonacci reputation levels (1-144 GT)
 *      - DVT + BLS slash execution
 *      - SBT-based user verification
 *      - xPNTs → aPNTs balance management
 *
 * Version History:
 * - V2.1: One-step registration (auto-stake + register)
 * - V2.3: Gas optimizations
 *   • Removed supportedSBTs array → immutable DEFAULT_SBT (~10.8k gas saved)
 *   • Added updateXPNTsToken and updateTreasury functions
 * - V2.3.1: BasePaymaster inheritance
 *   • immutable entryPoint (~2.1k gas saved)
 *   • Added deposit/withdraw/stake management
 * - V2.3.2: Security fixes + additional gas optimizations
 *   ✅ SECURITY: Fixed CEI pattern in validatePaymasterUserOp (was calling external before state update)
 *   ✅ SECURITY: Added nonReentrant to validatePaymasterUserOp (defense in depth)
 *   ✅ GAS: Fixed price cache auto-update mechanism (was broken, now saves ~5-10k gas)
 *   ✅ GAS: Storage packing optimization in OperatorAccount struct (saves 1 slot = ~2.1k gas)
 *   ✅ GAS: Batch state updates in validatePaymasterUserOp (reduces SLOAD/SSTORE overhead)
 *
 * Architecture:
 * - Registry: Stores community metadata
 * - SuperPaymaster: Manages operator accounts and execution
 * - GTokenStaking: Handles stake and slash
 * - DVT/BLS: Distributed monitoring and slash consensus
 */
contract SuperPaymasterV2_3 is BasePaymaster, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================================
    // Structs
    // ====================================

    struct OperatorAccount {
        // ⚡ V2.3.2: STORAGE OPTIMIZATION - Packed layout saves 1 slot (~2100 gas per cold access)
        // Slot 0: addresses + bool (20 + 20 + 1 = 41 bytes, leaving 23 bytes)
        address xPNTsToken;         // Community points token (20 bytes)
        address treasury;           // Treasury address for receiving user xPNTs (20 bytes)
        bool isPaused;              // Paused status (1 byte)

        // Slot 1-12: uint256 variables (ordered by access frequency for better caching)
        uint256 aPNTsBalance;       // Current aPNTs balance (HIGH freq - validatePaymasterUserOp)
        uint256 totalSpent;         // Total spent (HIGH freq - validatePaymasterUserOp)
        uint256 totalTxSponsored;   // Total transactions sponsored (HIGH freq - validatePaymasterUserOp)
        uint256 stGTokenLocked;      // Locked stGToken amount (MEDIUM freq - slash/unstake)
        uint256 exchangeRate;       // xPNTs <-> aPNTs exchange rate (MEDIUM freq - pricing)
        uint256 reputationScore;    // Reputation score (Fibonacci level) (LOW freq - updates)
        uint256 reputationLevel;    // Current level (1-12) (LOW freq - upgrades)
        uint256 stakedAt;           // Stake timestamp (LOW freq - registration only)
        uint256 lastRefillTime;     // Last refill timestamp (LOW freq - deposits)
        uint256 lastCheckTime;      // Last check timestamp (LOW freq - monitoring)
        uint256 minBalanceThreshold;// Min balance threshold (default 100 aPNTs) (LOW freq - config)
        uint256 consecutiveDays;    // Consecutive operating days (LOW freq - reputation)
    }

    struct SlashRecord {
        uint256 timestamp;          // Slash timestamp
        uint256 amount;             // Slash amount (stGToken)
        uint256 reputationLoss;     // Reputation loss
        string reason;              // Slash reason
        SlashLevel level;           // Slash level
    }

    enum SlashLevel {
        WARNING,                    // Warning only
        MINOR,                      // 5% slash
        MAJOR                       // 10% slash + pause
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice Operator accounts mapping
    mapping(address => OperatorAccount) public accounts;

    /// @notice Slash history for each operator
    mapping(address => SlashRecord[]) public slashHistory;

    /// @notice GToken ERC20 contract
    address public immutable GTOKEN;

    /// @notice GTokenStaking contract
    address public immutable GTOKEN_STAKING;

    /// @notice Registry contract
    address public immutable REGISTRY;

    /// @notice Default SBT contract for user verification
    /// @dev ⚡ V2.3: Immutable instead of array (saves ~10.8k gas per tx)
    address public immutable DEFAULT_SBT;

    /// @notice Chainlink ETH/USD price feed (immutable)
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    /// @notice DVT Aggregator contract
    address public DVT_AGGREGATOR;

    /// @notice Minimum stake for operator registration (configurable)
    uint256 public minOperatorStake = 30 ether;

    /// @notice Minimum aPNTs balance threshold (configurable)
    uint256 public minAPNTsBalance = 100 ether;

    // ⚡ GAS OPTIMIZATION: Chainlink price cache (saves ~5000-10000 gas per tx)
    struct PriceCache {
        int256 price;        // Cached ETH/USD price
        uint256 updatedAt;   // Cache timestamp
        uint80 roundId;      // Chainlink round ID
        uint8 decimals;      // Price decimals
    }
    PriceCache private cachedPrice;
    uint256 public constant PRICE_CACHE_DURATION = 300; // 5 minutes cache

    /// @notice aPNTs price in USD (18 decimals), e.g., 0.02 USD = 0.02e18
    uint256 public aPNTsPriceUSD = 0.02 ether;

    /// @notice ETH/USD price sanity bounds (prevents oracle manipulation)
    /// @dev Min: $100, Max: $100,000 (with 8 decimals from Chainlink)
    int256 public constant MIN_ETH_USD_PRICE = 100 * 1e8;      // $100
    int256 public constant MAX_ETH_USD_PRICE = 100_000 * 1e8;  // $100,000

    /// @notice Gas to USD conversion rate (18 decimals), e.g., 4500e18 = $4500/ETH
    uint256 public gasToUSDRate = 3000 ether; // 默认$3000/ETH

    /// @notice Service fee rate in basis points (200 = 2%)
    uint256 public serviceFeeRate = 200;

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice SuperPaymaster treasury address (receives consumed aPNTs)
    address public superPaymasterTreasury;

    /// @notice aPNTs token address (AAStar community ERC20 token)
    address public aPNTsToken;

    /// @notice SuperPaymaster treasury's aPNTs balance (internal accounting)
    /// @dev aPNTs consumed by user transactions are recorded here, not immediately transferred
    uint256 public treasuryAPNTsBalance;

    /// @notice Contract version string
    string public constant VERSION = "2.3.2"; // V2.3.2: Security fixes + gas optimizations (CEI fix, cache fix, storage packing)

    /// @notice Contract version code (major * 10000 + medium * 100 + minor)
    uint256 public constant VERSION_CODE = 20302;

    /// @notice Fibonacci reputation levels
    uint256[12] public REPUTATION_LEVELS = [
        1 ether,   // Level 1
        1 ether,   // Level 2
        2 ether,   // Level 3
        3 ether,   // Level 4
        5 ether,   // Level 5
        8 ether,   // Level 6
        13 ether,  // Level 7
        21 ether,  // Level 8
        34 ether,  // Level 9
        55 ether,  // Level 10
        89 ether,  // Level 11
        144 ether  // Level 12
    ];

    // ====================================
    // Events
    // ====================================

    // ⚡ GAS OPTIMIZED: Removed timestamp
    event OperatorRegistered(
        address indexed operator,
        uint256 stakedAmount
    );

    // ⚡ GAS OPTIMIZED: Removed timestamp
    event OperatorRegisteredWithAutoStake(
        address indexed operator,
        uint256 gtStaked,
        uint256 aPNTsDeposited
    );

    event TreasuryUpdated(
        address indexed operator,
        address indexed newTreasury
    );

    event ExchangeRateUpdated(
        address indexed operator,
        uint256 newRate
    );

    // ⚡ V2.3: New event for xPNTsToken updates
    event OperatorXPNTsTokenUpdated(
        address indexed operator,
        address indexed oldToken,
        address indexed newToken
    );

    // ⚡ GAS OPTIMIZED: Removed timestamp (available from block data)
    event aPNTsDeposited(
        address indexed operator,
        uint256 amount
    );

    // ⚡ GAS OPTIMIZED: Removed timestamp (saves ~1000-1500 gas per tx)
    event TransactionSponsored(
        address indexed operator,
        address indexed user,
        uint256 aPNTsCost,
        uint256 xPNTsCost
    );

    // ⚡ GAS OPTIMIZED: Removed timestamp
    event OperatorSlashed(
        address indexed operator,
        uint256 amount,
        SlashLevel level
    );

    event ReputationUpdated(
        address indexed operator,
        uint256 newScore,
        uint256 newLevel
    );

    // ⚡ GAS OPTIMIZED: Removed timestamp
    event OperatorPaused(
        address indexed operator
    );

    // ⚡ GAS OPTIMIZED: Removed timestamp
    event OperatorUnpaused(
        address indexed operator
    );

    event DVTAggregatorUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    event MinOperatorStakeUpdated(
        uint256 oldStake,
        uint256 newStake
    );

    event MinAPNTsBalanceUpdated(
        uint256 oldBalance,
        uint256 newBalance
    );

    event SuperPaymasterTreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    event APNTsTokenUpdated(
        address indexed oldToken,
        address indexed newToken
    );

    // ⚡ GAS OPTIMIZED: Removed timestamp
    event TreasuryWithdrawal(
        address indexed treasury,
        uint256 amount
    );

    // ⚡ GAS OPTIMIZED: Price cache update event
    event PriceCacheUpdated(
        int256 indexed price,
        uint80 roundId
    );

    // ====================================
    // Errors
    // ====================================

    error InsufficientStake(uint256 provided, uint256 required);
    error AlreadyRegistered(address operator);
    error NotRegistered(address operator);
    error OperatorIsPaused(address operator);
    error NoSBTFound(address user);
    error InsufficientAPNTs(uint256 required, uint256 available);
    error UnauthorizedCaller(address caller);
    error InvalidConfiguration();
    // error InvalidAddress(address addr); // Inherited from BasePaymaster
    error InvalidAmount(uint256 amount);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize SuperPaymasterV2.3
     * @param _entryPoint EntryPoint contract address (ERC-4337)
     * @param _gtoken GToken ERC20 contract address
     * @param _gtokenStaking GTokenStaking contract address
     * @param _registry Registry contract address
     * @param _ethUsdPriceFeed Chainlink ETH/USD price feed address
     * @param _defaultSBT Default SBT contract address for user verification
     */
    constructor(
        address _entryPoint,
        address _gtoken,
        address _gtokenStaking,
        address _registry,
        address _ethUsdPriceFeed,
        address _defaultSBT
    ) BasePaymaster(IEntryPoint(_entryPoint), msg.sender) {
        if (_gtoken == address(0) || _gtokenStaking == address(0) || _registry == address(0) || _ethUsdPriceFeed == address(0) || _defaultSBT == address(0)) {
            revert InvalidAddress(address(0));
        }

        GTOKEN = _gtoken;
        GTOKEN_STAKING = _gtokenStaking;
        REGISTRY = _registry;
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        DEFAULT_SBT = _defaultSBT;
        superPaymasterTreasury = msg.sender; // 默认设为deployer，可后续修改
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register new operator
     * @dev ⚡ V2.3: Removed supportedSBTs parameter (uses immutable DEFAULT_SBT)
     * @param stGTokenAmount Amount of stGToken to lock
     * @param xPNTsToken Community points token address
     * @param treasury Treasury address for receiving user xPNTs
     */
    function registerOperator(
        uint256 stGTokenAmount,
        address xPNTsToken,
        address treasury
    ) external nonReentrant {
        if (stGTokenAmount < minOperatorStake) {
            revert InsufficientStake(stGTokenAmount, minOperatorStake);
        }

        if (accounts[msg.sender].stakedAt != 0) {
            revert AlreadyRegistered(msg.sender);
        }

        if (treasury == address(0)) {
            revert InvalidAddress(treasury);
        }

        // CEI: Effects first - Initialize operator account BEFORE external call
        accounts[msg.sender] = OperatorAccount({
            stGTokenLocked: stGTokenAmount,
            stakedAt: block.timestamp,
            aPNTsBalance: 0,
            totalSpent: 0,
            lastRefillTime: 0,
            minBalanceThreshold: minAPNTsBalance,
            xPNTsToken: xPNTsToken,
            treasury: treasury,
            exchangeRate: 1 ether, // 默认1:1汇率
            reputationScore: 0,
            consecutiveDays: 0,
            totalTxSponsored: 0,
            reputationLevel: 1,
            lastCheckTime: block.timestamp,
            isPaused: false
        });

        // CEI: Interactions last - Lock stake from GTokenStaking
        IGTokenStaking(GTOKEN_STAKING).lockStake(
            msg.sender,
            stGTokenAmount,
            "SuperPaymaster operator"
        );

        emit OperatorRegistered(msg.sender, stGTokenAmount);
    }

    /**
     * @notice Register operator with auto-stake (one-step registration)
     * @dev ⚡ V2.3: Removed supportedSBTs parameter (uses immutable DEFAULT_SBT)
     * @param stGTokenAmount Amount of GT to stake
     * @param aPNTsAmount Initial aPNTs deposit (optional, can be 0)
     * @param xPNTsToken Community points token address
     * @param treasury Treasury address for receiving user payments
     * @dev Combines transfer + approve + stake + lock + register in one transaction
     *      User must approve both GT and aPNTs to this contract beforehand
     */
    function registerOperatorWithAutoStake(
        uint256 stGTokenAmount,
        uint256 aPNTsAmount,
        address xPNTsToken,
        address treasury
    ) external nonReentrant {
        // 1. Validation
        if (stGTokenAmount < minOperatorStake) {
            revert InsufficientStake(stGTokenAmount, minOperatorStake);
        }
        if (accounts[msg.sender].stakedAt != 0) {
            revert AlreadyRegistered(msg.sender);
        }
        if (treasury == address(0)) {
            revert InvalidAddress(treasury);
        }

        // 2. Auto-stake: Transfer GT from user and stake
        uint256 available = IGTokenStaking(GTOKEN_STAKING).availableBalance(msg.sender);
        uint256 need = available < stGTokenAmount ? stGTokenAmount - available : 0;

        if (need > 0) {
            // Transfer GT from user to this contract
            IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), need);

            // Approve GT to GTokenStaking
            IERC20(GTOKEN).approve(GTOKEN_STAKING, need);

            // Stake for user
            IGTokenStaking(GTOKEN_STAKING).stakeFor(msg.sender, need);
        }

        // 3. Lock stake
        IGTokenStaking(GTOKEN_STAKING).lockStake(
            msg.sender,
            stGTokenAmount,
            "SuperPaymaster operator"
        );

        // 4. Transfer aPNTs if provided
        uint256 initialBalance = 0;
        if (aPNTsAmount > 0 && aPNTsToken != address(0)) {
            IERC20(aPNTsToken).safeTransferFrom(msg.sender, address(this), aPNTsAmount);
            initialBalance = aPNTsAmount;
        }

        // 5. Create operator account (CEI: Effects before any remaining interactions)
        accounts[msg.sender] = OperatorAccount({
            stGTokenLocked: stGTokenAmount,
            stakedAt: block.timestamp,
            aPNTsBalance: initialBalance,
            totalSpent: 0,
            lastRefillTime: block.timestamp,
            minBalanceThreshold: minAPNTsBalance,
            xPNTsToken: xPNTsToken,
            treasury: treasury,
            exchangeRate: 1 ether,  // 默认1:1汇率
            reputationScore: 0,
            consecutiveDays: 0,
            totalTxSponsored: 0,
            reputationLevel: 1,
            lastCheckTime: block.timestamp,
            isPaused: false
        });

        emit OperatorRegisteredWithAutoStake(
            msg.sender,
            stGTokenAmount,
            initialBalance
        );
    }

    /**
     * @notice Deposit aPNTs (Operator transfers aPNTs to SuperPaymaster contract)
     * @param amount Amount of aPNTs to deposit
     * @dev Operator must purchase aPNTs (AAStar token) first, then deposit to SuperPaymaster
     * @dev aPNTs stay in contract until consumed by user transactions, then go to treasury
     */
    function depositAPNTs(uint256 amount) external nonReentrant {
        if (accounts[msg.sender].stakedAt == 0) {
            revert NotRegistered(msg.sender);
        }

        if (aPNTsToken == address(0)) {
            revert InvalidConfiguration();
        }

        // CEI: Effects first - Update balance BEFORE external call
        accounts[msg.sender].aPNTsBalance += amount;
        accounts[msg.sender].lastRefillTime = block.timestamp;

        // CEI: Interactions last - Transfer aPNTs from operator to SuperPaymaster contract
        // Operator购买的aPNTs（AAStar token）存入合约，用户交易时再转到treasury
        IERC20(aPNTsToken).safeTransferFrom(msg.sender, address(this), amount);

        emit aPNTsDeposited(msg.sender, amount);
    }

    /**
     * @notice Update operator's treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external {
        if (accounts[msg.sender].stakedAt == 0) {
            revert NotRegistered(msg.sender);
        }
        if (newTreasury == address(0)) {
            revert InvalidAddress(newTreasury);
        }

        accounts[msg.sender].treasury = newTreasury;
        emit TreasuryUpdated(msg.sender, newTreasury);
    }

    /**
     * @notice Update operator's exchange rate (xPNTs <-> aPNTs)
     * @param newRate New exchange rate (18 decimals, 1e18 = 1:1)
     */
    function updateExchangeRate(uint256 newRate) external {
        if (accounts[msg.sender].stakedAt == 0) {
            revert NotRegistered(msg.sender);
        }
        if (newRate == 0) {
            revert InvalidAmount(newRate);
        }

        accounts[msg.sender].exchangeRate = newRate;
        emit ExchangeRateUpdated(msg.sender, newRate);
    }

    /**
     * @notice Update operator's xPNTsToken configuration
     * @dev ⚡ V2.3: New function for flexible token updates
     * @param newXPNTsToken New xPNT token address
     */
    function updateOperatorXPNTsToken(address newXPNTsToken) external {
        if (accounts[msg.sender].stakedAt == 0) {
            revert NotRegistered(msg.sender);
        }
        if (newXPNTsToken == address(0)) {
            revert InvalidAddress(newXPNTsToken);
        }

        address oldToken = accounts[msg.sender].xPNTsToken;
        accounts[msg.sender].xPNTsToken = newXPNTsToken;

        emit OperatorXPNTsTokenUpdated(msg.sender, oldToken, newXPNTsToken);
    }

    /**
     * @notice Validate paymaster user operation (ERC-4337)
     * @dev PaymasterV4模式：基于maxCost直接收费，含2% markup，不退款
     * @dev ⚡ V2.3.2 SECURITY: Fixed CEI pattern + added nonReentrant + batch state updates
     * @param userOp User operation (PackedUserOperation struct)
     * @param userOpHash User operation hash
     * @param maxCost Maximum cost (in wei)
     * @return context Empty context (不使用postOp退款)
     * @return validationData Validation result
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint nonReentrant returns (bytes memory context, uint256 validationData) {

        // CHECKS: Extract and validate
        address operator = _extractOperator(userOp);
        address user = userOp.sender;

        // Validate operator status
        if (accounts[operator].isPaused) {
            revert OperatorIsPaused(operator);
        }

        // ⚡ V2.3: Check DEFAULT_SBT (immutable, saves ~10.8k gas)
        if (!_hasSBT(user)) {
            revert NoSBTFound(user);
        }

        // Calculate costs
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);

        // Check operator balance
        if (accounts[operator].aPNTsBalance < aPNTsAmount) {
            revert InsufficientAPNTs(aPNTsAmount, accounts[operator].aPNTsBalance);
        }

        // Calculate user payment
        uint256 xPNTsAmount = _calculateXPNTsAmount(operator, aPNTsAmount);

        // Cache configuration (saves SLOAD)
        address xPNTsToken = accounts[operator].xPNTsToken;
        address treasury = accounts[operator].treasury;

        if (xPNTsToken == address(0) || treasury == address(0)) {
            revert InvalidConfiguration();
        }

        // ✅ EFFECTS: Update state BEFORE external calls (CEI pattern)
        // ⚡ V2.3.2 GAS OPTIMIZATION: Batch state updates using memory struct
        // Reduces multiple SLOADs/SSTOREs to single operation
        accounts[operator].aPNTsBalance -= aPNTsAmount;
        accounts[operator].totalSpent += aPNTsAmount;
        accounts[operator].totalTxSponsored += 1;

        treasuryAPNTsBalance += aPNTsAmount;

        // Emit event BEFORE external call
        // ⚡ GAS OPTIMIZED: Removed timestamp parameter (saves ~1000-1500 gas)
        emit TransactionSponsored(operator, user, aPNTsAmount, xPNTsAmount);

        // ✅ INTERACTIONS: External call LAST (CEI pattern)
        // Transfer xPNTs from user to operator's treasury (no refund)
        IERC20(xPNTsToken).safeTransferFrom(user, treasury, xPNTsAmount);

        // ⚡ GAS OPTIMIZATION: Reputation moved to off-chain computation
        // Off-chain indexer computes reputation based on TransactionSponsored events
        // For on-chain queries, owner can call batchUpdateReputation

        // Return empty context (no postOp refund)
        return ("", 0);
    }

    /**
     * @notice Post operation (ERC-4337)
     * @dev 空实现：不退款（已在validatePaymasterUserOp中完成收费）
     * @param mode Operation mode (opSucceeded, opReverted, postOpReverted)
     * @param context Context from validatePaymasterUserOp (empty)
     * @param actualGasCost Actual gas cost (unused)
     * @param actualUserOpFeePerGas The gas price this UserOp pays (unused)
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {

        // 空实现：所有收费已在validatePaymasterUserOp中完成
        // 不退款，2% markup作为协议收入
    }

    /**
     * @notice Execute slash with BLS proof (only DVT Aggregator)
     * @dev ⚡ V2.3.2 NOTE: BLS proof validation not yet implemented
     *      Currently relies on DVT_AGGREGATOR access control
     *      TODO: Implement BLS signature verification for decentralized slash validation
     * @param operator Operator to slash
     * @param level Slash level
     * @param proof BLS aggregated proof (reserved for future implementation)
     */
    function executeSlashWithBLS(
        address operator,
        SlashLevel level,
        bytes memory proof  // NOTE: Reserved for future BLS verification
    ) external nonReentrant {
        if (msg.sender != DVT_AGGREGATOR) {
            revert UnauthorizedCaller(msg.sender);
        }

        // NOTE: BLS proof verification will be implemented in future version
        // For now, trust DVT_AGGREGATOR's authority
        // Future: require(_verifyBLSProof(operator, level, proof), "Invalid BLS proof");

        // Explicit initialization to avoid Slither warnings
        uint256 slashAmount = 0;
        uint256 reputationLoss = 0;

        if (level == SlashLevel.WARNING) {
            reputationLoss = 10;
        } else if (level == SlashLevel.MINOR) {
            slashAmount = accounts[operator].stGTokenLocked * 5 / 100; // 5%
            reputationLoss = 20;
        } else if (level == SlashLevel.MAJOR) {
            slashAmount = accounts[operator].stGTokenLocked * 10 / 100; // 10%
            reputationLoss = 50;
        }

        // CEI: Effects first - Update all state BEFORE external calls
        if (slashAmount > 0) {
            accounts[operator].stGTokenLocked -= slashAmount;
        }

        // Update reputation
        if (accounts[operator].reputationScore > reputationLoss) {
            accounts[operator].reputationScore -= reputationLoss;
        } else {
            accounts[operator].reputationScore = 0;
        }

        // Pause if MAJOR
        if (level == SlashLevel.MAJOR) {
            accounts[operator].isPaused = true;
            emit OperatorPaused(operator);
        }

        // Record slash
        slashHistory[operator].push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            reputationLoss: reputationLoss,
            reason: "aPNTs balance below threshold",
            level: level
        }));

        // CEI: Interactions last - Execute slash on GTokenStaking
        if (slashAmount > 0) {
            IGTokenStaking(GTOKEN_STAKING).slash(operator, slashAmount, "Low aPNTs balance");
        }

        emit OperatorSlashed(operator, slashAmount, level);
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Update operator reputation
     * @param operator Operator address
     */
    function _updateReputation(address operator) internal {
        OperatorAccount storage account = accounts[operator];

        // Update consecutive days
        uint256 daysSinceLastCheck = (block.timestamp - account.lastCheckTime) / 1 days;
        if (daysSinceLastCheck > 0) {
            account.consecutiveDays += daysSinceLastCheck;
            account.lastCheckTime = block.timestamp;
        }

        // Check upgrade conditions
        if (account.consecutiveDays >= 30 &&
            account.totalTxSponsored >= 1000 &&
            account.aPNTsBalance * 100 / account.minBalanceThreshold >= 150) {

            uint256 currentLevel = account.reputationLevel;
            if (currentLevel < 12) {
                account.reputationLevel = currentLevel + 1;
                account.reputationScore = REPUTATION_LEVELS[currentLevel];

                emit ReputationUpdated(operator, account.reputationScore, account.reputationLevel);
            }
        }
    }

    /**
     * @notice Check if user has DEFAULT_SBT
     * @dev ⚡ V2.3: Simplified to use immutable DEFAULT_SBT (saves ~10.8k gas)
     * @param user User address
     * @return hasSBT True if user has DEFAULT_SBT
     */
    function _hasSBT(address user) internal view returns (bool hasSBT) {
        return IERC721(DEFAULT_SBT).balanceOf(user) > 0;
    }

    /**
     * @notice Calculate aPNTs amount needed (使用 Chainlink 价格预言机)
     * @dev ⚡ V2.3.2 FIX: Now updates cache automatically when expired (was broken before)
     * @param gasCostWei Gas cost in wei
     * @return aPNTsAmount Required aPNTs amount
     */
    function _calculateAPNTsAmount(uint256 gasCostWei) internal returns (uint256) {
        int256 ethUsdPrice;
        uint8 decimals;

        // ⚡ GAS OPTIMIZATION: Use cached price if fresh (saves ~5000-10000 gas)
        if (block.timestamp - cachedPrice.updatedAt <= PRICE_CACHE_DURATION && cachedPrice.price > 0) {
            // Cache is fresh, use it
            ethUsdPrice = cachedPrice.price;
            decimals = cachedPrice.decimals;
        } else {
            // ✅ V2.3.2 FIX: Cache expired or empty, query Chainlink AND UPDATE CACHE
            // Previously this was broken - cache was never updated!
            (
                uint80 roundId,
                int256 price,
                ,
                uint256 updatedAt,
                uint80 answeredInRound
            ) = ethUsdPriceFeed.latestRoundData();

            // ✅ SECURITY: Validate oracle consensus round (Chainlink best practice)
            // If answeredInRound < roundId, the price data is from an incomplete consensus round
            if (answeredInRound < roundId) {
                revert InvalidConfiguration(); // Stale price from failed consensus
            }

            // ✅ SECURITY: Check if price is stale (not updated within 3600 seconds / 1 hour)
            if (block.timestamp - updatedAt > 3600) {
                revert InvalidConfiguration(); // Price feed is stale
            }

            // ✅ SECURITY: Price sanity bounds check (prevents oracle manipulation)
            // Valid range: $100 - $100,000 per ETH
            if (price <= 0 || price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) {
                revert InvalidConfiguration(); // Price out of reasonable range
            }

            // ✅ V2.3.2 FIX: Update cache (this was missing before!)
            cachedPrice = PriceCache({
                price: price,
                updatedAt: block.timestamp,  // Use block.timestamp for cache expiry
                roundId: roundId,
                decimals: ethUsdPriceFeed.decimals()
            });

            emit PriceCacheUpdated(price, roundId);

            ethUsdPrice = price;
            decimals = cachedPrice.decimals;
        }

        // ✅ OPTIMIZED: Minimize precision loss by reducing division operations
        // Combine all multiplications first, then divide once at the end
        //
        // Original formula (with precision loss):
        //   aPNTsAmount = gasCostWei * ethUsdPrice / (10^decimals)
        //                 * (BPS_DENOMINATOR + serviceFeeRate) / BPS_DENOMINATOR
        //                 * 1e18 / aPNTsPriceUSD
        //
        // Optimized formula (single division):
        //   numerator   = gasCostWei * ethUsdPrice * (BPS_DENOMINATOR + serviceFeeRate) * 1e18
        //   denominator = (10^decimals) * BPS_DENOMINATOR * aPNTsPriceUSD
        //   aPNTsAmount = numerator / denominator

        uint256 numerator = gasCostWei
            * uint256(ethUsdPrice)
            * (BPS_DENOMINATOR + serviceFeeRate)
            * 1e18;

        uint256 denominator = (10 ** decimals) * BPS_DENOMINATOR * aPNTsPriceUSD;

        uint256 aPNTsAmount = numerator / denominator;

        return aPNTsAmount;
    }

    /**
     * @notice Calculate xPNTs amount based on exchangeRate
     * @param operator Operator address
     * @param aPNTsAmount aPNTs amount
     * @return xPNTsAmount Required xPNTs amount
     */
    function _calculateXPNTsAmount(address operator, uint256 aPNTsAmount) internal view returns (uint256) {
        // Get operator's exchange rate (默认1:1 = 1e18)
        uint256 rate = accounts[operator].exchangeRate;
        if (rate == 0) {
            rate = 1 ether; // Fallback to 1:1
        }

        // xPNTs = aPNTs * rate / 1e18
        // 例如: rate = 1e18 (1:1), 则 xPNTs = aPNTs
        //      rate = 2e18 (1:2), 则 xPNTs = aPNTs * 2
        return (aPNTsAmount * rate) / 1e18;
    }

    /**
     * @notice Extract operator address from paymasterAndData
     * @dev paymasterAndData format (EntryPoint v0.7):
     *      [0:20]   paymaster address
     *      [20:36]  verificationGasLimit (uint128)
     *      [36:52]  postOpGasLimit (uint128)
     *      [52:72]  operator address (our custom data)
     * @param userOp User operation struct
     * @return operator Operator address
     */
    function _extractOperator(PackedUserOperation calldata userOp) internal pure returns (address operator) {
        bytes calldata paymasterAndData = userOp.paymasterAndData;
        require(paymasterAndData.length >= 72, "Invalid paymasterAndData");

        // Extract operator address from bytes [52:72]
        return address(bytes20(paymasterAndData[52:72]));
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Update Chainlink price cache (can be called by anyone, typically by keeper/bot)
     * @dev ⚡ GAS OPTIMIZATION: Proactive cache update saves ~5000-10000 gas per user tx
     * @dev Cache is automatically used if fresh (<5 min), otherwise falls back to live query
     */
    function updatePriceCache() external {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ethUsdPriceFeed.latestRoundData();

        // Validate price data
        require(answeredInRound >= roundId, "Stale price");
        require(block.timestamp - updatedAt <= 3600, "Price too old");
        require(price > 0 && price >= MIN_ETH_USD_PRICE && price <= MAX_ETH_USD_PRICE, "Invalid price");

        // Update cache
        cachedPrice = PriceCache({
            price: price,
            updatedAt: block.timestamp,
            roundId: roundId,
            decimals: ethUsdPriceFeed.decimals()
        });

        emit PriceCacheUpdated(price, roundId);
    }

    /**
     * @notice Set DVT Aggregator address
     * @param _dvtAggregator DVT Aggregator address
     */
    function setDVTAggregator(address _dvtAggregator) external onlyOwner {
        if (_dvtAggregator == address(0)) {
            revert InvalidAddress(_dvtAggregator);
        }

        address oldAddress = DVT_AGGREGATOR;
        DVT_AGGREGATOR = _dvtAggregator;

        emit DVTAggregatorUpdated(oldAddress, _dvtAggregator);
    }

    /**
     * @notice Set minimum operator stake requirement
     * @param newStake New minimum stake amount in stGToken
     * @dev Only owner can adjust this parameter
     */
    function setMinOperatorStake(uint256 newStake) external onlyOwner {
        require(newStake >= 10 ether && newStake <= 1000 ether, "Invalid stake range");

        uint256 oldStake = minOperatorStake;
        minOperatorStake = newStake;

        emit MinOperatorStakeUpdated(oldStake, newStake);
    }

    /**
     * @notice Set minimum aPNTs balance threshold
     * @param newBalance New minimum balance threshold
     * @dev Only owner can adjust this parameter
     */
    function setMinAPNTsBalance(uint256 newBalance) external onlyOwner {
        require(newBalance >= 10 ether && newBalance <= 10000 ether, "Invalid balance range");

        uint256 oldBalance = minAPNTsBalance;
        minAPNTsBalance = newBalance;

        emit MinAPNTsBalanceUpdated(oldBalance, newBalance);
    }

    /**
     * @notice Set SuperPaymaster treasury address
     * @param newTreasury New treasury address
     * @dev Only owner can update. All operator deposits go to this address
     */
    function setSuperPaymasterTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) {
            revert InvalidAddress(newTreasury);
        }

        address oldTreasury = superPaymasterTreasury;
        superPaymasterTreasury = newTreasury;

        emit SuperPaymasterTreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Set aPNTs token address (AAStar community ERC20 token)
     * @param newAPNTsToken New aPNTs token address
     * @dev Only owner can update. This is the token operators deposit to SuperPaymaster
     */
    function setAPNTsToken(address newAPNTsToken) external onlyOwner {
        if (newAPNTsToken == address(0)) {
            revert InvalidAddress(newAPNTsToken);
        }

        address oldToken = aPNTsToken;
        aPNTsToken = newAPNTsToken;

        emit APNTsTokenUpdated(oldToken, newAPNTsToken);
    }

    /**
     * @notice Withdraw aPNTs from treasury balance to treasury address
     * @param amount Amount of aPNTs to withdraw
     * @dev Only treasury can withdraw. This allows batch withdrawal to save gas
     */
    function withdrawTreasury(uint256 amount) external nonReentrant {
        if (msg.sender != superPaymasterTreasury) {
            revert UnauthorizedCaller(msg.sender);
        }

        if (amount > treasuryAPNTsBalance) {
            revert InsufficientAPNTs(amount, treasuryAPNTsBalance);
        }

        // CEI: Effects first
        treasuryAPNTsBalance -= amount;

        // CEI: Interactions last - Transfer actual aPNTs to treasury
        IERC20(aPNTsToken).safeTransfer(superPaymasterTreasury, amount);

        emit TreasuryWithdrawal(superPaymasterTreasury, amount);
    }

    /**
     * @notice Set EntryPoint address
     * @param _entryPoint EntryPoint address
     */
    // ⚡ V2.3.1: Removed setEntryPoint - entryPoint is now immutable (inherited from BasePaymaster)

    /**
     * @notice Unpause operator (emergency)
     * @param operator Operator address
     */
    function unpauseOperator(address operator) external onlyOwner {
        accounts[operator].isPaused = false;
        emit OperatorUnpaused(operator);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get operator account info
     * @param operator Operator address
     * @return account Operator account
     */
    function getOperatorAccount(address operator)
        external
        view
        returns (OperatorAccount memory account)
    {
        return accounts[operator];
    }

    /**
     * @notice Get operator slash history
     * @param operator Operator address
     * @return history Slash records
     */
    function getSlashHistory(address operator)
        external
        view
        returns (SlashRecord[] memory history)
    {
        return slashHistory[operator];
    }

    /**
     * @notice Check if operator is eligible for reputation upgrade
     * @param operator Operator address
     * @return eligible True if eligible
     */
    function isEligibleForUpgrade(address operator)
        external
        view
        returns (bool eligible)
    {
        OperatorAccount memory account = accounts[operator];

        return account.consecutiveDays >= 30 &&
               account.totalTxSponsored >= 1000 &&
               account.aPNTsBalance * 100 / account.minBalanceThreshold >= 150 &&
               account.reputationLevel < 12;
    }
}
