// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "./BasePaymasterUpgradeable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "src/interfaces/v3/IRegistry.sol";
import "../../../tokens/v2/IxPNTsTokenV2.sol";
import "../../../interfaces/IxPNTsFactory.sol";
import "../../../interfaces/ISuperPaymaster.sol";
import "../../../interfaces/v3/IAgentIdentityRegistry.sol";
import "../../../interfaces/v3/IAgentReputationRegistry.sol";



/**
 * @title SuperPaymaster
 * @notice SuperPaymaster - Unified Registry based Multi-Operator Paymaster
 * @dev Optimized for Gas and Security (CEI, Packing, Batch Updates).
 */
contract SuperPaymaster is BasePaymasterUpgradeable, ReentrancyGuard, ISuperPaymaster {
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
    /// @dev 5.5.0: operator reservation between validation and postOp (R10-M1b).
    struct Inflight {
        address operator;
        uint96 a0;
    }

    /// @dev exp/params: owner-settable gas parameters, one slot (4 x uint32).
    struct GasParams {
        uint32 minPostOpGas;
        uint32 settleGasBound;
        uint32 cWrap;
        uint32 cPostop;
    }

    /// @dev exp/params: pending proposal + eta, one slot.
    struct PendingGasParams {
        uint32 minPostOpGas;
        uint32 settleGasBound;
        uint32 cWrap;
        uint32 cPostop;
        uint64 eta;
    }

    /// @dev 5.5.0 postOp context (spec §3.2, R10-M3: price snapshot taken at validation).
    struct OpCtx {
        address token;
        address user;
        uint256 a0;
        bytes32 opHash;
        address operator;
        uint8 mode;
        uint128 callGas;
        uint128 postOpGas;
        int256 price;
        uint8 decimals;
        uint256 aPriceUSD;
    }
    // exp/params context format (Codex rounds 1-3). OpCtx is an upgrade-compatibility surface in
    // BOTH directions; every word of OpCtx stays ABI-canonical for its 5.5.0 type (never pack into
    // a narrow-typed word: 5.5.0's decoder reverts on dirty bits).
    //   emitted : abi.encode(OpCtx) (the 11 5.5.0 words, 352 B) ‖ one trailing word (384 B total):
    //             the GasParams slot as validation saw it (minPostOpGas | settleGasBound << 32 |
    //             cWrap << 64 | cPostop << 96; never zero — defaults substituted).
    //             5.5.0's `abi.decode(context, (OpCtx))` ignores the trailing word (rollback).
    //   accepted: 384 B → snapshot; 352 B (a 5.5.0 context, forward upgrade) → LEGACY rules;
    //             word 12 is read ONLY when the length is exactly 384.
    /// @dev Emit-only layout: OpCtx's 11 words + the trailing snapshot word (ABI-identical to
    ///      abi.encode(OpCtx) ‖ bytes32(gasSnap)). Decoding always uses OpCtx (trailing word ignored).
    struct OpCtxOut {
        address token;
        address user;
        uint256 a0;
        bytes32 opHash;
        address operator;
        uint8 mode;
        uint128 callGas;
        uint128 postOpGas;
        int256 price;
        uint8 decimals;
        uint256 aPriceUSD;
        uint256 gasSnap;
    }
    uint256 internal constant CTX_LEN = 384;

    struct UserOperatorState {
        uint48 lastTimestamp; // 6 bytes
        bool isBlocked;       // 1 byte
        // 25 bytes remaining in slot
    }

    // --- Mappings ---

    // CONSOLIDATED MAPPING: operator => user => state (Saves 1 SLOAD in hot path)
    mapping(address => mapping(address => UserOperatorState)) public userOpState;

    mapping(address => bool) public sbtHolders; // Global SBT holders list (verified via Registry)
    mapping(address => ISuperPaymaster.SlashRecord[]) public slashHistory;

    function version() external pure virtual override returns (string memory) {
        return "SuperPaymaster-5.5.1-exp"; // v5.5.0: AOA balance mode (xPNTs v2 escrow + reservation credit), in-flight sponsorship accounting
    }

    uint256 internal constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 internal constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 internal constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    /// @notice Grace window (seconds) for keeper clock skew on `updatedAt` checks.
    ///         Matches PaymasterBase.TIMESTAMP_GRACE_SECONDS to keep both modes in sync.
    uint256 internal constant TIMESTAMP_GRACE_SECONDS = 15;

    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)

    PriceCache public cachedPrice; // Make public for easy verification

    // V3.2.1 SECURITY: Enforce max rate in Validation
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52; // ERC-4337 v0.7
    uint256 internal constant RATE_OFFSET = 72; // 20 (paymaster addr) + 32 (gas limits) + 20 (operator addr) = 72
    // paymasterAndData (v0.7): [paymaster 20][pmVerifGas 16][pmPostOpGas 16][operator 20][maxRate 32]
    uint256 internal constant POSTOP_GAS_OFFSET = 36; // start of paymasterPostOpGasLimit (uint128)
    // C-04: floor for paymasterPostOpGasLimit. Below this an attacker forces postOp
    // OOG so validation's optimistic operator debit is never reconciled (operator
    // drain + protocolRevenue inflation). Measured postOp: ~142k (burn) / ~137k (debt
    // path w/ minTxInterval); conservative cold-storage worst ~178k. 200k covers it
    // with headroom and matches the gas-limit builders already use.
    uint256 internal constant MIN_POST_OP_GAS = 200_000; // exp/params: DEFAULT (see GasParams)

    // ---- 5.5.0 balance mode (spec 03 §1, §3.2, §10.1, §11.1) ----
    /// @dev paymasterAndData: [paymaster 20][verifGas 16][postOpGas 16][operator 20][maxRate 32][token 20][flags 1]
    uint256 internal constant TOKEN_OFFSET = 104;
    uint256 internal constant FLAGS_OFFSET = 124;
    uint8 internal constant FLAG_SP_RENEW = 1;       // SP relays a K-bounded renewal (D-13)
    uint8 internal constant FLAG_ACCOUNT_RENEW = 2;  // consumed by the account itself (option A); SP ignores it
    uint8 internal constant MODE_NONE = 0;
    uint8 internal constant MODE_BALANCE = 1;
    uint8 internal constant MODE_CREDIT = 2;
    /// @dev B-1 §10.1 ③ / R10-H1: postOp refuses to start settlement below this. It must cover
    ///      everything postOp does AFTER the entry check on its worst path (fresh rate-limit
    ///      timestamp, fresh idempotency/usedOpHash slots, BALANCE or CREDIT settle): measured
    ///      ~137k (D3), so every call that passes the check completes — no OOG band above it
    ///      (test_B1_no_oog_band_above_entry_guard). MIN_POST_OP_GAS (200k) still clears it
    ///      after the pre-check overhead (T-R14-09 through EntryPoint).
    uint256 internal constant SETTLE_GAS_BOUND = 160_000;
    /// @dev R10-M3 (exp/buffer): EntryPoint wrapper gas outside the postOp callback. Measured ~1.7k
    ///      on the canonical EntryPoint (SuperPaymasterV55GasTest); 5k once the postOp term below is
    ///      tightened, since C_WRAP then carries weight.
    uint256 internal constant C_WRAP_GAS = 5_000;
    /// @dev exp/buffer: upper bound of the WHOLE postOp frame gas on every path (replaces the user's
    ///      paymasterPostOpGasLimit in the buffer). Rule: C_POSTOP >= W_postop x (1 + m), W_postop
    ///      measured in-test on the worst paths (SuperPaymasterV55PostOpBoundTest, m = 15%).
    ///      MIN_POST_OP_GAS >= C_POSTOP, so min(postOpGasLimit, C_POSTOP) == C_POSTOP.
    ///      exp/params: default raised 170k -> 175k so that the default sits at the hard floor below.
    uint256 internal constant C_POSTOP_GAS = 175_000;
    // exp/params: the four constants above (MIN_POST_OP_GAS, SETTLE_GAS_BOUND, C_WRAP_GAS,
    // C_POSTOP_GAS) are the DEFAULTS of the owner-settable `GasParams` (48 h timelock). Hard bounds,
    // checked at queue AND execute (measurements: buffer-and-params-experiment.md §B.2):
    //   SETTLE_GAS_BOUND in [155k, 1M]   smallest value with no OOG band above the guard, measured
    //                                     on the worst path (CREDIT, first debt, cold timestamp): 144k
    //                                     (143k still has one); 155k = +7.6%
    //   MIN_POST_OP_GAS  in [SETTLE + 20k, 2M]   pre-check overhead measured ~7.4k (x2.7 margin)
    //   C_POSTOP         in [175k, MIN_POST_OP_GAS]   every accepted value satisfies the G-layer
    //                                     rule C_POSTOP >= W_postop x 1.15 (W_postop 146,853 ->
    //                                     168,881; 175k leaves +3.6% for drift); <= MIN keeps
    //                                     min(postOpGasLimit, C_POSTOP) == C_POSTOP
    //   C_WRAP           in [5k, 50k]    EntryPoint wrap measured 1,770 with the 12-word context
    //                                     (x2.8 margin)
    //   All-floor tuple (175k, 155k, 5k, 175k) is consistent (MIN = SETTLE + 20k = C_POSTOP) and is
    //   exercised by the G-layer rule and the G2 fuzz. R-AMS: Amsterdam requires re-measuring and,
    //   if needed, raising these floors by upgrade.
    uint256 internal constant GP_SETTLE_MIN = 155_000;
    uint256 internal constant GP_SETTLE_MAX = 1_000_000;
    uint256 internal constant GP_MINPOST_OVER_SETTLE = 20_000;
    uint256 internal constant GP_MINPOST_MAX = 2_000_000;
    uint256 internal constant GP_CPOSTOP_MIN = 175_000;
    uint256 internal constant GP_CWRAP_MIN = 5_000;
    uint256 internal constant GP_CWRAP_MAX = 50_000;
    uint256 internal constant GP_TIMELOCK = 48 hours;
    /// @dev 5.5.0 values, applied ONLY to a context produced by the 5.5.0 implementation (no
    ///      snapshot) that is settled by this implementation after a mid-bundle upgrade.
    uint256 internal constant LEGACY_SETTLE_GAS_BOUND = 160_000;
    uint256 internal constant LEGACY_C_WRAP_GAS = 30_000;
    bytes32 internal constant INFLIGHT_SEED = keccak256("SP.v5.5.inflight.live");

    // Protocol Fee (Basis Points)
    uint256 public protocolFeeBPS = 1000; // 10%
    uint256 internal constant BPS_DENOMINATOR = 10000;
    uint256 internal constant MAX_PROTOCOL_FEE = 2000; // 20% Hardcap (Security)
    uint256 internal constant VALIDATION_BUFFER_BPS = 1000; // 10% for Validation safety margin
    /// @notice Minimum protocolRevenue that must remain after any withdrawal.
    ///         Prevents draining the buffer needed for in-flight postOp refunds.
    ///         Sized to cover ~10 concurrent ops at 0.01 aPNTs each (conservative).
    uint256 internal constant PROTOCOL_REVENUE_BUFFER = 0.1 ether;

    address public BLS_AGGREGATOR; // Trusted Aggregator for DVT Slash

    // State Variables (Restored)
    uint256 public totalTrackedBalance;
    uint256 public protocolRevenue;

    // RETIRED in 5.5.0 (was the V4.1 pending-debt fallback). The slot is kept so the UUPS
    // layout stays byte-identical; nothing reads or writes it any more. Reconcile or write off
    // any non-zero entries BEFORE upgrading (spec 03 §6 step 2).
    mapping(address => mapping(address => uint256)) internal pendingDebts;

    // V3.1: Credit & Reputation Events
    event UserReputationAccrued(address indexed user, uint256 aPNTsValue);

    /**
     * @notice Emitted when aPNTs token is updated
     */
    event APNTsTokenUpdated(address indexed oldToken, address indexed newToken);
    /// @notice P0-9: emitted when an `setAPNTsToken` change is queued. The
    ///         pending swap can be cancelled by `cancelAPNTsTokenChange` or
    ///         executed once `eta` has elapsed via `executeAPNTsTokenChange`.
    event APNTsTokenChangeQueued(address indexed pendingToken, uint256 eta);
    event APNTsTokenChangeCancelled(address indexed pendingToken);
    /// @notice Emitted exclusively by `executeAPNTsTokenChange` (timelock path).
    ///         On-chain monitors can distinguish this from legacy direct-swap
    ///         `APNTsTokenUpdated` events by watching this separate topic.
    event APNTsTokenChangeExecuted(address indexed oldToken, address indexed newToken, uint256 executedAt);
    /// @notice P0-10: emitted when an emergency price is queued under the
    ///         break-glass path (Chainlink is stale + multisig owner approves).
    event EmergencyPriceQueued(int256 newPrice, uint256 eta);
    event EmergencyPriceExecuted(int256 newPrice);
    event EmergencyPriceCancelled(int256 cancelledPrice);
    event PriceModeChanged(uint8 oldMode, uint8 newMode);
    event APNTsPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event BLSAggregatorUpdated(address indexed oldAggregator, address indexed newAggregator);
    event OperatorPaused(address indexed operator);
    event OperatorUnpaused(address indexed operator);
    event OperatorMinTxIntervalUpdated(address indexed operator, uint48 minTxInterval);
    event UserBlockedStatusUpdated(address indexed operator, address indexed user, bool isBlocked);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event XPNTsFactoryUpdated(address indexed oldFactory, address indexed newFactory);

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
    /// @notice M-5: emitted when an operator's withdraw is locked pending a slash.
    event SlashQueued(address indexed operator);
    /// @notice M-5: emitted when a pending slash is cancelled without execution.
    event SlashCancelled(address indexed operator);
    /// @notice CC-13: emitted when the global BLS-slash cooldown floor is (re-)primed.
    event BlsSlashCooldownPrimed(uint48 floorUntil);
    
    event PriceUpdated(int256 indexed price, uint256 indexed timestamp);
    /**
     * @notice Emitted when Oracle update fails, forcing a realtime fallback (Warning Sign)
     */
    event OracleFallbackTriggered(uint256 timestamp);

    /// @notice P0-15 (J2-BLOCKER-1): observability hook for the silent
    ///         SIG_FAILURE branches of validatePaymasterUserOp. Reserved for
    ///         future monitoring integrations — NOT emitted from
    ///         validatePaymasterUserOp itself, since writing storage during
    ///         that opcode-restricted phase would violate ERC-7562.
    /// @dev Not emitted during validatePaymasterUserOp (ERC-7562 prohibits LOG* opcodes
    ///      in that phase). Off-chain monitoring should use `dryRunValidation()` for
    ///      pre-flight checks; this event is reserved for a future postOp observability hook.
    event ValidationFailed(bytes32 indexed userOpHash, bytes32 reasonCode);
    event ProtocolRevenueWithdrawn(address indexed to, uint256 amount);
    /// @notice Emitted when postOp refund is clamped to protocolRevenue (operator gets under-refunded).
    /// @dev Happens when owner withdrew protocolRevenue between validation and postOp, leaving
    ///      insufficient balance to cover the validation-phase buffer refund. Clamp avoids revert
    ///      in postOp (which would break UserOp flow); cost is operator absorbing the shortfall.
    event ProtocolRevenueUnderflow(address indexed operator, uint256 requestedRefund, uint256 availableRevenue);
    event DebtRecordFailed(address indexed token, address indexed user, uint256 amount);
    event PendingDebtRetried(address indexed token, address indexed user, uint256 amount);
    event PendingDebtCleared(address indexed token, address indexed user, uint256 amount);
    error Unauthorized();
    error InvalidAddress();
    error InvalidConfiguration();
    error PostOpGasTooLow();
    error GasParamsTimelock();
    event GasParamsQueued(uint32 minPostOpGas, uint32 settleGasBound, uint32 cWrap, uint32 cPostop, uint64 eta);
    event GasParamsExecuted(uint32 minPostOpGas, uint32 settleGasBound, uint32 cWrap, uint32 cPostop);
    event GasParamsCancelled();
    error SponsorshipInFlight();
    event SponsorshipReleased(bytes32 indexed opHash, address indexed operator, uint256 aPNTs);
    error InsufficientBalance(uint256 available, uint256 required);
    error DepositNotVerified();
    error OracleError();
    error NoSlashHistory();
    error InsufficientRevenue();
    error InvalidXPNTsToken();
    error AmountExceedsUint128();
    error ScoreExceedsUint32();
    error NoPendingDebt();
    /// @notice P0-10: emergencySetPrice rejected because Chainlink is fresh.
    error ChainlinkNotStale();
    /// @notice P0-10: emergency price outside the ±20% band vs current cache.
    error EmergencyPriceOutOfRange();
    /// @notice P0-10: executeEmergencyPrice called before timelock elapsed.
    error EmergencyTimelockNotElapsed();
    /// @notice P0-10: executeEmergencyPrice called with no queued price.
    error NoEmergencyPending();
    /// @notice P0-10: emergencySetPrice called after EMERGENCY_EXPIRY elapsed with no Chainlink recovery.
    error EmergencyExpired();
    /// @notice M-5: initialize() called with owner == address(0).
    error InvalidOwner();
    /// @notice M-5: withdraw blocked because a slash has been queued for this operator.
    error SlashPending();

    // ====================================
    // Internal Helpers
    // ====================================

    /// @dev Reverts with Unauthorized if caller is not a registered ROLE_PAYMASTER_SUPER member
    function _requireSuperOperatorRole() internal view {
        if (!REGISTRY.hasRole(keccak256("PAYMASTER_SUPER"), msg.sender)) revert Unauthorized();
    }

    /// @dev Reverts with Unauthorized if `account` is not a registered ROLE_PAYMASTER_SUPER member
    function _requireSuperOperatorRoleFor(address account) internal view {
        if (!REGISTRY.hasRole(keccak256("PAYMASTER_SUPER"), account)) revert Unauthorized();
    }

    // ====================================
    // Constructor & Initializer (UUPS)
    // ====================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IEntryPoint _entryPoint,
        IRegistry _registry,
        address _ethUsdPriceFeed
    ) BasePaymasterUpgradeable(_entryPoint) {
        REGISTRY = _registry;
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethUsdPriceFeed);
    }

    /**
     * @notice Initialize the UUPS proxy state
     * @param _owner Contract owner
     * @param _apntsToken aPNTs token address
     * @param _protocolTreasury Treasury address for protocol fees
     * @param _priceStalenessThreshold Oracle staleness threshold in seconds
     */
    function initialize(
        address _owner,
        address _apntsToken,
        address _protocolTreasury,
        uint256 _priceStalenessThreshold
    ) external initializer {
        if (_owner == address(0)) revert InvalidOwner();
        __BasePaymaster_init(_owner);
        // Note: _apntsToken can be address(0) during staged deployment
        // (deployed later via setAPNTsToken which has its own zero-address check)
        APNTS_TOKEN = _apntsToken;
        treasury = _protocolTreasury != address(0) ? _protocolTreasury : _owner;
        uint256 staleness = _priceStalenessThreshold > 0 ? _priceStalenessThreshold : 3600;
        // Same range as PaymasterBase.setPriceStalenessThreshold. There is no setter here, so this is
        // the only write: an oversized value underflows `block.timestamp - threshold` in updatePrice
        // and truncates `uint48(updatedAt + threshold)` (validUntil).
        if (staleness < 60 || staleness > 86400) revert InvalidConfiguration();
        priceStalenessThreshold = staleness;
        // Default values must be set explicitly (proxy storage doesn't inherit implementation defaults)
        aPNTsPriceUSD = 0.02 ether;
        protocolFeeBPS = 1000;
    }

    // ====================================
    // Operator Management
    // ====================================

    /**
     * @notice Configure billing settings (Operator only).
     *         Exchange rate is read from xPNTsToken.exchangeRate() at runtime.
     * @param xPNTsToken Token to charge users
     * @param _opTreasury Address to receive payments
     */
    /// @dev Registers msg.sender as an operator with the given xPNTs token; reverts if token not issued by the wired factory.
    function configureOperator(address xPNTsToken, address _opTreasury) external {
        // Must be registered in Registry
        _requireSuperOperatorRole();
        // BUS-RULE: Must be Community to be Paymaster
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert Unauthorized();
        }
        if (xPNTsToken == address(0) || _opTreasury == address(0)) {
            revert InvalidConfiguration();
        }

        // P1-4: Factory binding is always required — configuring an arbitrary ERC20
        // before the factory is set would bypass the community token validation.
        address factory = xpntsFactory;
        if (factory == address(0)) revert InvalidConfiguration();
        address validToken = IxPNTsFactory(factory).getTokenAddress(msg.sender);
        if (validToken != xPNTsToken) revert InvalidXPNTsToken();
        // 5.5.0: only balance-mode (xPNTs v2) tokens can back an operator.
        try IxPNTsTokenV2(xPNTsToken).BALANCE_MODE_VERSION() returns (uint16 v) {
            if (v != 1) revert InvalidXPNTsToken();
        } catch {
            revert InvalidXPNTsToken();
        }

        OperatorConfig storage config = operators[msg.sender];
        config.xPNTsToken = xPNTsToken;
        config.treasury = _opTreasury;
        config.isConfigured = true;

        emit OperatorConfigured(msg.sender, xPNTsToken, _opTreasury);
    }

    /// @notice Window between queueing an `setAPNTsToken` change and being
    ///         allowed to execute it. Owner can cancel any time during this
    ///         window. Picked to give all integrators (operators, SDKs,
    ///         off-chain monitors) at least one weekly review cycle to react.
    /// @dev    P0-9: was a single instant write; could strand operator
    ///         deposits permanently if the new token had zero balances. The
    ///         timelock + cancellation pattern follows OZ TimelockController
    ///         semantics in spirit (queue / cancel / execute).
    uint256 public constant APNTS_TOKEN_TIMELOCK = 7 days;

    // P0-10 — Chainlink break-glass state machine (D8 design)
    /// @notice 0 = CHAINLINK (normal), 1 = EMERGENCY (owner override active).
    uint8 public priceMode;
    /// @notice Timestamp at which `emergencySetPrice` was last called; 0 if none queued.
    uint256 public emergencyQueuedAt;
    /// @notice Pending emergency price (8 decimals, same scale as Chainlink).
    int256 public emergencyPendingPrice;
    /// @notice Timestamp at which EMERGENCY mode was first activated (i.e. first
    ///         `executeEmergencyPrice` call after a CHAINLINK→EMERGENCY transition).
    ///         Cleared to 0 on Chainlink recovery. Used to enforce EMERGENCY_EXPIRY.
    uint256 public emergencyActivatedAt;

    uint256 public constant EMERGENCY_TIMELOCK = 1 hours;
    uint256 internal constant CHAINLINK_STALE_THRESHOLD = 1 hours;
    /// @notice Anti-double-slash cooldown for the BLS/DVT slash path (executeSlashWithBLS).
    ///         Sized to cover the finality-lag + gossip + re-queue race window across DVT
    ///         nodes (which observe the same violation at different blocks → different epoch
    ///         → distinct queue-hash that the aggregator replay-guard cannot dedupe), while
    ///         staying short enough to allow a legitimate MINOR→MAJOR escalation afterwards.
    uint48 internal constant SLASH_BLS_COOLDOWN = 1 hours;
    uint256 internal constant EMERGENCY_PRICE_DEVIATION_BPS = 2000; // 20%
    /// @notice Maximum duration for which EMERGENCY mode may remain active.
    ///         After 7 days without Chainlink recovery the break-glass is
    ///         considered expired; `emergencySetPrice` will revert to prevent
    ///         an indefinitely-live manual-override regime.
    uint256 internal constant EMERGENCY_EXPIRY = 7 days;

    /// @notice Queue a new APNTS_TOKEN. Cannot take effect until
    ///         `pendingAPNTsTokenEta` and only when both `totalTrackedBalance`
    ///         and `protocolRevenue` are within PROTOCOL_REVENUE_BUFFER (otherwise
    ///         existing operator deposits would be stranded under the new token's
    ///         accounting).
    /// @dev    P0-9 (B2-N1): owner can cancel within the window via
    ///         `cancelAPNTsTokenChange`. Re-queueing a change refreshes the
    ///         timer (intentional — allows the owner to abort and restart).
    function setAPNTsToken(address newAPNTsToken) external onlyOwner {
        if (newAPNTsToken == address(0)) revert InvalidAddress();
        pendingAPNTsToken = newAPNTsToken;
        pendingAPNTsTokenEta = block.timestamp + APNTS_TOKEN_TIMELOCK;
        emit APNTsTokenChangeQueued(newAPNTsToken, pendingAPNTsTokenEta);
    }

    /// @notice Abort a queued APNTS_TOKEN swap before it executes.
    function cancelAPNTsTokenChange() external onlyOwner {
        address pending = pendingAPNTsToken;
        if (pending == address(0)) return; // idempotent
        pendingAPNTsToken = address(0);
        pendingAPNTsTokenEta = 0;
        emit APNTsTokenChangeCancelled(pending);
    }

    /// @notice Apply a previously queued APNTS_TOKEN swap.
    /// @dev    Requires the timelock to have elapsed AND the contract to be
    ///         drained of operator-tracked balance and protocol revenue —
    ///         the same balance-zero invariant the audit recommended,
    ///         enforced at execute-time so operators can decide when to
    ///         drain rather than blocking the queue itself.
    ///
    ///         Intentionally owner-only: unlike OZ TimelockController's
    ///         permissionless execute, token migration is sensitive enough
    ///         to require explicit owner confirmation. The owner can effectively
    ///         cancel any time before calling this function simply by not
    ///         calling it, or by calling cancelAPNTsTokenChange() to reset the
    ///         queue. Third-party execution is not allowed because it would
    ///         remove the owner's final veto after the timelock expires.
    function executeAPNTsTokenChange() external onlyOwner {
        address pending = pendingAPNTsToken;
        if (pending == address(0)) revert InvalidConfiguration();
        if (block.timestamp < pendingAPNTsTokenEta) revert InvalidConfiguration();
        // Safe-to-migrate invariant: no operator funds stranded under old token.
        //
        // totalTrackedBalance = sum(all operator aPNTs balances) + protocolRevenue.
        // When every operator has fully withdrawn, the difference
        // (totalTrackedBalance - protocolRevenue) reaches 0, i.e.
        // totalTrackedBalance == protocolRevenue.  Requiring this equality
        // ensures no operator balance remains stranded under the old token's
        // accounting before we switch to a new token.
        //
        // protocolRevenue can never reach 0 once the protocol has operated
        // (withdrawProtocolRevenue() leaves PROTOCOL_REVENUE_BUFFER unwithdrawable
        // to absorb in-flight postOp refunds — H-4 fix).  So we only require
        // protocolRevenue <= PROTOCOL_REVENUE_BUFFER (i.e. fully drained to buffer).
        if (totalTrackedBalance != protocolRevenue || protocolRevenue > PROTOCOL_REVENUE_BUFFER) revert InvalidConfiguration();

        address oldToken = APNTS_TOKEN;
        APNTS_TOKEN = pending;
        pendingAPNTsToken = address(0);
        pendingAPNTsTokenEta = 0;
        // Emit the timelock-specific event so monitors can distinguish this
        // from legacy direct-swap APNTsTokenUpdated events.
        emit APNTsTokenChangeExecuted(oldToken, pending, block.timestamp);
        // Also emit the backward-compatible event for existing listeners.
        emit APNTsTokenUpdated(oldToken, pending);
    }

    /// @notice P0-11: bounds for `setAPNTSPrice`. The unit-of-account scale
    ///         per D3 — 1 aPNTs anchors AAStar service value at roughly $0.02,
    ///         so bound the unit slack to a generous but finite range and cap
    ///         per-update drift to ±10% to limit the blast of a misclick or
    ///         partially-compromised owner key.
    uint256 internal constant APNTS_PRICE_MIN = 1e15;       // 0.001 ether per aPNTs
    uint256 internal constant APNTS_PRICE_MAX = 1e21;       // 1000 ether per aPNTs
    uint256 internal constant APNTS_PRICE_DELTA_BPS = 1000; // 10%

    /**
     * @notice Set the APNTS Price in USD (Owner Only)
     * @dev P0-11 (B2-N3): pre-fix the only check was `newPrice != 0`. Owner
     *      could move the unit scale arbitrarily — combined with the lack of
     *      timelock, a single mis-typed multisig call could distort the cost
     *      basis for every operator at once. Inline bounds:
     *      - absolute MIN/MAX: prevents nonsense magnitudes (e.g., off-by-1e18)
     *      - ±10% per-tx delta vs current price: bounds blast of mis-clicks
     *      - delta check skipped on first set (oldPrice == 0)
     *      Three setters across SP / xPNTs / V4 PaymasterBase each have their
     *      own MIN/MAX/DELTA tuned to the price they hold (different units),
     *      so the implementations are inline rather than a shared mixin.
     *
     * @dev Price-path independence: the ±10% delta cap enforced here is
     *      independent of the break-glass ±20% cap in `emergencySetPrice`.
     *      The two paths are separate entry points that operate on different
     *      storage (`aPNTsPriceUSD` vs `cachedPrice`); neither can be called
     *      through the other, so a caller cannot exploit one path to bypass
     *      the deviation limit of the other.
     */
    function setAPNTSPrice(uint256 newPrice) external onlyOwner {
        // APNTS_PRICE_MIN > 0, so this also rejects newPrice == 0.
        if (newPrice < APNTS_PRICE_MIN || newPrice > APNTS_PRICE_MAX) revert InvalidConfiguration();
        uint256 oldPrice = aPNTsPriceUSD;
        // Delta guard skipped when oldPrice == 0 (first write after deploy/upgrade).
        // Mitigation: always verify aPNTsPriceUSD > 0 in post-upgrade checks.
        if (oldPrice != 0) {
            uint256 lower;
            uint256 upper;
            unchecked {
                lower = oldPrice * (BPS_DENOMINATOR - APNTS_PRICE_DELTA_BPS) / BPS_DENOMINATOR;
                upper = oldPrice * (BPS_DENOMINATOR + APNTS_PRICE_DELTA_BPS) / BPS_DENOMINATOR;
            }
            if (newPrice < lower || newPrice > upper) revert InvalidConfiguration();
        }
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
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setXPNTsFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert InvalidAddress();
        emit XPNTsFactoryUpdated(xpntsFactory, _factory);
        xpntsFactory = _factory;
    }

    // ====================================
    // P0-10 — Chainlink break-glass (D8)
    // ====================================

    /// @notice True when Chainlink hasn't updated for at least
    ///         `CHAINLINK_STALE_THRESHOLD` seconds, OR when the call reverts.
    /// @dev    Stale = "operationally unusable", not "wrong". A Chainlink
    ///         revert is treated as the worst-case stale state so the break-
    ///         glass path opens.
    function _isChainlinkStale() internal view returns (bool) {
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80, int256, uint256, uint256 chainlinkUpdatedAt, uint80
        ) {
            if (chainlinkUpdatedAt == 0) return true;
            return block.timestamp > chainlinkUpdatedAt + CHAINLINK_STALE_THRESHOLD;
        } catch {
            return true;
        }
    }

    function isChainlinkStale() external view returns (bool) { return _isChainlinkStale(); }

    /// @notice Returns the timestamp after which the cached price is considered stale.
    /// @dev Returns 0 if price has never been updated. Use to check freshness off-chain.
    function priceValidUntil() external view returns (uint48) {
        if (cachedPrice.updatedAt == 0) return 0;
        return uint48(cachedPrice.updatedAt + priceStalenessThreshold);
    }

    /// @notice Queue an emergency price update. Only honored when Chainlink
    ///         is stale and the new price stays within ±20% of the last
    ///         cached price; eligible for execution after a 1-hour timelock.
    /// @dev    P0-10 (D8): pre-fix the owner break-glass path inside
    ///         `updatePriceDVT` skipped the deviation check whenever Chainlink
    ///         was unavailable, leaving a compromised owner free to write
    ///         any price. The new path enforces:
    ///           1. Chainlink must actually be stale (otherwise normal
    ///              `updatePrice` should be used);
    ///           2. New price within ±20% of `cachedPrice.price`;
    ///           3. 1-hour timelock so off-chain monitors can flag the queue
    ///              event before it lands.
    function emergencySetPrice(int256 newPrice) external onlyOwner {
        if (newPrice <= 0) revert OracleError();
        if (!_isChainlinkStale()) revert ChainlinkNotStale();
        // Prevent indefinite EMERGENCY regime: once activated, expires after 7 days.
        if (emergencyActivatedAt != 0 && block.timestamp > emergencyActivatedAt + EMERGENCY_EXPIRY) {
            revert EmergencyExpired();
        }

        int256 ref = cachedPrice.price;
        if (ref <= 0) revert OracleError();

        // Math.mulDiv is uint-only; do the band check manually with int math.
        int256 lower = (ref * int256(int256(uint256(BPS_DENOMINATOR - EMERGENCY_PRICE_DEVIATION_BPS)))) / int256(uint256(BPS_DENOMINATOR));
        int256 upper = (ref * int256(int256(uint256(BPS_DENOMINATOR + EMERGENCY_PRICE_DEVIATION_BPS)))) / int256(uint256(BPS_DENOMINATOR));
        if (newPrice < lower || newPrice > upper) revert EmergencyPriceOutOfRange();

        emergencyPendingPrice = newPrice;
        emergencyQueuedAt = block.timestamp;
        emit EmergencyPriceQueued(newPrice, block.timestamp + EMERGENCY_TIMELOCK);
    }

    /// @notice Cancel a queued emergency price. Useful when the multisig
    ///         realises the queued value is wrong before timelock elapses.
    function cancelEmergencyPrice() external onlyOwner {
        if (emergencyQueuedAt == 0) return; // idempotent
        int256 cancelled = emergencyPendingPrice;
        emergencyQueuedAt = 0;
        emergencyPendingPrice = 0;
        emit EmergencyPriceCancelled(cancelled);
    }

    /// @notice Apply a previously queued emergency price.
    /// @dev    Permissionless after the timelock — anyone can land the price,
    ///         not just the owner. The protective gates already ran inside
    ///         `emergencySetPrice` (Chainlink stale, ±20% band).
    /// @dev Permissionless: any address may execute after the 1-hour timelock expires.
    ///      This mirrors the OZ TimelockController liveness pattern — the ±20% deviation
    ///      cap limits manipulation even if an untrusted party triggers execution.
    function executeEmergencyPrice() external {
        if (emergencyQueuedAt == 0) revert NoEmergencyPending();
        if (block.timestamp < emergencyQueuedAt + EMERGENCY_TIMELOCK) {
            revert EmergencyTimelockNotElapsed();
        }

        int256 newPrice = emergencyPendingPrice;
        cachedPrice.price = newPrice;
        cachedPrice.updatedAt = block.timestamp;
        cachedPrice.roundId = 0;
        cachedPrice.decimals = 8;

        if (priceMode != 1) {
            emit PriceModeChanged(priceMode, 1);
            priceMode = 1;
            emergencyActivatedAt = block.timestamp;
        }

        emergencyQueuedAt = 0;
        emergencyPendingPrice = 0;

        emit EmergencyPriceExecuted(newPrice);
        emit PriceUpdated(newPrice, block.timestamp);
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
        _requireSuperOperatorRole();
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
     * @param chainlinkRecovered  0 = Chainlink feed still unavailable (price-only update);
     *                            1 = Chainlink feed has recovered — clears priceMode to 0
     *                                and resets emergencyActivatedAt.
     */
    function updatePriceDVT(
        int256 price,
        uint256 updatedAt,
        bytes calldata proof,
        uint8 chainlinkRecovered   // 0 = Chainlink not yet recovered; 1 = Chainlink recovered
    ) external {
        // 1. Verify caller authority
        if (msg.sender != BLS_AGGREGATOR && msg.sender != owner()) revert Unauthorized();

        // V3.6 FIX: Prevent Replay & Staleness
        if (updatedAt <= cachedPrice.updatedAt) revert OracleError(); // Must be strictly increasing
        if (updatedAt < block.timestamp - 2 hours) revert OracleError(); // Must be recent
        // P0-16 (Codex B-N1): also reject future timestamps. Without this, an
        // adversarial caller could write `updatedAt = far_future`, satisfying
        // both "strictly increasing" and "block.timestamp - 2 hours" checks,
        // freezing the cached price and underflowing the staleness check
        // downstream (block.timestamp - cachedPrice.updatedAt).
        // A 15-second grace window accommodates the ~12 s maximum drift between
        // a keeper's wall-clock and block.timestamp, preventing spurious
        // rejections of honest keepers while closing the far-future attack vector.
        if (updatedAt > block.timestamp + TIMESTAMP_GRACE_SECONDS) revert OracleError();
        
        // 2. BLS proof is verified by BLSAggregator before it calls this function.
        // Trusting msg.sender == BLS_AGGREGATOR is sufficient; owner path is an
        // emergency break-glass bypass (intentional, acknowledged risk: Chainlink ±20%
        // deviation guard below provides the secondary protection when BLS is bypassed).
        // proof is verified off-chain by BLSAggregator before it calls this function.
        // Not re-verified on-chain; msg.sender == BLS_AGGREGATOR is the trust anchor.tion.
        
        // 3. Validate price bounds
        if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();
        
        // 4. Optional: Check deviation from Chainlink (±20% tolerance)
        // This protects against DVT manipulation while allowing Chainlink downtime recovery
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80, int256 chainlinkPrice, uint256, uint256 chainlinkUpdatedAt, uint80
        ) {
            // Only check deviation if Chainlink data is recent (within 2 hours)
            // P1-42: guard chainlinkPrice <= 0 to prevent div-by-zero
            if (chainlinkPrice > 0 && block.timestamp - chainlinkUpdatedAt < 2 hours) {
                int256 deviation = price > chainlinkPrice
                    ? (price - chainlinkPrice) * 100 / chainlinkPrice
                    : (chainlinkPrice - price) * 100 / chainlinkPrice;
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

        // If Chainlink has been confirmed recovered, exit emergency mode.
        if (chainlinkRecovered == 1 && priceMode != 0) {
            emit PriceModeChanged(priceMode, 0);
            priceMode = 0;
            emergencyActivatedAt = 0;
        }

        emit PriceUpdated(price, updatedAt);
    }

    /**
     * @notice Deposit aPNTs (Legacy Pull Mode)
     * @dev Only works if APNTS_TOKEN allows transferFrom (e.g. old token or whitelisted)
     */
    /// @notice Deposit xPNTs tokens from msg.sender into their own operator balance.
    function deposit(uint256 amount) external nonReentrant {
        _requireSuperOperatorRole();
        // This might revert if Token blocks transferFrom (Secure Token)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _creditDeposit(msg.sender, amount);
    }

    /// @dev Shared deposit accounting: overflow-check, credit operator balance,
    ///      bump totalTrackedBalance, emit. Used by deposit/onTransferReceived/depositFor.
    function _creditDeposit(address operator, uint256 amount) internal {
        // Check overflow for uint128
        if (amount > type(uint128).max) revert AmountExceedsUint128();
        // casting to 'uint128' is safe because of the check above
        // forge-lint: disable-next-line(unsafe-typecast)
        operators[operator].aPNTsBalance += uint128(amount);
        // Update tracked balance to keep sync with manual transfers
        totalTrackedBalance += amount;
        emit OperatorDeposited(operator, amount);
    }

    // ====================================
    // Push Deposit & Views (Restored)
    // ====================================

    /**
     * @notice Handle ERC1363 transferAndCall (Push Mode)
     * @dev Safe deposit mechanism for tokens blocking transferFrom
     */
    function onTransferReceived(address, address from, uint256 value, bytes calldata) external nonReentrant returns (bytes4) {
        if (msg.sender != APNTS_TOKEN) revert Unauthorized();

        // Ensure operator is registered
        _requireSuperOperatorRoleFor(from);

        _creditDeposit(from, value);

        return this.onTransferReceived.selector;
    }

    /**
     * @notice Deposit aPNTs for a specific operator (Secure Push Mode)
     * @param targetOperator The operator to credit the deposit to
     * @param amount Amount of aPNTs
     */
    /// @notice Deposit xPNTs tokens on behalf of a specific operator address.
    function depositFor(address targetOperator, uint256 amount) external nonReentrant {
        _requireSuperOperatorRoleFor(targetOperator);
        // Transfer from sender (must approve first)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _creditDeposit(targetOperator, amount);
    }




    /**
     * @notice Withdraw aPNTs
     * @dev M-5: Reverts when a slash has been queued for this operator via
     *      queueSlash(). The slash must be executed (or cancelled) before the
     *      operator can withdraw, closing the front-run window where an operator
     *      could observe a pending slash TX in the mempool and drain their balance
     *      before it lands.
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (_pendingSlash[msg.sender]) revert SlashPending();
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
        // P1-2: leave PROTOCOL_REVENUE_BUFFER unwithdrawable to absorb in-flight postOp refunds.
        // Without this, an owner withdrawal between validate and postOp drains the pool,
        // causing ProtocolRevenueUnderflow and reducing the operator's refund.
        uint256 available = protocolRevenue > PROTOCOL_REVENUE_BUFFER
            ? protocolRevenue - PROTOCOL_REVENUE_BUFFER
            : 0;
        if (amount > available) revert InsufficientRevenue();

        protocolRevenue -= amount;
        totalTrackedBalance -= amount;
        IERC20(APNTS_TOKEN).safeTransfer(to, amount);

        emit ProtocolRevenueWithdrawn(to, amount);
    }

    /// @notice Remaining credit headroom for `user` on `token` (saturating; spec §10.4 / R4-H4).
    /// @dev    Delegates to the token's single canonical ceiling (C-0) and includes live reservations.
    function getAvailableCredit(address user, address token) external view returns (uint256) {
        IxPNTsTokenV2 t = IxPNTsTokenV2(token);
        uint256 cap = t.effectiveCreditCap(user);
        uint256 used = t.debts(user) + t.creditReservedOf(user);
        return cap > used ? cap - used : 0;
    }

    // ====================================
    // Reputation & Slash Management (Restored)
    // ====================================

    /**
     * @notice Mark an operator as having a pending slash (owner or BLS aggregator only).
     * @dev M-5: Called as a first step before executing slashOperator or
     *      executeSlashWithBLS. Once set, the operator's withdraw() is blocked until
     *      the slash executes or is cancelled. This closes the front-run window: the
     *      owner/aggregator queues the flag in one TX; by the time that TX is mined
     *      the operator can no longer drain their balance before the slash lands.
     *      Calling queueSlash when already pending is idempotent (no revert).
     */
    function queueSlash(address operator) external {
        if (msg.sender != owner() && msg.sender != BLS_AGGREGATOR) revert Unauthorized();
        // CC-13: block the BLS/DVT path from re-arming a slash while the cooldown is active.
        // Otherwise a raced duplicate (a different-epoch re-queue that the aggregator replay-guard
        // cannot dedupe) would leave _pendingSlash=true parked; once the window lapses that stale
        // flag would let a second slash execute for the same violation with no fresh queue. Gating
        // the re-arm here — not just the execution — is what actually prevents the double-slash.
        // Owner (trusted governance) may still queue; its slashOperator path carries its own cooldown.
        // Uses the dedicated BLS cooldown (F2) so the owner path's 24h cooldown never blocks DVT.
        if (msg.sender == BLS_AGGREGATOR && uint48(block.timestamp) < _blsCooldownEnd(operator)) revert SlashCooldown();
        _pendingSlash[operator] = true;
        emit SlashQueued(operator);
    }

    /// @dev Effective end of the BLS-slash cooldown for `operator`: the later of the per-operator
    ///      cooldown and the global post-upgrade floor (`_blsSlashCdFloor`). The floor closes the
    ///      cold-start window right after the 5.4.2 upgrade (see `primeBlsSlashCooldown`).
    function _blsCooldownEnd(address operator) internal view returns (uint48) {
        uint48 cd = _blsSlashCd[operator];
        uint48 fl = _blsSlashCdFloor;
        return fl > cd ? fl : cd;
    }

    /// @notice One-shot prime of the global BLS-slash cooldown floor to `now + SLASH_BLS_COOLDOWN`.
    /// @dev    Owner-only. Called atomically from the 5.4.2 upgrade (upgradeToAndCall data) so that,
    ///         immediately after the impl swap, no operator can be BLS-slashed for the cooldown
    ///         window — covering any operator that was slashed shortly before the upgrade and thus
    ///         has no per-operator `_blsSlashCd` recorded. Idempotent and harmless to re-call.
    function primeBlsSlashCooldown() external onlyOwner {
        _blsSlashCdFloor = uint48(block.timestamp) + SLASH_BLS_COOLDOWN;
        emit BlsSlashCooldownPrimed(_blsSlashCdFloor);
    }

    /**
     * @notice Cancel a previously queued slash (owner only).
     * @dev Allows the owner to unblock an operator's withdraw if the slash was
     *      queued in error.  Idempotent when no slash is pending.
     */
    function cancelSlash(address operator) external onlyOwner {
        _pendingSlash[operator] = false;
        emit SlashCancelled(operator);
    }

    /**
     * @notice Whether `operator` currently has a slash queued (withdraw-blocking flag set).
     * @dev O(1) authoritative read of the private `_pendingSlash` flag. DVT peers use this
     *      for failover — when the node that queued a slash dies before executing, another
     *      peer detects the pending state and continues to execute rather than re-queuing
     *      (which the aggregator replay-guard would reject). Replaces off-chain reconstruction
     *      from SlashQueued/SlashCancelled/OperatorSlashed events.
     */
    function isSlashPending(address operator) external view returns (bool) {
        return _pendingSlash[operator];
    }

    /**
     * @notice Slash an operator (Admin/Governance only)
     * @dev Reduces reputation and optionally pauses operator.
     *      Clears the pending-slash flag so the operator can withdraw again after.
     */
    function slashOperator(address operator, ISuperPaymaster.SlashLevel level, uint256 penaltyAmount, string calldata reason) external onlyOwner {
        // HIGH-1: enforce two-step slash — queueSlash must precede execution to block operator front-run.
        require(_pendingSlash[operator], "SP: must queueSlash first");
        // P0-14: 30% cap + 24h cooldown — prevents owner from draining operator in a single tx.
        if (uint48(block.timestamp) < _slashCd[operator]) revert SlashCooldown();
        _slashCd[operator] = uint48(block.timestamp) + 24 hours;
        _slash(operator, level, penaltyAmount, reason, true);
        // M-5: clear pending-slash guard after execution so withdraw is unblocked.
        _pendingSlash[operator] = false;
    }

    /**
     * @notice Update Operator Reputation (External Credit Manager)
     */
    function updateReputation(address operator, uint256 newScore) external onlyOwner {
        if (newScore > type(uint32).max) revert ScoreExceedsUint32();
        operators[operator].reputation = uint32(newScore);
        emit ReputationUpdated(operator, newScore);
    }



    /**
     * @notice Execute slash triggered by BLS consensus (DVT Module only)
     * @dev M-5: Clears the pending-slash flag after execution so withdraw is unblocked.
     */
    function executeSlashWithBLS(address operator, ISuperPaymaster.SlashLevel level, bytes calldata proof) external override {
        if (msg.sender != BLS_AGGREGATOR) revert Unauthorized();
        // HIGH-1: enforce two-step slash — queueSlash must precede execution to block operator front-run.
        require(_pendingSlash[operator], "SP: must queueSlash first");
        // CC-13: establish the anti-double-slash cooldown window (the primary re-arm gate lives in
        // queueSlash, which blocks the BLS path from parking a stale pending flag during the window).
        // The check here is defense-in-depth for any path that arms _pendingSlash within the window
        // (e.g. an owner queue followed by a BLS execute); the set records the window start.
        // Dedicated BLS cooldown (F2) — decoupled from the owner path's _slashCd; includes the
        // global post-upgrade floor (_blsCooldownEnd) so the cold-start window is covered.
        if (uint48(block.timestamp) < _blsCooldownEnd(operator)) revert SlashCooldown();
        _blsSlashCd[operator] = uint48(block.timestamp) + SLASH_BLS_COOLDOWN;

        // Logical penalty before cap: Warning=0, Minor=10%, Major=full balance.
        // Major is further capped at 30% inside _slash (applyCap=true).
        uint256 penalty = 0;
        if (level == ISuperPaymaster.SlashLevel.MINOR) {
            penalty = operators[operator].aPNTsBalance / 10;
        } else if (level == ISuperPaymaster.SlashLevel.MAJOR) {
            penalty = operators[operator].aPNTsBalance;
        }

        // Store proof hash for audit traceability
        bytes32 proofHash = keccak256(proof);

        _slash(operator, level, penalty, "DVT BLS Slash", true);
        // M-5: clear pending-slash guard after execution.
        _pendingSlash[operator] = false;

        // Emit event with proof hash
        emit SlashExecutedWithProof(operator, level, penalty, proofHash, block.timestamp);
    }

    /// @param applyCap If true, enforce 30% slash hardcap (BLS/DVT path). If false, no cap (owner governance).
    function _slash(address operator, ISuperPaymaster.SlashLevel level, uint256 penaltyAmount, string memory reason, bool applyCap) internal {
        ISuperPaymaster.OperatorConfig storage config = operators[operator];

        uint256 reputationLoss = level == ISuperPaymaster.SlashLevel.WARNING ? 10 : (level == ISuperPaymaster.SlashLevel.MINOR ? 20 : 50);
        if (level == ISuperPaymaster.SlashLevel.MAJOR) config.isPaused = true;

        if (config.isPaused) {
             emit OperatorPaused(operator);
        }

        if (config.reputation > reputationLoss) config.reputation -= uint32(reputationLoss);
        else config.reputation = 0;

        if (penaltyAmount > 0) {
            if (applyCap) {
                // V3.6 SECURITY: Enforce 30% Slash Hardcap for automated (BLS/DVT) slashing
                uint256 maxSlash = (uint256(config.aPNTsBalance) * 3000) / BPS_DENOMINATOR;
                if (penaltyAmount > maxSlash) {
                    penaltyAmount = maxSlash;
                    reason = string(abi.encodePacked(reason, " (Capped at 30%)"));
                }
            }

            if (config.aPNTsBalance >= penaltyAmount) {
                config.aPNTsBalance -= uint128(penaltyAmount);
                protocolRevenue += penaltyAmount;
            } else {
                uint256 actualBurn = config.aPNTsBalance;
                config.aPNTsBalance = 0;
                protocolRevenue += actualBurn;
                penaltyAmount = actualBurn;
            }
        }

        slashHistory[operator].push(ISuperPaymaster.SlashRecord({
            timestamp: block.timestamp,
            amount: penaltyAmount,
            reputationLoss: reputationLoss,
            reason: reason,
            level: level
        }));

        emit OperatorSlashed(operator, penaltyAmount, level);
        emit ReputationUpdated(operator, config.reputation);
    }

    // P0-3 (initial-deploy path): one-time setter for fresh deploys where BLS_AGGREGATOR == address(0).
    // The 24h timelock (queueBLSAggregator / applyBLSAggregator) only applies to REPLACEMENTS;
    // a fresh deployment has no aggregator to protect, so no delay is needed.
    function initBLSAggregator(address _bls) external onlyOwner {
        if (BLS_AGGREGATOR != address(0)) revert InvalidConfiguration(); // already initialized — use queue/apply
        if (_bls == address(0)) revert InvalidAddress();
        BLS_AGGREGATOR = _bls;
        emit BLSAggregatorUpdated(address(0), _bls);
    }

    // P0-3: 24h timelock on BLSAggregator replacement — prevents instant governance takeover.
    function queueBLSAggregator(address _bls) external onlyOwner {
        if (_bls == address(0)) revert InvalidAddress();
        pendingBLSAgg = _bls;
        pendingBLSAggEta = uint48(block.timestamp + 24 hours);
        emit BLSAggregatorQueued(_bls, pendingBLSAggEta);
    }

    function applyBLSAggregator() external onlyOwner {
        address p = pendingBLSAgg;
        if (p == address(0)) revert InvalidConfiguration();
        if (uint48(block.timestamp) < pendingBLSAggEta) revert InvalidConfiguration();
        address old = BLS_AGGREGATOR;
        BLS_AGGREGATOR = p;
        pendingBLSAgg = address(0);
        pendingBLSAggEta = 0;
        emit BLSAggregatorUpdated(old, p);
    }

    // ====================================
    // Slash Query Interfaces
    // ====================================

    function getSlashHistory(address operator) external view returns (ISuperPaymaster.SlashRecord[] memory) {
        return slashHistory[operator];
    }

    function getSlashCount(address operator) external view returns (uint256) {
        return slashHistory[operator].length;
    }

    function getLatestSlash(address operator) external view returns (ISuperPaymaster.SlashRecord memory) {
        if (slashHistory[operator].length == 0) revert NoSlashHistory();
        return slashHistory[operator][slashHistory[operator].length - 1];
    }

    // ====================================
    // Paymaster Implementation
    // ====================================

    /// @notice Update price cache from Chainlink oracle (keeper-callable).
    /// @dev No future-timestamp guard is needed on this path: `updatedAt` is
    ///      read directly from a validated Chainlink response, not supplied by
    ///      an untrusted caller. Chainlink nodes always set `updatedAt` to the
    ///      block timestamp of the round, which is always <= block.timestamp at
    ///      the time of the call. The existing staleness check
    ///      (`updatedAt < block.timestamp - priceStalenessThreshold`) already
    ///      rejects data that is too old; a Chainlink answer with a future
    ///      `updatedAt` is practically impossible (it would require a Chainlink
    ///      node to report a timestamp ahead of on-chain time) and would be
    ///      caught by the staleness check inverting direction. Contrast with
    ///      `updatePriceDVT`, where `updatedAt` is caller-supplied and
    ///      therefore requires an explicit future-timestamp guard (P0-16).
    function updatePrice() external {
        // 1. Try to get Price from Chainlink with automatic degradation
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Chainlink success: validate and update
            if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();
            if (updatedAt < block.timestamp - priceStalenessThreshold) revert OracleError();
            if (answeredInRound < roundId) revert OracleError();

            // 2. Update Cache
            cachedPrice = PriceCache({
                price: price,
                updatedAt: updatedAt,
                roundId: roundId,
                decimals: 8
            });

            // P0-10: Chainlink came back. If we previously flipped into
            // EMERGENCY mode via the break-glass path, transition back to
            // CHAINLINK now that fresh data is landing on-chain. Any pending
            // emergency price is also cleared — once Chainlink is healthy the
            // queued override is no longer the right answer.
            if (priceMode != 0) {
                emit PriceModeChanged(priceMode, 0);
                priceMode = 0;
                emergencyActivatedAt = 0;
            }
            if (emergencyQueuedAt != 0) {
                int256 cancelled = emergencyPendingPrice;
                emergencyQueuedAt = 0;
                emergencyPendingPrice = 0;
                emit EmergencyPriceCancelled(cancelled);
            }

            emit PriceUpdated(price, updatedAt);
        } catch {
            // Chainlink down: revert to signal need for DVT fallback or
            // emergency setPrice. Keeper should call updatePriceDVT() with BLS
            // proof, or owner can use emergencySetPrice + executeEmergencyPrice.
            revert OracleError();
        }
    }
    function _calculateAPNTsAmount(uint256 ethAmountWei) internal view returns (uint256) {
        PriceCache memory cache = cachedPrice;
        int256 ethUsdPrice = cache.price;
        if (ethUsdPrice <= 0) revert OracleError();
        return Math.mulDiv(
            ethAmountWei * uint256(ethUsdPrice),
            1e18,
            (10**uint256(cache.decimals)) * aPNTsPriceUSD,
            Math.Rounding.Ceil
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

        // Initialize Validation Times
        // V3.6 FIX: Return validUntil to enforce Staleness Check and validAfter for Rate Limit
        uint48 validUntil = uint48(cachedPrice.updatedAt + priceStalenessThreshold);
        uint48 validAfter = 0;
        
        // Check 2: Must not be Paused
        if (config.isPaused) {
             return ("", _packValidationData(true, 0, 0)); 
        }

        // V5.3: Dual-channel identity check (SBT holder OR ERC-8004 Agent NFT)
        if (!isEligibleForSponsorship(userOp.sender)) {
             return ("", _packValidationData(true, 0, 0));
        }

        // C-04: reject a paymasterPostOpGasLimit too low for postOp to complete.
        // Without this an attacker forces postOp OOG and the optimistic operator
        // debit (below) is never refunded → operator drain + revenue inflation.
        // exp/params: one SLOAD of SP's own slot (staked, STO-031); snapshotted into the context.
        uint256 gpRaw = _gpRaw();
        if (userOp.paymasterAndData.length >= POSTOP_GAS_OFFSET + 16) {
            uint128 pmPostOpGas = uint128(bytes16(userOp.paymasterAndData[POSTOP_GAS_OFFSET:POSTOP_GAS_OFFSET + 16]));
            if (pmPostOpGas < uint32(gpRaw)) {
                return ("", _packValidationData(true, 0, 0));
            }
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
            // V3.6 FIX: Use validAfter to enforce rate limit instead of reverting on block.timestamp
            if (lastTime != 0) {
                 validAfter = lastTime + config.minTxInterval;
            }
        }

        // 2.1 Token binding + rate commitment (R4-H1; rug-pull protection)
        bytes calldata pmd = userOp.paymasterAndData;
        if (pmd.length < TOKEN_OFFSET + 20) return ("", _packValidationData(true, 0, 0));
        address token = address(bytes20(pmd[TOKEN_OFFSET:TOKEN_OFFSET + 20]));
        if (token != config.xPNTsToken) return ("", _packValidationData(true, 0, 0));
        uint8 flags = pmd.length > FLAGS_OFFSET ? uint8(pmd[FLAGS_OFFSET]) : 0;
        if (flags & (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW) == (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW)) {
            return ("", _packValidationData(true, 0, 0));
        }
        uint256 maxRate = abi.decode(pmd[RATE_OFFSET:RATE_OFFSET + 32], (uint256));
        // §3.3: every token call fails CLOSED → sigFail (AA34), never a validation revert (AA33)
        (bool rateOk, uint256 rate) = _tokenWord(token, abi.encodeCall(IxPNTsTokenV2.exchangeRate, ()), true, 32);
        if (!rateOk || rate > maxRate) return ("", _packValidationData(true, 0, 0));

        // 3. Reservation a0 (spec §10.3): full maxCost at the cached price, + fee + validation buffer
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);
        uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS + VALIDATION_BUFFER_BPS;
        aPNTsAmount = Math.mulDiv(aPNTsAmount, totalRate, BPS_DENOMINATOR, Math.Rounding.Ceil);

        // 4. Operator solvency — checked BEFORE touching the token
        if (uint256(config.aPNTsBalance) < aPNTsAmount) {
             return ("", _packValidationData(true, 0, 0));
        }

        // 5. User side: escrow first, credit only on INSUFFICIENT (R-2)
        uint8 mode = _reserveForOp(token, userOp.sender, userOpHash, aPNTsAmount, flags & FLAG_SP_RENEW != 0);
        if (mode == MODE_NONE) return ("", _packValidationData(true, 0, 0));

        // 6. Operator side: a0 is IN FLIGHT, not revenue, until postOp settles (R10-M1b)
        config.aPNTsBalance -= uint128(aPNTsAmount); // Safe cast due to check above
        config.totalSpent += aPNTsAmount;
        _inflight[userOpHash] = Inflight(operator, uint96(aPNTsAmount));
        _setInflightLive(userOpHash, true);

        PriceCache memory pc = cachedPrice;
        context = abi.encode(OpCtxOut({
            token: token,
            user: userOp.sender,
            a0: aPNTsAmount,
            opHash: userOpHash,
            operator: operator,
            mode: mode,
            callGas: uint128(uint256(userOp.accountGasLimits)),
            postOpGas: uint128(bytes16(pmd[POSTOP_GAS_OFFSET:POSTOP_GAS_OFFSET + 16])),
            price: pc.price,
            decimals: pc.decimals,
            aPriceUSD: aPNTsPriceUSD,
            gasSnap: gpRaw
        }));
        return (context, _packValidationData(false, validUntil, validAfter));
    }

    /// @dev Escrow-then-credit decision (spec §1). Any token failure → no sponsorship (H3-1).
    function _reserveForOp(address token, address user, bytes32 opHash, uint256 a0, bool spRenew)
        internal returns (uint8)
    {
        (bool ok, uint256 r) = _tokenWord(token, abi.encodeCall(IxPNTsTokenV2.tryLockForGas, (user, opHash, a0, spRenew)), false, 64);
        if (!ok) return MODE_NONE;
        if (r == uint256(IxPNTsTokenV2.LockResult.OK)) return MODE_BALANCE;
        if (r != uint256(IxPNTsTokenV2.LockResult.INSUFFICIENT)) return MODE_NONE;
        (ok, r) = _tokenWord(token, abi.encodeCall(IxPNTsTokenV2.tryReserveCredit, (user, opHash, a0)), false, 32);
        return ok && r == uint256(IxPNTsTokenV2.CreditResult.OK) ? MODE_CREDIT : MODE_NONE;
    }

    /// @dev Validation-time token call that can only fail CLOSED (§3.3, Codex D3): a revert, a
    ///      return shorter than the function's full ABI return (`minLen`: 64 for tryLockForGas's
    ///      two words, 32 otherwise), or any out-of-range first word is reported as `ok = false`
    ///      or a value the caller rejects — never a revert in SP. Copies at most 32 bytes of
    ///      return data (no return-bomb). A typed `try … returns (…)` would still revert on
    ///      malformed success data, because its decoding happens in the caller outside the catch.
    function _tokenWord(address token, bytes memory data, bool isStatic, uint256 minLen)
        private returns (bool ok, uint256 w)
    {
        assembly ("memory-safe") {
            switch isStatic
            case 1 { ok := staticcall(gas(), token, add(data, 32), mload(data), 0, 32) }
            default { ok := call(gas(), token, 0, add(data, 32), mload(data), 0, 32) }
            if lt(returndatasize(), minLen) { ok := 0 }
            w := mload(0)
        }
    }

    // dryRunValidation moved to SuperPaymasterLens in 5.5.0 (spec F1 / §5: EIP-170 headroom).

    function postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint nonReentrant {
        if (context.length == 0) return;
        // B-1 §10.1 ③: never START a settlement that could run out of gas half-way. Reverting here
        // rolls back the user's execution (EntryPoint v0.7 innerHandleOp), so nothing is kept unpaid.
        // exp/params: the bound is the VALIDATION-time snapshot (trailing word 12), read before
        // decoding and ONLY for a 384-byte context; the admitted limit satisfied MIN_v >= SETTLE_v +
        // 20k, so a parameter change executed mid-bundle cannot move it. Any other length (a 5.5.0
        // context: 352 B) has no snapshot and keeps the 5.5.0 bound.
        uint256 snap;
        if (context.length == CTX_LEN) {
            assembly ("memory-safe") { snap := calldataload(add(context.offset, 352)) }
        }
        uint256 snapSettle = uint32(snap >> 32);
        if (gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)) revert PostOpGasTooLow();

        OpCtx memory c = abi.decode(context, (OpCtx));

        // V3.6: rate-limit timestamp ALWAYS (griefing defence), even if the op reverted.
        if (operators[c.operator].minTxInterval > 0) {
            userOpState[c.operator][c.user].lastTimestamp = uint48(block.timestamp);
        }

        // P1-17 idempotency guard: set before all accounting.
        if (_settledDebtOps[c.opHash]) return;
        _settledDebtOps[c.opHash] = true;
        operators[c.operator].totalTxSponsored++;

        // R10-M3: conservative charge in wei, priced at the VALIDATION-time snapshot.
        // snapshot: C_POSTOP + C_WRAP of the validation; 5.5.0 context: the 5.5.0 formula itself
        // (postOpGasLimit + LEGACY_C_WRAP), i.e. exactly what that op was admitted and quoted under.
        uint256 bufGas = snap == 0
            ? uint256(c.postOpGas) + LEGACY_C_WRAP_GAS
            : uint256(uint32(snap >> 96)) + uint32(snap >> 64);
        uint256 bufWei = (bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)) * actualUserOpFeePerGas;
        uint256 aGas = Math.mulDiv(
            (actualGasCost + bufWei) * uint256(c.price), 1e18, (10 ** uint256(c.decimals)) * c.aPriceUSD, Math.Rounding.Ceil
        );
        uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
        if (charge > c.a0) charge = c.a0;

        // B-1 §10.1 ①: NO try/catch. A failed settlement reverts postOp → EntryPoint rolls back
        // the user's execution; the escrow/reservation is then released after the transaction.
        if (c.mode == MODE_BALANCE) {
            IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge);
        } else {
            IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge);
        }

        // R10-M1b: in-flight a0 → revenue c, refund (a0 − c) to the operator. No shared-pool clamp.
        delete _inflight[c.opHash];
        _setInflightLive(c.opHash, false);
        operators[c.operator].aPNTsBalance += uint128(c.a0 - charge);
        protocolRevenue += charge;

        emit TransactionSponsored(c.operator, c.user, aGas, charge);
    }

    // ---- exp/params: governable gas parameters ----

    /// @dev Effective parameters; an all-zero slot (fresh proxy or pre-exp upgrade) = the defaults.
    /// @dev The GasParams slot as one word (minPostOpGas | settle << 32 | cWrap << 64 | cPostop << 96);
    ///      an all-zero slot (never set / pre-exp proxy) = the defaults.
    function _gpRaw() internal view returns (uint256 raw) {
        assembly ("memory-safe") { raw := sload(_gasParams.slot) }
        if (raw == 0) {
            raw = MIN_POST_OP_GAS | (SETTLE_GAS_BOUND << 32) | (C_WRAP_GAS << 64) | (C_POSTOP_GAS << 96);
        }
    }

    function _gp() internal view returns (GasParams memory p) {
        uint256 r = _gpRaw();
        p = GasParams(uint32(r), uint32(r >> 32), uint32(r >> 64), uint32(r >> 96));
    }

    function _checkGasParams(uint256 minPost, uint256 settle, uint256 cWrap, uint256 cPostop) private pure {
        if (settle < GP_SETTLE_MIN || settle > GP_SETTLE_MAX
            || minPost < settle + GP_MINPOST_OVER_SETTLE || minPost > GP_MINPOST_MAX
            || cPostop < GP_CPOSTOP_MIN || cPostop > minPost
            || cWrap < GP_CWRAP_MIN || cWrap > GP_CWRAP_MAX) revert InvalidConfiguration();
    }

    /// @notice Queue new gas parameters; effective after GP_TIMELOCK via `executeGasParams`.
    function queueGasParams(uint32 minPostOpGas, uint32 settleGasBound, uint32 cWrap, uint32 cPostop) external onlyOwner {
        _checkGasParams(minPostOpGas, settleGasBound, cWrap, cPostop);
        uint64 eta = uint64(block.timestamp + GP_TIMELOCK);
        _pendingGasParams = PendingGasParams(minPostOpGas, settleGasBound, cWrap, cPostop, eta);
        emit GasParamsQueued(minPostOpGas, settleGasBound, cWrap, cPostop, eta);
    }

    /// @notice Owner-only. NOT relied upon for mid-bundle safety: an owner such as a
    ///         TimelockController with an open executor role can be driven from inside a user op.
    ///         Safety comes from the OpCtx snapshot (settleGasBound, cPostop, cWrap).
    function executeGasParams() external onlyOwner {
        PendingGasParams memory q = _pendingGasParams;
        if (q.eta == 0 || block.timestamp < q.eta) revert GasParamsTimelock();
        _checkGasParams(q.minPostOpGas, q.settleGasBound, q.cWrap, q.cPostop);
        _gasParams = GasParams(q.minPostOpGas, q.settleGasBound, q.cWrap, q.cPostop);
        delete _pendingGasParams;
        emit GasParamsExecuted(q.minPostOpGas, q.settleGasBound, q.cWrap, q.cPostop);
    }

    function cancelGasParams() external onlyOwner {
        if (_pendingGasParams.eta == 0) revert GasParamsTimelock();
        delete _pendingGasParams;
        emit GasParamsCancelled();
    }

    /// @notice Effective parameters (defaults when never set) and the pending proposal.
    function gasParams() external view returns (GasParams memory current, PendingGasParams memory pending) {
        return (_gp(), _pendingGasParams);
    }

    /// @notice R10-M1b: after the original transaction, restore an operator's in-flight a0 whose
    ///         postOp never completed (a postOp revert also rolled back the user's execution).
    ///         Permissionless and idempotent. The EntryPoint ETH for that op stays spent (I10).
    function releaseStaleSponsorship(bytes32 opHash) external {
        Inflight memory f = _inflight[opHash];
        if (f.operator == address(0)) return;
        if (_isInflightLive(opHash)) revert SponsorshipInFlight();
        delete _inflight[opHash];
        operators[f.operator].aPNTsBalance += uint128(f.a0);
        emit SponsorshipReleased(opHash, f.operator, f.a0);
    }

    function inflightOf(bytes32 opHash) external view returns (address operator, uint256 a0) {
        Inflight memory f = _inflight[opHash];
        return (f.operator, f.a0);
    }

    function _inflightSlot(bytes32 opHash) private pure returns (bytes32) {
        return keccak256(abi.encode(opHash, INFLIGHT_SEED));
    }

    function _setInflightLive(bytes32 opHash, bool on) private {
        bytes32 slot = _inflightSlot(opHash);
        uint256 v = on ? 1 : 0;
        assembly { tstore(slot, v) }
    }

    function _isInflightLive(bytes32 opHash) private view returns (bool live) {
        bytes32 slot = _inflightSlot(opHash);
        assembly { live := tload(slot) }
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


    // ====================================
    // V5 Storage: Agent Sponsorship & x402
    // ====================================

    // ERC-8004 Agent Registries
    address public agentIdentityRegistry;
    address public agentReputationRegistry;

    // v5.4 god-split phase 1: the x402 settlement layer (setters + settle logic) was
    // extracted into the standalone X402Facilitator contract. Its 4 storage slots are
    // KEPT here as `private __deprecated_*` placeholders — NOT deleted — so this UUPS
    // proxy's storage layout stays BYTE-IDENTICAL to the pre-split (deployed) layout.
    // Deleting them would shift every following variable (pendingAPNTsToken, timelock,
    // BLS-aggregator, etc.) down by 4 slots and brick any in-place upgrade of the live
    // proxy. `private` => no getter => zero runtime bytecode (the size win came from
    // deleting the x402 FUNCTIONS, not these slots). Original names/types/order:
    //   facilitatorFeeBPS, operatorFacilitatorFees, x402SettlementNonces, facilitatorEarnings.
    uint256 private __deprecated_x402_facilitatorFeeBPS;
    mapping(address => uint256) private __deprecated_x402_operatorFacilitatorFees;
    mapping(bytes32 => bool) private __deprecated_x402_settlementNonces;
    mapping(address => mapping(address => uint256)) private __deprecated_x402_facilitatorEarnings;

    // P0-9: Timelock variables — appended after all V5 storage to avoid slot collisions.
    /// @notice Pending APNTS_TOKEN swap; address(0) when none queued.
    address public pendingAPNTsToken;
    /// @notice Earliest timestamp at which `executeAPNTsTokenChange` may run.
    uint256 public pendingAPNTsTokenEta;

    // P0-14: per-operator slash cooldown (24h between owner slashes of same operator).
    mapping(address => uint48) private _slashCd;

    // P0-3: BLSAggregator 24h timelock (packed into 1 slot: address 20B + uint48 6B).
    address public pendingBLSAgg;
    uint48 public pendingBLSAggEta;

    // V5 Events
    event AgentRegistriesUpdated(address identityRegistry, address reputationRegistry);

    // V5 Errors
    // P0-14
    error SlashCooldown();
    // P0-3
    event BLSAggregatorQueued(address indexed pending, uint48 eta);

    // P0-15: dryRunValidation reason codes (internal — SDKs should hardcode bytes32 values).
    // DRYRUN_* reason codes live in SuperPaymasterLens since 5.5.0.

    // ====================================
    // V5: Admin Setters
    // ====================================

    /// @notice Set ERC-8004 agent registries (Owner only)
    /// @dev ERC-7562 constraint: _identity is called via isRegisteredAgent(sender) inside
    ///      validatePaymasterUserOp. The contract MUST be ERC-7562 compliant:
    ///      (1) no banned opcodes (TIMESTAMP, NUMBER, BLOCKHASH, ORIGIN, etc.),
    ///      (2) isRegisteredAgent() reads only sender-associated storage slots.
    ///      Requires IAgentIdentityRegistry.isRegisteredAgent() — generic ERC-721s
    ///      are NOT accepted since any NFT holder would qualify as an agent.
    ///      Non-compliant registries cause bundlers to reject all agent-sponsored
    ///      UserOps. Pass address(0) to disable agent sponsorship (SBT-only mode).
    function setAgentRegistries(address _identity, address _reputation) external onlyOwner {
        if (_identity != address(0) && _identity.code.length == 0) revert InvalidAddress();
        if (_reputation != address(0) && _reputation.code.length == 0) revert InvalidAddress();
        agentIdentityRegistry = _identity;
        agentReputationRegistry = _reputation;
        emit AgentRegistriesUpdated(_identity, _reputation);
    }

    // v5.4 god-split phase 1: the x402 facilitator-fee admin setters
    // (setFacilitatorFeeBPS, setOperatorFacilitatorFee, getEffectiveFacilitatorFee,
    // withdrawFacilitatorEarnings) moved to the standalone X402Facilitator contract.

    // ====================================
    // F1: Agent Sponsorship Policy
    // ====================================

    /// @notice V5.3: Dual-channel eligibility — SBT holder OR registered ERC-8004 agent
    function isEligibleForSponsorship(address user) public view returns (bool) {
        return sbtHolders[user] || isRegisteredAgent(user);
    }

    /// @notice Check if an address is a registered ERC-8004 agent
    /// @dev Called inside validatePaymasterUserOp. ERC-7562 §3.2 permits this
    ///      external call because isRegisteredAgent(account) reads only
    ///      sender-associated storage, satisfying the "associated storage" rule.
    ///      Using the dedicated isRegisteredAgent() rather than generic balanceOf()
    ///      ensures only ERC-8004 compliant registries qualify — not arbitrary ERC-721s.
    ///      try/catch degrades gracefully if the registry is self-destructed or buggy.
    function isRegisteredAgent(address account) public view returns (bool) {
        address reg = agentIdentityRegistry;
        if (reg == address(0)) return false;
        try IAgentIdentityRegistry(reg).isRegisteredAgent(account) returns (bool registered) {
            return registered;
        } catch {
            return false;
        }
    }

    // ====================================
    // Storage Gap (UUPS upgrade safety)
    // ====================================

    /// @notice P1-17: SP-level guard — once a (token, opHash) pair has entered
    ///         _recordDebt, no retry can re-enter regardless of which path
    ///         (burn, recordDebt, pendingDebts) the first call took.  Closes the
    ///         pendingDebts fallback double-charge scenario that xPNTs-level
    ///         cross-checks alone cannot prevent.
    mapping(bytes32 => bool) internal _settledDebtOps;

    // M-5: per-operator pending-slash guard. True while a slash has been queued via
    // queueSlash() but not yet executed or cancelled. withdraw() reverts while this is
    // set, closing the front-run window where an operator could observe a pending slash
    // TX in the mempool and drain their balance before it lands.
    mapping(address => bool) private _pendingSlash;

    // CC-13 (F2): dedicated cooldown for the BLS/DVT slash path, SEPARATE from the owner path's
    // `_slashCd` (24h). Sharing one mapping coupled the paths — an owner slash (writes +24h) would
    // block the DVT path for up to 24h, stalling a legitimate MINOR→MAJOR escalation. Appended at
    // the end of storage (UUPS-safe: existing slots unchanged). This is the FIRST of two slots this
    // upgrade appends (with `_blsSlashCdFloor` below); together __gap goes 30→28 — see below.
    mapping(address => uint48) private _blsSlashCd;

    // CC-13: global BLS-slash cooldown floor. `primeBlsSlashCooldown()` sets it to now+cooldown
    // atomically during the 5.4.2 upgrade. This closes the cold-start window: right after an
    // upgrade that introduces/rebuilds `_blsSlashCd`, an operator BLS-slashed shortly before the
    // upgrade has no per-operator cooldown recorded, so a raced duplicate could slip through. The
    // floor treats the upgrade moment as if every operator was just slashed (blanket 1h pause).
    // Effective end = max(_blsSlashCd[op], _blsSlashCdFloor).
    uint48 private _blsSlashCdFloor;

    // v5.4 god-split phase 1: the x402 settle/admin LOGIC moved to X402Facilitator, but
    // the 4 x402 storage slots are RETAINED above as `private __deprecated_*` placeholders
    // to keep this UUPS proxy's layout byte-identical to the pre-split deployed layout.
    // Every variable keeps its original slot, so an in-place upgrade of the live proxy stays
    // storage-safe. 50 reserved; usage: 18 original + _slashCd + pendingBLSAgg/Eta +
    // _settledDebtOps + _pendingSlash + _blsSlashCd + _blsSlashCdFloor = 24. (The 4 deprecated
    // x402 slots are accounted in the "18 original"+V5 block, not here.)
    // 5.5.0 (R10-M1b): operator reservations in flight between validation and postOp.
    // Appended at the end of storage (UUPS-safe); consumes one __gap slot (28 → 27).
    mapping(bytes32 => Inflight) internal _inflight;

    // exp/params: governable gas parameters (appended; UUPS-safe; __gap 27 → 25).
    GasParams internal _gasParams;
    PendingGasParams internal _pendingGasParams;

    uint256[25] private __gap;
}