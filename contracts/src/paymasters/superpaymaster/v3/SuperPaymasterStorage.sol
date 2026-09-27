// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "./BasePaymasterUpgradeable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "src/interfaces/v3/IRegistry.sol";
import "../../../interfaces/ISuperPaymaster.sol";

/**
 * @title SuperPaymasterStorage
 * @notice D5b: the ONE storage/inheritance chain shared by the SuperPaymaster core and its
 *         SuperPaymasterAdmin extension (reached from the core's fallback via DELEGATECALL).
 * @dev    Both contracts inherit exactly this chain — BasePaymasterUpgradeable(Ownable2StepNamespaced
 *         → Ownable, Initializable, UUPSUpgradeable) + ReentrancyGuard + the state below — so they
 *         agree on every slot by construction; scripts/check-sp-layout.py re-checks it on the
 *         compiled artifacts. The sequential layout is the UUPS proxy layout of SuperPaymaster 5.5.0
 *         (+ Part B) with ONE appended slot (guardian + paused); scripts/check_storage_layout.py
 *         allows only that listed append.
 *
 *         RULES
 *         - Declaration ORDER below is the storage order. Never insert, reorder or resize; append
 *           only before `__gap` and shrink the gap by the same number of slots.
 *         - Any override that changes a BASE contract's behaviour (transferOwnership, …) belongs in
 *           this chain or in the core, never only in the extension: a selector the core has is
 *           always answered by the core (D5b-design §2.1).
 *         - Immutables live in the bytecode of each contract: the core and the extension are
 *           constructed with the same (entryPoint, REGISTRY, ETH_USD_PRICE_FEED) — the core creates
 *           its extension in its own constructor (D5b-design §2.2).
 */
abstract contract SuperPaymasterStorage is BasePaymasterUpgradeable, ReentrancyGuard {
    struct PriceCache {
        int256 price;
        uint256 updatedAt;
        uint80 roundId;
        uint8 decimals;
    }

    /// @dev 5.5.0: operator reservation between validation and postOp (R10-M1b).
    struct Inflight {
        address operator;
        uint96 a0;
    }

    /// @dev GOV-5: owner-settable gas parameters, one slot (4 x uint32).
    struct GasParams {
        uint32 minPostOpGas;
        uint32 settleGasBound;
        uint32 cWrap;
        uint32 cPostop;
    }

    /// @dev GOV-5: pending proposal + eta, one slot.
    struct PendingGasParams {
        uint32 minPostOpGas;
        uint32 settleGasBound;
        uint32 cWrap;
        uint32 cPostop;
        uint64 eta;
    }

    struct UserOperatorState {
        uint48 lastTimestamp; // 6 bytes
        bool isBlocked;       // 1 byte
        // 25 bytes remaining in slot
    }

    // ====================================
    // Storage (sequential layout — see RULES)
    // ====================================

    IRegistry public immutable REGISTRY;
    address public APNTS_TOKEN;            // aPNTs (AAStar Token) - Mutable to allow updates
    address public xpntsFactory;           // xPNTs Factory for dynamic pricing
    AggregatorV3Interface public immutable ETH_USD_PRICE_FEED;
    address public treasury; // Protocol Treasury for fees

    mapping(address => ISuperPaymaster.OperatorConfig) public operators;
    // CONSOLIDATED MAPPING: operator => user => state (Saves 1 SLOAD in hot path)
    mapping(address => mapping(address => UserOperatorState)) public userOpState;
    mapping(address => bool) public sbtHolders; // Global SBT holders list (verified via Registry)
    mapping(address => ISuperPaymaster.SlashRecord[]) public slashHistory;

    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)
    PriceCache public cachedPrice;
    // Protocol Fee (Basis Points)
    uint256 public protocolFeeBPS = 1000; // 10%
    address public BLS_AGGREGATOR; // Trusted Aggregator for DVT Slash
    uint256 public totalTrackedBalance;
    uint256 public protocolRevenue;
    // RETIRED in 5.5.0 (was the V4.1 pending-debt fallback). The slot is kept so the UUPS
    // layout stays byte-identical; nothing reads or writes it any more. Reconcile or write off
    // any non-zero entries BEFORE upgrading (spec 03 §6 step 2).
    mapping(address => mapping(address => uint256)) internal pendingDebts;

    // P0-10 — Chainlink break-glass state machine (D8 design)
    /// @notice 0 = CHAINLINK (normal), 1 = EMERGENCY (owner override active).
    uint8 public priceMode;
    /// @notice Timestamp at which `emergencySetPrice` was last called; 0 if none queued.
    uint256 public emergencyQueuedAt;
    /// @notice Pending emergency price (8 decimals, same scale as Chainlink).
    int256 public emergencyPendingPrice;
    /// @notice Timestamp at which EMERGENCY mode was first activated; cleared on Chainlink recovery.
    uint256 public emergencyActivatedAt;

    /// @notice Price staleness threshold (seconds)
    uint256 public priceStalenessThreshold;

    // ERC-8004 Agent Registries
    address public agentIdentityRegistry;
    address public agentReputationRegistry;

    // v5.4 god-split phase 1: the 4 x402 slots are KEPT as `private __deprecated_*` placeholders so
    // this UUPS proxy's layout stays byte-identical (original names: facilitatorFeeBPS,
    // operatorFacilitatorFees, x402SettlementNonces, facilitatorEarnings).
    uint256 private __deprecated_x402_facilitatorFeeBPS;
    mapping(address => uint256) private __deprecated_x402_operatorFacilitatorFees;
    mapping(bytes32 => bool) private __deprecated_x402_settlementNonces;
    mapping(address => mapping(address => uint256)) private __deprecated_x402_facilitatorEarnings;

    // P0-9: APNTS_TOKEN swap timelock.
    /// @notice Pending APNTS_TOKEN swap; address(0) when none queued.
    address public pendingAPNTsToken;
    /// @notice Earliest timestamp at which `executeAPNTsTokenChange` may run.
    uint256 public pendingAPNTsTokenEta;

    // P0-14: per-operator slash cooldown (24h between owner slashes of same operator).
    mapping(address => uint48) internal _slashCd;

    // P0-3: BLSAggregator 24h timelock (packed into 1 slot: address 20B + uint48 6B).
    address public pendingBLSAgg;
    uint48 public pendingBLSAggEta;

    /// @notice P1-17: postOp idempotency lock (keyed by opHash).
    mapping(bytes32 => bool) internal _settledDebtOps;

    // M-5: per-operator pending-slash guard (withdraw() reverts while set).
    mapping(address => bool) internal _pendingSlash;

    // CC-13 (F2): dedicated cooldown for the BLS/DVT slash path, separate from `_slashCd`.
    mapping(address => uint48) internal _blsSlashCd;

    // CC-13: global BLS-slash cooldown floor (primeBlsSlashCooldown); effective end =
    // max(_blsSlashCd[op], _blsSlashCdFloor).
    uint48 internal _blsSlashCdFloor;

    // 5.5.0 (R10-M1b): operator reservations in flight between validation and postOp.
    mapping(bytes32 => Inflight) internal _inflight;

    // GOV-5 (Part B): governable gas parameters.
    GasParams internal _gasParams;
    PendingGasParams internal _pendingGasParams;

    // D5b GOV-2 (spec 03 §10.7b A): emergency guardian + global sponsorship pause, ONE slot
    // (address 20 B + bool 1 B), appended; __gap 25 -> 24, end slot unchanged.
    /// @notice May ONLY pause (an operator, or all sponsorship). Unpausing is owner-only.
    address public guardian;
    /// @notice Global sponsorship stop: validatePaymasterUserOp returns SIG_FAILURE for every op,
    ///         checked before anything in the op is parsed. postOp / release are unaffected.
    bool public paused;

    uint256[24] private __gap;

    // ====================================
    // Constants
    // ====================================

    uint256 internal constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 internal constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 internal constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    /// @notice Grace window (seconds) for keeper clock skew on `updatedAt` checks.
    uint256 internal constant TIMESTAMP_GRACE_SECONDS = 15;

    // paymasterAndData (v0.7): [paymaster 20][pmVerifGas 16][pmPostOpGas 16][operator 20][maxRate 32][token 20][flags 1]
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52; // ERC-4337 v0.7
    uint256 internal constant RATE_OFFSET = 72;
    uint256 internal constant POSTOP_GAS_OFFSET = 36; // start of paymasterPostOpGasLimit (uint128)
    uint256 internal constant TOKEN_OFFSET = 104;
    uint256 internal constant FLAGS_OFFSET = 124;
    uint8 internal constant FLAG_SP_RENEW = 1;       // SP relays a K-bounded renewal (D-13)
    uint8 internal constant FLAG_ACCOUNT_RENEW = 2;  // consumed by the account itself (option A); SP ignores it
    uint8 internal constant MODE_NONE = 0;
    uint8 internal constant MODE_BALANCE = 1;
    uint8 internal constant MODE_CREDIT = 2;

    // GOV-5 defaults of the owner-settable `GasParams` (an all-zero slot = these values) and their
    // hard bounds (checked at queue AND execute; buffer-and-params-experiment.md §B.2):
    //   MIN_POST_OP_GAS (C-04 floor for paymasterPostOpGasLimit), SETTLE_GAS_BOUND (B-1 / R10-H1
    //   postOp entry guard), C_WRAP_GAS (R10-M3 EntryPoint wrapper), C_POSTOP_GAS (whole postOp
    //   frame upper bound; G-layer rule C_POSTOP >= W_postop x 1.15).
    //   SETTLE in [155k, 1M]; MIN in [SETTLE + 20k, 2M]; C_POSTOP in [175k, MIN]; C_WRAP in [5k, 50k].
    uint256 internal constant MIN_POST_OP_GAS = 200_000;
    uint256 internal constant SETTLE_GAS_BOUND = 160_000;
    uint256 internal constant C_WRAP_GAS = 5_000;
    uint256 internal constant C_POSTOP_GAS = 175_000;
    uint256 internal constant GP_SETTLE_MIN = 155_000;
    uint256 internal constant GP_SETTLE_MAX = 1_000_000;
    uint256 internal constant GP_MINPOST_OVER_SETTLE = 20_000;
    uint256 internal constant GP_MINPOST_MAX = 2_000_000;
    uint256 internal constant GP_CPOSTOP_MIN = 175_000;
    uint256 internal constant GP_CWRAP_MIN = 5_000;
    uint256 internal constant GP_CWRAP_MAX = 50_000;
    uint256 internal constant GP_TIMELOCK = 48 hours;

    // Protocol Fee (Basis Points)
    uint256 internal constant BPS_DENOMINATOR = 10000;
    uint256 internal constant MAX_PROTOCOL_FEE = 2000; // 20% Hardcap (Security)
    uint256 internal constant VALIDATION_BUFFER_BPS = 1000; // 10% for Validation safety margin
    /// @notice Minimum protocolRevenue that must remain after any withdrawal.
    uint256 internal constant PROTOCOL_REVENUE_BUFFER = 0.1 ether;

    // ====================================
    // Events
    // ====================================

    // V3.1: Credit & Reputation Events
    event UserReputationAccrued(address indexed user, uint256 aPNTsValue);
    event APNTsTokenUpdated(address indexed oldToken, address indexed newToken);
    event APNTsTokenChangeQueued(address indexed pendingToken, uint256 eta);
    event APNTsTokenChangeCancelled(address indexed pendingToken);
    event APNTsTokenChangeExecuted(address indexed oldToken, address indexed newToken, uint256 executedAt);
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
    event SlashExecutedWithProof(
        address indexed operator,
        ISuperPaymaster.SlashLevel level,
        uint256 penalty,
        bytes32 proofHash,
        uint256 timestamp
    );
    event SlashQueued(address indexed operator);
    event SlashCancelled(address indexed operator);
    event BlsSlashCooldownPrimed(uint48 floorUntil);
    event PriceUpdated(int256 indexed price, uint256 indexed timestamp);
    event OracleFallbackTriggered(uint256 timestamp);
    /// @dev Reserved; never emitted from validatePaymasterUserOp (ERC-7562 bans LOG* there).
    event ValidationFailed(bytes32 indexed userOpHash, bytes32 reasonCode);
    event ProtocolRevenueWithdrawn(address indexed to, uint256 amount);
    event ProtocolRevenueUnderflow(address indexed operator, uint256 requestedRefund, uint256 availableRevenue);
    event DebtRecordFailed(address indexed token, address indexed user, uint256 amount);
    event PendingDebtRetried(address indexed token, address indexed user, uint256 amount);
    event PendingDebtCleared(address indexed token, address indexed user, uint256 amount);
    event GasParamsQueued(uint32 minPostOpGas, uint32 settleGasBound, uint32 cWrap, uint32 cPostop, uint64 eta);
    event GasParamsExecuted(uint32 minPostOpGas, uint32 settleGasBound, uint32 cWrap, uint32 cPostop);
    event GasParamsCancelled();
    event SponsorshipReleased(bytes32 indexed opHash, address indexed operator, uint256 aPNTs);
    event AgentRegistriesUpdated(address identityRegistry, address reputationRegistry);
    event BLSAggregatorQueued(address indexed pending, uint48 eta);
    // D5b GOV-2
    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event GlobalPauseSet(address indexed by, bool isPaused);

    // ====================================
    // Errors
    // ====================================

    error Unauthorized();
    error InvalidAddress();
    error InvalidContextLength();
    error InvalidConfiguration();
    error PostOpGasTooLow();
    error GasParamsTimelock();
    error SponsorshipInFlight();
    error InsufficientBalance(uint256 available, uint256 required);
    error DepositNotVerified();
    error OracleError();
    error NoSlashHistory();
    error InsufficientRevenue();
    error InvalidXPNTsToken();
    error AmountExceedsUint128();
    error ScoreExceedsUint32();
    error NoPendingDebt();
    error ChainlinkNotStale();
    error EmergencyPriceOutOfRange();
    error EmergencyTimelockNotElapsed();
    error NoEmergencyPending();
    error EmergencyExpired();
    error InvalidOwner();
    error SlashPending();
    error SlashCooldown();

    // ====================================
    // Constructor
    // ====================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IEntryPoint _entryPoint, IRegistry _registry, address _ethUsdPriceFeed)
        BasePaymasterUpgradeable(_entryPoint)
    {
        REGISTRY = _registry;
        ETH_USD_PRICE_FEED = AggregatorV3Interface(_ethUsdPriceFeed);
    }

    // ====================================
    // Shared internals
    // ====================================

    /// @dev Reverts with Unauthorized if `account` is not a registered ROLE_PAYMASTER_SUPER member
    function _requireSuperOperatorRoleFor(address account) internal view {
        if (!REGISTRY.hasRole(keccak256("PAYMASTER_SUPER"), account)) revert Unauthorized();
    }

    /// @dev The GasParams slot as one word (minPostOpGas | settle << 32 | cWrap << 64 | cPostop << 96);
    ///      an all-zero slot (never set / pre-Part-B proxy) = the defaults.
    function _gpRaw() internal view returns (uint256 raw) {
        assembly ("memory-safe") { raw := sload(_gasParams.slot) }
        if (raw == 0) {
            raw = MIN_POST_OP_GAS | (SETTLE_GAS_BOUND << 32) | (C_WRAP_GAS << 64) | (C_POSTOP_GAS << 96);
        }
    }
}
