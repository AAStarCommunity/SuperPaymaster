# A2 (rc1 gate) complete fork rehearsal — fork block 11877936, script commit 0c21a8fe

**Run**: ONE uninterrupted `all` run of `script/evidence/a2-full-rehearsal.sh` at commit
`0c21a8fe6da29027ed31951e9125889c40ab8f41` (clean tree: `rehearsal.log` L2 prints no "+ uncommitted
changes"), forked from Sepolia block **11877936** (hash `0xe2e13fd3…d78228`) on a LOCAL anvil
(127.0.0.1:28613). Started 2026-10-09T14:28:44Z, finished 2026-10-09T14:43:11Z, exit code 0
(`console.log` last line). Result: **`RUN COMPLETED WITH 0 FAILURES (all)`** — 260 `CHECK … PASS`, 0
`CHECK … FAIL`, 0 `!!!` lines, **43 negative controls, 43/43 matched their exact expected revert**
(`rehearsal.log` L833–L834, `neg-controls.jsonl`). Nothing was broadcast to any public network: the
public RPC was used only as `anvil --fork-url` and for read-only pre-state reads; RPC URLs and keys
are not in any file here (scanned: 0 hits for the env file's key / URL values, with a positive control
on the env file itself).

Responds to DSR CC-124 comment 902e531e (items 1–4). Contracts: `contracts/src` byte-identical to
v5.5.0-rc.2 (peeled `1ac0e1c595dc84e684b540ca6a936168e922194f`) — `rehearsal.log` L3; the local
`profile.default` build reproduces all 10 attested artifacts (runtime + creation keccak) — L6–L17.

**Superseded attempt (not archived, stated for completeness):** the first full run of the previous
script commit `ebae23ad` (fork block 11877866) passed every step and all 43 negative controls but its
fork-tx ledger came out EMPTY — macOS `seq` prints 8-digit block numbers as `1.18779e+07`, so every
`cast block` failed. The ledger's own positive control (G0 deploy tx must be present) caught it and that
run ended `RUN FAILED (all): 2 failure(s)`. Fixed in `0c21a8fe` (integer loop + two more ledger
checks); this archive is a fresh run from scratch of that fixed commit.

## Pre-state (two independent endpoints)

`0-prestate-endpointA.txt` (the anvil fork provider) and `0-prestate-endpointB.txt` (publicnode, keyless)
read 23 values at block 11877936 — SP version/owner/impl slot/APNTS_TOKEN/pending switch/
totalTrackedBalance/both operators, EntryPoint deposit, Registry version/owner/impl slot, Safe version/
owners/threshold/nonce/guard/modules, old timelock roles — and are byte-identical
(`0-prestate-crosscheck.log`: `IDENTICAL (23 values)`; `rehearsal.log` L19). Live state at the fork:
SP `SuperPaymaster-5.4.2`, Registry `Registry-5.8.0`, Safe v1.4.1 2-of-3, Safe nonce 1, pending
switch `0xBb46…9883`. The fork's block hash equals endpoint A's (L45).

## Matrix: spec row → script step → log line → result

Spec = `docs/design/aoa-balance-mode/03-final-spec.md` (runbook rows L370–L385, "rc1 门槛（A2）的 fork 演练范围"
L390–L395). Log lines are `rehearsal.log` line numbers; "key evidence line" is the decisive CHECK in
that section. Every section's count of `!!!` lines is 0. A2 scope items: L391 (steps 0–7c + 5c) = rows
370–381 below; L392 (A3a full path: cancel → deploy → re-queue → +7d → ④) = the five row-371 lines;
L393 (M1–M3 incl. single-step owner transfers and the misconfigured-timelock negative) = rows 383–385;
L394 / L395 see "NOT covered". Stage 0 has no CHECK lines: its probes/inventory call `fail()` on any
error, so its criterion is "0 `!!!`" plus the logged values (`eth_config` `next: null`, L54; inventory
L55–L61).

| spec row (03-final-spec line) | script step | log lines (rehearsal.log) | key evidence line | CHECK PASS / !!! / NEG in section | result |
|---|---|---|---|---|---|
| 370 | 0 fork-level check + inventory | L53–L61 | L54 | 0 / 0 / 0 | PASS |
| 371 | 1 ① cancel 0xBb46 | L135–L139 | L139 | 2 / 0 / 0 | PASS |
| 371 | 1 ② deploy APNTsCapped (+ attested runtime) | L140–L152 | L152 | 5 / 0 / 0 | PASS |
| 371 | 1 ② GOV-1 accept via Safe -> TL schedule/48h/execute | L153–L193 | L190 | 12 / 0 / 6 | PASS |
| 371 | 1 ③ re-queue setAPNTsToken(APNTsCapped), ETA = +7d | L194–L212 | L198 | 7 / 0 / 2 | PASS |
| 371 | 1 ④ minter Safe mints 1:1 | L213–L248 | L246 | 12 / 0 / 1 | PASS |
| 371 | 1 ④ P1 drain / execute / redeposit 1:1 | L249–L263 | L260 | 6 / 0 / 0 | PASS |
| 372 | 2 pendingDebts | L264–L268 | L268 | 2 / 0 / 0 | PASS |
| 373 | 3 pause legacy operators | L269–L273 | L273 | 2 / 0 / 0 | PASS |
| 374-376,378 | 4 v2 stack, 5 SP upgrade (P2), 5b stake, 6 setXPNTsFactory | L274–L311 | L311 | 12 / 0 / 0 | PASS |
| 377 | 5c Registry upgrade (EOA) | L312–L330 | L330 | 4 / 0 / 0 | PASS |
| 379 | 7a v2 token per community, creditPolicy OFF | L331–L344 | L344 | 5 / 0 / 0 | PASS |
| 381 | 7c updatePrice -> configure -> unpause | L345–L362 | L362 | 10 / 0 / 0 | PASS |
| 381 | 7c acceptance op per community (AAStar + Mycelium) | L363–L391 | L386 | 12 / 0 / 0 | PASS |
| 383 | M1 ① transferOwnership x4 (SP, Registry two-step; AOAProtocolRegistry, xPNTsFactoryV2 single-step) | L392–L420 | L418 | 9 / 0 / 2 | PASS |
| 383, 393 | M1 misconfigured timelock cannot accept | L421–L428 | L426 | 1 / 0 / 1 | PASS |
| 383, 393 | M1 ② Safe scheduleBatch -> 48h -> executeBatch | L429–L514 | L485 | 24 / 0 / 8 | PASS |
| 394 | C timelock-aware upgrade drill SP + Registry | L515–L649 | L649 | 48 / 0 / 6 | PASS |
| 384 | M2 guardian pause / sigFail / negatives / timelock unpause | L650–L728 | L728 | 21 / 0 / 11 | PASS |
| 385 | M3 setAPNTSPrice only via timelock | L729–L790 | L790 | 16 / 0 / 6 | PASS |
| 383 (roles) | final exact role sets + final attested runtime | L791–L820 | L820 | 6 / 0 / 0 | PASS |
| 404 (§6.1) | fork tx ledger | L821–L835 | L826 | 7 / 0 / 0 | PASS |


### Spec rows / A2 items NOT covered by this run (stated plainly)

| spec | what | status |
|---|---|---|
| L380, row 7b | legacy-debt decision (D-21: abandon, record only) | **not exercised** — a written decision, no on-chain step; the inventory (L53–L61) shows total `pendingDebts` = 0 for both operators |
| L382, row 7d | aPNTs mint authority to the Safe (`renounceFactory` + `transferCommunityOwnership(Safe)`) | **not covered by this script** (previously rehearsed at block 11692415 per the spec row itself; not re-run here) |
| L370, row 0 (part) | `pendingDebts` enumeration **by `DebtRecordFailed` event scan** over two archive endpoints | **not covered**: `inventoryDebts` reads `pendingDebts` for the two known operators × their tokens; no event scan. `eth_config` (`next: null`) and the CLZ probe ARE covered (`0-fork-level-probes.json`) |
| L394, A2 item 4 | rc1 → rc1′ **dummy-bump** upgrade through the timelock | **partially**: the full timelock-aware path (deploy impl → Safe `schedule(upgradeToAndCall)` → 48h → Safe `execute` → `version()` + impl slot + raw slots + owner + BLS legs) runs for SP AND Registry (L515–L649), but it re-deploys the SAME rc.2 bytecode (new impl address, identical attested codehash) — no rc1′ artifact with a changed constant exists |
| L395, A2 item 5 | C2 bundle-mid-flight test (rc(n) → rc(n+1), forward + rollback) | **not covered** by this script |
| L386–L388, rows 8, 9, 10 | legacy swap contract, downstream issues, RepCredit follow-ups | out of scope for the fork rehearsal (no on-chain step in A2) |


## Negative controls: expected vs actual (DSR item 1)

Every `must_fail` now compares the first `data: "0x…"` revert-data field of the cast output
**byte-for-byte** with the ABI encoding of the expected error built by `errdata <sig> <args>`. A revert
with another selector, the same selector with other arguments, no revert data, or a succeeding call is a
FAILURE of the run (not a pass). The only regex matches left (NEG-13/21/24) are the OFF-CHAIN refusal of
`UpgradeViaTimelock.s.sol` to run without a roles attestation (nothing is sent; there is no revert data).
Full expected and actual hex of every row: `neg-controls.jsonl`; full raw cast output with the head block
before/after: `neg.log`. For every Safe negative the inner call is ALSO replayed as an `eth_call` from the
Safe (the Safe itself hides the inner reason behind `GS013`), so each pair below names both the outer
`Error("GS013")` and the inner custom error.

Expected errors, verified against SOURCE (not guessed):

| error | selector | where it is raised (rc.2 source unless noted) | used by |
|---|---|---|---|
| `OwnableUnauthorizedAccount(address)` | `0x118cdaa7` | OZ v5.0.2 `Ownable._checkOwner` (`singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/access/Ownable.sol:65`) via `onlyOwner` on `SuperPaymasterAdmin.setAPNTSPrice` (:223), `.withdrawProtocolRevenue` (:274), `BasePaymasterUpgradeable._authorizeUpgrade` (:45), `Registry._authorizeUpgrade` (:973), `AOAProtocolRegistry.revokeApproval` (:96), `xPNTsFactoryV2.setSuperPaymasterAddress` (:456); and `Ownable2StepNamespaced.acceptOwnership` (`contracts/src/utils/Ownable2StepNamespaced.sol:72`) for the misconfigured timelock | NEG-10, 11, 12, 19, 20, 29, 31, 38, 39 |
| `AccessControlUnauthorizedAccount(address,bytes32)` | `0xe2517d3f` | OZ v5.0.2 `AccessControl._checkRole` (`…/access/AccessControl.sol:96`) via `TimelockController` `onlyRole(PROPOSER_ROLE)` / `onlyRoleOrOpenRole(EXECUTOR_ROLE)` (the timelock artifact's metadata sources are the v5.0.2 tree) | NEG-1, 2, 6, 14, 17, 18, 43 |
| `TimelockUnexpectedOperationState(bytes32,bytes32)` | `0x5ead8eb5` | OZ v5.0.2 `TimelockController._beforeCall` (`…/governance/TimelockController.sol:422`, `:434`), `expectedStates = _encodeStateBitmap(Ready) = 0x…04`; the operation id is the exact `hashOperation(Batch)` | NEG-4, 15, 22, 25, 36, 41 (inner) |
| `InvalidConfiguration()` | `0xc52a9bd3` | the LIVE pre-upgrade SP is 5.4.2: tag `v5.4.2` `SuperPaymaster.sol:378–395` (three branches: pending == 0, ETA, not drained). NEG-8 + the positive control after it discriminate the ETA branch (state-override `eth_call`s, slots 15/16/30 first checked against the getters) | NEG-7/8 |
| `NotMinter(address)` | `0x361c31f2` | `contracts/src/tokens/APNTsCapped.sol:93` | NEG-9 |
| `Unauthorized()` | `0x82b42900` | `SuperPaymasterAdmin._requirePauseAuthority` (:77–83): guardian may only pause; anyone else reverts | NEG-27, 33, 35 |
| `Error("GS013")` / `Error("GS020")` | `0x08c379a0` | Safe v1.4.1 (live Sepolia Safe, `VERSION()` read back): `execTransaction` inner call failed with `safeTxGas == gasPrice == 0` / `checkNSignatures` signatures too short | GS013: NEG-5, 16, 23, 26, 28, 30, 32, 34, 37, 40, 42 (outer of each Safe pair); GS020: NEG-3 |

The comparator itself has its own control (`must-fail-selftest.sh` → `must-fail-selftest.log`): the
`must_fail` / `errdata` functions are extracted verbatim from the committed script and run against a
plain local anvil with a deployed OZ TimelockController; 7/7 probes give the right verdict — PASS only for
the exact `AccessControlUnauthorizedAccount(B, PROPOSER)`; FAIL for the same selector with the wrong
account, the same selector with the wrong role, a different selector, the bare 4-byte selector, a call
that succeeds, and a tooling error with no revert data.

| id | negative control | head block | expected (decoded) | expected revert data == actual revert data | result |
|---|---|---|---|---|---|
| NEG-1 | A1d: deployer EOA cannot schedule on the canonical TL (not PROPOSER) | 11877941 | AccessControlUnauthorizedAccount(OWNER-EOA, PROPOSER_ROLE) | `0xe2517d3f…` (68 B) vs actual: identical | PASS |
| NEG-2 | A1d: a Safe OWNER EOA acting directly (not through the Safe) cannot schedule | 11877941 | AccessControlUnauthorizedAccount(SafeOwnerO1, PROPOSER_ROLE) | `0xe2517d3f…` (68 B) vs actual: identical | PASS |
| NEG-3 | A1d: Safe exec with ONE owner signature (threshold 2) -> GS020 | 11877941 | Error("GS020") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-4 | A1d: Safe execute BEFORE 48h (TimelockUnexpectedOperationState) [inner call replayed as eth_call from the Safe] | 11877944 | TimelockUnexpectedOperationState(0xcfe0031e…, Ready-bitmap(0x04)) | `0x5ead8eb5…` (68 B) vs actual: identical | PASS |
| NEG-5 | A1d: Safe execute BEFORE 48h (TimelockUnexpectedOperationState) | 11877944 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-6 | A1d: deployer EOA cannot execute (not EXECUTOR) | 11877945 | AccessControlUnauthorizedAccount(OWNER-EOA, EXECUTOR_ROLE) | `0xe2517d3f…` (68 B) vs actual: identical | PASS |
| NEG-7 | A1e: executeAPNTsTokenChange before the 7-day ETA | 11877948 | InvalidConfiguration() | `0xc52a9bd3…` (4 B) vs actual: identical | PASS |
| NEG-8 | A1e discriminator (a): drain neutralised by state override, ETA real -> still InvalidConfiguration (ETA branch) | 11877948 | InvalidConfiguration() | `0xc52a9bd3…` (4 B) vs actual: identical | PASS |
| NEG-9 | A1f: deployer EOA cannot mint APNTsCapped (minter = Safe) | 11877949 | NotMinter(OWNER-EOA) | `0x361c31f2…` (36 B) vs actual: identical | PASS |
| NEG-10 | M1: deployer EOA AOAProtocolRegistry.revokeApproval after transfer | 11878009 | OwnableUnauthorizedAccount(OWNER-EOA) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-11 | M1: deployer EOA xPNTsFactoryV2.setSuperPaymasterAddress after transfer | 11878009 | OwnableUnauthorizedAccount(OWNER-EOA) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-12 | M1: misconfigured timelock executes SP.acceptOwnership (pendingOwner is the canonical TL) | 11878011 | OwnableUnauthorizedAccount(0xb9e22422435d69efb42258d4d165786681192303) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-13 | M1: UpgradeViaTimelock schedule-accept WITHOUT a roles attestation | 11878011 | roles attestation: missing | `roles attestation: missing` vs actual: identical | PASS |
| NEG-14 | M1: deployer EOA scheduleBatch directly (not PROPOSER) | 11878012 | AccessControlUnauthorizedAccount(OWNER-EOA, PROPOSER_ROLE) | `0xe2517d3f…` (68 B) vs actual: identical | PASS |
| NEG-15 | M1: Safe executeBatch BEFORE 48h [inner call replayed as eth_call from the Safe] | 11878015 | TimelockUnexpectedOperationState(0x01034015…, Ready-bitmap(0x04)) | `0x5ead8eb5…` (68 B) vs actual: identical | PASS |
| NEG-16 | M1: Safe executeBatch BEFORE 48h | 11878015 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-17 | M1: non-multisig (deployer EOA) executeBatch after 48h (not EXECUTOR) | 11878016 | AccessControlUnauthorizedAccount(OWNER-EOA, EXECUTOR_ROLE) | `0xe2517d3f…` (68 B) vs actual: identical | PASS |
| NEG-18 | M1: non-multisig (Safe owner EOA directly) executeBatch after 48h | 11878016 | AccessControlUnauthorizedAccount(SafeOwnerO2, EXECUTOR_ROLE) | `0xe2517d3f…` (68 B) vs actual: identical | PASS |
| NEG-19 | M1: old EOA owner SP.upgradeToAndCall after M1 | 11878020 | OwnableUnauthorizedAccount(OWNER-EOA) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-20 | M1: old EOA owner Registry.upgradeToAndCall after M1 | 11878020 | OwnableUnauthorizedAccount(OWNER-EOA) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-21 | C SP: schedule-upgrade WITHOUT a roles attestation | 11878021 | roles attestation: missing | `roles attestation: missing` vs actual: identical | PASS |
| NEG-22 | C SP: Safe execute BEFORE 48h [inner call replayed as eth_call from the Safe] | 11878025 | TimelockUnexpectedOperationState(0x9beb262c…, Ready-bitmap(0x04)) | `0x5ead8eb5…` (68 B) vs actual: identical | PASS |
| NEG-23 | C SP: Safe execute BEFORE 48h | 11878025 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-24 | C REGISTRY: schedule-upgrade WITHOUT a roles attestation | 11878030 | roles attestation: missing | `roles attestation: missing` vs actual: identical | PASS |
| NEG-25 | C REGISTRY: Safe execute BEFORE 48h [inner call replayed as eth_call from the Safe] | 11878034 | TimelockUnexpectedOperationState(0x278740ef…, Ready-bitmap(0x04)) | `0x5ead8eb5…` (68 B) vs actual: identical | PASS |
| NEG-26 | C REGISTRY: Safe execute BEFORE 48h | 11878034 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-27 | M2: guardian (Safe) unpause setGlobalPaused(false) [inner call replayed as eth_call from the Safe] | 11878041 | Unauthorized() | `0x82b42900…` (4 B) vs actual: identical | PASS |
| NEG-28 | M2: guardian (Safe) unpause setGlobalPaused(false) | 11878041 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-29 | M2: guardian (Safe) SP.upgradeToAndCall [inner call replayed as eth_call from the Safe] | 11878042 | OwnableUnauthorizedAccount(Safe) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-30 | M2: guardian (Safe) SP.upgradeToAndCall | 11878042 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-31 | M2: guardian (Safe) SP.withdrawProtocolRevenue (move funds) [inner call replayed as eth_call from the Safe] | 11878043 | OwnableUnauthorizedAccount(Safe) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-32 | M2: guardian (Safe) SP.withdrawProtocolRevenue (move funds) | 11878043 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-33 | M2: guardian (Safe) unpause an operator setOperatorPaused(OWNER,false) [inner call replayed as eth_call from the Safe] | 11878044 | Unauthorized() | `0x82b42900…` (4 B) vs actual: identical | PASS |
| NEG-34 | M2: guardian (Safe) unpause an operator setOperatorPaused(OWNER,false) | 11878044 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-35 | M2: old EOA unpause (neither owner nor guardian) | 11878044 | Unauthorized() | `0x82b42900…` (4 B) vs actual: identical | PASS |
| NEG-36 | M2: Safe execute(unpause) BEFORE 48h [inner call replayed as eth_call from the Safe] | 11878048 | TimelockUnexpectedOperationState(0x26436137…, Ready-bitmap(0x04)) | `0x5ead8eb5…` (68 B) vs actual: identical | PASS |
| NEG-37 | M2: Safe execute(unpause) BEFORE 48h | 11878048 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-38 | M3: old EOA setAPNTSPrice | 11878051 | OwnableUnauthorizedAccount(OWNER-EOA) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-39 | M3: Safe (guardian, not owner) setAPNTSPrice directly [inner call replayed as eth_call from the Safe] | 11878052 | OwnableUnauthorizedAccount(Safe) | `0x118cdaa7…` (36 B) vs actual: identical | PASS |
| NEG-40 | M3: Safe (guardian, not owner) setAPNTSPrice directly | 11878052 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-41 | M3: Safe execute(setAPNTSPrice) BEFORE 48h (early execute) [inner call replayed as eth_call from the Safe] | 11878056 | TimelockUnexpectedOperationState(0x921600c8…, Ready-bitmap(0x04)) | `0x5ead8eb5…` (68 B) vs actual: identical | PASS |
| NEG-42 | M3: Safe execute(setAPNTSPrice) BEFORE 48h (early execute) | 11878056 | Error("GS013") | `0x08c379a0…` (100 B) vs actual: identical | PASS |
| NEG-43 | M3: deployer EOA execute after 48h (not EXECUTOR) | 11878057 | AccessControlUnauthorizedAccount(OWNER-EOA, EXECUTOR_ROLE) | `0xe2517d3f…` (68 B) vs actual: identical | PASS |


## Role manifest — exact member sets of the canonical GOV-1 timelock

Timelock `0x11Cc8878C12DAfEe401FF4A3f5F7D2c4d4ed5D7c` (deployed in block 11877937, tx `0x5d196afd…2233e`,
minDelay 172800, from the `profile.default` OZ v5.0.2 artifact). Final sets, rebuilt by replaying EVERY
`RoleGranted` / `RoleRevoked` log of the timelock since its deployment block (`role-events-final.json`
→ `role-manifest-final.json`), and independently by `script/governance/check-timelock-roles.mjs`
(`roles-final.json`, L799):

| role | exact member set (final, head block 11878061) |
|---|---|
| `DEFAULT_ADMIN_ROLE` | [`0x11cc8878…5d7c`] (the timelock itself only) — L802 |
| `PROPOSER_ROLE` | [`0x51edf11f…e114`] (Mycelium Safe only) — L803 |
| `CANCELLER_ROLE` | [`0x51edf11f…e114`] (Safe only) — L804 |
| `EXECUTOR_ROLE` | [`0x51edf11f…e114`] (Safe only; not open: `hasRole(EXECUTOR, 0) == false`) — L805 |

`mustHoldNothing` (checked at every `roles_check`): the deployer EOA `0xb5600060…df0E` and the old live
timelock `0x86C8…9564`. The same check ran at 13 points (`roles-*.log`, one per schedule/execute) and each
produced the `attestation-*.json` consumed by `UpgradeViaTimelock`.

Ownership after M1 (L485–L503): SP, Registry, AOAProtocolRegistry, xPNTsFactoryV2 and APNTsCapped
`owner() == timelock`, SP/Registry `pendingOwner() == 0`, SP `guardian() == Safe`.

## Deployed runtime == rc.2 attestation (DSR item 4)

`verify-attested-runtime.mjs` reads `eth_getCode` from the fork, zeroes the artifact's
`immutableReferences` ranges (the attestation's `runtimeKeccak` is the artifact `deployedBytecode`
keccak with immutables zero, see its `hashNote`), and requires the masked on-chain code to be
byte-identical to the artifact AND its keccak to equal `docs/release/v5.5.0-rc.2-attestation.json`; the
raw on-chain codehash and the immutable words are reported alongside. Each call carries a negative
control (a deliberately wrong pairing must mismatch).

| step | targets | log line | result |
|---|---|---|---|
| A1c | APNTsCapped | L152 | MATCH |
| A3 | SuperPaymaster impl, SuperPaymasterAdmin, Lens, GlobalTierSource, AOAProtocolRegistry, xPNTsTokenV2Ext, xPNTsTokenV2, xPNTsFactoryV2 (+ neg) | L311 | 8/8 MATCH, neg mismatched |
| A4 | Registry impl | L330 | MATCH |
| A5 | AAStar + Mycelium v2 tokens = exact EIP-1167 clones of the attested template | L344 | 2/2 MATCH |
| C | the SP and Registry impls deployed for the timelock drill | L519, L586 | MATCH |
| final | 10 targets (SP impl, Admin, Registry impl, Lens, GlobalTierSource, AOAProtocolRegistry, V2Ext, V2, FactoryV2, APNTsCapped) + 2 clones + 1 negative control | L820 (`codehash-final.log`) | 10/10 + 2/2 MATCH, neg mismatched |

## Fork tx ledger (`fork-tx-ledger.jsonl`)

Every transaction mined on the fork after block 11877936 (blocks 11877937..11878061, all 125 walked,
L822): **104 txs, all status `0x1`** (L828). Senders: deployer EOA `0xb5600060…` ×52, Safe owner O1
`0x871608cb…` ×27, Safe owner O2 `0x8c349925…` ×16, ANNI `0xecaacb91…` ×9. Checks (L822–L829): every tx
hash in `receipts.jsonl` is in the ledger; the G0 deploy tx is present (positive control); **no tx FROM
the Safe address** (the Safe was never impersonated — every Safe action is a real `execTransaction` with
two owner approvals); every Safe-targeted tx came from O1/O2 only; no mined tx reverted (negative controls
never reach the chain); no tx was sent directly to the canonical timelock (every schedule/execute is an
internal call from the Safe).

## 7c acceptance ops (one per community)

| community | operator | TxHash | UserOpHash | block |
|---|---|---|---|---|
| Mycelium | ANNI `0xEcAA…33c9` | `0x76e49429cc30bec6a7fb8a75495f584ae33bea98f4dd4d24f3fb85d7e8c05c60` | `0xc1586668e90ed3a5702b79e074bdc163343a563e3cd5ec471da9e2400d25821f` | 11877998 |
| AAStar | OWNER `0xb560…df0E` | `0x9546c06bb1a0cb2b8f4fbde6da63eacc21b86c75b0debed726f0bb1bd48ac79d` | `0x58eb0a6e3a2773a4817a583076800e415c766f922f8960ccfabd97b3fad00e04` | 11878004 |

Both: exactly one `UserOperationEvent`, `success == 1`, paymaster == SP; `L4GaslessTest.verify()` reads
the settlement back from chain state; `creditPolicy` still OFF afterwards (L363–L391).

## Files and integrity

All files of this directory except `EVIDENCE.sha256` itself are listed in `EVIDENCE.sha256`
(`shasum -a 256 -c EVIDENCE.sha256`). `console.log` is the run's stdout/stderr with any RPC URL redacted
(none was present). The `.log` files are tracked through `docs/design/aoa-balance-mode/data/.gitignore`
(`!*.log`); the file count was verified against a fresh clone of the pushed branch (see the PR).

Reproduce (local anvil only; needs `forge build` with `profile.default` and node + viem):

```
script/evidence/a2-full-rehearsal.sh <env file with RPC_URL, PRIVATE_KEY, PRIVATE_KEY_ANNI> <fork block> <out dir> all
```
