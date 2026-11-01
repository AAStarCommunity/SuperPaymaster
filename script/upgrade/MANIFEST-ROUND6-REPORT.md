# Manifest executor round 6

Changes remain uncommitted. No Git metadata writes, signing, broadcasting, key access, contract-source edits or protected evidence edits were performed. The separately appearing untracked `script/upgrade/fixtures/` directory was not created or modified by this work.

## Corrections

- Reviewed A3a plan bytes are SHA-256 checked before frozen historical validation. The A3a validator now supports rebuilding from that plan's recorded commit, using freshly archived artifacts rather than working-tree artifacts. All rebuild fields are compared; there is no exception that skips the rebuild record. Missing historical build prerequisites fail closed. Original A3a execution callers retain their HEAD rebuild policy.
- Every A3a sender nonce from the original pin through the manifest pin (exclusive) must occur exactly once as a planned step or a proven gap. Mined planned transactions must equal their planned fields; gaps use the existing strict plain-transfer proof and must precede the manifest pin. Tests reject an internal nonce 101 hole and a relabeled S1 payload. Direct fake-chain collection and reconciliation cover successful history and noncanonical receipts; collection rejects a wrong Registry version.
- Evidence requires named C1–C9 passes, DVT suites with 7/11/5 passes and explicit Prague execution without skips, named mutation red tests with restored passes, Slither version and acceptance accounting, and per-contract creation hashes. The four manifest mutation controls and all three specified guardian-set controls are required. Tests reject missing or skipped suites/controls even with positive aggregate totals.
- An isolated archive of DVT `72aca4fa0ba4aaa8c8a96210b1124534431294d6` rebuilt successfully offline with Forge 1.7.1 and solc 0.8.33. The mock runtime hash is pinned to `0xae01c0c01f84a229b8c6f3591a70f678ea5d48ff956a90661ae669bf1be6d0db`. This is the raw runtime with immutable owner zero. No placeholder remains. The drill explicitly reads `isOverIssued()` false before N2 and true after its storage change, before submission. Tests also cover the drill's message-hash failure.
- The executor records full and CBOR-stripped creation hashes for all ten SP artifacts and the separately rebuilt verifier. Reproducible-build evidence must list both hashes for all eleven. Executable differences fail; metadata-only differences appear in `rebuild.metadataOnlyDifferences`. The verifier rebuild reproduced full hash `0x736520628b9e5ed4163f440e4e7b5d064b4e4cb4571c29d926941964e038e3ab` and stripped hash `0x697b97795dfc4547e615c048a5583d31f4c7f9a969b53d85d5ecb9e42e218d54`.
- README explains why B2's off-chain observation is acceptable: extra tokens only increase backing before 6d under the enforced paused state.

## Verification

| Suite | Passed | Failed |
| --- | ---: | ---: |
| Manifest Python | 81 | 0 |
| Existing upgrade Python | 141 | 0 |
| A3a executor Python | 93 | 0 |
| Solidity ManifestSolvencyTest, including inherited tests | 9 | 0 |
| Total | 324 | 0 |

Commands:

```sh
python3 -B -m unittest discover -s script/upgrade -q
python3 -B script/a3a/test_a3a_exec.py
FOUNDRY_TEST=script/upgrade /Users/jason/.foundry/bin/forge test \
  --offline --root /tmp/manifest-round2-tree \
  --match-contract ManifestSolvencyTest -vv
```

All 59 worktree Solidity sources match the temporary Solidity test tree byte-for-byte. `git diff --check` passes. This is the manifest's relevant Solidity suite, not the entire repository Solidity regression. The A3a signing/sending suite was not run because it performs synthetic-key signing, forbidden for this task.

No real amended A3a plan or complete release evidence was supplied for an integration run. Historical rebuild validation is implemented and tested at its compiler boundary, not claimed as an actual supplied-plan re-proof. No live fork rehearsal or release packet was produced. Synthetic fake-chain tests do not establish real fraud-proof validity. Production packet generation still requires the reviewed inputs, available historical build dependencies, a clean tagged tree and authenticated fork execution.
