# Safe governance review gate probes

All commands ran offline from the repository root. The orchestrator-supplied real block transaction lists in `chain-reads.json` were preserved; no network reads were made.

## Results

- 72/72 `a.need(...)` statements in `governance_entries` through `governance_evidence` are detected when individually replaced with `pass`.
- Final `SafeGovernanceTests`: 38 tests pass with the original gates intact, including recorded transactions and offline evidence replay.
- Replacing the absent-miner pre-state fallback with `pre[miner]['balance']` makes `test_miner_absent_pre_balance` fail. Its positive case removes the miner from pre-state and assigns exactly the priority fee to its post balance; adding one wei requires STOP. All three fixture copies are covered.

## Method

Parse `manifest_exec.py` with Python `ast`; for each expression calling `a.need` in the selected functions (including nested functions), deep-copy the containing function and replace only that expression with `ast.Pass`. Compile it into the imported module, run the complete `SafeGovernanceTests` suite, record failing/erroring test IDs, and restore the original function before the next mutation. Source files are never mutated by the probe. Deterministic local `cast` calls are memoized. Each row below lists a test detecting the removed statement; source and test line numbers were regenerated from the final AST.

## Probe table

| Gate | Source line | Detecting test | Result |
| --- | ---: | --- | --- |
| `'safe_gap_list'` | [L805](../../manifest_exec.py#L805) | [test_list_and_endpoint_controls](../../test_manifest_exec.py#L2889) | killed |
| `'safe_gap_reviewed_packet'` | [L810](../../manifest_exec.py#L810) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2866) | killed |
| `'safe_gap_step'` | [L811](../../manifest_exec.py#L811) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2866) | killed |
| `'safe_gap_packet_step'` | [L814](../../manifest_exec.py#L814) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2866) | killed |
| `'safe_gap_safe'` | [L817](../../manifest_exec.py#L817) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2866) | killed |
| `'safe_gap_packet_chain'` | [L818](../../manifest_exec.py#L818) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2866) | killed |
| `'safe_gap_safe_hash'` | [L819](../../manifest_exec.py#L819) | [test_packet_semantic_controls](../../test_manifest_exec.py#L2866) | killed |
| `'safe_gap_unique'` | [L822](../../manifest_exec.py#L822) | [test_exact_nonce_coverage](../../test_manifest_exec.py#L2734) | killed |
| `'safe_gap_trace_shape'` | [L832](../../manifest_exec.py#L832) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_trace_accounts'` | [L838](../../manifest_exec.py#L838) | [test_trace_account_controls](../../test_manifest_exec.py#L2612) | killed |
| `'safe_gap_trace_account_shape'` | [L841](../../manifest_exec.py#L841) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2547) | killed |
| `'safe_gap_trace_nonce'` | [L846](../../manifest_exec.py#L846) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2547) | killed |
| `'safe_gap_trace_storage'` | [L850](../../manifest_exec.py#L850) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2547) | killed |
| `'safe_gap_trace_sender'` | [L854](../../manifest_exec.py#L854) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_sender_fields'` | [L855](../../manifest_exec.py#L855) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_sender_nonce'` | [L856](../../manifest_exec.py#L856) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_sender_pre_balance'` | [L857](../../manifest_exec.py#L857) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2547) | killed |
| `'safe_gap_sender_balance'` | [L860](../../manifest_exec.py#L860) | [test_dual_identity_and_sender_balance](../../test_manifest_exec.py#L2645) | killed |
| `'safe_gap_sender_storage'` | [L861](../../manifest_exec.py#L861) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_sender_code'` | [L862](../../manifest_exec.py#L862) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_miner_fields'` | [L863](../../manifest_exec.py#L863) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_miner_balance'` | [L867](../../manifest_exec.py#L867) | [test_malformed_trace_gates](../../test_manifest_exec.py#L2547) | killed |
| `'safe_gap_miner_storage'` | [L868](../../manifest_exec.py#L868) | [test_sender_and_miner_trace_controls](../../test_manifest_exec.py#L2786) | killed |
| `'safe_gap_safe_fields'` | [L871](../../manifest_exec.py#L871) | [test_trace_account_controls](../../test_manifest_exec.py#L2612) | killed |
| `'safe_gap_storage_slots'` | [L883](../../manifest_exec.py#L883) | [test_storage_controls](../../test_manifest_exec.py#L2603) | killed |
| `'safe_gap_storage_value'` | [L885](../../manifest_exec.py#L885) | [test_storage_controls](../../test_manifest_exec.py#L2603) | killed |
| `'safe_gap_logs'` | [L899](../../manifest_exec.py#L899) | [test_log_controls](../../test_manifest_exec.py#L2596) | killed |
| `'safe_gap_log_' + field` | [L905](../../manifest_exec.py#L905) | [test_log_identity_fields](../../test_manifest_exec.py#L2530) | killed |
| `'safe_gap_log_logIndex'` | [L909](../../manifest_exec.py#L909) | [test_log_identity_fields](../../test_manifest_exec.py#L2530) | killed |
| `'safe_gap_log_removed'` | [L911](../../manifest_exec.py#L911) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2816) | killed |
| `'safe_gap_log_data'` | [L914](../../manifest_exec.py#L914) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2816) | killed |
| `'safe_gap_log_data'` | [L916](../../manifest_exec.py#L916) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2816) | killed |
| `'safe_gap_log_data'` | [L921](../../manifest_exec.py#L921) | [test_log_bytes_and_removed_controls](../../test_manifest_exec.py#L2816) | killed |
| `'safe_gap_endpoints'` | [L926](../../manifest_exec.py#L926) | [test_list_and_endpoint_controls](../../test_manifest_exec.py#L2889) | killed |
| `'safe_gap_found'` | [L933](../../manifest_exec.py#L933) | [test_missing_transaction](../../test_manifest_exec.py#L2746) | killed |
| `'safe_gap_hash'` | [L934](../../manifest_exec.py#L934) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2851) | killed |
| `'safe_gap_' + field` | [L937](../../manifest_exec.py#L937) | [test_transaction_controls](../../test_manifest_exec.py#L2583) | killed |
| `'safe_gap_input'` | [L938](../../manifest_exec.py#L938) | [test_real_chain_and_offline_replay](../../test_manifest_exec.py#L2495) | killed |
| `'safe_gap_type'` | [L939](../../manifest_exec.py#L939) | [test_transaction_controls](../../test_manifest_exec.py#L2583) | killed |
| `'safe_gap_authorizations'` | [L940](../../manifest_exec.py#L940) | [test_transaction_controls](../../test_manifest_exec.py#L2583) | killed |
| `'safe_gap_before_pin'` | [L942](../../manifest_exec.py#L942) | [test_block_controls](../../test_manifest_exec.py#L2756) | killed |
| `'safe_gap_block'` | [L945](../../manifest_exec.py#L945) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2851) | killed |
| `'safe_gap_canonical'` | [L946](../../manifest_exec.py#L946) | [test_block_controls](../../test_manifest_exec.py#L2756) | killed |
| `'safe_gap_block_number'` | [L947](../../manifest_exec.py#L947) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2851) | killed |
| `'safe_gap_block_transactions'` | [L950](../../manifest_exec.py#L950) | [test_block_transaction_membership](../../test_manifest_exec.py#L2715) | killed |
| `'safe_gap_block_transaction'` | [L951](../../manifest_exec.py#L951) | [test_block_transaction_membership](../../test_manifest_exec.py#L2715) | killed |
| `'safe_gap_miner_alias'` | [L954](../../manifest_exec.py#L954) | [test_miner_aliases](../../test_manifest_exec.py#L2521) | killed |
| `'safe_gap_receipt'` | [L956](../../manifest_exec.py#L956) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2851) | killed |
| `'safe_gap_receipt_identity'` | [L957](../../manifest_exec.py#L957) | [test_receipt_index_bound_to_mined_transaction](../../test_manifest_exec.py#L2538) | killed |
| `'safe_gap_status'` | [L959](../../manifest_exec.py#L959) | [test_status_controls](../../test_manifest_exec.py#L2590) | killed |
| `'safe_gap_logs_shape'` | [L960](../../manifest_exec.py#L960) | [test_mined_and_receipt_controls](../../test_manifest_exec.py#L2851) | killed |
| `'safe_gap_gas_used_positive'` | [L965](../../manifest_exec.py#L965) | [test_zero_gas_used](../../test_manifest_exec.py#L2690) | killed |
| `'safe_gap_effective_gas_price'` | [L966](../../manifest_exec.py#L966) | [test_effective_gas_price_anchor](../../test_manifest_exec.py#L2678) | killed |
| `'safe_gap_dual_identity'` | [L974](../../manifest_exec.py#L974) | [test_base_fee_required_and_agreed](../../test_manifest_exec.py#L2669) | killed |
| `'safe_gap_trace_available'` | [L976](../../manifest_exec.py#L976) | [test_trace_account_controls](../../test_manifest_exec.py#L2612) | killed |
| `'safe_gap_swap_required'` | [L979](../../manifest_exec.py#L979) | [test_list_and_endpoint_controls](../../test_manifest_exec.py#L2889) | killed |
| `'safe_gap_owner_swap_block'` | [L981](../../manifest_exec.py#L981) | [test_owner_swap_block_bound_to_chain](../../test_manifest_exec.py#L2653) | killed |
| `'safe_gap_pin_owners'` | [L983](../../manifest_exec.py#L983) | [test_pin_owner_controls](../../test_manifest_exec.py#L2626) | killed |
| `'safe_gap_pin_threshold'` | [L984](../../manifest_exec.py#L984) | [test_pin_owner_controls](../../test_manifest_exec.py#L2626) | killed |
| `'safe_gap_pin_nonce'` | [L985](../../manifest_exec.py#L985) | [test_pin_owner_controls](../../test_manifest_exec.py#L2626) | killed |
| `'safe_gap_pin_owners'` | [L987](../../manifest_exec.py#L987) | [test_independent_chain_state](../../test_manifest_exec.py#L2837) | killed |
| `'safe_gap_pin_threshold'` | [L988](../../manifest_exec.py#L988) | [test_independent_chain_state](../../test_manifest_exec.py#L2837) | killed |
| `'safe_gap_pin_nonce'` | [L989](../../manifest_exec.py#L989) | [test_independent_chain_state](../../test_manifest_exec.py#L2837) | killed |
| `'safe_gap_owner_eoa'` | [L991](../../manifest_exec.py#L991) | [test_independent_chain_state](../../test_manifest_exec.py#L2837) | killed |
| `'safe_gap_owner_eoa'` | [L992](../../manifest_exec.py#L992) | [test_pin_owner_controls](../../test_manifest_exec.py#L2626) | killed |
| `'safe_gap_evidence_undeclared'` | [L998](../../manifest_exec.py#L998) | [test_evidence_controls](../../test_manifest_exec.py#L2912) | killed |
| `'safe_gap_endpoints'` | [L1001](../../manifest_exec.py#L1001) | [test_collection_rejects_endpoint_count_before_delegating](../../test_manifest_exec.py#L2904) | killed |
| `'safe_gap_not_a3a'` | [L1021](../../manifest_exec.py#L1021) | [test_evidence_controls](../../test_manifest_exec.py#L2912) | killed |
| `'safe_gap_proof_duplicate'` | [L1030](../../manifest_exec.py#L1030) | [test_replay_duplicate_unused_and_endpoint_copy](../../test_manifest_exec.py#L2504) | killed |
| `'safe_gap_proof_read'` | [L1035](../../manifest_exec.py#L1035) | [test_evidence_controls](../../test_manifest_exec.py#L2912) | killed |
| `'safe_gap_trace_counts'` | [L1039](../../manifest_exec.py#L1039) | [test_base_fee_required_and_agreed](../../test_manifest_exec.py#L2669) | killed |
| `'safe_gap_proof_unused'` | [L1040](../../manifest_exec.py#L1040) | [test_replay_duplicate_unused_and_endpoint_copy](../../test_manifest_exec.py#L2504) | killed |

## Fee and block anchoring

Both endpoints require positive receipt gas usage and effective gas price equal to `min(packet.maxFeePerGas, block.baseFeePerGas + packet.maxPriorityFeePerGas)`, including the endpoint without a trace. Dual-endpoint identity includes receipt gas usage, effective gas price, and the complete block transaction list. Sender and miner trace balances reconcile to the receipt cost and priority fee respectively.

Negative controls cover price above the cap, below the base fee, and off by one; zero gas usage; endpoint disagreement on gas usage and price/base fee; missing block transaction lists, out-of-range indices, a hash moved to another index, and differing lists even when the target index still matches. A price disagreement with unchanged base fee fails the price anchor; shifting both endpoint B's base fee and price together reaches the dual-identity gate.

The real packet cap is 20,000,000,000 wei and priority fee is 100,000,000 wei for all three transactions. Each computed price equals the receipt on both endpoints:

| Transaction | Block base fee (wei) | Computed / receipt effective gas price (wei) | Gas used | Sender cost (wei) | Miner priority fee (wei) |
| --- | ---: | ---: | ---: | ---: | ---: |
| A99 | 22 | 100,000,022 | 68,394 | 6,839,401,504,668 | 6,839,400,000,000 |
| A100 | 28 | 100,000,028 | 135,104 | 13,510,403,782,912 | 13,510,400,000,000 |
| E755 | 29 | 100,000,029 | 188,871 | 18,887,105,477,259 | 18,887,100,000,000 |

## #596 X1 transaction lists

The complete real lists are in [chain-reads.json](chain-reads.json), under each transaction's `a.block.transactions` and `b.block.transactions`. Both endpoints have identical lists for each block. Indices are zero-based; every listed slot equals the transaction hash:

| Transaction | Block | Index | List length | Hash at index (both endpoints) |
| --- | ---: | ---: | ---: | --- |
| A99 | 12059736 | 1145 | 1214 | `0x1b13246cb084a7b1a9c3f344576a17bc2bc0072abd00e97b66654c755f8f4877` |
| A100 | 12060358 | 1104 | 1142 | `0xe268fc43baeb109562d8c85e1e1e71a6eefdb32c4c23513ee39f154d4dc2dcd7` |
| E755 | 12060359 | 107 | 139 | `0x3f45f5ef1987f3f625da2fb85a90c11abea2ab818a474d25245a7a1b9862b695` |

## Final offline suite results

All commands ran from the repository root and exited 0.

| Command | Final unittest lines |
| --- | --- |
| `python3 script/upgrade/test_manifest_exec.py` | `Ran 208 tests in 237.205s` / `OK` |
| `python3 script/a3a/test_a3a_exec.py` | `Ran 102 tests in 4.325s` / `OK` |
| `python3 script/upgrade/test_sp_upgrade_exec.py` | `Ran 141 tests in 2.227s` / `OK` |
| `python3 script/upgrade/test_pop_adapter.py` | `Ran 53 tests in 0.451s` / `OK` |
| `python3 script/upgrade/test_release_evidence.py` | `Ran 69 tests in 4.240s` / `OK` |

`git diff --check` also passes. Changes are uncommitted.
