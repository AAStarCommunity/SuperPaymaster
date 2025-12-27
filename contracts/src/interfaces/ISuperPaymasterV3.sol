// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ISuperPaymasterV3 - Multi-tenant SuperPaymaster Interface
 * @notice Interface for SuperPaymaster V3 with per-operator configuration
 */
interface ISuperPaymasterV3 {
    
    enum SlashLevel { WARNING, MINOR, MAJOR }

    struct OperatorConfig {
        address xPNTsToken;
        bool isConfigured;
        bool isPaused;
        address treasury;
        uint96 exchangeRate;
        uint256 aPNTsBalance;
        uint256 totalSpent;
        uint256 totalTxSponsored;
        uint256 reputation;
    }

    struct SlashRecord {
        uint256 timestamp;
        uint256 amount;
        uint256 reputationLoss;
        string reason;
        SlashLevel level;
    }

    // ============ Events ============

    event OperatorDeposited(address indexed operator, uint256 amount);
    event OperatorWithdrawn(address indexed operator, uint256 amount);
    event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury, uint256 exchangeRate);
    event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 xPNTsCost);
    event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level);
    event ReputationUpdated(address indexed operator, uint256 newScore);
    event ValidationRejected(address indexed user, address indexed operator, uint8 reasonCode);

    // ============ Functions ============

    /**
     * @notice Configure operator billing settings
     */
    function configureOperator(address xPNTsToken, address _opTreasury, uint256 exchangeRate) external;

    /**
     * @notice Deposit aPNTs as gas collateral
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Notify contract of a direct transfer (Ad-hoc Push Mode)
     */
    function depositFor(address targetOperator, uint256 amount) external;

    /**
     * @notice Withdraw aPNTs collateral
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Get operator credit limit for a user
     */
    function getAvailableCredit(address user, address token) external view returns (uint256);

    /**
     * @notice Slash operator via BLS consensus
     */
    function executeSlashWithBLS(address operator, SlashLevel level, bytes calldata proof) external;

    /**
     * @notice Get operator configuration
     */
    function operators(address operator) external view returns (
        address xPNTsToken,
        bool isConfigured,
        bool isPaused,
        address treasury,
        uint96 exchangeRate,
        uint256 aPNTsBalance,
        uint256 totalSpent,
        uint256 totalTxSponsored,
        uint256 reputation
    );
}
