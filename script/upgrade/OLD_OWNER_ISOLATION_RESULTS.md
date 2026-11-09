# L-1 offline verification — DSR re-ruling, 2026-11-04

No commit or network request. Registry is adopted under option (a), with the narrowed claim: on-chain runtime is behaviorally equivalent to the a839347e build (immutable-masked byte-for-byte equality, solc 0.8.33). Only APNTsCapped retains `deployment-record + runtime parity` with committed plan/receipt references; all other targets use `behavioral-equivalence`, matching the adopted fixtures.

All ten fresh implementation comparisons pass. The [immutable table and creation corroboration](DEPLOYED_SOURCE_PARITY_RESULTS.md#re-ruling-immutable-checks-2026-11-04) record 35 values, including 16 addresses checked against OLD and expected configuration. No live storage-authority or real-fork acceptance is claimed.

## PR #601 Low review follow-up — L1–L5

Base HEAD: `4656bd9f`. Implemented without committing or accessing the network.
All six suites ran from the repository root with the fork/control environment
variables unset, under both requested engines.

Full transaction data (including creation bytecode) is scanned for OLD, and both
primary and variant destinations reject OLD. Short calldata layouts stop at
`old_owner_calldata_payload` instead of raising IndexError. Endpoint identity now
hashes the hostname without the primary/secondary label, credentials, or path;
equal identities stop during collection and deployed-evidence replay.

Registry history includes RoleRegistered and RoleExited with the same bounded,
partition-checked log queries, canonical validation, client-side OLD filtering,
and block/transaction/log ordering. Registrations require a later exit for the
same role. Both new event types contribute to the role-id union. Per-event counts
are recorded; zero revokes/exits are allowed. Standard roles must still appear in
RoleConfigured and grant-type history. The offline Registry fixture models the
reviewer's supplied counts: 15 RoleGranted, 0 RoleRevoked, 36 RoleRegistered,
0 RoleExited, none for OLD. These are fixture inputs, not a fresh chain reading.

Gate-removal outcomes match under both engines:

| Case | Gate present | Gate removed |
| --- | --- | --- |
| L1: OLD in creation prefix | named STOP | bad fixture accepted |
| L2: primary / variant destination is OLD | named STOP for each | both bad fixtures accepted |
| L3: OLD registered without exit | named STOP | bad fixture accepted |
| L4: same endpoint host / recorded identity | named STOP in collection and replay | bad fixture accepted |
| L5: short `execute(uint256)` layout | named STOP | IndexError reproduced |

Dedicated mutants are red under both engines: L1 has one assertion failure;
L2 has two; L3 has one; L4 collection and replay each have one. L5 has one
IndexError when its gate is removed. Unmodified tests pass, including registered
then exited, mismatched-role exit rejection, empty revokes/exits, and standard
roles evidenced solely by RoleRegistered. Probe details and log hashes are in
[review-low-probes.json](fixtures/old-owner/review-low-probes.json).

Final suite lines:

```text
A3A_ENGINE_DIR=$HOME/.foundry/bin
oldowner: Ran 52 tests in 18.592s — OK (skipped=2)
manifest: Ran 287 tests in 322.019s — OK (skipped=2)
a3a: Ran 175 tests in 34.282s — OK
upgrade: Ran 141 tests in 1.209s — OK
adapter: Ran 53 tests in 0.229s — OK
release: Ran 69 tests in 3.176s — OK

Default nightly (A3A_ENGINE_DIR unset)
oldowner: Ran 52 tests in 19.352s — OK (skipped=2)
manifest: Ran 287 tests in 348.538s — OK (skipped=2)
a3a: Ran 175 tests in 34.780s — OK
upgrade: Ran 141 tests in 1.494s — OK
adapter: Ran 53 tests in 0.287s — OK
release: Ran 69 tests in 3.168s — OK

git diff --check: passed
```

The two skips in oldowner and manifest are opt-in live/fork controls.
Logs: `/tmp/low-{stable,nightly}-{oldowner,manifest,a3a,upgrade,adapter,release,mutants}.log`.
Earlier follow-ups below retain their historical results.

## PR #601 DSR follow-up — R1, R2, R3

Base HEAD: `9868c670c98341002e5a8cf5cfa8d0890a011b98`. No commit made.
All commands ran offline from the repository root, with `OLD_OWNER_FORK_PIN`,
`OLD_OWNER_FORK_RPC`, and `OLD_OWNER_CONTROL_RPC` unset. Both engines were tested:
`A3A_ENGINE_DIR=$HOME/.foundry/bin` and the default nightly (variable unset).

Role-history active grants now come from `expected_old`, the client-side OLD
subset of unfiltered logs. The dedicated omission fixture returns a canonical
OLD RoleGranted in the unfiltered query but omits it from the OLD-filtered query,
consistently across partitions. Removing the consistency gate still leaves the
uncancelled-grant gate protecting the audit.

| Dedicated negative fixture / gate | Gate present | Gate removed (both engines) |
| --- | --- | --- |
| Filtered query hides OLD grant / `old_owner_history_old_filter` | named STOP | red; `caught_elsewhere:old_owner_uncancelled_grants` |
| Non-OLD, noncanonical Safe fallback / `old_owner_fallback_canonical` | named STOP | red; bad fixture accepted |
| Safe module list contains a non-OLD module / `old_owner_module_page` | named STOP | red; bad fixture accepted |

The ordinary suite runs these removal probes through `removed_probe`. In addition,
each dedicated test was rerun with its gate suppressed in `a.need`: each mutant
produced one assertion failure and zero errors, under both engines. Evidence is
recorded in `fixtures/old-owner/adversarial-probes.json`; raw mutant logs are
`/tmp/dsr-{stable,nightly}-mutants.log`. A red history mutant means its exact gate
assertion fails, while the independent uncancelled-grant check still rejects it.

`decoded_arguments` already rejects strings and null with
`old_owner_calldata_decode`. Added manifest-level coverage for string, null,
number, and boolean cast JSON results; no decoder logic change was necessary.
`immutable_expectations` now reads `git show HEAD:deployments/config.sepolia.json`.
An isolated Git-object fixture verifies dirty entryPoint and factory addresses
do not change expectations, without modifying the real checkout or creating a
commit.

The updated probe snapshot contains 111 removal trials. Final suite results for
this follow-up are below; all later sections describe earlier runs.

```text
A3A_ENGINE_DIR=$HOME/.foundry/bin
oldowner: Ran 49 tests in 12.817s — OK (skipped=2)
manifest: Ran 284 tests in 284.239s — OK (skipped=2)
a3a: Ran 175 tests in 34.430s — OK
upgrade: Ran 141 tests in 1.206s — OK
adapter: Ran 53 tests in 0.231s — OK
release: Ran 69 tests in 3.209s — OK

Default nightly (A3A_ENGINE_DIR unset)
oldowner: Ran 49 tests in 13.307s — OK (skipped=2)
manifest: Ran 284 tests in 309.943s — OK (skipped=2)
a3a: Ran 175 tests in 34.622s — OK
upgrade: Ran 141 tests in 1.446s — OK
adapter: Ran 53 tests in 0.274s — OK
release: Ran 69 tests in 3.293s — OK
git diff --check: passed
```

Logs: `/tmp/dsr-{stable,nightly}-{oldowner,manifest,a3a,upgrade,adapter,release}.log`.
The two skips in old-owner (also imported into manifest) are opt-in live/fork tests.

Suite commands, repeated under each engine from the repository root:

```sh
python3 -B -m unittest discover -s script/upgrade -p test_old_owner_isolation.py -q
python3 -B -m unittest discover -s script/upgrade -p test_manifest_exec.py -q
python3 -B -m unittest discover -s script/a3a -p "test_*.py" -q
python3 -B -m unittest discover -s script/upgrade -p test_sp_upgrade_exec.py -q
python3 -B -m unittest discover -s script/upgrade -p test_pop_adapter.py -q
python3 -B -m unittest discover -s script/upgrade -p test_release_evidence.py -q
```

## Follow-up: proxy allowlist and independent configuration coverage

Every inventory target now reads the EIP-1967 implementation and beacon slots at
its state pin. Only Registry and SuperPaymaster are allowlisted, with their own
proxy runtime parity checks retained. Unexpected slot indirection STOPs at
`unexpected_proxy`; beacon indirection also STOPs for allowlisted targets.
Undeclared standard EIP-1167 runtimes STOP at `old_owner_undeclared_clone`.
RoleConfigured results independently require nonempty coverage of every standard
role for each emitter, without borrowing grant/revoke coverage.

New offline regression and removal probes:

| Input | Gate present | Gate removed |
| --- | --- | --- |
| GToken with an implementation slot and valid implementation bytes | `unexpected_proxy` STOP | accepted |
| GToken with a beacon slot | `unexpected_proxy` STOP | accepted |
| Undeclared GToken EIP-1167 runtime | `old_owner_undeclared_clone` STOP | caught by `metadata_cbor` |
| Empty RoleConfigured full range and both partitions, intact grant history | `old_owner_role_extraction_empty` STOP | accepted |
| RoleConfigured has a custom role but lacks the standard role | `old_owner_role_extraction_empty` STOP | accepted |
| A second emitter has empty RoleConfigured results | `old_owner_role_extraction_empty` STOP | accepted |

The clone removal probe reaches another gate; it is not a successful bypass.
A separate positive test verifies both slot reads for every inventory target at
the pin and proxy parity evidence for exactly Registry and SuperPaymaster.
Repository-wide Markdown/JSON claim searches found no remaining current claim of
`deployment-record + runtime parity` for a target other than APNTsCapped.

## Final suite lines

Run from repository root:

```text
old-owner: Ran 43 tests in 5.179s — OK (skipped=2)
manifest: Ran 235 tests in 292.297s — OK (skipped=2)
a3a (exec + send): Ran 175 tests in 33.232s — OK
git diff --check: passed
```

Commands, all from repository root:

```sh
python3 -B -m unittest discover -s script/upgrade -p test_old_owner_isolation.py -q
python3 -B -m unittest discover -s script/upgrade -p test_manifest_exec.py -q
python3 -B -m unittest discover -s script/a3a -p 'test_*.py' -q
```

The two old-owner skips (also imported by manifest) require opt-in RPC/fork
configuration and were not enabled for this offline run. Logs:
`/tmp/oldowner-tests.log`, `/tmp/oldowner-manifest-final.log`,
`/tmp/oldowner-a3a.log`. No commit was made.

Final old-owner run: 108 removal trials — 72 accepted, 32 caught elsewhere, 4 structural errors. Structural errors are not successful bypasses.

## Earlier gate-removal evidence (before this follow-up)

88 removal trials ran: 60 accepted the bad input after removal, 26 stopped at another gate, and 2 crashed. Crashes are classified separately and are not claimed as accepted bypasses. Each negative input first hit its expected STOP gate with the checker intact.

The AST-extra-getter test adds a getter to the compiler AST/ABI, extracts it, and verifies that a live-read revert propagates as STOP. It cannot become an absent surface. Pin-time tests exercise both immutable negative gates through deployed_inventory, in addition to direct runtime comparison controls.

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
| `old_owner_immutable_address_encoding` | `caught_elsewhere:old_owner_immutable_expected` | 1 |
| `old_owner_immutable_ast` | `crash:TypeError` | 1 |
| `old_owner_immutable_expected` | `accepted` | 2 |
| `old_owner_immutable_not_old` | `accepted` | 1 |
| `old_owner_immutable_not_old` | `caught_elsewhere:old_owner_immutable_expected` | 2 |
| `old_owner_immutable_values` | `crash:IndexError` | 1 |
| `old_owner_implementation` | `accepted` | 1 |
| `old_owner_log_partition` | `caught_elsewhere:old_owner_history_old_filter` | 1 |
| `old_owner_mapping_GTokenStaking_authorizedSlashers` | `accepted` | 1 |
| `old_owner_mapping_Registry_authorized` | `accepted` | 1 |
| `old_owner_mapping_control_path` | `caught_elsewhere:old_owner_mapping_control_case` | 1 |
| `old_owner_mapping_xPNTsFactory_isXPNTs` | `accepted` | 1 |
| `old_owner_mapping_xPNTsToken_approvedFacilitators` | `accepted` | 2 |
| `old_owner_mapping_xPNTsToken_autoApprovedSpenders` | `accepted` | 3 |
| `old_owner_metadata_unmasked` | `caught_elsewhere:old_owner_immutable_ast` | 1 |
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
| `old_owner_source_claim` | `accepted` | 1 |
| `old_owner_source_rule4` | `accepted` | 3 |
| `old_owner_source_rule4` | `caught_elsewhere:old_owner_runtime_parity` | 1 |
| `old_owner_uncancelled_grants` | `accepted` | 1 |

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

## Historical blocker — superseded

The following describes the earlier acceptance state and is superseded by the later results above.

All ten attempted candidate-source rebuilds stopped before compiler execution because local Chainlink submodule objects are unavailable. No per-contract runtime parity, actual deployment boundary, live historical-log completeness, live getter value or real-fork injection is claimed. Full candidate mappings and the precise remaining DSR/live inputs are in [OLD_OWNER_ISOLATION.md](OLD_OWNER_ISOLATION.md) and [deployed_source_candidates.json](deployed_source_candidates.json).

No commit or remote PR was created under the no-commit/no-network constraint.

## Timelock address correction (DSR 2026-11-05)

The TimelockController parity result previously recorded here was for
`0x86c86c789edc099801cc6a5f48334f1d67dc9564`, the earlier 48h timelock.
The canonical A3a S2 timelock is `0xccdf8e0d29fb2c3061910d79484a2b653757c34b`
(block 12032424, transaction
`0xe2c6b4276e8be5ea26057499b924c2550d29ff983fccac790784d715c117d48c`,
built at `cd9aa1c410ac926a6007b0dc0b7e95b0b3effad2`).
Both runtimes are identical and both delays are 172800, so the recorded parity
values stand. Runtime parity cannot distinguish their addresses. Address binding
comes only from `discover_targets` and its `old_owner_source_targets` equality gate.
Retained parity measurements and the earlier deployment record in
`deployed_source_candidates.json` remain explicitly bound to the legacy address;
this offline correction makes no new on-chain measurement.

`old_timelock_holds_nothing` runs at the pin and at closing. It checks all four
roles on the new timelock, the isolation authority getters, role holders and
mappings, and Safe ownership/module membership, recording every call at that
phase's single block. See [reader impact](../../docs/release/sp-upgrade-a6e/OLD_TIMELOCK_CORRECTION.md).
