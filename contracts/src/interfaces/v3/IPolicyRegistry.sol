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
///   3. GOVERNANCE-GATED, CA CANNOT CHANGE IT. Policy params change ONLY via the on-chain
///      governance flow below — never by a controlling account (CA) / owner key directly.
///      LOOSENING (raise a cap / widen scope / unfreeze) = 2-day timelock (propose→execute).
///      TIGHTENING / FREEZE = immediate. Guardian = AirAccount's 2-of-3 RecoveryService.
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
    /// @dev The consumer maps this to its own action:
    ///        ALLOW       → proceed with normal validation (single KMS/owner signature).
    ///        REQUIRE_DVT → within the hard ceiling but past the DVT trigger threshold (or the
    ///                      target is flagged `requireDVTAlways`): the consumer MUST additionally
    ///                      verify a ≥threshold DVT BLS aggregate co-sign bound to this userOpHash
    ///                      (SuperPaymaster #283 / AirAccount #70). If absent → reject.
    ///        REJECT      → over the per-tx hard cap, not on the contract/selector allowlist,
    ///                      velocity window exhausted, or the sender is frozen → fail validation.
    enum PolicyDecision {
        ALLOW,
        REQUIRE_DVT,
        REJECT
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Config value types (mirrors #110 shipped primitives)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Per-(sender, asset) amount policy. Mirrors `AAStarGlobalGuard.TokenConfig`.
    /// @dev `dvtTriggerAmount` ≈ tier2Limit (single-tx amount at/above which DVT co-sign is
    ///      required); `perTxHardCap` is the immutable-by-CA upper bound (over → REJECT);
    ///      `dailyLimit` is the cumulative per-asset ceiling over `windowSeconds`.
    ///      All amounts are in the asset's native units (no USD conversion).
    struct AssetPolicy {
        uint128 dvtTriggerAmount; // single-tx amount ≥ this → REQUIRE_DVT
        uint128 perTxHardCap;     // single-tx amount  > this → REJECT
        uint256 dailyLimit;       // cumulative spend over `windowSeconds` → REJECT when exceeded
        bool configured;          // false ⇒ no policy set for this (sender, asset)
    }

    /// @notice Input form of {AssetPolicy} for governance setters (no `configured` flag).
    struct AssetPolicyInput {
        uint128 dvtTriggerAmount;
        uint128 perTxHardCap;
        uint256 dailyLimit;
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
    //   // governance machinery
    //   mapping(bytes32 proposalId => uint64 eta)                            _looseningEta;
    //   mapping(address consumer => bool)                                    _authorizedConsumer;
    //   address  guardian;            // AirAccount 2-of-3 RecoveryService
    //   uint256  LOOSEN_TIMELOCK;     // = 2 days
    // ─────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────
    // 1. Validation-time read  (cheap view, sender-keyed)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Validation-time policy decision for one intended action. MUST be `view` and
    ///         read only `sender`-associated storage so a staked consumer can call it inside
    ///         `validatePaymasterUserOp` / `validateUserOp` without a bundler storage violation.
    /// @param sender   the AA account address (the policy + counter key).
    /// @param target   the contract the op will call.
    /// @param asset    the ERC-20 whose `amount` is being moved (native units; address(0) = ETH).
    /// @param amount   the asset amount in native units.
    /// @param selector the function selector being invoked on `target`.
    /// @return decision ALLOW / REQUIRE_DVT / REJECT (see {PolicyDecision}).
    /// @return remainingDaily the asset's remaining native-unit allowance in the current window
    ///         AFTER this `amount` would post (0 when REJECT due to a cap). Lets the consumer
    ///         surface "how much headroom is left" without a second call.
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
    /// @param sender   the AA account (counter key).
    /// @param target   the contract that was called.
    /// @param asset    the asset spent (native units; address(0) = ETH).
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
    // 3a. Governance — LOOSENING path  (2-day timelock: propose → execute)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Propose raising/widening a (sender, asset) policy. Subject to LOOSEN_TIMELOCK.
    /// @dev MUST revert if the proposed params are not strictly looser than current (a tighten
    ///      must use {tightenAssetPolicy}). Governance-only.
    /// @return proposalId deterministic id (keccak of params + sender) used by {executeProposal}.
    function proposeAssetPolicy(
        address sender,
        address asset,
        AssetPolicyInput calldata params
    ) external returns (bytes32 proposalId);

    /// @notice Propose allowing/widening a (sender, target) scope (allow target, add selectors,
    ///         raise velocity). Subject to LOOSEN_TIMELOCK. Governance-only.
    /// @return proposalId id used by {executeProposal}.
    function proposeContractScope(
        address sender,
        address target,
        ContractScopeInput calldata params
    ) external returns (bytes32 proposalId);

    /// @notice Propose lifting a freeze on `sender`. Unfreeze is a loosening → timelocked.
    function proposeUnfreeze(address sender) external returns (bytes32 proposalId);

    /// @notice Execute a previously-proposed loosening once `block.timestamp >= eta`.
    ///         Governance-only. MUST revert before ETA or if cancelled.
    function executeProposal(bytes32 proposalId) external;

    /// @notice Cancel a pending loosening before it executes. Governance OR guardian
    ///         (a guardian must be able to abort an in-flight cap raise during an incident).
    function cancelProposal(bytes32 proposalId) external;

    // ─────────────────────────────────────────────────────────────────────────
    // 3b. Governance — TIGHTENING / FREEZE path  (immediate)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Immediately tighten a (sender, asset) policy. MUST revert unless the new params
    ///         are strictly ≤ current on every dimension. Governance-only.
    function tightenAssetPolicy(
        address sender,
        address asset,
        AssetPolicyInput calldata params
    ) external;

    /// @notice Immediately tighten a (sender, target) scope (disallow target, remove selectors,
    ///         lower velocity, set requireDVTAlways). MUST revert unless strictly tighter.
    ///         Governance-only.
    function tightenContractScope(
        address sender,
        address target,
        ContractScopeInput calldata params
    ) external;

    /// @notice Immediately freeze `sender`: {checkPolicy} returns REJECT for all ops. Immediate
    ///         is the whole point — defense must not wait. Callable by governance OR the guardian
    ///         (AirAccount 2-of-3 RecoveryService). Unfreezing is a loosening → {proposeUnfreeze}.
    function freezeSender(address sender) external;

    // ─────────────────────────────────────────────────────────────────────────
    // 3c. Governance — admin
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the guardian (AirAccount 2-of-3 RecoveryService) that may freeze/cancel.
    ///         Governance-only.
    function setGuardian(address guardian) external;

    /// @notice Authorize / revoke a staked consumer permitted to call {recordSpend}.
    ///         Governance-only. Only staked EntryPoint entities should be authorized.
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

    /// @return eta the timestamp a pending loosening becomes executable (0 if none/cancelled).
    function looseningEta(bytes32 proposalId) external view returns (uint64 eta);

    /// @notice The loosening timelock in seconds (= 2 days). Tightening/freeze bypass this.
    function LOOSEN_TIMELOCK() external view returns (uint256);

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

    event LooseningProposed(bytes32 indexed proposalId, address indexed sender, uint64 eta);
    event LooseningExecuted(bytes32 indexed proposalId, address indexed sender);
    event ProposalCancelled(bytes32 indexed proposalId, address indexed canceller);
    event PolicyTightened(address indexed sender, address indexed governor);

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

    error NotGovernance();
    error NotGuardianOrGovernance();
    error NotAuthorizedConsumer();
    error NotStrictlyLooser();   // a propose* received params that are not a loosening
    error NotStrictlyTighter();  // a tighten* received params that are not a tightening
    error ProposalNotReady();    // executeProposal before ETA
    error UnknownProposal();
    error SenderIsFrozen();
    error ZeroAddress();
}
