// SPDX-License-Identifier: MIT
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
        uint128 aPNTsBalance;   // Cap: ~3.4e38 (Enough for 18 decimals)
        uint96 exchangeRate;    // Cap: ~7.9e28
        bool isConfigured;
        bool isPaused;
        // Remaining: 2 bytes
        
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
    event OperatorConfigured(address indexed operator, address xPNTsToken, address treasury, uint256 exchangeRate);
    event TransactionSponsored(address indexed operator, address indexed user, uint256 aPNTsCost, uint256 xPNTsCost);
    event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level);
    event ReputationUpdated(address indexed operator, uint256 newScore);
    // event ValidationRejected removed — ERC-4337 validatePaymasterUserOp cannot emit events

    // ============ x402 Events ============

    event X402PaymentSettled(
        address indexed from,
        address indexed to,
        address asset,
        uint256 amount,
        uint256 fee,
        bytes32 nonce
    );
    event FacilitatorFeeUpdated(uint256 oldFee, uint256 newFee);

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
        uint128 aPNTsBalance,
        uint96 exchangeRate,
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

    // ============ x402 Functions ============

    /**
     * @notice Verify an x402 payment before settlement (off-chain pre-check)
     * @param from     Payer address (token holder)
     * @param to       Payee address (content provider)
     * @param asset    EIP-3009 compatible token address (e.g., USDC)
     * @param amount   Payment amount in token units
     * @param validAfter  Earliest valid timestamp
     * @param validBefore Latest valid timestamp
     * @param nonce    Unique nonce for replay prevention
     * @param signature EIP-3009 authorization signature
     * @return valid   Whether the payment can be settled
     * @return reason  Failure reason (empty if valid)
     */
    function verifyX402Payment(
        address from,
        address to,
        address asset,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external view returns (bool valid, string memory reason);

    /**
     * @notice Settle an x402 payment using EIP-3009 transferWithAuthorization
     * @param from     Payer address (token holder)
     * @param to       Payee address (content provider)
     * @param asset    EIP-3009 compatible token address (e.g., USDC)
     * @param amount   Payment amount in token units
     * @param validAfter  Earliest valid timestamp
     * @param validBefore Latest valid timestamp
     * @param nonce    Unique nonce for replay prevention
     * @param signature EIP-3009 authorization signature
     * @return settlementId Unique settlement identifier
     */
    function settleX402Payment(
        address from,
        address to,
        address asset,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external returns (bytes32 settlementId);

    /**
     * @notice Set the default facilitator fee in basis points
     * @param _fee Fee in basis points (max 500 = 5%)
     */
    function setFacilitatorFeeBPS(uint256 _fee) external;

    /**
     * @notice Set a per-operator facilitator fee override
     * @param operator Operator address
     * @param _fee Fee in basis points (0 = use default, max 500 = 5%)
     */
    function setOperatorFacilitatorFee(address operator, uint256 _fee) external;

}
