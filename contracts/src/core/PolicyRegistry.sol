// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {IPolicyRegistry} from "../interfaces/v3/IPolicyRegistry.sol";
import {SafeCast} from "@openzeppelin-v5.0.2/contracts/utils/math/SafeCast.sol";

/// @title PolicyRegistry — sender-keyed, governance-gated DVT trigger / spend policy
/// @author SuperPaymaster (DVT cross-repo program, hub: AAStarCommunity/YetAnotherAA-Validator#42)
/// @notice Reference implementation of {IPolicyRegistry}. See the interface for the full design
///         invariants. This contract is the single on-chain source of truth that staked consumers
///         (SuperPaymaster #283, AirAccount #70) read during validation, and that DVT nodes /
///         the slash path reference so that "what a node enforced == what is punished".
///
/// @dev UPGRADEABILITY DECISION — NON-UPGRADEABLE, single instance.
///      Policy evolution is meant to happen through governance (the {TimelockController} +
///      guardian), NOT through code upgrades. Making the contract immutable removes a proxy-admin
///      key as an attack surface and keeps the storage layout permanently auditable for the
///      ERC-7562 "sender-associated storage" guarantee. The {TimelockController} and the guardian
///      are injected at construction. If a future hard requirement for logic upgrades appears, the
///      contract can be re-pointed (deploy v2 + re-authorize the same consumers); a UUPS variant
///      would gate `_authorizeUpgrade` on `onlyTimelock`.
///
/// @dev WIRE-FORMAT INVARIANT (Q6): this registry NEVER inspects or packs signature wire-format.
///      The combined-signature 0x04/05/07 packing is owned entirely by AirAccount #70. Here we
///      only reason about (sender, target, asset, amount, selector) — never raw signatures.
contract PolicyRegistry is IPolicyRegistry {
    using SafeCast for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Canonical ETH sentinel (Q4). `asset == ETH_SENTINEL` is the valid ETH path;
    ///         `asset == address(0)` is INVALID and reverts {ZeroAddress}.
    address public constant ETH_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Default daily-limit / velocity window when a config leaves `windowSeconds == 0`.
    uint64 public constant DEFAULT_WINDOW = 1 days;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage (mirrors the interface STORAGE SHAPE block; all counters sender-keyed)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Sender-keyed cumulative spend / velocity counter ("todaySpent").
    struct SpendCounter {
        uint128 spentInWindow;
        uint64 windowStart;
    }

    // policy config (governance-gated)
    mapping(address sender => mapping(address asset => AssetPolicy)) private _assetPolicy;
    mapping(address sender => mapping(address target => ContractScope)) private _contractScope;
    mapping(address sender => mapping(address target => mapping(bytes4 selector => bool)))
        private _selectorAllowed;
    mapping(address sender => bool) private _frozen;

    // sender-keyed cumulative spend / velocity counters
    mapping(address sender => mapping(address asset => SpendCounter)) private _assetSpend;
    mapping(address sender => mapping(address target => SpendCounter)) private _targetSpend;

    // governance machinery (Q5: delay provided by the external TimelockController)
    mapping(address consumer => bool) private _authorizedConsumer;

    /// @notice AirAccount 2-of-3 RecoveryService — immediate tighten / freeze.
    address public guardian;

    /// @notice OZ {TimelockController}; its `minDelay` (= 2 days) gates loosening. Immutable so the
    ///         loosening authority can never be silently re-pointed without redeploying.
    address public immutable timelock;

    // ─────────────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────────────

    /// @param timelock_ the OZ TimelockController (loosening + admin authority).
    /// @param guardian_ the AirAccount 2-of-3 RecoveryService (immediate tighten/freeze authority).
    /// @param initialConsumer optional staked consumer to authorize at deploy (address(0) ⇒ none).
    constructor(address timelock_, address guardian_, address initialConsumer) {
        if (timelock_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        guardian = guardian_;
        emit GuardianUpdated(address(0), guardian_);
        if (initialConsumer != address(0)) {
            _authorizedConsumer[initialConsumer] = true;
            emit ConsumerAuthorizationSet(initialConsumer, true);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    modifier onlyGuardianOrTimelock() {
        if (msg.sender != guardian && msg.sender != timelock) revert NotGuardianOrTimelock();
        _;
    }

    modifier onlyAuthorizedConsumer() {
        if (!_authorizedConsumer[msg.sender]) revert NotAuthorizedConsumer();
        _;
    }

    /// @dev Normalizes/validates an asset address: `address(0)` is invalid (Q4).
    function _requireValidAsset(address asset) private pure {
        if (asset == address(0)) revert ZeroAddress();
    }

    /// @dev Effective window length for a config value (0 ⇒ DEFAULT_WINDOW).
    function _window(uint64 windowSeconds) private pure returns (uint64) {
        return windowSeconds == 0 ? DEFAULT_WINDOW : windowSeconds;
    }

    /// @dev View-safe window roll: returns the spend that COUNTS right now without writing.
    ///      If the stored window has elapsed, the effective spend is 0 (a fresh window).
    function _effectiveSpent(SpendCounter storage c, uint64 windowSeconds)
        private
        view
        returns (uint256)
    {
        uint64 w = _window(windowSeconds);
        // windowStart == 0 (never spent) ⇒ block.timestamp >= w ⇒ fresh window ⇒ 0.
        if (block.timestamp >= uint256(c.windowStart) + w) return 0;
        return c.spentInWindow;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Validation-time read (cheap view, sender-keyed, ERC-7562 associated storage)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IPolicyRegistry
    /// @dev Reads ONLY `sender`-keyed slots so a staked consumer may call it inside
    ///      `validatePaymasterUserOp` / `validateUserOp`. Mirrors SP `_creditExceeded`'s
    ///      sender-keyed ceiling pattern.
    ///
    ///      OPT-IN, default-ALLOW. This registry is an OPT-IN DVT layer, NOT a global
    ///      allowlist: a sender with nothing configured for an (asset, target) is UNRESTRICTED
    ///      and resolves to ALLOW with `remainingDaily == type(uint256).max`. An explicit
    ///      `freeze` is the one hard block (highest priority). Each dimension is enforced ONLY
    ///      when it is `configured`; an unconfigured dimension imposes no constraint and never
    ///      triggers DVT. Combine: any configured dimension yielding REJECT ⇒ REJECT; else any
    ///      configured dimension yielding REQUIRE_DVT ⇒ REQUIRE_DVT; else ALLOW.
    function checkPolicy(
        address sender,
        address target,
        address asset,
        uint256 amount,
        bytes4 selector
    ) external view returns (PolicyDecision decision, uint256 remainingDaily) {
        _requireValidAsset(asset);

        // (a) frozen sender ⇒ hard REJECT (explicit freeze is the one hard block, top priority).
        if (_frozen[sender]) return (PolicyDecision.REJECT, 0);

        // Opt-in default: nothing configured ⇒ unrestricted (unlimited headroom). Configured
        // dimensions narrow this below; an unconfigured dimension imposes no constraint.
        remainingDaily = type(uint256).max;
        bool requireDVT;

        // (b) ASSET dimension — enforced ONLY when configured (else asset is UNRESTRICTED).
        AssetPolicy storage ap = _assetPolicy[sender][asset];
        if (ap.configured) {
            // per-tx hard cap.
            if (amount > ap.perTxHardCap) return (PolicyDecision.REJECT, 0);
            // daily (asset) window: would posting `amount` exceed dailyLimit?
            uint256 assetSpent = _effectiveSpent(_assetSpend[sender][asset], ap.windowSeconds);
            uint256 projected = assetSpent + amount;
            if (projected > ap.dailyLimit) return (PolicyDecision.REJECT, 0);
            remainingDaily = ap.dailyLimit - projected;
            // DVT trigger by amount: `dvtTriggerAmount == 0` ⇒ DISABLED (no amount-based trigger).
            if (ap.dvtTriggerAmount != 0 && amount >= ap.dvtTriggerAmount) {
                requireDVT = true;
            }
        }

        // (c) CONTRACT-SCOPE dimension — enforced ONLY when configured (else target UNRESTRICTED).
        ContractScope storage cs = _contractScope[sender][target];
        if (cs.configured) {
            // target must be on the call-target allowlist, and the selector allowed.
            if (!cs.allowed) return (PolicyDecision.REJECT, 0);
            if (!_selectorAllowed[sender][target][selector]) return (PolicyDecision.REJECT, 0);
            // per-target velocity window (0 window ⇒ no velocity limit).
            if (cs.velocityWindow != 0) {
                uint256 targetSpent =
                    _effectiveSpent(_targetSpend[sender][target], cs.velocityWindow);
                if (targetSpent + amount > cs.velocityLimit) return (PolicyDecision.REJECT, 0);
            }
            // target flagged requireDVTAlways ⇒ REQUIRE_DVT regardless of amount.
            if (cs.requireDVTAlways) {
                requireDVT = true;
            }
        }

        if (requireDVT) return (PolicyDecision.REQUIRE_DVT, remainingDaily);
        return (PolicyDecision.ALLOW, remainingDaily);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Execution-time debit hook
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IPolicyRegistry
    function recordSpend(
        address sender,
        address target,
        address asset,
        uint256 amount,
        bytes4 selector
    ) external onlyAuthorizedConsumer {
        _requireValidAsset(asset);

        // Advance the per-asset counter, rolling the window first if elapsed.
        AssetPolicy storage ap = _assetPolicy[sender][asset];
        _advance(_assetSpend[sender][asset], ap.windowSeconds, amount);

        // Advance the per-target velocity counter.
        ContractScope storage cs = _contractScope[sender][target];
        _advance(_targetSpend[sender][target], cs.velocityWindow, amount);

        emit SpendRecorded(sender, asset, target, amount, selector);
    }

    /// @dev Roll the window if elapsed (reset to a fresh window starting now), then add `amount`.
    function _advance(SpendCounter storage c, uint64 windowSeconds, uint256 amount) private {
        uint64 w = _window(windowSeconds);
        uint256 base;
        if (block.timestamp >= uint256(c.windowStart) + w) {
            // window elapsed (or first ever spend): open a new window at `now`.
            c.windowStart = uint64(block.timestamp);
            base = 0;
        } else {
            base = c.spentInWindow;
        }
        c.spentInWindow = (base + amount).toUint128(); // reverts on >uint128 overflow.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3a. Governance — LOOSENING path (onlyTimelock; delay is the timelock's minDelay)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IPolicyRegistry
    /// @dev Reached only via the timelock's delayed path, so no direction check is needed —
    ///      it may loosen or tighten. Immediate tightening uses {tightenAssetPolicy}.
    function setAssetPolicy(address sender, address asset, AssetPolicyInput calldata params)
        external
        onlyTimelock
    {
        _requireValidAsset(asset);
        _assetPolicy[sender][asset] = AssetPolicy({
            dvtTriggerAmount: params.dvtTriggerAmount,
            perTxHardCap: params.perTxHardCap,
            dailyLimit: params.dailyLimit,
            windowSeconds: params.windowSeconds,
            configured: true
        });
        emit AssetPolicySet(
            sender, asset, params.dvtTriggerAmount, params.perTxHardCap, params.dailyLimit
        );
    }

    /// @inheritdoc IPolicyRegistry
    /// @dev Selectors are ADDED to the allow set (Q3 additive). Removal is via {tightenContractScope}.
    function setContractScope(address sender, address target, ContractScopeInput calldata params)
        external
        onlyTimelock
    {
        if (target == address(0)) revert ZeroAddress();
        _contractScope[sender][target] = ContractScope({
            allowed: params.allowed,
            requireDVTAlways: params.requireDVTAlways,
            velocityLimit: params.velocityLimit,
            velocityWindow: params.velocityWindow,
            configured: true
        });
        emit ContractScopeSet(
            sender, target, params.allowed, params.requireDVTAlways, params.velocityLimit, params.velocityWindow
        );
        uint256 len = params.selectorAllowlist.length;
        for (uint256 i; i < len; ++i) {
            bytes4 sel = params.selectorAllowlist[i];
            _selectorAllowed[sender][target][sel] = true; // additive
            emit SelectorScopeSet(sender, target, sel, true);
        }
    }

    /// @inheritdoc IPolicyRegistry
    function unfreezeSender(address sender) external onlyTimelock {
        _frozen[sender] = false;
        emit SenderUnfrozen(sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3b. Governance — TIGHTENING / FREEZE path (immediate, guardian OR timelock)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IPolicyRegistry
    /// @dev Tighten = every dimension ≤ current. Prevents the immediate (no-delay) path from
    ///      being abused to loosen. Requires the policy to already be configured.
    function tightenAssetPolicy(address sender, address asset, AssetPolicyInput calldata params)
        external
        onlyGuardianOrTimelock
    {
        _requireValidAsset(asset);
        AssetPolicy storage cur = _assetPolicy[sender][asset];
        if (!cur.configured) revert NotStrictlyTighter();
        // GOVERNANCE INVARIANT: dvtTriggerAmount==0 is the "DVT disabled" sentinel
        // (checkPolicy treats 0 as "no amount-based trigger"), so 0 is the LOOSEST value,
        // not the tightest. Setting a configured non-zero trigger to 0 via this IMMEDIATE
        // guardian path would DISABLE DVT — a LOOSENING that must go through the 2-day
        // timelock, never the instant path. Treat 0 as +infinity: reject tightening a live
        // trigger down to 0. (Without this, the "instant path only tightens" invariant breaks.)
        if (cur.dvtTriggerAmount != 0 && params.dvtTriggerAmount == 0) revert NotStrictlyTighter();
        // Lower dvtTriggerAmount ⇒ DVT required sooner ⇒ tighter. Lower caps/limit ⇒ tighter.
        if (
            params.dvtTriggerAmount > cur.dvtTriggerAmount || params.perTxHardCap > cur.perTxHardCap
                || params.dailyLimit > cur.dailyLimit
        ) revert NotStrictlyTighter();
        cur.dvtTriggerAmount = params.dvtTriggerAmount;
        cur.perTxHardCap = params.perTxHardCap;
        cur.dailyLimit = params.dailyLimit;
        // windowSeconds left unchanged: shrinking/growing a window is not monotone in safety.
        emit AssetPolicySet(
            sender, asset, params.dvtTriggerAmount, params.perTxHardCap, params.dailyLimit
        );
        emit PolicyTightened(sender, msg.sender);
    }

    /// @inheritdoc IPolicyRegistry
    /// @dev Tighten = disallow target (true→false ok, false→true forbidden), set requireDVTAlways
    ///      (false→true ok, true→false forbidden), lower velocityLimit, and REMOVE the listed
    ///      selectors from the allow set. Requires the scope to already be configured.
    function tightenContractScope(address sender, address target, ContractScopeInput calldata params)
        external
        onlyGuardianOrTimelock
    {
        if (target == address(0)) revert ZeroAddress();
        ContractScope storage cur = _contractScope[sender][target];
        if (!cur.configured) revert NotStrictlyTighter();
        // Cannot newly allow a target via the immediate path.
        if (params.allowed && !cur.allowed) revert NotStrictlyTighter();
        // Cannot drop a requireDVTAlways flag via the immediate path.
        if (cur.requireDVTAlways && !params.requireDVTAlways) revert NotStrictlyTighter();
        // Cannot raise velocity via the immediate path.
        if (params.velocityLimit > cur.velocityLimit) revert NotStrictlyTighter();

        cur.allowed = params.allowed;
        cur.requireDVTAlways = params.requireDVTAlways;
        cur.velocityLimit = params.velocityLimit;
        // velocityWindow left unchanged: setting it to 0 would DISABLE the velocity check
        // (a loosening), which must not be reachable via the immediate path.
        emit ContractScopeSet(
            sender, target, params.allowed, params.requireDVTAlways, params.velocityLimit, cur.velocityWindow
        );

        // Selectors listed here are REMOVED (the tighten direction of the additive set).
        uint256 len = params.selectorAllowlist.length;
        for (uint256 i; i < len; ++i) {
            bytes4 sel = params.selectorAllowlist[i];
            _selectorAllowed[sender][target][sel] = false;
            emit SelectorScopeSet(sender, target, sel, false);
        }
        emit PolicyTightened(sender, msg.sender);
    }

    /// @inheritdoc IPolicyRegistry
    function freezeSender(address sender) external onlyGuardianOrTimelock {
        _frozen[sender] = true;
        emit SenderFrozen(sender, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3c. Governance — admin (onlyTimelock)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IPolicyRegistry
    function setGuardian(address newGuardian) external onlyTimelock {
        if (newGuardian == address(0)) revert ZeroAddress();
        address old = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(old, newGuardian);
    }

    /// @inheritdoc IPolicyRegistry
    function setConsumerAuthorization(address consumer, bool authorized) external onlyTimelock {
        if (consumer == address(0)) revert ZeroAddress();
        _authorizedConsumer[consumer] = authorized;
        emit ConsumerAuthorizationSet(consumer, authorized);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IPolicyRegistry
    function getAssetPolicy(address sender, address asset)
        external
        view
        returns (AssetPolicy memory)
    {
        return _assetPolicy[sender][asset];
    }

    /// @inheritdoc IPolicyRegistry
    function getContractScope(address sender, address target)
        external
        view
        returns (ContractScope memory)
    {
        return _contractScope[sender][target];
    }

    /// @inheritdoc IPolicyRegistry
    function isSelectorAllowed(address sender, address target, bytes4 selector)
        external
        view
        returns (bool)
    {
        return _selectorAllowed[sender][target][selector];
    }

    /// @inheritdoc IPolicyRegistry
    function getAssetSpend(address sender, address asset)
        external
        view
        returns (uint128 spentInWindow, uint64 windowStart)
    {
        SpendCounter storage c = _assetSpend[sender][asset];
        return (c.spentInWindow, c.windowStart);
    }

    /// @inheritdoc IPolicyRegistry
    function isFrozen(address sender) external view returns (bool) {
        return _frozen[sender];
    }

    /// @inheritdoc IPolicyRegistry
    function isAuthorizedConsumer(address consumer) external view returns (bool) {
        return _authorizedConsumer[consumer];
    }

    // `guardian` and `timelock` getters are auto-generated from the public state vars.

    /// @notice Contract version (see CLAUDE.md versioning convention).
    function version() external pure returns (string memory) {
        return "PolicyRegistry-1.0.0";
    }
}
