# Pre-sampling manifest: one reviewed hash for every remaining Sepolia write (CC-125 / CC-127)

Status: **design accepted by DSR (revision 3 + two text fixes, 2026-11-01)**. Packet building follows the §2 preconditions. No packet has been built, nothing is
signed, and nothing below may be sent until the author gives a separate go for the built packet's sha256. Each go
request carries the decision card in §9.

This document extends [DESIGN.md](DESIGN.md) (the original IG-08 route) to every remaining write that the author and
DSR decided on (2026-10-31 / 11-01). DESIGN.md's "Pre-restore gate", which says unpausing needs another packet, is
**superseded** by D2 below.

Every item marked **VERIFY** is read back from chain at the pin block before the packet is frozen. Values marked
"current" were read on 2026-11-01 (publicnode, Sepolia) and are re-read at the pin.

## 1. Decisions this manifest implements

| # | Decision | Source |
| --- | --- | --- |
| D1 | Upgrade in place, no fresh deployment. SP proxy `0x09DF…4DE9` keeps its address and storage. | author 10-31 |
| D2 | Option ②: operator and global unpause are part of the gas-activation timelock operation. The upgrade still goes through the timelock. | author 10-31 |
| D3 | Bind every contract to its latest version and deploy/upgrade them together: SP 5.5.0; Registry 5.8.0 → 5.9.0 (UUPS, EOA owner); BLSAggregator 4.11 → 4.12 (new deployment, three pointers); xPNTs V2 stack. | author 10-31 |
| D4 | aPNTs → APNTsCapped. `executeAPNTsTokenChange` is in 6d, **before** the unpause. The 6c schedule must give 6d an execution time ≥ `pendingAPNTsTokenEta` (S7 + 7 days). No separate operation. | DSR 11-01 ruling |
| D5 | Owners: Registry, AOAProtocolRegistry and xPNTsFactoryV2 go to the A3a timelock. BLSAggregator, DVTValidator and slashPolicyAdmin go to the test Safe `0x16dF…bEBf`. Handover is the **last** phase. | author 10-31; DSR 11-01 (AOA registry, factory) |
| D6 | Gas tuple `(480000, 450000, 5000, 450000)`. `_checkGasParams` is unchanged. Any later SETTLE change re-validates with ⌈64S/63 + C⌉. | DSR 11-01, #576 |
| D7 | W-1: SP stake ≥ 1 ETH with unstake delay ≥ 86400, added before SP ownership leaves the EOA. | DSR 10-31 |
| D8 | All pre-sampling writes form one manifest: senders, nonce order, budgets, dependencies and STOP conditions. One go for one sha256. | DSR 10-31 |
| D9 | DVTValidator `0x568b…9E0e` is frozen. The new BLSAggregator binds it in its constructor. | DVT 10-31 |
| D10 | DVT supplies only PoP data (public key, slot, signature). The calldata goes into the packet, and the executor sends it from D. DVT's tooling never holds or sends from D. | DSR 11-01 |
| D11 | Thresholds: `minThreshold = 2`, `defaultThreshold = 2` (2-of-3), the same as the old aggregator `0xEaeC…2E5D`. `slashThresholds` keep their constructor values: WARNING 2, MINOR 3, MAJOR 3. With N = 3, MINOR and MAJOR therefore need all three signatures. | DSR 11-01 |
| D12 | The fraud-proof verifier is a **new** `OverIssueFraudProofVerifier(A7, Registry)` deployed by D from DVT's frozen commit. It binds `AGGREGATOR` as an immutable and in its domain separator, so the existing `0xa134…1cd3` (AGGREGATOR = old aggregator) cannot be reused. | DSR 11-01 |

Why D4 matters for sampling, and why "sampling does not need the swap" was wrong:
- Settlement never calls `APNTS_TOKEN`. But validation debits the operator's `aPNTsBalance` (`SuperPaymaster.sol:313`, `:322`), and deposits go through `APNTS_TOKEN` (`:163`).
- If operators were funded and sampled with the old token before the swap, `totalTrackedBalance` would no longer equal `protocolRevenue`. The swap would then fail, and the samples would be bound to the old token.

## 2. Preconditions (all must hold before A1; otherwise STOP)

Release preconditions, needed so that §8's "one tag" claim has evidence:
- A frozen release tag. A reproducible build of every deployed contract from that tag, compared with the packet's
  artifacts. The full creation hash includes CBOR metadata, which depends on remapping paths (a symlinked checkout changes
  only the IPFS hash). So each contract records two hashes, with metadata and with the CBOR tail stripped, built from a
  fixed build path. A metadata-only difference is reported, not accepted silently. Any difference in executable code is a STOP.
- On the final tree: the A4 conformance checks C1–C9, the mutation run and Slither, each with results archived.
- A plan for source verification of every deployed contract after Phase A (results archived).

Chain preconditions at the pin block:
- A3a S6a, S6b and S7 are mined and read back:
  - the deployer nonce is the manifest's first nonce;
  - APNTsCapped is owned by the timelock;
  - SP `pendingAPNTsToken == APNTsCapped`, and `pendingAPNTsTokenEta` is recorded.
- The three A3a signers have sent nothing outside the plans, or every such transaction is a proven gap (#571).
- SP is 5.4.2 and owned by the deployer. The timelock `0xCCdF…C34B` has the A3a role sets.
- Registry is 5.8.0 with storage layout identical to 5.9.0 (32 variables, `_owner` at slot 0). **VERIFY**.
- The old BLSAggregator has no in-flight proposal or exit notice, scanned from its deployment block. **VERIFY**.
- Token-swap balances (current, re-read at the pin):
  - `totalTrackedBalance` = 2934.14 aPNTs;
  - deployer operator 1690.01;
  - Anni `0xEcAACb91…33c9` 844.54;
  - `protocolRevenue` 399.59.

  The sum closes.
- The Anni key: `PRIVATE_KEY_ANNI` in `.env.sepolia` derives `0xEcAACb91…33c9` (checked 11-01, nothing printed). It is
  imported into a Foundry keystore before the packet is built. The packet references the keystore, never the key.
- DVT's frozen commit `72aca4fa` (accepted by DSR 11-01, including `OverIssueFraudProofVerifier`) builds reproducibly
  under the same two-hash rule, with the DVT CI pass record that `BLSAggregator.sol:86` requires.
- That verifier source was validated against BLSAggregator 4.11.0 only. DVT's conformance run against 4.12.0 (`fbd74fb1`)
  must pass before the packet is built. Otherwise STOP.
- After the pin, D gives DVT the new aggregator's address, `version()` and the validator slots. DVT exports the PoP data
  through its reviewed PoP tool (DVT PR).
- The PoP data from DVT is generated **after** the pin. `popDigest` binds `domainSeparator() = keccak(name, chainid,
  address(this), REGISTRY)`, and the new aggregator's address is fixed by the deployer nonce at the pin.

## 3. Phases and transactions

Senders:
- **D**: deployer `0xb560…df0E` (Foundry keystore);
- **N**: Anni operator (keystore);
- **A**: A3a approver (Safe owner 1);
- **E**: A3a executor (Safe owner 2).

Safe transactions are approved by A and executed by E. "Undo" says what reverses a step if a later STOP leaves the
system half-way (see §6).

### Phase A — EOA (D still owns SP, Registry, BLSAggregator and DVTValidator)

| Step | Sender | Call | Depends on | Undo |
| --- | --- | --- | --- | --- |
| A1 | D | CREATE SuperPaymaster 5.5.0 implementation (its constructor CREATEs the extension) | pin | none (unused code) |
| A2 | D | CREATE GlobalTierSource(Registry) | — | unused |
| A3 | D | CREATE AOAProtocolRegistry(owner = D); `bootstrapApprove(KIND_SP, spKey(SP proxy))`; `bootstrapApprove(KIND_TIER_SOURCE, codehash(A2))`; `seal()` | A2 | after seal, approvals need 48 h proposals |
| A4 | D | CREATE xPNTsTokenV2Ext(A3); xPNTsTokenV2 implementation(A3, ext); xPNTsFactoryV2(SP, Registry, implementation, A2) | A3 | unused |
| A5 | D | CREATE SuperPaymasterLens | A1 | unused |
| A6 | D | CREATE Registry 5.9.0 implementation; `Registry.upgradeToAndCall(implementation, "")` | pin | D re-upgrades to the 5.8.0 implementation |
| A7 | D | CREATE BLSAggregator 4.12(Registry, SP, DVTValidator `0x568b…`); initial `minThreshold = 3`, `defaultThreshold = 7` | A6 | unused until wired |
| A8 | D | `Registry.setBLSAggregator(A7)`; `DVTValidator.setBLSAggregator(A7)`; then committee `0x7ac7…96a9.setBlsAggregator(A7)` | A7 | point back to the old aggregator |
| A9 | D | `Registry.setReputationSource(A7, true)`; `Registry.setReputationSource(old, false)` | A8 | reverse both |
| A10 | D | three `A7.registerBLSPublicKey(validator, publicKey, slot, popSignature)` (owner path), with the calldata built from the PoP data DVT supplies after the pin | A8 | owner can remove |
| A11 | D | `A7.setMinThreshold(2)`, then `A7.setDefaultThreshold(2)` (min ≤ default holds at each step: 2 ≤ 7, then 2 ≥ 2) | A10 | owner can reset |
| A12a | D | CREATE `OverIssueFraudProofVerifier(A7, Registry)` from DVT's frozen commit `72aca4fa`. The address is fixed by D's nonce; the calldata and artifact are in the packet. This bare CREATE bypasses DVT's deploy-script identity checks, and a wrong argument would not revert: later proofs would just fail silently. So the read-back must show `A12a.AGGREGATOR() == A7` and `A12a.REGISTRY() == A7.REGISTRY()`, otherwise STOP. | A7 | unused until applied |
| A12b | D | `A7.proposeFraudProofVerifier(A12a)`; the 4-day delay starts | A12a | owner re-proposes |
| A13 | D | SP `addStake{value}` until stake ≥ 1 ETH with delay ≥ 86400 (current stake 0.1 ETH); EntryPoint `depositTo(SP)` top-up | pin | `unlockStake`, then 86400 s |
| A14 | D | `setOperatorPaused(op, true)` for every configured operator (pause **before** draining) | — | unpaused in 6d (sampled operators only) |
| A15 | D, N | drain: D `withdraw(1690.01e18)`; N `withdraw(844.54e18)`; D `withdrawProtocolRevenue(D, protocolRevenue − 0.1e18)` (exact amounts from the pin) | A14 | re-deposit |
| A16 | D | Registry role-config freeze (existing executor step) | A6 | existing unfreeze |
| A17 | D | `SP.transferOwnership(timelock)` (existing executor step) | A1–A16 | only via Safe → timelock afterwards |

The drain is exact because `executeAPNTsTokenChange` requires `totalTrackedBalance == protocolRevenue ≤ 0.1 ether`.
Withdrawing protocol revenue leaves exactly 0.1 ether.

### Phase B — Safe → timelock, and the verifier apply

| Op | Content (in order) | Delay | Read-back |
| --- | --- | --- | --- |
| B1 = 5a/5b `upgrade` | `upgradeToAndCall(A1, setGlobalPaused(true))`; `queueGasParams(480000,450000,5000,450000)`; `setXPNTsFactory(A4 factory)`; `queueBLSAggregator(A7)` | 48 h | implementation slot, extension, global pause, queued tuple and ETA, factory, queued aggregator |
| B2 (before 6d) | read-back gate: `totalTrackedBalance == protocolRevenue ≤ 0.1e18`; no in-flight sponsorship (a stale release returns balance); no pending slash | — | STOP if any differs |
| B3 = 6c/6d `activation` (predecessor B1) | `executeGasParams()`; `applyBLSAggregator()`; **`executeAPNTsTokenChange()`**; `setOperatorPaused(op, false)` for each **sampled** operator only; `setGlobalPaused(false)` | 6c is scheduled so that 6d runs at ≥ `pendingAPNTsTokenEta` | active tuple, aggregator, `APNTS_TOKEN == APNTsCapped`, sampled operators and global unpaused, unsampled operators still paused |
| B4 | D: `A7.applyFraudProofVerifier()` once 4 days have passed since A12b. Only the executor sends it: DVT's Apply Verifier Rotation workflow is hard-wired to the old aggregator, and DVT disables it until the Phase D read-back. The function has no permission gate, so the executor still reads `fraudProofVerifier` first and skips if it is already A12a (not a STOP). | 4 d | `fraudProofVerifier == A12a` |

Timing:
- `queueBLSAggregator` has a 24 h internal delay, so `applyBLSAggregator` in 6d is in time.
- `deposit`, `depositFor` and `onTransferReceived` do not check the pause, so balances can be added back after the drain. That is why B2 re-reads them immediately before 6d.

### Phase C — funding and sampling configuration (after 6d)

| Step | Sender | Call |
| --- | --- | --- |
| C1 | Safe (A/E) | `APNTsCapped.mint(operator, amount)` for each sampled operator. The minter is the Safe (S3 constructor). |
| C2 | each operator | `APNTsCapped.approve(SP)`; `SP.deposit(amount)` |
| C3 | operators | V2 token from the factory; `configureOperator(V2 token, treasury)`; V2 mint and credit policy |
| C4 | D / Registry | user SBT status and balances; Registry SUPER unfreeze |
| C5 | D | VPM/TPM baseline deployment (`script/a6-collector/deploy-baselines.mjs`) |

The amounts are not yet computed. Per sampled operator: samples per arm × maximum reservation at the new tuple (maxCost
rises about 1.8 M gas; see the G3 prerequisites), plus a stated buffer. Each operator's `maxSingleTxLimit` and EntryPoint
deposit are checked against them.

**VERIFY, and decide before the packet is frozen:** whether the existing operators can be reconfigured to V2 or new
operators are needed. This must become concrete transactions, or D8's one hash does not hold. A new operator changes
the G3 matrix.

### Phase D — owner handover (last)

| Contract | Owner mechanism | New owner | Steps |
| --- | --- | --- | --- |
| Registry | Ownable2Step (pending owner in the ERC-7201 slot) | timelock | D `transferOwnership(timelock)`; Safe → timelock op `acceptOwnership()`, 48 h |
| AOAProtocolRegistry | Ownable (single step) | timelock | D `transferOwnership(timelock)` |
| xPNTsFactoryV2 | Ownable(msg.sender), single step | timelock | D `transferOwnership(timelock)` |
| BLSAggregator (A7) | Ownable(msg.sender), single step | Safe | D `transferOwnership(Safe)`; D `setSlashPolicyAdmin(Safe)` first |
| DVTValidator | Ownable | Safe | D `transferOwnership(Safe)` |
| committee `0x7ac7…96a9` | single-step `transferOwnership` present; no `acceptOwnership` or `renounceOwnership` (runtime selectors, read 11-01); owner currently D | Safe | D `transferOwnership(Safe)` after A8 |
| OverIssueFraudProofVerifier (A12a) | no Ownable/owner in DVT's current checkout `72aca4f` (DSR 11-01); re-confirmed on the frozen commit | — | — |
| old BLSAggregator `0xEaeC…2E5D` (retired) | Ownable, owner D; `slashPolicyAdmin` also D (read back) | Safe | D `setSlashPolicyAdmin(Safe)`, then D `transferOwnership(Safe)`, so D keeps no power over a retired but still callable contract |
| old verifier `0xa134…1cd3` (retired) | no `owner()` (reverts) | — | nothing to hand over; it is bound to the old aggregator only |
| SP proxy | (already the timelock since A17) | — | — |
| GlobalTierSource, xPNTsTokenV2 implementation and extension, SuperPaymasterLens | no owner | — | — |
| SP and Registry implementations | used only behind proxies; initializers disabled (**VERIFY**) | — | — |

A10, A11 and B4 must complete before BLSAggregator leaves D. After the Registry handover, an emergency Registry rotation
also takes 48 h. BLSAggregator and DVTValidator are Safe-only, with no timelock; the matrix records that asymmetry.

## 4. Nonce, budget and timing

- **Nonces.**
  - All D steps form one strictly increasing nonce sequence starting at the post-S7 nonce.
  - N, A and E each have their own sequences.
  - No other process may send from D, N, A or E until the manifest completes. The DVT/keeper ban stays in force.
- **Budget.** The deployer currently holds 12.16 ETH. That covers the stake top-up (≥ 0.9 ETH), the EntryPoint deposit
  top-up, and gas for every D step at the planned fee cap. The packet carries the exact per-sender budget, checked
  against balances at the pin.
- **Timing.** The 6d execution time must be ≥ `pendingAPNTsTokenEta`. With S7 on 2026-11-02, that is about
  2026-11-09 08:04 UTC.
  - Critical path: Phase A (about a day) → 5a + 48 h → 5b → 6c, scheduled so that 6d ≥ S7 + 7 d → 6d → Phase C → Phase D.
  - The Registry acceptance adds 48 h.
  - Expect sampling to start no earlier than about **2026-11-11/12**, roughly 2 days later than the route without the swap.

## 5. Relation to G3

- G3 freeze and sampling start only after Phase D is fully read back, including the Registry acceptance.
- The G3 matrix records:
  - the new tuple and the sampler gas limits;
  - the funding amounts;
  - which operators are sampled;
  - the owner topology, including the BLS/DVTValidator asymmetry.

## 6. STOP conditions, the state left behind, and recovery

STOP conditions (each is a hard stop; nothing later is sent):
- any §2 precondition fails;
- a read-back differs from the plan (address, codehash, owner, pointer, role set, tuple, pause state, stake, balances);
- a sender nonce differs from the plan, unless a gap is proven (#571);
- an estimate exceeds the planned gas limit;
- a mined status is not 1;
- an in-flight proposal appears on the old aggregator;
- the B2 gate fails.

| Stopped during | State left | Recovery |
| --- | --- | --- |
| A1–A5 | unused contracts; nothing pointed at them | none needed; rebuild from a new pin |
| A6 | Registry on 5.9.0 (same layout) | continue, or re-upgrade to 5.8.0 |
| A7–A12b | aggregator partially wired | point Registry/DVTValidator/committee back to the old aggregator; restore reputation sources |
| A13 | extra stake | `unlockStake` + 86400 s if it must be reclaimed |
| A14–A15 | operators paused, balances drained | owner unpauses; operators re-deposit |
| A17 | SP owned by the timelock and unpaused, still on 5.4.2 | every further change goes through Safe → timelock |
| 5a scheduled, before 5b | nothing executed | Safe cancels the operation (`CANCELLER` = Safe) |
| after 5b | SP 5.5.0, **globally paused**, tuple queued | Safe → timelock: a corrective operation, or 6c |
| 6c scheduled, before 6d | still paused | Safe cancels 6c |
| after 6d | active and unpaused on APNTsCapped | normal operation |
| Phase C/D partial | as listed per step | per-step undo above |

## 7. Rehearsal and controls (before the packet is frozen)

- **Rehearsal.** A full fork rehearsal on the pinned Sepolia state with the Amsterdam engine: every step, every read-back, timelock delays warped.
  - It includes the B2 gate and the swap in 6d.
  - After B4, one valid fraud proof submitted through A7 is accepted, and one invalid proof is rejected.
- **Negative controls.**
  - unpause before 6d rejected;
  - `configureOperator` before `setXPNTsFactory` rejected;
  - `applyBLSAggregator` before 24 h rejected;
  - `executeAPNTsTokenChange` before its ETA, or with `totalTrackedBalance ≠ protocolRevenue`, rejected;
  - the old aggregator cannot submit reputation after A9;
  - a non-owner Registry upgrade rejected;
  - `applyFraudProofVerifier` before 4 days rejected; a second direct call reverts `NoPendingVerifierRotation` (asserted); the executor, reading `fraudProofVerifier == A12a`, sends no transaction;
  - after Phase D, D can no longer call any owner function on the handed-over contracts.
- **The 0.1 aPNTs left after the swap.** `protocolRevenue` keeps 0.1e18 of accounting units backed by the old token,
  while SP holds 0 of the new token right after the swap. The rehearsal reads back `totalTrackedBalance` against the
  APNTsCapped balance of SP after 6d and after the first deposits. It confirms that later `deposit`,
  `withdrawProtocolRevenue` and every solvency invariant still hold; the conclusion is recorded here.
- **On chain.** The G3 pilot checks handleOps admission at 480000 (DSR #4, D6).

## 8. What changes for the paper

- All contract versions are bound to one frozen tag, with the §2 release evidence. After the tag, `contracts/src` does not change.
- Multisig disclosure: both testnet signers were controlled by one operator.
- Registry, AOAProtocolRegistry and xPNTsFactoryV2 are governed by the same 48 h timelock. BLSAggregator and DVTValidator are Safe-only.

## 9. Decision card for the go (filled in when the packet is built)

For each phase:
- the transactions in plain language, and who sends them;
- the on-chain state afterwards;
- whether and how each step can be undone (§6);
- the maximum cost;
- the main risks, and which guard stops a bad send;
- what changed since the previous go;
- who reviewed it;
- the timing.

The packet sha256 comes last, as the identifier.
