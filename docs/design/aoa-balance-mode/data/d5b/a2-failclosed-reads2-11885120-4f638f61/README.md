# A2 fail-closed reads: final local-fork evidence

- Script commit: `4f638f61cd238d418e38c342d792da7c3836523e`.
- Baseline: PR #464 head `554e956e3e2927b37bb56bb6b79aef4d96be97bd`.
- Sepolia fork block: `11885120`; final local fork head: `11885271`.
- Execution: `a2-full-rehearsal.sh <env-file> 11885120 <this-directory> all`, with all writes confined to a local Anvil fork on `127.0.0.1`.
- Result: exit `0`; **370 CHECK PASS, 0 CHECK FAIL, 0 failure lines, 0 live READ FAILED**. The fork ledger contains 120 mined transactions. The rehearsal's 65 expected negative controls all reverted: **55 exact revert-data matches and 10 regex matches** (`neg-controls.jsonl`). The text `READ-FAILED` appears in expected negative-control descriptions and positive CHECK labels; no read failure occurred in the run.

## Changes

The script now validates the fork ledger transaction list, every receipt and transaction projection, typed transaction hashes/addresses/statuses, and an independent transaction count per block. It validates SP getter snapshots and the pre-state compound tuples by field type, checks every Stage C storage read, and refuses missing or ill-typed dummy runtime hashes. A missing final rehearsal log fails the tally. It no longer writes endpoint B's URL into the cross-check log. The earlier archive at head `554e956e` was not rewritten; PR-Daemon reported that its endpoint URL was keyless and found no keyed URLs or private keys there.

The existing read-failclosed harness now redacts every HTTP(S) URL portably and fails if a URL remains. The full rehearsal removes its `.rv.err`, `.rb.err`, and `.xr.err` scratch files on exit. Eight equivalent scratch files produced by the segment harness were removed before this archive was sealed.

## Old/new segment controls

`negctl-review/negctl-table.tsv` records actual exit codes from executable segments extracted from the baseline and final committed scripts. Each row injects the same local fault into both versions. The 14 rows with `0 → 1` demonstrate former fail-open paths; the `rb` and command-substitution rows extend coverage of already-fail-closed paths. These are segment tests, not claims that the entire old and new rehearsals were rerun for every injection.

| Injected case | Old exit | New exit |
| --- | ---: | ---: |
| Pre-state operator tuple malformed | 0 | 1 |
| SP getter address ill-typed | 0 | 1 |
| Snapshot address ill-typed | 0 | 1 |
| Stage C before-slot read fails | 0 | 1 |
| Stage C after-slot read fails | 0 | 1 |
| Dummy runtime jq read missing | 0 | 1 |
| Ledger list omits a transaction | 0 | 1 |
| Ledger transaction read fails | 0 | 1 |
| Ledger receipt status ill-typed | 0 | 1 |
| Ledger sender address ill-typed | 0 | 1 |
| Ledger independent count differs | 0 | 1 |
| `rb` address ill-typed | 1 | 1 |
| `rv` fail only inside `$(...)` | 1 | 1 |
| Final rehearsal log missing | 0 | 1 |
| Endpoint B URL written | 0 | 1 |
| Public-node URL survives redaction | 0 | 1 |

The final run also exercised D0's getter-snapshot and storage-read negative controls on the local fork. An earlier failed attempt at block `11884900` exposed stale D0 expected-text assertions; it is excluded from this archive. The final script was committed before this fresh run and was not changed while it ran.

## Archive checks

All HTTP(S) URLs in generated evidence were replaced with `<redacted-rpc>` before hashing. `URL-redaction-summary.txt` records 74 files redacted and zero remaining URL-bearing files. `sensitive-scan-summary.txt` records a scan of the environment file's non-empty values: 12 secret or endpoint values had zero archive matches; public addresses and chain IDs remain as evidence. JSON and JSONL parsing passed after redaction.

`EVIDENCE.sha256` covers every archive file except the manifest itself, whose self-hash cannot be included. Verification result: **231/231 files matched**.
