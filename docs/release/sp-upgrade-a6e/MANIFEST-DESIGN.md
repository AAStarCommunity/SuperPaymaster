# Pre-sampling manifest: one reviewed hash for every remaining Sepolia write (CC-125 / CC-127)

Status: **design for review**. No packet has been built, nothing is signed, and nothing below may be sent until the
author gives a separate go for the built packet's sha256. Each go request carries the decision card in §8.

This document extends [DESIGN.md](DESIGN.md) (the original IG-08 route) to the full set of writes that the author and
DSR decided on (2026-10-31 / 11-01). Every item marked **VERIFY** is read back from chain at the pin block
before the packet is frozen; nothing here is assumed from memory.

## 1. Decisions this manifest implements

| # | Decision | Source |
| --- | --- | --- |
| D1 | Upgrade in place, no fresh deployment. SP proxy `0x09DF…4DE9` keeps its address and storage. | author 10-31 |
| D2 | Option ②: unpause (operators and global) is part of the gas-activation timelock operation; the upgrade still goes through the timelock. | author 10-31 |
| D3 | Bind every contract to its latest version and deploy/upgrade them together: SP 5.5.0, Registry 5.8.0 → 5.9.0 (UUPS, EOA owner), BLSAggregator 4.11 → 4.12 (new deployment, three pointers), xPNTs V2 stack. | author 10-31 |
| D4 | aPNTs → APNTsCapped (A3a S7 queues it; execution waits for the 7-day SP token timelock and drained balances). | author 10-31 |
| D5 | Registry owner → A3a timelock (two-step, accepted by Safe → timelock, 48 h). BLSAggregator, DVTValidator and slashPolicyAdmin owners → test Safe `0x16dF…bEBf`. Handover is the **last** phase. | author 10-31 |
| D6 | Gas tuple `(480000, 450000, 5000, 450000)`; `_checkGasParams` unchanged; later SETTLE changes re-validate with ⌈64S/63 + C⌉. | DSR 11-01, #576 |
| D7 | W-1: SP stake ≥ 1 ETH, unstake delay ≥ 86400, before SP ownership leaves the EOA. | DSR 10-31 |
| D8 | All pre-sampling EOA writes form one manifest with senders, nonce order, budgets, dependencies and STOP conditions; one go for one sha256. | DSR 10-31 |
| D9 | DVTValidator `0x568b…9E0e` is frozen (DVT will not redeploy it); new BLSAggregator binds it in its constructor. | DVT 10-31 |

## 2. Preconditions (all must hold at the pin block; otherwise STOP)

- A3a S6a, S6b and S7 are mined and read back: the deployer nonce is the next manifest nonce, APNTsCapped is owned by
  the timelock, and SP `pendingAPNTsToken == APNTsCapped`.
- The three A3a signers have sent nothing outside the plans (`nonceGaps` mechanism, #571, if one did).
- SP is still 5.4.2, owner = deployer, and the timelock `0xCCdF…C34B` has the role sets of the A3a plan.
- Registry is 5.8.0 with storage layout identical to 5.9.0 (32 variables, `_owner` at slot 0; checked 10-31; **VERIFY**
  at pin).
- No in-flight proposal or exit notice on the old BLSAggregator (scan from its deployment block; **VERIFY**).
- Price cache: not a precondition for the manifest itself (SP is paused for most of it). It is a G3 precondition (P-price).

## 3. Phases and transactions

Senders: **D** = deployer `0xb560…df0E` (Foundry keystore), **A** = A3a approver (Safe owner 1), **E** = A3a executor
(Safe owner 2), **DVT** = DVT's own tooling signing with D (nonces reserved here, sent at the time this manifest assigns).
"Undo" says what reverses the step if a later STOP leaves the system half-way.

### Phase A — EOA (deployer is still owner of SP, Registry, BLSAggregator, DVTValidator)

| Step | Sender | Call | Depends on | Undo |
| --- | --- | --- | --- | --- |
| A1 | D | CREATE SuperPaymaster 5.5.0 implementation (constructor CREATEs the extension) | pin | none needed (unused code) |
| A2 | D | CREATE GlobalTierSource(Registry) | — | unused |
| A3 | D | CREATE AOAProtocolRegistry(owner) → `bootstrapApprove(KIND_SP, spKey(SP proxy))`, `bootstrapApprove(KIND_TIER_SOURCE, codehash(A2))`, `seal()` | A2 | none after seal (approvals then need 48 h proposals) |
| A4 | D | CREATE xPNTsTokenV2Ext(A3), xPNTsTokenV2 impl(A3, ext), xPNTsFactoryV2(SP, Registry, impl, A2) | A3 | unused |
| A5 | D | CREATE SuperPaymasterLens | A1 | unused |
| A6 | D | CREATE Registry 5.9.0 implementation; `Registry.upgradeToAndCall(impl, "")` | pin | re-upgrade to the 5.8.0 implementation (EOA owner) |
| A7 | D | CREATE BLSAggregator 4.12(Registry, SP, DVTValidator `0x568b…`) | A6 | unused until wired |
| A8 | D | `Registry.setBLSAggregator(A7)`; `DVTValidator.setBLSAggregator(A7)`; committee `0x7ac7…96a9.setBlsAggregator(A7)` (after Registry) | A7 | point back to the old aggregator |
| A9 | D | `Registry.setReputationSource(A7, true)`; `Registry.setReputationSource(old, false)` | A8 | reverse both |
| A10 | DVT (signs with D) | three guardian re-registrations on A7 with PoP generated on the DVT host | A8 | owner can remove |
| A11 | D | `A7.setMinThreshold(2)` (and default threshold so that 2-of-3 holds); `A7.proposeFraudProofVerifier(v)` (4-day delay starts) | A10 | owner can reset |
| A12 | D | SP `addStake{value}` so stake ≥ 1 ETH, delay ≥ 86400; EntryPoint `depositTo(SP)` top-up | pin | `unlockStake` + 86400 s |
| A13 | operators | drain for the token swap: each SP operator `withdraw` its aPNTs (D for itself; **Anni `0xEcAA…33c9` needs its own key — VERIFY address**); D `withdrawProtocolRevenue` | pin | re-deposit |
| A14 | D | Registry role-config freeze (existing executor step) | A6 | existing unfreeze |
| A15 | D | `setOperatorPaused(op, true)` for every configured operator (existing executor step) | — | unpaused in Phase B |
| A16 | D | `SP.transferOwnership(timelock)` (existing executor step) | A1–A15 | only via Safe → timelock afterwards |

### Phase B — Safe → timelock (A approves, E executes)

| Op | Batch content (in order) | Delay | Readback |
| --- | --- | --- | --- |
| 5a/5b `upgrade` | `upgradeToAndCall(A1, setGlobalPaused(true))`; `queueGasParams(480000,450000,5000,450000)`; `setXPNTsFactory(A4 factory)`; `queueBLSAggregator(A7)` | 48 h | implementation slot, extension, global pause, queued tuple and ETA, factory, queued aggregator |
| 6c/6d `activation` (predecessor = upgrade) | `executeGasParams()`; `applyBLSAggregator()`; `setOperatorPaused(op, false)` for each sampled operator; `setGlobalPaused(false)` | 48 h (overlaps the internal 48 h GP_TIMELOCK) | active tuple, aggregator, every operator and global unpaused |

`queueBLSAggregator` has a 24 h internal delay, so `applyBLSAggregator` in 6d (≥ 48 h after 5b) is in time.

**Open (needs the author):** `executeAPNTsTokenChange` requires S7 + 7 days and drained balances. If 6d falls before
S7 + 7 d, it cannot be in 6d and needs its own Safe → timelock operation (+48 h). The sampling window does not need it
(balance-mode settlement never calls APNTS_TOKEN); the paper's "aPNTs replaced" statement does.

### Phase C — sampling configuration (after 6d)

- Operator V2 configuration (`configureOperator` with a factory-deployed V2 token), V2 token mint and credit policy,
  user SBT status and balances, VPM/TPM baseline deployment (`script/a6-collector/deploy-baselines.mjs`), Registry SUPER
  unfreeze. **VERIFY** whether existing operators can be reconfigured to V2 or new operators are needed; a new operator
  changes the G3 matrix.
- Sampler gas limits follow the new tuple: SP `post = 480000` or read from chain; `ver` re-derived including SP_RENEW;
  maxCost and xPNTs reservations recomputed (see the G3 matrix prerequisites).

### Phase D — owner handover (last)

| Step | Sender | Call |
| --- | --- | --- |
| H1 | D | `Registry.transferOwnership(timelock)` (two-step; pending owner in the ERC-7201 slot) |
| H2 | A/E | Safe → timelock op `Registry.acceptOwnership()`, 48 h |
| H3 | D | `BLSAggregator(A7).transferOwnership(Safe)`; `DVTValidator.transferOwnership(Safe)`; slashPolicyAdmin → Safe |

Thresholds (A11) and guardian registration (A10) must be done before H3. After H2, an emergency Registry rotation also
takes 48 h. BLSAggregator and DVTValidator have no timelock (Safe only); the matrix records that asymmetry.

## 4. Nonce and timing plan

- All D steps are one strictly increasing nonce sequence starting at the post-S7 nonce, including the three A10 slots
  reserved for DVT. No other process may send from D, A or E until the manifest completes (the DVT/keeper ban stays in
  force).
- Critical path: A1–A16 (one day, mostly confirmations) → 5a + 48 h → 5b → 6c + 48 h → 6d → Phase C → H1/H2 + 48 h.
  About 6–7 days from the go.

## 5. STOP conditions (each is a hard stop; nothing later is sent)

- Any precondition in §2 fails at the pin or before a step.
- A read-back after a step differs from the plan (address, codehash, owner, pointer, role set, tuple, pause state, stake).
- The deployer, approver or executor nonce differs from the plan, unless a gap is proven by `check_gaps` (#571).
- Any estimate above the planned gas limit, or a mined status other than 1.
- An in-flight proposal appears on the old aggregator.

## 6. Rehearsal and controls (before the packet is frozen)

- A full fork rehearsal on the pinned Sepolia state with the Amsterdam engine: every step, every read-back, and the timelock delays warped.
- Negative controls:
  - unpause before 6d rejected;
  - an operator `configureOperator` before `setXPNTsFactory` rejected;
  - `applyBLSAggregator` before 24 h rejected;
  - the old aggregator can no longer submit reputation after A9;
  - a non-owner Registry upgrade rejected.
- On-chain handleOps admission check of 480000 in the G3 pilot (DSR #4, D6).

## 7. What changes for the paper

- All contract versions are bound to one frozen tag. After the tag, `contracts/src` does not change.
- The multisig disclosure: both testnet signers were controlled by one operator.
- The Registry is governed by the same 48 h timelock. BLSAggregator and DVTValidator are Safe-only.

## 8. Decision card for the go (filled in when the packet is built)

For each phase: the transactions in plain language, who sends them, the on-chain state afterwards, whether and how each
can be undone, the maximum cost, the main risks and which guard stops a bad send, what changed since the previous go,
who reviewed it, and the timing. The packet sha256 comes last, as the identifier.
