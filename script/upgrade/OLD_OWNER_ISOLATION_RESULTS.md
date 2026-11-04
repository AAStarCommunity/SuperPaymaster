# L-1 offline verification results

Base HEAD: `03f8bdeb94c72b85d351235adbe6e2cdfbc0b5b0`. Changes uncommitted.

All commands ran from the repository root. Fork environment variables were removed for these runs; no network or real-fork test executed. Local cast supplies ABI encoding/decoding and keccak.

## Final suite lines

```text
script/upgrade/test_manifest_exec.py: Ran 216 tests in 284.134s — OK (skipped=2)
script/upgrade/test_old_owner_isolation.py: Ran 24 tests in 3.905s — OK (skipped=2)
script/a3a/test_a3a_exec.py: Ran 102 tests in 3.857s — OK
script/upgrade/test_sp_upgrade_exec.py: Ran 141 tests in 1.977s — OK
script/upgrade/test_pop_adapter.py: Ran 53 tests in 0.392s — OK
script/upgrade/test_release_evidence.py: Ran 69 tests in 3.630s — OK
git diff --check: passed
```

The two skips are opt-in real local-fork tests (also imported into the manifest suite). Missing fork controls remain a production STOP, not an acceptance skip.

## Gate-removal probes

Each listed mutation first hits its intended STOP gate. Removing that gate makes the exact expected-STOP assertion red. `accepted` means the bad fixture then passes; `caught_elsewhere:<gate>` identifies the independent gate that still rejects it. This is checker mutation evidence, not an attestation about the live chain.

56 individual removal probes:

```text
old_owner_runtime_parity removed=red caught_elsewhere:old_owner_inventory
old_owner_fork_pin removed=red accepted
old_owner_fork_head removed=red accepted
old_owner_fork_positive removed=red caught_elsewhere:old_owner_fork_negative
old_owner_fork_restore removed=red accepted
old_owner_uncancelled_grants removed=red accepted
old_owner_log_partition removed=red caught_elsewhere:old_owner_history_old_filter
old_owner_history_address removed=red accepted
old_owner_history_removed removed=red accepted
old_owner_history_signature removed=red accepted
old_owner_history_canonical removed=red accepted
old_owner_history_log_range removed=red accepted
old_owner_history_positive removed=red accepted
old_owner_role_TimelockController_PROPOSER_ROLE removed=red caught_elsewhere:old_owner_event_role_TimelockController
old_owner_authority_SuperPaymaster_pendingOwner removed=red accepted
old_owner_mapping_Registry_authorized removed=red accepted
old_owner_role_admin_ROLE_COMMUNITY removed=red caught_elsewhere:old_owner_event_role_admin
old_owner_authority_GTokenStaking_owner removed=red caught_elsewhere:old_owner_control_GTokenStaking
old_owner_authority_GToken_owner removed=red caught_elsewhere:old_owner_control_GToken
old_owner_authority_xPNTsFactory_owner removed=red caught_elsewhere:old_owner_control_xPNTsFactory
old_owner_authority_xPNTsToken_communityOwner removed=red caught_elsewhere:old_owner_control_xPNTsToken
old_owner_authority_MySBT_daoMultisig removed=red caught_elsewhere:old_owner_control_MySBT
old_owner_authority_PaymasterFactory_owner removed=red caught_elsewhere:old_owner_control_PaymasterFactory
old_owner_mapping_GTokenStaking_authorizedSlashers removed=red accepted
old_owner_mapping_xPNTsFactory_isXPNTs removed=red accepted
old_owner_mapping_xPNTsToken_autoApprovedSpenders removed=red accepted
old_owner_role_Registry_0x7777777777777777777777777777777777777777777777777777777777777777 removed=red accepted
old_owner_role_admin_0x7777777777777777777777777777777777777777777777777777777777777777 removed=red accepted
old_owner_allowance_0x2222222222222222222222222222222222222222_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf removed=red accepted
old_owner_operator_treasury_0xb5600060e6de5e11d3636731964218e53caadf0e removed=red accepted
old_owner_operator removed=red accepted
old_owner_registry_user_roles removed=red accepted
old_owner_allowance_0x696a73701b104c6ccbbaaddd2216788ea08eab89_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf removed=red accepted
old_owner_safe_owners removed=red accepted
old_owner_safe_modules removed=red caught_elsewhere:old_owner_fork_negative
old_owner_safe_guard removed=red caught_elsewhere:old_owner_fork_negative
old_owner_safe_fallback removed=red caught_elsewhere:old_owner_fallback_canonical
old_owner_control_GTokenStaking removed=red accepted
old_owner_control_GToken removed=red accepted
old_owner_control_xPNTsFactory removed=red accepted
old_owner_control_PaymasterFactory removed=red accepted
old_owner_control_MySBT removed=red accepted
old_owner_control_xPNTsToken removed=red accepted
old_owner_control_authority removed=red accepted
old_owner_control_registration removed=red accepted
old_owner_control_operator removed=red accepted
old_owner_mapping_control_path removed=red caught_elsewhere:old_owner_mapping_control_case
old_owner_control_safe removed=red accepted
old_owner_calldata_bytes removed=red caught_elsewhere:old_owner_calldata_argument
old_owner_role_log_address removed=red accepted
old_owner_role_log_removed removed=red accepted
old_owner_role_log_topic removed=red accepted
old_owner_role_log_canonical removed=red accepted
old_owner_role_log_range removed=red accepted
old_owner_implementation removed=red accepted
old_owner_creation_before removed=red accepted
```

The post-upgrade negative-control test additionally injects each annotated authority, membership, mapping, allowance, role-config, operator and Safe result into a replay of the full audit and requires its specific STOP gate. Fork doubles verify CONTROL success, OLD rejection and restoration through setters/getters. Source tests cover fresh-build selection, runtime mismatch, immutable masking, implementation mismatch, creation-boundary mismatch, missing source and replay tampering.

## Live acceptance remains blocked

All ten attempted candidate-source rebuilds stopped before compiler execution because local Chainlink submodule objects are unavailable. No per-contract runtime parity, actual deployment boundary, live historical-log completeness, live getter value or real-fork injection is claimed. Full candidate mappings and the precise remaining DSR/live inputs are in [OLD_OWNER_ISOLATION.md](OLD_OWNER_ISOLATION.md) and [deployed_source_candidates.json](deployed_source_candidates.json).

No commit or remote PR was created under the no-commit/no-network constraint.
