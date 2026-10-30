# A4 credit log scanner: offline validation

Offline validation performed without network access or signing. The Anvil control was executed later (see the evidence README).

## Files and use

- `a4-credit-logscan.py`: stdlib-only read-only scanner; URL contents come from files and are never printed. Exit 0 means both criteria pass, 1 means fail or unverified, and command/output errors are nonzero.
- `test_a4_credit_logscan.py`: 35 offline unittest controls and a repeatable mutation runner.
- `a4-credit-logscan-anvil-control.sh`: read-only positive control for an already prepared Anvil chain with executed policy 2. Starts the existing local proxy and requires a complete scan with C4=fail and policy 2 present.

```sh
python3 script/evidence/a4-credit-logscan.py --rpc-a-file /path/to/a.rpc --rpc-b-file /path/to/b.rpc \
  --token 0xTOKEN1 0xTOKEN2 --from-block DEPLOY_OR_EARLIER --to-block PINNED_FINALIZED --out evidence.json
python3 script/evidence/test_a4_credit_logscan.py
python3 script/evidence/test_a4_credit_logscan.py --mutations
bash -n script/evidence/a4-credit-logscan-anvil-control.sh
# Later, on the prepared local chain (not run during this validation):
bash script/evidence/a4-credit-logscan-anvil-control.sh 0xTOKEN FROM TO control.json
```

`--token` also supports repetition. `--chunk-size` defaults to 2000; an RPC failure halves the actual failed range, retries at the same start, and retains the reduced size. A one-block failure stops with both verdicts `未能验证`. Decoding/disagreement failures stop immediately. Failed and successful attempts appear in `chunks`; `complete=false` and a null digest prevent partial output being mistaken for complete evidence.

The canonical list contains normalized lowercase hex, integer quantities, removed=false, and transactionIndex as well as the requested identity fields. It sorts by (blockNumber, transactionIndex, logIndex, address). SHA-256 hashes UTF-8 JSON with sorted keys, separators `(",", ":")`, and no trailing newline. Output includes the list itself.

## Source and ABI cross-check

Baseline: `contracts/src/tokens/v2/xPNTsV2Base.sol`; policy execution reviewed in `xPNTsTokenV2Ext.sol`, reservation and settlement in `xPNTsTokenV2.sol`, release in the base, and initial OFF assertion in `xPNTsFactoryV2.sol`.

Each topic0 was computed offline using both `cast keccak` and PyCryptodome Keccak-256; the results agreed. The scanner embeds these constants and needs neither tool at runtime. The offline tests pin the selectors independently and compare canonical signatures and indexed field layouts to the source and all three checked-in token ABIs.

| Canonical signature | topic0 | Indexed fields |
|---|---|---|
| `CreditPolicyExecuted(uint8,uint32)` | `0x4a53aec9f255b2d5bcb9ce63ec2e9263cd6094537eec19973e8708c1b1e35f02` | none |
| `CreditReserved(address,bytes32,address,uint256)` | `0xe7f1ceee255e2908b896f5fa254cb3bac9e538bdac389f75de2fc3446d2a7b69` | user, opHash, locker |
| `CreditSettled(address,bytes32,uint256)` | `0xe24e7f4be2a6dcf7000d9d67421687e27dcf1f62554dbdeec78adb103aae6323` | user, opHash |
| `CreditReleased(address,bytes32,uint256)` | `0xdad6678c895f98939e7284e161055630849182add6c69672f905c25a73369269` | user, opHash |

`out/` is absent. `abis/xPNTsTokenV2.json`, `abis/xPNTsTokenV2Ext.json`, and `abis/xPNTsTokenV2.full.json` all match these four event declarations (names, types, field order, indexed flags, and non-anonymous status). No staleness was found for those declarations; this is not a claim that the entire ABI is current. `abis/xPNTsFactoryV2.json` contains none of these token events, as expected.

## Results and targeted mutations

35/35 tests passed. 39/39 targeted mutations were killed by assertion failures, with zero mutant test errors. Each unittest method has one aggregate assertion and a named mutation that makes it fail. These results do not claim exhaustive mutation coverage of every branch or every component within an aggregate assertion. The shell control was executed on a local anvil chain afterwards; see `docs/design/aoa-balance-mode/data/a4-credit-logscan/README.md`.

The fake provider filters by the requested topics, while injected event topic0 values are independent literals. With a wrong policy selector the scan misses the fixture and returns C4=pass: the deliberate broken-instrument test records that failure mode, and the separate policy-selector mutation turns the actual positive control red.

| Mutation tried | Test that went red | Result |
|---|---|---|
| Ignore all nonzero policies | `test_policy_positive` | assertion failed |
| Drop policy-OFF executions from the report | `test_off_policy_reported` | assertion failed |
| Ignore open reservations when deciding C7 | `test_open_zero_amount` | assertion failed |
| Replay in reverse chronological order | `test_reuse_chronological` | assertion failed |
| Suppress duplicate-open anomaly | `test_duplicate_reserve` | assertion failed |
| Suppress close-without-open anomaly | `test_orphan_closes` | assertion failed |
| Use opHash alone, dropping token and user | `test_user_and_token_key` | assertion failed |
| Skip A/B log equality check | `test_missing_chunk_log` | assertion failed |
| Stop instead of shrinking failed ranges | `test_shrink_completes` | assertion failed |
| Give up at two blocks instead of retrying one block | `test_permanent_error` | assertion failed |
| Return pass when start is after deployment | `test_start_after_deploy` | assertion failed |
| Report start instead of discovered deployment block | `test_bisection_and_evidence` | assertion failed |
| Return pass when no token code exists at the end | `test_no_code` | assertion failed |
| Skip the finalized-checkpoint check against the numbered view | `test_finalized_checkpoint_in_numbered_view` | assertion failed |
| Remove finalized-height gate | `test_finalized_both` | assertion failed |
| Remove chain-ID equality gate | `test_chain_mismatch` | assertion failed |
| Remove chunk-boundary header equality gate | `test_boundary_hash` | assertion failed |
| Ignore mismatch between log blockHash and header | `test_log_hash` | assertion failed |
| Accept removed logs | `test_removed_log` | assertion failed |
| Accept duplicate log positions | `test_duplicate_log` | assertion failed |
| Echo malformed hex in error text | `test_malformed_hex_no_echo` | assertion failed |
| Echo malformed quantity in error text | `test_malformed_quantity_no_echo` | assertion failed |
| Accept an overflowing policy uint8 | `test_bad_event_encoding` | assertion failed |
| Force C4 fail even when the bad selector hides the fixture | `test_wrong_selector_load_bearing` | assertion failed |
| Accept the wrong JSON-RPC version | `test_rpc_envelope_no_echo` | assertion failed |
| Output the full endpoint URL instead of host | `test_cli_redaction` | assertion failed |
| Return pass for the same endpoint twice | `test_same_endpoint` | assertion failed |
| Change canonical policy signature uint8 to uint256 | `test_source_abi_selectors` | assertion failed |
| Ignore a re-reservation after the first close | `test_reuse_left_open` | assertion failed |
| Fabricate historical code instead of probing either endpoint | `test_archive_both_required` | assertion failed |
| Normalize every transactionIndex to zero | `test_transaction_index_disagreement` | assertion failed |
| Hash an empty list regardless of collected logs | `test_nonempty_canonical_digest` | assertion failed |
| Treat out-of-range logs as an empty response | `test_outside_filter` | assertion failed |
| Fabricate a deployment boundary after code disagreement | `test_code_disagreement` | assertion failed |
| Remove the end-of-scan pinned-hash check | `test_pinned_hash_changes` | assertion failed |
| Replace policy topic0 with zero | `test_policy_positive` | assertion failed |
| Replace reserve topic0 with zero | `test_open_zero_amount` | assertion failed |
| Replace settle topic0 with zero | `test_reuse_chronological` | assertion failed |
| Replace release topic0 with zero | `test_reuse_chronological` | assertion failed |

Exact source replacements are in `MUTATIONS` in the test file; mutation execution uses in-memory module copies and never modifies the scanner on disk.

## What remains unverified

- No live archive RPC scan or Anvil positive-control execution. No chain-specific C4/C7 conclusion is established by these offline tests.
- Provider independence and identical omissions cannot be established by endpoint agreement, code probes, or returned log data. The local Anvil proxy explicitly shares its backend with A and is only an instrumentation control.
- C1, C2, C3, C5, C6, C8, and C9 are outside this scanner. C7 passing does not establish zero debt (C8). Token code identity must separately be verified against xPNTs v2.
- Code bisection assumes persistent xPNTs v2 code after creation; arbitrary metamorphic contracts are outside scope. Genesis deployments are rejected because a from-block-minus-one probe is unavailable. If from-block is later than deployment, the scan refuses to make either claim.
- ABI verification covers these four declarations, not compilation or deployment identity.

## Checked file SHA-256 values

| File | SHA-256 |
|---|---|
| `contracts/src/tokens/v2/xPNTsV2Base.sol` | `20d1bbda5cc769de35e5c82030779831fec7408a01ac4a50d63e9b7450d7292d` |
| `contracts/src/tokens/v2/xPNTsTokenV2Ext.sol` | `ed46ee6bc1c84933b3bbd5fe8b7b8ff64fdcca94b9bcf1d2ea2f49dfb2d6b714` |
| `contracts/src/tokens/v2/xPNTsTokenV2.sol` | `6ddccb29160f41e77178c6139629e384b39ffa053e32d81f18388c55dba88ef4` |
| `contracts/src/tokens/v2/xPNTsFactoryV2.sol` | `893eb4f8fe0e1dd3170049546d990627e1717fff984b12b89e218024991f71e1` |
| `abis/xPNTsTokenV2.json` | `968548bc1b626a5202cf33d6dc279fad8b61c2995814c8575f9c0fe3f54261b7` |
| `abis/xPNTsTokenV2Ext.json` | `d9b2e9e724852f33c5e482ac2caa25cc3bbf0596860c2c337cd310d631baf7a3` |
| `abis/xPNTsTokenV2.full.json` | `e7def77e1cbfb6378a1cdf04b1e2191b2c995c9b252264c9ca582d0c7b703826` |
