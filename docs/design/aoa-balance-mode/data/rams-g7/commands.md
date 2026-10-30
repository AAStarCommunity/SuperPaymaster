# Offline commands and evidence provenance

Engine: `/Users/jason/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge`,
1.8.7-nightly, commit `4e8874b2bdc840929585ca73e170993c50a4a531`.
No network, no source contract / deployment script / Foundry configuration changes, no commit or push.

Common flags for full runs: `test --offline --no-isolate --fuzz-seed 0x5eed -vv`.
Cancun uses the default compile/runtime target. Prague adds `--evm-version prague`.
Amsterdam adds `--evm-version prague --hardfork amsterdam`.
Inline test configuration (including G2 isolation and fuzz runs) is honored by Forge.

- `amsterdam-before.log`: byte-for-byte copy of user-supplied `.ams-baseline.log` (not a new baseline run).
- `cancun-before.log`: full run, no test edits when invoked; normal `out`/`cache`.
- `prague-before.log`: full run, no test edits when invoked; `FOUNDRY_OUT=out-g7-prague-before FOUNDRY_CACHE_PATH=cache-g7-prague-before`. Compilation inputs were loaded before edits; existing normal `out` supplied hard-coded artifact reads.
- `amsterdam.log`: final full run, `FOUNDRY_OUT=out-g7-after FOUNDRY_CACHE_PATH=cache-g7-after`.
- `prague.log`: final full run, `FOUNDRY_OUT=out-g7-prague-before FOUNDRY_CACHE_PATH=cache-g7-prague-before`.
- `cancun.log`: final full run, normal `out`/`cache`.
- `*-first-pass.log`: intermediate diagnostic full runs, NOT final acceptance evidence.
- `diagnostic-traces.log`: Amsterdam flags, `-vvvv --match-test 'test_rule_under_all_floor_params|test_G2_coverage_replay_fixed_seeds'`, after deployment params/budgets, before the EX_OK call-gas fix and logging-underflow fix.
- `mutations.log`: Amsterdam flags, `--match-test '^test_mutation_'`; temporary `contracts/test/v2/G7Mutations.t.sol`, preserved as `G7Mutations.t.sol.txt`. The first G2 mutation lacked the inline isolation annotation and stopped at StillLive; not accepted as assertion-liveness evidence.
- `mutation-g2-isolated.log`: same, `--match-test '^test_mutation_G2'`, with the isolation annotation present in the preserved source. See report for the limits of this control.
- `mutation-old-budgets-probe.log`: Amsterdam flags, `-vvvv --match-test 'test_balance_mode_end_to_end|test_G_wrap_bound_canonical_entrypoint'`. Temporary changes: shared PM_VERIFICATION = 700_000; probe lastPassedGas/callCount initializers = 0, calls() returns callCount; GasTest MIN_POST_OP_GAS = 200_000. Restored afterwards. Recorded before the new explicit bundle probe-completion assertion, to reproduce the exact original 184136 failure.

Temporary mutation test sources are absent from the final suite. Logs contain local test keys/addresses only (Forge redacts private keys in traces). No live RPC calibration was repeated: the user-specified calibrated engine was used.

`mechanism-g2-trace.log.gz`: unmutated final Amsterdam replay, `--match-test test_G2_coverage_replay_fixed_seeds -vvvv`; `mechanism-g2-trace.log` is an explicitly labeled tail excerpt with the raw SHA256 and original line range. The full raw trace is compressed because it is 132 MB. Final fuzz failures can replay Foundry cached counterexamples (as recorded in the logs).

## Large traces kept outside git

`diagnostic-traces.log` (8.3 MB; its raw sha256 stays in `checksums.sha256`) and `mechanism-g2-trace.log.gz`
(8.4 MB) are not committed. They are stored outside the repository; `external-traces.sha256` gives the sha256 of
the stored files (`diagnostic-traces.log.gz` is the gzip of the raw log). Both are regenerable with the commands
above. `mechanism-g2-trace.log` (the labelled excerpt quoted in REPORT.md) is committed.
