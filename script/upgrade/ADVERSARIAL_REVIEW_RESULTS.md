# Old-owner adversarial-review fixes — 2026-11-04

Base HEAD: `e4a5ea20`. Offline; no transactions or commits.

All four findings are addressed in `old_owner_isolation.py`:

- Config history shares the grant/revoke bounded/bisected getLogs reader, 1000-row saturation gate and disjoint partition comparison. Both endpoint transcripts replay these checks. The regression drops a config event for a custom role whose config owner is OLD; it STOPs before the omitted role can escape discovery. Consistent omission across all partitions and both providers is not detectable by this check.
- Both Registry and SuperPaymaster proxy runtimes are checked independently of their slot-selected implementations against ERC1967Proxy at `cf26915e032ccc9e8e02f9aaf3769afd4335027e`. The offline full default-profile rebuild used Forge 1.7.1, solc 0.8.33, optimizer 500, via IR, Cancun, bytecodeHash none. Both supplied runtimes match all 100 bytes, including metadata; there are no compiler immutable ranges. Runtime SHA-256: `3f4dbc5dc73f561246d40078415688e2e6d7d269ecd1888a2744534a466e7afe`.
- Every masked address-typed immutable requires an independently supplied expectation. Unknown address names STOP at `old_owner_immutable_expectation_missing`. Non-address values remain recorded even without an expectation.
- Deployment-record claims now require a committed record read from HEAD and verified by SHA-256, its resolved source commit, and a successful receipt with the expected transaction hash and implementation address. APNTsCapped has a validated committed A3a plan plus S3 receipt. Local broadcast files are absent from Git history, so their targets now explicitly claim behavioral-equivalence. Registry retains behavioral-equivalence. SP's real CREATE is `0xc73a1f1ba653a0691427e547b935c4ba35d47ba30a7d6aa3cda13741015c3fcf`; the transactions array swaps its hash with upgradeToAndCall.

Evidence:

- [Proxy rebuild and supplied pinned code/slots](fixtures/old-owner/proxy-parity.json)
- [Local broadcast hashes, receipts and SP discrepancy](fixtures/old-owner/broadcast-provenance.json)
- [Updated source input and APNTsCapped record references](fixtures/old-owner/deployed-sources.json)
- [Every gate-removal outcome](fixtures/old-owner/adversarial-probes.json)

Gate-removal outcomes for the four fixes:

| Control | Gate enabled | Gate removed |
|---|---|---|
| Dropped custom config event, primary and secondary | STOP: `old_owner_log_partition` | Accepted, both trials |
| Saturated single-block config page | STOP: `old_owner_log_limit` | Accepted |
| Extra selector in either proxy; implementation untouched | STOP: `old_owner_runtime_length` | Runtime parity still catches it; removing both runtime checks admits it |
| Unknown address immutable with a non-OLD value | STOP: `old_owner_immutable_expectation_missing` | Accepted |
| Incorrect record SHA-256 | STOP: `old_owner_record_sha256` | Accepted |
| Reference commit mismatch | STOP: `old_owner_record_commit` | Accepted |
| Record's actual commit mismatch | STOP: `old_owner_record_source_commit` | Accepted |
| Wrong record address | STOP: `old_owner_record_address` | Plan address gate catches it |
| Wrong receipt transaction hash | STOP: `old_owner_record_receipt` | Structural IndexError |
| Missing claimed deployment record | STOP: `old_owner_record_required` | Structural TypeError |

Total: 102 removal trials, 67 accepted, 31 caught elsewhere, 4 structural errors (including 2 pre-existing structural probes). Structural errors are not successful bypasses or proof of an independent validation gate.

Suite commands were run from the repository root. Final results follow below.

```text
python3 script/upgrade/test_old_owner_isolation.py
Ran 39 tests in 5.404s

OK (skipped=2)

python3 script/upgrade/test_manifest_exec.py
Ran 231 tests in 294.067s

OK (skipped=2)

python3 script/a3a/test_a3a_exec.py
Ran 102 tests in 3.258s

OK

python3 script/a3a/test_a3a_send.py
Ran 73 tests in 32.304s

OK

git diff --check: PASS
```

All commands exited 0. The two skips in old-owner and manifest require opt-in
hydrated local forks. No live isolation certificate is claimed. Logs and hashes
are retained in `fixtures/old-owner/adversarial-suite-results.json`.
