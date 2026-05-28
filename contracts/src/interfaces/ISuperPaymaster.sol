// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import "src/interfaces/IVersioned.sol";

/**
 * @title ISuperPaymaster - Multi-tenant SuperPaymaster Interface
 * @notice Interface for SuperPaymaster V3 with per-operator configuration
 */
interface ISuperPaymaster is IVersioned {
    
    enum SlashLevel { WARNING, MINOR, MAJOR }

    struct OperatorConfig {
        // Slot 0: HOT (Validation Critical)
        // Layout: aPNTsBalance(16) + isConfigured(1) + isPaused(1) = 18 bytes; 14 bytes slack.
        // STORAGE NOTE: v5.3.2 and earlier packed `uint96 exchangeRate` into bytes [18..30) of
        // slot 0.  Removing it leaves those 12 bytes as unused padding.  Because address(20)
        // never fit in the ≤14 remaining bytes of slot 0 (with or without uint96), `xPNTsToken`
        // and all subsequent fields still start at the same slots as in v5.3.2.
        // → UUPS in-place upgrade from v5.3.2 is SAFE; stale `exchangeRate` bytes are ignored.
        uint128 aPNTsBalance;   // Cap: ~3.4e38 (Enough for 18 decimals)
        bool isConfigured;
        bool isPaused;

        // Slot 1: WARM
        address xPNTsToken;
        uint32 reputation;      // Max 4 billion
        uint48 minTxInterval;   // Min interval between user ops

        // Slot 2: COLD
        address treasury;

        // Slot 3+: Stats
        uint256 totalSpent;
        uint256 totalTxSponsored;
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
    event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury);
    // aPNTsCost: raw gas cost before protocol fee; debtAPNTs: actual debt recorded (cost + fee markup)
    event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 debtAPNTs);
    event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level);
    event ReputationUpdated(address indexed operator, uint256 newScore);
    // event ValidationRejected removed — ERC-4337 validatePaymasterUserOp cannot emit events

    // V5: x402 Events
    event X402PaymentSettled(address indexed from, address indexed to, address asset, uint256 amount, uint256 fee, bytes32 nonce);

    // ============ Functions ============

    /**
     * @notice Configure operator billing settings.
     *         Exchange rate is read from the xPNTs token contract at runtime.
     */
    function configureOperator(address xPNTsToken, address _opTreasury) external;

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
        uint128 aPNTsBalance,
        bool isConfigured,
        bool isPaused,
        address xPNTsToken,
        uint32 reputation,
        uint48 minTxInterval,
        address treasury,
        uint256 totalSpent,
        uint256 totalTxSponsored
    );

    function updateBlockedStatus(address operator, address[] calldata users, bool[] calldata statuses) external;

    function updateSBTStatus(address user, bool status) external;

    // V5.3: Dual-channel eligibility
    function isEligibleForSponsorship(address user) external view returns (bool);

    // V5: x402 EIP-3009 Settlement (USDC native)
    function settleX402Payment(
        address from, address to, address asset, uint256 amount,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external returns (bytes32 settlementId);

    // V5: x402 Direct Settlement (xPNTs and pre-approved tokens)
    function settleX402PaymentDirect(
        address from, address to, address asset, uint256 amount, bytes32 nonce
    ) external returns (bytes32 settlementId);

}
