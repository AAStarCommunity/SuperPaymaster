# L-1 offline verification — DSR rulings, 2026-11-04

Base HEAD: `f7e8dffabd71c77876cb475d06c54c35de4f9adc`. Offline, uncommitted.

Ten implementation comparisons now PASS including unmasked metadata; the fresh xPNTsToken build and all CBOR fields are recorded in [DEPLOYED_SOURCE_PARITY_RESULTS.md](DEPLOYED_SOURCE_PARITY_RESULTS.md). No live storage-authority or real-fork acceptance is claimed.

## Current gate-removal evidence

The two new focused tests failed before implementation with missing `clone_implementation` and `source_provenance` entry points. The final old-owner suite passes all implemented controls (two opt-in fork tests skipped).

79 removal probes ran. Every bad input first hit its expected STOP gate. The table groups repeated probes by gate and removal outcome; counts reflect executed trials, not distinct gates. `accepted` means the guard is necessary for that trial; `caught_elsewhere` identifies the independent remaining STOP.

| Removed gate | Outcome | Trials |
|---|---|---|
| `old_owner_allowance_0x2222222222222222222222222222222222222222_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` | `accepted` | 1 |
| `old_owner_allowance_0x696a73701b104c6ccbbaaddd2216788ea08eab89_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` | `accepted` | 2 |
| `old_owner_allowance_0xe6579a90dc498a710008de12119812d0fb7aa224_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` | `accepted` | 1 |
| `old_owner_authority_GTokenStaking_owner` | `caught_elsewhere:old_owner_control_GTokenStaking` | 1 |
| `old_owner_authority_GToken_owner` | `caught_elsewhere:old_owner_control_GToken` | 1 |
| `old_owner_authority_MySBT_daoMultisig` | `caught_elsewhere:old_owner_control_MySBT` | 1 |
| `old_owner_authority_PaymasterFactory_owner` | `caught_elsewhere:old_owner_control_PaymasterFactory` | 1 |
| `old_owner_authority_SuperPaymaster_pendingOwner` | `accepted` | 1 |
| `old_owner_authority_xPNTsFactory_owner` | `caught_elsewhere:old_owner_control_xPNTsFactory` | 1 |
| `old_owner_authority_xPNTsToken_communityOwner` | `caught_elsewhere:old_owner_control_xPNTsToken` | 3 |
| `old_owner_calldata_bytes` | `caught_elsewhere:old_owner_calldata_argument` | 1 |
| `old_owner_clone_factory_nonce1` | `accepted` | 1 |
| `old_owner_clone_implementation` | `accepted` | 1 |
| `old_owner_clone_implementation` | `caught_elsewhere:old_owner_clone_factory_nonce1` | 3 |
| `old_owner_clone_same_implementation` | `accepted` | 1 |
| `old_owner_clone_standard` | `accepted` | 4 |
| `old_owner_control_GToken` | `accepted` | 1 |
| `old_owner_control_GTokenStaking` | `accepted` | 1 |
| `old_owner_control_MySBT` | `accepted` | 1 |
| `old_owner_control_PaymasterFactory` | `accepted` | 1 |
| `old_owner_control_authority` | `accepted` | 1 |
| `old_owner_control_operator` | `accepted` | 1 |
| `old_owner_control_registration` | `accepted` | 1 |
| `old_owner_control_safe` | `accepted` | 1 |
| `old_owner_control_xPNTsFactory` | `accepted` | 1 |
| `old_owner_control_xPNTsToken` | `accepted` | 1 |
| `old_owner_creation_before` | `accepted` | 1 |
| `old_owner_fork_head` | `accepted` | 1 |
| `old_owner_fork_pin` | `accepted` | 1 |
| `old_owner_fork_positive` | `caught_elsewhere:old_owner_fork_negative` | 1 |
| `old_owner_fork_restore` | `accepted` | 1 |
| `old_owner_history_address` | `accepted` | 1 |
| `old_owner_history_canonical` | `accepted` | 1 |
| `old_owner_history_log_range` | `accepted` | 1 |
| `old_owner_history_positive` | `accepted` | 1 |
| `old_owner_history_removed` | `accepted` | 1 |
| `old_owner_history_signature` | `accepted` | 1 |
| `old_owner_implementation` | `accepted` | 1 |
| `old_owner_log_partition` | `caught_elsewhere:old_owner_history_old_filter` | 1 |
| `old_owner_mapping_GTokenStaking_authorizedSlashers` | `accepted` | 1 |
| `old_owner_mapping_Registry_authorized` | `accepted` | 1 |
| `old_owner_mapping_control_path` | `caught_elsewhere:old_owner_mapping_control_case` | 1 |
| `old_owner_mapping_xPNTsFactory_isXPNTs` | `accepted` | 1 |
| `old_owner_mapping_xPNTsToken_approvedFacilitators` | `accepted` | 2 |
| `old_owner_mapping_xPNTsToken_autoApprovedSpenders` | `accepted` | 3 |
| `old_owner_metadata_unmasked` | `accepted` | 1 |
| `old_owner_operator` | `accepted` | 1 |
| `old_owner_operator_treasury_0xb5600060e6de5e11d3636731964218e53caadf0e` | `accepted` | 1 |
| `old_owner_registry_user_roles` | `accepted` | 1 |
| `old_owner_role_Registry_0x7777777777777777777777777777777777777777777777777777777777777777` | `accepted` | 1 |
| `old_owner_role_TimelockController_PROPOSER_ROLE` | `caught_elsewhere:old_owner_event_role_TimelockController` | 1 |
| `old_owner_role_admin_0x7777777777777777777777777777777777777777777777777777777777777777` | `accepted` | 1 |
| `old_owner_role_admin_ROLE_COMMUNITY` | `caught_elsewhere:old_owner_event_role_admin` | 1 |
| `old_owner_role_log_address` | `accepted` | 1 |
| `old_owner_role_log_canonical` | `accepted` | 1 |
| `old_owner_role_log_range` | `accepted` | 1 |
| `old_owner_role_log_removed` | `accepted` | 1 |
| `old_owner_role_log_topic` | `accepted` | 1 |
| `old_owner_runtime_parity` | `caught_elsewhere:old_owner_inventory` | 1 |
| `old_owner_safe_fallback` | `caught_elsewhere:old_owner_fallback_canonical` | 1 |
| `old_owner_safe_guard` | `caught_elsewhere:old_owner_fork_negative` | 1 |
| `old_owner_safe_modules` | `caught_elsewhere:old_owner_fork_negative` | 1 |
| `old_owner_safe_owners` | `accepted` | 1 |
| `old_owner_source_rule4` | `accepted` | 3 |
| `old_owner_source_rule4` | `caught_elsewhere:old_owner_runtime_parity` | 1 |
| `old_owner_uncancelled_grants` | `accepted` | 1 |

## Current final suite lines

```text
old-owner: Ran 31 tests in 4.498s — OK (skipped=2)
manifest: Ran 223 tests in 293.178s — OK (skipped=2)
a3a exec: Ran 102 tests in 2.963s — OK
a3a send (PTY): Ran 73 tests in 79.222s — OK
git diff --check: passed
```

The sender suite used a PTY after an initial pipe-based run stalled around its terminal-confirmation test. All 73 sender tests passed on the PTY rerun. The two skips in old-owner/manifest are the existing opt-in real-fork tests.

## Historical results (superseded)

# L-1 offline verification results

Historical results for the earlier base below. For the HEAD `926a0282` offline
source-parity rerun and current test results, see
[DEPLOYED_SOURCE_PARITY_RESULTS.md](DEPLOYED_SOURCE_PARITY_RESULTS.md).

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
