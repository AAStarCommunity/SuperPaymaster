# Pre-sampling manifest: one reviewed hash for every remaining Sepolia write (CC-125 / CC-127)

Status: **design accepted by DSR (revision 3 + two text fixes, 2026-11-01; Phase C rulings 2026-11-02)**. Packet building follows the §2 preconditions. No packet has been built, nothing is
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

The whole packet requires `sampled == [deployer]`; Anni stays paused after 6d.

Chain preconditions at the pin block:
- The old aggregator's `slashPolicyAdmin()` is read at the pin and must equal D.
- A3a S6a, S6b and S7 are mined and read back:
  - D's manifest start nonce is **12136**, rechecked at the pin;
  - APNTsCapped is owned by the timelock;
  - SP `pendingAPNTsToken == APNTsCapped` (`0x9Eb1…e1e7`), and `pendingAPNTsTokenEta == 1794226596` = **2026-11-09 12:16:36 UTC**, from S7 block **12048088**. The literal ETA is enforced by `pin_pending_token_eta`.
  - DSR 2026-11-02 read-back: S6a/S6b/S7 status 1 on both RPCs; APNTsCapped owner is the timelock. These are read-backs, not authorization for subsequent writes.
- The three A3a signers have sent nothing outside the plans, or every such transaction is a proven gap (#571).
- SP is 5.4.2 and owned by the deployer. The timelock `0xCCdF…C34B` has the A3a role sets.
- Registry is 5.8.0 with storage layout identical to 5.9.0 (32 variables, `_owner` at slot 0). **VERIFY**.
- The old BLSAggregator has no in-flight proposal or uncleared exit notice, scanned from its deployment block, except **DSR 2026-11-04 ruling: address-exact exemption**. Only `0xf36c9317765634e4995ce1e7210b5738225425b0` is hard-coded in the repository; plans/external inputs cannot add exemptions. For a nonzero `guardianExitRequests` value, independently require `expiresAt < block.timestamp` (`old_exit_exempt_expired`), absence from **every** `validatorAtSlot(1..13)` (`old_exit_exempt_slot`), on-chain `MAX_VALIDATORS == 13` (`old_exit_max_validators`), zero `pendingGuardianSlashCount` (`old_exit_exempt_slash`), absence from the A7 PoP inventory (`old_exit_exempt_pop`; at stage a7, before the PoP exists, this follows from the slot scan because the PoP validator set must equal the old aggregator's nonempty slot inventory, recorded as `popSource: slot-inventory`), and exact exemption-list membership (`old_exit_exempt_listed`). Otherwise STOP under the `old_exit_cleared` precondition with the specific failing gate. Read at the pin on both endpoints, record and replay both transcripts offline, and re-read all conditions at every `pre_send`.
  - In 4.11.0 the notice affects only `_reconstructPkAgg` (slot holders in the signer mask) and `_requireCommitteeSurvivesExit` (iterates `validatorAtSlot`). A guardian in no slot affects neither signing nor quorum counting on the forward **or rollback** path. The slot condition is load-bearing; rollback during A7–A12b can point back to this aggregator. The expired request cannot be consumed to exit the DVT role (`GuardianExitRequestExpired`).
- DVTValidator `0x568b…9E0e` has no unexecuted proposal, except **DSR 2026-11-05 ruling: id-exact exemption** for the seven duplicate E2E proposals `{1,2,4,5,6,8,9}` (see *A7 evidence notes — DSR 2026-11-05 stale DVT proposals*). The id set is hard-coded; plans/external inputs cannot add ids. The getters are the inventory: `nextProposalId == 10` (`dvt_stale_next_id`), `proposals(1..9)` are read directly, and the `ProposalCreated` log ids must equal exactly `1..9` (`dvt_proposal_inventory`; a missing or extra log STOPs). Each unexecuted id must pass `dvt_stale_proposal_listed`, `dvt_stale_proposal_shape` and `dvt_stale_sibling_executed`, and the unexecuted set must equal the seven ids (`dvt_stale_open_set`, so executing any of them also STOPs). At the pin `old_pointer` requires DVTValidator and the committee to point at the old aggregator; `A8.dvt` reads back `BLS_AGGREGATOR == A7`; after the last step `dvt_closing` takes one block number from `latest` and binds every read to it (DSR #606 L2): it re-checks all three A8 pointers — `Registry.blsAggregator`, `DVTValidator.BLS_AGGREGATOR`, `committee.blsAggregator` — against the old aggregator at stage `a7` and A7 otherwise (`closing_registry_pointer`, `closing_dvt_pointer`, `closing_committee_pointer`; L1), re-runs the inventory against the pin record (`closing_dvt_activity`) and the seven `executed == false` (`closing_stale_unexecuted`). The run artifact records `dvtClosing` = {block, pointers, dvtAggregator, staleUnexecuted}.
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
  `result: PASS` covers only the 23 required suites. Bind `ciRun {runId, headSha, overall:"failure", jobs}`
  and a closed `acceptedFailures` list containing only "Security Audit" (npm). Any other failing job or missing
  run binding is STOP (DSR 2026-11-02).
- That verifier source was validated against BLSAggregator 4.11.0 only. DVT's conformance run against 4.12.0 (`fbd74fb1`)
  must pass before the packet is built. Otherwise STOP. DVT reported on 11-01:
  - `CC115CrossRepoConformance`: 7 passed;
  - `CC115GenuinePragueCrossRepo`: 11 passed with `FOUNDRY_EVM_VERSION=prague` (all skip by default);
  - provenance: 5 passed.

  Re-run if BLSAggregator changes on main before the frozen tag.
- Guardian-set binding mutation controls (DVT 11-01, on the vendored copy at `fbd74fb1`, mock and real Prague agree).
  Each mutation turns a test red, and everything passes once reverted:
  - removing the `_isEqualSet` check: `VerifierAcceptsGuardianSubset` red;
  - weakening it to a subset comparison: `VerifierAcceptsGuardianSubset` red;
  - changing the length check from `!=` to `<`: `VerifierAcceptsGuardianSuperset` red.
- Verifier pin: DVT `72aca4fa0ba4aaa8c8a96210b1124534431294d6`.
  - Build: Forge 1.7.1 with the real submodules (no symlinks): `cd contracts && forge build --force --skip test --skip script --use 0.8.33`.
  - Creation keccak without constructor arguments: `0x736520628b9e5ed4163f440e4e7b5d064b4e4cb4571c29d926941964e038e3ab`, 3301 bytes.
  - DVT's own deploy script pins `BLSAggregator-4.11.0` (`EXPECTED_AGGREGATOR_VERSION`). The packet uses a bare CREATE, so the A12a read-back is mandatory.
- After the pin, D gives DVT the new aggregator's address, `version()` and the validator slots (current guardians
  hold slots 1, 2 and 3: `0x5D87…Eca3`, `0x40F0…bd1f`, `0xD904…1601`). DVT exports the PoP data
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
| B2a (after the 5b read-back passes, before 6c is scheduled) | Safe (A approves, E executes): `APNTsCapped.mint(SP proxy, 0.1e18)`. This is a plain `_mint` (`APNTsCapped.sol:92`), not `transferAndCall`, so it is not recorded as a deposit. The Safe is the minter. Safe nonces are fixed in the order 5a, 5b, B2a, 6c, 6d, so every safeTxHash is computable in advance. If the mint fails, 6c is not scheduled. | — | `APNTsCapped.balanceOf(SP) == 0.1e18` |
| B2 (before 6d) | read-back gate: `totalTrackedBalance == protocolRevenue ≤ 0.1e18` (old-token accounting); `APNTsCapped.balanceOf(SP) == 0.1e18` **exactly** (more is also a STOP; read independently of the tracked total); no in-flight sponsorship (a stale release returns balance); no pending slash | — | STOP if any differs |
| B3 = 6c/6d `activation` (predecessor B1) | `executeGasParams()`; `applyBLSAggregator()`; **`executeAPNTsTokenChange()`**; `setOperatorPaused(op, false)` for each **sampled** operator only; `setGlobalPaused(false)` | 6c is scheduled so that 6d runs at ≥ `pendingAPNTsTokenEta` | active tuple, aggregator, `APNTS_TOKEN == APNTsCapped`, sampled operators and global unpaused, unsampled operators still paused |
| B4 | D, at a **reserved nonce that is always used** (DSR 11-01, option d). Read `fraudProofVerifier` just before sending. If it is not yet A12a, send `A7.applyFraudProofVerifier()` (only the executor sends it: DVT's Apply Verifier Rotation workflow is hard-wired to the old aggregator and stays disabled until the Phase D read-back). If it is already A12a, send instead a placeholder at the same nonce: a 0-value self-transfer from D to D with empty data, its gas limit fixed. Both variants are fully specified (to, value, data, gas, fees) in the packet and covered by its hash. No other content is allowed. | 4 d | **Post-state**: `fraudProofVerifier == A12a` and the pending rotation cleared |

Timing:
- `queueBLSAggregator` has a 24 h internal delay, so `applyBLSAggregator` in 6d is in time.
- `deposit`, `depositFor` and `onTransferReceived` do not check the pause, so balances can be added back after the drain. That is why B2 re-reads them immediately before 6d.

### Phase C — funding and sampling configuration (after 6d)

Resolved by DSR 2026-11-02; these design rulings do not authorize on-chain writes. The author still gives go on the packet hash.
**D is the only sampled operator.** B3 unpauses D only; N stays paused, receives no V2 token and no funding.
All amounts below are integer base units. Every symbolic input becomes a literal in the packet before its hash/go;
no sender chooses an amount, address, branch or nonce at execution time. A row containing several calls expands into
separate, ordered transactions with separate nonces and read-backs.

Bindings (G3 §2, §6): `F` = A4 factory, `X` = D's new V2 clone, `EP` = v0.7 singleton,
`S` = one SimpleAccount shared across all arms, `O` = its registered owner keystore, `s` = pinned salt,
`B` = dedicated bundler EOA, distinct from D/N/A/E, `V` = VPM signer keystore. B/O/V are freshly generated,
dedicated keystores; only their addresses enter the packet, never keys. D funds B and O.
`R = 0x000000000000000000000000000000000000dEaD`, distinct from S. `T` is a new plain ERC-20 task token,
separate from APNTsCapped, X and TPM's fee token `Q`. `u = 1` smallest T unit. All arms execute exactly
`S.execute(address,uint256,bytes)(T,0,abi.encodeCall(transfer,(R,u)))`; record its `callDataHash`.
The existing factory is `0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985`, implementation `0x6864…00C2`;
full implementation address/runtime and rebuild evidence are pinned, not inferred from the abbreviation.

**Funding worksheet (G3 §3, §3a, §4).** Define `ceilDiv(n,d) = (n+d-1)//d`, `positive(x) = max(0,x)`.
Use `n = 100` attempts **per arm** (50 formal + 20 pilot + 30 failure/exclusion margin), `f = 5×10^9 wei`,
priority cap `1×10^9 wei`, including the pilot. For arm j, pre-pilot funding bounds are
`c_j, v_j, pv_j, pp_j, pre_j` for call, account verification, paymaster verification, postOp and preVerification gas.
`SP_RENEW` is **never set**, and initial `pp_SP = 480000`. Pre-pilot gas and outer transaction upper bounds
are the Amsterdam fork rehearsal measurements × 1.5 (rounded up), fixed before the packet, with `g_j = c_j+v_j+pv_j+pp_j+pre_j`, `M_j = g_j×f` (maximum EntryPoint prefund).
This is the v0.7 sum, with no v0.6 multiplier (`singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol:402`).

Set `P* = 3500e8` (8 decimals, `d = 8`) as the upper bound for positive cached ETH/USD price, `a` the pinned
`aPNTsPriceUSD`, `b` the pinned `protocolFeeBPS`, and `e = 1e18`. Exceeding P* is **STOP**;
a pin price alone does not bound future reservations. Source rounding is nested, not one rounded approximation:

| Quantity | Exact funding rule / predicate |
| --- | --- |
| Maximum SP reservation in aPNTs units | `A0 = ceilDiv(M_SP×P*×10^18,10^d×a)`; `Amax = ceilDiv(A0×(10000+b+1000),10000)`. The 1000 is `VALIDATION_BUFFER_BPS`; see its declaration at `SuperPaymasterStorage.sol:209` and use at `SuperPaymaster.sol:309`; the initial conversion is at `SuperPaymaster.sol:218–222` (under `contracts/src/paymasters/superpaymaster/v3/`). |
| D operator deposit | Target `AD = n×Amax + beta_A`; top-up `delta_A = positive(AD − operators(D).aPNTsBalance)`. Mint `delta_m = positive(delta_A − APNTsCapped.balanceOf(D))`. `beta_A = 5×Amax`. Require final operator balance ≥ AD and ≤ uint128 max. |
| EP deposits | Each j ∈ {SP,VPM,TPM}: target `ED_j = n×M_j + beta_EP_j`; `delta_EP_j = positive(ED_j − EP.balanceOf(j))`, using post-A13 balance for SP. Set `beta_EP_j = M_j + extra_EP_j` with `extra_EP_j = 5×M_j`: the collector requires post-send deposit ≥ `B_max×M_j = M_j`, even on attempt 100 (`deposit-guard.mjs:40`). Separate stake from spendable deposit. |
| User V2 balance | `Xmax = ceilDiv(Amax×e,10^18)`; target `XD = n×Xmax + beta_X`, `beta_X = 5×Xmax`; mint `positive(XD−X.balanceOf(S))` only with `debts(S)==0`, `lockedOf(S)==0`, `creditReservedOf(S)==0`. Amax is in aPNTs units; X needs this conversion (equal at e = 1e18), as registered in G3 §4. Require `Amax ≤ 5000e18` and `X.maxSingleTxLimit() ≥ Amax` (default 5000e18). |
| Task token | Before pilot: `T.balanceOf(S) ≥ 3×n×u + u = 301`, `T.balanceOf(R) ≥ u = 1`; the extra sender unit keeps both balances nonzero even after 300 successful transfers. Mint the exact deficits. R never sends T back during the window. |
| TPM fee token / allowance | With Q's 18 decimals, F1Oracle 1:1 and markup 1e26, `Qmax = ceilDiv((M_TPM+40000×f)×10^26,10^26)`; target `QD = n×Qmax + beta_Q`, `beta_Q = 5×Qmax`. Mint deficit to S and approve TPM for QD. Require cachedPrice = 1e26; otherwise recompute from `floor(cachedPrice×1e26/markup)` as denominator. Covers the extra refundPostopCost in `singleton-paymaster/lib/account-abstraction-v7/contracts/samples/TokenPaymaster.sol:132`; never use T to pay fees. |
| Bundler ETH | `BD = n×f×(H_SP+H_VPM+H_TPM) + f×sum(H_aux) + beta_B`. H_j bounds the **outer** single-op handleOps transaction, including overhead; H_aux bounds B's separately listed maintenance transactions; `beta_B = 0.2 ETH`. Fund `positive(BD−balance(B))`. Do not net expected beneficiary reimbursements: B must pay even reverted outer transactions. |

Fixed inputs (Resolved by DSR 2026-11-02): `name = "AOA Research Points"`, `symbol = "xARP"`,
`communityName = "AOA Research"`, `communityENS = ""`, `e = 1e18`, and
`treasury = 0x16dF788Ed4ed1fc384e52Dc832a6a6C3A23BdeBf` (test Safe). P*, betas and R are fixed above.
Measured calibration/H values, generated B/O/V addresses, S/salt and balances are recorded at the pin / packet build.
Actual pilot measurements and G3 frozen gas values remain **TBD until the pilot**; 5/1 gwei caps are fixed.
O sends C9, C18's approval and in-window TPM refreshes; D sends C18's mint. SP refresh belongs to the DVT keeper.
O's ETH target `OD` sums every listed preparation/maintenance gas limit × its fee cap; D funds its deficit.

**Ordering:** Phase C funding precedes Phase D and the pilot. It funds against the fee cap and the above reviewed gas/
price upper bounds, not an unknown pilot measurement. No separate pilot funding step is needed: its ≤20 attempts per
arm are included in n. W3's 480000/479999 admission checks are `eth_call`, not funded transactions. The pilot runs ≥5
cold/warm operations per arm; freeze call/post at `ceilDiv(pilotUpper×115,100)`, SP post at least 480000, and record
verification/preVerification bounds. If SP post freezes **above 480000**, recompute **all** affected reservations,
limits and balances (G3 §4); likewise for any other exceeded bound. Initial 480000 funding is not claimed to bound a
larger post. Compare remaining funds against remaining attempts and the collector deposit floor; archive consumption
and surplus. With h_j attempts already consumed, require EP deposit ≥ `(100−h_j)×M_j_new + M_j_new + extra_EP_j`, D balance ≥ `(100−h_SP)×Amax_new + beta_A`, and X balance ≥ `(100−h_SP)×Xmax_new + beta_X`; recompute Q/B similarly, including all 5× buffers from the new per-attempt maxima. If balances suffice, DSR signs off the recomputation without a transaction. If any transaction is needed,
**STOP** before formal sampling and build a new packet for author go on the new hash, with new read-backs. Never top up mid-sampling. Exceeding the pilot's 20-attempt allocation also requires a new budget review.

**Concrete transactions.** CREATE rows bind full creation bytecode, constructor ABI, arguments and predicted address.
`pin.*` means an archived value/decision, not a live lookup that silently changes calldata. Zero-deficit and already-
satisfied conditional rows are omitted **before** nonce assignment; a later discrepancy is STOP, not a skipped nonce.
Paths below are relative to the repository. Step labels are retained; C20 funds O before C9/C18 owner calls,
and its nonce is assigned in that execution order.

| Step | Sender → target | Exact call / arguments | Preconditions | Read-back predicate | Undo / recovery | G3 row |
| --- | --- | --- | --- | --- | --- | --- |
| C1 | Safe (A approves / E executes) → APNTsCapped | `mint(address,uint256)(D,delta_m)` | B3/B4 complete; active gas tuple=(480000,450000,5000,450000), pending gas queue empty, global/D unpaused and N paused; `minter()==Safe`; D≠0; `totalSupply()+delta_m ≤ cap()`; pinned existing D balance | D balance and supply increase exactly delta_m; cap/minter unchanged | D `burn(uint256)(unused)` frees cap; spent mint cannot be undone | §4 operator funding; W1 |
| C2 | D → APNTsCapped, then SP | `approve(address,uint256)(SP,delta_A)`; `deposit(uint256)(delta_A)` | C1; D has PAYMASTER_SUPER; APNTS_TOKEN is capped token; allowance/balance sufficient; uint128 addition safe | allowance after approve = delta_A; operator balance ≥ AD, tracked and SP token balances each rise delta_A; solvency reconciled | D `withdraw(uint256)(unused)` if no pending slash/inflight; revoke leftover approval | §4 operator funding |
| C3 | D → F, then SP | `deployxPNTsToken(string,string,string,string,uint256,address)(pin.name,pin.symbol,pin.communityName,pin.communityENS,e,address(0))`; `configureOperator(address,address)(X,pin.treasury)` | F is active SP factory; checks listed below; D roles true | F.getTokenAddress(D)=X; isXPNTs(X); clone/template bindings; operator token=X, treasury exact, configured=true, paused=false; balance/minTxInterval unchanged; X policy=0, pendingPolicyEta=0 | Clone cannot be deleted/redeployed for D in F; stop and review correction. Old V1 cannot simply be restored through this V2-only configure path | §2 operators/BALANCE; §5 |
| C5 | D → existing SimpleAccount factory | `createAccount(address,uint256)(O,s)` | G3 rebuild evidence; `getAddress(O,s)==S`; pinned factory/implementation/EP; S absent or correct | code/implementation match, `owner()==O`, `entryPoint()==EP`; same S on every arm | No deletion; unused account may remain | §2 Accounts; §6 Senders |
| C6 | D → GToken | `approve(address,uint256)(Registry.GTOKEN_STAKING(),k+t)` | New ENDUSER S; D token balance ≥ k+t; k=pin ENDUSER minStake, t=pin ticketPrice; lock/stake constraints pass | allowance=k+t | `approve(staking,0)` | W1, §2 Accounts |
| C7 | D → Registry | `safeMintForRole(bytes32,address,bytes)(keccak256("ENDUSER"),S,abi.encode(D,k))` | C5/C6; ENDUSER active; D COMMUNITY; S lacks ENDUSER; MySBT/Registry/SP pointers and airdrop eligibility valid | Registry.hasRole(ENDUSER,S), MySBT membership, SP.sbtHolders(S) and isEligibleForSponsorship(S) true; stake=k, ticket accounted | O→S `execute(Registry,0,abi.encodeCall(exitRole,(ENDUSER)))` subject to role lock/exit fee; ticket not refunded | W1, §2 Accounts |
| C8 | D → X | `mint(address,uint256)(S,positive(XD−pin.balanceX))` | C3/C5; communityOwner=D; no user debt/lock/reservation | balance≥XD; supply delta exact; creditPolicy=0, pendingPolicyEta=0 | S owner may burn unused own X; no arbitrary third-party burn | §4 user balance; §5 OFF |
| C20 | D → O | ETH transfer, `data=0x`, `value=positive(OD−pin.balanceO)` | Dedicated O fixed; all C9/C18 preparation and in-window TPM refresh gas budgeted; D full budget passes | balance(O)≥OD | O returns unused ETH after completion | §4 funding; §6 owner/maintenance |
| C9 | O → S → X | `execute(address,uint256,bytes)(X,0,abi.encodeCall(setAutoAllowance,(SP,L)))`; inner `setAutoAllowance(address,uint256)(SP,L)`; same wrapper for `setUserTotalCap(uint256)(L)`, `setRenewalMode(uint8)(0)` | L=50000e18; Amax≤min(L,X.maxSingleTxLimit()); C20 funding satisfied; fresh X/S used counters zero; no outstanding lock/reservation; O owns S | `autoAllowance(S,SP)=(L,0)`, `userTotal(S)=(L,0)`, renewalMode=0, autoRenewUsed=0; OFF unchanged | Owner restores pinned caps/mode when idle; no renewal | §3 SP_RENEW never; §4 balance; §5 |
| C10 | D → CREATE T | `F1TestToken.constructor()` from pinned `contracts/test/bundler/F1Fixtures.sol` artifact, separate instance from Q | DSR permits fixture use on Sepolia; source commit/provenance in §9 card; creation hash/nonce fixed | MINTER=D; 18 decimals; ERC-20 runtime/hash exact | Unused contract remains | §2 Task; §6 T |
| C11 | D → T | `mint(address,uint256)(S,positive(301−pin.balanceT_S))`; `mint(address,uint256)(R,positive(1−pin.balanceT_R))` | C5/C10; fixed R≠S, R≠0 | S≥301, R≥1; hash of identical task calldata recorded | Transfer unused balances only by their holders; no burn in F1TestToken | §2 Task; §6 R/callDataHash |
| C12 | D → CREATE VPM | `VerifyingPaymaster.constructor(address,address)(EP,V)` | Pinned unchanged v0.7 artifact; real registered V keystore | runtime/immutables, owner=D, entryPoint=EP, verifyingSigner=V | Unused deployment remains | §6 VPM; W1/W6 |
| C13 | D → CREATE Q, then oracle | `F1TestToken.constructor()`; `F1Oracle.constructor()` | Separate Q≠T; pinned artifacts as C10 | Q.MINTER=D, decimals=18; oracle decimals=8, answer=1e8 | Unused deployments remain | §6 TPM configuration |
| C14 | D → CREATE TPM | `TokenPaymaster.constructor(address,address,address,address,(uint256,uint128,uint48,uint48),(uint48,uint48,address,address,bool,bool,bool,uint256),(uint256,uint24,uint8),address)(Q,EP,DEAD,DEAD,(1e26,0,40000,864000),(864000,864000,C13.oracle,0,true,false,false,1e25),(1,3000,5),D)`; DEAD=`0x000000000000000000000000000000000000dEaD` | C13; pinned v0.7 artifact and tuples; no swap path (minEntryPointBalance=0) | owner, EP, Q, oracle/config/runtime/immutables match; wrappedNative/uniswap=DEAD | Unused deployment remains; no real swap permitted | §6 TPM; §7 TPM disclosure |
| C15 | D → TPM | `updateCachedPrice(bool)(true)` | C14; oracle read valid | cachedPrice=1e26, timestamp fresh; recheck W2 before pilot/window | Refresh via O later; no rollback of time | W2; §4 TPM funding |
| C16 | D → VPM, then TPM | each `addStake(uint32)(86400){value:1 ether}` | C12/C14; owner=D; explicit 2 ETH budget | EP.getDepositInfo: stake≥1 ETH, delay≥86400, withdrawTime=0 | Each owner `unlockStake()` then `withdrawStake(address)(D)` after delay | W1; §6 baseline configuration |
| C17 | D → EP (three transactions) | `depositTo(address)(SP){value:delta_EP_SP}`; same for VPM and TPM | C12/C14; balances at pin plus known earlier effects; D ETH budget passes | EP.balanceOf(j)≥ED_j for all three; stake unchanged | Baseline owner `withdrawTo(address,uint256)(D,unused)`; SP withdrawal requires its timelock owner | §4 EntryPoint deposits |
| C18 | D → Q, then O → S → Q | `mint(address,uint256)(S,positive(QD−pin.balanceQ))`; `execute(address,uint256,bytes)(Q,0,abi.encodeCall(approve,(TPM,QD)))` | C5/C13/C14; QD worksheet; O owns S | Q.balanceOf(S)≥QD; allowance(S,TPM)=QD | O revokes approval/transfers unused Q | §4 comparator funding; §6 TPM |
| C19 | D → B | ETH transfer, `data=0x`, `value=positive(BD−pin.balanceB)` | Dedicated B identity fixed, distinct from D/N/A/E; D budget covers it | balance(B)≥BD; registered B/beneficiary match | B returns unused ETH after completion | §6 Bundler; §4 funding |

**Registration stays frozen (Resolved by DSR 2026-11-02).** No reopening transaction is included.
A16 sets `PAYMASTER_SUPER.isActive=false`, blocking registration/minting (`Registry.sol:322`, `:421`, `:458`),
without erasing existing membership. ENDUSER inactive is **STOP**. If S already has valid membership, omit C6/C7
at build time after reading both MySBT and SP status. Any S status mismatch is **STOP**: D cannot call
`SP.updateSBTStatus` directly (Registry-only, `SuperPaymasterAdmin.sol:170`); no impersonation/override is a repair.

**In-place configuration is confirmed, not an open choice.** `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:118–146`
has no already-configured check and writes only xPNTsToken, treasury and isConfigured. It preserves aPNTsBalance,
pause, reputation, minTxInterval and counters. Record all `operators(D)` fields before/after C3, plus old/new token limits and policy getters. Its complete checks are: D has PAYMASTER_SUPER (helper in
`SuperPaymasterStorage.sol:311`); D has COMMUNITY; token and treasury nonzero; xpntsFactory nonzero;
factory.getTokenAddress(D)==X; X.BALANCE_MODE_VERSION() returns 1 (revert/malformed call fails). There is no
operator `maxSingleTxLimit` field: read `operators(D)` for balance/minTxInterval and **X.maxSingleTxLimit()** for
the reservation cap. Preserve the pinned minTxInterval; wait until each next SP attempt satisfies lastTimestamp +
interval and record that cadence in G3. No unlisted `setOperatorLimits` or cap increase.

`contracts/src/tokens/v2/xPNTsFactoryV2.sol:288–343` checks implementation codehash and its EXTENSION codehash,
COMMUNITY membership, no prior communityToToken[D], and nonzero exchangeRate. Clone creation must succeed.
Initialization (`contracts/src/tokens/v2/xPNTsTokenV2.sol:72–108`) is initializer-only and requires nonzero
community/owner and effective rate in [1e14,1e22]. Zero superPaymaster and tierSource are allowed; if nonzero,
they must be approved (`:87–93` and `:102–107`, respectively). A nonzero genesis spender must differ from SP
and have an approved implementation (`:94–101`; in this plan paymasterAOA=0). Factory then asserts FACTORY=self,
communityOwner=D, community=D, exchangeRate=e, `SUPERPAYMASTER_ADDRESS()==SUPERPAYMASTER`,
`creditTierSource()==defaultTierSource`, creditPolicy=0, and autoApprovedSpenders(paymasterAOA) if nonzero
(`contracts/src/tokens/v2/xPNTsFactoryV2.sol:324–332`; the SP/source equality checks are `:328–329`).
For this plan, nonzero SP/source bindings follow from those assertions against the pinned nonzero factory configuration,
not from initialize rejecting zero. The factory constructor permits SUPERPAYMASTER=0 (`:244`), but requires an
approved nonzero defaultTierSource (`:234–236`); its source setter also enforces that (`:446–452`).
It records the mapping/list/whitelist.
No metadata nonempty check or role isActive check is present. Clone/initializer/external getter failures also revert the factory transaction. Read `pendingPolicyEta()==0` additionally; there is
**no credit queue/execute transaction**. X mint permits only factory/communityOwner and nonzero recipient
(`xPNTsTokenV2Ext.sol:368`); minting to a debtor repays/burns debt, hence C8's zero-debt gate.
APNTsCapped mint is Safe-minter-only, capped by supply+amount, and rejects zero recipient via ERC-20 `_mint`
(`contracts/src/tokens/APNTsCapped.sol:92`). Insufficient cap is STOP, not an implicit raiseCap operation.

**No renewal (Resolved by DSR 2026-11-02, Q5 reversed).** `L = 50000e18`; `SP_RENEW` is **never set**,
and there is no owner-renewal transaction. Before **every SP attempt**, pilot and formal, read `used` for both
`autoAllowance(S,SP)` and `userTotal(S)`; if either `L-used < Amax`, **STOP and go through a new packet**.
Archive the precheck. Never reset usage to continue collection.
`settleLocked` refunds `aReserved-charge` (`xPNTsTokenV2.sol:250–268`), so used accumulates actual charges,
roughly 193/attempt at 2 gwei or 481 at 5 gwei (~19k–48k for 100 attempts); these estimates do not replace the precheck.
Renewal resets used to zero and makes the next SP attempt incur first-write cost, contaminating samples.
SP uses only lock/settle (`SuperPaymaster.sol:439`); stale `_releaseLock` refunds the full aReserved.
`_spendV2` (`xPNTsTokenV2.sol:162`) adds the full amount only for auto-approved non-SP spenders calling
transferFrom/burnFrom; with `paymasterAOA=0` there is none. Source citations are the verified DSR ruling evidence.

**Tooling reconciliation.** `deploy-baselines.mjs` is a local-only recipe (Anvil keys, 10 ETH deposits per baseline),
not a Sepolia executor. C12–C18 retain its comparator constructor/config values while substituting registered signers
and computed deposits. DSR permits the F1TestToken/F1Oracle artifacts on Sepolia without source changes.
Record their source commit in the packet and explain the difference from the fixture header's "local only" scope
in the §9 decision card; this does not authorize the local deployment script or its Anvil defaults. Current `collector.mjs:264–280` takes formal GAS/PM_GAS/MAX_FEE_CEILING and
calldata from the frozen configuration; its local defaults are not the G3 configuration. Formal preparation checks
S via the factory and task balances (`:480`), but is not a substitute for these funding transactions. Bind formal
5/1 gwei, the pilot's frozen gas, `B_max=1`, rotating arms, BALANCE/OFF and identical transfer calldata. Collector,
validator and positive-control acceptance remain W6 gates; this document makes no claim that they have passed.
W1 additionally requires Phase D/Registry acceptance; W4 (author go/A4), W5 (independent RPC identities) and W7
(author DVT-freeze decision) are evidence/decision gates, not missing Phase C transactions. Require all W1–W7
before the G3 freeze, with W3 supplied by the pilot.

Resolved by DSR 2026-11-02 (design decisions; presented with the packet hash go):
1. **Q1:** P*=3500e8; beta_A/extra_EP_j/beta_X/beta_Q are 5× their per-attempt maxima; beta_B=0.2 ETH.
   Pre-pilot bounds use Amsterdam rehearsal ×1.5; SP post=480000; Amax≤5000e18. DSR signs off a sufficient
   post-pilot recomputation without a transaction; any needed transaction requires a new packet and author go on its hash.
2. **Q2:** D funds B/O; B/O/V use fresh dedicated keystores, with only addresses in the packet. O sends C9,
   C18 approval and in-window TPM refreshes; the DVT keeper refreshes SP.
3. **Q3:** No registration reopening. ENDUSER inactive or S status mismatch is STOP.
4. **Q4:** X metadata/rate, test Safe treasury and dead-address R are fixed above. F1 fixtures are permitted with
   source commit and the local-only-header explanation in §9. No separate author question; include them with hash go.
5. **Q5 (reversed):** No renewal; SP_RENEW never. Before every SP attempt, `L-used < Amax` is STOP, new packet.
6. **Q6:** 1 ETH stake each for VPM/TPM, D ownership (disclosed), and 864000-second TPM cache settings accepted.

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
| SP and Registry implementations | used only behind proxies; initializers disabled. Their implementation-local storage still has `owner == D`, because the constructor runs `Ownable(msg.sender)` before `_disableInitializers` (`Registry.sol:86`, `BasePaymasterUpgradeable.sol:24`). This does not give D any control of the proxies. It is disclosed, not handed over | — | — |

A10, A11 and B4 must complete before BLSAggregator leaves D. After the Registry handover, an emergency Registry rotation
also takes 48 h. BLSAggregator and DVTValidator are Safe-only, with no timelock; the matrix records that asymmetry.

## 4. Nonce, budget and timing

- **Nonces.**
  - All D steps form one strictly increasing nonce sequence starting at **12136**, the post-S7 nonce (rechecked at the pin).
  - N, A and E each have their own sequences. Phase C adds Safe mint nonce(s) after 6d, plus O's account-owner calls; expand every multi-call row before fixing CREATE addresses. B/O/V are fresh dedicated identities; bind their addresses before assigning nonces.
  - B has a separate sequence for pilot/formal handleOps and registered maintenance, beginning only after Phase D. Pin O preparation/TPM-refresh slots and the account's EntryPoint nonce separately; direct owner execute calls consume EOA nonces, not UserOperation nonces.
  - No other process may send from D, N, A or E until the manifest completes. The DVT/keeper ban stays in force.
- **Full budget.** The packet computes the **total ETH required from D**, including all Phase A/B deployments
  and calls, SP stake top-up and both 1 ETH baseline stakes, every EP deposit (count A13 only once), B and O
  funding, and all transaction gas at packet fee caps. Re-read D's balance at the pin. If it is short, **STOP and
  report the exact shortfall; never reduce n** (100 attempts per arm). DSR's rough EP ~3.5 ETH, baseline stakes
  2 ETH and B worst ~3.75 ETH plus Phase A/B deployments are close to the historical 12.16 ETH balance;
  they are estimates, not a sufficiency proof. Safe/A/E/O/B each need a separate budget. The worksheet also binds
  APNTs cap headroom, GToken stake/ticket, V2/Q/T amounts and integer rounding. Pilot/formal fees remain 5/1 gwei.
- **Timing.** 6d must execute at or after **2026-11-09 12:16:36 UTC**, `pendingAPNTsTokenEta = 1794226596`,
  from S7 block **12048088**.
  - Critical path: Phase A (about a day) → 5a + 48 h → 5b → 6c, scheduled so that 6d ≥ S7 + 7 d → 6d → Phase C → Phase D (including Registry +48 h acceptance/read-back) → pilot → recomputation/read-back → G3 freeze → formal collection.
  - The Registry acceptance adds 48 h. Phase C must fund the pilot before this handover; pilot → recomputation/read-back → G3 freeze → formal collection follows full Phase D acceptance. Reserve W2 refresh time and D's pinned minTxInterval between SP attempts. A funding shortfall delays the window; no mid-sampling top-up.
  - **2026-11-11/12 remains only a conditional earliest-start estimate**, not a confirmed sampling date. Assume 6d executes on November 9, Phase C and full Phase D acceptance/read-back finish by November 11, and reserve up to one additional day for the pilot (including minTxInterval/W2 waits), recomputation/read-back and DSR's G3 freeze. Under those assumptions formal collection can start late November 11 or on November 12. If the pilot/freeze needs longer, another W1–W7 gate is outstanding, or funding needs a revised packet, move the estimate later; pilot time is not zero.

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
- a mined status is not 1, with one exception: if B4's `applyFraudProofVerifier` was front-run after the read and
  mined with status 0, B4 passes only when its post-state holds (`fraudProofVerifier == A12a`, pending cleared). The tx
  is recorded. If the post-state does not hold, STOP;
- an in-flight proposal appears on the old aggregator;
- the B2 gate fails;
- cached ETH/USD exceeds `P* = 3500e8`, Amax exceeds 5000e18, ENDUSER is inactive or S status mismatches;
- before any SP attempt, either used counter leaves `L-used < Amax`: STOP, new packet; SP_RENEW is never set;
- any renewal is proposed, or a required post-pilot transaction is absent from a new reviewed packet/hash go;
- the full D budget is short: report integer wei fields `requiredWei`, `balanceWei` and `shortfallWei` (DSR 2026-11-05; both the `budget_<sender>` and Phase C `budget_deployer_values` reports), never reduce n; or B/O/other sender funding is insufficient;
- the DVT CI run binding is missing or any failing job is outside the closed "Security Audit" (npm) exception.

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
| after B2a, before 6c | as above, plus 0.1 APNTsCapped held by SP and not yet tracked | harmless: it backs the buffer only once the swap runs; if the route is abandoned it stays as untracked new token in SP |
| 6c scheduled, before 6d | still paused | Safe cancels 6c |
| after 6d | active and unpaused on APNTsCapped | normal operation |
| Phase C partial | D may be funded/reconfigured, S prepared, comparators deployed/staked; N remains paused and unfunded | Per-step recovery above; no claim that deployments, tickets or used funding are reversible. SP recovery requiring owner authority goes through timelock. |
| Phase C/pilot funding or identity gate | Cap headroom, roles/SBT, policy OFF/pending ETA, single reservation/allowance, gas/price bounds, sender budget or identity differs; or the per-attempt used precheck fails | STOP. Fix the design and obtain a new packet/go for additional writes. If pilot SP post >480000, recompute; any shortfall stops formal collection, never triggers mid-sampling funding. |
| Formal window funds/cap exhausted | Attempts and surplus/shortfall recorded; no unlisted top-up, cap change or renewal sent | STOP and preserve evidence; insufficient `L-used` requires a new packet; a changed configuration requires a new reviewed freeze/window. Fee-cap exclusion follows G3 §3a: pause/wait, keep attempts, never raise the cap. |
| Phase D partial | ownership partly handed over | Use the actual current owners; no D-only recovery assumed. |

## 7. Rehearsal and controls (before the packet is frozen)

- **Rehearsal.** A full fork rehearsal on the pinned Sepolia state with the Amsterdam engine: every step, every read-back, timelock delays warped.
  - It includes the B2 gate and the swap in 6d.
  - After B4, one valid fraud proof submitted through A7 is accepted, and one invalid proof is rejected.
    The data comes from DVT's read-only `--export-fraud-drill`, run after the pin. It needs A7 and the verifier address
    (both fixed by D's nonces); no key material is involved.
    - Fork state, built on a snapshot: `anvil_setCode` puts `MockOverIssuableToken` (from `72aca4fa`) at DVT's fixed address
      T, with `over = false`. `anvil_setStorageAt` writes A7's `proposalSignersCommitment[pid]`, using the slot computed
      from `forge inspect BLSAggregator storage-layout` at the pin. The value is read back and must equal the tool's value
      (this also catches a wrong slot), otherwise STOP. pid is a large random value, so it cannot collide with a real proposal.
    - Valid: `A7.queueGuardianSlash(fraudProofId, guiltyGuardians, fraudProof)` succeeds and emits `GuardianSlashQueued`,
      with `fraudProofId = verifier.deriveFraudProofId(pid)` and the three guardians in ascending order.
    - Invalid, each rejected:
      - N1: one guilty guardian missing (`InvalidFraudProof`);
      - N2: T's `over` set to true, same proof (`InvalidFraudProof`);
      - N3: one bit of `signerMask` flipped in the proof (commitment mismatch, revert);
      - N4: one digest bit flipped (A7 computes the digest itself, so this is checked by a direct `verifier.verify`, which must return false).
    - Scope: this proves A7 plus the deployed verifier bytecode, under the real domain, accept and reject correctly. It does
      **not** prove that A7's `verifyAndExecute` writes the same commitment, and it skips `_checkSignatures`. That part rests
      on source-level tests at `fbd74fb1` (`InnerCommitmentLayoutParity` and the real-precompile Prague tests).
    - DSR conditions (11-01):
      - The drill runs on its own snapshot and is reverted afterwards. `anvil_setCode` / `anvil_setStorageAt` state
        never enters the main rehearsal path, and no main-path read-back comes from a modified fork. The report records
        both snapshot ids.
      - The report records the written slots and values, and the runtime hashes of A7 and the verifier under test. Both
        hashes must equal the packet's expected values.
      - N1–N3 assert the specific revert reason, not merely "failed", so that a wrong slot cannot pass as a rejection.
        N4 asserts that `verify` returns false.
      - Re-run if the tag changes BLSAggregator or the verifier.
    - No real guardian key signs anything for this drill. Such a signature would also be valid on the real A7, so the owner
      could use it to start a real slash. The exported proof is rejected on the real chain: there the commitment is 0 and T has no code.
  - This pair runs with the packet's actual verifier creation code, on the fork engine (Amsterdam, a superset of
    osaka). DVT's conformance tests used SP's compile settings (cancun/prague, runs 500, no metadata hash), not the
    deployed bytecode (osaka, runs 200), so they do not cover it.
  - Verifier artifact archived by DSR:
    `DSR-Research-Flow/docs/report/aoa-closure-2026-10-31/dvt-verifier-72aca4fa/OverIssueFraudProofVerifier-72aca4fa.json`.
    Its hashes: sha256 `4d7e0125…e7d6`; creation keccak `0x73652062…e3ab`; keccak with the CBOR tail stripped `0x697b9779…8d54`.
  - The packet uses that creation code, or a real-submodule rebuild compared against it under the two-hash rule. The constructor arguments (A7, Registry) are appended by the builder.
- **Negative controls.**
  - missing DVT CI run binding or a failing job other than "Security Audit" (npm) rejected;
  - exhausted allowance (`L-used < Amax`), SP_RENEW set, price above P*, and a short full D budget each STOP; n is never reduced;
  - unpause before 6d rejected;
  - `configureOperator` before `setXPNTsFactory` rejected;
  - `applyBLSAggregator` before 24 h rejected;
  - `executeAPNTsTokenChange` before its ETA, or with `totalTrackedBalance ≠ protocolRevenue`, rejected;
  - the old aggregator cannot submit reputation after A9;
  - a non-owner Registry upgrade rejected;
  - `applyFraudProofVerifier` before 4 days rejected; a second direct call reverts `NoPendingVerifierRotation` (asserted);
  - B4 three ways:
    1. Applied manually first: B4 takes the placeholder branch, and D's later nonces are not shifted.
    2. Front-run after the read: the apply mines with status 0, but the post-state holds, so the run continues.
    3. The verifier was set to another address: STOP.
  - after Phase D, D can no longer call any owner function on the handed-over contracts.
- **The post-swap 0.1 buffer.** `withdrawProtocolRevenue` cannot take `protocolRevenue` below
  `PROTOCOL_REVENUE_BUFFER` (`SuperPaymasterAdmin.sol:274`). The swap requires `tracked == revenue ≤ 0.1e18` (`:200`).
  So after the swap the tracked total is exactly 0.1e18, and without B2a SP would hold 0 new token. That violates
  `invariant_solvency` (`SuperPaymasterFundConservation.invariant.t.sol:91`), and no later deposit or withdrawal closes
  the gap.
  - B2a pre-mints the backing.
  - The rehearsal reads `APNTsCapped.balanceOf(SP)` against `totalTrackedBalance` at three points: after 6d, after the
    first deposits, after the first revenue withdrawal. Equality is recorded as equality; any difference is explained
    by its source.
  - Negative control: 6d without B2a shows the solvency failure, and the executor refuses to build the packet.
- **The stranded old token.** The old token's 0.1e18 stays in SP permanently, untracked, with no withdrawal path (no
  recover/rescue function). §9's decision card states this.
- **On chain.** The G3 pilot checks handleOps admission at 480000 (DSR #4, D6).

## 8. What changes for the paper

- All contract versions are bound to one frozen tag, with the §2 release evidence. After the tag, `contracts/src` does not change.
- Multisig disclosure: both testnet signers were controlled by one operator.
- Registry, AOAProtocolRegistry and xPNTsFactoryV2 are governed by the same 48 h timelock. BLSAggregator and DVTValidator are Safe-only.
- Guardian-slash evidence is fork state construction plus source-level tests, not an on-chain end-to-end run. On A7's
  bytecode, the `verifyAndExecute` → commitment segment has no end-to-end drill. The paper does not claim that the
  fraud-proof path has been exercised on chain.
- A contract-design constraint, disclosed as an operational precondition: an aPNTs token swap cannot keep SP solvent by
  itself. The operator must pre-mint the 0.1e18 buffer in the new token (B2a). 5.5.0 is not changed. The G3 matrix and
  the paper record this, and the next contract version should fix it (noted in DESIGN.md).

## 9. Decision card for the go (filled in when the packet is built)

B2a (the 0.1 APNTsCapped pre-mint to SP) is listed on its own line, together with the stranded old-token 0.1. So is B4's
possible placeholder transaction: one empty self-transfer, costing gas only.

For each phase:
- the transactions in plain language, and who sends them;
- the on-chain state afterwards;
- whether and how each step can be undone (§6);
- the maximum cost;
- the main risks, and which guard stops a bad send;
- what changed since the previous go;
- who reviewed it;
- the timing.

Resolved by DSR 2026-11-02, Q4 fields (included with hash go, no separate author question):
- X name **AOA Research Points**, symbol **xARP**, communityName **AOA Research**, communityENS **""**, exchange rate **1e18**;
- treasury: test Safe **0x16dF788Ed4ed1fc384e52Dc832a6a6C3A23BdeBf**. It is only stored by
  `configureOperator` (`SuperPaymasterAdmin.sol:142`); settlement never reads or writes it (verified DSR source evidence);
- task recipient **0x000000000000000000000000000000000000dEaD**, one smallest T unit per identical transfer;
- **F1 fixture provenance:** record the exact source commit and artifacts for F1TestToken (separate T/Q instances)
  and F1Oracle. Their header says "local only"; DSR permits these controlled fixtures on Sepolia for this gas experiment,
  without changing source. Explain that scope difference explicitly; the local Anvil deployment recipe is not used.
- disclose baseline ownership by D, 1 ETH stakes each, 864000-second cache, no renewal, and the full D budget/shortfall check.

The first Phase C/D executor output on a real pin goes to DSR **before** asking the author for go.
The packet sha256 comes last, as the identifier.

### A7 evidence notes — DSR 2026-11-04 exit exemption

Old aggregator `0xeaec2f512ea50708211fa95533e4dbb60e3d2e5d` is
BLSAggregator-4.11.0, source `7c732e70`. The sole exempt guardian
`0xf36c9317765634e4995ce1e7210b5738225425b0` came from aastar-sdk #413,
commit `667b1bb2`, `tests/regression/onchain-evidence/dvt-onboard-e2e.ts:145`:
a one-shot key generated in memory and discarded. The notice has
`readyAt=1788933060`, `expiresAt=1789019460`.
Request tx: `0xe4737f3924f5488e1d037532dbae71b1f0efc91fa6544f92799e112402c82d38`;
committee syncExitNotice tx: `0xaad53b17a7a3d59ab0d171c7126a7d2341c82d54741c0f1ea04420d130425524`.
Only the guardian can cancel it, and the key is gone.
Even the A7 stage must supply `inputs.pop` validators to use this exemption;
missing inventory fails `old_exit_exempt_pop`. A7 does not yet require signed
PoP calldata, but later stages still enforce the full PoP schema and inventory.

The pin records guardian, readyAt, expiresAt, pin time and block hash, all 13
slot values, MAX_VALIDATORS, slash count and PoP exclusion, with ordered RPC
transcripts for both endpoints. Offline replay reruns the gates and binds the
result to the pin timestamp/hash and current input PoP inventory. Every pre-send
repeats the reads, including the full slot scan; advancing time/hash alone is
allowed. These offline controls are not a fresh live-chain observation.

Known residual: this guardian still holds Registry ROLE_DVT and a locked stake
forever (key gone). It has no governance authority over SP/Registry. The
exemption does not clear that role, unlock the stake, or cancel the notice.

Offline verification (run from the repository root; no commits or chain writes):
`A3A_ENGINE_DIR=$HOME/.foundry/bin python3 <suite>` uses cast 1.7.1
(`4072e487`); `env -u A3A_ENGINE_DIR python3 <suite>` uses the default
1.8.7-nightly (`4e8874b2`). The complete manifest reruns used unittest `-f`
(fail-fast); all 304 tests completed. Suite paths are `script/upgrade/` except
`script/a3a/test_a3a_exec.py`.

| Suite | Stable final summary | Nightly final summary |
| --- | --- | --- |
| `test_manifest_exec.py` | Ran 304 tests in 291.740s; OK (skipped=2) | Ran 304 tests in 316.905s; OK (skipped=2) |
| `test_old_owner_isolation.py` | Ran 56 tests in 17.252s; OK (skipped=2) | Ran 56 tests in 17.766s; OK (skipped=2) |
| `test_a3a_exec.py` | Ran 102 tests in 3.211s; OK | Ran 102 tests in 3.876s; OK |
| `test_sp_upgrade_exec.py` | Ran 141 tests in 1.434s; OK | Ran 141 tests in 1.842s; OK |
| `test_pop_adapter.py` | Ran 53 tests in 0.253s; OK | Ran 53 tests in 0.315s; OK |
| `test_release_evidence.py` | Ran 69 tests in 3.354s; OK | Ran 69 tests in 3.511s; OK |

The two skips are opt-in local-fork isolation controls requiring configured fork
RPC/pin inputs (also imported by the manifest suite), not exit-exemption tests.
All 13 dedicated exit tests passed under both engines. Literal AST replacement
of each named gate call with `pass` made its specific negative control RED;
restoration passed for all six: `old_exit_exempt_expired`,
`old_exit_exempt_slot`, `old_exit_exempt_slash`, `old_exit_exempt_listed`,
`old_exit_exempt_pop`, and `old_exit_max_validators`. Endpoint replay controls
exercise both transcripts; pre-send controls cover each of slots 1–13 and the
real `pre_send` call path. `git diff --check` passed.

### A7 evidence notes — DSR 2026-11-05 stale DVT proposals

The A7 dry-run on `e2e56562` (pin 12,064,139) stopped at `dvt_proposal_executed`.
DVTValidator `0x568b1486bfe036e603ea11f0d03dc47fa62c9e0e` had `nextProposalId = 10`
and `BLS_AGGREGATOR = 0xEaeC…2E5D` (the old aggregator). All nine proposals target
operator `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C`, level 1, reason
`credit-over-limit: debt 400e18 EXCEEDS limit 300e18`:

| ids | blocks | creators | executed | evidenceHash |
| --- | --- | --- | --- | --- |
| 1–6 | 11223327–11223331 (2026-07-07) | D, E, F, two each | 3 only | `0x6d1c0d602056be56edf7a5086903bc1a4b9dc082ca8a31df4c4e6ca3d77d5237` |
| 7–9 | 11228494–11228495 (2026-07-08) | D, E, F, one each | 7 only | `0x64357531834ff863e1207cea92dcf62db5ecf498d87cd629cb0e27e9d1247d79` |

They are duplicates left by DVT slash-consensus E2E runs: every validator proposed the
same evidence and one sibling executed (DVT #186 fixed the orphaning). DVTValidator has
no cancel or expiry path, and `markProposalExecuted` is aggregator-only, so they stay open.
DSR independently read the same values on two endpoints at the pin and at latest.

The getters `nextProposalId` and `proposals(1..9)` are the inventory; the log ids must
equal `1..9` exactly, so incomplete logs (even if both endpoints agree) STOP instead of
hiding a proposal. The exemption accepts an unexecuted proposal only if its id is listed,
its (operator, level, executed, exists, evidenceHash) equals the recorded tuple, and its
sibling (3 or 7) is executed with equal operator, level and evidenceHash; the unexecuted
set must be exactly the seven ids.
Gate-removal probes: `script/evidence/stale_proposal_probes.py` (mutates an in-memory copy only; each removal must turn its
control red by an assertion failure, not by an exception).

Known residual (also for the paper's disclosure):
- the seven proposals remain executable on-chain against `0xF7Bf…642C` (Jammy: guardian
  and test-Safe executor), level 1 each;
- executing one needs an active validator plus a BLS co-signature that meets the A7
  threshold. That is the same bar as creating **and executing** a fresh proposal
  (creation alone needs only an active validator, no BLS proof), so no capability is added;
- DVT reports that its nodes never execute them (master `830a544e` and the running
  containers: no enumeration of on-chain proposals, `executeWithProof` only for ids from
  the node's own round, audit execution disabled). DSR has not re-verified this.

