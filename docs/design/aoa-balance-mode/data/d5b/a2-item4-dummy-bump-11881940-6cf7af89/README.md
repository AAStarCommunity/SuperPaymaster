# A2 item 4: real changed-runtime upgrade drill (rc.2 → rc1′ TEST dummy → rc.2), fork block 11881940, script commit 6cf7af89

**Supersedes** `../a2-item4-dummy-bump-11881530-fb507e36/` (left unchanged as written). Codex review of
#462 found two Mediums in that run's script:
- M1: the dummy artifact was never bound to the committed source.
- M2: a failed `cast storage` read was swallowed inside `echo`, so two equally failed slot dumps would compare "identical".

Both are fixed in `6cf7af89`. This directory is a fresh run of that commit, started from scratch. Nothing from earlier runs is reused.

**Run**: ONE uninterrupted `all` run of `script/evidence/a2-full-rehearsal.sh` at commit
`6cf7af89d01cdff4efc4851f0b53e89fc01ca1b9`. The tree was clean: `rehearsal.log` L2 prints no "+ uncommitted
changes". The fork was taken from Sepolia block **11881940** (hash `0x1b708b2e…951a9a1d`, L44) on a LOCAL anvil at
127.0.0.1:28631. Logged UTC 03:54Z → 04:02Z on 2026-10-10; exit code 0.

Result: **`RUN COMPLETED WITH 0 FAILURES (all)`**, with 353 `CHECK … PASS`, 0 `CHECK … FAIL` and 0 `!!!` lines (L1081–L1082).
**63 negative controls, 63/63 PASS**, split by match kind:
- **55 byte-exact revert-data matches**: selector + arguments, compared byte for byte.
- **8 offline regex refusals**: tooling or script guards that send no transaction, matched by a regex over their output.

Stage D alone (new): 93 CHECK PASS and 20 negative controls (NEG-44…NEG-63 = 15 exact revert data + 5 offline regex refusals). It sent 16 fork transactions.

Nothing was broadcast to any public network. The public RPC was used only as `anvil --fork-url` and for
read-only pre-state reads. RPC URLs and keys are not in any file here. A scan for the env file's 9 key/URL values found 0 hits in this directory; positive control: all 9/9 are found in the env file itself.

`contracts/src` is byte-identical to v5.5.0-rc.2 (peeled `1ac0e1c595dc84e684b540ca6a936168e922194f`, L3).
The local `profile.default` build reproduces every attested artifact (L6–L17).

This run responds to DSR CC-124 (a6097e85 / e96d0111), A2 item 4. It is stacked on #459 (`d5c-2/a2-full-rehearsal`). Stages 0, I and II
are the #459 script, re-run here; they build the post-A2 governance state that stage D needs.

## Why this run exists

Spec `docs/design/aoa-balance-mode/03-final-spec.md` **L394** (rc1 gate, item 4, §10.7b C):

> 感知 timelock 的升级流程：rc1 → rc1′（只改一个无害常量的 dummy bump）经 timelock 升级：部署 impl →
> `schedule(upgradeToAndCall)` → 48h → `execute` → 读回 `version()` 与实现槽。

The #459 C drill re-deployed the SAME rc.2 bytecode at a new address. That proves the timelock ROUTE only:
the implementation slot moves, but the code does not. Here the SP proxy is upgraded to a runtime that actually
differs from rc.2, and is then rolled back.

## The TEST artifact (not a release artifact)

| item | value |
|---|---|
| source | `contracts/test/upgrade-drill/SuperPaymasterA2DrillDummyBump.sol` (copy: `D-dummy-source.SuperPaymasterA2DrillDummyBump.sol`) |
| source sha256 | `516a20a473ddc622fce101d7ffd23a4eb7e5cbb25e0fde0e2db19a53c1a9a66c` |
| what changes vs rc.2 | `contract SuperPaymasterA2DrillDummyBump is SuperPaymaster`. Overrides ONLY `version()`, which now returns `"SuperPaymaster-5.5.0-A2DRILL-DUMMY-NOT-A-RELEASE"`. Declares no state variable. The constructor forwards the same three immutables, so `EXTENSION` is a fresh rc.2 `SuperPaymasterAdmin` |
| compiler | solc 0.8.33, cancun, 500 runs, via_ir, bytecodeHash none (L797) |
| runtime | 13,782 B (rc.2 SP: 13,744 B), keccak `0xcb760244e1416530f8845e0651cb4efb90d0853a514d458db0614d4fa6e803d0` (`D-dummy-artifact.runtime.hex`) |
| creation keccak | `0xd105ba35a8a023675a8505e5c809a5c54778ff5f5029f66e21e1f7de0f9ce547` (`D-dummy-artifact.creation.hex`) |
| rc.2 attested SP runtime keccak | `0xc9fe37f57b2bf4de56d8c87270660ce4a098692280ed642855c0a603d6b9d222` (the local build matches it, L798) |
| full record | `D-dummy-artifact.json` |

**Provenance (Codex M1 fix; L801–L805, `D0-dummy-provenance.log`, `D0-dummy-fresh-build.log`).** The checks run before the dummy is deployed; a mismatch stops the run.
- **(a) Sources match the checkout.** The artifact's compiler metadata records 35 sources: the dummy, `SuperPaymaster.sol` and every transitive import. For each one, the recorded `keccak256` equals keccak256 of the file in the checkout (35/35).
- **(b) Target and settings.** `compilationTarget` is the dummy, and the settings are the release settings.
- **(c) Fresh rebuild.** The dummy is recompiled in this run into isolated `cache/` dirs (35 files). Its runtime and creation bytecode are byte-identical to the deployed artifact.

Negative controls (offline):
- NEG-44: a stale artifact whose recorded dummy source differs (the metadata keccak of the source with "extra logic" appended) is refused with `PROVENANCE MISMATCH: source keccak: …`.
- NEG-45: a stale artifact whose runtime differs by one byte is refused with `PROVENANCE MISMATCH: runtime != fresh rebuild`.

Other separations from the release path:
- The dummy lives under `contracts/test/` and is not listed in `docs/release/*-attestation.json`.
- The RELEASE upgrade tool refuses it (NEG-48: `DefaultArtifacts: SuperPaymaster runtime != profile.default artifact`).
- The check that the deployed code matches the artifact uses a TEST-ONLY attestation generated here (`D-dummy-TEST-ONLY-attestation.json`).

**Storage-layout compatibility (L806–L810).** The compiler `storageLayout` of the dummy is identical to rc.2 SuperPaymaster's.
- Compared: every entry's label, slot and offset, plus its type expanded recursively (members, key/value, base, encoding, size).
- Ignored: solc's `contract` attribution and per-compilation astIds.
- Comparator controls: SP vs Registry gives DIFFERENT; one mutated member offset gives DIFFERENT; self vs self gives IDENTICAL.
- Layout dumps: `D-dummy-storage-layout.json` and `D-rc2-storage-layout.json` (42 entries; the last occupied slot, including `__gap`, is 64).

**Raw slot snapshots (Codex M2 fix).** `dump_slots` now checks every read: the block number and each `cast storage` call.
- On a failed read it writes `READ-FAILED`, returns 1, and the run fails.
- Every snapshot must consist of exactly **67** lines `slot <id> 0x<64 hex>`: slots 0..64, plus the Initializable and Ownable2Step ERC-7201 slots. The four D5/D6 snapshots pass this check at L918, L928, L1002 and L1012.

Controls:
- NEG-46: an injected read failure on slot 5 (`cast` shadowed for that one call) makes `dump_slots` return failure (`READ-FAILED slot 5`). Its snapshot is rejected as `INVALID(66 valid words, 1 bad lines)` (L812). The injection is scoped: afterwards `cast` is the binary again (L813).
- NEG-47: a dead RPC returns failure, and its snapshot is rejected (L815).
- A healthy snapshot is accepted (L816).
- A snapshot with one empty word, the old swallowed-error shape `slot 4 `, is rejected (L817).

## Matrix: L394 → step → log line (`rehearsal.log`)

| L394 element | stage D step | key lines | result |
|---|---|---|---|
| rc1′ = harmless-constant dummy bump | D0 build provenance, fresh rebuild, layout, slot-dump guards | L795–L817 | PASS |
| 部署 impl | D1 deploy (deployer EOA; constructor = live proxy immutables) | TX L822, version L825, deployed == artifact L835, extension == rc.2 Admin L840, core != rc.2 L841; NEG-48 | PASS |
| pre-state | D2: snapshot, impl is rc.2, validate-probe positive control | L851–L862 | PASS |
| (only the timelock can upgrade) | D3: NEG-49…NEG-54 | L863–L873 | PASS |
| `schedule(upgradeToAndCall)` | D4: Safe 2-of-3 execTransaction → TL.schedule | TX L888; getTimestamp == ts+172800 at L897 | PASS |
| (early execute reverts) | D4: NEG-55/56 right after scheduling, NEG-57/58 about 800 s before readiness; impl unchanged | L898–L912 | PASS |
| 48h | warp 172000 + 800 s, then `isOperationReady`; NEG-59 (EOA execute) | L904, L913, L915 | PASS |
| `execute` | D5: Safe → TL.execute; `Upgraded(dummy)` event | TX L924, L929 | PASS |
| 读回实现槽 | ERC-1967 slot == dummy, changed vs rc.2 | L933–L934 | PASS |
| 读回 `version()` | via proxy == dummy string | L936 | PASS |
| runtime codehash changed | impl codehash == dummy (L938), changed (L939), != rc.2 attestation (L943) | | PASS |
| state preserved | snapshots well-formed (L918, L928); getters identical (L953); raw slots identical (L955); owner / pendingOwner / guardian (L947, L949, L951) | | PASS |
| still functional | validate probe on the dummy, sigFail 0 (L959); NEG-60 | | PASS |
| rollback | D6: schedule (release printer accepts rc.2) → NEG-61/62 early execute → 48h → NEG-63 → execute | L961–L1012 | PASS |
| rollback read-backs | impl slot == rc.2 (L1017); version 5.5.0 (L1019); codehash == original (L1021); rc.2 attestation MATCH (L1025); EXTENSION == original (L1027); snapshots well-formed (L1002, L1012); getters and raw slots identical (L1033–L1034); probe sigFail 0 (L1038) | | PASS |

## Read-backs before / after

| | before (rc.2) | after D5 (dummy) | after D6 (rollback) |
|---|---|---|---|
| ERC-1967 impl | `0x3a69c08a310bb62befdd03048c6ec64235772e5b` | `0x90F740A94f8f7f441c1dD0C55FE2e11597E27ff6` | `0x3a69c08a310bb62befdd03048c6ec64235772e5b` |
| `version()` via proxy | `SuperPaymaster-5.5.0` | `SuperPaymaster-5.5.0-A2DRILL-DUMMY-NOT-A-RELEASE` | `SuperPaymaster-5.5.0` |
| impl runtime codehash (raw) | `0x855c0e80217be18958cecb20582584966412ae98b5e357cd7e109dd37219dfbf` | `0xea5051d205a52644cad65acea4e19bc311fd22b6e97ddcd123ab4a574e985d79` | `0x855c0e80…19dfbf` |
| vs rc.2 attestation (masked) | MATCH | MISMATCH (expected) | MATCH |
| `EXTENSION` | `0xA497F738446fD823e15198bFa8157E6Aa50677C0` | `0x35e905E6730e94850725724E1F7C6Bcb3690Cc64` (rc.2 Admin code) | `0xA497F738…0677C0` |
| owner / pendingOwner / guardian | TL `0x11Cc8878…5D7c` / 0 / Safe | unchanged | unchanged |
| block | 11882066 | 11882078 | 11882088 |

## Stage D negative controls

Match kind **exact** means the first revert `data` field equals the expected ABI-encoded error byte for byte.
**offline regex** means a script or tooling guard that sends no transaction, matched by a regex over its output.
Full expected/actual values are in `neg-controls.jsonl`, and the full outputs in `neg.log`.

| id | kind | control | expected |
|---|---|---|---|
| NEG-44 | offline regex | stale artifact: recorded dummy source != checkout | `PROVENANCE MISMATCH: source keccak: contracts/test/upgrade-drill/…` |
| NEG-45 | offline regex | stale artifact: runtime differs by 1 byte from the fresh rebuild | `PROVENANCE MISMATCH: runtime != fresh rebuild` |
| NEG-46 | offline regex | `dump_slots` with an injected read failure on slot 5 | `READ-FAILED slot 5` |
| NEG-47 | offline regex | `dump_slots` against a dead RPC | `READ-FAILED block number` |
| NEG-48 | offline regex | release tool `UpgradeViaTimelock schedule-upgrade` with the dummy | `DefaultArtifacts: SuperPaymaster runtime != profile.default artifact` |
| NEG-49 | exact | old EOA owner `SP.upgradeToAndCall(dummy)` | `OwnableUnauthorizedAccount(0xb560…df0E)` |
| NEG-50 | exact | Safe (guardian) `SP.upgradeToAndCall(dummy)`, inner call replayed | `OwnableUnauthorizedAccount(Safe)` |
| NEG-51 | exact | same, through Safe execTransaction | `Error("GS013")` |
| NEG-52 | exact | deployer EOA `TL.schedule` directly | `AccessControlUnauthorizedAccount(EOA, PROPOSER_ROLE)` |
| NEG-53 | exact | Safe owner EOA `TL.schedule` directly | `AccessControlUnauthorizedAccount(O1, PROPOSER_ROLE)` |
| NEG-54 | exact | schedule with delay 172799 (eth_call from the Safe) | `TimelockInsufficientDelay(172799, 172800)` |
| NEG-55 | exact | Safe execute immediately after schedule, inner call | `TimelockUnexpectedOperationState(id, 1<<Ready)` |
| NEG-56 | exact | same, Safe exec | `Error("GS013")` |
| NEG-57 | exact | Safe execute ~800 s before readiness, inner call | `TimelockUnexpectedOperationState(id, 1<<Ready)` |
| NEG-58 | exact | same, Safe exec | `Error("GS013")` |
| NEG-59 | exact | deployer EOA `TL.execute` after 48h | `AccessControlUnauthorizedAccount(EOA, EXECUTOR_ROLE)` |
| NEG-60 | exact | old EOA owner upgrades the dummy back directly | `OwnableUnauthorizedAccount(EOA)` |
| NEG-61 | exact | Safe execute rollback before 48h, inner call | `TimelockUnexpectedOperationState(rollbackId, 1<<Ready)` |
| NEG-62 | exact | same, Safe exec | `Error("GS013")` |
| NEG-63 | exact | deployer EOA execute rollback after 48h | `AccessControlUnauthorizedAccount(EOA, EXECUTOR_ROLE)` |

## Rest of the run (stages 0, I and II: the #459 script)

This part has the same coverage as the #459 archive, re-run on this fork: 260 CHECK PASS and NEG-1…NEG-43.
Those 43 split into 40 exact revert-data matches and 3 offline regex refusals: NEG-13, NEG-21 and NEG-24, where `UpgradeViaTimelock` refuses to run without a roles attestation.

The fork tx ledger (`fork-tx-ledger.jsonl`) covers 151 blocks and 120 txs. It shows:
- no tx from the Safe address;
- Safe txs only from the owner EOAs O1/O2;
- no mined revert;
- no direct tx to the timelock.

Final state after the rollback: every deployed runtime == rc.2 attestation (`codehash-final.log`).

## Not covered / out of scope

* **Registry dummy bump: out of scope by DSR ruling.** CC-124 e96d0111 rules that spec item 4 (L394) is the SP rc1 → rc1′ upgrade only. Registry's timelock upgrade route stays exercised with the same rc.2 bytecode (stage II / C).
* L395 C2 bundle-midway test (rc(n) → rc(n+1) inside one bundle) is a separate item and is not in this run.
* The dummy changes only a `pure` string. It does not exercise a forward upgrade whose logic changes, such as the OpCtx context-compatibility paths; that is C2's job.
* The same swallowed-read pattern (Codex M2) still exists in the #459 stage II / C slot dumps (`II-C-*-slots-*.txt`). They are outside this PR's stage D. They are guarded there by an explicit well-formedness CHECK (SP 65:65:1, Registry 74:74:1), which a failed read would fail.

## Post-hoc check of the archived run (script 6cf7af89)

**This archived run predates the getter-snapshot hardening.** Codex #462 round 2 found a gap in script `6cf7af89`:
- `sp_state` wrote each `cast call` result without checking its exit status.
- `state_ok` accepted any 24 lines containing " = " that had no error/revert.
- So a getter returning blank in BOTH snapshots would let the D5/D6 before/after diff say "identical".

Fixed in `85b62b385a91cb6f7e3f3e430faf1ba06bde1a9c`:
- Every getter now goes through `sp_getter`. A non-zero exit or an empty value writes `<getter> = FAILED`, and `sp_state` returns 1, which fails the run.
- `state_ok` requires EXACTLY 24 lines `<getter> = <non-empty>`, with no FAILED/error/revert, plus a block header.
- D0 now runs `state_neg_controls`.

To save time, no new `all` run was made. Instead, `script/evidence/a2-item4-state-guard-selftest.sh @ 85b62b38` loads the guard's function bodies verbatim from the committed `a2-full-rehearsal.sh`. Its output is in `posthoc-state-guard-85b62b38/` (`rehearsal.log`, `neg-controls.jsonl`, `neg.log`, `D0-state-guard-controls.log`, `console.log`).

**1. The negative controls** run on a short-lived local anvil fork of block 11881940. The live SP there is 5.4.2. The fork-only cheat that gives it a 5.5.0 surface: the rc.2 impl build is deployed on the fork and the proxy's ERC-1967 slot is pointed at it with `anvil_setStorageAt` (`rehearsal.log` L3).
- NEG-1: an injected EMPTY getter (operators(OWNER) exits 0 with a blank value) → `sp_state` fails with `FAILED operators(OWNER) @block …: empty value`. PASS (offline regex).
- NEG-2: an injected FAILED getter (exit 1) → `sp_state` fails with `FAILED operators(OWNER) @block …: Error: injected read failure`. PASS (offline regex).
- Both injected snapshots are rejected by `state_ok`; a healthy snapshot is accepted (L8–L10).
- Codex reproduction, operators(OWNER) blank in BOTH snapshots: each side is rejected as `INVALID(23 non-empty values, 1 bad lines)`, and the OLD rule is shown to accept it (L11–L13).

**2. The NEW `state_ok` applied to the 4 archived getter snapshots** (L15–L24):

| file | NEW state_ok | " = " lines | blank values | error/revert | block |
|---|---|---|---|---|---|
| `D5-state-before.txt` | valid | 24 | 0 | 0 | 11882076 |
| `D5-state-after.txt` | valid | 24 | 0 | 0 | 11882078 |
| `D6-state-before.txt` | valid | 24 | 0 | 0 | 11882086 |
| `D6-state-after.txt` | valid | 24 | 0 | 0 | 11882088 |

The D5 and D6 before/after getters are still identical. The self-test ends `SELFTEST COMPLETED WITH 0 FAILURES`: 13 CHECK PASS and 2/2 negative controls, both offline regex refusals.

This archive's own numbers above (353 CHECK, 63 negative controls) are those of the `6cf7af89` run and are unchanged. If DSR requires it, a fresh complete `all` run under the final script (`85b62b38` or later) can be made.

## Reproduce

```
forge build                      # profile.default
pnpm install
script/evidence/a2-full-rehearsal.sh <env file with RPC_URL> 11881940 <out dir> all
script/evidence/a2-item4-state-guard-selftest.sh <env file> 11881940 <this dir> <out dir>   # post-hoc guard check
cd docs/design/aoa-balance-mode/data/d5b/a2-item4-dummy-bump-11881940-6cf7af89 && shasum -a 256 -c EVIDENCE.sha256
```
