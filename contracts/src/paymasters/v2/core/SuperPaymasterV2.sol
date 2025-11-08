// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title SuperPaymasterV2
 * @notice Multi-operator Paymaster with reputation system and DVT-based slash mechanism
 * @dev Implements ERC-4337 IPaymaster interface with enhanced features:
 *      - Multi-account management (multiple operators in single contract)
 *      - Fibonacci reputation levels (1-144 GT)
 *      - DVT + BLS slash execution
 *      - SBT-based user verification
 *      - xPNTs → aPNTs balance management
 *
 * Architecture:
 * - Registry: Stores community metadata
 * - SuperPaymaster: Manages operator accounts and execution
 * - GTokenStaking: Handles stake and slash
 * - DVT/BLS: Distributed monitoring and slash consensus
 */
contract SuperPaymasterV2 is Ownable, ReentrancyGuard, IPaymaster {
    using SafeERC20 for IERC20;

    // ====================================
    // Structs
    // ====================================

    struct OperatorAccount {
        // Staking info
        uint256 stGTokenLocked;      // Locked stGToken amount
        uint256 stakedAt;           // Stake timestamp

        // Operating balance
        uint256 aPNTsBalance;       // Current aPNTs balance
        uint256 totalSpent;         // Total spent
        uint256 lastRefillTime;     // Last refill timestamp
        uint256 minBalanceThreshold;// Min balance threshold (default 100 aPNTs)

        // Community config
        address[] supportedSBTs;    // Supported SBT contracts
        address xPNTsToken;         // Community points token
        address treasury;           // Treasury address for receiving user xPNTs

        // Pricing config (借鉴PaymasterV4)
        uint256 exchangeRate;       // xPNTs <-> aPNTs exchange rate (18 decimals, default 1e18 = 1:1)

        // Reputation system
        uint256 reputationScore;    // Reputation score (Fibonacci level)
        uint256 consecutiveDays;    // Consecutive operating days
        uint256 totalTxSponsored;   // Total transactions sponsored
        uint256 reputationLevel;    // Current level (1-12)

        // Monitoring status
        uint256 lastCheckTime;      // Last check timestamp
        bool isPaused;              // Paused status
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

    /// @notice GTokenStaking contract
    address public immutable GTOKEN_STAKING;

    /// @notice Registry contract
    address public immutable REGISTRY;

    /// @notice Chainlink ETH/USD price feed (immutable)
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    /// @notice DVT Aggregator contract
    address public DVT_AGGREGATOR;

    /// @notice EntryPoint contract (ERC-4337)
    address public ENTRY_POINT;

    /// @notice Minimum stake for operator registration (configurable)
    uint256 public minOperatorStake = 30 ether;

    /// @notice Minimum aPNTs balance threshold (configurable)
    uint256 public minAPNTsBalance = 100 ether;

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
    string public constant VERSION = "2.0.1"; // Oracle security fix (answeredInRound validation)

    /// @notice Contract version code (major * 10000 + medium * 100 + minor)
    uint256 public constant VERSION_CODE = 20001;

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

    event OperatorRegistered(
        address indexed operator,
        uint256 stakedAmount,
        uint256 timestamp
    );

    event TreasuryUpdated(
        address indexed operator,
        address indexed newTreasury
    );

    event ExchangeRateUpdated(
        address indexed operator,
        uint256 newRate
    );

    event aPNTsDeposited(
        address indexed operator,
        uint256 amount,
        uint256 timestamp
    );

    event TransactionSponsored(
        address indexed operator,
        address indexed user,
        uint256 aPNTsCost,
        uint256 xPNTsCost,
        uint256 timestamp
    );

    event OperatorSlashed(
        address indexed operator,
        uint256 amount,
        SlashLevel level,
        uint256 timestamp
    );

    event ReputationUpdated(
        address indexed operator,
        uint256 newScore,
        uint256 newLevel
    );

    event OperatorPaused(
        address indexed operator,
        uint256 timestamp
    );

    event OperatorUnpaused(
        address indexed operator,
        uint256 timestamp
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

    event TreasuryWithdrawal(
        address indexed treasury,
        uint256 amount,
        uint256 timestamp
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
    error InvalidAddress(address addr);
    error InvalidAmount(uint256 amount);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize SuperPaymasterV2
     * @param _gtokenStaking GTokenStaking contract address
     * @param _registry Registry contract address
     * @param _ethUsdPriceFeed Chainlink ETH/USD price feed address
     */
    constructor(
        address _gtokenStaking,
        address _registry,
        address _ethUsdPriceFeed
    ) Ownable(msg.sender) {
        if (_gtokenStaking == address(0) || _registry == address(0) || _ethUsdPriceFeed == address(0)) {
            revert InvalidAddress(address(0));
        }

        GTOKEN_STAKING = _gtokenStaking;
        REGISTRY = _registry;
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        superPaymasterTreasury = msg.sender; // 默认设为deployer，可后续修改
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register new operator
     * @param stGTokenAmount Amount of stGToken to lock
     * @param supportedSBTs List of supported SBT contracts
     * @param xPNTsToken Community points token address
     */
    function registerOperator(
        uint256 stGTokenAmount,
        address[] memory supportedSBTs,
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
            supportedSBTs: supportedSBTs,
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

        emit OperatorRegistered(msg.sender, stGTokenAmount, block.timestamp);
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

        emit aPNTsDeposited(msg.sender, amount, block.timestamp);
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
     * @notice Validate paymaster user operation (ERC-4337)
     * @dev PaymasterV4模式：基于maxCost直接收费，含2% markup，不退款
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
    ) external returns (bytes memory context, uint256 validationData) {
        require(msg.sender == ENTRY_POINT, "Only EntryPoint");

        // Extract operator from paymasterAndData
        address operator = _extractOperator(userOp);
        address user = userOp.sender;

        // Validations
        if (accounts[operator].isPaused) {
            revert OperatorIsPaused(operator);
        }

        if (!_hasSBT(user, accounts[operator].supportedSBTs)) {
            revert NoSBTFound(user);
        }

        // 基于maxCost计算aPNTs费用（含2% service fee）
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);

        // 检查operator的aPNTs余额
        if (accounts[operator].aPNTsBalance < aPNTsAmount) {
            revert InsufficientAPNTs(aPNTsAmount, accounts[operator].aPNTsBalance);
        }

        // 计算用户需要支付的xPNTs数量（根据operator的exchangeRate）
        uint256 xPNTsAmount = _calculateXPNTsAmount(operator, aPNTsAmount);

        // 获取配置
        address xPNTsToken = accounts[operator].xPNTsToken;
        address treasury = accounts[operator].treasury;

        if (xPNTsToken == address(0) || treasury == address(0)) {
            revert InvalidConfiguration();
        }

        // 1. 转账xPNTs从用户到operator的treasury（不退款）
        IERC20(xPNTsToken).transferFrom(user, treasury, xPNTsAmount);

        // 2. 内部记账：将aPNTs从operator余额转到treasury余额
        accounts[operator].aPNTsBalance -= aPNTsAmount;
        treasuryAPNTsBalance += aPNTsAmount;

        // 3. 更新operator统计
        accounts[operator].totalSpent += aPNTsAmount;
        accounts[operator].totalTxSponsored += 1;

        // 4. Emit event
        emit TransactionSponsored(operator, user, aPNTsAmount, xPNTsAmount, block.timestamp);

        // 5. Update reputation
        _updateReputation(operator);

        // 返回空context（不使用postOp退款）
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
    ) external {
        require(msg.sender == ENTRY_POINT, "Only EntryPoint");

        // 空实现：所有收费已在validatePaymasterUserOp中完成
        // 不退款，2% markup作为协议收入
    }

    /**
     * @notice Execute slash with BLS proof (only DVT Aggregator)
     * @param operator Operator to slash
     * @param level Slash level
     * @param proof BLS aggregated proof
     */
    function executeSlashWithBLS(
        address operator,
        SlashLevel level,
        bytes memory proof
    ) external nonReentrant {
        if (msg.sender != DVT_AGGREGATOR) {
            revert UnauthorizedCaller(msg.sender);
        }

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
            emit OperatorPaused(operator, block.timestamp);
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

        emit OperatorSlashed(operator, slashAmount, level, block.timestamp);
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
     * @notice Check if user has SBT
     * @param user User address
     * @param sbts List of SBT contracts
     * @return hasSBT True if user has any SBT
     */
    function _hasSBT(address user, address[] memory sbts) internal view returns (bool hasSBT) {
        for (uint i = 0; i < sbts.length; i++) {
            if (IERC721(sbts[i]).balanceOf(user) > 0) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Calculate aPNTs amount needed (使用 Chainlink 价格预言机)
     * @param gasCostWei Gas cost in wei
     * @return aPNTsAmount Required aPNTs amount
     */
    function _calculateAPNTsAmount(uint256 gasCostWei) internal view returns (uint256) {
        // Step 1: Get ETH/USD price from Chainlink with comprehensive validation
        (
            uint80 roundId,
            int256 ethUsdPrice,
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
        if (ethUsdPrice <= 0 || ethUsdPrice < MIN_ETH_USD_PRICE || ethUsdPrice > MAX_ETH_USD_PRICE) {
            revert InvalidConfiguration(); // Price out of reasonable range
        }

        uint8 decimals = ethUsdPriceFeed.decimals();

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

        emit TreasuryWithdrawal(superPaymasterTreasury, amount, block.timestamp);
    }

    /**
     * @notice Set EntryPoint address
     * @param _entryPoint EntryPoint address
     */
    function setEntryPoint(address _entryPoint) external onlyOwner {
        if (_entryPoint == address(0)) {
            revert InvalidAddress(_entryPoint);
        }
        ENTRY_POINT = _entryPoint;
    }

    /**
     * @notice Unpause operator (emergency)
     * @param operator Operator address
     */
    function unpauseOperator(address operator) external onlyOwner {
        accounts[operator].isPaused = false;
        emit OperatorUnpaused(operator, block.timestamp);
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
