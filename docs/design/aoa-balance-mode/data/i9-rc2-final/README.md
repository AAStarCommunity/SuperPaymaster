# I9 on v5.5.0-rc.2: all five Halmos targets reach their expected terminal result (CC-125 d030f6e8 ②, 15beee0b)

Category: `unit-test` (bounded symbolic execution with Halmos, plus forge in-process EVM). No chain was touched. **This is not an independent audit and not public-chain evidence.**

## Bottom line

| # | contract.check | role | expected | runner verdict | halmos result line | wall |
|---|---|---|---|---|---|---|
| 1 | `SuperPaymasterI9HalmosTest.check_I9_CF3_settleCannotSilentlyFail` | **CF-3 / I9 property**, 352-byte context | PASS | **ACCEPT** | `[PASS]` paths 1502, 55.80 s, `bounds: []` | 74 s |
| 2 | `SuperPaymasterI9HalmosTest.check_witness_I9_freshBalanceSettlementReachable` | original reachability witness | FAIL+cex | **ACCEPT** | `[FAIL]` paths 478, 3117.27 s (models 2631.27 s), counterexamples printed | 3136 s |
| 3 | `SuperPaymasterI9Rc2HalmosTest.check_I9_CF3ctx384_settleCannotSilentlyFail` | **CF-3 / I9 property**, 384-byte fee-snapshot context (#442) | PASS | **ACCEPT** | `[PASS]` paths 1491, 72.25 s, `bounds: []` | 91 s |
| 4 | `SuperPaymasterI9Rc2HalmosTest.check_witness_I9_posCharge352Reachable` | positive-amount witness (a0 > 0, charge > 0), 352 B | FAIL+cex | **ACCEPT** | `[FAIL]` paths 539, 1528.53 s, counterexamples printed | 1547 s |
| 5 | `SuperPaymasterI9Rc2HalmosTest.check_witness_I9_posCharge384Reachable` | positive-amount witness, 384 B | FAIL+cex | **ACCEPT** | `[FAIL]` paths 286, 1517.11 s, counterexamples printed | 1538 s |

Runner exit codes are all 0 (ACCEPT). The process groups had no survivors (no `still alive` line in any trailer). The runner is the expectation-aware `run-i9-witness.py` from #463/#464. **A PASS-expected target is downgraded to INCONCLUSIVE when the loop-unrolling-bound warning appears**; that warning (`paths have not been fully explored due to the loop unrolling bound`) is **absent** from every log. The only `loop` text in the logs is the `--loop 2` argument on the command line.

The three rows the reviewer asked to keep separate (15beee0b):

- **CF-3 property (I9 body):** rows 1 and 3. PASS under `--loop 2`, `bounds: []`, no loop-bound warning.
- **Reachability witnesses:** rows 2, 4 and 5. They are FAIL by design: the counterexample shows the fresh-BALANCE settlement path is reachable. Rows 4 and 5 force a0 > 0 and charge > 0.
- **EntryPoint-level fuzz:** `forge-test.log`. `SuperPaymasterI9Fuzz` at `--fuzz-runs 10000` plus `SuperPaymasterCtxLengthRc2` (351/353/383/385-byte lengths rejected, 352/384 accepted): **14 passed, 0 failed**. This is finite random testing, not a proof.

Earlier INCONCLUSIVE results (#463, DSR runs on 10-09/10-10) were wall-cap kills on a heavily loaded host. On this run CF-3 took about 1 minute.

## What was run

- Clean detached worktree of `1ac0e1c595dc84e684b540ca6a936168e922194f` (= `v5.5.0-rc.2^{}`). Submodules were copied from checkouts at the rc.2 gitlinks; see `SUBMODULE-PROVENANCE.txt`: every source HEAD equals the gitlink, the sources are clean, and file-level `diff -r` is empty except two empty nested `lib/` directories under `standards/`, which are never referenced. Only four files are overlaid, all byte-identical to feat `72bd595d`: `SuperPaymasterI9Rc2Halmos.t.sol`, `SuperPaymasterCtxLengthRc2.t.sol`, `run-i9-witness.py`, `test_run_i9_witness.py`. `contracts/src` diff is empty (`PROVENANCE.txt`).
- `drive.sh` does one `forge build --ast --extra-output storageLayout metadata` outside any cap. It then runs each target **once, sequentially**: `python3 script/halmos/run-i9-witness.py --wall-cap 14400 --solver-timeout-assertion 300s --keep-cache --contract <C> --check <c>`. The halmos argv, logged in each header, is `--match-test '^<check>\(' --loop 2 --solver-timeout-assertion 300s --statistics`. Exact commands are in `run/NN-*.cmd`.
- Afterwards, on the same tree: `forge test --match-path 'contracts/test/v2/SuperPaymaster{CtxLengthRc2,I9Fuzz}.t.sol' --fuzz-runs 10000` (`run/forge-test.log`, exit 0) and `python3 script/halmos/test_run_i9_witness.py` (`run/runner-unittests.log`, 18/18 OK).
- Load during the I9 window is in `run/load-during-i9.log` (1-min samples). The host is 10 cores. Halmos' own solver fan-out pushed load above 200 during the witness targets. The wall cap was never approached: the longest target took 3136 s of a 14400 s cap.

## Warnings in the logs, explained with evidence

1. **`Skipped <file>.json due to parsing failure` (194 per log).** Every one of the 194 has the same cause: `ValueError: ('duplicate contract names in the same file', …)` (`SKIPPED-ARTIFACTS.tsv`). `compilation_restrictions` make forge emit several profile variants of one contract into the same `out/<File>.sol/` directory, such as `X.json`, `X.default.json` and `X.registry-size.json`. Halmos 0.3.3 keys artifacts by the name before the first dot, keeps the first variant it reads and skips the rest as duplicates. `KEPT-VARIANTS.tsv` lists, for each of the 198 affected (directory, contract) pairs, the variant that was kept. **An earlier draft of this README said that the plain `SuperPaymaster.json` was the one loaded. That was wrong.** For `SuperPaymaster`, halmos kept `SuperPaymaster.registry-size.json` (optimizer runs 200, 13,335 B runtime) and skipped the plain `SuperPaymaster.json` (runs 500, 13,745 B runtime, the release profile). Five pairs have no kept variant (`IFraudProofVerifier`, and `MockRegistryV2`, `MockAgentIdentityRegistry`, `MockXPNTsFactory` in unrelated test files). None of them is used by the I9 harnesses. The two harness artifacts (`SuperPaymasterI9HalmosTest`, `SuperPaymasterI9Rc2HalmosTest`) were not skipped.
2. **The code that was executed is the release-profile `SuperPaymaster`.** The harness deploys SuperPaymaster with `new`, so the executed bytecode is the creation code embedded in the harness artifact, not the label map. Checked: a runtime window and the creation-code prefix of the plain `SuperPaymaster.json` (runs 500) occur in the bytecode of both harness artifacts (`SuperPaymasterI9HalmosTest.json`, `SuperPaymasterI9Rc2HalmosTest.json`). The registry-size variant's do not.
3. **`unknown deployed bytecode` (one per log) is that same SuperPaymaster.** The bytecode printed under the warning starts with exactly the runtime of the plain `SuperPaymaster.json`, and not that of the registry-size variant. The prefix is identical in all five logs. Halmos could not name it because its label map kept the other variant. **Effect: trace labels only.** We do not claim halmos uses skipped artifacts for nothing else at all; we state what was checked.
4. **`Missing dependencies … git clone … failed` and `revision mismatch … found 1ac0e1c5` (prebuild and each log header).** The submodules were copied without `.git`. Forge then tries to clone into the already-populated directories, which fails and leaves the copies untouched. It also reads the parent repository's HEAD (`1ac0e1c5`) as the submodule revision. The copies themselves are proven equal to the rc.2 gitlinks in `SUBMODULE-PROVENANCE.txt`, which now also lists the two empty nested `lib/` directories by path.

## Known limitations (stated, not resolved)

1. **Bounded:** `--loop 2`, a 300 s per-query solver timeout, and the harness's concrete choices (see the harness and `D5c-2-halmos.md` §2). PASS means no counterexample within these bounds. It is not an unbounded proof.
2. The witness counterexamples are Halmos models. Their concrete forge replay (`SuperPaymasterCtxLengthRc2Test.test_replay_witness_posCharge{352,384}_halmosModel`, PASS in `run/forge-test.log`) replays the parameters on a zero pre-state, not the full symbolic storage model.
3. **Re-judging the archived logs:** the runner judges halmos output *before* it writes its trailer, and the trailer repeats the result line. Run `judge()` on the text before `# VERDICT:`. Run on the complete file, it reports REJECT (`more than one halmos result line`). That is a runner property, not a different verdict. Re-run by the SP main session with the archived runner: all five prefixes give ACCEPT (exit 0), and all five complete files give REJECT (exit 1).

## Integrity

`shasum -a 256 -c EVIDENCE.sha256` in this directory. Paths under the session scratch directory are replaced by `$SCRATCH`, home by `~`, hostname by `<host>`.

A2/A2a acceptance and any claim-ledger change (C-13b / D12-I9-FT) are DSR's decision. A3a remains NO-GO.
