# Manifest executor round 7

Changes remain uncommitted. No Git metadata writes, signing, broadcasting, key access, contract-source edits, or protected evidence/fixture edits were performed.

The fraud fixture now uses a SHA-256-reviewed wrapper with required `toolCommit`, pinned `verifierCommit`, and `export` containing DVT's unchanged wire format. The schema and validator accept checksummed addresses, decimal-string IDs/epoch, a hex signer mask, `forkState`, `valid`, and the ordered N1–N4 `mustReject` array. Unknown fields and altered call/check/expect instructions fail closed.

Production validation requires BLSAggregator-4.12.0, chain 11155111, Registry, derived A7/A12a, the pinned block number and ascending pinned guardians. The export has no block hash; the executor retains its independently authenticated pin. Proof metadata is checked against the ABI payload, the DVT slash-message/evidence hash is reconstructed, and commitment/domain digests are recomputed. The layout-derived storage slot comes only from the independently inspected build layout; the export supplies mapping/key/value/check and cannot supply a slot. Rehearsal reads the commitment through the required view and retains all negative-case checks and restoration checks.

The mock token must match both full runtime keccak `0xae01c0c01f84a229b8c6f3591a70f678ea5d48ff956a90661ae669bf1be6d0db` and CBOR-stripped keccak `0xb4dcef54c1bf03ed09b0c6dcd6b78699d4801a3e6baf044ddd531c72acb74a86`. Owner words at offsets 130 and 210 must be zero, storage slot must be 0, and `isOverIssued()` must resolve to `0xbeaf15d9`.

The real 4.11 sample parses under the isolated `fraud_format_only` helper. Production/build validation refuses it. Synthetic sample-derived 4.12 exports pass schema and semantic checks with A7/A12a substituted. Independent old aggregator, old verifier, and old version mutations are refused, alongside missing commits, altered proof metadata, commitment keys/values/checks, runtime bytes, guardian sets, and negative cases. Address substitution is a schema/binding test; it is not evidence that the sample's historical domain is valid for the new addresses.

## Verification

| Suite | Passed | Failed |
| --- | ---: | ---: |
| Manifest Python | 83 | 0 |
| Existing upgrade Python | 141 | 0 |
| A3a executor Python | 93 | 0 |
| Solidity ManifestSolvencyTest, including inherited tests | 9 | 0 |
| Total | 326 | 0 |

Commands:

```sh
python3 -B -m unittest discover -s script/upgrade -p test_manifest_exec.py -q
python3 -B script/upgrade/test_sp_upgrade_exec.py
python3 -B script/a3a/test_a3a_exec.py
FOUNDRY_TEST=script/upgrade /Users/jason/.foundry/bin/forge test \
  --offline --root /tmp/manifest-round2-tree \
  --match-contract ManifestSolvencyTest -vv
```

All 59 worktree Solidity sources match the existing temporary Solidity test tree byte-for-byte. The manifest test differs only in its temporary import path. `git diff --check` passes. This covers the manifest's relevant Solidity suite, not the full repository Solidity regression. The A3a signing/sending suite is excluded because it performs synthetic-key signing, prohibited for this task.

No live fork rehearsal, signing, broadcast, or release packet was produced. A reviewed 4.12 export for the actual A7/A12a deployment and authenticated fork execution remain necessary to establish live validity.
