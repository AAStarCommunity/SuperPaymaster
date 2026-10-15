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

## Known limitations (stated, not resolved)

1. **Skipped build artifacts.** Every log carries `Skipped <Name>.{default,registry-size}.json due to parsing failure` (151 distinct names, `SKIPPED-ARTIFACTS.tsv`). These are the per-profile variants that `compilation_restrictions` emit into the shared `out/`. The plain `<Name>.json` exists for the contracts under test (`SuperPaymaster.json`, the I9 harness and probe). Some names have only a skipped variant (e.g. `Clones`, `AggregatorV3Interface`, forge-std helpers). These are libraries, interfaces or test utilities whose code reaches the symbolic run through the harness's own creation bytecode. **We believe** halmos uses these artifacts only for name and label resolution, but we have not proven that the skips cannot affect the explored state space. This is recorded here as a limitation.
2. **`unknown deployed bytecode`** (one warning per log): halmos could not map one deployed contract to an artifact name. This affects trace labels. DSR raised the same class of warning in its 10-09 diagnosis.
3. **Bounded:** `--loop 2`, a 300 s per-query solver timeout, and the harness's concrete choices (documented in the harness and in `D5c-2-halmos.md` §2). PASS here means no counterexample within these bounds. It is not an unbounded proof.
4. The witnesses' counterexamples are Halmos models. Their concrete forge replay (`SuperPaymasterCtxLengthRc2Test.test_replay_witness_posCharge{352,384}_halmosModel`) replays the parameters on a zero pre-state, not the full symbolic storage model.

## Integrity

`shasum -a 256 -c EVIDENCE.sha256` in this directory. Paths under the session scratch directory are replaced by `$SCRATCH`, home by `~`, hostname by `<host>`.

A2/A2a acceptance and any claim-ledger change (C-13b / D12-I9-FT) are DSR's decision. A3a remains NO-GO.
