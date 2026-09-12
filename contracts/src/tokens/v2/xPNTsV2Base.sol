// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { AOAProtocolRegistry } from "./AOAProtocolRegistry.sol";

/**
 * @title xPNTsV2Base
 * @notice Shared storage, constants, events, errors and internal logic of xPNTs v2.
 * @dev    xPNTs v2 is split into a CORE contract (xPNTsTokenV2: ERC20 + every
 *         validation/settlement hot path) and an EXTENSION (xPNTsTokenV2Ext: administration,
 *         user settings, views) reached through the core's fallback via DELEGATECALL.
 *         Both inherit THIS contract through the identical chain
 *         `Initializable, ERC20, ERC20Permit, xPNTsV2Base`, so their storage layouts are
 *         identical by construction (asserted by test). The split exists purely for EIP-170;
 *         the validation-frame entry points never cross into the extension.
 *
 *         Normative spec: docs/design/aoa-balance-mode/03-final-spec.md. Rule IDs (A-*, E-*,
 *         L-*, C-*, S-*, B-*) in comments refer to it.
 */
abstract contract xPNTsV2Base is Initializable, ERC20, ERC20Permit {
    // =====================================================================
    // Constants
    // =====================================================================

    uint8 public constant K = 1;                                    // D-18
    uint256 public constant SP_DEFAULT_CAP = 5_000 ether;           // Q5  (aPNTs)
    uint256 public constant SP_CAP_FLOOR = 250 ether;               // D-4 (aPNTs)
    uint256 public constant USER_TOTAL_DEFAULT = 5_000 ether;       // Q6  (aPNTs)
    uint256 public constant PROTOCOL_MAX_CAP = 50_000 ether;        // user-settable ceiling (aPNTs)
    uint256 public constant PROTOCOL_CREDIT_CEILING = 50_000 ether; // C-0 (aPNTs)
    uint256 public constant TIMELOCK = 48 hours;                     // X4 / C-3 / S-*
    uint256 public constant TIER_SOURCE_GAS = 100_000;              // §9: forwarded-gas cap for tierOf

    uint8 public constant POLICY_OFF = 0;
    uint8 public constant POLICY_MANUAL = 1;
    uint8 public constant POLICY_AUTO = 2;
    uint8 public constant MODE_SP_K = 0;
    uint8 public constant MODE_ACCOUNT_ONLY = 1;

    bytes32 internal constant LOCK_SEED = keccak256("xPNTs.v2.lock.live");
    bytes32 internal constant CREDIT_SEED = keccak256("xPNTs.v2.credit.live");

    /// @notice Protocol allowlists (SP address / spender impl / tier-source impl).
    AOAProtocolRegistry public immutable PROTOCOL_REGISTRY;

    // =====================================================================
    // Storage (append-only; both CORE and EXTENSION share this layout)
    // =====================================================================

    // --- identity & admin ---
    address public FACTORY;
    address public communityOwner;
    address public community;              // fixed at init (§9): the COMMUNITY-role address
    string public communityName;
    string public communityENS;
    string internal _tokenName;
    string internal _tokenSymbol;

    // --- pricing ---
    uint256 public exchangeRate;
    uint256 public exchangeRateUpdatedAt;
    uint256 public maxSingleTxLimit;
    uint256 public issuanceCap;

    // --- SP address state machine (§2.5) ---
    address public SUPERPAYMASTER_ADDRESS;
    address public pendingSP;
    uint64 public pendingSPEta;
    bool public pendingSPByFactory;
    bool public emergencyDisabled;
    address public emergencyRevokedAddress;
    address public pendingStandby;
    uint64 public pendingStandbyEta;
    address public standbySP;
    mapping(address => bool) public historicalSP;

    // --- spenders ---
    mapping(address => bool) public autoApprovedSpenders;
    mapping(address => uint64) public spenderActivatesAt;
    mapping(address => bool) public approvedFacilitators;

    struct SpenderRateLimit { uint128 dailyBurnTotal; uint64 windowStart; uint64 reserved; }
    mapping(address => SpenderRateLimit) public spenderRateLimit;
    uint256 public spenderDailyCapTokens;
    mapping(address => uint256) public spenderDailyCapOverride;

    // --- bounded auto-allowance (aPNTs) ---
    struct Allow { uint128 used; uint120 cap; bool set; }
    mapping(address spender => mapping(address user => Allow)) internal _auto;
    mapping(address user => Allow) internal _budget;
    mapping(address user => uint8) public autoRenewUsed;
    mapping(address user => uint8) public renewalMode;
    mapping(address spender => mapping(address user => bool)) public spenderDisabled;

    // --- escrow (A2) ---
    struct LockRec { uint128 xLocked; uint128 aReserved; address locker; }
    mapping(address user => uint256) public lockedOf;
    mapping(bytes32 opHash => mapping(address user => LockRec)) internal _locks;

    // --- credit (C-*) ---
    struct CreditReq { uint112 requestedCap; uint112 approvedCap; uint32 epoch; }
    struct CreditRes { uint128 amount; address locker; }
    mapping(address user => uint256) public debts;
    mapping(address user => CreditReq) public creditReq;
    mapping(address user => uint256) public creditReservedOf;
    mapping(bytes32 opHash => mapping(address user => CreditRes)) internal _creditRes;
    uint8 public creditPolicy;
    uint32 public policyEpoch;
    uint8 public pendingPolicy;
    bool public hasPendingPolicy;
    uint64 public pendingPolicyEta;
    address public creditTierSource;
    address public pendingTierSource;
    uint64 public pendingTierSourceEta;

    // --- misc ---
    mapping(bytes32 => bool) public usedOpHashes;
    mapping(address user => uint256) public actionNonce;
    uint256 internal _reentrancyStatus;

    // =====================================================================
    // Events
    // =====================================================================

    event LockCreated(address indexed user, bytes32 indexed opHash, address indexed locker, uint256 xLocked, uint256 aReserved);
    event LockSettled(address indexed user, bytes32 indexed opHash, uint256 xBurned, uint256 aCharged);
    event LockReleased(address indexed user, bytes32 indexed opHash, uint256 xLocked);
    event CreditReserved(address indexed user, bytes32 indexed opHash, address indexed locker, uint256 amount);
    event CreditSettled(address indexed user, bytes32 indexed opHash, uint256 debtAdded);
    event CreditReleased(address indexed user, bytes32 indexed opHash, uint256 amount);
    event DebtRepaid(address indexed user, uint256 amountRepaid, uint256 remainingDebt);
    event AllowanceRenewed(address indexed user, address indexed spender, bool bySP);
    event AutoAllowanceSet(address indexed user, address indexed spender, uint256 cap);
    event UserTotalCapSet(address indexed user, uint256 cap);
    event RenewalModeSet(address indexed user, uint8 mode);
    event SpenderDisabledByUser(address indexed user, address indexed spender, bool disabled);
    event CreditRequested(address indexed user, uint256 maxCap, uint32 epoch);
    event CreditApproved(address indexed user, uint256 cap, uint32 epoch);
    event CreditPolicyQueued(uint8 policy, uint64 eta);
    event CreditPolicyExecuted(uint8 policy, uint32 epoch);
    event CreditPolicyCancelled();
    event TierSourceQueued(address source, uint64 eta);
    event TierSourceExecuted(address source, uint32 epoch);
    event SpenderProposed(address indexed spender, uint64 eta);
    event AutoApprovedSpenderAdded(address indexed spender);
    event AutoApprovedSpenderRemoved(address indexed spender);
    event SPProposed(address indexed sp, uint64 eta, bool byFactory);
    event SPProposalCancelled(address indexed sp);
    event SuperPaymasterAddressUpdated(address indexed oldSP, address indexed newSP);
    event StandbyProposed(address indexed sp, uint64 eta);
    event StandbyDesignated(address indexed sp);
    event EmergencyDisabledSet(address indexed by);
    event EmergencyDisabledCleared(address indexed by);
    event CommunityOwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);
    event MaxSingleTxLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event IssuanceCapUpdated(uint256 oldCap, uint256 newCap);
    event SpenderDailyCapUpdated(uint256 oldCap, uint256 newCap);
    event SpenderDailyCapForUpdated(address indexed spender, uint256 oldCap, uint256 newCap);
    event SpenderRateLimitWindowReset(address indexed spender, uint64 newWindowStart);
    event FacilitatorApproved(address indexed facilitator);
    event FacilitatorRemoved(address indexed facilitator);

    // =====================================================================
    // Errors
    // =====================================================================

    error Unauthorized(address caller);
    error InvalidAddress(address addr);
    error InvalidParam();
    error NotApproved(address target);
    error EmergencyStop();
    error ExchangeRateCannotBeZero();
    error ExchangeRateOutOfRange(uint256 rate, uint256 min, uint256 max);
    error ExchangeRateDeltaTooLarge(uint256 newRate, uint256 oldRate, uint256 maxDeltaBPS);
    error ExchangeRateCooldownActive();
    error SingleTxLimitExceeded();
    error BalanceLocked(address user, uint256 locked);
    error SPCannotTransfer();
    error UnauthorizedRecipient();
    error AutoAllowanceExceeded();
    error SpenderIsDisabled();
    error SpenderDailyCapExceeded(address spender, uint256 attempted, uint256 capRemaining);
    error BurnExceedsAllowance();
    error NoLock();
    error NotLive();
    error StillLive();
    error RenewBlocked();
    error BelowFloor();
    error AboveCeiling();
    error TimelockActive(uint64 eta);
    error NothingPending();
    error RecoveryNotComplete();
    error NoDebtToRepay();
    error RepayExceedsDebt();
    error BurnExceedsBalance();
    error InvalidSignature();
    error SignatureExpired();
    error UnknownAction(uint8 kind);

    // =====================================================================
    // Construction
    // =====================================================================

    constructor(address protocolRegistry) ERC20("", "") ERC20Permit("") {
        if (protocolRegistry == address(0)) revert InvalidAddress(address(0));
        PROTOCOL_REGISTRY = AOAProtocolRegistry(protocolRegistry);
    }

    function name() public view override returns (string memory) { return _tokenName; }
    function symbol() public view override returns (string memory) { return _tokenSymbol; }

    modifier onlyCommunityOwner() {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        _;
    }

    // =====================================================================
    // ERC20 hook (A-1) — shared by CORE and EXTENSION (mint lives in the extension)
    // =====================================================================

    /// @dev A-1: no outgoing movement may leave a balance below `lockedOf`. Mint-time
    ///      auto-repayment of debt is retained from 3.x (it burns only newly minted value,
    ///      so it can never violate the lock invariant).
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            uint256 locked = lockedOf[from];
            if (locked != 0) {
                uint256 bal = balanceOf(from);
                if (bal < value || bal - value < locked) revert BalanceLocked(from, locked);
            }
        }
        if (from == address(0) && to != address(0) && value > 0) {
            uint256 debt = debts[to];
            if (debt > 0) {
                uint256 rate = _requireRate();
                uint256 mintedAPNTs = (value * 1e18) / rate;
                if (mintedAPNTs > 0) {
                    uint256 repayAPNTs = mintedAPNTs > debt ? debt : mintedAPNTs;
                    uint256 repayXPNTs = (repayAPNTs * rate + 1e18 - 1) / 1e18;
                    debts[to] = debt - repayAPNTs;
                    super._update(from, to, value);
                    _burn(to, repayXPNTs);
                    emit DebtRepaid(to, repayAPNTs, debts[to]);
                    return;
                }
            }
        }
        super._update(from, to, value);
    }

    // =====================================================================
    // Shared internals
    // =====================================================================

    function _requireRate() internal view returns (uint256 r) {
        r = exchangeRate;
        if (r == 0) revert ExchangeRateCannotBeZero();
    }

    function _defaultCap(address spender) internal view returns (uint256) {
        return spender == SUPERPAYMASTER_ADDRESS ? SP_DEFAULT_CAP : 0;
    }

    /// @dev Remaining aPNTs under both the per-spender cap and the user total (saturating, B-7).
    function _remainingWith(address spender, address user, uint256 usedA, uint256 usedB)
        internal view returns (uint256)
    {
        Allow memory a = _auto[spender][user];
        Allow memory b = _budget[user];
        uint256 capA = a.set ? a.cap : _defaultCap(spender);
        uint256 capB = b.set ? b.cap : USER_TOTAL_DEFAULT;
        uint256 r1 = capA > usedA ? capA - usedA : 0;
        uint256 r2 = capB > usedB ? capB - usedB : 0;
        return r1 < r2 ? r1 : r2;
    }

    function _remaining(address spender, address user) internal view returns (uint256) {
        return _remainingWith(spender, user, _auto[spender][user].used, _budget[user].used);
    }

    /// @dev Return unused reservation to the ORIGINATING spender's cell (A-4) and the total.
    function _refund(address spender, address user, uint256 amount) internal {
        if (amount == 0) return;
        Allow storage a = _auto[spender][user];
        a.used = a.used > amount ? a.used - uint128(amount) : 0;
        Allow storage b = _budget[user];
        b.used = b.used > amount ? b.used - uint128(amount) : 0;
    }

    /// @dev A-6: resets `used` (spender + total) and `autoRenewUsed`, only with nothing
    ///      outstanding. Touches ONLY slots keyed by `user` (safe in an account validation frame).
    function _renew(address user, address spender) internal {
        if (spender == address(0)) revert InvalidAddress(address(0));
        if (lockedOf[user] != 0 || creditReservedOf[user] != 0) revert RenewBlocked();
        _auto[spender][user].used = 0;
        _budget[user].used = 0;
        autoRenewUsed[user] = 0;
        emit AllowanceRenewed(user, spender, false);
    }

    // --- stale release (L-4), shared by CORE's public entry and EXTENSION's releaseAndDisable ---

    function _releaseLock(address user, bytes32 opHash) internal {
        LockRec memory r = _locks[opHash][user];
        if (r.locker == address(0)) return; // idempotent
        if (_isLive(user, opHash, LOCK_SEED)) revert StillLive();
        delete _locks[opHash][user];
        lockedOf[user] -= r.xLocked;
        _refund(r.locker, user, r.aReserved);
        emit LockReleased(user, opHash, r.xLocked);
    }

    function _releaseCredit(address user, bytes32 opHash) internal {
        CreditRes memory r = _creditRes[opHash][user];
        if (r.locker == address(0)) return; // idempotent
        if (_isLive(user, opHash, CREDIT_SEED)) revert StillLive();
        delete _creditRes[opHash][user];
        creditReservedOf[user] -= r.amount;
        emit CreditReleased(user, opHash, r.amount);
    }

    // --- transient "live in the original transaction" marker (L-2) ---

    /// @dev slot = keccak(user ‖ keccak(opHash ‖ seed)) → associated with `user` (OP-070/STO-021).
    function _liveSlot(address user, bytes32 opHash, bytes32 seed) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, keccak256(abi.encode(opHash, seed))));
    }

    function _setLive(address user, bytes32 opHash, bytes32 seed, bool on) internal {
        bytes32 slot = _liveSlot(user, opHash, seed);
        uint256 v = on ? 1 : 0;
        assembly { tstore(slot, v) }
    }

    function _isLive(address user, bytes32 opHash, bytes32 seed) internal view returns (bool live) {
        bytes32 slot = _liveSlot(user, opHash, seed);
        assembly { live := tload(slot) }
    }
}
