# DeployLive round 6b validation

Scope: build on the uncommitted round-six work in rc8-dl. The per-file delta below
uses a worktree snapshot taken at the start of this round, not HEAD. No formatter,
git writes, network, RPC, keystore or .env access. All Forge commands use `--offline`.
No `contracts/src` changes. H is frozen; no edits were made to it.

## Changes

- The prediction site passes `beforeV54 + 9` and its CREATE address into handover.
  After the six transfers, the live nonce and CREATE address must match those
  predictions **before CREATE TL**. Negative tests insert a real local deployer
  transaction or provide a wrong predicted address, require the precise rejection,
  inspect state-diff records for any attempted CREATE, and check absent TL code.
  The existing production transaction walk still independently derives distance 22.
- Safe-compatible M-of-N validation reads `getOwners()` and rejects the deployer,
  both before broadcast and during final handover assertions. The checker reads it
  independently. Its role-overlap table is INFO only and lists every repeated
  address across Safe owners, guardians, SP guardian, guardian address, genesis,
  deployer, recipient, governance owner and all five explicit owner inputs.
- The actual subjects builder used by `_assertHandover` returns exactly `N + 6`
  entries. A focused test gives every subject a distinct nonzero address and
  verifies all nine entries, including index 6. Production's governor slot is
  deliberately assigned `governorInput` (zero under the removed governor input);
  it is not an unassigned gap.
- Both disclosures explain that a remaining GToken balance lets the deployer
  re-approve staking and pay the 30 GToken ticket through permissionless
  `registerRole` to register itself as COMMUNITY again.

## Fixtures and output isolation

The committed inputs are small files under `contracts/test/fixtures/deploylive/`:
`production-pins.json`, `test-pins.json`, and `tampered-timelock.json`. The first two
are the round-six release pins, now read directly rather than regenerated over the
expected values. The last contains only a deliberately invalid creation bytecode.
Compiled release artifacts are still read from Foundry's ignored `out/` directory.

All generated test records, writable pin copies and Python temporary directories
are under `cache/deploylive-tests/`. The production harness overrides only the config
output path; normal deployment config paths retain their existing behavior. Existing
`.gitignore` entry `cache/` covers every output, and Foundry's existing `./` read-write
fs_permission covers that directory. No new ignore/permission exception was needed.
The old rehearsal evidence directory is deleted and no test reads from it.

The round-six logs are excluded from the repository's deliverable files. They are
preserved in ignored `cache/deploylive-tests/round6-archive/`. **They have not been
moved physically outside the worktree:** this session's explicit restriction permits
writing only inside this worktree. An external archive move must be done by a session
allowed to write there; claiming it happened here would be false. Round-6b full logs
and the starting snapshot are in ignored `cache/deploylive-tests/round6b/`.

## Fail-first and retrospective evidence

L-1 and L-2 tests were run before implementing their checks. Original implementation:

```text
[FAIL: next call did not revert as expected] test_Round6bSafeOwnerCannotBeDeployer() (gas: 3307728)
[FAIL: Error != expected error: handover: bootstrap nonce != handover: timelock nonce] test_Round6bExtraTransactionRejectedBeforeTimelockCreate() (gas: 26383742)
[FAIL: Error != expected error: handover: bootstrap nonce != handover: predicted timelock before CREATE] test_Round6bWrongPredictionRejectedBeforeTimelockCreate() (gas: 26381663)
Ran 17 tests in 0.793s
FAILED (failures=2)
SUMMARY 157 passed, 0 failed, 157 total
```

The first nonce harness used mocked calls; it was subsequently strengthened to real
local transactions because mocked calls do not consume the broadcast nonce. Final
mutation runs repeat both negative cases with the real-transaction harness. Logs:
`red-safe.log`, `red-nonce.log`, `red-checker.log`, `red-solidity-assertions.log`.

Round six had no individual red evidence for these changed/new `_assertHandover`
assertions: facilitator owner; each single-step owner; Safe owner gate; mint
accounting; each stake accounting entry; each ticket treasury; both GToken
conservation predicates; zero deployer balance; exact recipient delta; and resolved
slash admin. The new tests corrupt each value and require its specific error.
Removing the corresponding assertions together produces individually logged failures:
10 single-owner slots, 6 stake entries, 6 treasury entries, and each scalar predicate.
The final Safe-owner recheck is exercised independently after successful deployment.
The subjects regression is also tested with the former `N + 7` / offset-7 mutation.
These are **retrospective mutation controls**, not a claim that round six was
implemented test-first.

**Specific exception — Safe owner gate:** it is redundant with earlier checks.
An incorrect owner for any of its five targets fails `handover: single owner` first;
a bad Safe threshold, owner list, code or delegation prefix fails `_validateSafe`
first. With those predecessors intact and stable contract readbacks, no fixture state
independently reaches and fails this gate. An inconsistent, gas-dependent malicious
getter would be a different behavior, not the stable-state authority mutation tested here. Its required behavior is covered by those earlier negative
checks, but no independent red evidence is claimed for the redundant require itself.
H was not changed to manufacture a reachable failure.

Checker assertions that lacked individual red evidence at round-six completion:
all five `*_OWNER`/slash-admin resolved-contract checks; zero recorded deployer GToken
balance even when the live balance agrees; totalSupply versus mints; each stake
readback; conservation; rejected deployer mint; and Registry/SP recorded implementation
owner equality. The new named negative cases cover each. Existing recipient delta,
mint ledger, ticket ledger and mint-event cases now also demand the exact FAIL label.
Disabling those checks produces 25 failures (`red-checker-assertions.log`).
Input-guard removal produces 15 failures and 4 errors (`red-checker-inputs.log`):
malformed values either reach the missing guard's consumer or are wrongly accepted.
New numeric keys and all three numeric arrays each have named subtests. Existing
owner-slot tests cover every changed owner expectation. INFO and N/A lines are
output contracts, not failure assertions; their tests require the expected text.

## Local evidence limits

The production fixture uses the real local EVM deployment sequence and contracts,
with infrastructure and BLS boundaries mocked. It is neither a broadcast nor a
fork. N=3 still mints 2199 GToken, locks 140, transfers 2059, and leaves deployer
balance and staking allowance zero. The failed-H rehearsal and asset inventory
remain covered. No genuine PoP or network deployment is claimed.

The token scanner cannot prove absence of nonstandard tokens without Transfer
logs; direct Forge callers must keep the recorded EVM version consistent with
flags. Those existing limits are unchanged. H's runtime remains 16 bytes.

## Final commands and verbatim results

`/Users/jason/.foundry/bin/forge build --offline` (exit 0; existing lint warnings
are retained in `build-final.log`):

```text
No files changed, compilation skipped
```

`/Users/jason/.foundry/bin/forge test --offline --match-path 'contracts/test/scripts/DeployLive*.t.sol'` (exit 0):

```text
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 6.69ms (5.48ms CPU time)
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 4.13ms (252.17µs CPU time)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 27.04ms (34.23ms CPU time)
Suite result: ok. 29 passed; 0 failed; 0 skipped; finished in 31.58ms (83.04ms CPU time)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 383.99ms (378.72ms CPU time)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 3.02s (3.02s CPU time)
Ran 6 test suites in 3.04s (3.47s CPU time): 46 tests passed, 0 failed, 0 skipped (46 total tests)
```

`python3 -m unittest discover -s script/rehearsal -p 'test_deploylive*.py'` (exit 0):

```text
................................
----------------------------------------------------------------------
Ran 32 tests in 1.548s

OK
SUMMARY 158 passed, 0 failed, 158 total
```

`python3 -m unittest discover -s script/rehearsal -p 'test_creation_pins.py'` (exit 0):

```text
.
----------------------------------------------------------------------
Ran 1 test in 0.006s

OK
```

Checker SUMMARY is from the fully mocked read-only checker fixture, N=2. The new
Safe-owner assertion adds one check: valid-config count is now `154 + 2N` (158 for
N=2). This is offline checker evidence, not an RPC run against a deployed system.

Each moved fixture was individually broken, tested, and restored before the final
full test run. Verbatim failures, in fixture order production-pins, test-pins,
tampered-timelock:

```text
[FAIL: creation pin mismatch: TimelockController] test_ProductionPathN3() (gas: 36259956)
[FAIL: creation pin mismatch: TimelockController] test_TamperedPinAndArtifactRejectedWithoutNonceConsumption() (gas: 12766455)
[FAIL: next call did not revert as expected] test_TamperedPinAndArtifactRejectedWithoutNonceConsumption() (gas: 85623434)
```

Replacing tampered-timelock with the valid release artifact must make its rejection
test fail; that control proves the invalid fixture is read rather than ignored.
The three fixtures total 4343 bytes. Python generated-input tests create their
artifacts under ignored cache and explicitly compare changes/missing files.

The final source-assertion mutation run (before restoring all checks):

```text
Ran 3 test suites in 5.38s (4.32s CPU time): 0 tests passed, 5 failed, 0 skipped (5 total tests)
```

The 30 per-assertion FAIL records identify every tested scalar/slot. Separately,
suppressing checker owner-slot checks produces 32 failures; restoring them passes.

`git diff --stat bfb9cc45 -- contracts/script/v3/TimelockHandoverBootstrap.sol`
produced **no output**, both on entry and after completion. Thus the round-six
working tree supplied here had no H changes relative to bfb9cc45, and round 6b
adds none. `git diff -- contracts/src` and `git diff --check` also produce no output.


## Round-6b per-file line counts

Compared with the starting uncommitted round-six snapshot using `git diff
--no-index --numstat`. Unchanged round-six files are omitted. Generated command
logs, compiler outputs, caches and the archival copy are excluded.

| File | Added | Deleted |
|---|---:|---:|
| `contracts/script/v3/DeployLive.s.sol` | 19 | 9 |
| `contracts/script/v3/DeployLiveInputs.sol` | 5 | 3 |
| `contracts/test/fixtures/deploylive/production-pins.json` | 1 | 0 |
| `contracts/test/fixtures/deploylive/tampered-timelock.json` | 1 | 0 |
| `contracts/test/fixtures/deploylive/test-pins.json` | 1 | 0 |
| `contracts/test/scripts/DeployLiveHandover.t.sol` | 10 | 0 |
| `contracts/test/scripts/DeployLiveNonce.t.sol` | 78 | 0 |
| `contracts/test/scripts/DeployLivePins.t.sol` | 5 | 6 |
| `contracts/test/scripts/DeployLiveProduction.t.sol` | 44 | 7 |
| `docs/security/rc8-daybreak-fixes.md` | 5 | 0 |
| `script/rehearsal/DEPLOYLIVE_HANDOFF.md` | 5 | 0 |
| `script/rehearsal/DEPLOYLIVE_VALIDATION.md` | 184 | 173 |
| `script/rehearsal/deploylive_postdeploy_check.py` | 15 | 0 |
| `script/rehearsal/test_creation_pins.py` | 4 | 1 |
| `script/rehearsal/test_deploylive_postdeploy_check.py` | 55 | 3 |
| `script/rehearsal/test_deploylive_round6_tools.py` | 5 | 2 |

Removed generated JSON records from the former rehearsal evidence directory
(the pin contents are now in the fixture files above):

| Removed file | Added | Deleted |
|---|---:|---:|
| `config.abandoned.json` | 0 | 1 |
| `config.success.json` | 0 | 1 |
| `production-pins.json` | 0 | 1 |
| `production-transactions.json` | 0 | 1 |
| `test-pins.json` | 0 | 1 |
