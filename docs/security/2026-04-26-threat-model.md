# SuperPaymaster Threat Model 2026-04-26

**Date**: 2026-04-26
**Branch**: `security/audit-2026-04-25`
**Author**: Local model (with Codex Tier 1 cross-check pending)
**Related docs**:
- `docs/security/2026-04-25-review.md` —— 18 P0 + 32 P1 + ~70 P2 audit findings
- `docs/security/2026-04-26-decision-records.md` —— D1-D8 user decisions
- `docs/security/2026-04-25-governance-slash-design.md` —— Optimistic Slash design (deferred to v6.0)
- `docs/security/2026-04-25-dvt-proof-scenarios.md` —— DVT proof attack scenarios

**Purpose**: 在写代码修复前，**显式声明 trust 假设**，把每个 P0 重新分类为"安全 bug"或"治理风险"，并枚举可能的 attack scenario。Codex Phase 6 反馈强调：

> "I would start by writing a concrete threat model (what is trusted: owner multisig? DVT quorum? Chainlink? factory?), and I would score findings against that model; several items are only 'P0' if you require trust minimization, otherwise they are governance centralization risks."

本文档是修复执行前的**最后一道方法学闸门**。

---

## 1. Scope

### 1.1 In-scope contracts

| Layer | Contract | Role |
|---|---|---|
| Core | `Registry.sol` | role + metadata + slashing dispatch |
| Core | `GTokenStaking.sol` | role lock + slash burn |
| Core | `SuperPaymaster.sol` | router + EntryPoint integration + accounting |
| Core | `MySBT.sol` | identity + reputation tracking |
| Tokens | `xPNTsFactory.sol` | per-community xPNTs deploy |
| Tokens | `xPNTsToken.sol` | community gas token + auto-approve firewall |
| Tokens | `aPNTsToken.sol` | unit of account (per D3, non-transferable redesign needed) |
| Tokens | `aPNTsSaleContract.sol` | **(new, per D3)** multisig-mint sale contract |
| Tokens | `GToken.sol` | governance / staking |
| Paymasters | `Paymaster.sol` (V4) | AOA mode independent paymaster |
| Paymasters | `PaymasterBase.sol` (V4) | shared base |
| Paymasters | `PaymasterFactory.sol` | EIP-1167 factory |
| Channels | `MicroPaymentChannel.sol` | EIP-712 voucher state channel |
| Modules | `BLSAggregator.sol` | BLS aggregate signature verification |
| Modules | `DVTValidator.sol` | DVT proposal lifecycle |
| Modules | `BLSValidator.sol` | (TO BE DELETED per P0-1) |
| Modules | `ReputationSystem.sol` | reputation scoring |
| x402 | `x402-facilitator-node` | off-chain settlement service |

### 1.2 Out-of-scope

- **Smart contract bytecode itself**: assume Solidity compiler 0.8.33 + optimizer is correct
- **EVM precompiles**: assume EIP-2537 (BLS12-381 pairing) on Pectra mainnet is correct
- **Chainlink oracle internal**: trust Chainlink price feed integrity (mitigation: D8 break-glass)
- **EntryPoint v0.7**: assume EntryPoint contract at `0x0000000071727De22E5E9d8BAf0edAc6f37da032` is correct
- **OpenZeppelin v5.0.2 / Solady**: assume audited libraries
- **Bundler / off-chain infrastructure** beyond x402-facilitator-node (e.g., user wallet UX, RPC providers)
- **Front-running / MEV at large**: protocol may experience MEV; not a primary defense target

---

## 2. Assets to Protect

| Asset | Description | Loss Bound | Recovery |
|---|---|---|---|
| **A1: Operator funds (aPNTsBalance)** | Each operator's accounting balance for sponsoring user gas | Per-operator deposit | Hard (need owner re-mint) |
| **A2: User USDC (x402)** | User-approved USDC available to facilitator | User's `approve(facilitator, X)` cap | Soft (re-approve) |
| **A3: User xPNTs balance** | Per-community gas token | $100 / tx (firewall) | Soft (issuer re-mint) |
| **A4: Operator GToken stake** | Locked GToken in `GTokenStaking.roleLocks` | Per-operator stake | Hard (true burn on slash) |
| **A5: Protocol revenue** | SP `protocolRevenue` accumulated fees | Bounded by accumulated fees | Owner withdraw |
| **A6: MPC channel balance** | Locked deposit in MicroPaymentChannel | Per-channel deposit | Hard (timelock + voucher dispute) |
| **A7: Reputation score** | `MySBT.reputation` + `ReputationSystem` | Per-user score | Soft (rebuild over time) |
| **A8: Service availability** | Paymaster's ability to sponsor gas (uptime) | Lost transaction volume | Soft (recover when oracle/bundler return) |
| **A9: Governance integrity** | Multisig / timelock / role config integrity | Catastrophic | None (requires fork) |

---

## 3. Trust Boundaries

> **Codex's central question**: "what is trusted?"
>
> Trust level definitions:
> - **TRUSTED**: Their action is taken at face value; no on-chain countermeasure if they misbehave.
> - **BOUNDED TRUST**: Trusted within explicit constraints (timelock, single-tx limit, multisig threshold). Misbehavior is bounded.
> - **PARTIAL TRUST**: Trusted under normal conditions but with on-chain detection + fallback paths.
> - **ADVERSARIAL**: Always assumed hostile; defenses are mandatory.

### 3.1 Trust matrix

| Actor | Trust Level | Reasoning | Safeguards | Failure Mode |
|---|---|---|---|---|
| **AAStar Owner Multisig (5/7 Safe)** | TRUSTED | Multi-key signers, accountable | Timelock 7d (1d emergency), event-driven monitoring | 5/7 collusion → out of scope (=protocol fork) |
| **Community Owner Multisig** | BOUNDED TRUST | Per-community ops, self-sovereign over their xPNTs | xPNTs firewall + MAX_SINGLE_TX_LIMIT + approvedFacilitators whitelist | Community admin abuse → bounded by firewall |
| **DVT Validator Quorum** | PARTIAL TRUST | Distributed validators, BLS aggregate | minThreshold ⌈N/3⌉+1, stake-gated, slashable | Quorum compromise → governance slash fallback (D5-bis) |
| **Chainlink Oracle** | PARTIAL TRUST | External oracle, history of outages | D8 break-glass owner emergency setPrice with bounds + timelock | Oracle pollution → emergencySetPrice within ±20% |
| **xPNTsFactory** | TRUSTED | Deployer-controlled, immutable address mapping | isXPNTs whitelist (P0-13 fix) | Factory bug → all xPNTs at risk; mitigation: factory itself UUPS |
| **aPNTsSaleContract Multisig** | TRUSTED | (new, per D3) controls aPNTs supply | Mint timelock + cap per epoch + transparency events | Supply abuse → bounded by per-epoch cap |
| **x402 Facilitator** | BOUNDED TRUST | Off-chain service, possibly compromised | Per-asset whitelist (D4) + community-approved list + xPNTs $100/tx firewall | Compromise → loss bounded by $100/tx × frequency |
| **Operator (registered)** | BOUNDED TRUST | Bonded GToken stake, slashable | DVT slash + governance slash + rate limits + reputation | Operator misbehavior → slashed; user-side rate limit |
| **Community Admin (COMMUNITY role)** | BOUNDED TRUST | Bonded stake, role-locked | Slash + reputation | Admin abuse → role-specific slash |
| **DVT Validator (single)** | PARTIAL TRUST | Bonded stake, vote weight | minStake gate + DVT quorum | Single validator dishonest → quorum overrides |
| **End User (ENDUSER + SBT)** | ADVERSARIAL | Anyone with SBT | Per-tx rate limit + minTxInterval + per-operator opt-out | Malicious user → bounded by rate limit |
| **Anonymous Caller** | ADVERSARIAL | No on-chain identity | All public functions reviewed | Default-deny |
| **Pre-image / Front-runner** | ADVERSARIAL | Sees mempool | Nonce/replay protection + signature verification | Replay → blocked by nonce/chain-id |

### 3.2 Trust assumption documents

After fix execution, the following trust assumptions must be **publicly documented**:

1. `docs/security/trust-assumptions.md` — comprehensive list (this section + rationale)
2. `docs/runbooks/multisig-signers.md` — who holds the 7 multisig keys (anonymized roles, not real names)
3. `docs/runbooks/incident-response.md` — break-glass procedures (D8) + timelock override conditions

---

## 4. Threat Actors

### 4.1 Actor inventory

| ID | Actor | Capabilities |
|---|---|---|
| **A1** | External anonymous caller | Submit any tx, view all public state, observe mempool |
| **A2** | Malicious end user (SBT holder) | A1 + register self via Registry, use paymaster as ENDUSER |
| **A3** | Malicious operator (registered + bonded) | A2 + register as operator, configure rates, sponsor user ops |
| **A4** | Malicious DVT validator (single, in quorum) | A3 + sign BLS proofs, submit DVT proposals |
| **A5** | Compromised facilitator (private key leaked) | Sign x402 settlements with authority; cannot mint |
| **A6** | Compromised oracle (Chainlink poisoning) | Push arbitrary price (constrained by Chainlink internal verification) |
| **A7** | Multisig minority (< 5/7) | Cannot execute, can grief by holding signatures |
| **A8** | Multisig majority (≥ 5/7) | OUT OF SCOPE (full governance capture = protocol fork) |
| **A9** | Compromised facilitator + compromised user wallet | Worst case for x402 user fund drain |
| **A10** | Cross-community attacker | Operator in community A attacking user in community B |

### 4.2 Attacker motivation

- **Financial**: extract operator deposits, drain user balances, steal protocol revenue
- **Governance**: manipulate slashing, reputation, oracle to gain advantage
- **Service disruption (DoS)**: deny availability to users / operators
- **Reputation harm**: poison reputation scores to harm specific operators/users
- **Insider trading**: front-run state changes (price updates, slashing)

---

## 5. Threat Scenarios

### 5.1 Format

Each scenario:
- **T-NN**: ID
- **Title**: short name
- **Actor**: from §4.1
- **Asset(s) at risk**: from §2
- **Pre-conditions**: what must be true for attack to start
- **Attack flow**: step-by-step
- **Damage**: estimated loss / impact
- **Existing mitigations**: in current code
- **Required mitigations**: what we still need (maps to P0/P1)
- **Residual risk**: after mitigations applied

---

### T-01: BLS aggregate signature forgery (B6-C1a)

| Field | Value |
|---|---|
| **Actor** | A1 / A4 |
| **Asset(s)** | A4 (operator stake), A7 (reputation), A9 (governance integrity) |
| **Pre-conditions** | None — exploit available to anonymous caller |
| **Attack flow** | (1) Caller crafts arbitrary `pkAgg` and `signerMask`. (2) Calls `BLSAggregator.verify(message, signerMask, pkAgg, sig)`. (3) BLS pairing equation `e(pk_agg, H(m)) == e(g1, sig)` mathematically holds for ANY (sig, pkAgg) pair the caller chooses freely. (4) Aggregator returns true. (5) Caller invokes slash / blacklist / oracle update with this "valid" proof. |
| **Damage** | Slash any operator → drain GToken stake; blacklist any operator; pollute oracle. **Catastrophic, full protocol compromise.** |
| **Existing mitigations** | None — `pkAgg` is caller-supplied and not cross-checked against `blsPublicKeys[validator]` |
| **Required mitigations** | **P0-1**: BLSAggregator must reconstruct `pkAgg` from `signerMask` + on-chain `blsPublicKeys`, NOT accept caller-supplied `pkAgg`. Delete `BLSValidator.sol`. |
| **Residual risk** | Bug in EIP-2537 precompile (out of scope) |
| **Severity** | **CRITICAL** (confirmed P0) |

### T-02: Validator registration without stake (B6-C1b)

| Field | Value |
|---|---|
| **Actor** | A1 (with admin coordination) — actually requires owner to add validator without checks |
| **Asset(s)** | A9 (governance integrity) |
| **Pre-conditions** | Owner adds a validator without verifying stake; combined with T-01, anyone forges proofs |
| **Attack flow** | (1) Owner calls `addValidator(addr, blsPK)`. (2) No check that `addr` holds ROLE_DVT or has minStake. (3) Combined with T-01, even validators without stake forge proofs. |
| **Damage** | Stake-less validators participate in quorum → no economic accountability |
| **Existing mitigations** | None |
| **Required mitigations** | **P0-2**: `addValidator` requires `Registry.hasRole(addr, ROLE_DVT)` AND `GTokenStaking.roleLocks[addr][ROLE_DVT].amount >= minStake` |
| **Residual risk** | Owner could still add malicious-but-bonded validator (bounded trust per §3.1) |
| **Severity** | **CRITICAL** (confirmed P0) |

### T-03: Slash single point of failure (B6-C1c)

| Field | Value |
|---|---|
| **Actor** | A4 (DVT quorum compromise) or A1 (DVT keys lost) |
| **Asset(s)** | A4, A9 |
| **Pre-conditions** | DVT quorum unavailable (offline, compromised, or all keys lost) |
| **Attack flow** | (1) Operator goes rogue. (2) DVT cannot produce BLS proof to slash. (3) Operator drains aPNTsBalance / abuses xPNTs. (4) No one can stop them. |
| **Damage** | Operator runs away with unspent aPNTs; user trust shattered |
| **Existing mitigations** | `SuperPaymaster.slashOperator()` is owner-only path (already exists per Codex Phase 6) |
| **Required mitigations** | **D5-bis (a) → P1**: Wrap `slashOperator` with multisig (5/7) + timelock (1d emergency / 7d normal). v6.0 adds Optimistic Governance Slash. |
| **Residual risk** | Owner multisig collusion (bounded trust per §3.1, A8 out of scope) |
| **Severity** | Was P0; **downgraded to P1** after D5-bis |

### T-04: BLS threshold trivial (B6-C2)

| Field | Value |
|---|---|
| **Actor** | A1 |
| **Asset(s)** | A9 |
| **Pre-conditions** | `Registry.updateOperatorBlacklist` accepts empty `proof` if BLS aggregator unset |
| **Attack flow** | (1) BLS aggregator address unset OR threshold = 1. (2) Caller submits empty proof. (3) Blacklist applied unilaterally. |
| **Damage** | Anonymous user blacklists arbitrary operator, censorship |
| **Existing mitigations** | None |
| **Required mitigations** | **P0-4**: `updateOperatorBlacklist` requires `proof.length > 0` AND `msg.sender == BLS_AGGREGATOR_ADDRESS`. Add chainid + proposalId + nonce to BLS message (Codex B-N4). |
| **Residual risk** | None after fix |
| **Severity** | **CRITICAL** (confirmed P0) |

### T-05: x402 Direct path drain via approve (B2-N4 + B3-N2)

| Field | Value |
|---|---|
| **Actor** | A5 (compromised facilitator) |
| **Asset(s)** | A2 (user USDC) |
| **Pre-conditions** | User has `approve(facilitator, MAX)` on USDC; `settleX402PaymentDirect` lacks asset whitelist |
| **Attack flow** | (1) User does standard `approve(facilitator, MAX)` for USDC (a normal "infinite approval" pattern). (2) Facilitator key leaks. (3) Attacker calls `settleX402PaymentDirect` with `asset = USDC`. (4) Contract calls `transferFrom(user, facilitator, amount)` → drains user USDC. |
| **Damage** | Per-user USDC approval limit (often unlimited) |
| **Existing mitigations** | None for USDC; xPNTs has firewall + MAX_SINGLE_TX_LIMIT |
| **Required mitigations** | **P0-13a**: `settleX402PaymentDirect` requires `xPNTsFactory.isXPNTs(asset)`. **P0-13b** (D4): require `IXPNTsToken(asset).approvedFacilitators(msg.sender)` (community-controlled whitelist). |
| **Residual risk** | xPNTs holder loses up to (MAX_SINGLE_TX_LIMIT × calls/day) — bounded by daily-cap (recommended new mitigation) |
| **Severity** | **HIGH** → P0 (split into 13a CRITICAL + 13b HIGH) |

### T-06: Operator drain via Chainlink oracle pollution + break-glass abuse (B2-N2 + P3-H2)

| Field | Value |
|---|---|
| **Actor** | A6 (oracle compromise) or A8 minority (multisig partial collusion) |
| **Asset(s)** | A1, A5 |
| **Pre-conditions** | Chainlink price feed pushed extreme value, OR owner uses break-glass during attack |
| **Attack flow (oracle)** | (1) Attacker pumps ETH price oracle by 10×. (2) `aPNTsPriceUSD` calculation skews. (3) Operators sponsor too cheap → drain protocolRevenue. |
| **Attack flow (break-glass abuse)** | (1) Owner calls `updatePriceDVT(newPrice)`. (2) Without bound checks, sets price 10× off real value. (3) Same skew. |
| **Damage** | Per-tx skew × volume; could drain operator deposits in minutes |
| **Existing mitigations** | `cachedPrice` deviation check; but break-glass path skips deviation when Chainlink down |
| **Required mitigations** | **P0-11** (D8 (b)): Owner-only `emergencySetPrice` with **±20% bound vs cachedPrice** + timelock (1h emergency, 7d normal) + price-mode state machine + event monitoring. |
| **Residual risk** | Sustained ±20% × N updates over time can drift; mitigation: monotonic timestamp (T-08) + per-epoch drift cap |
| **Severity** | **HIGH** → P0 |

### T-07: Slash sync drift between Registry and Staking (H-01 + B1-confirmed)

| Field | Value |
|---|---|
| **Actor** | A3 |
| **Asset(s)** | A4, A9 |
| **Pre-conditions** | Operator slashed; Registry.roleStakes not updated |
| **Attack flow** | (1) Operator slashed by DVT — `GTokenStaking.roleLocks[op][role]` reduced. (2) `Registry.roleStakes[op][role]` stays at pre-slash value. (3) `Registry.topUpStake` reads stale value, potentially over-counts stake. (4) Operator avoids further slashing or claims stake fraudulently. |
| **Damage** | Stake double-spend / under-collateralization |
| **Existing mitigations** | None |
| **Required mitigations** | **P0-17**: GTokenStaking slash callback writes back to Registry via `syncStakeFromStaking(user, role)` (only-staking-callable) |
| **Residual risk** | None after fix |
| **Severity** | **HIGH** → P0 |

### T-08: Future timestamp staleness bypass (Codex B-N1)

| Field | Value |
|---|---|
| **Actor** | A3 (operator with cache write access) or A8 minority |
| **Asset(s)** | A1, A5 |
| **Pre-conditions** | Caller can set `cachedPrice.updatedAt` to future time |
| **Attack flow** | (1) Caller writes future timestamp to `cachedPrice.updatedAt`. (2) Stale check `block.timestamp - updatedAt < threshold` always passes. (3) Old (or arbitrary) price used indefinitely. (4) Combined with T-06, drain via stale price. |
| **Damage** | Unbounded — bypasses all staleness defense |
| **Existing mitigations** | None |
| **Required mitigations** | **P0-19** (Codex B-N1): All cache writes assert `updatedAt <= block.timestamp` in: `SP.updatePriceDVT:347`, `PaymasterBase.setCachedPrice:474`, `PaymasterBase:299`. Also fix postOp underflow brick. |
| **Residual risk** | None after fix |
| **Severity** | **HIGH** → P0 |

### T-09: DVT proposal pre-poison (Codex B-N5)

| Field | Value |
|---|---|
| **Actor** | A1 |
| **Asset(s)** | A9 |
| **Pre-conditions** | `markProposalExecuted` sets `executed = true` for arbitrary proposalId |
| **Attack flow** | (1) Anonymous caller calls `markProposalExecuted(proposalId = X)` for X not yet created. (2) `executed[X] = true`. (3) Later, when legitimate proposal X is created and tries to execute, `if (executed[X]) revert AlreadyExecuted()` — proposal can never execute. |
| **Damage** | Permanent DoS of arbitrary proposal IDs; could prevent specific slashing actions |
| **Existing mitigations** | None — `createProposal` doesn't reset `executed = false` |
| **Required mitigations** | **P0-20** (Codex B-N5): Restrict `markProposalExecuted` to onlyAuthorized; OR `createProposal` resets `executed[id] = false` and asserts uniqueness |
| **Residual risk** | None after fix |
| **Severity** | **HIGH** → P0 |

### T-10: setAPNTsToken arbitrary swap (B2-N1)

| Field | Value |
|---|---|
| **Actor** | A8 minority (governance abuse, bounded trust) |
| **Asset(s)** | A1, A5 |
| **Pre-conditions** | Owner can call `setAPNTsToken` even when balances exist |
| **Attack flow** | (1) protocolRevenue + Σ aPNTsBalance > 0. (2) Owner calls `setAPNTsToken(newToken)`. (3) New token has no balances; old balances stranded → all operators frozen. |
| **Damage** | Frozen protocol; all operators lose access to balance |
| **Existing mitigations** | None |
| **Required mitigations** | **P0-10**: `require(totalTrackedBalance == 0 && protocolRevenue == 0)` OR migration timelock with explicit transfer of all balances |
| **Residual risk** | After fix: only safe migration possible |
| **Severity** | **HIGH** → P0 |

### T-11: V4 Paymaster registry interface break (B5-H1)

| Field | Value |
|---|---|
| **Actor** | A3 |
| **Asset(s)** | A8 (availability), A1 (operator funds) |
| **Pre-conditions** | V4 Paymaster calls `Registry.deactivate/activate` which doesn't exist |
| **Attack flow** | (1) Operator wants to deactivate per crisis. (2) Function reverts (interface mismatch). (3) Operator cannot stop sponsoring — bleeding continues. |
| **Damage** | Per-incident operator loss |
| **Existing mitigations** | None — function permanently reverts |
| **Required mitigations** | **P0-6**: V4 uses `Registry.exitRole(ROLE_PAYMASTER_AOA)` |
| **Residual risk** | None after fix |
| **Severity** | **HIGH** → P0 |

### T-12: V4 Paymaster pause never triggers (B5-H2)

| Field | Value |
|---|---|
| **Actor** | A3 (when needs to halt) |
| **Asset(s)** | A8 |
| **Pre-conditions** | `whenNotPaused` modifier exists but no `pause()` setter |
| **Attack flow** | Same as T-11 — operator cannot halt, no way to trigger pause |
| **Damage** | Per-incident operator loss |
| **Existing mitigations** | None |
| **Required mitigations** | **P0-7**: Add `pause()` / `unpause()` onlyOwner with events |
| **Severity** | **HIGH** → P0 |

### T-13: xPNTs emergencyRevoke incomplete (B4-H1)

| Field | Value |
|---|---|
| **Actor** | A3 (compromised SP) |
| **Asset(s)** | A3 (user xPNTs) |
| **Pre-conditions** | SUPERPAYMASTER_ADDRESS compromised; emergencyRevokePaymaster called but doesn't reset address |
| **Attack flow** | (1) SP exploit detected. (2) Community calls `emergencyRevokePaymaster`. (3) But `SUPERPAYMASTER_ADDRESS` not zeroed → compromised SP can still call `burnFromWithOpHash` |
| **Damage** | Continued user xPNTs drain |
| **Existing mitigations** | Partial revoke (autoApprovedSpenders cleared) |
| **Required mitigations** | **P0-8**: Set `SUPERPAYMASTER_ADDRESS = address(0)` OR add `emergencyDisabled` flag checked in burn paths |
| **Severity** | **HIGH** → P0 |

### T-14: xPNTs burn firewall bypass (B4-H2)

| Field | Value |
|---|---|
| **Actor** | A3 (autoApproved spender) |
| **Asset(s)** | A3 |
| **Pre-conditions** | autoApproved spender calls `burn(address user, uint256 amount)` (the address-uint variant) |
| **Attack flow** | (1) Spender calls `burn(victimUser, amount)`. (2) Path bypasses `_spendAllowance` check. (3) Burns arbitrary user balance up to MAX_SINGLE_TX_LIMIT. |
| **Damage** | Per-tx $100; sustained = unbounded |
| **Existing mitigations** | MAX_SINGLE_TX_LIMIT $100 |
| **Required mitigations** | **P0-9**: `burn(address, uint256)` enforces `_spendAllowance` |
| **Residual risk** | None after fix |
| **Severity** | **HIGH** → P0 |

### T-15: x402 nonce DoS (B3-N3 + B2-N8)

| Field | Value |
|---|---|
| **Actor** | A1 |
| **Asset(s)** | A8 |
| **Pre-conditions** | `x402SettlementNonces` keyed by nonce only (global namespace) |
| **Attack flow** | (1) Attacker observes pending settlements. (2) Submits transaction with the same nonce in different asset/from context. (3) `nonces[nonce] = true` blocks legitimate settlement → DoS. |
| **Damage** | Per-transaction blocked |
| **Existing mitigations** | None |
| **Required mitigations** | **P0-16**: Key by `keccak256(asset, from, nonce)` triple |
| **Severity** | **HIGH** → P0 |

### T-16: PriceSetter unbounded (B2-N3 + B4-M2 + P3-H1)

Multiple price setters across SP, Factory, PaymasterBase have no MIN/MAX bounds + no per-tx delta cap. **P0-12**: unify as `BoundedPriceFeed` module with bounds + ±10% per-tx + 24h timelock.

### T-17: SilentSigFailure (J2-BLOCKER-1)

`SuperPaymaster.validatePaymasterUserOp` has 6 paths returning silent SIG_FAILURE. Bundlers/UI cannot diagnose. **P0-18**: add `dryRunValidation(userOp, maxCost)` view function mirroring all checks.

### T-18: ENDUSER cross-operator targeted DoS (B2-N5)

User registers as ENDUSER → uses paymaster X → spams operator X with rate-limit-respecting tx → operator X cannot deny user without removing entire feature. **P1-1**: per-operator `setUserBlocked(user, bool)`.

### T-19: Replay attack — multi-chain (Codex B-N4)

`updateOperatorBlacklist` BLS message has no chainId / proposalId / nonce → replay across chains. **Mitigation in P0-4**: include `chainId, proposalId, nonce` in BLS message.

### T-20: Operator-self-blocked-by-rate-limit + recovery DoS (J3 user journey)

Operator hits rate-limit window; user tries to recover via different operator but stuck on stale `minTxInterval`. Mitigated by per-operator state.

### T-21: facilitator front-runs settle order (B2-N12 / B3)

Facilitator observes pending settlements, reorders to extract value. Mitigation: facilitator economic incentives + monitoring (out of scope for v5.4).

### T-22: aPNTs sale price manipulation (D3 design new)

(For D3 future implementation) Attacker observes mint, front-runs purchase. **Future P1**: aPNTs sale must use commit-reveal or batch auction.

### T-23: aPNTs supply over-issuance (D3 design new)

Multisig issues more aPNTs than AAStar can service → operator service degradation. **Future P1**: per-epoch mint cap + transparent service-capacity reporting.

### T-24: xPNTs auto-approve spender abuse (D4 follow-up)

Currently `autoApprovedSpenders` accumulates without rotation. **P1 new**: xPNTs adds `removeAutoApprovedSpender` (community multisig) + remove old SP allowance on rotation.

---

## 6. P0 Re-prioritization

Based on the trust model + D1-D8 user decisions, **re-score each P0 from review.md**:

### 6.1 Confirmed P0 (15 items)

| New P0 # | Original | Threat Scenario | Severity | Justification |
|---|---|---|---|---|
| P0-1 | B6-C1a | T-01 | **CRITICAL** | Bypasses BLS — anonymous caller forges proofs |
| P0-2 | B6-C1b | T-02 | **CRITICAL** | No stake → no skin in game |
| P0-3 | B6-C2 | T-04 | **CRITICAL** | Anonymous blacklist; censorship |
| P0-4 | B6-H1 | T-04 (related) | **HIGH** | executeWithProof unrestricted |
| P0-5 | B5-H1 | T-11 | **HIGH** | V4 cannot deactivate |
| P0-6 | B5-H2 | T-12 | **HIGH** | V4 cannot pause |
| P0-7 | B4-H1 | T-13 | **HIGH** | xPNTs emergency revoke incomplete |
| P0-8 | B4-H2 | T-14 | **HIGH** | xPNTs burn firewall bypass |
| P0-9 | B2-N1 | T-10 | **HIGH** | setAPNTsToken arbitrary swap |
| P0-10 | B2-N2+P3-H2 | T-06 | **HIGH** | break-glass + Chainlink down |
| P0-11 | B2-N3+B4-M2+P3-H1 | T-16 | **HIGH** | price setter no bounds |
| P0-12a | B2-N4+B3-N2 | T-05 (asset whitelist) | **HIGH** | settleDirect asset whitelist (D4 implements) |
| P0-12b | (D4 new) | T-05 (community whitelist) | **HIGH** | settleDirect community-approved facilitator (D4 implements) |
| P0-13 | B3-N3+B2-N8 | T-15 | **HIGH** | x402 nonce per-asset triple |
| P0-14 | H-01 | T-07 | **HIGH** | slash sync registry ↔ staking |
| P0-15 | J2-BLOCKER-1 | T-17 | **HIGH** | dryRunValidation |
| P0-16 | Codex B-N1 | T-08 | **HIGH** | future timestamp |
| P0-17 | Codex B-N5 | T-09 | **HIGH** | proposalId pre-poison |

**Wait — that's 17. Let me recount:** above list has 18 due to P0-12 split → **17 unique P0 items**.

### 6.2 Downgraded from P0

| Original P0 | New | Reason |
|---|---|---|
| P0-3 (B6-C1c slash single-point) | **P1** | D5-bis (a): existing `SuperPaymaster.slashOperator()` + multisig + timelock sufficient. v6.0 upgrade to Optimistic Slash. |
| P0-14 (B2-N6 owner-slash cap) | **P1** | D5-bis (a): cap can be challenge-window-based; not blocker for mainnet |
| P0-15 (B3-N1 Agent sponsorship) | **DELETED** | D1: feature removed entirely |

### 6.3 Newly added (Codex Phase 6)

Already merged into 6.1 as P0-16/17 (Codex B-N1, B-N5).

### 6.4 Final P0 count: **17 items**

(Range was 15-17 in decision-records; final tally is 17 with P0-12 split into a/b sub-items.)

---

## 7. Failure Mode Inventory

### 7.1 Detection / Recovery / Loss-bound matrix

| Failure mode | Detection | Recovery | Loss bound |
|---|---|---|---|
| Forged BLS proof (T-01) | None pre-fix | None pre-fix; full slash + recovery post-fix | Catastrophic → bounded after P0-1 |
| Validator without stake (T-02) | Owner audit | Remove validator, rebuild quorum | Per-validator vote weight |
| Slash via DVT impossible (T-03) | Operator misbehavior + DVT silence | D5-bis (a): owner multisig slash | Per-operator stake |
| Anonymous blacklist (T-04) | Event monitoring | None until P0-3 fix | Per-operator service uptime |
| x402 facilitator drain (T-05) | Approval audit | User revoke + re-approve | Per-user approval |
| Oracle pollution (T-06) | Price deviation alert | D8 break-glass | Per-tx skew × volume |
| Slash sync drift (T-07) | Registry/Staking diff query | Manual `syncStakeFromStaking` | Stake double-count |
| Future timestamp (T-08) | Cache age inverse check | `updatedAt <= now` assert | Unbounded → bounded |
| Proposal pre-poison (T-09) | Proposal id collision | None pre-fix; reset on create | DoS specific proposalIds |
| setAPNTsToken stranding (T-10) | Balance non-zero check | Migration with timelock | All operator balances |
| V4 deactivate revert (T-11) | Operator support ticket | None pre-fix | Per-operator |
| V4 pause null (T-12) | Same as T-11 | None pre-fix | Per-operator |
| xPNTs emergency revoke (T-13) | Compromise detection | Set SP address to 0 + emergencyDisabled | All xPNTs holders |
| xPNTs burn bypass (T-14) | Burn event monitoring | _spendAllowance enforcement | $100/tx |
| Nonce DoS (T-15) | Settlement failure | Triple-key | Per-tx |
| Price setter unbounded (T-16) | Per-tx % delta alert | BoundedPriceFeed | Per-update |
| Silent sigFailure (T-17) | Bundler logs | dryRunValidation | UX only |

### 7.2 Recovery objectives (RTO/RPO style)

| Asset | RTO (recovery time objective) | RPO (recovery point — what loss accepted) |
|---|---|---|
| A1 Operator funds | 24 hours (multisig + emergency setPrice) | 0% pre-fix, ±20% bounded post-fix |
| A2 User USDC | User self-revoke (immediate) | Single-cycle approval |
| A3 User xPNTs | $100/tx × N until revoke | Per-day cap (D4 follow-up) |
| A4 Operator stake | Permanent on slash (intentional) | N/A |
| A5 Protocol revenue | Owner withdraw timelock | Per-update bounded |
| A6 MPC channel | CLOSE_TIMEOUT (chain-dependent per D6) | Per-channel deposit |
| A7 Reputation | Long rebuild period | Per-incident |
| A8 Service availability | Bundler reconnect / oracle restore | Lost transactions |
| A9 Governance integrity | Multisig key rotation | Catastrophic if 5/7 collude (out of scope) |

---

## 8. Defense-in-Depth Layers

| Layer | Defense | Tested by |
|---|---|---|
| L1: Cryptographic | BLS verify with on-chain pkAgg reconstruction (P0-1) | unit + integration tests |
| L2: Economic | Stake-gating (P0-2) + slash + reputation | invariant tests |
| L3: Governance | Multisig 5/7 + timelock + bounded params | runbook + monitoring |
| L4: Asset-level | xPNTs firewall + MAX_SINGLE_TX_LIMIT + community-controlled facilitator whitelist (D4) | unit tests |
| L5: User-level | rate-limit + per-operator opt-out (P1-1) + revoke paths | UX tests |
| L6: Off-chain | Watchtower (MPC) + monitoring (Slack webhooks per D8) | runbook drills |

**Codex's invariant focus** (P0-fix priority): all defenses across layers must satisfy:
1. `INV-12: Registry.roleStakes == GTokenStaking.roleLocks` for all (user, role)
2. `INV-03: protocolRevenue + Σ aPNTsBalance + inflight = totalTracked`
3. `INV-x402: x402SettlementNonces[asset, from, nonce] is monotonic`
4. `INV-price: cachedPrice.updatedAt <= block.timestamp` (always)

These are the "state-machine / accounting" invariants Codex flagged as the highest-impact failure mode.

---

## 9. Open Questions (for review)

1. **A8 multisig majority capture**: confirmed out of scope. But what if 5/7 collude in a way that's reversible (e.g., they can be re-elected)? Currently no mechanism for "removing a multisig signer". Should we add multisig-rotation governance?

2. **Cross-community attacks (A10)**: an operator in community A is a normal user in community B. If A operator becomes adversarial in B, what's the blast radius? D7 (eligibleHolders rename) is partial answer. Need explicit per-community sponsorship boundary?

3. **aPNTs supply emergency hold**: per D3, if AAStar's service capacity drops suddenly (e.g., key partner dropout), can aPNTs sale be paused? Should sale contract have `pause()` for this?

4. **D8 break-glass detection**: what triggers "emergency mode"? Manual (multisig vote) or automatic (Chainlink stale > N hours)? Recommend: automatic detection allows emergency setPrice; multisig still required to actually set price.

5. **DVT validator removal**: P1-25 mentions `removeValidator` is missing. Per the trust model, removing a validator without their consent is governance action — should it require multisig vote or single owner?

6. **Reputation as governance input**: ReputationSystem affects sponsorship and slash thresholds. Is ReputationSystem itself trusted? Currently treated as TRUSTED (deployer-controlled), but reputation values are computed off-chain and pushed on-chain by `syncToRegistry`. This is a vector — needs analysis.

7. **Bridge / cross-chain**: contracts are EVM-only. If protocol expands to multiple chains (per Codex B-N4 multi-chain replay concern), what's cross-chain governance? Out of scope for v5.4 but worth flagging.

---

## 10. Acceptance Criteria for Mainnet

> Criteria from review.md §5.4 + this threat model. Mainnet deployment is **only after**:

### 10.1 Technical
- [ ] All 17 P0 fixed (this document §6.1)
- [ ] All P1 (≥30 items) fixed or documented as intentional
- [ ] All Codex Phase 6 findings re-reviewed by Codex Tier 1
- [ ] Echidna long-run (≥24h) 0 counterexamples on full suite
- [ ] All 4 invariants (§8) verified with custom invariant tests
- [ ] forge test 0 failures (current 368 + P0-fix tests)
- [ ] All Phase 4 user journeys re-tested

### 10.2 Governance
- [ ] AAStar Owner multisig deployed (5/7 Safe)
- [ ] Per-community multisig templates documented
- [ ] All listed setters from §5.4.3 wrapped with timelock (24h normal / 1h emergency for D8)
- [ ] D5-bis: governance slash (multisig + timelock) implemented
- [ ] Trust assumption documents published

### 10.3 Operational
- [ ] Watchtower deployed (MPC monitoring)
- [ ] Keeper deployed (Chainlink price refresh)
- [ ] Bundler compatibility tested (P0-15 dryRun)
- [ ] SDK updated and tested (D4 facilitator filter, D7 eligibleHolders rename)
- [ ] Runbooks: incident response, multisig signers, emergency procedures

### 10.4 Audit
- [ ] Codex Tier 1 final review pass
- [ ] gh Copilot PR review pass
- [ ] (Optional) external audit on BLS + governance slash design

### 10.5 Economic
- [ ] aPNTs Sale Contract designed (D3) — implementation can be deferred to post-launch with placeholder
- [ ] Mint cap per epoch documented + multisig configured
- [ ] Trust assumptions reviewed by economic model owner

---

## 11. Methodology Notes

This threat model follows STRIDE-Attack-Tree-Mixed methodology:

- **Identify trust boundaries** (§3) — Codex's explicit demand
- **Enumerate actors with capabilities** (§4) — STRIDE-like classification
- **Walk threat scenarios per actor** (§5) — attack tree per scenario
- **Re-score against trust model** (§6) — Codex's specific re-prioritization request
- **Failure-mode catalog** (§7) — IT-style RTO/RPO

Reviewer feedback can be addressed inline or in §9 (Open Questions). After review, this document becomes the **input to Wave 1 fix execution**.

---

## 12. Revision Log

- 2026-04-26 (initial): threat model written based on D1-D8 final decisions; 17 P0 confirmed; 24 threat scenarios enumerated; trust matrix established
