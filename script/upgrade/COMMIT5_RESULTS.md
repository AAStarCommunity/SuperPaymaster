# COMMIT 5 review evidence

This is an uncommitted working-tree change against `f353af657f3df6b44d61827f9ee6b1c6d8a4ac4b`. No RPC/environment/keystore configuration or chain state was changed.

H1 binds each `roleConfigs` index (including storage-alias origins) and every `RoleConfigured` argument to the function's own first `bytes32` parameter declaration. Parameter assignment/unary mutation, assembly references to the parameter, and local-copy keys STOP at `old_owner_role_write_key`; incorrect event arguments STOP at `old_owner_role_configure_emit`.

H2 scans Registry, its complete linearization (including modifiers), and imported libraries. Dangerous Yul instructions and unreviewed low-level calls STOP. Low-level calls are conservatively rejected even when their selector is hidden in a local value. Allowlist exceptions require both the compiler AST absolutePath and the keccak of the corresponding build-info input source, with a written reason.

M keeps observed discovery separate from retained authority coverage. After the switch, the old factory must enumerate the pin-time token set and both round clones; the release factory must enumerate exactly the planned new tokens. An empty release factory is valid at the intermediate stage before token deployment. Neither retained tokens nor round-clone constants are injected into observed discovery.

L uses single-source-site deletion, a green baseline, one or more failures, zero errors, and at least one assertion message naming the deleted gate. Named STOP assertions convert a missing gate or an unexpected downstream exception into an assertion failure in test code. No production probe fallbacks were added. The audit driver permits an uncommitted checkout because the operator commits after verification. Pure evidence-test-name parsing is cached by source text; changed contents always get parsed again.

## Deployed Registry binding and STOP

Registry implementation `0x9bed0f58d6001b0006923eb8c4b1cc548d42ccee` -> [recorded immutable-masked runtime parity](DEPLOYED_SOURCE_PARITY_RESULTS.md) / [Registry reRulingBuild.parity](deployed_source_candidates.json) -> commit `a839347e04b40da287522c3641e12121ef2e8e9e` -> [actual AST proof inputs and all source keccaks](registry_ast_proof_inputs.json).

Build-info ID: `e34c552b450719a1`. Build-info SHA-256: `b83fa70c805b322d603955b4b5643cb8daf6f61320e970e03af6d79398151a95`. The archived build remains at `/private/tmp/l1-builds/a839347e04b40da287522c3641e12121ef2e8e9e`; the real-build regression requires that evidence and does not substitute a release build.

The strengthened role-write proof passes for all seven initialized roles. The complete opaque-call proof **STOPs at `old_owner_role_lowlevel_call`**: the deployed source has selector-encoded calls in Registry itself, outside the OZ-only allowlist. Existing runtime parity does not grant an exception. No new chain measurement is claimed.

| Source | Function | Line | Result |
|---|---|---:|---|
| `contracts/src/core/Registry.sol` | `_safeSetRoleExitFee` | 194 | STOP: `call` |
| `contracts/src/core/Registry.sol` | `exitRole` | 388 | STOP: `call` |
| `contracts/src/core/Registry.sol` | `exitRole` | 394 | STOP: `call` |

## Exact allowlist from the archived build

The path column is solc `absolutePath` (repository-relative in this build), not a machine-specific filesystem prefix. These entries also appear in [registry_ast_allowlist.json](registry_ast_allowlist.json).

| absolutePath | Source keccak | Reason |
|---|---|---|
| `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/proxy/utils/Initializable.sol` | `0x631188737069917d2f909d29ce62c4d48611d326686ba6683e26b72a23bfac0b` | OpenZeppelin ERC-7201 initializer storage pointer; initializer authority is checked by the role-write proof. |
| `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/utils/Address.sol` | `0xaf28a975a78550e45f65e559a3ad6a5ad43b9b8a37366999abd1b7084eb70721` | OpenZeppelin call/delegatecall utility used by ERC1967 upgrades; upgrade authority is covered by owner isolation. |
| `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/utils/StorageSlot.sol` | `0x32ba59b4b7299237c8ba56319110989d7978a039faf754793064e967e5894418` | OpenZeppelin typed storage-slot access for ERC1967 upgrades; upgrade authority is covered by owner isolation. |

Production deployment-event decoding no longer substitutes an empty event or zero address after a missing gate; test assertions handle deletion failures without synthetic production values.

## Assertion classifications

Class A controls prove a named gate; they use `assert_stop` (or an equivalent named assertion) so deletion cannot be credited as an unhandled ERROR. Class B parser/schema rejection tests retain explicit exception-type `assertRaises`; they do not accept a runner ERROR.

| Name | File | Class | Change |
|---|---|---|---|
| `GasProbeReportingTests + suppressed_outcome (replaced)` | `probe_gas_gates.py` | A | Remove AttributeError-as-success; use exact-site deletion and named assertion failures |
| `assert_enduser_controls` | `test_old_owner_isolation.py` | A | Name the positive/negative mapping gate when its required read is missing. |
| `test_mapping_enduser_faults_stop_audit` | `test_old_owner_isolation.py` | A | Name the deleted getter gate as well as the caller control-path gate on assertion failure. |
| `mapping_control / old_owner_mapping_getter` binding | `audit605_probes.py` | A | Bind to existing direct getter rejection test; preserve the older fallback test for reviewer ruling. |
| `assert_gate` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `assert_timelock_build_gate` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `check` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `check_closing_inventory` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `check_old_timelock` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `control` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `gate (DiscoveryTests)` | `test_manifest_exec.py` | A | Assert expected gate; downstream exceptions become named failures |
| `never_recheck_change` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `registry_layout_fixture` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `rehearse_fake` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `removed_probe` | `test_old_owner_isolation.py` | A | Replace crash-as-red diagnostics with captured named assertion failures and zero errors |
| `stop` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `stop` | `test_manifest_phase_c.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_aggregator_transfer_requires_completed_admin` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_all_manifest_stages_require_remote_gas_evidence` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_ast_extra_getter_revert_stops` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_b2_implementation_identity_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_b2_single_upgrade_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_budget_includes_stake_and_deposit` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_builder_runs_release_validation` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_built_aggregator_version_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_cached_build_current_head_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_calldata_payload_removal_hits_named_gate` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_clone_collection_and_post_upgrade_gate_removals` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_clone_identity_and_factory_origin_controls` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_closure_finding_cannot_be_outside` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_collect_direct_fake_chain` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_collect_registry_version_negative` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_collection_rejects_endpoint_count_before_delegating` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_committee_handover_requires_completed_binding` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_committee_rejects_two_step_runtime` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_config_history_drop_truncation_both_endpoints` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_control_must_fire_named_gate` | `test_manifest_phase_c.py` | A | Catch a failed positive restoration as a named X_restore assertion instead of a downstream Gate ERROR |
| `test_decoded_arguments_both_cast_formats` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_deployed_source_collection_replay_and_missing_source` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_deployment_record_binding_and_gate_removals` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_dvt_closing_binds_pointer_and_stale_proposals` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_dvt_mock_rebuilt_runtime_gate` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_dvt_rebuilt_creation_gate` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_dvt_repo_must_be_configured` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_early_swap_detects_missing_eta_guard` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_early_swap_refuses_old_implementation` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_early_swap_requires_eta_revert_reason` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_early_swap_requires_valid_accounting` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_embedded_a3a_contract_call_gap_refused` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_empty_extraction_categories_stop` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_empty_range_discovery` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_endpoint_replay_reruns_predicates` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_endpoint_without_hostname` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_evidence_controls` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_evidence_full_creation_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_extra_token_closing` | `test_manifest_exec.py` | A | Stop at closing_timelock_inventory, isolate role history, assert old_timelock_inventory; never continue into authority RPCs |
| `test_fabricated_scope_hides_high_finding` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_factory_enumeration_must_stand_alone` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_factory_only_token_and_operator_union` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_finding_path_canonical_gate` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_finding_symlink_canonical_gate` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_fork_pin_positive_and_restore_gates` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_governance_evidence_revalidated_by_builder` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_grants_cancellation_union_and_truncation` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_guardian_inventory_and_anni_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_history_identity_gate_removals` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_history_standard_revoke_only` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_immutable_address_negative_controls_and_removals` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_immutable_ast_and_malformed_reference_controls` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_immutable_repeated_values_must_agree` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_internal_nonce_hole_refused` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_layout_pair_identity_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_layout_pair_parity_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_legacy_timelock_source_targets` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_list_and_endpoint_controls` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_live_owner_code_on_one_endpoint` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_manifest_calldata_invalid_cast_output` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_mapping_enduser_without_control_holder` | `test_old_owner_isolation.py` | A | Unexpected STOP is a named assertion, not an ERROR |
| `test_metadata_bytes_cannot_be_masked_as_immutables` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_metadata_masked_requires_rule4` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_missing_transaction` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_named_clones_storage_authority_controls` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_negative_controls_and_gate_removal_probes` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_filtered_history_cannot_hide_grant` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_pointers_require_old_aggregator` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_timelock_approval_history` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_timelock_approval_incomplete` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_timelock_external_approval` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_timelock_external_approval_closing` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_timelock_external_approval_pre_send` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_timelock_inventory_new_token` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_old_timelock_log_replay` | `test_manifest_exec.py` | A | Name old_timelock_replay / old_timelock_unused in typed STOP assertion |
| `test_owner_swap_block_bound_to_chain` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_packet_semantic_controls` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pair_and_independent_endpoint_failure` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pin_pending_token_eta` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pin_replay_both_endpoints_and_tampering` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pin_time_immutable_gates` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_positive_controls_fail_closed` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pre_send_bound_runtime_is_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pre_send_delta_call` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pre_send_enforces_exit_gate` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pre_send_real_b2_is_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pre_send_registry_owner_follows_completed_accept` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_pre_send_rereads_slots_and_time` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_proxy_runtime_extra_selector_stops` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_proxy_slot_binds_parity_to_pinned_implementation` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_raw_absolute_mapping_rejected` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_raw_report_symlink_escape_rejected` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_real_chain_and_offline_replay` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_reconcile_direct_and_canonical_receipt` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_recursive_manifest_abi_controls` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_registered_wrong_data_length` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_registry_adopted_behavioral_claim` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_replay_duplicate_unused_and_endpoint_copy` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_replay_evidence_required_and_counts_checked` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_reproducible_reference_bytes_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_review_low_calldata_gates` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_review_low_endpoint_identity` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_review_low_registry_registered_exited` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_config_control` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_configure_emit` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_configured_coverage_per_emitter` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_control_case_without_path_gate` | `test_old_owner_isolation.py` | A | Assert old_owner_role_control_case in failure message |
| `test_role_event_abi_and_inventory_source_seam` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_history_authentication_and_empty_probes` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_init_ids` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_init_standard` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_initializer_only` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_write_extraction_call` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_role_write_sites` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_run_manifest_final_frozen_check_requires_timelock_owner` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_runtime_mask_ranges_and_nonimmutable_mismatch` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_safe_mint_exit_and_regrant` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_safe_noncanonical_fallback_and_non_old_module` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_sampled_deployer_only` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_scope_empty_and_dependency_disjointness` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_slither_raw_rederived_gate` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_source_implementation_and_boundary_gate_removals` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_staged_source_rebuild` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_staged_timing_prefix` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_stale_dvt_proposals_accepted_only_exactly` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_stale_tree_evidence_refused` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_trace_rpc_failure_is_recorded_and_fails_closed` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_unchanged_old_activity_detects_new_activity_after_pin` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_unexpected_indirection_and_gate_removals` | `test_old_owner_isolation.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_unpause_outside_6d_refused` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_unsigned_dvt_proposal_stops` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_verifier_metadata_solc_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_verifier_segment_length_required` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `xpnts_owner_change` | `test_manifest_exec.py` | A | Named STOP assertion; downstream exceptions fail with gate name |
| `test_extra_acceptance_schema_stop` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_duplicate_acceptance_schema_stop` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_wrong_acceptance_schema_stop` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_ci_schema_fields_stop` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_reference_single_line_stop` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_pop_selector_and_duplicates_refused` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_fraud_sample_format_only` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_fraud_sample_412_schema_and_bindings` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |
| `test_fraud_fixture_schema_and_binding` | `test_manifest_exec.py` | B | Explicit typed rejection retained: `a.Gate`; no runner ERROR acceptance |

## Older controls retained for reviewer ruling

These controls predate `645ff3a1`. Their test bodies were not changed to force a strict red result. A failed strict criterion is reported, never credited as a successful deletion. The separate audit605 driver tests replay/history statements individually.

| Name | Driver | Current strict result |
|---|---|---|
| `proxy_runtime_all_parity_gates` (inside `test_proxy_runtime_extra_selector_stops`) | `test_old_owner_isolation.py` | Legacy diagnostic removes two gates and accepts the action; no one-site assertion failure. It is now explicitly printed as `LEGACY_NOT_STRICT`, with unchanged test semantics. |
| `GasGateControls.test_measurement_executionTimestamp` | `probe_gas_gates.py` | One site deleted; baseline OK; mutated OK (0 failures, 0 errors). A second timestamp check still enforces the same gate. |
| `ManifestTests.test_rehearsal_funding_rechecked_after_phase_c` / `C_funding_bundler` | `probe_phase_c_gates.py` | No production gate statement at the recorded caller site: the test raises its gate through a fake funding function. |
| `ManifestTests.test_old_timelock_replay` / `old_timelock_replay` | `probe_phase_c_gates.py` | Baseline reaches two failing source sites; the old combined-name control cannot identify one statement for deletion. |
| `ManifestTests.test_old_timelock_approval_history` / `old_timelock_approval_history` | `probe_phase_c_gates.py` | Baseline reaches two failing source sites; the old combined-name control cannot identify one statement for deletion. |
| `OldOwnerIsolationTests.test_mapping_function_falls_back` / `old_owner_mapping_getter` | `probe_phase_c_gates.py` | One failure, zero errors, but assertion names `old_owner_role_control_path`, not the deleted getter gate. |

`L1_CONTROL` lines are internal named-assertion controls, not claimed as standalone single-site deletion evidence; the deletion drivers provide the one-site checks.

The older `X_restore` ERROR was class A and was fixed: both `X_gate` and `X_restore` now have green baselines and one-site, named assertion failures with zero errors. The two opt-in old-owner fork tests remain skipped (hydrated local engine/fixed RPC pin required); no chain actions were taken.

## Final verification

All three requested unit suites passed. Every new gate and the discovery/extraction seams meet the revised strict criterion. `audit605_probes.py --jobs 3` passes all 94 sites, including the formerly failing `old_timelock_inventory` full-suite run. The generic `audit/probe_gate_removal.py` driver was exercised in baseline, listing, bound-test and full `--failfast` modes by audit605.

The Phase C and gas driver FAIL totals below are intentional reporting of the preserved older non-strict controls listed above; no new gate is uncovered. The snapshot ERROR was converted and both of its one-site probes pass. Only the default engine was used in this run; no result is claimed for another engine.

The final AST proof is not a deployment approval: the exact deployed Registry remains STOP under the DSR's OZ-only low-level-call rule.

`python3 -B script/upgrade/test_old_owner_isolation.py` ([local full log](/tmp/c5-old-last.log)):

```text
Ran 95 tests in 21.093s
OK (skipped=2)
```

`python3 -B script/upgrade/test_manifest_exec.py (invoked by audit605 baseline)` ([local full log](/tmp/c5-audit-final.log)):

```text
BASELINE_SUITE green Ran 507 tests in 378.006s
```

`python3 -B script/upgrade/test_manifest_phase_c.py` ([local full log](/tmp/c5-phase-last.log)):

```text
Ran 140 tests in 209.471s
OK
```

`python3 -B script/evidence/enduser_mapping_probes.py` ([local full log](/tmp/c5-enduser-final.log)):

```text
DISCOVERY_DELETION_PROBES PASS 38/38; each matches=1 and red
DELTA_DELETION_PROBES PASS
ENDUSER_PROBES PASS
```

`python3 -B script/upgrade/probe_phase_c_gates.py 645ff3a1` ([local full log](/tmp/c5-phase-probes-complete.log)):

```text
Ran 1 test in 0.026s
DISCOVERY_DELETION_PROBES PASS 38/38; each matches=1 and red
DELTA_DELETION_PROBES PASS
PHASE_C_GATE_PROBES FAIL 197/201 red; uncovered new gates: []
```

`python3 -B script/evidence/inventory_replay_probes.py` ([local full log](/tmp/c5-inventory-verified.log)):

```text
INVENTORY_REPLAY_PROBES PASS
```

`python3 -B script/evidence/stale_proposal_probes.py` ([local full log](/tmp/c5-stale-final.log)):

```text
SOURCE_UNCHANGED 1
PROBES_ALL_RED=1
```

`python3 -B script/upgrade/probe_gas_gates.py` ([local full log](/tmp/c5-gas-final.log)):

```text
Ran 1 test in 0.000s
OK
GAS_GATE_PROBES FAIL 15/16
```

`H1 assembly-parameter focused unit and single-site deletion probe` ([local full log](/tmp/c5-h1-assembly.log)):

```text
Ran 1 test in 0.001s
OK
H1_ASSEMBLY_PARAMETER_PROBE PASS matches=1 baseline=Ran 1 test in 0.001s OK removed=Ran 1 test in 0.006s FAILED (failures=7)
```

`python3 -B script/evidence/audit605_probes.py --jobs 3` ([local full log](/tmp/c5-audit-final.log)):

```text
BASELINE_SUITE green Ran 507 tests in 378.006s
PROBED 94 OK 94 MISSING []
AUDIT605_PROBES PASS
```

## Files changed

- [script/evidence/audit605_probes.py](../evidence/audit605_probes.py)
- [script/evidence/enduser_mapping_probes.py](../evidence/enduser_mapping_probes.py)
- [script/evidence/inventory_replay_probes.py](../evidence/inventory_replay_probes.py)
- [script/evidence/stale_proposal_probes.py](../evidence/stale_proposal_probes.py)
- [script/upgrade/audit/probe_gate_removal.py](audit/probe_gate_removal.py)
- [script/upgrade/manifest_exec.py](manifest_exec.py)
- [script/upgrade/old_owner_isolation.py](old_owner_isolation.py)
- [script/upgrade/probe_gas_gates.py](probe_gas_gates.py)
- [script/upgrade/probe_phase_c_gates.py](probe_phase_c_gates.py)
- [script/upgrade/test_manifest_exec.py](test_manifest_exec.py)
- [script/upgrade/test_manifest_phase_c.py](test_manifest_phase_c.py)
- [script/upgrade/test_old_owner_isolation.py](test_old_owner_isolation.py)
- [script/upgrade/COMMIT5_RESULTS.md](COMMIT5_RESULTS.md)
- [script/upgrade/gate_assertions.py](gate_assertions.py)
- [script/upgrade/registry_ast_allowlist.json](registry_ast_allowlist.json)
- [script/upgrade/registry_ast_proof_inputs.json](registry_ast_proof_inputs.json)

`git diff --check` passed. HEAD remains `f353af657f3df6b44d61827f9ee6b1c6d8a4ac4b`; no commit or staging was performed.
