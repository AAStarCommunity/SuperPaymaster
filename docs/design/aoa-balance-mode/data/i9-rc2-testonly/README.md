# I9 on v5.5.0-rc.2 — TEST-ONLY Halmos runs (DSR CC-125 d030f6e8 ②, audit 8b8fd5d8)

Category: `unit-test` (Halmos symbolic execution + forge in-process EVM). No chain was touched.

## Bottom line

| # | contract.check | expected | verdict | runner exit | wall | cleanup |
|---|---|---|---|---|---|---|
| 1 | `SuperPaymasterI9HalmosTest.check_I9_CF3_settleCannotSilentlyFail` (352 B ctx, original) | PASS | **INCONCLUSIVE** (wall cap) | 2 | 605 s | pgid 77385: 0 survivors |
| 2 | `SuperPaymasterI9HalmosTest.check_witness_I9_freshBalanceSettlementReachable` (original) | FAIL | **INCONCLUSIVE** (wall cap) | 2 | 605 s | pgid 28986: 0 survivors |
| 3 | `SuperPaymasterI9Rc2HalmosTest.check_I9_CF3ctx384_settleCannotSilentlyFail` (new, 384 B) | PASS | **INCONCLUSIVE** (wall cap) | 2 | 605 s | pgid 85008: 0 survivors |
| 4 | `SuperPaymasterI9Rc2HalmosTest.check_witness_I9_posCharge352Reachable` (new) | FAIL | **INCONCLUSIVE** (wall cap; 4 counterexamples printed, no result line) | 2 | 605 s | pgid 32505: 0 survivors |
| 5 | `SuperPaymasterI9Rc2HalmosTest.check_witness_I9_posCharge384Reachable` (new) | FAIL | **INCONCLUSIVE** (wall cap; 2 counterexamples printed, no result line) | 2 | 605 s | pgid 94838: 0 survivors |

**No target reached a terminal Halmos result inside its 600 s cap. Nothing here is a PASS or an
ACCEPT, and I9 is NOT discharged on rc.2 by this run.** Halmos exit code -9 = SIGKILL from the
runner's wall cap, not a halmos result.

What the runs do show, without being a verdict:
- Targets 4 and 5 printed `Counterexample:` blocks with **a0 > 0** (e.g. a0 = 0x2000000000000000,
  0x10000000000000000, 2^127; every other parameter 0). Halmos keeps exploring after a valid model
  (no `--early-exit`), so the run still hit the cap before printing `[FAIL]`; the runner correctly
  says INCONCLUSIVE, because a counterexample without the result line + statistics is not the
  required evidence. The first model of each was **replayed concretely** in forge
  (`SuperPaymasterCtxLengthRc2Test.test_replay_witness_posCharge{352,384}_halmosModel`, PASS):
  postOp returns, `settleLocked` is reached, a0 > 0, charge > 0, charge <= a0 — the positive-
  amount fresh-settlement branch IS reachable on rc.2 for both context lengths (on a concrete
  zero pre-state; the Halmos model's symbolic-storage values are not printed, so this is a
  replay of the parameters, not of the full model).
- The machine was heavily loaded (1-min load average 26–134 at the target starts; `0*.load`),
  and another session's D5c-1 Halmos batch (pgid 27307, `run-all-d5c1.sh`) was seen running
  after targets 3, 4 and 5 (`0*.ps-after`). The
  archived pre-rc.2 run of target 2 needed 2881 s; a 600 s cap on this box was always unlikely
  to be enough for the symbolic-gas targets. A longer cap on an idle machine is the obvious
  next step; it was out of scope for this task (cap <= 600 s each).

## What was run, exactly

Clean tree: `git worktree add --detach <dir> 1ac0e1c595dc84e684b540ca6a936168e922194f`
(= `v5.5.0-rc.2^{}`), submodules `contracts/lib/{solady,chainlink-brownie-contracts}` copied from
checkouts at the rc.2 gitlinks, then ONLY these four files checked out from commit `63dda3c0`:
`contracts/test/halmos/SuperPaymasterI9Rc2Halmos.t.sol`, `contracts/test/v2/SuperPaymasterCtxLengthRc2.t.sol`,
`script/halmos/run-i9-witness.py`, `script/halmos/test_run_i9_witness.py`.
`git diff --stat HEAD -- contracts/src` is empty (`PROVENANCE.txt`).

Note on `SuperPaymasterCtxLengthRc2.t.sol`: the Halmos runs compiled the 63dda3c0 version
(sha256 `fcf3ca05…f2f9`); the two replay tests were added after the runs, and `forge-test.log`
ran the final version (sha256 in `PROVENANCE.txt`). That file contains no `check_*` function and
does not feed any Halmos target.

1. `drive.sh` — one fresh `forge build --ast --root . --extra-output storageLayout metadata`
   (halmos' own build command, `00-prebuild.*`, outside every cap), then each target ONCE,
   sequentially: `python3 script/halmos/run-i9-witness.py --wall-cap 600 --solver-timeout-assertion 300s --keep-cache --log <log> --contract <C> --check <c>`
   (exact command per target in `NN-*.cmd`; the halmos argv is in the log header:
   `halmos --contract C --match-test ^<check>\( --loop 2 --solver-timeout-assertion 300s --statistics`).
   `300s` carries an explicit unit (halmos 0.3.3 parses a bare number as ms).
2. `forge.sh` — `forge test --match-path 'contracts/test/v2/SuperPaymaster{CtxLengthRc2,I9Fuzz}.t.sol'`
   (`forge-test.log`, exit 0, 14/14 pass) and the runner's unit tests
   (`runner-unittests.log`, exit 0, 17/17 OK).
3. `prov.sh` — `PROVENANCE.txt`: HEAD, tag, status, tool versions (halmos 0.3.3, Yices 2.6.4,
   forge 1.7.1, solc 0.8.33, Python 3.11.9), sha256 of source / harness / runner / tests.

Per target: `NN-<check>.{cmd,start,end,load,log,stdout,exit,ps-after}`; `.log` is the raw halmos
stdout+stderr with the runner header and trailer (`# pgid`, `# WALL-CAP`, `# exit_code`,
`# VERDICT`); `.stdout` is the runner's own one-line verdict; `.exit` its exit code
(0 ACCEPT / 1 REJECT / 2 INCONCLUSIVE / 3 config error).

Cleanup: the runner SIGTERMs then SIGKILLs its own process group (halmos + yices children) and
reports survivors in the trailer (`# WARNING: pids still alive …` — absent in all five logs).
Independently, `NN-*.ps-after` lists every halmos/yices/z3/bitwuzla process on the box right
after each target: none belongs to any of the five run pgids (every line is another session's
halmos/solver process — pgid 27307, or halmos leaders in their own groups under parent 40153 —
or an unrelated shell whose command line merely contains "halmos"), and a final `ps -A -o pgid=` matched none of them.

## Harness / runner changes this evidence is about

- `SuperPaymasterI9Rc2HalmosTest` inherits the UNCHANGED `SuperPaymasterI9HalmosTest`
  (sha256 `50d945d2…cbb9` = rc.2's file). CF-3 over the 384-byte context keeps every assertion
  bit; word 12 is concrete (GasParams defaults | (500 + 1) << 128, fee snapshot 500 ≠ pinned live
  fee 1000). Witnesses require `a0 > 0` and `lockedCharge > 0`; gas cost / fee per gas are
  concrete (1e12 / 1 gwei) so the charge is decided by a0 alone.
- `run-i9-witness.py` is now expectation-aware (`EXPECTATIONS` table, `--expect`), selects the
  check exactly (`--match-test '^<check>\('` — `--function X` is a prefix regex), and rejects
  a log with more than one result line. Reverse negative controls are real-process tests
  (`test_reverse_control_*`); a mutant that ignores the expectation turns 4 tests red.

### Runner correction after this archive

Halmos 0.3.3 can print `[PASS]` with full statistics and exit 0 even when `--loop 2` cuts
paths. Its `loop-bound` warning says `paths have not been fully explored due to the loop
unrolling bound: 2`; the warning may appear after the result line. The runner now classifies
such a PASS-expected result as **INCONCLUSIVE** (exit 2), never ACCEPT. FAIL-expected witness
verdicts are unchanged. This correction does not change the five archived runs or their logs.
The new judge fixture and fake-Halmos process test both turn red when the check is removed;
see `runner-loop-bound-mutation.txt`. The archived `runner-unittests.log` records the earlier
17/17 result; the corrected runner has 18 judge fixtures.

## Integrity

`shasum -a 256 -c EVIDENCE.sha256` in this directory (covers every file except itself).
