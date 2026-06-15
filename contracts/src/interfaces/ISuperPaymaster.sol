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
        // ⚠️  BREAKING STORAGE LAYOUT CHANGE vs v5.3.2:
        // v5.3.2 slot 0: bytes 0-15 aPNTsBalance | bytes 16-27 exchangeRate(uint96) | byte 28 isConfigured | byte 29 isPaused
        // v5.3.3 slot 0: bytes 0-15 aPNTsBalance | byte 16 isConfigured             | byte 17 isPaused
        // isConfigured shifts from byte 28 → byte 16.  On an in-place UUPS upgrade new code reads
        // isConfigured at byte 16 = old exchangeRate LSByte (e.g. 1e18 LSByte = 0x00 → false).
        // All operators would appear unconfigured.  In-place UUPS upgrade from v5.3.2 is NOT SAFE.
        // All affected deployments must be redeployed.  Sepolia was redeployed in PR #196.
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

    // v5.4 god-split phase 1: x402 events/functions (X402PaymentSettled, settleX402Payment,
    // settleX402PaymentDirect) moved to the standalone X402Facilitator contract.

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

}
