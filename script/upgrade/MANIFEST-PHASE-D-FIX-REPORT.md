# Phase D fix round

Changes are uncommitted. No Git metadata writes, signing, broadcasting, key access, contract-source edits, or protected evidence/fixture edits were performed.

The post-Phase-D ownership controls now probe SP with `setProtocolFee(uint256)` using its current `protocolFeeBPS`. D and a directly impersonated Safe must each revert with the exact `OwnableUnauthorizedAccount(address)` payload identifying the caller. An impersonated timelock must succeed.

For both new A7 and the old `0xEaeC…` aggregator, the controls call `setSlashThreshold(0, currentThreshold)` and `setGuardianSlashBps(currentBps)`. D must revert with the exact `NotSlashPolicyAdmin(D)` payload; the impersonated Safe must succeed. Severity 0 is valid; the setters permit thresholds 2–13 and guardian slash BPS 100–10000. Current values are read from each aggregator independently.

Each new setter probe takes its own snapshot, verifies its authority, checks exact denial payloads and successful authorized receipts, reads the unchanged value back, and reverts the snapshot in `finally`. A post-restoration read checks the value again. Existing ownership and admin read-backs remain enforced. Unit assertions check both aggregators, callers, calldata, exact expected error payloads, and snapshot counts.

Phase D unit tests cover sequence construction and dependency gates only. They do not establish compatibility of the pinned bytecode. Compatibility—including single-step transfer on the committee and exact error selectors/payloads—is established only by the fork rehearsal on the real pin. No fork rehearsal was run in this fix round.

Validation commands:

```sh
python3 -B -m unittest discover -s script/upgrade -p test_manifest_exec.py -q
python3 -B script/upgrade/test_sp_upgrade_exec.py
python3 -B script/a3a/test_a3a_exec.py
FOUNDRY_TEST=script/upgrade /Users/jason/.foundry/bin/forge test \
  --offline --root /tmp/manifest-round2-tree \
  --match-contract ManifestSolvencyTest -vv
```

The existing isolated Solidity tree matches all 59 worktree contract sources byte-for-byte; the manifest test matches except for its temporary import path, and token test sources match. This is the relevant Solidity solvency suite, not the full repository Solidity regression. The signing/sending suite remains excluded because it performs synthetic-key signing, which this task prohibits.

| Suite | Passed | Failed |
| --- | ---: | ---: |
| Manifest Python | 98 | 0 |
| Existing upgrade Python | 141 | 0 |
| A3a executor Python | 93 | 0 |
| Solidity ManifestSolvencyTest, including inherited tests | 9 | 0 |
| Total | 341 | 0 |

All four suites passed. `git diff --check` passed.
