# A6 offline review

Run from the worktree root with Node and `viem` installed:

```sh
node script/a6-collector/offline-review/run.mjs
```

This runs all three checks sequentially without RPC access:

- `check.mjs`: current archive positive control, every emitted passport leaf deleted independently, original tampering controls, collector argument gates, and tracked archives outside this generated fixture directory. `results.tsv`, `archives.tsv`, and `passport-fields.txt` are regenerated.
- `check-library.mjs`: valid success/postOp conservation, missing-lock evaluation, independent reservation, inflight state, persistent validation writes, unchanged xPNTs/supply, both lock identity topics, and source citations.
- `check-round2.mjs`: 57 JSONL mutations of the current positive/N=50/drop-op archive. Every mutation must exit **0** under the round-2 comparator and **1, 2, or 3** under the fixed validator. `round2-results.tsv` records each rejection reason. A valid synthetic postOp branch and inflight regressions are also checked.

`validate-old.mjs` is the immutable round-1 comparator, pinned by SHA256 in `check-library.mjs`. It is intentionally unrelated to the moving HEAD. `validate-round2-old.mjs` is the validator before this repair, SHA256 `8bab958d2675c3b37696fd775fd19f4d973b90d168eb8208e5ea4b5fd5a0e1fa`, matching the current archive's recorded validator source hash. Neither snapshot is used in production validation.

The round-2 rules bind each arm's paymaster to both the packed operation and passport, require the expected packed operation in its bundle, and require distinct paymasters, transactions, and op hashes within each triplet. Extra EntryPoint UserOperationEvents stay in the raw logs and are copied into the validator report. Non-fixture receipts containing extra operations are rejected because aggregate deposit deltas cannot be attributed by this single-op gauge. Deliberate drop-op/wrong-hash fixtures remain consistent failures and cannot match triplets.

RPC identity is parsed as scheme, host, and effective port. Loopback aliases (`localhost`, `127.0.0.1`, `[::1]`) share an identity; credentials, paths, queries, and fragments cannot manufacture distinct endpoints. A count-50 run is accepted only when conformance is recomputed true, even if its recorded conformance flag is false. Small positive mechanism checks remain accepted with conformance false. Counts must be positive integers; conformance requires exactly 50.

Both passports require typed, non-empty config leaves, including the local override flag. EntryPoint address/code/arm bindings, canonical-address flag, account sender, token and SP references must agree. Rows must bind to those addresses and passport gas/callData. Success locks bind user/locker to sender/SP. Failed postOp checks preserve `totalSpent += a0`, the inflight reservation and lock, while user xPNTs, supply, sponsorship count, and revenue remain unchanged.

The local chain archive was **not regenerated**: the existing `a6-gauge/1` fields contain all evidence needed for the new checks. Generated offline fixtures use the current archive directly; no missing transaction fields are invented. Archived JSONL, reports, setup logs, README, redacted signer key, and `EVIDENCE.sha256` remain unchanged. Positive and N=50 still validate with exit 0. The archive is local mechanism evidence; its proxy endpoints share one Anvil and do not prove provider independence or canonical EntryPoint deployment.
