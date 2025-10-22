// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
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
contract SuperPaymasterV2 is Ownable {

    // ====================================
    // Structs
    // ====================================

    struct OperatorAccount {
        // Staking info
        uint256 sGTokenLocked;      // Locked sGToken amount
        uint256 stakedAt;           // Stake timestamp

        // Operating balance
        uint256 aPNTsBalance;       // Current aPNTs balance
        uint256 totalSpent;         // Total spent
        uint256 lastRefillTime;     // Last refill timestamp
        uint256 minBalanceThreshold;// Min balance threshold (default 100 aPNTs)

        // Community config
        address[] supportedSBTs;    // Supported SBT contracts
        address xPNTsToken;         // Community points token

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
        uint256 amount;             // Slash amount (sGToken)
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

    /// @notice DVT Aggregator contract
    address public DVT_AGGREGATOR;

    /// @notice EntryPoint contract (ERC-4337)
    address public ENTRY_POINT;

    /// @notice Minimum stake: 30 GToken
    uint256 public constant MIN_STAKE = 30 ether;

    /// @notice Minimum aPNTs balance: 100 aPNTs
    uint256 public constant MIN_APNTS_BALANCE = 100 ether;

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

    event aPNTsDeposited(
        address indexed operator,
        uint256 amount,
        uint256 timestamp
    );

    event TransactionSponsored(
        address indexed operator,
        address indexed user,
        uint256 cost,
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

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize SuperPaymasterV2
     * @param _gtokenStaking GTokenStaking contract address
     * @param _registry Registry contract address
     */
    constructor(
        address _gtokenStaking,
        address _registry
    ) Ownable(msg.sender) {
        if (_gtokenStaking == address(0) || _registry == address(0)) {
            revert InvalidAddress(address(0));
        }

        GTOKEN_STAKING = _gtokenStaking;
        REGISTRY = _registry;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register new operator
     * @param sGTokenAmount Amount of sGToken to lock
     * @param supportedSBTs List of supported SBT contracts
     * @param xPNTsToken Community points token address
     */
    function registerOperator(
        uint256 sGTokenAmount,
        address[] memory supportedSBTs,
        address xPNTsToken
    ) external {
        if (sGTokenAmount < MIN_STAKE) {
            revert InsufficientStake(sGTokenAmount, MIN_STAKE);
        }

        if (accounts[msg.sender].stakedAt != 0) {
            revert AlreadyRegistered(msg.sender);
        }

        // Lock stake from GTokenStaking
        IGTokenStaking(GTOKEN_STAKING).lockStake(msg.sender, sGTokenAmount);

        // Initialize operator account
        accounts[msg.sender] = OperatorAccount({
            sGTokenLocked: sGTokenAmount,
            stakedAt: block.timestamp,
            aPNTsBalance: 0,
            totalSpent: 0,
            lastRefillTime: 0,
            minBalanceThreshold: MIN_APNTS_BALANCE,
            supportedSBTs: supportedSBTs,
            xPNTsToken: xPNTsToken,
            reputationScore: 0,
            consecutiveDays: 0,
            totalTxSponsored: 0,
            reputationLevel: 1,
            lastCheckTime: block.timestamp,
            isPaused: false
        });

        emit OperatorRegistered(msg.sender, sGTokenAmount, block.timestamp);
    }

    /**
     * @notice Deposit aPNTs (burn xPNTs 1:1)
     * @param amount Amount to deposit
     */
    function depositAPNTs(uint256 amount) external {
        if (accounts[msg.sender].stakedAt == 0) {
            revert NotRegistered(msg.sender);
        }

        address xPNTsToken = accounts[msg.sender].xPNTsToken;
        if (xPNTsToken == address(0)) {
            revert InvalidConfiguration();
        }

        // Burn xPNTs from user (pre-authorized, no approve needed)
        IxPNTsToken(xPNTsToken).burn(msg.sender, amount);

        accounts[msg.sender].aPNTsBalance += amount;
        accounts[msg.sender].lastRefillTime = block.timestamp;

        emit aPNTsDeposited(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Validate paymaster user operation (ERC-4337)
     * @param userOp User operation
     * @param userOpHash User operation hash
     * @param maxCost Maximum cost
     * @return context Context for postOp
     * @return validationData Validation result
     */
    function validatePaymasterUserOp(
        bytes calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        // Extract operator from paymasterAndData
        address operator = _extractOperator(userOp);
        address user = _extractSender(userOp);

        // Validations
        if (accounts[operator].isPaused) {
            revert OperatorIsPaused(operator);
        }

        if (!_hasSBT(user, accounts[operator].supportedSBTs)) {
            revert NoSBTFound(user);
        }

        if (accounts[operator].aPNTsBalance < maxCost) {
            revert InsufficientAPNTs(maxCost, accounts[operator].aPNTsBalance);
        }

        // Pre-deduct cost
        accounts[operator].aPNTsBalance -= maxCost;

        // Return context for postOp
        context = abi.encode(operator, user, maxCost);
        validationData = 0; // Validation passed
    }

    /**
     * @notice Post operation (ERC-4337)
     * @param mode Operation mode
     * @param context Context from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost
     */
    function postOp(
        uint8 mode,
        bytes calldata context,
        uint256 actualGasCost
    ) external {
        require(msg.sender == ENTRY_POINT, "Only EntryPoint");

        (address operator, address user, uint256 maxCost) = abi.decode(
            context,
            (address, address, uint256)
        );

        // mode: 0 = opSucceeded, 1 = opReverted, 2 = postOpReverted
        if (mode <= 1) {
            // Refund unused gas
            uint256 refund = maxCost - actualGasCost;
            accounts[operator].aPNTsBalance += refund;
            accounts[operator].totalSpent += actualGasCost;
            accounts[operator].totalTxSponsored += 1;

            emit TransactionSponsored(operator, user, actualGasCost, block.timestamp);

            // Update reputation
            _updateReputation(operator);
        }
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
    ) external {
        if (msg.sender != DVT_AGGREGATOR) {
            revert UnauthorizedCaller(msg.sender);
        }

        uint256 slashAmount;
        uint256 reputationLoss;

        if (level == SlashLevel.WARNING) {
            reputationLoss = 10;
        } else if (level == SlashLevel.MINOR) {
            slashAmount = accounts[operator].sGTokenLocked * 5 / 100; // 5%
            reputationLoss = 20;
        } else if (level == SlashLevel.MAJOR) {
            slashAmount = accounts[operator].sGTokenLocked * 10 / 100; // 10%
            reputationLoss = 50;
            accounts[operator].isPaused = true;
            emit OperatorPaused(operator, block.timestamp);
        }

        // Execute slash on GTokenStaking
        if (slashAmount > 0) {
            accounts[operator].sGTokenLocked -= slashAmount;
            IGTokenStaking(GTOKEN_STAKING).slash(operator, slashAmount, "Low aPNTs balance");
        }

        // Update reputation
        if (accounts[operator].reputationScore > reputationLoss) {
            accounts[operator].reputationScore -= reputationLoss;
        } else {
            accounts[operator].reputationScore = 0;
        }

        // Record slash
        slashHistory[operator].push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            reputationLoss: reputationLoss,
            reason: "aPNTs balance below threshold",
            level: level
        }));

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
     * @notice Extract operator address from paymasterAndData
     * @param userOp User operation bytes
     * @return operator Operator address
     */
    function _extractOperator(bytes calldata userOp) internal pure returns (address operator) {
        // paymasterAndData format: [paymaster (20)][operator (20)][...]
        // userOp contains paymasterAndData at specific offset
        // Simplified: assume operator is at bytes 20-40
        require(userOp.length >= 40, "Invalid userOp");
        return address(bytes20(userOp[20:40]));
    }

    /**
     * @notice Extract sender from user operation
     * @param userOp User operation bytes
     * @return sender Sender address
     */
    function _extractSender(bytes calldata userOp) internal pure returns (address sender) {
        // Simplified: sender is at beginning
        require(userOp.length >= 20, "Invalid userOp");
        return address(bytes20(userOp[0:20]));
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
