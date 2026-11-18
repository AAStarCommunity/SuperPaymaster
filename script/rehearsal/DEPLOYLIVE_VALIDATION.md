# DeployLive implementation and offline validation

Implemented production input validation, H-only initial timelock authority, exact
handover/history checker, namespaced mutation fixtures and updated ceremony docs.
contracts/src is untouched. No network/RPC, environment file or keystore access,
formatter, or git write was performed. The two initially untracked recovery shell
runners were deleted, and recovery code/tests were removed from the retained helper.

One interpretation remains explicit: scripted genesis/DVT Registry registration
is retained as required setup; the no-registration-before-PASS rule applies to
additional operational registrations. A failed set may already have scripted
registrations, so its no-funds/no-registrations abandonment condition cannot be
assumed. This is documented and was raised for clarification.

H runtime: **16 bytes**, measured by the successful constructor deployment test.
Checker: **139 + N checks**, including two INFO-PASS implementation checks;
**141 for two guardians**. All original 53 checks are mapped in DEPLOYLIVE_HANDOFF.md.
No live deployment/fork/PoP execution was performed.

## Verbatim validation summaries

Build (`/Users/jason/.foundry/bin/forge build --offline`, exit 0):

```text
Compiling 3 files with Solc 0.8.33
Compiling 3 files with Solc 0.8.33
Solc 0.8.33 finished in 5.75s
Solc 0.8.33 finished in 16.15s
Compiler run successful with warnings:
Warning (4591): There are more than 256 warnings. Ignoring the rest.
```

Forge (`--offline --match-path contracts/test/scripts/DeployLive*.t.sol`, exit 0):

```text
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 10.06ms (265.12µs CPU time)
Suite result: ok. 23 passed; 0 failed; 0 skipped; finished in 15.66ms (31.68ms CPU time)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 24.55ms (37.16ms CPU time)
Ran 3 test suites in 36.96ms (50.27ms CPU time): 35 tests passed, 0 failed, 0 skipped (35 total tests)
```

Python (`python3 -m unittest discover -s script/rehearsal -p test_deploylive*.py`, exit 0):

```text
................
----------------------------------------------------------------------
Ran 16 tests in 0.613s

OK
SUMMARY 141 passed, 0 failed, 141 total
```

```text
bash -n: 1 scripts passed
```

`git diff --check` exited 0 with no output.

## Three-commit review plan (no commits made)

Counts below are final changes versus HEAD a65762de, including pre-existing
uncommitted work and retained initially untracked files. New files count as all
added lines. Deleted recovery runners were untracked at the start, so are not in
git numstat. Logic/tests/helpers total 845 added+deleted lines; docs are separate.

1. Input validation/Safe: DeployLiveInputs.sol plus the DeployLive.s.sol input
   resolution, preflight and initial-price hunks. Include input-related test hunks
   from group 3 when validating this commit independently.
2. Handover/bootstrap: remaining DeployLive.s.sol hunks and TimelockHandoverBootstrap.sol.
3. Checker/tests/docs: all remaining files; retained rehearsal helpers have no recovery paths.

To avoid double counting, the full DeployLive.s.sol file diff is counted in group 2
below, although its input-validation hunks belong in commit 1. Tests are counted
in group 3, matching the requested review split.

### Group 1

| File | Added | Deleted |
|---|---:|---:|
| `contracts/script/v3/DeployLiveInputs.sol` | 36 | 1 |
| **Total** | **36** | **1** |

### Group 2

| File | Added | Deleted |
|---|---:|---:|
| `contracts/script/v3/DeployLive.s.sol` | 50 | 17 |
| `contracts/script/v3/TimelockHandoverBootstrap.sol` | 14 | 10 |
| **Total** | **64** | **27** |

### Group 3

| File | Added | Deleted |
|---|---:|---:|
| `contracts/test/scripts/DeployLiveHandover.t.sol` | 120 | 14 |
| `docs/security/rc8-daybreak-fixes.md` | 37 | 0 |
| `script/rehearsal/DEPLOYLIVE_HANDOFF.md` | 194 | 138 |
| `script/rehearsal/deploylive_postdeploy_check.py` | 95 | 2 |
| `script/rehearsal/test_deploylive_postdeploy_check.py` | 132 | 10 |
| `contracts/test/scripts/DeployLiveInfrastructure.t.sol` | 61 | 0 |
| `script/rehearsal/deploylive_fork_deploy.py` | 39 | 0 |
| `script/rehearsal/deploylive_hook_check.sh` | 3 | 0 |
| `script/rehearsal/deploylive_rehearse.py` | 164 | 0 |
| `script/rehearsal/test_deploylive_rehearse.py` | 77 | 0 |
| `script/rehearsal/DEPLOYLIVE_VALIDATION.md` | 106 | 0 |
| **Total** | **1028** | **164** |
