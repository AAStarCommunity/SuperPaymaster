// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title IPolicyRegistry — sender-keyed, governance-gated DVT trigger / spend policy
/// @author SuperPaymaster (DVT cross-repo program, hub: AAStarCommunity/YetAnotherAA-Validator#42)
/// @notice Single source of truth for "is this op within policy / does it need DVT co-sign".
///         Read by staked EntryPoint consumers (SuperPaymaster) during
///         `validatePaymasterUserOp`, by AirAccount accounts (#70) during `validateUserOp`,
///         and by DVT nodes / the slash path off-chain. ALL of those read the SAME registry
///         and the SAME schema so that the policy a node enforces == the policy the slash
///         path punishes against (fair punishment).
///
/// @dev DESIGN INVARIANTS (frozen by DVT coordination — non-negotiable):
///
///   1. PER-SENDER KEYED, NOT per-operator. Every cumulative counter (`spent` / velocity)
///      and every policy entry is keyed by `sender` (the AA account address). This is the
///      entire reason this is a *separate* registry: a consumer may read `spent[sender]`
///      during validation because it is **sender-associated storage** under ERC-7562, so the
///      bundler does not reject the UserOp for accessing storage the sender does not own.
///
///   2. STAKED-VALIDATION ENFORCEMENT. The consumer (SuperPaymaster) is a staked EntryPoint
///      entity (`BasePaymasterUpgradeable.addStake`), which earns the relaxed associated-
///      storage grace to read this governance config + the sender-keyed counters during
///      validation. Therefore `checkPolicy` MUST be a cheap `view` keyed by `sender`.
///      This mirrors SP's existing credit ceiling `_creditExceeded(token,user,charge)`
///      (`SuperPaymaster.sol`), which already reads `getDebt(user)+pendingDebts+charge <=
///      getCreditLimit(user)` — all sender-keyed — inside `validatePaymasterUserOp`.
///
///   3. GOVERNANCE-GATED, CA CANNOT CHANGE IT. Policy params change ONLY via governance —
///      never by a controlling account (CA) / owner key directly.
///      LOOSENING (raise a cap / widen scope / unfreeze) flows through an EXTERNAL OZ
///      {TimelockController} (Q5): governance schedules the call on the timelock, whose own
///      `minDelay` (= 2 days) provides the observable delay, then executes it — at which point
///      the timelock (and ONLY the timelock) calls the loosening setters here (`onlyTimelock`).
///      TIGHTENING / FREEZE = immediate, callable by the guardian OR the timelock
///      (`onlyGuardianOrTimelock`). Guardian = AirAccount's 2-of-3 RecoveryService.
///      Cancelling an in-flight loosening is handled by the TimelockController's own
///      CANCELLER_ROLE (granted to the guardian) — no registry-level proposal store exists.
///      An owner key compromise therefore cannot "raise the cap to infinity then drain":
///      loosening is delayed and observable; tightening/freeze defends instantly.
///
///   4. ASSET-NATIVE AMOUNTS, NO USD ORACLE. All limits are expressed in the asset's own
///      native units (`uint*` of the ERC-20). This registry deliberately does NOT reuse
///      PaymasterV4's Chainlink price oracle. A global USD threshold is out of scope.
///
///   5. SCHEMA REUSES #110's SHIPPED PRIMITIVES (airaccount-contract v0.18.0-beta.2):
///        - per-asset amount limits  ← `AAStarGlobalGuard.TokenConfig`
///                                       (uint128 tier1Limit; uint128 tier2Limit; uint256 dailyLimit)
///        - per-contract / selector / velocity scoping ← `SessionKeyValidator.Session`
///                                       (address[] callTargets; bytes4[] selectorAllowlist;
///                                        velocityLimit; velocityWindow)
///      This registry is the on-chain, sender-keyed, staked generalization of those two
///      structs, plus the DVT-trigger factor (amount → which signing factors are required).
interface IPolicyRegistry {
    // ─────────────────────────────────────────────────────────────────────────
    // Decision semantics
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Tri-state result of a validation-time policy read.
    /// @dev OPT-IN, default-ALLOW: a sender with NO policy configured for the (asset, target) is
    ///      UNRESTRICTED and resolves to ALLOW (this is an opt-in DVT layer, NOT a global
    ///      allowlist). The consumer maps the result to its own action:
    ///        ALLOW       → proceed with normal validation (single KMS/owner signature). Returned
    ///                      when nothing relevant is configured, or every configured dimension is
    ///                      satisfied below its DVT trigger.
    ///        REQUIRE_DVT → within the hard ceiling but past a *configured* DVT trigger threshold
    ///                      (`dvtTriggerAmount != 0 && amount >= dvtTriggerAmount`) or the target is
    ///                      a *configured* scope flagged `requireDVTAlways`: the consumer MUST
    ///                      additionally verify a ≥threshold DVT BLS aggregate co-sign bound to this
    ///                      userOpHash (SuperPaymaster #283 / AirAccount #70). If absent → reject.
    ///        REJECT      → the sender is frozen (explicit hard block, highest priority), OR a
    ///                      *configured* dimension is violated: over the per-tx hard cap, projected
    ///                      over the daily limit, target/selector not on a configured allowlist, or
    ///                      a configured velocity window exhausted → fail validation.
    enum PolicyDecision {
        ALLOW,
        REQUIRE_DVT,
        REJECT
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Config value types (mirrors #110 shipped primitives)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Per-(sender, asset) amount policy. Mirrors `AAStarGlobalGuard.TokenConfig`,
    ///         resolved (per cross-repo Q1) to a SINGLE DVT-trigger + a hard cap (no tier1/tier2,
    ///         no REQUIRE_EXTRA tier).
    /// @dev `dvtTriggerAmount` (single-tx amount at/above which DVT co-sign is required);
    ///      `0` ⇒ the amount-based DVT trigger is DISABLED (no amount alone forces DVT — matching
    ///      the "0 = unlimited / unset" convention; `requireDVTAlways` on a configured contract
    ///      scope still forces DVT independently).
    ///      `perTxHardCap` is the immutable-by-CA upper bound (over → REJECT);
    ///      `dailyLimit` is the cumulative per-asset ceiling over `windowSeconds`.
    ///      `windowSeconds` (Q2) is the configurable daily-limit window; 0 ⇒ DEFAULT_WINDOW (1 day).
    ///      All amounts are in the asset's native units (no USD conversion).
    ///      `configured == false` ⇒ this (sender, asset) is UNRESTRICTED (opt-in): no cap, no
    ///      daily limit, no amount-based DVT trigger.
    struct AssetPolicy {
        uint128 dvtTriggerAmount; // single-tx amount ≥ this → REQUIRE_DVT; 0 ⇒ trigger DISABLED
        uint128 perTxHardCap;     // single-tx amount  > this → REJECT (only when configured)
        uint256 dailyLimit;       // cumulative spend over `windowSeconds` → REJECT when exceeded
        uint64 windowSeconds;     // daily-limit window length (Q2); 0 ⇒ DEFAULT_WINDOW (1 day)
        bool configured;          // false ⇒ no policy set for this (sender, asset) ⇒ UNRESTRICTED
    }

    /// @notice Input form of {AssetPolicy} for governance setters (no `configured` flag).
    struct AssetPolicyInput {
        uint128 dvtTriggerAmount;
        uint128 perTxHardCap;
        uint256 dailyLimit;
        uint64 windowSeconds; // 0 ⇒ DEFAULT_WINDOW (1 day)
    }

    /// @notice Per-(sender, target-contract) scope. Mirrors `SessionKeyValidator.Session`
    ///         (callTargets / selectorAllowlist / velocityLimit / velocityWindow).
    /// @dev Selector allow-list lives in a nested mapping in storage (see STORAGE SHAPE),
    ///      so this view struct returns scalars only; query selectors via {isSelectorAllowed}.
    struct ContractScope {
        bool allowed;             // target on this sender's call-target allowlist
        bool requireDVTAlways;    // this target always requires DVT co-sign regardless of amount
        uint128 velocityLimit;    // max cumulative amount routed to this target per window
        uint64 velocityWindow;    // velocity window length, seconds (0 ⇒ no velocity limit)
        bool configured;          // false ⇒ no scope set for this (sender, target)
    }

    /// @notice Input form of {ContractScope} for governance setters; selectors set as a batch.
    struct ContractScopeInput {
        bool allowed;
        bool requireDVTAlways;
        uint128 velocityLimit;
        uint64 velocityWindow;
        bytes4[] selectorAllowlist; // selectors to mark allowed for this target
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STORAGE SHAPE (informative — the implementing contract declares these; an
    // interface cannot. Counters are sender-keyed precisely so a staked consumer
    // may read them at validation time under ERC-7562.)
    //
    //   // policy config (governance-gated)
    //   mapping(address sender => mapping(address asset  => AssetPolicy))     _assetPolicy;
    //   mapping(address sender => mapping(address target => ContractScope))   _contractScope;
    //   mapping(address sender => mapping(address target =>
    //             mapping(bytes4 selector => bool)))                          _selectorAllowed;
    //   mapping(address sender => bool)                                       _frozen;
    //
    //   // sender-keyed cumulative spend / velocity counters ("todaySpent")
    //   struct SpendCounter { uint128 spentInWindow; uint64 windowStart; }
    //   mapping(address sender => mapping(address asset  => SpendCounter))    _assetSpend;
    //   mapping(address sender => mapping(address target => SpendCounter))    _targetSpend;
    //
    //   // governance machinery (Q5: delay provided by an EXTERNAL OZ TimelockController)
    //   mapping(address consumer => bool)                                    _authorizedConsumer;
    //   address  guardian;            // AirAccount 2-of-3 RecoveryService (immediate tighten/freeze)
    //   address  timelock;            // OZ TimelockController; its minDelay (2 days) gates loosening
    // ─────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Validation-time read  (cheap view, sender-keyed)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Validation-time policy decision for one intended action. MUST be `view` and
    ///         read only `sender`-associated storage so a staked consumer can call it inside
    ///         `validatePaymasterUserOp` / `validateUserOp` without a bundler storage violation.
    /// @dev OPT-IN, default-ALLOW (NOT a global allowlist). An explicit `freeze` ⇒ REJECT (the one
    ///      hard block, top priority). Otherwise each dimension is enforced ONLY when `configured`:
    ///      an unconfigured asset is UNRESTRICTED (no cap / daily / amount-DVT; `remainingDaily ==
    ///      type(uint256).max`) and an unconfigured target is UNRESTRICTED (no allow-list / selector
    ///      / velocity / requireDVTAlways check). Combine: any configured dimension ⇒ REJECT wins;
    ///      else any configured dimension ⇒ REQUIRE_DVT wins; else ALLOW. A sender with NOTHING
    ///      configured ⇒ ALLOW with `remainingDaily == type(uint256).max`.
    /// @param sender   the AA account address (the policy + counter key).
    /// @param target   the contract the op will call.
    /// @param asset    the ERC-20 whose `amount` is being moved (native units; the ETH sentinel
    ///                 `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` = ETH). `address(0)` is INVALID
    ///                 (reverts ZeroAddress) — 0xEee is the explicit ETH marker (Q4).
    /// @param amount   the asset amount in native units.
    /// @param selector the function selector being invoked on `target`.
    /// @return decision ALLOW / REQUIRE_DVT / REJECT (see {PolicyDecision}).
    /// @return remainingDaily the asset's remaining native-unit allowance in the current window
    ///         AFTER this `amount` would post (0 when REJECT due to a cap; `type(uint256).max` when
    ///         the asset is UNRESTRICTED / not configured). Lets the consumer surface "how much
    ///         headroom is left" without a second call.
    function checkPolicy(
        address sender,
        address target,
        address asset,
        uint256 amount,
        bytes4 selector
    ) external view returns (PolicyDecision decision, uint256 remainingDaily);

    // ─────────────────────────────────────────────────────────────────────────
    // 2. Execution-time debit hook  (postOp / post-execution updates spent[sender])
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Authoritative spend record. Called AFTER execution (SuperPaymaster `postOp`,
    ///         or the account post-call) by an authorized staked consumer. Advances both the
    ///         per-asset and per-target sender-keyed counters, rolling the window if elapsed.
    /// @dev Same key tuple as {checkPolicy} so per-target velocity can be charged too.
    ///      MUST revert if `msg.sender` is not an authorized consumer (see {isAuthorizedConsumer}).
    ///      Belt-and-suspenders: even though validation saw a slightly-stale counter, this
    ///      authoritative debit closes the drain-then-bypass window (same mitigation philosophy
    ///      as SP's postOp credit reconciliation).
    /// @dev KNOWN LIMITATION — TOCTOU (accepted carry-forward, PR #285 round-3): the CUMULATIVE
    ///      checks (`dailyLimit`, `velocityLimit`) are read at validation and debited here at
    ///      postOp, so multiple ops from the SAME sender in ONE bundle each observe the pre-debit
    ///      counter and can collectively overshoot by up to a single bundle's worth — BOUNDED,
    ///      since the next bundle rejects. The PER-TX guards are UNAFFECTED: `perTxHardCap` and
    ///      `dvtTriggerAmount` are single-tx comparisons evaluated per op and cannot be bypassed
    ///      by bundling (a high-value op still trips its hard cap / still requires DVT). This is
    ///      inherent to the ERC-4337 validation/execution split (identical to SP's credit
    ///      ceiling). An atomic check-and-debit was evaluated and DEFERRED: it would need a
    ///      state-writing validation-time call (ERC-7562 associated-storage risk) plus on-revert
    ///      refund logic, and the bounded residual does not justify that complexity.
    /// @param sender   the AA account (counter key).
    /// @param target   the contract that was called.
    /// @param asset    the asset spent (native units; ETH sentinel 0xEee…EEeE = ETH; address(0) invalid).
    /// @param amount   the asset amount actually spent.
    /// @param selector the selector invoked.
    function recordSpend(
        address sender,
        address target,
        address asset,
        uint256 amount,
        bytes4 selector
    ) external;

    // ─────────────────────────────────────────────────────────────────────────
    // 3a. Governance — LOOSENING path  (Q5: gated by an EXTERNAL OZ TimelockController)
    //
    // These setters are `onlyTimelock`: they revert unless `msg.sender == timelock()`.
    // The 2-day delay is NOT re-implemented here — it is the TimelockController's own
    // `minDelay`. Governance `schedule()`s a call to one of these on the timelock, waits
    // out the delay, then `execute()`s it, which makes the timelock call back into the
    // setter. Because every call already cleared the delayed path, these setters may move a
    // policy in EITHER direction (loosen or tighten) with no per-dimension direction check —
    // the delay itself is the safety property. (Immediate TIGHTENING uses 3b instead.)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set a (sender, asset) policy. `onlyTimelock` — reached only after the timelock's
    ///         2-day delay, so it may loosen or tighten. `asset` must not be `address(0)`
    ///         (use the ETH sentinel for ETH). Emits {AssetPolicySet}.
    function setAssetPolicy(
        address sender,
        address asset,
        AssetPolicyInput calldata params
    ) external;

    /// @notice Set a (sender, target) scope and ADD the listed selectors to the allow set
    ///         (Q3: additive). `onlyTimelock`. Emits {ContractScopeSet} + {SelectorScopeSet}.
    /// @dev ADDITIVE semantics (Q3, by design — accepted carry-forward, PR #285 round-3):
    ///      re-calling UNIONS the new `selectorAllowlist` with whatever is already allowed; it
    ///      does NOT replace. To REMOVE selectors (a tightening) use {tightenContractScope}.
    ///      There is intentionally no single-call "replace": loosen adds, tighten removes — so
    ///      "swap the selector set" = tighten away the stale ones, then set the new ones. This
    ///      keeps loosen/tighten direction unambiguous for the timelock-vs-guardian split.
    function setContractScope(
        address sender,
        address target,
        ContractScopeInput calldata params
    ) external;

    /// @notice Lift a freeze on `sender`. Unfreeze is a loosening → `onlyTimelock`.
    function unfreezeSender(address sender) external;

    // ─────────────────────────────────────────────────────────────────────────
    // 3b. Governance — TIGHTENING / FREEZE path  (immediate, guardian OR timelock)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Immediately tighten a (sender, asset) policy. MUST revert unless the new params
    ///         are ≤ current on every dimension (NotStrictlyTighter). `onlyGuardianOrTimelock`.
    function tightenAssetPolicy(
        address sender,
        address asset,
        AssetPolicyInput calldata params
    ) external;

    /// @notice Immediately tighten a (sender, target) scope (disallow target, remove the listed
    ///         selectors, lower velocity, set requireDVTAlways). MUST revert unless tighter.
    ///         `onlyGuardianOrTimelock`.
    function tightenContractScope(
        address sender,
        address target,
        ContractScopeInput calldata params
    ) external;

    /// @notice Immediately freeze `sender`: {checkPolicy} returns REJECT for all ops. Immediate
    ///         is the whole point — defense must not wait. `onlyGuardianOrTimelock` (guardian =
    ///         AirAccount 2-of-3 RecoveryService). Unfreezing is a loosening → {unfreezeSender}.
    function freezeSender(address sender) external;

    // ─────────────────────────────────────────────────────────────────────────
    // 3c. Governance — admin (`onlyTimelock`)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the guardian (AirAccount 2-of-3 RecoveryService) that may freeze/tighten.
    ///         `onlyTimelock`.
    function setGuardian(address guardian) external;

    /// @notice Authorize / revoke a staked consumer permitted to call {recordSpend}.
    ///         `onlyTimelock`. Only staked EntryPoint entities should be authorized.
    function setConsumerAuthorization(address consumer, bool authorized) external;

    // ─────────────────────────────────────────────────────────────────────────
    // 4. Views (config + counters + governance state)
    // ─────────────────────────────────────────────────────────────────────────

    function getAssetPolicy(address sender, address asset)
        external
        view
        returns (AssetPolicy memory);

    function getContractScope(address sender, address target)
        external
        view
        returns (ContractScope memory);

    function isSelectorAllowed(address sender, address target, bytes4 selector)
        external
        view
        returns (bool);

    /// @return spentInWindow cumulative native-unit spend in the current window for this asset.
    /// @return windowStart unix timestamp the current window began.
    function getAssetSpend(address sender, address asset)
        external
        view
        returns (uint128 spentInWindow, uint64 windowStart);

    function isFrozen(address sender) external view returns (bool);

    function isAuthorizedConsumer(address consumer) external view returns (bool);

    function guardian() external view returns (address);

    /// @notice The OZ {TimelockController} whose `minDelay` (= 2 days) gates every loosening.
    ///         It is the only address allowed to call the `onlyTimelock` loosening/admin setters.
    function timelock() external view returns (address);

    // ─────────────────────────────────────────────────────────────────────────
    // 5. Events  (off-chain monitoring + the node-policy-source == slash-policy-source link)
    //
    //    DVT nodes index {AssetPolicySet}/{ContractScopeSet}/{SenderFrozen} to know the
    //    in-force policy, and {SpendRecorded} to track usage. The slash path (SuperPaymaster
    //    `executeSlashWithBLS` / `GTokenStaking.slashByDVT`) references the SAME registry via
    //    {checkPolicy} + {getAssetSpend} so that what a node enforced == what is punished.
    // ─────────────────────────────────────────────────────────────────────────

    event AssetPolicySet(
        address indexed sender,
        address indexed asset,
        uint128 dvtTriggerAmount,
        uint128 perTxHardCap,
        uint256 dailyLimit
    );
    event ContractScopeSet(
        address indexed sender,
        address indexed target,
        bool allowed,
        bool requireDVTAlways,
        uint128 velocityLimit,
        uint64 velocityWindow
    );
    event SelectorScopeSet(
        address indexed sender,
        address indexed target,
        bytes4 indexed selector,
        bool allowed
    );

    /// @dev Emitted by the immediate tighten path; `actor` is the guardian or the timelock.
    event PolicyTightened(address indexed sender, address indexed actor);

    event SenderFrozen(address indexed sender, address indexed actor);
    event SenderUnfrozen(address indexed sender);

    event SpendRecorded(
        address indexed sender,
        address indexed asset,
        address indexed target,
        uint256 amount,
        bytes4 selector
    );

    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event ConsumerAuthorizationSet(address indexed consumer, bool authorized);

    // ─────────────────────────────────────────────────────────────────────────
    // 6. Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotTimelock();             // a `onlyTimelock` setter called by a non-timelock address
    error NotGuardianOrTimelock();   // a tighten/freeze called by neither guardian nor timelock
    error NotAuthorizedConsumer();
    error NotStrictlyTighter();      // a tighten* received params that are not a tightening
    error SenderIsFrozen();
    error ZeroAddress();
}
