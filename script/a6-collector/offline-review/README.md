# A6 offline review

Run from the worktree root with Node and `viem` installed:

```sh
node script/a6-collector/offline-review/run.mjs
```

This runs all five checks sequentially without RPC access:

- `check.mjs`: archive-derived offline positive control, every emitted passport leaf deleted independently, original tampering controls, collector argument gates, and tracked archives outside this generated fixture directory. `results.tsv`, `archives.tsv`, and `passport-fields.txt` are regenerated.
- `check-library.mjs`: valid success/postOp conservation, missing-lock evaluation, independent reservation, inflight state, persistent validation writes, unchanged xPNTs/supply, both lock identity topics, and source citations.
- `check-round2.mjs`: 57 JSONL mutations of the current positive/N=50/drop-op archive. Every mutation must exit **0** under the round-2 comparator and **1, 2, or 3** under the fixed validator. `round2-results.tsv` records each rejection reason. A valid synthetic postOp branch and inflight regressions are also checked.

`validate-old.mjs` is the immutable round-1 comparator, pinned by SHA256 in `check-library.mjs`. It is intentionally unrelated to the moving HEAD. `validate-round2-old.mjs` is the validator before this repair, SHA256 `8bab958d2675c3b37696fd775fd19f4d973b90d168eb8208e5ea4b5fd5a0e1fa`, matching the current archive's recorded validator source hash. Neither snapshot is used in production validation.

The round-2 rules bind each arm's paymaster to both the packed operation and passport, require the expected packed operation in its bundle, and require distinct paymasters, transactions, and op hashes within each triplet. Extra EntryPoint UserOperationEvents stay in the raw logs and are copied into the validator report. Non-fixture receipts containing extra operations are rejected because aggregate deposit deltas cannot be attributed by this single-op gauge. Deliberate drop-op/wrong-hash fixtures remain consistent failures and cannot match triplets.

RPC identity uses normalized host and effective port, ignoring transport and URL decoration. Distinct provider identities require different non-loopback hosts. Different ports on the same/local host require the recorded `allowSameEndpointLocal` override, which disqualifies conformance. Loopback aliases (`localhost`, `localhost.`, `*.localhost`, `127.0.0.0/8`, `[::1]`, IPv4-mapped IPv6 loopback, `0.0.0.0`) share an identity; credentials, paths, queries, and fragments cannot manufacture distinct endpoints. A count-50 run is accepted only when conformance is recomputed true, even if its recorded conformance flag is false. Small local mechanism checks require the explicit override and different ports; they remain nonconformant. Counts must be positive integers; conformance requires exactly 50.

Both passports require typed, non-empty config leaves, including the local override flag. EntryPoint address/code/arm bindings, canonical-address flag, account sender, token and SP references must agree. Rows must bind to those addresses and passport gas/callData. Success locks bind user/locker to sender/SP. Failed postOp checks preserve `totalSpent += a0`, the inflight reservation and lock, while user xPNTs, supply, sponsorship count, and revenue remain unchanged.

The local chain archive is preserved byte-for-byte. Round 4 requires an operator-balance readback at each passport's exact block hash. The existing end passport is at the final TPM block, but its readback has no `operatorBalance`. The newly instrumented collector reads this field for **every arm**. Current ordered archive exits (positive / exec-revert / drop-op / wrong-hash / tamper-B / conservation-injected / missing-field / N=50) are **2/2/2/2/2/1/2/2**, versus the expected pre-repair **0/3/3/3/2/1/2/3**. See `round4-archives.tsv`. Missing end-block evidence is reported, never reconstructed in archive validation.

Offline controls use `a.invalid` / `b.invalid` labels only; no endpoints are contacted. Round-3 and round-4 conformance fixtures clear the local override at both passports and run_start, and explicitly set N=50 conformance true. `synthetic-anchors.mjs` adds the missing end-block operator-balance field to **test fixtures only**, using the known separate-arm synthetic scenario. These fixtures are not provider evidence or regenerated archives. Round-2 override controls toggle the existing value so they cannot become no-ops when an archive changes.

Round 3 adds `check-round3.mjs` and `round3-results.tsv`: each tampered JSONL must exit 0 under the frozen `validate-round3-old.mjs` and reject under the current validator. The comparator SHA256 is `a6eccc76bc7c6f71a8edaa3c7dd79bffd1be0f6598739acafbbf25f665ce0598`. Valid synthetic credit and local-override records are also exercised.

Run-wide transaction/op/block uniqueness prevents triplet replay. Each before block must equal the preceding after block, anchored at the start passport. Deposits are tracked per arm; persistent SP balances/counters must equal the preceding SP after values, since the other arms use separate paymasters and tokens. `lockXLocked`, `inflightA0`, and `inflightOperator` are op-hash-specific and start empty for each new op; this expected change from a previous failed op is checked by the per-row reservation rules. No unexplained state delta is allowed.

Only `fixture === null` means no fixture; all counting and fixture exclusions use that predicate. Success requires cleared inflight operator/a0; balance settlement preserves debts/credit reservations and binds LockSettled user/hash to LockCreated user/hash/locker (LockSettled has no locker topic). Credit settlement checks reservation bounds, totalSpent, reserved/settled identities and debt bounds. Failed postOp requires no settlement events and unchanged debt/reservations. Collector conservation mirrors these checks while validator decoding remains independent.

End passports must retain chainId and be at or after the last attempt block. At equal height the hash must match; at a later height the hash must differ. Equality is necessary because the collector takes its end passport at the final mined block (e.g. N=50 block 336); a strictly greater height would reject the collector's own output. `run_end.exitCode` must equal `stop.code`.

Round 4 adds `check-round4.mjs`, frozen `validate-round4-old.mjs` (SHA256 checked by the harness), and `round4-results.tsv`. Every new tampering control requires old exit 0, new rejection, and the specific rejection reason. Already-rejected IPv4 unspecified addresses remain a separate old=1/new=1 regression. The controls cover malformed DNS and IPv6 unspecified hosts, cross-arm and cross-attempt nonce reuse/decrease, each sponsorship flag and stale quote, both passport balances and missing same-hash anchor, sponsorship cost/fee consistency, balance-lock bounds/rate/available balance, both packed tails, and both block checks without a UOE. Independent nonce keys remain valid.

Rules were checked using `git show 1ac0e1c5:<path>`, with line assertions in the harness:

| Finding | Pinned source / rule |
| --- | --- |
| 1. Endpoint identity | Gauge provider-independence rule; no Solidity endpoint concept. URL parsing plus DNS-label validation; unspecified IPv4/IPv6 share loopback identity. |
| 2. Nonce | `singleton-paymaster/lib/account-abstraction-v7/contracts/core/NonceManager.sol:36-40`: sender + uint192 key, uint64 sequence; EntryPoint `:650-652` enforces it. Require strict increase across successes, not contiguous increments. |
| 3. Sponsor-able state | `SuperPaymaster.sol:233,242,248,252,257`; `tokens/v2/xPNTsTokenV2.sol:194`; EntryPoint `:605`; `Helpers.sol:47-50` maps zero validUntil to max uint48. Start cached quote must stay fresh through the end passport's timestamp; end cache must also be fresh at its block. This is conservative if a quote expires and refreshes mid-run. |
| 4. Passport balance | `SuperPaymaster.sol:313,322,447`: operator balance is mutable accounting state. Require independently recorded A/B readbacks at the **same block hash**, never carry a different block's value into archive validation. Collector now includes operatorBalance on baseline arms too. |
| 5. Event cost | `SuperPaymaster.sol:426-434,450`: first event data word is aGas; charge = min(ceil(aGas*(10000+feeBps)/10000), a0). Check this forward relation, including clamping; inversion is not unique at the cap. |
| 6. Lock admission | `SuperPaymaster.sol:313-324`, `tokens/v2/xPNTsTokenV2.sol:196,210-212`: a0 <= single-tx limit; xLocked = ceil(a0*rate/1e18); balance - alreadyLocked >= xLocked. Gauge additionally requires a0 < 2^96 so the inflight representation is lossless. **The explicit Solidity cast truncates; it does not revert**, contrary to the review's explanation. Apply admission checks to retained postOp-revert locks too. |
| 7. Packed tails | EntryPoint `:427-430` rejects initCode for an existing account. `SuperPaymaster.sol:486-489` / `SuperPaymasterStorage.sol:176` extracts operator at byte 52; it must match passport and sponsored event. |
| 8. No UOE blocks | Gauge isolation/bracketing rule, independent of whether EntryPoint emitted an operation event. Before+1 = after = receipt height, and after hash = receipt block hash, including sent stopped rows. |

The full suite regenerates offline fixture files and result tables. No chain, deployment, or contract source changes are involved.
