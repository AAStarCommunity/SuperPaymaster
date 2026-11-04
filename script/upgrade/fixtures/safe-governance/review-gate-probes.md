# Safe governance review gate probes

All commands ran offline from the repository root. No fixtures were changed and no network reads were made.

## Results

- 68/68 `a.need(...)` statements in `governance_entries` through `governance_evidence` are detected when individually replaced with `pass`: 63 single-line statements and 5 multiline statements.
- The first pass (after production fixes and chain-state separation, before new negative controls) had 33 surviving mutations.
- Final `SafeGovernanceTests`: 31 tests pass with the original gates intact, including the real recorded transactions and offline evidence replay.
- No gate was excluded as structurally unreachable. Packet semantic checks behind the digest allowlist are isolated by mocking `reviewed_file` with a mutable packet; the digest check itself retains its existing negative control.
- The collection endpoint-count gate at line 861 is redundant with `check_governance` during end-to-end validation. Its dedicated boundary test stubs that delegate to fail if called, requiring the collection gate to reject the invalid count first. The initial final pass killed 67/68; after adding that test, rerunning the line-861 mutation killed it too.

## Method

Parse `manifest_exec.py` with Python `ast`; for each expression calling `a.need` in the selected functions (including nested functions), deep-copy the containing function and replace only that expression with `ast.Pass`. Compile it into the imported module, run the complete `SafeGovernanceTests` suite, record failing/erroring test IDs, and restore the original function before the next mutation. Source files are never mutated by the probe. Deterministic local `cast` calls are memoized during the probe. Every listed negative control passes with intact production code and asserts the expected gate name; deleting a gate causes either a missing/wrong-gate assertion or an unexpected error. Line numbers below refer to the final production source.

## Probe table

Each row lists one test that detects the removed statement. Multiple rows with the same gate name deliberately cover distinct statements. The two dynamic gate expressions also have field-specific assertions in their tests.

| Gate | Source line | Detecting test | Result |
| --- | ---: | --- | --- |
| `'safe_gap_list'` | [L676](../../manifest_exec.py#L676) | [test_list_and_endpoint_controls](../../test_manifest_exec.py#L2441) | killed |
| `'safe_gap_reviewed_packet'` | [L681](../../manifest_exec.py#L681) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2418) | killed |
| `'safe_gap_step'` | [L682](../../manifest_exec.py#L682) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2418) | killed |
| `'safe_gap_packet_step'` | [L685](../../manifest_exec.py#L685) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2418) | killed |
| `'safe_gap_safe'` | [L688](../../manifest_exec.py#L688) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2418) | killed |
| `'safe_gap_packet_chain'` | [L689](../../manifest_exec.py#L689) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2418) | killed |
| `'safe_gap_safe_hash'` | [L690](../../manifest_exec.py#L690) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2418) | killed |
| `'safe_gap_unique'` | [L693](../../manifest_exec.py#L693) | [test_exact_nonce_coverage](../../test_manifest_exec.py#L2289) | killed |
| `'safe_gap_trace_shape'` | [L703](../../manifest_exec.py#L703) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_trace_accounts'` | [L709](../../manifest_exec.py#L709) | [test_trace_account_controls](../../test_manifest_exec.py#L2242) | killed |
| `'safe_gap_trace_account_shape'` | [L712](../../manifest_exec.py#L712) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2177) | killed |
| `'safe_gap_trace_nonce'` | [L717](../../manifest_exec.py#L717) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2177) | killed |
| `'safe_gap_trace_storage'` | [L721](../../manifest_exec.py#L721) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2177) | killed |
| `'safe_gap_trace_sender'` | [L725](../../manifest_exec.py#L725) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_sender_fields'` | [L726](../../manifest_exec.py#L726) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_sender_nonce'` | [L727](../../manifest_exec.py#L727) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_sender_pre_balance'` | [L728](../../manifest_exec.py#L728) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2177) | killed |
| `'safe_gap_sender_balance'` | [L731](../../manifest_exec.py#L731) | [test_dual_identity_and_sender_balance](../../test_manifest_exec.py#L2275) | killed |
| `'safe_gap_sender_storage'` | [L732](../../manifest_exec.py#L732) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_sender_code'` | [L733](../../manifest_exec.py#L733) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_miner_fields'` | [L734](../../manifest_exec.py#L734) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_miner_balance'` | [L737](../../manifest_exec.py#L737) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2177) | killed |
| `'safe_gap_miner_storage'` | [L738](../../manifest_exec.py#L738) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2341) | killed |
| `'safe_gap_safe_fields'` | [L741](../../manifest_exec.py#L741) | [test_trace_account_controls](../../test_manifest_exec.py#L2242) | killed |
| `'safe_gap_storage_slots'` | [L753](../../manifest_exec.py#L753) | [test_storage_controls](../../test_manifest_exec.py#L2233) | killed |
| `'safe_gap_storage_value'` | [L755](../../manifest_exec.py#L755) | [test_storage_controls](../../test_manifest_exec.py#L2233) | killed |
| `'safe_gap_logs'` | [L769](../../manifest_exec.py#L769) | [test_log_controls](../../test_manifest_exec.py#L2226) | killed |
| `'safe_gap_log_' + field` | [L775](../../manifest_exec.py#L775) | [test_log_identity_fields](../../test_manifest_exec.py#L2160) | killed |
| `'safe_gap_log_logIndex'` | [L779](../../manifest_exec.py#L779) | [test_log_identity_fields](../../test_manifest_exec.py#L2160) | killed |
| `'safe_gap_log_removed'` | [L781](../../manifest_exec.py#L781) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2371) | killed |
| `'safe_gap_log_data'` | [L784](../../manifest_exec.py#L784) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2371) | killed |
| `'safe_gap_log_data'` | [L786](../../manifest_exec.py#L786) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2371) | killed |
| `'safe_gap_log_data'` | [L791](../../manifest_exec.py#L791) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2371) | killed |
| `'safe_gap_endpoints'` | [L796](../../manifest_exec.py#L796) | [test_list_and_endpoint_controls](../../test_manifest_exec.py#L2441) | killed |
| `'safe_gap_found'` | [L803](../../manifest_exec.py#L803) | [test_missing_transaction](../../test_manifest_exec.py#L2301) | killed |
| `'safe_gap_hash'` | [L804](../../manifest_exec.py#L804) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2403) | killed |
| `'safe_gap_' + field` | [L807](../../manifest_exec.py#L807) | [test_transaction_controls](../../test_manifest_exec.py#L2213) | killed |
| `'safe_gap_input'` | [L808](../../manifest_exec.py#L808) | [test_real_chain_and_offline_replay](../../test_manifest_exec.py#L2125) | killed |
| `'safe_gap_type'` | [L809](../../manifest_exec.py#L809) | [test_transaction_controls](../../test_manifest_exec.py#L2213) | killed |
| `'safe_gap_authorizations'` | [L810](../../manifest_exec.py#L810) | [test_transaction_controls](../../test_manifest_exec.py#L2213) | killed |
| `'safe_gap_before_pin'` | [L812](../../manifest_exec.py#L812) | [test_block_controls](../../test_manifest_exec.py#L2311) | killed |
| `'safe_gap_block'` | [L815](../../manifest_exec.py#L815) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2403) | killed |
| `'safe_gap_canonical'` | [L816](../../manifest_exec.py#L816) | [test_block_controls](../../test_manifest_exec.py#L2311) | killed |
| `'safe_gap_block_number'` | [L817](../../manifest_exec.py#L817) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2403) | killed |
| `'safe_gap_miner_alias'` | [L820](../../manifest_exec.py#L820) | [test_miner_aliases](../../test_manifest_exec.py#L2151) | killed |
| `'safe_gap_receipt'` | [L822](../../manifest_exec.py#L822) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2403) | killed |
| `'safe_gap_receipt_identity'` | [L823](../../manifest_exec.py#L823) | [test_receipt_index_bound_to_mined_transaction](../../test_manifest_exec.py#L2168) | killed |
| `'safe_gap_status'` | [L825](../../manifest_exec.py#L825) | [test_status_controls](../../test_manifest_exec.py#L2220) | killed |
| `'safe_gap_logs_shape'` | [L826](../../manifest_exec.py#L826) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2403) | killed |
| `'safe_gap_dual_identity'` | [L834](../../manifest_exec.py#L834) | [test_dual_identity_and_sender_balance](../../test_manifest_exec.py#L2275) | killed |
| `'safe_gap_trace_available'` | [L836](../../manifest_exec.py#L836) | [test_trace_account_controls](../../test_manifest_exec.py#L2242) | killed |
| `'safe_gap_swap_required'` | [L839](../../manifest_exec.py#L839) | [test_list_and_endpoint_controls](../../test_manifest_exec.py#L2441) | killed |
| `'safe_gap_owner_swap_block'` | [L841](../../manifest_exec.py#L841) | [test_owner_swap_block_bound_to_chain](../../test_manifest_exec.py#L2283) | killed |
| `'safe_gap_pin_owners'` | [L843](../../manifest_exec.py#L843) | [test_pin_owner_controls](../../test_manifest_exec.py#L2256) | killed |
| `'safe_gap_pin_threshold'` | [L844](../../manifest_exec.py#L844) | [test_pin_owner_controls](../../test_manifest_exec.py#L2256) | killed |
| `'safe_gap_pin_nonce'` | [L845](../../manifest_exec.py#L845) | [test_pin_owner_controls](../../test_manifest_exec.py#L2256) | killed |
| `'safe_gap_pin_owners'` | [L847](../../manifest_exec.py#L847) | [test_independent_chain_state](../../test_manifest_exec.py#L2389) | killed |
| `'safe_gap_pin_threshold'` | [L848](../../manifest_exec.py#L848) | [test_independent_chain_state](../../test_manifest_exec.py#L2389) | killed |
| `'safe_gap_pin_nonce'` | [L849](../../manifest_exec.py#L849) | [test_independent_chain_state](../../test_manifest_exec.py#L2389) | killed |
| `'safe_gap_owner_eoa'` | [L851](../../manifest_exec.py#L851) | [test_independent_chain_state](../../test_manifest_exec.py#L2389) | killed |
| `'safe_gap_owner_eoa'` | [L852](../../manifest_exec.py#L852) | [test_pin_owner_controls](../../test_manifest_exec.py#L2256) | killed |
| `'safe_gap_evidence_undeclared'` | [L858](../../manifest_exec.py#L858) | [test_evidence_controls](../../test_manifest_exec.py#L2464) | killed |
| `'safe_gap_endpoints'` | [L861](../../manifest_exec.py#L861) | [test_collection_rejects_endpoint_count_before_delegating](../../test_manifest_exec.py#L2456) | killed |
| `'safe_gap_not_a3a'` | [L881](../../manifest_exec.py#L881) | [test_evidence_controls](../../test_manifest_exec.py#L2464) | killed |
| `'safe_gap_proof_duplicate'` | [L890](../../manifest_exec.py#L890) | [test_replay_duplicate_unused_and_endpoint_copy](../../test_manifest_exec.py#L2134) | killed |
| `'safe_gap_proof_read'` | [L895](../../manifest_exec.py#L895) | [test_evidence_controls](../../test_manifest_exec.py#L2464) | killed |
| `'safe_gap_trace_counts'` | [L899](../../manifest_exec.py#L899) | [test_block_controls](../../test_manifest_exec.py#L2311) | killed |
| `'safe_gap_proof_unused'` | [L900](../../manifest_exec.py#L900) | [test_replay_duplicate_unused_and_endpoint_copy](../../test_manifest_exec.py#L2134) | killed |

## Production changes and limits

- `governance_trace` takes the receipt from the endpoint supplying the trace. Lines 729–731 validate `gasUsed` and `effectiveGasPrice` and reconcile the sender decrease to their product plus the reviewed transaction value (zero). Negative controls cover an increase, no decrease, and a still-decreasing balance off by one wei, plus malformed receipt fee fields.
- Line 828 adds `mined['transactionIndex']` to the identity compared at line 834. `test_dual_transaction_index` moves endpoint B's mined transaction, receipt, and every log together and requires `safe_gap_dual_identity`.
- All recorded blocks omit `baseFeePerGas`. Miner accounting therefore remains the one-sided increase check at line 737; no base fee was invented or fetched.
- Mock `getOwners`, `getThreshold`, `nonce`, and owner-code reads use deep-copied per-endpoint `chain_state`, independent of the pin. Both endpoints have chain-side negative controls; the existing pin-side controls remain.

The unchanged fixtures reconcile exactly (wei, endpoint A supplies each trace):

| Transaction | Observed sender decrease | Receipt gas cost + value |
| --- | ---: | ---: |
| A99 | 6,839,401,504,668 | 6,839,401,504,668 |
| A100 | 13,510,403,782,912 | 13,510,403,782,912 |
| E755 | 18,887,105,477,259 | 18,887,105,477,259 |

## Final offline suite results

All commands ran from the repository root and exited 0. The manifest suite was rerun after adding the final collection-boundary test.

| Command | Final unittest lines |
| --- | --- |
| `python3 script/upgrade/test_manifest_exec.py` | `Ran 173 tests in 210.112s` / `OK` |
| `python3 script/a3a/test_a3a_exec.py` | `Ran 102 tests in 3.277s` / `OK` |
| `python3 script/upgrade/test_sp_upgrade_exec.py` | `Ran 141 tests in 1.526s` / `OK` |
| `python3 script/upgrade/test_pop_adapter.py` | `Ran 53 tests in 0.282s` / `OK` |
| `python3 script/upgrade/test_release_evidence.py` | `Ran 38 tests in 1.835s` / `OK` |

`git diff --check` also passes. Changes are uncommitted.
