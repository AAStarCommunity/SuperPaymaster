# Gate-removal probe table (all sites)

Generated from summary.json. Killed probes ran with --failfast; the first failing test is shown.

| Line | Function | Gate | Result | First failing test (failfast) |
|---:|---|---|---|---|
| 753 | `old_activity` | `old_proposal_complete` | survived | — |
| 756 | `old_activity` | `old_exit_cleared` | survived | — |
| 767 | `dvt_activity` | `dvt_proposal_executed` | killed | test_manifest_exec.ManifestTests.test_unsigned_dvt_proposal_stops |
| 775 | `balances` | `operator_shape` | survived | — |
| 783 | `drain_gate` | `drain_nonnegative` | survived | — |
| 785 | `drain_gate` | `drain_sum_closes` | killed | test_manifest_exec.ManifestTests.test_drain_refusals |
| 786 | `drain_gate` | `revenue_buffer` | survived | — |
| 788 | `drain_gate` | `drain_senders` | killed | test_manifest_exec.ManifestTests.test_drain_refusals |
| 1150 | `collect` | `anni_pending_nonce` | survived | — |
| 1151 | `collect` | `anni_eoa` | survived | — |
| 1153 | `collect` | `registry_version` | killed | test_manifest_exec.ManifestTests.test_collect_registry_version_negative |
| 1158 | `collect` | `fixed_old_aggregator` | survived | — |
| 1160 | `collect` | `guardian_maximum` | survived | — |
| 1163 | `collect` | `old_aggregator_owner` | survived | — |
| 1167 | `collect` | `pointer_owner` | survived | — |
| 1168 | `collect` | `old_pointer` | survived | — |
| 1174 | `collect` | `deposit_info_shape` | survived | — |
| 1176 | `collect` | `stake_not_unlocking` | survived | — |
| 1199 | `runtime_bytes` | `'immutable_supplied_' + entry['name']` | killed | test_manifest_exec.ManifestTests.test_runtime_patches_named_immutables |
| 1290 | `verify_prefix` | `prefix_stage` | killed | test_manifest_exec.ManifestTests.test_staged_metadata_guards (field='stage') |
| 1291 | `verify_prefix` | `prefix_digest` | killed | test_manifest_exec.ManifestTests.test_staged_metadata_guards (field='prefixDigest') |
| 1295 | `verify_prefix` | `prefix_boundary` | killed | test_manifest_exec.ManifestTests.test_staged_metadata_guards |
| 1296 | `verify_prefix` | `prefix_exact` | killed | test_manifest_exec.ManifestTests.test_staged_prefix_guards (kind='constructor') |
| 1300 | `stage_readback` | `stage_local` | killed | test_manifest_exec.ManifestTests.test_staged_domain_guards |
| 1302 | `stage_readback` | `stage_domain` | killed | test_manifest_exec.ManifestTests.test_staged_domain_guards |
| 1307 | `build_plan` | `manifest_inputs_required` | survived | — |
| 1310 | `build_plan` | `external_digest_nonzero` | survived | — |
| 1314 | `build_plan` | `stage_sources` | killed | test_manifest_exec.ManifestTests.test_staged_metadata_guards |
| 1319 | `build_plan` | `binding_nonempty` | survived | — |
| 1320 | `build_plan` | `fixed_old_aggregator` | survived | — |
| 1327 | `build_plan` | `sampled_inventory` | survived | — |
| 1328 | `build_plan` | `drain_inventory` | survived | — |
| 1329 | `build_plan` | `anni_binding` | survived | — |
| 1330 | `build_plan` | `sender_labels` | survived | — |
| 1331 | `build_plan` | `sender_unique` | survived | — |
| 1338 | `build_plan` | `stake_not_unlocking` | survived | — |
| 1340 | `build_plan` | `'sender_' + label` | survived | — |
| 1362 | `build_plan` | `source_plan_bytes` | killed | test_manifest_exec.ManifestTests.test_stage_source_is_exact_rebuild |
| 1364 | `build_plan` | `source_readback_prefix` | survived | — |
| 1365 | `build_plan` | `source_domain` | survived | — |
| 1368 | `build_plan` | `readback_required` | survived | — |
| 1381 | `build_plan` | `'nonempty_runtime_' + name` | survived | — |
| 1433 | `build_plan` | `guardian_slots` | survived | — |
| 1434 | `build_plan` | `guardian_inventory` | survived | — |
| 1435 | `build_plan` | `pop_count` | survived | — |
| 1437 | `build_plan` | `pop_domain` | killed | test_manifest_exec.ManifestTests.test_staged_domain_guards |
| 1438 | `build_plan` | `pop_aggregator` | killed | test_manifest_exec.ManifestTests.test_pop_binding |
| 1439 | `build_plan` | `pop_pin` | killed | test_manifest_exec.ManifestTests.test_pop_binding |
| 1451 | `build_plan` | `fixture_domain` | killed | test_manifest_exec.ManifestTests.test_staged_domain_guards |
| 1470 | `build_plan` | `'drain_operator_present_' + label` | survived | — |
| 1589 | `handover_gate` | `committee_transfer_selector` | killed | test_manifest_exec.ManifestTests.test_handover_gates_require_each_completed_step |
| 1590 | `handover_gate` | `committee_no_accept_ownership` | killed | test_manifest_exec.ManifestTests.test_committee_rejects_two_step_runtime (selector='79ba5097') |
| 1591 | `handover_gate` | `committee_no_pending_owner` | killed | test_manifest_exec.ManifestTests.test_committee_rejects_two_step_runtime (selector='e30c3978') |
| 1595 | `handover_gate` | `handover_dependencies` | killed | test_manifest_exec.ManifestTests.test_aggregator_transfer_requires_completed_admin (name='aggregator') |
| 1601 | `handover_trace` | `handover_trace_object` | survived | — |
| 1603 | `handover_trace` | `'handover_trace_' + key` | survived | — |
| 1604 | `handover_trace` | `handover_trace_success` | survived | — |
| 1612 | `handover_trace` | `handover_trace_call_count` | killed | test_manifest_exec.ManifestTests.test_registry_accept_trace_requires_timelock_caller (field='input') |
| 1613 | `handover_trace` | `handover_trace_caller` | killed | test_manifest_exec.ManifestTests.test_registry_accept_trace_requires_timelock_caller (field='from') |
| 1614 | `handover_trace` | `handover_trace_call_success` | killed | test_manifest_exec.ManifestTests.test_registry_accept_trace_requires_timelock_caller (field='error') |
| 1619 | `handover_controls` | `handover_controls_local` | survived | — |
| 1631 | `handover_controls` | `handover_positive_status` | survived | — |
| 1641 | `handover_controls` | `handover_admin_status` | survived | — |
| 1645 | `handover_controls` | `handover_control_restore` | killed | test_manifest_exec.ManifestTests.test_handover_controls_assert_reasons_success_and_restore |
| 1667 | `handover_controls` | `label + '_status'` | survived | — |
| 1672 | `handover_controls` | `handover_setter_restore` | killed | test_manifest_exec.ManifestTests.test_handover_controls_assert_reasons_success_and_restore |
| 1685 | `activation_eta_gate` | `6c_schedule_floor` | survived | — |
| 1686 | `activation_eta_gate` | `6d_timelock_eta` | killed | test_manifest_exec.ManifestTests.test_eta_rule |
| 1687 | `activation_eta_gate` | `6d_token_eta` | survived | — |
| 1691 | `b2_gate` | `B2_capped_buffer` | killed | test_manifest_exec.ManifestTests.test_b2_stop_conditions (mutate=<function ManifestTests.test_b2_stop_conditions.<locals>.<lambda> at 0x7f673a776ac0>) |
| 1693 | `b2_gate` | `B2_balances` | killed | test_manifest_exec.ManifestTests.test_b2_stop_conditions (mutate=<function ManifestTests.test_b2_stop_conditions.<locals>.<lambda> at 0x7f9fbb77ec00>) |
| 1694 | `b2_gate` | `B2_revenue` | killed | test_manifest_exec.ManifestTests.test_b2_stop_conditions (mutate=<function ManifestTests.test_b2_stop_conditions.<locals>.<lambda> at 0x7f6cf877bc40>) |
| 1695 | `b2_gate` | `B2_operator_balances` | killed | test_manifest_exec.ManifestTests.test_b2_stop_conditions (mutate=<function ManifestTests.test_b2_stop_conditions.<locals>.<lambda> at 0x7f7f85a7ee80>) |
| 1697 | `b2_gate` | `'B2_pending_slash_' + who` | killed | test_manifest_exec.ManifestTests.test_b2_stop_conditions (mutate=<function ManifestTests.test_b2_stop_conditions.<locals>.<lambda> at 0x7f7e35577100>) |
| 1701 | `b2_gate` | `B2_global_pause` | killed | test_manifest_exec.ManifestTests.test_b2_stop_conditions (mutate=<function ManifestTests.test_b2_stop_conditions.<locals>.<lambda> at 0x7f0460e7f060>) |
| 1704 | `b2_gate` | `B2_pause_history_present` | survived | — |
| 1705 | `b2_gate` | `B2_no_unpause_since_upgrade` | killed | test_manifest_exec.ManifestTests.test_b2_stop_conditions (mutate=<function ManifestTests.test_b2_stop_conditions.<locals>.<lambda> at 0x7f58a7e76d40>) |
| 1707 | `b2_gate` | `B2_single_upgrade` | killed | test_manifest_exec.ManifestTests.test_b2_single_upgrade_required |
| 1708 | `b2_gate` | `B2_upgrade_identity` | killed | test_manifest_exec.ManifestTests.test_b2_implementation_identity_required |
| 1718 | `b4_post_state` | `B4_variant` | killed | test_manifest_exec.ManifestTests.test_b4_poststate_status_exception_is_narrow (variant='third', status=1, values={'fraudProofVerifier()': 196464281818105414612061400431828927693469387727, 'pendingFraudProofVerifier()': 0, 'pendingFraudProofVerifierReadyAt()': 0}) |
| 1720 | `b4_post_state` | `B4_status` | killed | test_manifest_exec.ManifestTests.test_b4_poststate_status_exception_is_narrow (variant='apply', status=2, values={'fraudProofVerifier()': 196464281818105414612061400431828927693469387727, 'pendingFraudProofVerifier()': 0, 'pendingFraudProofVerifierReadyAt()': 0}) |
| 1754 | `execute_b4` | `B4_block_gas` | survived | — |
| 1758 | `execute_b4` | `B4_nonce_consumed` | survived | — |
| 1759 | `execute_b4` | `B4_safe_nonce` | survived | — |
| 1760 | `execute_b4` | `B4_receipt_gas` | survived | — |
| 1784 | `b4_controls` | `B4_control_initial` | survived | — |
| 1793 | `b4_controls` | `B4_control_placeholder` | survived | — |
| 1803 | `b4_controls` | `B4_wrong_gate` | survived | — |
| 1804 | `b4_controls` | `B4_wrong_status` | survived | — |
| 1807 | `b4_controls` | `B4_wrong_must_stop` | survived | — |
| 1808 | `b4_controls` | `B4_control_status` | survived | — |
| 1811 | `b4_controls` | `B4_next_nonce` | survived | — |
| 1815 | `b4_controls` | `B4_later_nonce` | survived | — |
| 1818 | `b4_controls` | `B4_control_restore` | survived | — |
| 1826 | `check_predicate` | `verifier_bound_runtime` | killed | test_manifest_exec.ManifestTests.test_a12a_runtime_is_enforced |
| 1835 | `check_predicate` | `readback_eta` | survived | — |
| 1841 | `check_predicate` | `'readback_' + p.get('signature', kind)` | killed | test_manifest_exec.ManifestTests.test_a12a_getters_are_enforced (broken='AGGREGATOR()') |
| 1852 | `batch_readback` | `batch_gas` | survived | — |
| 1854 | `batch_readback` | `batch_gas_queue_empty` | survived | — |
| 1860 | `batch_readback` | `gas_eta` | survived | — |
| 1875 | `budget` | `'budget_' + label` | killed | test_manifest_exec.ManifestTests.test_budget_includes_stake_and_deposit |
| 1881 | `validate_plan` | `external_inputs_match` | survived | — |
| 1885 | `validate_plan` | `'manifest_' + key` | killed | test_manifest_exec.ManifestTests.test_creation_layout_packet |
| 1886 | `validate_plan` | `manifest_length` | killed | test_manifest_exec.ManifestTests.test_partial_or_mutated_plan_refused |
| 1894 | `validate_plan` | `no_skipped_nonce` | survived | — |
| 1897 | `validate_plan` | `'manifest_step_' + key` | survived | — |
| 1900 | `validate_plan` | `'manifest_tx_' + key` | killed | test_manifest_exec.ManifestTests.test_partial_or_mutated_plan_refused |
| 1907 | `validate_plan` | `'B4_variant_' + key` | killed | test_manifest_exec.ManifestTests.test_b4_exact_variants_and_hash_binding |
| 1908 | `validate_plan` | `B4_apply_binding` | survived | — |
| 1910 | `validate_plan` | `B4_placeholder_intrinsic` | survived | — |
| 1923 | `validate_plan` | `manifest_budget` | survived | — |
| 1932 | `pre_send` | `manifest_local_only` | survived | — |
| 1935 | `pre_send` | `chain` | killed | test_manifest_exec.GasGateControls.test_b4_preapplied_real_measurement (tamper=None) |
| 1936 | `pre_send` | `sender_nonce` | survived | — |
| 1937 | `pre_send` | `pending_nonce` | survived | — |
| 1938 | `pre_send` | `safe_nonce` | survived | — |
| 1939 | `pre_send` | `safe_state` | survived | — |
| 1942 | `pre_send` | `bound_runtime` | killed | test_manifest_exec.ManifestTests.test_pre_send_bound_runtime_is_required |
| 1943 | `pre_send` | `old_activity_unchanged` | survived | — |
| 1945 | `pre_send` | `dvt_activity_unchanged` | survived | — |
| 1947 | `pre_send` | `registry_owner` | killed | test_manifest_exec.ManifestTests.test_pre_send_registry_owner_follows_completed_accept (accepted=False, owner='0xccdf8e0d29fb2c3061910d79484a2b653757c34b') |
| 1949 | `pre_send` | `SP_owner` | survived | — |
| 1953 | `pre_send` | `role_config_unchanged` | survived | — |
| 1955 | `pre_send` | `pending_token` | survived | — |
| 1956 | `pre_send` | `pending_token_eta` | survived | — |
| 1961 | `pre_send` | `transfer_drained` | survived | — |
| 1962 | `pre_send` | `transfer_revenue` | survived | — |
| 1970 | `pre_send` | `onchain_safe_hash` | survived | — |
| 1976 | `pre_send` | `fresh_estimate` | survived | — |
| 1977 | `pre_send` | `block_gas_limit` | survived | — |
| 1983 | `mint_trace` | `mint_trace_top` | survived | — |
| 1985 | `mint_trace` | `mint_trace_success` | survived | — |
| 1988 | `mint_trace` | `mint_trace_count` | survived | — |
| 1989 | `mint_trace` | `mint_trace_call` | survived | — |
| 1997 | `unbacked_swap_control` | `unbacked_initial` | survived | — |
| 2007 | `unbacked_swap_control` | `unbacked_shortfall` | survived | — |
| 2011 | `unbacked_swap_control` | `unbacked_refusal_gate` | survived | — |
| 2019 | `unbacked_swap_control` | `unbacked_plan_refusal_gate` | survived | — |
| 2026 | `unbacked_swap_control` | `unbacked_restore` | survived | — |
| 2034 | `early_swap_control` | `early_swap_implementation` | killed | test_manifest_exec.Round8Controls.test_early_swap_refuses_old_implementation |
| 2037 | `early_swap_control` | `early_swap_accounting` | killed | test_manifest_exec.Round8Controls.test_early_swap_requires_valid_accounting |
| 2039 | `early_swap_control` | `early_swap_token` | survived | — |
| 2040 | `early_swap_control` | `early_swap_owner` | survived | — |
| 2042 | `early_swap_control` | `early_swap_pending` | survived | — |
| 2044 | `early_swap_control` | `early_swap_future_eta` | survived | — |
| 2051 | `early_swap_control` | `early_swap_mature_token` | survived | — |
| 2052 | `early_swap_control` | `early_swap_mature_pending` | survived | — |
| 2053 | `early_swap_control` | `early_swap_mature_eta` | survived | — |
| 2056 | `early_swap_control` | `early_swap_restore` | killed | test_manifest_exec.Round8Controls.test_early_swap_detects_missing_eta_guard |
| 2067 | `controls_at` | `control_fixture_restore` | survived | — |
| 2090 | `controls_at` | `factory_control_restore` | survived | — |
| 2106 | `controls_at` | `funded_swap_restore` | survived | — |
| 2112 | `run_manifest` | `manifest_local_only` | killed | test_manifest_exec.ManifestTests.test_remote_execution_refused |
| 2123 | `run_manifest` | `frozen_step_not_skipped` | survived | — |
| 2146 | `run_manifest` | `manifest_receipt_gas` | survived | — |
| 2147 | `run_manifest` | `manifest_timestamp` | survived | — |
| 2149 | `run_manifest` | `manifest_rr_witness` | survived | — |
| 2151 | `run_manifest` | `post_nonce` | survived | — |
| 2152 | `run_manifest` | `post_safe_nonce` | survived | — |
| 2191 | `run_manifest` | `stage_steps_complete` | killed | test_manifest_exec.ManifestTests.test_staged_runner_guards |
| 2198 | `run_manifest` | `controls_complete` | survived | — |
| 2199 | `run_manifest` | `steps_complete` | survived | — |
| 2203 | `run_manifest` | `post_swap_tracked` | survived | — |
| 2204 | `run_manifest` | `post_swap_revenue` | survived | — |
| 2205 | `run_manifest` | `post_swap_capped_balance` | survived | — |
| 2206 | `run_manifest` | `accounting_unchanged_since_6d` | survived | — |
| 2211 | `run_manifest` | `post_swap_solvency` | killed | test_manifest_exec.ManifestTests.test_rehearsal_stops_on_solvency_without_pass_record |
| 2222 | `solvency_probe` | `solvency_probe_local` | survived | — |
| 2232 | `solvency_probe` | `capped_minter` | survived | — |
| 2244 | `solvency_probe` | `fixture_revenue_accrued` | survived | — |
| 2249 | `solvency_probe` | `solvency_fixture_restore` | killed | test_manifest_exec.ManifestTests.test_solvency_probe_accrues_before_withdrawing |
| 2254 | `solvency_probe` | `solvency_difference_explained` | survived | — |
| 2257 | `solvency_probe` | `solvency_accounting_sum` | survived | — |
| 2265 | `save_artifact` | `stage_not_final` | survived | — |
| 2279 | `load_artifact` | `stage_not_final` | killed | test_manifest_exec.ManifestTests.test_stage_artifact_loader_rejects_final (stage='a7') |
| 2318 | `main` | `output_empty` | survived | — |
| 2335 | `main` | `independent_pin` | survived | — |
| 2338 | `main` | `simulation_pin` | survived | — |
| 2340 | `main` | `simulation_stage` | killed | test_manifest_exec.ManifestTests.test_staged_cli_guard |
| 2352 | `main` | `engine_stderr` | survived | — |
| 2353 | `main` | `pin_recheck` | survived | — |
| 2355 | `main` | `frozen_plan_unchanged` | survived | — |

total 182 killed 57 survived 125 errors 0 survived&reached 90 survived&unreached 35
