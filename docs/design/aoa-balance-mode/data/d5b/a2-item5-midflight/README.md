# A2 item 5 — C2 bundle-mid-flight tests, rc.1 ↔ rc.2 (CC-124 `a6097e85`)

> Requirement: `03-final-spec.md` L395 (§6 "rc1 门槛（A2）的 fork 演练范围" item 5) and §10.7b C2 (L654–664):
> freeze the rc1 runtime fixture; every rc(n+1) runs rc(n) → rc(n+1) bundle-mid-flight tests in BOTH
> directions (forward and rollback). DSR finding: the existing race tests use a 22,915 B fixture
> (`SuperPaymasterV55UpgradeRace`) and a `c30854f9` / 23,568 B fixture (`SuperPaymasterD5bUpgradeRace`),
> neither provably rc.1.
>
> Local Foundry evidence only. No transaction was sent to any network.

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
from the working tree). Owner = OZ TimelockController with an OPEN executor; canonical EntryPoint v0.7 bytecode
(codehash asserted). Bundle = [attacker op executing ONE matured timelock batch, guardian 4337-account op
(`setGlobalPaused` + `setOperatorPaused`, extension functions), victim 1, victim 2].

| Spec clause | Test | Batch executed mid-bundle | Expected (asserted) | Result |
|---|---|---|---|---|
| C2 forward: op0 upgrades rc(n) → rc(n+1) via timelock; ops validated by the old impl settle normally | `test_rc1_to_rc2_forward_mid_bundle` | `upgradeToAndCall(rc.2)`, `executeGasParams()`, `setProtocolFee(2000)` | rc.1 contexts = 384 B, fee bits 0 (probe). Under rc.2: 4/4 ops succeed, 0 `PostOpRevertReason`, 2 `TransactionSponsored`, 2 `LockSettled`; executions kept; gas at the **validation-time snapshot** (not the mid-bundle params); fee = **live 2000** (rc.2 legacy rule = what rc.1 charges); `usedOpHashes`, `inflightOf == (0,0)`, `lockedOf == 0`; operator Δ == revenue Δ == Σcharge == xPNTs burned | PASS |
| C2 rollback: op0 rolls back rc(n+1) → rc(n); ops validated by the new impl settle normally | `test_rc2_to_rc1_rollback_mid_bundle` | `executeGasParams()`, `setProtocolFee(2000)`, `upgradeToAndCall(rc.1)` (guardian pauses first, through rc.2) | rc.2 contexts = 384 B, fee bits = 1001 (probe). Under rc.1: same bundle-level, lock, in-flight and conservation assertions; gas at the snapshot; fee = **live 2000** (rc.1 ignores bits ≥ 128) | PASS |
| control (fee assertion discriminates) | `test_control_rc2_stays_chargesSnapshotFee` | same, no upgrade, stays rc.2 | fee = **snapshot 1000** | PASS |
| control (forward reproduces rc.1's own rule) | `test_control_rc1_stays_chargesLiveFee` | same, no upgrade, stays rc.1 | fee = live 2000 | PASS |

Verbatim (`results/rc1rc2-cancun.log`; `results/rc1rc2-prague.log` identical results, 0 skipped):

```
Ran 4 tests for contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol:SuperPaymasterRc1Rc2MidBundleTest
[PASS] test_control_rc1_stays_chargesLiveFee() (gas: 31023645)
[PASS] test_control_rc2_stays_chargesSnapshotFee() (gas: 31023897)
[PASS] test_rc1_to_rc2_forward_mid_bundle() (gas: 31259487)
[PASS] test_rc2_to_rc1_rollback_mid_bundle() (gas: 31259466)
```

Regression (`results/related-{cancun,prague}.log`, `--match-contract 'UpgradeRace|FeeSnapshot|Rc1Rc2MidBundle'`):
4 suites, **16 passed / 0 failed / 0 skipped** on both Cancun and Prague (V55UpgradeRace 2, D5bUpgradeRace 2,
FeeSnapshot 8, Rc1Rc2MidBundle 4).

## 4. Negative controls (`run-negative-controls.sh` → `results/negative-controls.txt`, `results/neg-*.log`)

Each mutant changes one line of the test; the test file is restored and its sha256 re-checked.

| Mutant | Must fail with | Result |
|---|---|---|
| N1 forward expects the snapshot fee (1000) | `charged at the expected protocol fee` | RED |
| N2 rollback expects the snapshot fee (1000) | `charged at the expected protocol fee` | RED |
| N3 rc.2 bytes loaded as rc.1 | `fixture identity` | RED |
| N4 old `c30854f9` fixture loaded as rc.1 | `fixture identity` | RED |
| N5 forward batch without `executeGasParams` | `gas params changed mid-bundle` | RED |

## 5. Reproduce

```
bash docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/run-tests.sh              # results/*.log
bash docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/run-negative-controls.sh  # results/neg-*
python3 docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/build-hashes.py rc.1=<out> rc.2=<out> ...
shasum -a 256 -c docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/EVIDENCE.sha256   # from the repo root
```

## 6. Limits / gaps

- **rc.1 is not on chain** and has no attestation; the spec's "check the rc1 fixture against the on-chain runtime
  codehash after A3b" cannot be done for it. Its identity here rests on two local builds from the tag (identical)
  plus the same pipeline reproducing the rc.2 attestation byte-for-byte. rc.1 is VOID per the rc.2 attestation;
  whether "previous release" for C2 should be rc.1 at all (vs. the 5.4.2 live impl → rc.2) is a DSR call.
- Local Foundry (EntryPoint v0.7 bytecode etched), not a fork rehearsal; no bundler; balance mode (`settleLocked`)
  only — the credit path (`settleCredit`) is not exercised mid-bundle in either direction.
- The gas-snapshot assertion is a bound (W ≤ G + bufSnap, ≥ G + bufSnap − 250k gwei; precondition bufNew > bufSnap +
  200k gwei), as in `SuperPaymasterD5bUpgradeRace`; N5 only shows the mid-bundle parameter change is required by
  the precondition, it does not mutate the bound itself.
- Submodule sources were copied from the main checkout at the recorded gitlink commits (HEAD checked, worktree
  status not independently verified); SP's dependency closure uses only `AggregatorV3Interface.sol` from them.
