# Manifest executor round 8

Changes remain uncommitted. No Git metadata writes, signing, broadcasting, key access, contract-source edits, or protected evidence/fixture edits were performed.

Historical A3a builds request AST/build-info and resolve immutable identities inside the archived compile tree. Source metadata is authenticated against that archive, including archived dependencies, before the temporary tree is removed. The default path retains current-HEAD/worktree source checks and local build-info resolution. The replacement historical test runs real plan/artifact/rebuild validation against a fixture tar archive with a synthetic compiler-output boundary. It proves an empty checkout without build-info passes, changed checkout sources do not affect the result, and tampered historical source metadata is refused. It also preserves the historical transaction-tampering check.

The early-swap control runs before A17, after A15 has drained balances. It checks tracked == revenue <= buffer, snapshots state, requeues the pending capped token with a fresh future ETA, checks the premature transaction's InvalidConfiguration revert, and executes the same transaction successfully after ETA. Token and pending-state readbacks confirm success; the outer snapshot restores everything. No original-S7 pin-expiration check remains. Tests cover early/late pins, restoration on success and failure, invalid accounting, wrong revert reason, and a missing ETA guard.

Direct tests exercise both DVT rebuild hash gates. Independently bypassing dvt_rebuilt_creation or dvt_mock_rebuilt_runtime makes its test fail; restored gates pass.

| Suite | Passed | Failed |
| --- | ---: | ---: |
| Manifest Python | 90 | 0 |
| Existing upgrade Python | 141 | 0 |
| A3a executor Python | 93 | 0 |
| Solidity ManifestSolvencyTest, including inherited tests | 9 | 0 |
| Total | 333 | 0 |

Commands:

```sh
python3 -B -m unittest discover -s script/upgrade -p test_manifest_exec.py -q
python3 -B script/upgrade/test_sp_upgrade_exec.py
python3 -B script/a3a/test_a3a_exec.py
FOUNDRY_TEST=script/upgrade /Users/jason/.foundry/bin/forge test \
  --offline --root /tmp/manifest-round2-tree \
  --match-contract ManifestSolvencyTest -vv
```

All 59 worktree Solidity sources match the temporary test tree byte-for-byte. The manifest Solidity test differs only in its temporary import path. This is the relevant Solidity suite, not the full repository Solidity regression. The A3a signing/sending suite remains excluded because it performs synthetic-key signing, prohibited for this task. No live fork rehearsal was run. `git diff --check` passes.
