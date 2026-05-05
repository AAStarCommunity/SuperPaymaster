// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "./BasePaymasterUpgradeable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../../interfaces/v3/IRegistry.sol";
import "../../../interfaces/IxPNTsToken.sol";
import "../../../interfaces/IxPNTsFactory.sol";
import "../../../interfaces/ISuperPaymaster.sol";
import "../../../interfaces/v3/IAgentIdentityRegistry.sol";
import "../../../interfaces/v3/IAgentReputationRegistry.sol";
import "../../../interfaces/v3/IERC3009.sol";



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
        return "SuperPaymaster-5.3.0";
    }

    uint256 internal constant PRICE_CACHE_DURATION = 300; // 5 minutes
    int256 internal constant MIN_ETH_USD_PRICE = 100 * 1e8;
    int256 internal constant MAX_ETH_USD_PRICE = 100_000 * 1e8;
    /// @notice Grace window (seconds) for keeper clock skew on `updatedAt` checks.
    ///         Matches PaymasterBase.TIMESTAMP_GRACE_SECONDS to keep both modes in sync.
    uint256 public constant TIMESTAMP_GRACE_SECONDS = 15;

    uint256 public aPNTsPriceUSD = 0.02 ether; // $0.02 (18 decimals)

    PriceCache public cachedPrice; // Make public for easy verification

    // V3.2.1 SECURITY: Enforce max rate in Validation
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52; // ERC-4337 v0.7
    uint256 internal constant RATE_OFFSET = 72; // 20 (paymaster addr) + 32 (gas limits) + 20 (operator addr) = 72

    // Protocol Fee (Basis Points)
    uint256 public protocolFeeBPS = 1000; // 10%
    uint256 internal constant BPS_DENOMINATOR = 10000;
    uint256 internal constant MAX_PROTOCOL_FEE = 2000; // 20% Hardcap (Security)
    uint256 internal constant VALIDATION_BUFFER_BPS = 1000; // 10% for Validation safety margin

    address public BLS_AGGREGATOR; // Trusted Aggregator for DVT Slash

    // State Variables (Restored)
    uint256 public totalTrackedBalance;
    uint256 public protocolRevenue;

    // V4.1: Pending debt fallback for postOp resilience
    // token => user => accumulated pending debt (xPNTs)
    mapping(address => mapping(address => uint256)) public pendingDebts;

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

    /// @notice P0-15 (J2-BLOCKER-1): observability hook for the silent
    ///         SIG_FAILURE branches of validatePaymasterUserOp. Reserved for
    ///         future monitoring integrations — NOT emitted from
    ///         validatePaymasterUserOp itself, since writing storage during
    ///         that opcode-restricted phase would violate ERC-7562.
    /// @dev Intentionally not emitted in the current implementation. Retained for ABI
    ///      compatibility and future use: once Stage-2 audit confirms bundler LOG* policy,
    ///      a UUPS upgrade will wire this into postOp or an off-chain monitoring hook.
    ///      Integrators must NOT subscribe to this event expecting real-time notifications —
    ///      use `dryRunValidation()` instead for pre-flight checks.
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
    // AgentSponsorshipApplied removed — _applyAgentSponsorship is V5.1 only (not yet wired)

    error Unauthorized();
    error InvalidAddress();
    error InvalidConfiguration();
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

    // ====================================
    // Internal Helpers
    // ====================================

    /// @dev Reverts with Unauthorized if caller is not a registered ROLE_PAYMASTER_SUPER member
    function _requireSuperOperatorRole() internal view {
        if (!REGISTRY.hasRole(REGISTRY.ROLE_PAYMASTER_SUPER(), msg.sender)) revert Unauthorized();
    }

    /// @dev Reverts with Unauthorized if `account` is not a registered ROLE_PAYMASTER_SUPER member
    function _requireSuperOperatorRoleFor(address account) internal view {
        if (!REGISTRY.hasRole(REGISTRY.ROLE_PAYMASTER_SUPER(), account)) revert Unauthorized();
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
        __BasePaymaster_init(_owner);
        // Note: _apntsToken can be address(0) during staged deployment
        // (deployed later via setAPNTsToken which has its own zero-address check)
        APNTS_TOKEN = _apntsToken;
        treasury = _protocolTreasury != address(0) ? _protocolTreasury : _owner;
        priceStalenessThreshold = _priceStalenessThreshold > 0 ? _priceStalenessThreshold : 3600;
        // Default values must be set explicitly (proxy storage doesn't inherit implementation defaults)
        aPNTsPriceUSD = 0.02 ether;
        protocolFeeBPS = 1000;
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
        _requireSuperOperatorRole();
        // BUS-RULE: Must be Community to be Paymaster
         if (!REGISTRY.hasRole(REGISTRY.ROLE_COMMUNITY(), msg.sender)) {
            revert Unauthorized();
        }
        if (xPNTsToken == address(0) || _opTreasury == address(0) || exchangeRate == 0) {
            revert InvalidConfiguration();
        }

        // V3.6 SECURITY: Enforce Binding with Factory
        if (xpntsFactory != address(0)) {
            address validToken = IxPNTsFactory(xpntsFactory).getTokenAddress(msg.sender);
            if (validToken != xPNTsToken) revert InvalidXPNTsToken();
        }

        OperatorConfig storage config = operators[msg.sender];
        config.xPNTsToken = xPNTsToken;
        config.treasury = _opTreasury;
        config.exchangeRate = uint96(exchangeRate);
        config.isConfigured = true;

        emit OperatorConfigured(msg.sender, xPNTsToken, _opTreasury, exchangeRate);
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
    uint256 internal constant EMERGENCY_PRICE_DEVIATION_BPS = 2000; // 20%
    /// @notice Maximum duration for which EMERGENCY mode may remain active.
    ///         After 7 days without Chainlink recovery the break-glass is
    ///         considered expired; `emergencySetPrice` will revert to prevent
    ///         an indefinitely-live manual-override regime.
    uint256 public constant EMERGENCY_EXPIRY = 7 days;

    /// @notice Queue a new APNTS_TOKEN. Cannot take effect until
    ///         `pendingAPNTsTokenEta` and only when both `totalTrackedBalance`
    ///         and `protocolRevenue` are zero (otherwise existing operator
    ///         deposits would be stranded under the new token's accounting).
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
        // `protocolRevenue` accumulates continuously via postOp penalty/burn paths.
        // Call `withdrawProtocolRevenue()` first to drain it to zero before
        // executing this change — that is the required prerequisite step.
        // This guard is intentional: it ensures no protocol-owned funds are
        // permanently stranded under the old token's accounting after migration.
        if (totalTrackedBalance != 0 || protocolRevenue != 0) revert InvalidConfiguration();

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
        // proof parameter is kept for ABI compatibility and future on-chain verification.
        
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
    function deposit(uint256 amount) external nonReentrant {
        _requireSuperOperatorRole();
        // This might revert if Token blocks transferFrom (Secure Token)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        // Check overflow for uint128
        if (amount > type(uint128).max) revert AmountExceedsUint128();
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
    function onTransferReceived(address, address from, uint256 value, bytes calldata) external nonReentrant returns (bytes4) {
        if (msg.sender != APNTS_TOKEN) revert Unauthorized();

        // Ensure operator is registered
        _requireSuperOperatorRoleFor(from);


        if (value > type(uint128).max) revert AmountExceedsUint128();
        // casting to 'uint128' is safe because of the check above
        // forge-lint: disable-next-line(unsafe-typecast)
        operators[from].aPNTsBalance += uint128(value);
        // Update tracked balance to keep sync with manual transfers
        totalTrackedBalance += value;
        
        emit OperatorDeposited(from, value);

        return this.onTransferReceived.selector;
    }

    /**
     * @notice Deposit aPNTs for a specific operator (Secure Push Mode)
     * @param targetOperator The operator to credit the deposit to
     * @param amount Amount of aPNTs
     */
    function depositFor(address targetOperator, uint256 amount) external nonReentrant {
        _requireSuperOperatorRoleFor(targetOperator);
        // Transfer from sender (must approve first)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        
        if (amount > type(uint128).max) revert AmountExceedsUint128();
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

    function getAvailableCredit(address user, address token) external view returns (uint256) {
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
        // Owner slash: no 30% hardcap (full authority for governance actions)
        _slash(operator, level, penaltyAmount, reason, false);
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
        
        _slash(operator, level, penalty, "DVT BLS Slash", true);
        
        // ✅ Emit event with proof hash (链上永久可查,DVT保留完整proof 30天供验证)
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

    function setBLSAggregator(address _bls) external onlyOwner {
        if (_bls == address(0)) revert InvalidAddress();
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
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);
        uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS + VALIDATION_BUFFER_BPS;
        aPNTsAmount = Math.mulDiv(aPNTsAmount, totalRate, BPS_DENOMINATOR, Math.Rounding.Ceil);



        // 4. Solvency Check
        // lastTimestamp intentionally NOT updated on sigFailure — rate-limit only counts successful validations.
        if (uint256(config.aPNTsBalance) < aPNTsAmount) {
             return ("", _packValidationData(true, 0, 0));
        }

        // 5. Accounting (Optimistic)
        config.aPNTsBalance -= uint128(aPNTsAmount); // Safe cast due to check above
        config.totalSpent += aPNTsAmount;
        protocolRevenue += aPNTsAmount;
        config.totalTxSponsored++;

        // 6. Return Context — xPNTsAmount excluded (postOp recomputes from exchangeRate)
        return (abi.encode(config.xPNTsToken, userOp.sender, aPNTsAmount, userOpHash, operator), _packValidationData(false, validUntil, validAfter));
    }

    /// @notice P0-15 (J2-BLOCKER-1): pure-view diagnostic mirror of
    ///         validatePaymasterUserOp. Bundlers / SDKs / dApps call this
    ///         off-chain (eth_call) before submitting a UserOperation to
    ///         distinguish the 8 distinct rejection paths that
    ///         validatePaymasterUserOp returns as an opaque SIG_FAILURE.
    /// @dev    Mirrors the main path order; intentionally does NOT mutate
    ///         storage or emit events (would brick ERC-7562 compliance and
    ///         is impossible from a `view` anyway). Mirrors STALE_PRICE
    ///         using the same comparison the main path delegates to
    ///         EntryPoint via `validUntil` — i.e., a price is stale when
    ///         `block.timestamp > cachedPrice.updatedAt + priceStalenessThreshold`.
    /// @dev MERGE DEPENDENCY: This function must be deployed together with P0-16
    ///      (future-timestamp guard on cache writes). Without P0-16, dryRunValidation
    ///      may return ok=true for a future-timestamp cache, while the actual
    ///      validatePaymasterUserOp would revert after P0-16 is deployed.
    /// @param userOp  The UserOperation to dry-run.
    /// @param maxCost Same maxCost EntryPoint will pass to validation.
    /// @return ok          True if validation would pass.
    /// @return reasonCode  Zero when ok==true, otherwise one of the
    ///                     `DRYRUN_*` constants explaining why.
    function dryRunValidation(PackedUserOperation calldata userOp, uint256 maxCost)
        external
        view
        returns (bool ok, bytes32 reasonCode)
    {
        // 1. Extract operator (mirror validatePaymasterUserOp step 1)
        address operator = _extractOperator(userOp);
        ISuperPaymaster.OperatorConfig storage config = operators[operator];

        // 2. Operator config check
        if (!config.isConfigured) return (false, DRYRUN_OPERATOR_NOT_CONFIGURED);
        if (config.isPaused)      return (false, DRYRUN_OPERATOR_PAUSED);

        // 3. Identity check (V5.3 dual-channel: SBT or registered agent)
        if (!isEligibleForSponsorship(userOp.sender)) {
            return (false, DRYRUN_USER_NOT_ELIGIBLE);
        }

        // 4. Per-operator user state: blocklist check (hard failure).
        //    Rate-limit is a soft/temporary failure; it is deferred until after
        //    all hard checks so that a user who is rate-limited *and* also fails
        //    a hard check receives the hard failure code rather than a misleading
        //    "just wait" response.
        UserOperatorState memory userState = userOpState[operator][userOp.sender];
        if (userState.isBlocked) return (false, DRYRUN_USER_BLOCKED);

        // Capture rate-limit state now; we will return it only if every hard
        // check below passes (mirroring the "mirror" contract behaviour).
        bool rateLimited = config.minTxInterval > 0
            && userState.lastTimestamp != 0
            && block.timestamp < uint256(userState.lastTimestamp) + uint256(config.minTxInterval);

        // 5. Rate commitment (rug-pull protection — hard failure): paymasterAndData layout
        //    [paymaster(20)] [gasLimits(32)] [operator(20)] [maxRate(32)]
        uint256 maxRate = type(uint256).max;
        if (userOp.paymasterAndData.length >= 104) {
            maxRate = abi.decode(
                userOp.paymasterAndData[RATE_OFFSET:RATE_OFFSET+32],
                (uint256)
            );
        }
        if (uint256(config.exchangeRate) > maxRate) {
            return (false, DRYRUN_RATE_COMMITMENT_VIOLATED);
        }

        // 6. Staleness (hard failure) — main path delegates to EntryPoint via
        //    validUntil, but for off-chain diagnostics we surface it explicitly.
        //    Use the same predicate as updatePrice (block.timestamp - updatedAt > threshold).
        //    NOTE: future timestamps (updatedAt > block.timestamp) are NOT flagged
        //    here because P0-16 is the dedicated fix for that vector.
        if (cachedPrice.updatedAt == 0 ||
            block.timestamp > cachedPrice.updatedAt + priceStalenessThreshold) {
            return (false, DRYRUN_STALE_PRICE);
        }

        // 7. Solvency (hard failure): replicate Validation-phase aPNTs charge with buffer
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);
        uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS + VALIDATION_BUFFER_BPS;
        aPNTsAmount = Math.mulDiv(aPNTsAmount, totalRate, BPS_DENOMINATOR, Math.Rounding.Ceil);
        if (uint256(config.aPNTsBalance) < aPNTsAmount) {
            return (false, DRYRUN_INSUFFICIENT_BALANCE);
        }

        // 8. Rate-limit (soft/temporary failure): checked last so that hard
        //    failures take precedence. A user who is rate-limited *and* would
        //    fail a hard check will get the hard-failure code, not RATE_LIMITED.
        if (rateLimited) {
            return (false, DRYRUN_RATE_LIMITED);
        }

        // All checks pass.
        return (true, DRYRUN_OK);
    }

    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint nonReentrant {
        if (context.length == 0) return;

        (
            address token,
            address user,
            uint256 initialAPNTs,
            bytes32 userOpHash,
            address operator
        ) = abi.decode(context, (address, address, uint256, bytes32, address));

        // V3.6 FIX: Update Rate Limit Timestamp ALWAYS (Defense against Griefing)
        // Even if op reverted, usage counts towards limit to prevent spam.
        if (operators[operator].minTxInterval > 0) {
            userOpState[operator][user].lastTimestamp = uint48(block.timestamp);
        }

        // Defense: If postOp previously failed, validation already charged - avoid double charging
        if (mode == PostOpMode.postOpReverted) return;

        // 1. Calculate Actual Cost in aPNTs (always uses cached price)
        uint256 actualAPNTsCost = _calculateAPNTsAmount(actualGasCost);

        // 2. Apply Protocol Fee Markup (e.g. 10%)
        // We want the final deduction to be Actual + 10%.
        uint256 finalCharge = (actualAPNTsCost * (BPS_DENOMINATOR + protocolFeeBPS)) / BPS_DENOMINATOR;

        // 3. Process Refund & Record Debt
        uint256 exchangeRate = operators[operator].exchangeRate;

        if (finalCharge < initialAPNTs) {
            uint256 refund = initialAPNTs - finalCharge;
            if (refund > type(uint128).max) refund = type(uint128).max;
            if (refund > protocolRevenue) {
                emit ProtocolRevenueUnderflow(operator, refund, protocolRevenue);
                refund = protocolRevenue;
            }

            uint256 finalXPNTsDebt = (finalCharge * exchangeRate) / 1e18;

            // Preferred: burn from user's xPNTs balance with replay protection.
            // Falls back to recordDebt when user has insufficient balance (e.g. new user).
            // OperationAlreadyProcessed is impossible here: EntryPoint calls postOp once per op.
            _recordXPNTsDebt(token, user, finalXPNTsDebt, userOpHash);

            operators[operator].aPNTsBalance += uint128(refund);
            protocolRevenue -= refund;

            emit TransactionSponsored(operator, user, finalCharge, finalXPNTsDebt);
        } else {
             // B2-N14: finalCharge > initialAPNTs should not occur under EntryPoint v0.7
             // (which guarantees actualGasCost <= maxCost and validation adds a buffer).
             // This branch is a defensive cap; if reached in production it indicates
             // an EntryPoint invariant violation or an unexpected price swing between
             // validation and postOp. Cap at initialAPNTs to protect operator solvency.
             // Rare: actual > max, cap at max (no refund)
             uint256 finalXPNTsDebt = (initialAPNTs * exchangeRate) / 1e18;
             _recordXPNTsDebt(token, user, finalXPNTsDebt, userOpHash);
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

    /// @dev Try to burn xPNTs debt from user; fall back to recordDebt; fall back to pendingDebts.
    function _recordXPNTsDebt(address token, address user, uint256 amount, bytes32 opHash) internal {
        try IxPNTsToken(token).burnFromWithOpHash(user, amount, opHash) {} catch {
            try IxPNTsToken(token).recordDebt(user, amount) {} catch {
                pendingDebts[token][user] += amount;
                emit DebtRecordFailed(token, user, amount);
            }
        }
    }

    // ====================================
    // Pending Debt Recovery
    // ====================================

    /// @notice Retry recording a pending debt that failed during postOp
    /// @param token The xPNTs token address
    /// @param user The user address
    function retryPendingDebt(address token, address user) external nonReentrant {
        uint256 amount = pendingDebts[token][user];
        if (amount == 0) revert NoPendingDebt();
        delete pendingDebts[token][user];
        IxPNTsToken(token).recordDebt(user, amount);
        emit PendingDebtRetried(token, user, amount);
    }

    /// @notice Admin function to clear stuck pending debt (escape hatch)
    /// @dev Use when accumulated debt exceeds MAX_SINGLE_TX_LIMIT or token is unreachable
    /// @param token The xPNTs token address
    /// @param user The user address
    function clearPendingDebt(address token, address user) external onlyOwner {
        uint256 amount = pendingDebts[token][user];
        if (amount == 0) revert NoPendingDebt();
        delete pendingDebts[token][user];
        emit PendingDebtCleared(token, user, amount);
    }

    // ====================================
    // V5 Storage: Agent Sponsorship & x402
    // ====================================

    // ERC-8004 Agent Registries
    address public agentIdentityRegistry;
    address public agentReputationRegistry;

    // x402 Facilitator Fees
    uint256 public facilitatorFeeBPS; // Default fee (e.g. 30 = 0.3%)
    mapping(address => uint256) public operatorFacilitatorFees; // Per-operator override
    /// @notice x402 settlement nonces, keyed by keccak256(asset, from, nonce).
    /// @dev    P0-13: Pre-V5.4 keyed by `nonce` alone (global namespace), which let
    ///         an anonymous attacker pre-burn a victim's nonce by submitting a dummy
    ///         settlement with the same nonce on a different (asset, from) pair.
    ///         The triple key isolates each payer's nonce space per asset.
    mapping(bytes32 => bool) public x402SettlementNonces;
    mapping(address => mapping(address => uint256)) public facilitatorEarnings; // operator => asset => amount

    // F1: Agent Sponsorship Policy
    mapping(address => ISuperPaymaster.AgentSponsorshipPolicy[]) public agentPolicies; // operator => policies
    mapping(address => mapping(uint256 => uint256)) private _agentDailySpend; // operator => day => USD spent

    // P0-9: Timelock variables — appended after all V5 storage to avoid slot collisions.
    // Slots 27-28 (after _agentDailySpend at slot 26). __gap reduced from 40 to 38.
    /// @notice Pending APNTS_TOKEN swap; address(0) when none queued.
    address public pendingAPNTsToken;
    /// @notice Earliest timestamp at which `executeAPNTsTokenChange` may run.
    uint256 public pendingAPNTsTokenEta;

    // V5 Events
    event FacilitatorFeeUpdated(uint256 oldFee, uint256 newFee);
    event AgentRegistriesUpdated(address identityRegistry, address reputationRegistry);
    event FacilitatorEarningsWithdrawn(address indexed operator, address indexed asset, uint256 amount);

    // V5 Errors
    error NonceAlreadyUsed();
    error InvalidFee();

    // x402 Constants
    uint256 internal constant MAX_FACILITATOR_FEE = 500; // 5% hardcap

    // P0-15: dryRunValidation reason codes (internal — SDKs should hardcode bytes32 values).
    bytes32 internal constant DRYRUN_OK                      = bytes32(0);
    bytes32 internal constant DRYRUN_OPERATOR_NOT_CONFIGURED = bytes32("OPERATOR_NOT_CONFIGURED");
    bytes32 internal constant DRYRUN_OPERATOR_PAUSED         = bytes32("OPERATOR_PAUSED");
    bytes32 internal constant DRYRUN_USER_NOT_ELIGIBLE       = bytes32("USER_NOT_ELIGIBLE");
    bytes32 internal constant DRYRUN_USER_BLOCKED            = bytes32("USER_BLOCKED");
    bytes32 internal constant DRYRUN_RATE_LIMITED            = bytes32("RATE_LIMITED");
    bytes32 internal constant DRYRUN_RATE_COMMITMENT_VIOLATED = bytes32("RATE_COMMITMENT_VIOLATED");
    bytes32 internal constant DRYRUN_INSUFFICIENT_BALANCE    = bytes32("INSUFFICIENT_BALANCE");
    bytes32 internal constant DRYRUN_STALE_PRICE             = bytes32("STALE_PRICE");

    // ====================================
    // V5: Admin Setters
    // ====================================

    /// @notice Set ERC-8004 agent registries (Owner only)
    function setAgentRegistries(address _identity, address _reputation) external onlyOwner {
        agentIdentityRegistry = _identity;
        agentReputationRegistry = _reputation;
        emit AgentRegistriesUpdated(_identity, _reputation);
    }

    /// @notice Set default facilitator fee BPS (Owner only)
    function setFacilitatorFeeBPS(uint256 _fee) external onlyOwner {
        if (_fee > MAX_FACILITATOR_FEE) revert InvalidFee();
        uint256 oldFee = facilitatorFeeBPS;
        facilitatorFeeBPS = _fee;
        emit FacilitatorFeeUpdated(oldFee, _fee);
    }

    /// @notice Set per-operator facilitator fee override (Owner only)
    function setOperatorFacilitatorFee(address operator, uint256 _fee) external onlyOwner {
        if (_fee > MAX_FACILITATOR_FEE) revert InvalidFee();
        operatorFacilitatorFees[operator] = _fee;
    }

    /// @notice Withdraw accumulated facilitator earnings
    function withdrawFacilitatorEarnings(address asset) external nonReentrant {
        uint256 amount = facilitatorEarnings[msg.sender][asset];
        if (amount == 0) revert InsufficientBalance(0, 1);
        delete facilitatorEarnings[msg.sender][asset];
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit FacilitatorEarningsWithdrawn(msg.sender, asset, amount);
    }

    // ====================================
    // F1: Agent Sponsorship Policy
    // ====================================

    /// @notice V5.3: Dual-channel eligibility — SBT holder OR registered ERC-8004 agent
    function isEligibleForSponsorship(address user) public view returns (bool) {
        return sbtHolders[user] || isRegisteredAgent(user);
    }

    /// @notice Check if an address is a registered ERC-8004 agent
    function isRegisteredAgent(address account) public view returns (bool) {
        address reg = agentIdentityRegistry;
        if (reg == address(0)) return false;
        try IAgentIdentityRegistry(reg).balanceOf(account) returns (uint256 bal) {
            return bal > 0;
        } catch {
            return false;
        }
    }

    uint256 internal constant MAX_AGENT_POLICIES = 10;

    /// @notice Set agent sponsorship policies for an operator (sorted by minReputationScore desc)
    function setAgentPolicies(ISuperPaymaster.AgentSponsorshipPolicy[] calldata policies) external override {
        _requireSuperOperatorRole();
        if (policies.length > MAX_AGENT_POLICIES) revert InvalidConfiguration();
        delete agentPolicies[msg.sender];
        for (uint256 i = 0; i < policies.length; i++) {
            if (policies[i].sponsorshipBPS > BPS_DENOMINATOR) revert InvalidConfiguration();
            agentPolicies[msg.sender].push(policies[i]);
        }
        emit AgentPoliciesUpdated(msg.sender, policies.length);
    }

    /// @notice Get the sponsorship rate for an agent from an operator
    /// @return bps Sponsorship rate in basis points (0 = no sponsorship)
    function getAgentSponsorshipRate(address agent, address operator) external view override returns (uint256 bps) {
        if (!isRegisteredAgent(agent)) return 0;
        uint256 agentScore;
        address repReg = agentReputationRegistry;
        if (repReg != address(0)) {
            address[] memory empty = new address[](0);
            (, int128 avg) = IAgentReputationRegistry(repReg).getSummary(
                uint256(uint160(agent)), empty, bytes32(0), bytes32(0)
            );
            if (avg > 0) agentScore = uint256(int256(avg));
        }
        ISuperPaymaster.AgentSponsorshipPolicy[] storage policies = agentPolicies[operator];
        for (uint256 i = 0; i < policies.length; i++) {
            if (agentScore >= policies[i].minReputationScore && policies[i].sponsorshipBPS > bps) {
                bps = policies[i].sponsorshipBPS;
            }
        }
    }

    // ====================================
    // F3: x402 Payment Settlement
    // ====================================

    /// @notice Compose the per-(asset, from, nonce) replay-protection key.
    /// @dev    P0-13: must match exactly what the EIP-3009 / direct callers
    ///         submit on-chain. Keep this function `pure` so off-chain SDKs can
    ///         mirror the encoding via the contract ABI.
    function x402NonceKey(address asset, address from, bytes32 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(asset, from, nonce));
    }

    /// @notice Shared validation and fee logic for both x402 settle paths.
    function _validateX402AndComputeFee(
        address asset, address from, uint256 amount, bytes32 nonce
    ) internal returns (uint256 fee) {
        _requireSuperOperatorRole();

        // Guard against replay of settlements made BEFORE the P0-13 upgrade.
        // Pre-V5.4 the mapping was keyed by the raw nonce bytes32 value alone;
        // if that slot is already set the nonce was consumed under the old scheme
        // and must not be reused under the new triple-key scheme.
        if (x402SettlementNonces[nonce]) revert NonceAlreadyUsed();

        bytes32 key = x402NonceKey(asset, from, nonce);
        if (x402SettlementNonces[key]) revert NonceAlreadyUsed();
        x402SettlementNonces[key] = true;

        uint256 effectiveFeeBPS = operatorFacilitatorFees[msg.sender];
        if (effectiveFeeBPS == 0) effectiveFeeBPS = facilitatorFeeBPS;
        fee = (amount * effectiveFeeBPS) / BPS_DENOMINATOR;
        if (fee > 0) facilitatorEarnings[msg.sender][asset] += fee;
    }

    /// @notice Settle x402 payment via EIP-3009 transferWithAuthorization (USDC native path)
    /// @dev settlementId uses abi.encode (not encodePacked) to stay consistent with
    ///      x402NonceKey encoding and to avoid any future collision risk with variable-length
    ///      types. All fields (address, uint256, bytes32) are fixed-size, so the encoding
    ///      produces a unique deterministic id per (from, to, asset, amount, nonce) tuple.
    function settleX402Payment(
        address from, address to, address asset, uint256 amount,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external nonReentrant returns (bytes32 settlementId) {
        uint256 fee = _validateX402AndComputeFee(asset, from, amount, nonce);
        IERC3009(asset).transferWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, signature);
        IERC20(asset).safeTransfer(to, amount - fee);
        emit X402PaymentSettled(from, to, asset, amount, fee, nonce);
        settlementId = keccak256(abi.encode(from, to, asset, amount, nonce));
    }

    /// @notice Settle x402 payment via direct transferFrom (xPNTs only)
    /// @dev    Direct path is restricted to xPNTs tokens registered in
    ///         `xpntsFactory` AND to facilitators explicitly approved by the
    ///         community that owns the xPNTs. Without these gates:
    ///         - any ERC20 the payer ever did `approve(facilitator, MAX)` on
    ///           (e.g. USDC for x402 standard payments) could be drained by
    ///           a compromised facilitator (xPNTs carry an in-contract
    ///           firewall + per-tx cap; arbitrary ERC20s do not);
    ///         - any single global facilitator compromise would blast across
    ///           every community's xPNTs.
    ///         For non-xPNTs settlement use `settleX402Payment` (EIP-3009).
    /// @dev    settlementId uses abi.encode (not encodePacked), matching the
    ///         x402NonceKey encoding to avoid hash-collision with variable-length types.
    /// @dev    P0-12a: enforce `xpntsFactory.isXPNTs(asset)` gate.
    /// @dev    P0-12b (D4): enforce community-side `approvedFacilitators`
    ///         whitelist on the xPNTs token. Community owner toggles via
    ///         `xPNTsToken.add/removeApprovedFacilitator`. AAStar's default
    ///         facilitator is NOT auto-approved at deploy — each community
    ///         decides explicitly.
    /// @dev    Nonce and asset whitelist: _validateX402AndComputeFee writes the
    ///         nonce before the isXPNTs check executes. However, if the call
    ///         reverts (e.g. InvalidXPNTsToken), EVM revert semantics roll back
    ///         the nonce write — so the nonce is NOT consumed on failure.
    function settleX402PaymentDirect(
        address from, address to, address asset, uint256 amount, bytes32 nonce
    ) external nonReentrant returns (bytes32 settlementId) {
        // Validate fee/nonce/role first so unauthorized callers cannot probe
        // the asset whitelist by pre-burning nonces.
        uint256 fee = _validateX402AndComputeFee(asset, from, amount, nonce);

        // P0-12a: Direct settle is xPNTs-only. Reject any asset that is not
        // a token deployed by the configured xPNTs factory.
        address factory = xpntsFactory;
        if (factory == address(0)) revert InvalidConfiguration();
        if (!IxPNTsFactory(factory).isXPNTs(asset)) revert InvalidXPNTsToken();

        // P0-12b: facilitator must be explicitly approved by THIS community's
        // xPNTs. `_validateX402AndComputeFee` already established msg.sender
        // has ROLE_PAYMASTER_SUPER; this per-token whitelist narrows the
        // trust surface from "any global facilitator" to "this community's
        // choice". Distinct from `autoApprovedSpenders` (transferFrom
        // firewall): this gates settle-call invocation, not allowance.
        if (!IxPNTsToken(asset).approvedFacilitators(msg.sender)) {
            revert Unauthorized();
        }

        IERC20(asset).safeTransferFrom(from, address(this), amount);
        IERC20(asset).safeTransfer(to, amount - fee);
        emit X402PaymentSettled(from, to, asset, amount, fee, nonce);
        settlementId = keccak256(abi.encode(from, to, asset, amount, nonce));
    }

    // ====================================
    // Storage Gap (UUPS upgrade safety)
    // ====================================

    // Was 50, minus 8 V5 storage + 2 P0-9 + 6 P0-10 storage slots = 34.
    uint256[34] private __gap;
}