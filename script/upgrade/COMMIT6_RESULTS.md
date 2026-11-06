# Commit 6: strict older-control deletion probes

Changes are uncommitted on base HEAD `c277d5c6`. Production gates are unchanged.
All execution is offline; no RPC configuration, environment files, keystores, or chains were accessed.

## Older controls

Each strict result requires exactly one matched production statement, a green baseline,
at least one mutant assertion failure, zero mutant errors, and an AssertionError
message naming the deleted gate as checked by `gate_assertions.assertion_mentions`.

| Older control | Change | Strict result |
|---|---|---|
| `measurement_executionTimestamp` | Separate `_context` and `_transaction` controls. Context control isolates the downstream transaction validator; transaction control calls that validator directly. Both production sites remain intact. | PASS, two single-site probes |
| `test_rehearsal_funding_rechecked_after_phase_c` / `C_funding_bundler` | Replace fake gate raising with the real `funding_gate` and an offline Phase C chain whose bundler balance is one wei short. Exercise the rehearsal caller and verify it stops at the Phase C boundary. Deletion binds to the production `C_funding_` balance check. | PASS, single-site probe |
| `old_timelock_replay` | Split mismatched recorded reads and mismatched approval-owner inventory into `_reads` and `_owners` controls. | PASS, two single-site probes |
| `old_timelock_approval_history` | Split invalid creation range and malformed approval log into `_range` and `_log` controls. | PASS, two single-site probes |
| `old_owner_mapping_getter` | Bind to `test_mapping_function_getter_rejected_per_role`, whose assertion names the getter gate. Retain `test_mapping_function_falls_back` unchanged. | PASS, single-site probe |
| `proxy_runtime_all_parity_gates` | Replace the two-gate diagnostic with AST deletion probes for `old_owner_runtime_length` and `old_owner_runtime_parity`. Test extra selector bytes for length and an equal-length changed opcode for parity, for both proxies. | PASS, two single-site probes |

The gas reporting regression now requires every registered probe to be strict red,
including both timestamp sites. Proxy probes also run in the Phase C probe suite.
The audit605 harness binds each of the two replay/history statements to its own
control and rejects an unexpected number of sites.

## Verification

- `test_old_owner_isolation.py`: 97 tests, OK (skipped=2); no `LEGACY_NOT_STRICT` output.
- `test_manifest_exec.py`: 512 tests, OK (skipped=2).
- `test_manifest_phase_c.py`: 140 tests, OK.
- Both skips require an opt-in hydrated local fork; no chain was used.

The table below preserves each command's literal final nonempty combined-output line.
For the first two suites, buffered diagnostic stdout follows unittest's successful summary.

| Command | Verbatim final line |
|---|---|
| `python3 -B script/upgrade/test_old_owner_isolation.py` | `L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0` |
| `python3 -B script/upgrade/test_manifest_exec.py` | `L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0` |
| `python3 -B script/upgrade/test_manifest_phase_c.py` | `OK` |
| `python3 -B script/upgrade/probe_gas_gates.py` | `GAS_GATE_PROBES PASS 17/17` |
| `python3 -B script/evidence/enduser_mapping_probes.py` | `ENDUSER_PROBES PASS` |
| `python3 -B script/evidence/inventory_replay_probes.py` | `INVENTORY_REPLAY_PROBES PASS` |
| `python3 -B script/evidence/stale_proposal_probes.py` | `PROBES_ALL_RED=1` |
| `python3 -B script/upgrade/probe_phase_c_gates.py 645ff3a1` | `PHASE_C_GATE_PROBES PASS 205/205 red; uncovered new gates: []` |
| `python3 -B script/evidence/audit605_probes.py --jobs 3` | `AUDIT605_PROBES PASS` |

Audit605: `PROBED 94 OK 94 MISSING []`. Phase C: 205/205 strict red, no uncovered new gates.
Gas: 17/17 strict red. Appended discovery probes: 38/38; delta probes PASS.

`git diff --check` passes. No commits were created.

## DSR follow-up — incomplete, not release acceptance

This follow-up preserves the pre-existing uncommitted changes at `c277d5c6`.
No commit was created, and no live RPC, environment credentials, keystore or chain
was accessed. The earlier verification section is historical; it does **not**
certify all of the additional A–G rulings.

Implemented so far:

- `assert_stop` catches only `a.Gate`. A wrong gate fails with both names;
  acceptance fails with the expected gate name; arbitrary exceptions propagate.
  Four dedicated regressions cover these semantics.
- The xPNTs deployment-count deletion control uses duplicate logs. The empty-log
  case remains a separate rejection test.
- Runtime-key, arm-key, owner-preparation and maintenance-field schema deletion
  controls use extra fields, retaining valid downstream data.
- Gas evidence/context type controls use populated `UserDict` values: the real
  dict-only gate rejects them; deleting it permits the remaining validation.
- The deployment receipt control uses duplicate receipts; the missing receipt
  still has a normal rejection test. The record-type deletion control uses a
  populated `UserDict` and retains the missing-record integration rejection.
- Immutable prerequisite gates are factored into `validate_immutable_inputs`,
  called before decoding. Direct deletion controls test this validation boundary;
  runtime rejection cases remain. No default declaration/value was introduced.
- The Phase C pin-presence gate is factored into `stage_pin`, called by the builder
  before reading Phase C data. The stage-input and zero-price deletion controls
  exercise the existing prerequisite validators directly. No production gate
  was removed or weakened, and no production fallback was introduced.

### Corrected COMMIT 5 classification findings

The prior blanket claim that downstream exceptions can count as named Class A
failures is withdrawn for **every Class A row** in the COMMIT 5 table. Only an
expected `a.Gate` is accepted by the helper. Class B explicit typed rejection
semantics are unchanged. The complete per-entry re-audit is still pending.

The following previously claimed strict results were disproved by the first
run under corrected semantics. They were changed as described above; a final
full-driver run is required before claiming strict acceptance:

| Control / gate | Old conclusion invalid because |
|---|---|
| `test_gas_evidence_missing` | Deleted gate led to `None.get` |
| `test_remote_estimate_context` | Deleted gate led to `None.get` |
| `test_build_phase_c_runtime_keys` | Missing account key led to `KeyError` |
| `test_build_phase_c_arms` | Missing arm led to `KeyError` |
| `test_build_phase_c_owner_preparation` | Missing preparation key led to `KeyError` |
| `test_build_phase_c_maintenance_fields` | Missing gas field led to `KeyError` |
| `test_build_stage_inputs` | Missing Phase C input led to `KeyError` |
| `test_build_stage_pin_phase_c` | Missing Phase C pin led to `KeyError` |
| `test_build_C_pricing_nonzero` | Zero price led to division by zero |
| `test_xpnts_deployment_count` | Empty deployment list could lead to indexing failure |
| `test_deployment_record_binding_and_gate_removals` / `old_owner_record_receipt` | Empty receipt matches led to `IndexError` |
| Same test / `old_owner_record_required` | Missing record led to dereferencing `None` |
| `test_immutable_address_negative_controls_and_removals` / `old_owner_immutable_ast` | Missing declaration led to dereferencing `None` |
| `test_immutable_ast_and_malformed_reference_controls` / `old_owner_immutable_values` | Empty values led to `IndexError` |

### Outstanding required scope

A/B and the Registry portions of E/F/G are not implemented in this follow-up:
three-site AST exception and writer proof, three-point target binding, closed-world
AST/node-type restrictions, emit ordering, full real-build positive control,
behavioural discovery call-site replacements, authority timing matrix and all
associated strict deletion probes remain outstanding. The real-build test still
expects `old_owner_role_lowlevel_call` STOP. This is **not** the requested final
Registry proof and must not be treated as release acceptance.

### Follow-up verification logs

Logs are local `/tmp/dsr-*.log` artifacts, not committed evidence. The initial
corrected-semantics audit605 run ended with `BASELINE_SUITE RED Ran 513 tests in
465.044s`; its baseline included the old-owner controls subsequently repaired.
The initial Phase C deletion run also exposed ERRORs listed above. Neither run
is credited as passing.

| Command | Verbatim final nonempty line | Status |
|---|---|---|
| `test_old_owner_isolation.py` | `L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0` | Completed: 98 tests, OK (skipped=2). |
| `test_manifest_exec.py` | `L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0` | Earlier snapshot: 517 tests, FAILED (failures=4, skipped=2); not final-tree validation. |
| `test_manifest_phase_c.py` | `OK` | Completed before stage_pin extraction: 140 tests, OK; final boundary tests also pass. |
| `probe_gas_gates.py` | `GAS_GATE_PROBES PASS 17/17` | Completed. |
| `inventory_replay_probes.py` | `INVENTORY_REPLAY_PROBES PASS` | Completed. |
| `stale_proposal_probes.py` | `PROBES_ALL_RED=1` | Completed. |

`probe_phase_c_gates.py 645ff3a1`, `audit605_probes.py --jobs 3`, and
`enduser_mapping_probes.py` were launched but no final successful result is
claimed. The first audit605 run failed its baseline; a subsequent run is in
`/tmp/dsr-audit-final.log`. The second Phase C run was interrupted (exit 130)
after source movement made its line-number bindings stale. The initial Phase C
log is `/tmp/dsr-phase.log`; end-user log is `/tmp/dsr-enduser.log`. These are not
accepted final-tree evidence. A fresh fixed-source full run is still required.

Focused final-source C/D probes (`/tmp/dsr-cd.log`) ended with:

```text
stage_pin_phase_c PASS
C_funding_bundler PASS
C_funding_bundler PASS
old_owner_runtime_length PASS
old_owner_runtime_parity PASS
```

Both funding controls (the live gate and the rehearsal caller) were exercised;
each proxy gate was removed separately. Each PASS above uses the existing strict
runner: one site, green baseline, at least one named assertion failure, no errors.

`git diff --check` passed at this checkpoint. No release acceptance is claimed.

## 6b

**Partial checkpoint; not release acceptance. No commit was made.** All changes
are offline. No live RPC, environment file, keystore, transaction, deployment,
pre-send/closing target reads, or authority time-point matrix was used or added.

### Implemented

- A: `registry_ast_allowlist.json` now has exactly three `callSites`, with the
  archived Registry source keccak, enclosing function/name/src, member src,
  target storage variable, resolved interface function/path/src, and reason.
  Only direct `.call(abi.encodeCall(...))` matches; options, other call kinds,
  unmatched calls, changed offsets, and missing/extra entries STOP. Evidence
  records the three consumed entries.
- A: complete target-writer enumeration is compared with reviewed assignment
  offsets in `targetWriters`. Initializer/owner modifiers resolve by declaration
  ID to keccak-pinned OZ sources. No immutable assumption is used for these
  variables. Extra/missing writers and absent/non-OZ owner modifiers STOP.
- A, pin only: `registry_callsite_targets` reads through the Registry proxy using
  the existing recorded offline audit calls, compares full lowercased addresses
  with `targets['GTokenStaking']`, `targets['MySBT']`, and `u.SP`, and records
  `registryCallsiteTargets` plus the raw reads. Fake-RPC mismatch and middle-byte
  controls pass. Canonical config/staking/SBT/SP equality is tested.
- B / H1-H3: imported free functions and library bodies join the opaque scan;
  modifiers remain included. Free-function references, using-for directives,
  storage-parameter member calls, and unreviewed storage returns STOP. Required
  import sources cannot silently disappear. Pinned OZ storage helpers retain
  their existing keccak exception.
- F1: `registry_ast_node_types.json` records the actual archived build ID,
  source keccaks and Solidity body-node set. Unknown body node types STOP before
  the semantic rules. Non-OZ assembly is rejected completely; Registry's Yul
  allowlist is empty. Yul `return`, `stop`, `selfdestruct`, and `invalid` STOP
  anywhere scanned, including otherwise trusted source bodies.
- H4 / F4 / G1: configureRole's sole RoleConfigured emit must follow all its
  direct roleConfigs writes in the same function. Nested/later writes, early
  returns, try/catch and intervening calls STOP, except exactly one resolved
  typed `GTOKEN_STAKING.setRoleExitFee` call. The sole modifier must resolve to
  pinned OZ nonReentrant, with the reviewed before/placeholder/after body shape.
  `_initRole` remains initializer-only and enumerated through `init_ids`.
- M5: initializer-only proof now resolves the actual modifier declaration and
  verifies the OZ source hash. Missing required allowlisted source inputs STOP.
- F2: the archived-build regression now expects PASS and exactly three consumed
  sites. The archive is required, never skipped. `registry_ast_proof_inputs.json`
  records AST PASS and the consumed entries; this is not chain acceptance.
- F3: `script/evidence/registry_ast_probes.py` binds every one of the ten new
  gates and the changed existing gates to strict one-site deletion controls.
  It also tests the call/writer/emit variants and extraction-scope seams.
- M6, targeted: retained strict `assert_stop`; removed the remaining broad
  exception conversion in `DiscoveryTests.gate`. Replaced the old
  `test_role_control_case_without_path_gate` crash-catching control with a valid
  UserDict adverse case: deleting the dict gate now reaches acceptance and
  fails with `old_owner_role_control_case: Gate not raised`, errors=0.
  The existing duplicate-log count control and separate empty-log case remain.
- Updated synthetic inventory fixtures with the real reviewed sites, writer
  assignments and OZ declarations. Generic authority replies now preserve
  concrete discovered target values. Updated extraction-call deletion seams
  for the new function signatures.

### Still undone

1. **M7:** `DiscoveryCallTests` still uses source-spelling assertions. The 26
   discovery-call controls have NOT been replaced with adverse fake-RPC
   behavioral tests and corresponding strict call-site deletion probes. Their
   historical green results are not credited as behavioral evidence.
2. **F5:** the complete COMMIT 5 A/B table has NOT been re-audited under strict
   exception semantics. The earlier 6a invalidation table remains applicable.
   Two additional conclusions changed here: the old role-control-case probe's
   A classification depended on catching arbitrary exceptions; it is now
   replaced and strictly red by acceptance. `DiscoveryTests.gate` also caught
   arbitrary exceptions; that conversion is removed, but the whole family
   still needs a completed strict deletion re-audit. No unchanged table row is
   newly certified by this checkpoint.
3. **M6 global acceptance:** all deletion drivers were launched again. The
   Phase C, audit605 and enduser drivers were interrupted before completion
   (exit 130); no full-driver PASS is claimed for them. Fix any further strict
   failures and complete those runs after M7/F5. The earlier runs that failed
   on fixture address overwrites are not accepted evidence.
4. **F3 completeness beyond Registry:** the new Registry gates have strict
   probes, but the missing M7 controls/global re-audit prevent claiming the
   entire requested 6b acceptance scope complete.

The pre-send/closing target reads and authority time-point matrix are deliberately
out of scope for this pass, not implemented, and not counted as completed work.

### Verification evidence

Final Registry deletion command:
`python3 -B script/evidence/registry_ast_probes.py`.
Each PASS below requires a green baseline, exactly one deleted statement,
failures >= 1, errors == 0, and the gate in an AssertionError message. The gate
coverage comparison against HEAD found ten new gates and zero uncovered gates.

```text
REGISTRY_AST_PROBE test_node_type gate=old_owner_role_node_type baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_free_function gate=old_owner_role_free_function baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_using_for gate=old_owner_role_storage_escape baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_storage_receiver gate=old_owner_role_storage_escape baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_using_library_assembly_scope gate=old_owner_role_storage_escape baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_storage_return gate=old_owner_role_storage_return baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_yul_terminator gate=old_owner_role_yul_terminator baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_missing_allowlisted_source gate=old_owner_role_allowlisted_source baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_extra_writer gate=old_owner_callsite_target_writers baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_setter_without_owner gate=old_owner_callsite_target_writers baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_setter_non_oz_owner gate=old_owner_callsite_target_writers baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_missing_writer gate=old_owner_callsite_target_writers baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_initializer_declaration gate=old_owner_role_initializer_only baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_configure_guard gate=old_owner_role_configure_guard baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_modifier_post_termination gate=old_owner_role_configure_guard baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_nested_write gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_early_return gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_before_write gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_internal_call gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_two_calls gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_try gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_different_target gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_emit_different_function gate=old_owner_role_configure_emit baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_extra_call gate=old_owner_role_lowlevel_call baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_delegatecall gate=old_owner_role_lowlevel_call baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_call_value gate=old_owner_role_lowlevel_call baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_call_gas gate=old_owner_role_lowlevel_call baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_call_wrong_target gate=old_owner_role_lowlevel_call baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_call_wrong_interface gate=old_owner_role_lowlevel_call baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_modifier_delegatecall_scope gate=old_owner_role_lowlevel_call baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_src_offset gate=old_owner_role_callsite_count baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_allowlist_two gate=old_owner_role_callsite_count baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_allowlist_four gate=old_owner_role_callsite_count baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_pin_target_middle_byte gate=old_owner_role_callsite_target baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_pin_target_rpc_mismatch gate=old_owner_role_callsite_target baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_free_function_assembly_scope gate=old_owner_role_assembly baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBE test_library_assembly_scope gate=old_owner_role_assembly baseline=green sites=1 failures=1 errors=0 PASS
REGISTRY_AST_PROBES PASS 37/37 strict red
```

Final requested command: `python3 -B script/upgrade/test_old_owner_isolation.py`.

```text
Ran 138 tests in 52.716s
OK (skipped=2)
```

The two skips are the pre-existing opt-in live/fork controls. The archived-build
positive control ran and passed; no archive absence was skipped.

Other completed offline checks:

```text
GAS_GATE_PROBES PASS 17/17
INVENTORY_REPLAY_PROBES PASS
```

The focused discovery baseline completed with `Ran 25 tests in 76.548s` and
`OK`. This is baseline evidence only, not M7 call-deletion acceptance.

Local logs: `/private/tmp/registry-6b-unit-final.log`,
`/private/tmp/registry-6b-probes-final.log`,
`/private/tmp/registry-6b-gas.log`,
`/private/tmp/registry-6b-replay-final.log`. Interrupted global runs:
`/private/tmp/registry-6b-phase-final.log`,
`/private/tmp/registry-6b-audit-final.log`,
`/private/tmp/registry-6b-enduser-final.log`.

The final stale-proposal driver also completed successfully
(`/private/tmp/registry-6b-stale-final.log`):

```text
SOURCE_UNCHANGED 1
PROBES_ALL_RED=1
```

`git diff --check` passed. No ERROR or interrupted run is credited as proof.


## 6c

Work in progress on base HEAD `49bb77420d0e079b07d9ba1b4c772de8ade6d8ac`
(COMMIT 6b). No commit, network RPC, environment credentials, keystore, or chain
was used. All transaction counts below come from offline fakes.
This section supersedes no historical results above and is **not full 6c acceptance**.

### Implemented

- Item 1: `pre_send` and `dvt_closing` now read all three Registry target getters
  at their selected block through `registry_callsite_targets`, before discovery.
  Expected values still come from committed `deployments/config.sepolia.json`.
  Tests change each getter at pre-send for every packet step, and at closing.
  Look-alike targets answer as the real targets rather than crashing a fake.
  The known 6b closing authority rows now expect `old_owner_role_callsite_target`;
  none are skipped. Existing fixtures answer `SUPER_PAYMASTER()` correctly.
- Item 2, partial: `test_authority_checkpoints.py` covers the 3 × 2 × 2 matrix
  for Registry `owner()` and an existing standard role config owner, with
  OLD/OLD_TIMELOCK and pin/pre-send/closing. Four behavioral deletion probes
  bind both authority-check calls in pre-send and closing.
- Item 4: whole-call deletion controls for `stage_pin` in `build_plan` and
  `validate_immutable_inputs` in `decode_immutable`. Adverse containers preserve
  downstream data while denying declaration/presence; deleting the calls permits
  acceptance rather than an indexing error. No production fallback was added.
- Item 5: `ExceptionStopTests` drives the real rehearsal loop through
  `manifest_exec.main`. Injected KeyError at first pre-send yields zero receipt
  calls; at k=2 and k=3 pre-send/measurement/readback yield k−1/k−1/k sends,
  rc 1 and `FAILURE.json` naming `manifest_error`. Sign/send refusals in all three
  entrypoints return rc 3 without RPC construction or HTTP access; a3a/SP output
  directories receive the disabled failure record. Whole-handler deletions in
  manifest/a3a main must fail assertions naming `manifest_error`/`executor_error`.
- Item 6: `swallow_audit.py` computes a conservative AST function-reference closure
  from `run_manifest` across the six requested modules. It follows import aliases,
  module aliases, lexical helpers, nested callbacks and RPC callable methods.
  Broad handlers without guaranteed raising must match a reviewed body hash.
  Tests inject Exception/BaseException/bare handlers, a cross-module callback,
  a partial re-raise, and an altered allowlisted body. Line-number changes preserve
  identity. A strict deletion probe removes the check itself.

### Reviewed swallow allowlist

The machine-readable source is `script/upgrade/swallow_allowlist.json`.

| Module | Function | Exception | Handler-body SHA256 | Reason | Condition under which execution continues |
|---|---|---|---|---|---|
| a3a_exec | RPC._post_with_deadline.work | Exception | 15a0fb0c037bd1cbc065647524c5eb1c4177a1a0c4517a86ac5c0eb3da456932 | Worker transfers the exception to the waiting caller in `box['error']`. | Only the worker returns. After join, the caller raises the stored error; deadline expiry raises TimeoutError. No successful RPC result is returned. |

### Undone / not certified

- Item 2: role first configured by a packet step and present only in closing
  inventory; full standard/event/history role coverage and real Registry inventory
  assertion. An exploratory read of the existing local Registry artifact through
  `inventory_source(ROOT, mode='release', names=('Registry',))` STOPped at
  `old_owner_role_callsite_count`; it was not bypassed or accepted.
- Item 3 (M7): the existing `DiscoveryCallTests` spelling checks have **not** all
  been replaced. Their historical PASS output is not behavioral evidence.
- Item 7: complete per-row COMMIT 5 A/B re-audit and changed-conclusion table.
- Item 8: complete provenance column 5 table for #599/#601/#604, including all
  adverse inputs and classification of every probe beyond the known 14.
  In particular `removed_probe` still suppresses by gate label, without proving
  a single source site. Its green suite is not strict single-site certification.
- No claim that every requested control is ASSERT named is made while these
  items remain open. ERROR and unnamed assertion outcomes never count as success.

### Verification

Final command summaries are recorded below after completion. Initial manifest
verification exposed outdated address-read mocks (15 failures and 1 error);
these were repaired, and the affected 16 tests passed. Initial closing-target
mutation reached an unprogrammed post-packet token in the fake; using the closing
state inventory repaired it. Those initial runs were rejected, not accepted.


### Provenance findings so far

One additional probe beyond the known 14 was disproved in this run:

| Origin | Test | Gate | 6b input/result | 6c adverse input/result |
|---|---|---|---|---|
| #604 | SnapshotControlTests.test_control_slot_readback | C_control_layout_cachedPrice | Missing cachedPrice entry; HAS-ERROR (`IndexError` after deletion). | Duplicate valid cachedPrice entries; the first remains decodable. Focused strict rerun: ASSERT named. The missing-entry rejection remains a separate test. |

#599 was rerun in full: `GAS_GATE_PROBES PASS 17/17`. All following inputs
are unchanged from 6b; no new production fallback or disabled gate was needed.

| Test (GasGateControls) | Gate | Adverse input | Result |
|---|---|---|---|
| test_gas_evidence_missing | gas_evidence_missing | Populated UserDict instead of dict | ASSERT named |
| test_remote_estimate_context | remote_estimate_context | Populated context UserDict instead of dict | ASSERT named |
| test_measurement_executionTimestamp_context | measurement_executionTimestamp | Zero timestamp and matching zero time override; separate gas validator isolated | ASSERT named |
| test_measurement_executionTimestamp_transaction | measurement_executionTimestamp | Zero transaction timestamp | ASSERT named |
| test_measurement_blockGasLimit | measurement_blockGasLimit | Float block limit 200000000.0 | ASSERT named |
| test_B4_variant_measurements | B4_variant_measurements | Extra unexpected variant key | ASSERT named |
| test_B4_placeholder_measurements_tx | B4_placeholder_measurements | Unexpected populated tx key | ASSERT named |
| test_B4_placeholder_measurements_unexpected | B4_placeholder_measurements | Extra unexpected placeholder key | ASSERT named |
| test_fresh_estimate_pin | fresh_estimate_pin | Missing pin block with overrides | ASSERT named |
| test_remote_margin | measured_gas_limit | Limit based on 68394 despite remote estimate 135104 | ASSERT named |
| test_missing_remote | remote_estimate_missing | Missing estimateGas | ASSERT named |
| test_wrong_pin | remote_estimate_pin | Evidence block 0x124 instead of 0x123 | ASSERT named |
| test_missing_override | remote_estimate_overrides | Empty state overrides | ASSERT named |
| test_fresh_estimate | fresh_estimate | Fresh estimate one above gas limit | ASSERT named |
| test_block_limit | block_gas_limit | Block limit one below transaction gas | ASSERT named |
| test_wrong_time_override | remote_estimate_time | Override timestamp one above execution timestamp | ASSERT named |
| test_wrong_prior_steps | remote_estimate_prior_steps | Missing prior step in prefix | ASSERT named |


A second additional adverse-input defect was found in
`OldOwnerIsolationTests.test_legacy_timelock_source_targets` /
`old_owner_source_targets` (#604 binding of a #601 test): replacing the current
Timelock record with the legacy record caused HAS-ERROR (`KeyError`) on deletion.
The deletion input now adds the legacy record while retaining the current record;
the replacement rejection remains a separate test.

The first Phase C pass also exposed a driver defect: re-executing the complete
`old_owner_isolation` module during a mutation replaced the offline
`callsite_target_expectations` patch with the real config reader. Mutants then
failed in fixture setup at `old_owner_role_callsite_target`. These are rejected
HAS-ERROR runs, not evidence for the gate being deleted. The driver now recompiles
only the containing top-level function, retaining unrelated fixture bindings.
Exactly one failing source statement and the strict named-assertion/zero-error
criterion remain mandatory. A fresh full driver run was started after this fix.


### Latest completed verification summaries

Verbatim summary lines (no runner ERROR is accepted):

| Command | Summary | Log |
|---|---|---|
| `test_old_owner_isolation.py` | `Ran 143 tests in 143.173s` / `OK (skipped=2)` | `/tmp/6c-isolation-final.log` |
| `test_manifest_exec.py (latest completed; final rerun pending)` | `Ran 525 tests in 597.572s` / `OK (skipped=2)` | `/tmp/commit6c-checks/test_manifest_exec.log` |
| `test_manifest_phase_c.py` | `Ran 141 tests in 443.941s` / `OK` | `/tmp/6c-phase-final.log` |
| `test_a3a_exec.py` | `Ran 102 tests in 3.886s` / `OK` | `/tmp/commit6c-checks/test_a3a_exec.log` |
| `test_sp_upgrade_exec.py` | `Ran 141 tests in 2.563s` / `OK` | `/tmp/commit6c-checks/test_sp_upgrade_exec.log` |
| `probe_gas_gates.py` | `GAS_GATE_PROBES PASS 17/17` | `/tmp/6c-gas-final.log` |
| `inventory_replay_probes.py` | `INVENTORY_REPLAY_PROBES PASS` | `/tmp/commit6c-checks/inventory_replay_probes.log` |
| `registry_ast_probes.py` | `REGISTRY_AST_PROBES PASS 40/40 strict red` | `/tmp/6c-registry-final.log` |
| `stale_proposal_probes.py` | `PROBES_ALL_RED=1` | `/tmp/commit6c-checks/stale_proposal_probes.log` |
| `probe_commit6c.py` | `COMMIT6C_PROBES PASS 12/12 strict red` | `/tmp/6c-probes-final12.log` |
| `test_authority_checkpoints.py` | `Ran 6 tests in 17.489s` / `OK` | `/tmp/commit6c-checks/test_authority_checkpoints.log` |
| `test_swallow_exceptions.py` | `Ran 6 tests in 7.799s` / `OK` | `/tmp/6c-swallow-final.log` |
| `test_manifest_exec.py ExceptionStopTests (final strengthened fault-reached assertions)` | `Ran 4 tests in 0.130s` / `OK` | `/tmp/6c-exceptions-final.log` |


### Running commands at the budget checkpoint

All requested commands were started. The following have no completed final summary
at this checkpoint; they are **not** reported as PASS:

| Command | Output log | Tool session / owner |
|---|---|---|
| final test_manifest_exec.py rerun after retained source-replacement test | /tmp/6c-manifest-final.log | 15211 |
| fresh probe_phase_c_gates.py 645ff3a1 after harness/input fixes | /tmp/6c-phase-probes-final.log | 72809 |
| audit605_probes.py --jobs 3 | /tmp/commit6c-checks/audit605_probes.log | batch 36207 |
| enduser_mapping_probes.py | /tmp/commit6c-checks/enduser_mapping_probes.log | batch 36207 |

The initial Phase C run, whose log is
`/tmp/commit6c-checks/probe_phase_c_gates.log`, predates the harness and adverse-input
repairs. Its HAS-ERROR results are rejected. It may still finish its discovery
subset; that does not supersede the fresh run. The original batch also contains
inventory/stale/Registry checks; completed standalone summaries above are retained.
The audit605 baseline was green (`BASELINE_SUITE green Ran 521 tests in 590.854s`),
but that baseline alone is not a successful deletion audit.

No commits were made. `git diff --check` passed at this checkpoint. Work remaining
is explicitly listed above; full 6c acceptance is withheld.
