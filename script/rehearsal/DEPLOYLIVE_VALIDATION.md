# DeployLive round 7b validation

Round 7b supersedes the round 7 automatic agent wiring and a=1 OP count below.
OP defaults OFF (a=0): 96 transactions before H for N=3/c=1. Explicit opt-in
requires both nonzero addresses to match the reviewed dependency file; the OP
file expects zero, so enabling OP requires a reviewed file change. Switch and
pointers are logged and serialized. The existing checker already compares both
on-chain getters to the file; new offline OP cases prove zero acceptance and
rejection of either nonzero getter. Both disclosures record the OP rationale
and the unchanged known Sepolia testnet exposure.

## Fail-first evidence

Before implementation, cache/round7b-red.log recorded these behavioral failures:

```text
[FAIL: next call did not revert as expected] test_AgentAddressesMustMatchReviewedFile() (gas: 103308)
[FAIL: next call did not revert as expected] test_AgentAddressesRequireSwitch() (gas: 63017)
[FAIL: next call did not revert as expected] test_AgentSwitchMustBeBoolean() (gas: 103125)
[FAIL: next call did not revert as expected] test_AgentSwitchRequiresBothAddresses() (gas: 83165)
[FAIL: vm.parseJsonBool: path ".enableAgentRegistries" must return exactly one JSON value] test_ProductionPathAgentsEnabled() (gas: 323220738)
[FAIL: 86 + 3N + c + a: 97 != 96] test_ProductionPathN3() (gas: 323194408)
[FAIL: 86 + 3N + c + a: 97 != 96] test_TicketsReachSafeWithSeparateRecipient() (gas: 323187281)
[FAIL: next call did not revert as expected] test_AgentAddressesMustMatchReviewedFile() (gas: 103308)
[FAIL: next call did not revert as expected] test_AgentAddressesRequireSwitch() (gas: 63017)
[FAIL: next call did not revert as expected] test_AgentSwitchMustBeBoolean() (gas: 103125)
[FAIL: next call did not revert as expected] test_AgentSwitchRequiresBothAddresses() (gas: 83165)
[FAIL: vm.parseJsonBool: path ".enableAgentRegistries" must return exactly one JSON value] test_ProductionPathAgentsEnabled() (gas: 323220738)
[FAIL: 86 + 3N + c + a: 97 != 96] test_ProductionPathN3() (gas: 323194408)
[FAIL: 86 + 3N + c + a: 97 != 96] test_TicketsReachSafeWithSeparateRecipient() (gas: 323187281)
```

The duplicate lines above are Forge's per-suite output and final failure list.
cache/round7b-checker-red.log records the OP checker fixture failing with:

```text
SUMMARY 174 passed, 2 failed, 176 total
```

Both expected registry values were still nonzero in that red run. The new
input guards each had a fail-first test. Existing nonce checks are now measured
for both a values. The enabled and disabled scenarios use separate output
directories after the initial green-candidate run exposed a shared-file collision.

## Verbatim final results

`forge test --offline --match-path 'contracts/test/scripts/DeployLive*.t.sol' -vv`
— exit 0; full output: cache/round7b-forge.log.

```text
  pre-H zero-value transactions: 97
  TL-to-H observed distance: 22
  v5.4-to-TL observed distance: 7
  pre-H zero-value transactions: 96
  TL-to-H observed distance: 22
  v5.4-to-TL observed distance: 7
  pre-H zero-value transactions: 96
  TL-to-H observed distance: 22
  v5.4-to-TL observed distance: 7
Ran 7 test suites in 1.66s (4.24s CPU time): 70 tests passed, 0 failed, 0 skipped (70 total tests)
```

`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s script/rehearsal -p 'test_deploylive*.py'`
— exit 0; full output: cache/round7b-python.log.

```text
..........s.............................................
----------------------------------------------------------------------
Ran 56 tests in 4.053s

OK (skipped=1)
PASS failure
SUMMARY 176 passed, 0 failed, 176 total
```

The 176-row checker SUMMARY is from the offline mock fixture, not a live chain
or a real forge-script config. No Anvil was started or loopback binding attempted.
The opt-in local-forge regression remains for the main session; it explicitly
enables the 31337 registry fixture. No formatter, network/RPC, keystore, .env,
git write, or contracts/src edit was performed.

## Scope checks

- git diff --check — exit 0; output: 0 bytes
- git diff -- contracts/src — exit 0; output: 0 bytes
- git diff bfb9cc45 -- contracts/script/v3/TimelockHandoverBootstrap.sol — exit 0; output: 0 bytes

---

The remainder is the historical round 7 report; its a=1 OP statements are
superseded by round 7b above.

# DeployLive round 7 validation

Offline implementation and validation completed; acceptance rehearsal is **not complete**.
The real non-fork Anvil regression was attempted but the sandbox denied loopback
socket binding before Anvil started. No real-forge-config checker SUMMARY or live
failure-rehearsal inventory exists for this round. The failure driver was exercised
with mocked RPC/deployment boundaries, not a live chain.

HEAD started at 8dc5d550. No formatter, external network/RPC, keystore, .env or git
writes were used. All task files and evidence remain inside this worktree. New
reviewed JSON files are prepared for commit, not committed. `.opus-r2.md` was read
first and deleted. `contracts/src` remains untouched.

## Dispositions

| Item | Implementation / evidence |
|---|---|
| M1 | Ticket account comparison normalizes both sides; all other address comparisons audited. Failed-set accounts normalized. Fixtures use precomputed checksummed addresses. Real forge-script regression added, but execution blocked at socket bind. |
| M2 | Failure driver accepts `--external-tokens FILE`; mock failure mode runs successfully with a 31337 group. Both Transfer and registration scans use deploymentStartBlock. Live rehearsal remains blocked. |
| getOwners Low | Return code must succeed before parsing owners; an error containing two valid-looking addresses fails both Safe rows. |
| M3 | Reviewed dependency files for 10 and 31337. Unknown chain fails. Production rejects identity/reputation overrides. Checker independently reads chainId and expected files. OP values are owner-supplied verification at block 159689777, not rechecked here. |
| M4 | Script checks empty modules and zero guard. Checker also checks official singleton/fallback lists. Each allowlist entry cites an existing repository file. |
| M5 | Five owner choices and recipient accept safe/timelock or a checked Safe. EOA, delegation, threshold one, deployer owner, modules and guard cases are tested for every explicit authority. |
| M6 | Every production path, including 31337 rehearsal, requires its canonical chain pin path. Missing file/rehearsal path fail. Config records SHA-256. CI clean rebuild compares OP pins and local pins. Checker runtime comparison is limited to Registry implementation, SP implementation and Timelock, with compiler immutable ranges masked. |
| M7 | Three run-level mutation tests; invalid infrastructure and artifact/pin mismatch produce zero broadcasts before mutation. Mutation deletions each produce 98 broadcast attempts and fail. Swallowed price failure is detected. Self-referential nonce equality replaced with independently counted transaction count. Handover assertion-to-checker mapping is in HANDOFF. |
| Other Lows | Two N/A rows are real absence checks; SBT balance and pending burn forced to zero/false; PolicyRegistry timelock and guardian assertions added; empty recipient has named error; forge/cast use PATH or FORGE/CAST. |

## Fail-first evidence and limits

Logs are under `cache/deploylive-tests/round7/`. Initial checker, failed-set,
Safe/input, dependency, pin-path and final-assertion regressions ran before their
respective implementation edits. Additional expanded case tables were replayed
against saved HEAD implementation files; temporary mutations were restored.
The three run-level tests were first run green, then independently made red by the
explicit requested mutations. This is targeted fail-first/mutation evidence, not
an exhaustive proof that every historical assertion has an isolated mutation test.

| Regression | Red log |
|---|---|
| Address case and failed getOwners read | checker-red.log |
| Deployment-bounded logs | failed-set-red.log |
| Two absence rows and SBT/pending burn | lows-red.log; absent-config-red.log |
| Safe modules/guard, six authority rejection cases, empty recipient | safe-inputs-red.log; all-authority-cases-red.log |
| Four independent Safe checks | safe-checker-red.log |
| v1.4.1 singleton allowlist acceptance | safe-v141-red.log |
| Wrong/missing dependency group and forbidden overrides | deps-red.log; agent-override-red.log |
| All six independent dependency rows / unknown chain | deps-checker-red.log; all-dependencies-checker-red.log |
| Runtime code for each of three subjects | runtime-red.log |
| Explicit authority rows / all unsafe categories | authority-checker-red.log; all-checker-authority-red.log |
| Production and local production reject rehearsal pins | pins-red.log; local-pin-path-red.log |
| SBT, pending burn and two PolicyRegistry assertions | assertions-red.log (all four probes report ASSERTION FAIL) |
| Driver external token injection | driver-red.log |
| Remove _validateInfrastructure | mutation-infrastructure-red.log |
| Remove _assertCreationPins | mutation-pins-red.log |
| Restore swallowed price error | mutation-price-red.log |

The complete logs distinguish actual assertion failures from compiler output. The
final expanded authority baseline was rerun with both original DeployLive and
original Inputs so all nine failures are behavioral, not missing-symbol errors.

## Verbatim final command results

`forge build --offline` — exit 0. Verbatim excerpt; full output in build-final.log:

```text
Compiling 1 files with Solc 0.8.33
Compiling 5 files with Solc 0.8.33
Solc 0.8.33 finished in 724.14ms
Solc 0.8.33 finished in 35.17s
Compiler run successful with warnings:
Warning (4591): There are more than 256 warnings. Ignoring the rest.
```

`forge test --offline --match-path 'contracts/test/scripts/DeployLive*.t.sol' -vv`
— exit 0. Verbatim suite results; full output in forge-final.log:

```text
Suite result: ok. 10 passed; 0 failed; 0 skipped; finished in 2.29ms (1.74ms CPU time)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 3.43ms (2.71ms CPU time)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 11.62ms (11.27ms CPU time)
Suite result: ok. 38 passed; 0 failed; 0 skipped; finished in 21.45ms (69.97ms CPU time)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 572.11ms (574.78ms CPU time)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 1.61s (273.68ms CPU time)
Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 1.61s (3.22s CPU time)
Ran 7 test suites in 1.61s (3.83s CPU time): 65 tests passed, 0 failed, 0 skipped (65 total tests)
```

`python3 -m unittest discover -s script/rehearsal -p 'test*.py'` — exit 0:

```text
...........s............................................
----------------------------------------------------------------------
Ran 56 tests in 3.812s

OK (skipped=1)
PASS failure
SUMMARY 176 passed, 0 failed, 176 total
```

The skipped test is the opt-in real local Anvil regression. It was also explicitly
attempted with `DEPLOYLIVE_LOCAL_TEST=1`; local-test.log records:

```text
PermissionError: [Errno 1] Operation not permitted

Ran 1 test in 0.000s

FAILED (errors=1)
```

**Checker SUMMARY from mock fixtures (N=2):**

```text
SUMMARY 176 passed, 0 failed, 176 total
```

**Checker SUMMARY from a real local forge config: unavailable.** No such run
reached deployment in this sandbox. The production Foundry unit fixtures write
config.success.json, but those are not `forge script` broadcast evidence and are
not substituted for the missing result. Expected N=3 count is 178, not a measured
local-forge SUMMARY.

Checker count: **172 + 2N**, consisting of 172 fixed rows plus N guardian and N
additional stake rows (the three fixed stake rows are in 172). No N/A rows remain.
The two implementation-isolation INFO-PASS results count; other INFO does not.

## Creation pins and transaction count

`python3 script/rehearsal/creation_pins.py deployments/creation-pins.10.json`
succeeded from an empty isolated output/cache build (creation-pins-clean.log).
It produced 25 pins. The 31337 file contains the same release bytes. A separate
read of the current selected artifacts confirmed all 25 hashes match. Both JSON
files have SHA-256:

```text
dd8694eb6806ec70013ee1bf0b6ede386de8f9cc9b55b0907b2ecfebba15532f
```

The production fixture's config SHA-256 was independently compared with the file.
CI also triggers for production pin and pin-generator changes. The clean build
emitted a sandbox `nice: setpriority: Operation not permitted` warning but continued
and exited successfully; no artifact was taken from a pre-existing output directory.

Both N=3 production unit scenarios exercise a=1 and emit:

```text
pre-H zero-value transactions: 97
TL-to-H observed distance: 22
```

Formula: **86 + 3N + c + a**. c=1 when minimum threshold <3; a=1 when agent
registries are wired. OP N=3/c=1/a=1 gives 97 before H, 98 including H. Agent
registry wiring is Step 5, before v5.4 and CREATE TL. Consequently **+7** from
v5.4 to CREATE TL and **22** from TL to H remain valid. The successful run-level
invalid infrastructure / mismatched pin tests each emit `broadcast count: 0`.

## Scope checks and remaining acceptance work

`git diff --stat bfb9cc45 -- contracts/script/v3/TimelockHandoverBootstrap.sol`
produced exactly zero bytes:

```text
```

`git diff -- contracts/src` is empty. `git diff --check` passes. The raw review
file is absent. No commit, push, notification, deployment or PR operation occurred.

Run the opt-in local regression and the live failure rehearsal in an authorized
session that can bind loopback, then attach their actual checker/inventory output.
The local regression and its genuine PoP fixture compile, but their runtime behavior
has not been verified here. Other chain dependency groups require separately
reviewed files. All other deployed contracts require block-explorer source
verification as described in HANDOFF; runtime checker coverage is intentionally
limited to the three requested contracts. Listed-token balances cover prefunding,
but log discovery cannot find unlisted pre-deployment or non-Transfer tokens.

## Changed/new file line counts

Counts include all final changed and new task files, including this report;
gitignored evidence is excluded.

| File | Lines |
|---|---:|
| `.github/workflows/test.yml` | 139 |
| `contracts/script/v3/DeployLive.s.sol` | 1003 |
| `contracts/script/v3/DeployLiveInputs.sol` | 144 |
| `contracts/script/v3/DeployLivePins.sol` | 33 |
| `contracts/test/fixtures/deploylive/checksummed-addresses.json` | 44 |
| `contracts/test/scripts/DeployLiveHandover.t.sol` | 350 |
| `contracts/test/scripts/DeployLiveInfrastructure.t.sol` | 80 |
| `contracts/test/scripts/DeployLiveLocalFixture.s.sol` | 41 |
| `contracts/test/scripts/DeployLivePins.t.sol` | 55 |
| `contracts/test/scripts/DeployLiveProduction.t.sol` | 226 |
| `contracts/test/scripts/DeployLiveRun.t.sol` | 58 |
| `deployments/creation-pins.10.json` | 27 |
| `deployments/creation-pins.31337.json` | 27 |
| `deployments/external-deps.10.json` | 9 |
| `deployments/external-deps.31337.json` | 9 |
| `deployments/safe-official.json` | 16 |
| `script/rehearsal/DEPLOYLIVE_HANDOFF.md` | 301 |
| `script/rehearsal/DEPLOYLIVE_VALIDATION.md` | 212 |
| `script/rehearsal/creation_pins.py` | 70 |
| `script/rehearsal/deploylive_failed_set_check.py` | 98 |
| `script/rehearsal/deploylive_fork_deploy.py` | 40 |
| `script/rehearsal/deploylive_postdeploy_check.py` | 434 |
| `script/rehearsal/deploylive_rehearse.py` | 299 |
| `script/rehearsal/deploylive_runtime.py` | 33 |
| `script/rehearsal/test_deploylive_failed_set.py` | 82 |
| `script/rehearsal/test_deploylive_local.py` | 89 |
| `script/rehearsal/test_deploylive_modes.py` | 78 |
| `script/rehearsal/test_deploylive_postdeploy_check.py` | 434 |
| `script/rehearsal/test_deploylive_round6_tools.py` | 56 |
