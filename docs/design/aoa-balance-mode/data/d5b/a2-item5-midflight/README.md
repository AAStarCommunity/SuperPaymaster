# A2 item 5 — C2 bundle-mid-flight tests, rc.1 ↔ rc.2 (CC-124 `a6097e85`)

> Requirement: `03-final-spec.md` L395 (§6 "rc1 门槛（A2）的 fork 演练范围" item 5) and §10.7b C2 (L654–664):
> freeze the rc1 runtime fixture; every rc(n+1) runs rc(n) → rc(n+1) bundle-mid-flight tests in BOTH
> directions (forward and rollback). DSR finding: the existing race tests use a 22,915 B fixture
> (`SuperPaymasterV55UpgradeRace`) and a `c30854f9` / 23,568 B fixture (`SuperPaymasterD5bUpgradeRace`),
> neither provably rc.1.
>
> DSR follow-up (CC-124 `e96d0111`): rc.1 is VOID and was never deployed, so it cannot be the "previous
> release" for A3b. The live proxy runs **SuperPaymaster-5.4.2**. §8 adds 5.4.2 → rc.2 FORWARD same-bundle
> evidence. A 5.4.2 rollback direction is deliberately absent (spec P2).
>
> Local Foundry evidence plus read-only Sepolia reads (`eth_getCode` / `eth_call` / `eth_getStorageAt`).
> No transaction was sent to any network.

## 1. What rc.1 and rc.2 are

| | Tag object | Commit | Status |
|---|---|---|---|
| rc.1 | `v5.5.0-rc.1` → `a37c67b13896e513063688d4230e0db1493cb7cc` | `7ae5b3400308082928da4c180b8e3108ed00b288` | Tagged; never deployed; **declared VOID** by the rc.2 attestation (`2d66867f` + PR #442 changed bytecode after it). No rc.1 attestation exists. |
| rc.2 | `v5.5.0-rc.2` → `250fb800b0162bd77c8d5067c1aef55371ef6584` | `1ac0e1c595dc84e684b540ca6a936168e922194f` | `docs/release/v5.5.0-rc.2-attestation.{md,json}` |

`git diff --quiet 7ae5b340 1ac0e1c5 -- contracts/src` → exit 1 (differs; 10 files, incl. SuperPaymaster.sol,
SuperPaymasterAdmin.sol, SuperPaymasterStorage.sol). `git diff --quiet 1ac0e1c5 origin/feat/aoa-balance-mode-5.5.0 -- contracts/src`
→ exit 0 (feat head contracts == rc.2).

SP settlement-relevant differences rc.1 → rc.2 (from the diff):
- rc.2 snapshots `protocolFeeBPS` into bits 128–255 of context word 12 as `fee + 1`; postOp charges the snapshot
  fee when present, else the live fee. rc.1 always charges the live fee and reads only uint32 slices below
  bit 128 of word 12.
- rc.2 rejects context lengths other than 352 / 384 (`InvalidContextLength`); both rcs emit 384 B.
- Admin: `executeEmergencyPrice` re-checks the emergency gates (not on the postOp path).

## 2. Fixture provenance (all rebuilt here, forge 1.7.1 `4072e487`, solc 0.8.33, profile.default)

Source trees: `git archive <ref>` + submodules `chainlink-brownie-contracts@6e324d8a`, `solady@90db92ce`
(the gitlinks at both tags). Full numbers: `build-hashes.json` (produced by `build-hashes.py`).

| Fixture (`contracts/test/fixtures/`) | Built from | Creation keccak | Core runtime B | Ext runtime B | Matches |
|---|---|---|---|---|---|
| `superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex` (new) | `v5.5.0-rc.1` full build; 2nd independent sparse build identical | `0x7afad5da…2483cc` | 13,571 | 19,208 | build == fixture (both builds) |
| `superpaymaster-5.5.0-rc.2-1ac0e1c5-impl.creation.hex` (new) | `v5.5.0-rc.2` full build | `0x4edff578…0a0e4e` | 13,744 | 19,214 | **== rc.2 attestation** (SP + Admin, runtime + creation keccak and size: 6/6) |
| `superpaymaster-5.5.0-impl.creation.hex` (existing) | `1cb21fe8` sparse build | `0xfb170a13…db12f3` | 22,915 | — | build == fixture; **not rc.1** |
| `superpaymaster-5.5.0-c30854f9-impl.creation.hex` (existing) | `c30854f9` sparse build | `0xd2a9e92e…9e05e5b` | 23,568 | — | build == fixture == `d5b-previous-release.provenance.json`; **not rc.1** |

Fixture provenance file: `contracts/test/fixtures/sp-5.5.0-rc1-rc2.PROVENANCE.md`.

## 3. Spec → test → result

Test: `contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol` (`SuperPaymasterRc1Rc2MidBundleTest`). Both
implementations are deployed from the fixtures (keccak asserted against the constants above; nothing compiled
from the working tree). Owner = OZ TimelockController with an OPEN executor and a 1-day delay; canonical
EntryPoint v0.7 bytecode (codehash asserted). Bundle = [attacker op executing ONE matured timelock batch,
guardian 4337-account op (`setGlobalPaused` + `setOperatorPaused`, extension functions), victim 1, victim 2].

**Gas parameters (Codex round 1, Medium 2).** Before the bundle the GOV-5 params are set to
VAL = (MIN 1,000,000, SETTLE 300,000, C_WRAP 50,000, C_POSTOP 1,000,000) and the victims are validated under
VAL (postOpGasLimit 1,000,000). The batch executes MID = the defaults (200,000 / 160,000 / 5,000 / 175,000).
So a postOp that uses the validation snapshot, the live params, or hard-coded defaults gives clearly different
buffers: bufSnap = 1,180,000 gwei vs bufLive = bufDefault = 310,000 gwei. In the bundle tests,
W − G must lie in [bufSnap − 350,000 gwei, bufSnap]. The precondition `bufLive + OVH < bufSnap − OVH`
makes that window disjoint from the live/default window. W is the charged gas in wei, aGas/1e5; G is
`UserOperationEvent.actualGasCost`; OVH = 350,000 gwei bounds postOp's own gas plus the 10% unused-gas penalty.
The **exact** tests skip the EntryPoint's accounting. They validate a victim, execute the same batch, call
`postOp` directly as the EntryPoint with `actualGasCost = 1e14`, `feePerGas = 1 gwei`, and assert `aGas` and
`charge` **exactly** under the spec rule. They also check that the live-param value differs.

| Spec clause | Test | Batch executed between validate and postOp | Expected (asserted) | Result |
|---|---|---|---|---|
| C2 forward: op0 upgrades rc(n) → rc(n+1) via timelock; ops validated by the old impl settle normally | `test_rc1_to_rc2_forward_mid_bundle` | `upgradeToAndCall(rc.2)`, `executeGasParams()` (VAL→MID), `setProtocolFee(2000)` | rc.1 contexts = 384 B, fee bits 0 (probe). Under rc.2: 4/4 ops succeed, 0 `PostOpRevertReason`, 2 `TransactionSponsored`, 2 `LockSettled`; executions kept; W − G within the **snapshot (VAL)** window; fee = **live 2000** (rc.2 legacy rule = what rc.1 charges); `usedOpHashes`, `inflightOf == (0,0)`, `lockedOf == 0`; operator Δ == revenue Δ == Σcharge == xPNTs burned | PASS |
| C2 rollback: op0 rolls back rc(n+1) → rc(n); ops validated by the new impl settle normally | `test_rc2_to_rc1_rollback_mid_bundle` | `executeGasParams()`, `setProtocolFee(2000)`, `upgradeToAndCall(rc.1)` (guardian pauses first, through rc.2) | rc.2 contexts = 384 B, fee bits = 1001 (probe). Under rc.1: same assertions; snapshot window; fee = **live 2000** (rc.1 ignores bits ≥ 128) | PASS |
| C2 forward, exact | `test_exact_forward_rc1ctx_settledByRc2` | same as forward (executed directly, open executor) | word 12 holds VAL C_POSTOP/C_WRAP, fee bits 0; `aGas == ceil((A + (1,050,000 + 130,000)·1 gwei)·price·1e18 / (10^dec·aPriceUSD))` exactly, ≠ the live-param value; `charge == ceil(aGas·1.2)` < a0; operator refund == a0 − charge; revenue == charge; lock and in-flight cleared | PASS |
| C2 rollback, exact | `test_exact_rollback_rc2ctx_settledByRc1` | same as rollback | the same checks, with fee bits 1001 in the context and the charge still at the live fee 2000 under rc.1 | PASS |
| control (fee assertion discriminates) | `test_control_rc2_stays_chargesSnapshotFee` | same, no upgrade, stays rc.2 | fee = **snapshot 1000**; snapshot gas window | PASS |
| control (forward reproduces rc.1's own rule) | `test_control_rc1_stays_chargesLiveFee` | same, no upgrade, stays rc.1 | fee = live 2000; snapshot gas window | PASS |

rc.1 and rc.2 apply the **same** gas-buffer rule (both read C_POSTOP/C_WRAP from word 12 of a 384-B
context); they differ only in the fee rule, which is asserted per direction above.

Verbatim (`results/rc1rc2-cancun.log`; `results/rc1rc2-prague.log` identical results, 0 skipped):

```
[PASS] test_control_rc1_stays_chargesLiveFee() (gas: 31130235)
[PASS] test_control_rc2_stays_chargesSnapshotFee() (gas: 31130486)
[PASS] test_exact_forward_rc1ctx_settledByRc2() (gas: 30540264)
[PASS] test_exact_rollback_rc2ctx_settledByRc1() (gas: 30540063)
[PASS] test_rc1_to_rc2_forward_mid_bundle() (gas: 31366107)
[PASS] test_rc2_to_rc1_rollback_mid_bundle() (gas: 31366074)
Suite result: ok. 6 passed; 0 failed; 0 skipped
```

Regression (`results/related-{cancun,prague}.log`, `--match-contract 'UpgradeRace|FeeSnapshot|Rc1Rc2MidBundle|V542ToRc2MidBundle'`):
5 suites, **20 passed / 0 failed / 0 skipped** on both Cancun and Prague (V55UpgradeRace 2, D5bUpgradeRace 2,
FeeSnapshot 8, Rc1Rc2MidBundle 6, V542ToRc2MidBundle 2).

## 4. Negative controls (`run-negative-controls.sh` → `results/negative-controls.txt`, `results/neg-*.log`)

Each mutant is a single sed substitution in the test. The test file is restored afterwards and its sha256 is
re-checked.

| Mutant | Must fail with | Result |
|---|---|---|
| N1 forward expects the snapshot fee (1000) | `charged at the expected protocol fee` | RED |
| N2 rollback expects the snapshot fee (1000) | `charged at the expected protocol fee` | RED |
| N3 rc.2 bytes loaded as rc.1 | `fixture identity` | RED |
| N4 old `c30854f9` fixture loaded as rc.1 | `fixture identity` | RED |
| N5 forward batch without `executeGasParams` | `gas params changed mid-bundle` | RED |
| N6 forward bundle expects the **live-param** buffer | `gas buffer` | RED |
| N7 rollback bundle expects the **live-param** buffer | `gas buffer` | RED |
| N8 exact forward expects the **live-param** aGas | `exact aGas under the validation-time gas snapshot` | RED |
| N9 exact rollback expects the **live-param** aGas | `exact aGas under the validation-time gas snapshot` | RED |
| N10 (5.4.2→rc.2) expects no `InvalidContextLength` rejection | `revert reason is PostOpReverted(InvalidContextLength())` | RED |
| N11 (5.4.2→rc.2) expects the operator's validation debit to be refunded | `operator lost the full validation debit` | RED |
| N12 (5.4.2 control) the control op actually upgrades | `precondition: still 5.4.2` | RED |

## 5. Fail-closed runners (Codex round 1, Medium 1)

`run-tests.sh` records every forge exit status. It also checks each log for `Suite result: ok` and the absence
of `FAIL`, and exits 1 if any run fails. `run-negative-controls.sh` exits 1 if any mutant is "MUTATION DID NOT
APPLY" or "NOT DETECTED", or if the restore check fails. `selftest-fail-closed.sh` proves both scripts this way
(logs in `results/selftest/`):

| Injection | Exit |
|---|---|
| S1 `run-tests.sh` with one control assertion broken | 1 |
| S2 `run-negative-controls.sh` with `INJECT=noapply` (mutant does not apply) | 1 |
| S3 `run-negative-controls.sh` with `INJECT=undetected` (comment-only mutant, suite stays green) | 1 |

All archived logs were regenerated from the committed test and scripts after the interruption. No partial-run
log is kept.

## 6. Reproduce

```
bash docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/run-tests.sh              # results/*.log
bash docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/run-negative-controls.sh  # results/neg-*
bash docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/selftest-fail-closed.sh   # results/selftest/
python3 docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/build-hashes.py rc.1=<out> rc.2=<out> ...
python3 docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/live-compare.py <v5.4.2 artifact> live-5.4.2/impl-code-publicnode-11882092.hex <5.4.2 fixture>
shasum -a 256 -c docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/EVIDENCE.sha256   # from the repo root
```

## 7. Limits / gaps

- **The timelock path is not proven here.** The race is built with a 1-day OPEN-executor TimelockController, so
  any 4337 op can execute the matured batch inside a bundle. These tests do **not** prove the production
  Safe-only executor / 48 h path. That path is covered by the fork rehearsal.
- **rc.1 is not on chain** and has no attestation. Its identity rests on two identical local builds from the
  tag, plus the same pipeline reproducing the rc.2 attestation byte-for-byte. DSR (CC-124 `e96d0111`) ruled
  rc.1 VOID, so it is not the "previous release" for A3b. That role belongs to the live 5.4.2 implementation
  (see §8).
- Local Foundry only (EntryPoint v0.7 bytecode etched): not a fork rehearsal and no bundler. Balance mode
  (`settleLocked`) only; the credit path (`settleCredit`) is not exercised mid-bundle in either direction.
- The bundle-level gas check is a window (W − G ∈ [bufSnap − OVH, bufSnap]) because G includes EntryPoint
  overhead. The exact per-wei check is the direct-postOp pair.
- Submodule sources were copied from the main checkout at the recorded gitlink commits. HEAD was checked; the
  worktree status was not independently verified. SP's dependency closure uses only `AggregatorV3Interface.sol`
  from them.

## 8. 5.4.2 (live) → rc.2 FORWARD, same bundle (DSR CC-124 `e96d0111`)

**Fixture.** `contracts/test/fixtures/superpaymaster-5.4.2-78364b12-impl.creation.hex` is built from tag `v5.4.2`
(tag object `e1ddf9dd…`, commit `78364b12f42f1d3043ae992472ab6bdb6de82377`) with the same method as above. Its
creation keccak is `0x1650ed80…f88033` (24,291 B), and the runtime is 23,569 B. **The live comparison matches.**
The Sepolia proxy `0x09DF…4DE9` has ERC-1967 impl `0xe25f88dbeafc64200270a948df8e9dd2f9b22c27`, whose `version()`
is `SuperPaymaster-5.4.2`. Its code was read at block 11,882,092 from publicnode and 1rpc, and the two reads are
byte-identical. The on-chain codehash is `0x63a66dc0…435135`. After zeroing the 4 immutable ranges, that code is
**byte-identical** to the artifact runtime (`0xdd83d0f7…afd20b`). Negative control: the `c30854f9` artifact is
not equal (`live-5.4.2/`, `fetch.txt`). This verifies 5.4.2 against the chain. rc.1 could never be verified this way.

**What happens, from the sources.**
1. 5.4.2 `validatePaymasterUserOp` debits the operator optimistically: `aPNTsBalance -= a0`,
   `protocolRevenue += a0`. It then returns a **160-byte** context, `abi.encode(token, user, a0, opHash, operator)`.
2. rc.2 `postOp` accepts only 352 or 384 bytes, so it reverts with `InvalidContextLength()`.
3. EntryPoint v0.7 reports `PostOpReverted(InvalidContextLength())` via `PostOpRevertReason`, reverts
   `innerHandleOp`, and rolls back the user's execution. It charges the paymaster's EntryPoint deposit for the
   gas and does not call postOp again.

**Result: this is a failure mode, not a pass.** Each in-flight 5.4.2 op is lost. The user's call does not
happen and the user is not charged. SP's ETH deposit pays the gas. The operator's validation debit `a0` is
**never refunded** and stays in `protocolRevenue`. No user debt is recorded.

The spec does not rely on this path being safe. 03 §10.7b C2 (last bullet) says the 5.4.2 → 5.5.0 upgrade is a
separate EOA transaction, so no bundle can straddle it. The live owner `0xb560…df0E` is an EOA
(`eth_getCode` = `0x` at block 11,882,092). Runbook step 3 also pauses all operators and waits for the mempool to
drain before step 5. In this test the owner is made a 4337 account only to **construct** the window.

| Test (`SuperPaymasterV542ToRc2MidBundle.t.sol`) | Bundle | Asserted | Result |
|---|---|---|---|
| `test_v542_to_rc2_forward_mid_bundle_inflightOpsFail` | [owner op `upgradeToAndCall(rc.2)`, victim 1, victim 2], victims validated by 5.4.2 | probe: 5.4.2 context = 160 B, a0 > 0; impl == rc.2 after the bundle; upgrade op succeeded; `PostOpRevertReason` ×2, each `PostOpReverted(InvalidContextLength())`; victims' `success == false`, executions rolled back; 0 `TransactionSponsored`; operator Δ = −2·a0 (no refund); revenue Δ = +2·a0; user xPNTs unchanged, debt 0; SP EntryPoint deposit Δ = −(G1 + G2) | PASS |
| `test_control_v542_stays_settlesNormally` | same, owner op calls `version()` (no upgrade) | still 5.4.2; 0 postOp reverts; both victims succeed and executions kept; `TransactionSponsored` ×2; Σcharge < 2·a0 (refund); operator Δ == revenue Δ == Σcharge == xPNTs burned | PASS |

Negative controls N10–N12 are in §4. The 5.4.2 token is a minimal stub (`V542Token`) that implements exactly
the five `IxPNTsToken` calls 5.4.2 makes, at rate 1:1. The real 5.4.2-era xPNTs token is not used, which does
not matter here because postOp never reaches it in the upgrade case.

Verbatim (`results/v542rc2-cancun.log`; Prague identical):

```
[PASS] test_control_v542_stays_settlesNormally() (gas: 14700525)
[PASS] test_v542_to_rc2_forward_mid_bundle_inflightOpsFail() (gas: 14694258)
Suite result: ok. 2 passed; 0 failed; 0 skipped
```

**Consequence for A3b.** Rc.2 cannot settle a 5.4.2 op validated in the same bundle as the upgrade.
Forward compatibility from 5.4.2 therefore rests on the operational controls: pause operators, drain the
mempool, then upgrade in a separate EOA transaction (no in-bundle owner). It does not rest on context
compatibility. Making it safe in code would need rc.2 to accept 160-B contexts, which would be a `contracts/src`
change and is out of scope here.
