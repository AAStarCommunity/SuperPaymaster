# PolicyRegistry — Interface & Governance Design

> **Status:** Interface draft for consumer alignment (no contract body yet).
> **Owner / lead:** SuperPaymaster (DVT cross-repo program).
> **Deliverable:** `contracts/src/interfaces/v3/IPolicyRegistry.sol` + this doc.
> **Coordination hub:** `AAStarCommunity/YetAnotherAA-Validator#42` (single source of truth).
> **Blocks:** `airaccount-contract#110` (consumer: account-side DVT gate) and `AirAccount#70`
> (consumer: combined-signature verification). Both wait on this interface to build their reads.
> **Companion threads:** SuperPaymaster `#283`, hub `#42` design item **#2** (policy governance),
> aastar-sdk `#63` (owner-facing policy client).

---

## 0. TL;DR

`PolicyRegistry` is a **single-instance, sender-keyed, governance-gated, on-chain** registry that
answers one question cheaply at validation time:

> For this `(sender, target, asset, amount, selector)`, is the op **ALLOW**ed,
> does it **REQUIRE_DVT** co-sign, or must it be **REJECT**ed?

It is the **single source of truth** for the DVT trigger policy: the same registry that DVT nodes
read to decide "should I co-sign this op" is the one the **slash path** references to decide
"was this op within policy" — so punishment is fair (node-policy-source == slash-policy-source).

It deliberately stores limits in **asset-native units** (no USD oracle), and it is the on-chain,
sender-keyed generalization of two primitives **already shipped** by `airaccount-contract`
(`v0.18.0-beta.2`): `AAStarGlobalGuard.TokenConfig` (per-asset amount) and
`SessionKeyValidator.Session` (per-contract / selector / velocity).

---

## 1. Why a separate registry (the sender-keyed / ERC-7562 rationale)

ERC-4337 bundlers reject a UserOp whose validation phase touches storage the `sender` does not
"own" (ERC-7562 associated-storage rules). A paymaster or account can only read storage during
validation if it is **sender-associated** — a `mapping(address sender => …)` slot — **and** the
reading entity is **staked** at the EntryPoint (which buys the relaxed associated-storage grace).

That is exactly why the DVT trigger state **cannot** live in `airaccount-contract`'s existing
`AAStarGlobalGuard` (a per-account guard contract): reading another contract's `todaySpent` during
validation is illegal, so in `v0.18` those amount tiers are enforced at **execution** time. To
enforce the DVT trigger at **validation** time (decision **2a** in hub #42), the state must be:

1. **keyed by `sender`** — every counter and policy entry is `mapping(address sender => …)`, so a
   consumer reading `spent[sender]` is reading sender-associated storage → bundler-legal; and
2. **read by a staked entity** — SuperPaymaster is staked
   (`BasePaymasterUpgradeable.addStake`), AirAccount accounts validate their own ops.

This **mirrors SuperPaymaster's existing pattern exactly.** SP already does sender-keyed,
validation-time cap enforcement — the credit ceiling. In `_creditExceeded(token, user, charge)`
(`contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`):

```solidity
function _creditExceeded(address token, address user, uint256 charge) internal view returns (bool) {
    uint256 used = IxPNTsToken(token).getDebt(user) + pendingDebts[token][user];
    return used + charge > REGISTRY.getCreditLimit(user);
}
```

Everything there is sender (`user`)-keyed, it is a `view`, and it is called inside
`validatePaymasterUserOp` — legal **because SP is staked**. `PolicyRegistry.checkPolicy` is the same
shape: a cheap, sender-keyed `view`, read at validation time by a staked consumer.

> Decision **2a** from hub #42, verbatim intent: *"PolicyRegistry is a singleton + sender-keyed
> mapping + staked → validation-period readable. The DVT trigger state MUST live here (SP mode),
> not in the per-account guard, otherwise it's not validation-readable."*

---

## 2. The interface

### 2.1 Validation-time read (cheap `view`, sender-keyed)

```solidity
function checkPolicy(
    address sender,
    address target,
    address asset,
    uint256 amount,
    bytes4 selector
) external view returns (PolicyDecision decision, uint256 remainingDaily);

enum PolicyDecision { ALLOW, REQUIRE_DVT, REJECT }
```

| Return | Meaning | Consumer action |
|---|---|---|
| `ALLOW` | within all caps, below DVT trigger, target+selector allowlisted, not frozen | proceed with the normal single (KMS/owner) signature |
| `REQUIRE_DVT` | within the per-tx hard cap but `amount ≥ dvtTriggerAmount` (or target flagged `requireDVTAlways`) | additionally verify a ≥threshold **DVT BLS aggregate co-sign bound to this `userOpHash`** (SP #283 / AirAccount #70); if absent → reject |
| `REJECT` | over `perTxHardCap`, not on the contract/selector allowlist, velocity/daily exhausted, or `sender` frozen | fail validation |

`remainingDaily` returns the asset's remaining native-unit allowance in the current window after
this `amount` would post (0 on a cap-based REJECT), so a consumer/UI gets headroom in one call.

> A tri-state enum (not `(bool inPolicy, bool needsDVT)`) was chosen because the three outcomes
> are genuinely distinct and a consumer branches on all three. The `(inPolicy, needsDVT)` mapping
> is: `ALLOW=(true,false)`, `REQUIRE_DVT=(true,true)`, `REJECT=(false,*)`.

### 2.2 Execution-time debit hook (`postOp` updates `spent[sender]`)

```solidity
function recordSpend(
    address sender,
    address target,
    address asset,
    uint256 amount,
    bytes4 selector
) external; // authorized staked consumers only
```

Called **after** execution (SP `postOp`, or the account post-call). It advances the per-asset and
per-target sender-keyed counters, rolling the window when elapsed. Same key tuple as `checkPolicy`
so per-target velocity can be charged. This is the **authoritative** debit: even though validation
read a slightly-stale counter, `recordSpend` closes the drain-then-bypass window — the same
belt-and-suspenders philosophy SP uses when it reconciles credit in `postOp`. `recordSpend` reverts
unless `msg.sender` is an authorized (staked) consumer.

### 2.3 Governance setters (asymmetric timelock + guardian)

| Direction | Functions | Delay | Caller |
|---|---|---|---|
| **Loosen** (raise cap / widen scope / unfreeze) | `proposeAssetPolicy`, `proposeContractScope`, `proposeUnfreeze` → `executeProposal` | **2 days** (`LOOSEN_TIMELOCK`) | governance |
| cancel a pending loosening | `cancelProposal` | immediate | governance **or guardian** |
| **Tighten** (lower cap / narrow scope) | `tightenAssetPolicy`, `tightenContractScope` | **immediate** | governance |
| **Freeze** (all ops → REJECT) | `freezeSender` | **immediate** | governance **or guardian** |
| admin | `setGuardian`, `setConsumerAuthorization` | immediate | governance |

`propose*` revert unless the params are *strictly looser* than current; `tighten*` revert unless
*strictly tighter*. Direction is enforced on-chain — a CA/owner key can never bypass it.

### 2.4 Config value types (reuse #110's shipped shapes)

```solidity
// per-(sender, asset) amount limits — mirrors AAStarGlobalGuard.TokenConfig
//   struct TokenConfig { uint128 tier1Limit; uint128 tier2Limit; uint256 dailyLimit; }
struct AssetPolicy {
    uint128 dvtTriggerAmount; // ≈ tier2Limit: single-tx amount ≥ this → REQUIRE_DVT
    uint128 perTxHardCap;     // single-tx amount > this → REJECT (CA-immutable upper bound)
    uint256 dailyLimit;       // cumulative spend over the window → REJECT when exceeded
    bool configured;
}

// per-(sender, target) scope — mirrors SessionKeyValidator.Session
//   struct Session { address[] callTargets; bytes4[] selectorAllowlist;
//                    velocityLimit; velocityWindow; ... }
struct ContractScope {
    bool allowed;          // target on the sender's call-target allowlist
    bool requireDVTAlways; // this target always needs DVT co-sign, any amount
    uint128 velocityLimit; // max cumulative amount to this target per window
    uint64  velocityWindow;// window length, seconds (0 ⇒ none)
    bool configured;
}
```

All amounts are **native asset units**. There is **no price oracle** and **no global USD
threshold** — that is the frozen "asset-native amounts" requirement. (A global USD floor, if ever
wanted, is a consumer-side fallback, not this registry's concern.)

### 2.5 Storage shape (sender-keyed)

```solidity
// policy config (governance-gated)
mapping(address sender => mapping(address asset  => AssetPolicy))            _assetPolicy;
mapping(address sender => mapping(address target => ContractScope))          _contractScope;
mapping(address sender => mapping(address target =>
          mapping(bytes4 selector => bool)))                                 _selectorAllowed;
mapping(address sender => bool)                                              _frozen;

// sender-keyed cumulative spend / velocity counters ("todaySpent") — the
// associated-storage that makes validation-time reads ERC-7562-legal
struct SpendCounter { uint128 spentInWindow; uint64 windowStart; }
mapping(address sender => mapping(address asset  => SpendCounter))           _assetSpend;
mapping(address sender => mapping(address target => SpendCounter))           _targetSpend;

// governance machinery
mapping(bytes32 proposalId => uint64 eta)                                    _looseningEta;
mapping(address consumer => bool)                                            _authorizedConsumer;
address guardian;              // AirAccount 2-of-3 RecoveryService
uint256 LOOSEN_TIMELOCK;       // = 2 days
```

Every policy entry **and every counter is keyed by `sender` first** — that is the load-bearing
property for ERC-7562 validation-time reads.

---

## 3. Governance model

- **Governance** owns all policy mutation. Not a CA/owner EOA acting alone — the on-chain flow is
  the only path, satisfying hub #42 命门 **②** (CA cannot change policy).
- **Asymmetric timelock**:
  - *Loosening* (raise a cap, widen an allowlist, lift a freeze) goes `propose → wait 2 days →
    execute`. The delay is observable on-chain, so a stolen owner key cannot "raise the cap to
    infinity then drain" — the victim/guardian sees the pending `LooseningProposed` and can
    `cancelProposal` / `freezeSender` before ETA.
  - *Tightening / freeze* is **immediate** — defense must never wait for an attacker's timelock.
- **Guardian = AirAccount 2-of-3 RecoveryService**: may `freezeSender` and `cancelProposal`
  immediately (incident response), but **cannot loosen** — unfreezing still goes through the
  2-day `proposeUnfreeze → executeProposal` path.
- **aastar-sdk #63** is a *client* only: it shows pending proposals + ETA and submits
  propose/tighten/freeze txns. It can **never** apply a loosening by itself (no SDK/owner-key
  short-circuit) — exactly the constraint the SDK owner called out in #42 ("must reflect on-chain
  pending state, not self-adjudicate", the `resolveAPNTsToken` pattern).

This mirrors SP's existing trust model: SP already reads credit tiers from the
governance-controlled `Registry` (`getCreditLimit`), not from a per-tx caller — the PolicyRegistry
generalizes that to per-(asset/contract/selector) DVT triggers.

---

## 4. node-policy-source == slash-policy-source (fair punishment)

The DVT punishment loop must be **fair**: a node is only slashable for deviating from a policy that
was *actually on-chain and in-force*. So both ends read the **same** registry:

- **DVT nodes** (off-chain `PolicyService`, hub-repo) read `getAssetPolicy` / `getContractScope` /
  `isSelectorAllowed` / `isFrozen` (plus index `AssetPolicySet` / `ContractScopeSet` /
  `SenderFrozen` events) to decide whether to co-sign.
- **The slash path** references the same registry:
  - SuperPaymaster `executeSlashWithBLS(operator, level, proof)` and
    `GTokenStaking.slashByDVT(...)` — when adjudicating a DVT-triggered slash — derive
    "was this op within policy" from the **same** `checkPolicy` + `getAssetSpend` config, not from
    any node-local or off-chain rule.

Practical note: on-chain history of a *past* decision is not stored, so the slash path references
the **current deterministic config** for the `(sender, asset, target, selector)` in question plus
the recorded counter. The frozen requirement is satisfied: the policy source the node reads is
*the same contract/schema* the slash path reads. Where SP's slash references it is annotated in
`executeSlashWithBLS` (the `proof` is bound to the op; the policy lookup is `checkPolicy`).

---

## 5. How each repo consumes it

| Repo / issue | Role | What it calls |
|---|---|---|
| **SuperPaymaster** (this repo) | staked paymaster consumer | `checkPolicy` in `validatePaymasterUserOp` (alongside `_creditExceeded`); `recordSpend` in `postOp`; slash path references `checkPolicy` |
| **airaccount-contract #110** | account-side DVT gate | `checkPolicy` in `validateUserOp` to decide if the combined sig must include a DVT aggregate; reads `getAssetPolicy`/`getContractScope` to surface limits |
| **AirAccount #70** | combined-signature verifier | on `REQUIRE_DVT`, verify KMS main sig + ≥threshold DVT BLS aggregate bound to `userOpHash`; off-chain KMS gate reads the same registry to decide whether to demand a co-sign |
| **aastar-sdk #63** | owner-facing policy client | `propose*` / `tighten*` / `freezeSender`, plus reads `looseningEta` + events to show pending state + ETA |
| **DVT nodes** (hub repo) | policy reader + co-signer | `getAssetPolicy` / `getContractScope` / `isSelectorAllowed` / events |

---

## 6. Open questions for #110 alignment

1. **`dvtTriggerAmount` ↔ `TokenConfig` tier mapping.** `TokenConfig` has `tier1Limit`,
   `tier2Limit`, `dailyLimit`. This draft folds them into `dvtTriggerAmount` (≈ tier2),
   `perTxHardCap`, `dailyLimit`. **Does #110 want both tiers exposed** (e.g. tier1 = "needs +1
   factor", tier2 = "needs DVT"), or is a single DVT trigger + hard cap sufficient? If a
   multi-factor ladder is needed, `PolicyDecision` may need a `REQUIRE_EXTRA` variant or a
   `factorsRequired` return field.

2. **Window semantics for `dailyLimit` / velocity.** Fixed UTC-day reset vs rolling-window vs
   per-policy `windowSeconds`? `v0.18`'s `TokenConfig.dailyLimit` + `Session.velocityWindow` —
   what exact reset rule do they use? This draft keeps `windowStart` + a `windowSeconds`
   (rolling); confirm to match.

3. **Selector set-semantics.** `ContractScopeInput.selectorAllowlist` is additive (marks listed
   selectors allowed). `Session.selectorAllowlist` — is it a replace-set or additive? Replace-set
   makes loosen/tighten direction ambiguous; confirm additive (loosen = add, tighten = remove via
   `tightenContractScope`).

4. **ETH / native asset.** This draft uses `asset == address(0)` for ETH. Confirm #110's
   convention (some use a sentinel like `0xEeee…`).

5. **Who is "governance".** Concretely: a Timelock/Governor contract, the SP `Registry` owner, or a
   dedicated multisig? The asymmetric-timelock logic can live *inside* PolicyRegistry (as drafted)
   or be delegated to an external OZ `TimelockController`. #110/#42 should ratify which, since it
   sets whether `LOOSEN_TIMELOCK` is self-enforced or external.

6. **Combined-signature wire format coupling.** On `REQUIRE_DVT`, #70 defines how the DVT aggregate
   is packed into `UserOp.signature` (hub #42: align on existing `0x04/0x05/0x07` cumulative tiers,
   do not invent a new format). PolicyRegistry only emits the *requirement*; confirm #70 owns the
   wire format and PolicyRegistry stays format-agnostic (it should).
