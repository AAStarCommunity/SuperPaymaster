# A2 item 4 — REAL changed-runtime upgrade drill (rc.2 → rc1′ TEST dummy → rc.2) — fork block 11881530, script commit fb507e36

**Run**: ONE uninterrupted `all` run of `script/evidence/a2-full-rehearsal.sh` at commit
`fb507e36367287f2746c99dc914be2072814a233` (clean tree: `rehearsal.log` L2 prints no "+ uncommitted
changes"), forked from Sepolia block **11881530** (hash `0xb9766fcc…49e37dc`, L44) on a LOCAL anvil
(127.0.0.1:28631). 2026-10-10 ~02:28Z → 02:47Z, exit code 0. Result: **`RUN COMPLETED WITH 0 FAILURES (all)`**
— 343 `CHECK … PASS`, 0 `CHECK … FAIL`, 0 `!!!` lines (L1065–L1066); **59 negative controls, 59/59
matched their exact expected revert data** (`neg-controls.jsonl`). The new stage D alone: 83 CHECK PASS,
16 negative controls (NEG-44 … NEG-59), 16 fork txs.

Nothing was broadcast to any public network: the public RPC was used only as `anvil --fork-url` and for
read-only pre-state reads. RPC URLs and keys are not in any file here (scan of the 9 key/URL values of the
env file: 0 hits in this directory; positive control: 9/9 found in the env file itself).
`contracts/src` is byte-identical to v5.5.0-rc.2 (peeled `1ac0e1c595dc84e684b540ca6a936168e922194f`, L3)
and the local `profile.default` build reproduces all attested artifacts (L6–L17).

Responds to DSR CC-124 (a6097e85), A2 item 4. Stacked on #459 (`d5c-2/a2-full-rehearsal`): stages 0 / I /
II are the #459 script unchanged and re-run here from scratch (they build the post-A2 governance state stage
D needs); only stage D and the test artifact are new.

## Why this run exists

Spec `docs/design/aoa-balance-mode/03-final-spec.md` **L394** (rc1 gate, item 4, §10.7b C):

> 感知 timelock 的升级流程：rc1 → rc1′（只改一个无害常量的 dummy bump）经 timelock 升级：部署 impl →
> `schedule(upgradeToAndCall)` → 48h → `execute` → 读回 `version()` 与实现槽。

The #459 archive (`fork-rehearsal-a2-full-11877936-0c21a8fe`, stage II / C) re-deployed the SAME rc.2
bytecode at a new address, which proves the timelock ROUTE only (the implementation slot moves, the code
does not). Here the proxy is upgraded to a runtime that actually differs from rc.2, then rolled back.

L394 names rc1 → rc1′, i.e. the SuperPaymaster release artifact; this drill therefore upgrades the **SP
proxy**. The Registry proxy is not upgraded to a dummy (its timelock routing is covered by stage II / C,
L515–L649, same bytecode); see "Not covered".

## The TEST artifact (not a release artifact)

| item | value |
|---|---|
| source | `contracts/test/upgrade-drill/SuperPaymasterA2DrillDummyBump.sol` (copy: `D-dummy-source.SuperPaymasterA2DrillDummyBump.sol`) |
| source sha256 | `516a20a473ddc622fce101d7ffd23a4eb7e5cbb25e0fde0e2db19a53c1a9a66c` |
| what changes vs rc.2 | `contract SuperPaymasterA2DrillDummyBump is SuperPaymaster` overriding ONLY `version()` → `"SuperPaymaster-5.5.0-A2DRILL-DUMMY-NOT-A-RELEASE"`; no state variable; constructor forwards the same three immutables (so `EXTENSION` is a fresh rc.2 `SuperPaymasterAdmin`) |
| compiler | solc 0.8.33, cancun, 500 runs, via_ir (profile.default; L797) |
| runtime | 13,782 B (rc.2 SuperPaymaster: 13,744 B), keccak `0xcb760244e1416530f8845e0651cb4efb90d0853a514d458db0614d4fa6e803d0` (`D-dummy-artifact.runtime.hex`) |
| creation keccak | `0xd105ba35a8a023675a8505e5c809a5c54778ff5f5029f66e21e1f7de0f9ce547` (`D-dummy-artifact.creation.hex`) |
| rc.2 attested SP runtime keccak | `0xc9fe37f57b2bf4de56d8c87270660ce4a098692280ed642855c0a603d6b9d222` (local build matches it, L798) |
| full record | `D-dummy-artifact.json` |

It is labelled TEST ARTIFACT in its NatSpec, its version string and every log line; it lives under
`contracts/test/`, is not listed in `docs/release/*-attestation.json`, and the RELEASE upgrade tool refuses
it (NEG-44: `UpgradeViaTimelock schedule-upgrade` → `DefaultArtifacts: SuperPaymaster runtime !=
profile.default artifact`). Its own deployed-vs-artifact check uses a TEST-ONLY attestation file generated
into this directory (`D-dummy-TEST-ONLY-attestation.json`), never under `docs/release/`.

**Storage-layout compatibility** (L801–L804): the compiler `storageLayout` of the dummy equals rc.2
SuperPaymaster's — every entry's label/slot/offset and its type expanded recursively (struct members,
mapping key/value, array base, encoding, numberOfBytes); dumps in `D-dummy-storage-layout.json` /
`D-rc2-storage-layout.json` (42 entries, last occupied slot incl. `__gap` = 64). Not compared: solc's
`contract` attribution and astId / raw type ids (per-compilation AST ids — a trial run that compared raw
JSON failed exactly there, because forge script had recompiled SuperPaymaster mid-run; fixed in fb507e36).
Comparator controls: SP vs Registry → DIFFERENT; rc.2 layout with one struct-member offset mutated →
DIFFERENT; rc.2 vs itself → IDENTICAL. On chain, the raw proxy storage (slots 0..64 + the Initializable and
Ownable2Step ERC-7201 slots) is byte-identical across both upgrades (L941, L1018).

## Matrix: L394 → step → log line (`rehearsal.log`)

| L394 element | stage D step | key lines | result |
|---|---|---|---|
| rc1′ = harmless-constant dummy bump | D0 build provenance + layout | L795–L805 | PASS |
| 部署 impl | D1 deploy (deployer EOA, constructor = live proxy immutables) | TX L810, impl L811, version L813, deployed == artifact L823, extension == rc.2 Admin L828, core != rc.2 L829 | PASS |
| (release tool rejects test bytes) | D1 NEG-44 | `neg-controls.jsonl` | PASS |
| pre-state | D2 snapshot, impl is rc.2, validate probe positive control | L842–L850 | PASS |
| (only the timelock can upgrade) | D3 NEG-45…NEG-50 | L851–L861 | PASS |
| `schedule(upgradeToAndCall)` | D4 Safe 2-of-3 execTransaction → TL.schedule | TX L876, getTimestamp == ts+172800 L885 | PASS |
| (early execute reverts) | D4 NEG-51/52 immediately, NEG-53/54 ~800 s before readiness, impl unchanged | L886–L900 | PASS |
| 48h | warp 172000 + 800 → `isOperationReady` | L892, L901, L903; NEG-55 EOA execute | PASS |
| `execute` | D5 Safe → TL.execute, `Upgraded(dummy)` event | TX L911, L915 | PASS |
| 读回实现槽 | ERC-1967 slot == dummy, changed vs rc.2 | L919–L920 | PASS |
| 读回 `version()` | via proxy == dummy string | L922 | PASS |
| runtime codehash changed | impl codehash == dummy, != rc.2, != rc.2 attestation | L923–L929 | PASS |
| state preserved | getters identical (L939), raw slots identical (L941), owner / pendingOwner / guardian (L933, L935, L937) | | PASS |
| still functional | validate probe on the dummy, sigFail 0 (L945); NEG-56 EOA cannot upgrade back | | PASS |
| rollback (preferred) | D6 schedule (release printer accepts rc.2, calldata == independent encoding) → early execute NEG-57/58 → 48h → NEG-59 → execute | L947–L996 | PASS |
| rollback read-backs | impl slot == rc.2 (L1001), version 5.5.0 (L1003), codehash == original (L1005), rc.2 attestation MATCH (L1009), EXTENSION == original (L1011), getters / raw slots identical (L1017–L1018), probe sigFail 0 (L1022) | | PASS |

## Read-backs before / after

| | before (rc.2) | after D5 (dummy) | after D6 (rollback) |
|---|---|---|---|
| ERC-1967 impl | `0x3a69c08a310bb62befdd03048c6ec64235772e5b` | `0x90F740A94f8f7f441c1dD0C55FE2e11597E27ff6` | `0x3a69c08a310bb62befdd03048c6ec64235772e5b` |
| `version()` via proxy | `SuperPaymaster-5.5.0` | `SuperPaymaster-5.5.0-A2DRILL-DUMMY-NOT-A-RELEASE` | `SuperPaymaster-5.5.0` |
| impl runtime codehash (raw, with immutables) | `0x855c0e80217be18958cecb20582584966412ae98b5e357cd7e109dd37219dfbf` | `0xea5051d205a52644cad65acea4e19bc311fd22b6e97ddcd123ab4a574e985d79` | `0x855c0e80…19dfbf` |
| vs rc.2 attestation (masked) | MATCH | MISMATCH (expected) | MATCH |
| `EXTENSION` | `0xA497F738446fD823e15198bFa8157E6Aa50677C0` | `0x35e905E6730e94850725724E1F7C6Bcb3690Cc64` (rc.2 Admin code) | `0xA497F738…0677C0` |
| owner / pendingOwner / guardian | TL `0x11Cc8878…5D7c` / 0 / Safe | unchanged | unchanged |
| block | 11881656 | 11881668 | 11881678 |

Snapshots: `D5-state-{before,after}.txt`, `D5-slots-{before,after}.txt`, `D6-*` (each at one block).

## Stage D negative controls (expected == actual, exact revert data)

| id | control | expected |
|---|---|---|
| NEG-44 | release tool `UpgradeViaTimelock schedule-upgrade` with the dummy | regex `DefaultArtifacts: SuperPaymaster runtime != profile.default artifact` (off-chain guard, sends nothing) |
| NEG-45 | old EOA owner `SP.upgradeToAndCall(dummy)` | `OwnableUnauthorizedAccount(0xb560…df0E)` |
| NEG-46/47 | Safe (guardian) `SP.upgradeToAndCall(dummy)`: inner replay / exec | `OwnableUnauthorizedAccount(Safe)` / `Error("GS013")` |
| NEG-48/49 | deployer EOA / Safe owner EOA `TL.schedule` directly | `AccessControlUnauthorizedAccount(acct, PROPOSER_ROLE)` |
| NEG-50 | schedule with delay 172799 (eth_call from the Safe) | `TimelockInsufficientDelay(172799, 172800)` |
| NEG-51/52 | Safe execute immediately after schedule | inner `TimelockUnexpectedOperationState(id, 1<<Ready)` / `GS013` |
| NEG-53/54 | Safe execute ~800 s before readiness | same |
| NEG-55 | deployer EOA `TL.execute` after 48h | `AccessControlUnauthorizedAccount(EOA, EXECUTOR_ROLE)` |
| NEG-56 | old EOA owner upgrades the dummy back directly | `OwnableUnauthorizedAccount(EOA)` |
| NEG-57/58 | Safe execute rollback before 48h | inner `TimelockUnexpectedOperationState(rollbackId, 1<<Ready)` / `GS013` |
| NEG-59 | deployer EOA execute rollback after 48h | `AccessControlUnauthorizedAccount(EOA, EXECUTOR_ROLE)` |

Full expected/actual hex per control: `neg-controls.jsonl`; full outputs: `neg.log`.

## Rest of the run (stages 0 / I / II, unchanged #459 script)

Same coverage as the #459 archive, re-run on this fork: 260 CHECK PASS and NEG-1…NEG-43 all matched; the
fork tx ledger (`fork-tx-ledger.jsonl`, 151 blocks) has no tx from the Safe, Safe txs only from owner EOAs
O1/O2, no mined revert, no direct tx to the timelock (L1053–L1062). Final state after the rollback: every
deployed runtime == rc.2 attestation (`codehash-final.log`).

## Not covered

* Registry dummy bump: L394 is about rc1 → rc1′ (SP). Registry's timelock upgrade route is exercised only
  with the same rc.2 bytecode (stage II / C).
* L395 C2 bundle-midway test (rc(n) → rc(n+1) inside one bundle): separate item, not in this run.
* The dummy changes only a `pure` string; it does not exercise a forward upgrade whose logic changes
  (e.g. the OpCtx context compatibility paths) — that is C2's job.

## Reproduce

```
forge build                      # profile.default
pnpm install
script/evidence/a2-full-rehearsal.sh <env file with RPC_URL> 11881530 <out dir> all
cd docs/design/aoa-balance-mode/data/d5b/a2-item4-dummy-bump-11881530-fb507e36 && shasum -a 256 -c EVIDENCE.sha256
```
