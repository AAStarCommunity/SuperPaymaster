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

## 6d

This is an uncommitted follow-up to the COMMIT 6c checkpoint. No RPC endpoint,
environment file, keystore, or chain was used. No production gate was relaxed.
`assert_stop` still accepts only `a.Gate`. **6d acceptance is withheld** until
all requested items and verification are complete.

### Implemented

- **0:** Removed the import-time `patch.object(...).start()`. Synthetic callsite
  expectations now have fixture-owned cleanup in the two isolation test classes
  and the manifest classes that need pin/audit fixtures. Restored the complete
  `probe_phase_c_gates.run()` body from `49bb7742`; AST comparison confirms equality.
  The first restored-driver attempt was interrupted to finish fixture scoping;
  it supplies no acceptance evidence. The sequential verification below reruns it.
- **A:** Pin collection records `callsiteTargetSource` with the fixed config path,
  resolved HEAD, SHA-256 of git-show bytes, and lowercase expected addresses.
  `build_plan` validates path, commit against rebuild commit, SHA-256, and expected
  values using named gates. Pre-send and closing pass the plan's expected values
  explicitly, with no config read. The config metadata is checked separately from
  the RPC transcript; transcript replay retains its existing equality checks.
  Five focused tests pass, including a patched git-show reader whose one-byte
  whitespace change rejects the old pin and changes the new saved-plan digest.
  All four source-binding deletion probes have a green baseline, one source site,
  named FAIL assertions, and zero errors. Target getter tests also prohibit calling
  the pin-time expectation reader during execution.
- **H:** Added worker `KeyError` and custom-exception tests requiring the exact
  exception object to escape `_post_with_deadline`. The fake response decodes a
  body before its context-manager exit raises, matching a real possible response
  lifecycle; deleting re-raise therefore returns a body rather than encountering
  an unprogrammed fake. Tests cover both a live worker and an elapsed deadline.
  Whole-module deletion of each caller raise statement gives two named assertion
  failures and zero errors. `COMMIT6D_PROBES PASS 2/2 strict red`.

- **B:** Implemented in the B-only continuation below; its final verification is
  recorded there. The preliminary inventory is superseded by the closed DSR table.

### Outstanding

- **C:** Execution HEAD and clean-tree gates and their deletion controls remain undone.
- **D:** `DiscoveryCallTests` still checks source spelling; behavioural replacements
  and their strict deletion controls remain undone.
- **E:** Closing-only packet role authority matrix and real archived Registry
  `authority_rows` union test remain undone.
- **F:** Complete row-by-row COMMIT 5 A/B re-audit remains undone. The older statement
  that arbitrary downstream exceptions count as named Class A failures remains
  withdrawn; current green suites alone do not establish every deletion claim.
- **G:** Complete #601/#604 per-probe provenance and the inventory beyond the known
  16 remain undone. Internal `removed_probe` controls suppress names, not exactly
  one source statement; their `L1_CONTROL` output alone is not strict evidence.

### B: preliminary execution read inventory (historical, superseded below)

This inventory uses the repository AST call-closure scanner with the seven requested
entry points as roots. It conservatively includes cached helpers and fallback
branches; cache hits are not proof that a read cannot happen. Duplicate nested
worker entries are consolidated. No allowlist approval is inferred from this table.

| Reachable function / operation | Data read | Disposition |
|---|---|---|
| `pre_send`, `dvt_closing` → Registry getter expectations | Previously `git show HEAD:deployments/config.sepolia.json` | Moved to `plan.pin.oldOwnerIsolation.callsiteTargetSource.expected`; pin/build retain the committed-byte read. |
| `pre_send` → `u.governance` → `u.runtime` → cached `u.build` | Forge version; `a.compile_commit(CANDIDATE, ...)` | **Unresolved:** move runtime identity to plan or prove an explicit pre-execution binding; do not rely on cache warmth. |
| `a.compile_commit` → `a.archive_commit` | `git archive`, `git ls-tree`, submodule `git rev-parse`, `git cat-file` | **Unresolved** transitive build reads; no runtime allowlist exception granted. |
| `a.compile_commit` | Archived `foundry.toml` via `Path.read_text` / TOML parse; offline Forge build | **Unresolved** transitive build reads. Temporary archive location does not make source trust independent of the repo. |
| `a.raw_artifact` | Archived build JSON via `Path.read_text` / JSON parse | **Unresolved** transitive build read. |
| `a.immutable_identity` | Runtime identity artifact via `Path.read_text` / JSON parse | Conservative fallback reachability; must bind the supplied plan identity and exclude runtime fallback. **Unresolved.** |
| `a.committed_bytes` | `git show` and `git ls-tree`, including pinned gitlinks | **Unresolved** transitive artifact-source reads. |
| `u.build`, `a.validate_artifact` | `json.loads` of artifact metadata | Parse of build data; not a separate file access, but inherits unresolved artifact provenance above. |
| `a.RPC._post_with_deadline.work` | `json.loads(r.read())` | RPC response bytes, not a repository-file read. No network was used in this audit. |
| `a.cast` | Cast subprocess output | ABI encoding/hash operation; no repository source input is passed. Binary is outside `u.ROOT`. |

There were no direct `open`, `Path.read_text` or `Path.read_bytes` calls in the
seven root function bodies. The relevant reads are in transitive helpers above.
The runtime guard itself must be installed after plan validation and remain in
scope across execution, including late validation; this is still outstanding.

### Resumed A-fix (2026-11-07)

The prior `/tmp/commit6d-checks` batch died with its session. Its recorded suite
claims and queued/running driver states are withdrawn as evidence for this turn.
No full driver batch is launched here; the operator runs drivers after review.

- **A-fix implemented:** `collect` reads `callsite_target_source()` once, passes
  its `expected` object through `collect_deployed` into `audit`, and records the
  identical source object. The fallback helper is deleted; expectations are
  mandatory at every Registry target check and audit/replay caller. Replay and
  release checks receive explicit expectations, without a repository fallback.
- Added a behavioural identity test through the real `collect_deployed`: one
  source-reader invocation, recorded source identity, and audit argument identity.
- **0 / A / H:** reviewed incoming changes retained; H is not reimplemented.
- **B, C, D, E, F, G:** remain outstanding as described above. This continuation
  stops at the A-fix boundary; no later item is claimed complete.

Verification results for this continuation are recorded below once commands exit.
No commit, RPC, environment-file, keystore, or chain access is authorized or used.

All commands below exited successfully. The initial old-owner suite (143 tests,
`Ran 143 tests in 40.085s`, `OK (skipped=2)`, final line
`L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0`)
briefly overlapped the manifest suite; it was repeated alone after the other
checks. Retained sequential order: manifest, phase C, A3A, SP, authority, swallow,
focused A tests, focused A probes, old-owner. The focused tests cover the final
execution-fake edits made while the manifest suite was running.

The last output line is shown literally, including buffered `L1_CONTROL` output
that appears after unittest's summary. Those internal controls are **not** newly
claimed as strict single-site evidence; F/G remain outstanding.

| Command | Exit | Unittest summary | Verbatim final line |
|---|---:|---|---|
| `python3 script/upgrade/test_old_owner_isolation.py` | 0 | `Ran 143 tests in 38.856s`; `OK (skipped=2)` | `L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0` |
| `python3 script/upgrade/test_manifest_exec.py` | 0 | `Ran 532 tests in 403.963s`; `OK (skipped=2)` | `L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0` |
| `python3 script/upgrade/test_manifest_phase_c.py` | 0 | `Ran 141 tests in 189.816s`; `OK` | `OK` |
| `python3 script/a3a/test_a3a_exec.py` | 0 | `Ran 102 tests in 3.148s`; `OK` | `OK` |
| `python3 script/upgrade/test_sp_upgrade_exec.py` | 0 | `Ran 141 tests in 1.402s`; `OK` | `OK` |
| `python3 script/upgrade/test_authority_checkpoints.py` | 0 | `Ran 6 tests in 12.749s`; `OK` | `OK` |
| `python3 script/upgrade/test_swallow_exceptions.py` | 0 | `Ran 9 tests in 2.561s`; `OK` | `OK` |
| `python3 /tmp/6d-resume-focused-tests.py` | 0 | `Ran 6 tests in 16.426s`; `OK` | `OK` |
| `python3 /tmp/6d-resume-focused.py` | 0 | `COMMIT6C_PROBES PASS 7/7 strict red` | `COMMIT6C_PROBES PASS 7/7 strict red` |

Focused probe selection: the two Registry execution-call cases from
`probe_commit6c.CASES`, four `validate_callsite_source` gates paired with
`ManifestTests.test_callsite_source_*`, and the target-comparison gate paired with
`RegistryASTProofTests.test_pin_target_rpc_mismatch`. This is a seven-case subset
using the existing strict driver, not the full `probe_commit6c` batch. Exact output:

```text
test_pre_send_target_change: gate=old_owner_role_callsite_target sites=1 baseline=green failures=264 errors=0 ASSERT named
test_closing_target_change: gate=old_owner_role_callsite_target sites=1 baseline=green failures=3 errors=0 ASSERT named
test_callsite_source_path: gate=callsite_source_path sites=1 baseline=green failures=1 errors=0 ASSERT named
test_callsite_source_commit: gate=callsite_source_commit sites=1 baseline=green failures=1 errors=0 ASSERT named
test_callsite_source_sha256: gate=callsite_source_sha256 sites=1 baseline=green failures=1 errors=0 ASSERT named
test_callsite_source_expected: gate=callsite_source_expected sites=1 baseline=green failures=1 errors=0 ASSERT named
test_pin_target_rpc_mismatch: gate=old_owner_role_callsite_target sites=1 baseline=green failures=1 errors=0 ASSERT named
COMMIT6C_PROBES PASS 7/7 strict red
```

Logs and focused invocation scripts: `/tmp/6d-resume-*`. Results above are copied
here so evidence does not depend on a live process or temporary-log persistence.
Full requested probe drivers remain **not run this turn**, pending operator review.
HEAD remains `171807d936ef1b9d4fcecf0ff63d09cd99193884`. No commit or staging.
All foreground commands launched by this continuation have exited; no worker or
background process was launched or left running. `git diff --check` passes.


### B-only continuation: execution-time repository reads (DSR)

Scope is exactly **B**. Incoming **0 / A / A-fix / H** remain intact. **C / D / E /
F / G remain undone**; overall 6d acceptance remains withheld. No commit or staging,
RPC, environment-file, keystore, or chain access. No full probe-driver batch.

`run_manifest` first validates/reconstructs the plan and captures a detached
expected plan. It loads `execution_read_allowlist.json`, then enters the read
barrier before impersonation, controls, or the first `pre_send`. The barrier stays
active through measurement, receipts, readbacks, closing and final validation,
and restores every patched function on both success and exception.

`pre_send` passes `plan.timelockRuntimeIdentity` explicitly to `u.governance`;
`governance` has no source/build fallback. The builder derives that identity from
the fixed candidate build and normal plan validation compares it. Closing plan
validation and the omitted-mint negative control receive the already-validated
expected plan explicitly. They retain the field, transaction, gas, budget and
missing-step checks, without rebuilding during execution. Cache warmth is not a
security assumption.

The reviewed allowlist is **empty**: no repository read is justified during
execution. Its top-level reason documents why. The barrier patches
`builtins.open`, `io.open` (including `Path.open`), `Path.read_text`,
`Path.read_bytes`, and `subprocess.run` for git. It checks read/update modes,
relative paths, resolved paths and resolved prefixes, including symlinks into
and out of the repository. Regular-file read descriptors are refused; `fstat`
identifies pipes/sockets as non-file I/O (including Cast stdout/stderr). Git has
no exception, including absolute executable paths, `-C`, keyword arguments and
shell command strings. Write/append-only output is permitted. The single STOP
site is `execution_repo_read`; there is no exception-to-acceptance fallback.

#### Closed execution-read table

Repository functions only. Roots: `pre_send`, `u.measure_step`, `u.fresh_gas`,
`u.receipt`, `check_predicate`, `batch_readback`, `dvt_closing`. The existing
`swallow_audit.call_closure` scanner was run with precisely these seven roots
(via a synthetic root), traversing aliases and nested callbacks in its six
repository modules. It reaches **110 functions**. Every reached `open`,
`read_text`, `read_bytes`, subprocess and JSON/YAML loading site is listed below;
the removed transitive source reads are retained for comparison with the
preliminary inventory. There are no reachable YAML file loaders or git
`show`/`rev-parse` calls in this seven-root closure after the change.

| Root / reachable operation | File or data read | Disposition |
|---|---|---|
| `pre_send`, `dvt_closing` → `registry_callsite_targets` | Former `git show HEAD:deployments/config.sepolia.json` | Already moved by A/A-fix to `plan.pin.oldOwnerIsolation.callsiteTargetSource.expected`; no execution read. |
| `pre_send` → `u.governance` | Former `u.runtime → u.build` candidate artifacts | Moved to `plan.timelockRuntimeIdentity`; explicit required argument, verified with the same `a.verify_runtime` gates. |
| Former `u.build → a.compile_commit → a.archive_commit` | `git archive`, `ls-tree`, submodule `rev-parse`, `cat-file` | No longer reachable from these roots. Build-time only; no allowlist exception. |
| Former `a.compile_commit` | Archived `foundry.toml` via `Path.read_text` / TOML parse; Forge offline build | Build-time only, removed from execution closure. |
| Former `a.raw_artifact` / `a.immutable_identity` | Artifact JSON and build-info JSON via `Path.read_text` / `json.loads` | Build-time only; runtime verification consumes the supplied identity directly. |
| Former `a.committed_bytes` / artifact source validation | `git show`, `ls-tree`; source `Path.read_bytes` | Build-time only, removed from execution closure. |
| Former `u.build` / `a.validate_artifact` | `json.loads` of artifact metadata | In-memory parsing of pre-execution build data; no runtime artifact reread. |
| RPC-using roots → `a.RPC._post_with_deadline.work` | `urlopen`, response `r.read()`, `json.loads` | Response bytes, not a repo-file read. Nested worker counted once. Tests use offline fakes. |
| ABI/hash-using roots → `a.cast` | `subprocess.run([ENGINE/'cast', ...])` stdout | Offline ABI/hash arguments, no repo source paths. No git invocation or file-read exception. |
| Conservative scanner match `u.log` (local `log` variable shares its name; actual calls are in the runner) | `(out/'simulate.log').open('a')` | Append-only output; no read. No allowlist exception. |
| `u.fresh_gas`, `u.receipt`, `check_predicate`, `batch_readback`, `dvt_closing` | No additional file/subprocess/JSON/YAML reads beyond the shared helpers above | All inputs come from the plan, arguments, or RPC responses. |

Additional whole-run paths (outside the seven-root table) are covered by the
same barrier:

| Operation | Disposition |
|---|---|
| Initial `validate_plan → build_plan`, release evidence, schemas, source and artifact verification | Completes before the barrier. Existing gates retained. |
| `reviewed_allowlist` → `Path.read_text` / `json.loads` of `script/upgrade/execution_read_allowlist.json` | Loaded before the barrier; fixed code-owned path, never plan-supplied. Empty allowlist with reasons. |
| Final `validate_plan` in full and staged execution | Uses detached pre-execution `expected`; no source/evidence/schema rebuild. |
| `controls_at → unbacked_swap_control` | Uses the same expected plan for the omitted-mint candidate and its rejection. No runtime rebuild. |
| `a.write_json`, `u.log` | Output-only writes/appends; no read exemption. |

Tests exercise all guarded APIs, JSON-through-open, update mode, symlink aliases,
explicit allowed paths, outside-repo reads, output writes, cleanup on exception,
installation after validation, the real runner closing path, subprocess pipes,
regular read descriptors, and detached late validation. The governance test
runs the real runtime comparator with `u.build` prohibited and verifies changed
runtime bytes still STOP.

The focused deletion probe compiles the whole guard module with exactly one
`raise` statement removed. The file targets contain valid data; the git fake
returns a successful `CompletedProcess`, matching the real target's success
shape. Deletion therefore reaches acceptance instead of an unprogrammed fake.
`assert_stop` is unchanged and catches only `a.Gate`.

Verification notes: the first manifest run was interrupted after the new
plan-time build reached a real offline compile; the fixture now scopes a stub
for that build. A second diagnostic run was interrupted during ordinary test
work. Neither supplies acceptance evidence. The initial symlink test/probe
failed its green-baseline criterion, identified an alias escape, and was fixed.
An integration run was stopped after the changed `controls_at` signature exposed
an outdated fixture callback; that callback now accepts the expected plan. A
focused runner rerun then exposed the pipe-descriptor issue described above; it
was fixed and all ten runner cases passed. No ERROR result is accepted. Only the
final green-baseline probe and completed green suites below supply acceptance
evidence. One completed manifest attempt ran 532 tests and reported one
`KeyError` in the hand-built old-exit test plan, which lacked the new required
identity field (`FAILED (errors=1, skipped=2)`, exit 1). That fixture now carries
the valid timelock identity; its focused test passed. The failed run is rejected
as acceptance evidence and the entire suite is rerun below.

Final accepted checks (each exit 0; sequential foreground execution):

| Command | Unittest summary | Verbatim final line |
|---|---|---|
| `python3 script/upgrade/test_sp_upgrade_exec.py` | `Ran 141 tests in 1.387s`; `OK` | `OK` |
| `python3 script/upgrade/test_execution_reads.py` | `Ran 10 tests in 0.083s`; `OK` | `OK` |
| `python3 script/upgrade/test_manifest_exec.py F05RunManifestGates -v` | `Ran 10 tests in 13.940s`; `OK` | `OK` |
| `python3 script/upgrade/test_manifest_exec.py OldExitExemptionTests.test_pre_send_enforces_exit_gate -v` | `Ran 1 test in 4.762s`; `OK` | `OK` |
| `python3 script/upgrade/test_manifest_exec.py -v` | `Ran 532 tests in 407.345s`; `OK (skipped=2)` | `L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0` |
| `python3 script/upgrade/test_manifest_phase_c.py -v` | `Ran 141 tests in 190.852s`; `OK` | `OK` |
| `python3 script/upgrade/test_authority_checkpoints.py` | `Ran 6 tests in 12.896s`; `OK` | `OK` |
| `python3 script/upgrade/test_swallow_exceptions.py` | `Ran 9 tests in 2.592s`; `OK` | `OK` |
| `python3 script/upgrade/probe_execution_reads.py` | One-site deletion; baseline green; 13 failures, zero errors; named assertion | `COMMIT6D_B_PROBE PASS 1/1 strict red` |

Verbatim focused probe output:

```text
execution_repo_read: sites=1 baseline=green failures=13 errors=0 ASSERT named
AssertionError: execution_repo_read: Gate not raised
COMMIT6D_B_PROBE PASS 1/1 strict red
```

The manifest suite's buffered `L1_CONTROL` final line is reproduced literally;
it is not claimed as new strict deletion evidence for F/G. Logs are in
`/tmp/6d-b-*.log`; final summaries and lines above are retained here independently
of those temporary files. The full probe-driver batch was not run.

**Done this continuation: B only. Undone: C, D, E, F, G.** Incoming 0, A, A-fix
and H are preserved. The existing source-spelling test was only pointed at the
extracted `_run_manifest` body; D's behavioural replacement remains undone.
All foreground command sessions have exited. No worker/background process was
launched or retained. `git diff --check` passes. HEAD remains
`171807d936ef1b9d4fcecf0ff63d09cd99193884`; no commit or staging.

### C-only continuation: execution HEAD and clean-tree gates (DSR)

`run_manifest` now reads `git rev-parse HEAD` and requires exact equality with
`plan['rebuild']['commit']` at `execution_head`. It then runs
`git status --porcelain --untracked-files=all` and requires empty stdout at
`execution_clean_tree`. Both commands use `cwd=u.ROOT` and `check=True`.
These checks run after plan validation and loading the reviewed allowlist,
immediately before entering B's read barrier and `_run_manifest`; therefore
both precede the first `pre_send`, including B4's execution path. They apply
to calibration and frozen replay. No gate, allowlist, exception handling or
production fallback was weakened. `assert_stop` still accepts only `a.Gate`.

New tests use real temporary offline git repositories: matching clean HEAD,
wrong HEAD, changed tracked file, and an untracked file. The matching case
covers calibration and frozen replay. The downstream real staged runner has
valid closing/readback/budget fixtures and returns `status=PASS` when a gate
is deleted, rather than encountering an unprogrammed fake. Existing manifest
and execution-read fixtures now supply successful, clean-checkout git replies
for their synthetic rebuild commit; other subprocess targets remain unchanged.
This fixture behavior exists only in test code.

`probe_execution_head.py` recompiles the whole production module with exactly
one named `a.need` statement deleted per case, restores it afterward, and
requires a green baseline, failures >= 1, errors == 0, and an assertion message
naming that gate. Both deletions reach acceptance and fail at `assert_stop`.

Accepted checks (each exit 0, sequential foreground execution):

| Command | Unittest summary | Verbatim final line |
|---|---|---|
| `python3 script/upgrade/test_execution_head.py -v` | `Ran 4 tests in 0.575s`; `OK` | `OK` |
| `python3 script/upgrade/probe_execution_head.py` | Two single-site deletions; green baselines; one failure and zero errors each | `COMMIT6D_C_PROBES PASS 2/2 strict red` |
| `python3 script/upgrade/test_execution_reads.py` | `Ran 10 tests in 0.081s`; `OK` | `OK` |
| `python3 script/upgrade/test_manifest_exec.py F05RunManifestGates -v` | `Ran 10 tests in 15.442s`; `OK` | `OK` |
| `python3 script/upgrade/test_manifest_exec.py ManifestTests.test_staged_runner_guards ManifestTests.test_run_manifest_final_frozen_check_requires_timelock_owner ManifestTests.test_remote_execution_refused -v` | `Ran 3 tests in 14.597s`; `OK` | `OK` |
| `python3 script/upgrade/test_swallow_exceptions.py` | `Ran 9 tests in 2.574s`; `OK` | `OK` |
| `python3 script/upgrade/probe_execution_reads.py` | Existing B barrier: green baseline; 13 failures, zero errors | `COMMIT6D_B_PROBE PASS 1/1 strict red` |

Verbatim focused C probe output:

```text
execution_head: sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: execution_head: Gate not raised
execution_clean_tree: sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: execution_clean_tree: Gate not raised
COMMIT6D_C_PROBES PASS 2/2 strict red
```

Verbatim focused B regression probe output:

```text
execution_repo_read: sites=1 baseline=green failures=13 errors=0 ASSERT named
AssertionError: execution_repo_read: Gate not raised
COMMIT6D_B_PROBE PASS 1/1 strict red
```

**Done this continuation: C only. Undone: D, E, F, G.** Incoming 0, A, A-fix,
B and H are preserved. This status supersedes earlier outstanding lists in 6d.
No ERROR result was accepted. Only affected tests and focused probes were run;
the full probe-driver batch was not run. Logs: `/tmp/6d-c-*.log`.
All foreground command sessions exited; no background process was launched or
retained. No RPC, environment/keystore access or chain operation was performed.
`git diff --check` passes. HEAD remains
`171807d936ef1b9d4fcecf0ff63d09cd99193884`; no commit or staging.

### D-only continuation: partial M7 behavioural caller replacement

**D remains undone; overall 6d acceptance is withheld.** Only D was touched in
this continuation. Existing completed 0, A, A-fix, B, C and H work is preserved;
E, F and G remain undone. No production code, gate, exception policy or fallback
was changed. `assert_stop` still catches only `a.Gate`.

Replaced source-spelling controls 9, 12, 13, 14, 21 and 22 with adverse fake-RPC
caller tests: the released factory has OLD as owner, a newly discovered token
has OLD as community owner, or a retained token grants OLD_TIMELOCK a nonzero
allowance. Both pre-send and closing invoke the real discovery/authority checks.
A clean positive test exercises both callers. The pre-send fake now supplies
valid nonce, chain, Safe, binding and owner continuation data, so deleting its
old-authority or allowance call reaches normal return rather than an
unprogrammed fake. These are test fixtures only.

`probe_discovery_calls.py` selects exactly one AST call expression in its actual
caller and replaces it with `None` in memory (the normal return of a void check;
for closing's assigned never-granted result it leaves an unused `None` result).
It requires one source site, a green baseline, failures >= 1, errors == 0 and a
FAIL assertion message naming the expected gate. Four controls reach normal
return. The two community-owner controls instead reach a later authority STOP;
the resulting wrong-STOP assertions name the expected owner gate. These two
are strict-red evidence under the stated criterion, **not acceptance evidence**.

The other 20 source-spelling controls remain explicitly marked as pending, not
silently dropped or counted as behavioural coverage. The original table mixes
check calls with value-producing calls. For example, deleting
`pin_discovery(plan['pin'])` from `build_expected_discovery` does not remove
`discovery_step_table`, whose predicate depends only on step IDs; on an otherwise
valid plan the deleted state initializer instead causes an invalid value later.
Similar value-producing sites cannot be counted merely because deletion raises
a Python error. A clarification about explicitly documented cached-value bypass
mutations was requested; no such replacement was assumed or implemented.

Accepted foreground checks:

| Command | Summary | Verbatim final line |
|---|---|---|
| `python3 script/upgrade/test_manifest_exec.py DiscoveryCallTests DiscoveryTests -v` | `Ran 52 tests in 76.407s`; 20 retained source checks are included and are not M7 completion evidence | `OK` |
| `python3 script/upgrade/probe_discovery_calls.py` | Six focused single-site controls; green baselines, one failure and zero errors each | `COMMIT6D_D_PROBES PASS 6/6 strict red` |

Verbatim first focused probe output:

```text
9: gate=discovery_old_authority sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: discovery_old_authority: Gate not raised
12: gate=discovery_old_authority sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: discovery_old_authority: Gate not raised
13: gate=old_owner_xpnts_owner_recheck sites=1 baseline=green failures=1 errors=0 ASSERT named
 : old_owner_xpnts_owner_recheck
14: gate=old_owner_xpnts_owner_recheck sites=1 baseline=green failures=1 errors=0 ASSERT named
 : old_owner_xpnts_owner_recheck
21: gate=old_timelock_allowance sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: old_timelock_allowance: Gate not raised
22: gate=old_timelock_allowance sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: old_timelock_allowance: Gate not raised
COMMIT6D_D_PROBES PASS 6/6 strict red
```

The initial fixture-development runs were rejected, with final lines respectively
`FAILED (errors=4)`, `FAILED (failures=4, errors=1)` and `FAILED (failures=2)`.
No ERROR result was accepted. Probe assertion reporting was then expanded to
show the complete assertion message, including the later STOP for owner cases.

The focused owner-only diagnostic command was
`PYTHONPATH=script/upgrade python3 -u -c 'import probe_discovery_calls as p; p.CASES = (13, 14); raise SystemExit(p.main())'`
(exit 0). Its verbatim output and final line:

```text
13: gate=old_owner_xpnts_owner_recheck sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: 'discovery_old_authority' != 'old_owner_xpnts_owner_recheck'
- discovery_old_authority
+ old_owner_xpnts_owner_recheck
 : old_owner_xpnts_owner_recheck
14: gate=old_owner_xpnts_owner_recheck sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: 'discovery_old_authority' != 'old_owner_xpnts_owner_recheck'
- discovery_old_authority
+ old_owner_xpnts_owner_recheck
 : old_owner_xpnts_owner_recheck
COMMIT6D_D_PROBES PASS 2/2 strict red
```

**Done within D: six caller controls and their focused probes. Undone: the other
20 behavioural replacements; D as a whole, E, F and G.** No whole item is claimed
complete in this continuation. Logs: `/tmp/6d-d-tests-final.log`,
`/tmp/6d-d-probes.log`, `/tmp/6d-d-owner-probes.log`.
All foreground sessions have exited; no background process was launched or
retained. No live RPC, environment/keystore access or chain operation was
performed. The full probe-driver batch was not run. `git diff --check` passes.
HEAD remains `171807d936ef1b9d4fcecf0ff63d09cd99193884`; no commit or staging.

### E-only continuation: closing packet-role authority matrix and real Registry rows

**Done this continuation: E only (item 2 remainder). Undone: D's remaining
20 behavioural replacements, F and G.** Existing 0, A, A-fix, B, C and H work
is preserved. Overall 6d acceptance remains withheld.

Added closing matrix cells for OLD and OLD_TIMELOCK as config owner of a role
first configured by a synthetic packet step, plus a clean closing control. The
role is explicitly absent from the pin's standard roles, configured roles and
roleHistory, and appears only in the returned closing inventory. These are
consumer unit tests: `closing_timelock_inventory` is a fixture boundary; the
real `dvt_closing`, `authority_rows`, OLD audit and OLD_TIMELOCK audit execute.
They do not claim packet execution or inventory-producer acceptance of an
additional role. The synthetic configureRole calldata and expected discovery
state are supplied in the test packet. All authority reads use the closing
block. The new role's hasRole mapping answers false, as a config owner need
not have membership; deleting either authority gate therefore reaches normal
closing return rather than an unprogrammed fake or a later STOP.

A separate test calls `extract` on the REAL archived Registry build at
`/private/tmp/l1-builds/a839347e04b40da287522c3641e12121ef2e8e9e`, without
replacing extraction or using the synthetic Registry inventory. It asserts
`authority_rows` contains inherited `owner()` and exactly one config row for
each role in standard union RoleConfigured events union roleHistory. Distinct
event-only and history-only roles make omission of either source observable.

No production code, gate or fallback changed. `assert_stop` remains restricted
to `a.Gate`. The focused probe recompiles the whole production module with
exactly one named gate statement deleted per case and restores it afterward.

Accepted checks (sequential foreground execution, exit 0):

| Command | Summary | Verbatim final line |
|---|---|---|
| `python3 script/upgrade/test_authority_checkpoints.py -v` | `Ran 10 tests in 15.988s` | `OK` |
| `python3 -u script/upgrade/probe_authority_checkpoints.py` | Two single-site deletions; green baselines; one named failure and zero errors each | `COMMIT6D_E_PROBES PASS 2/2 strict red` |
| `git diff --check` | Pass | No output |

Verbatim focused probe output:

```text
discovery_old_authority: sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: discovery_old_authority: Gate not raised
old_timelock_authority: sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: old_timelock_authority: Gate not raised
COMMIT6D_E_PROBES PASS 2/2 strict red
```

The initial fixture-development run ended `FAILED (errors=3)` because the
synthetic step lacked an expected-discovery entry. That run was rejected; the
fixture now supplies the unchanged discovery state after configureRole. No
ERROR result was accepted. Logs: `/tmp/6d-e-tests.log` (rejected),
`/tmp/6d-e-tests-final.log`, `/tmp/6d-e-probes.log`.

Only the affected suite and focused probes ran; no full probe-driver batch.
All foreground sessions exited; no background process was launched or retained.
No live RPC, environment-file/keystore access or chain operation was performed.
HEAD remains `171807d936ef1b9d4fcecf0ff63d09cd99193884`; no commit or staging.

### F-only continuation: complete COMMIT 5 A/B row re-audit

**Done this continuation: F only.** Re-audited all 160 rows of COMMIT 5's
Assertion classifications table against the current test bodies, their shared
helpers and the corrected `assert_stop`. The table below preserves original
row order and names, including retired names. **CHANGED** marks all 151 Class A
rows whose historical crash-as-red evidence policy is withdrawn; it does not
mean 151 test bodies were edited. The nine Class B rows are **UNCHANGED**.
Class A describes the control's purpose, **not certification of its deletion**.
A green unit test, a helper call or a binding is not strict deletion evidence.
The full probe-driver batch was deliberately not run.

Each named STOP now accepts only the expected `a.Gate`; wrong gates and normal
return fail by assertion, and arbitrary exceptions must propagate. The re-audit
found an exception-conversion wrapper outside `assert_stop`:
`ManifestTests.assert_timelock_build_gate` still caught KeyError, TypeError and
IndexError and converted them to a named FAIL. That wrapper has been removed.
A regression verifies exception identity for all three types. No production
code, gate, fallback or `assert_stop` behavior was changed.

Other row-specific findings: `removed_probe` still suppresses a label globally,
so its zero-error L1_CONTROL diagnostics cannot certify one source site. The
former approval-history test is replaced by separate range and log tests. The
former two-gate proxy diagnostic now runs individual length and parity probes.
The ENDUSER caller test's getter annotation names the getter but its expected
STOP is the caller control-path gate; only the direct getter binding addresses
the getter itself. Positive observation/restoration rows and typed-rejection
subcases are identified separately below. Generic helper names are checked at
all definitions: `check` includes DeltaTests and the five F05 caller classes;
`stop` includes SafeGovernanceTests, GasGateControls and F05Fixture (manifest)
and PhaseCTests (Phase C). `gate (DiscoveryTests)` is the current named wrapper.

In the table, “non-Gate exceptions propagate” describes the STOP assertion
boundary; internal diagnostics explicitly reject captured runner errors. It
does not assert that every production deletion has been rerun or reaches
acceptance. Any previous strict result depending on arbitrary-exception
conversion is invalid, regardless of its historical green suite.

| # | COMMIT 5 row | File | Re-audit | Current classification / evidence |
|---:|---|---|---|---|
| 1 | `GasProbeReportingTests + suppressed_outcome (replaced)` | `probe_gas_gates.py` | **CHANGED** | A (probe reporter): Current `GasProbeReportingTests` in test_manifest_exec.py delegates to strict_outcome/run; exact-site counts, green baseline, zero errors and named failure required. Retired suppressed_outcome is absent. Reporter is not a production gate. |
| 2 | `assert_enduser_controls` | `test_old_owner_isolation.py` | **CHANGED** | A (observation): Named assertions check required positive/negative reads; no exception-to-success conversion. |
| 3 | `test_mapping_enduser_faults_stop_audit` | `test_old_owner_isolation.py` | **CHANGED** | A (caller control): Catches AssertionError only to add getter name; expected STOP for getter fault is role_control_path. Not standalone getter-site evidence; direct getter test is the binding. |
| 4 | `mapping_control / old_owner_mapping_getter` binding | `audit605_probes.py` | **CHANGED** | A (binding): audit605_probes.py binds mapping_control/getter to test_mapping_function_getter_rejected_per_role; binding alone is not deletion evidence. |
| 5 | `assert_gate` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 6 | `assert_timelock_build_gate` | `test_manifest_exec.py` | **CHANGED** | A (corrected wrapper): Removed KeyError/TypeError/IndexError-to-FAIL conversion in this continuation. All non-Gate exceptions now propagate. Missing oldTimelock deletion is not certified. |
| 7 | `check` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 8 | `check_closing_inventory` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 9 | `check_old_timelock` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 10 | `control` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 11 | `gate (DiscoveryTests)` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): DiscoveryTests.gate delegates to strict assert_stop. |
| 12 | `never_recheck_change` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 13 | `registry_layout_fixture` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 14 | `rehearse_fake` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 15 | `removed_probe` | `test_old_owner_isolation.py` | **CHANGED** | A (diagnostic only): Suppresses every a.need with the label, not one source site. Rejects captured errors, but L1_CONTROL is not strict deletion evidence. |
| 16 | `stop` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 17 | `stop` | `test_manifest_phase_c.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 18 | `test_aggregator_transfer_requires_completed_admin` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 19 | `test_all_manifest_stages_require_remote_gas_evidence` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 20 | `test_ast_extra_getter_revert_stops` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 21 | `test_b2_implementation_identity_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 22 | `test_b2_single_upgrade_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 23 | `test_budget_includes_stake_and_deposit` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 24 | `test_builder_runs_release_validation` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 25 | `test_built_aggregator_version_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 26 | `test_cached_build_current_head_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 27 | `test_calldata_payload_removal_hits_named_gate` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 28 | `test_clone_collection_and_post_upgrade_gate_removals` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 29 | `test_clone_identity_and_factory_origin_controls` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 30 | `test_closure_finding_cannot_be_outside` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 31 | `test_collect_direct_fake_chain` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 32 | `test_collect_registry_version_negative` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 33 | `test_collection_rejects_endpoint_count_before_delegating` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 34 | `test_committee_handover_requires_completed_binding` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 35 | `test_committee_rejects_two_step_runtime` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 36 | `test_config_history_drop_truncation_both_endpoints` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 37 | `test_control_must_fire_named_gate` | `test_manifest_phase_c.py` | **CHANGED** | A (mixed control): Negative STOP uses PhaseCTests.stop; positive restoration catches only a.Gate and names X_restore. Other exceptions propagate. |
| 38 | `test_decoded_arguments_both_cast_formats` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 39 | `test_deployed_source_collection_replay_and_missing_source` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. |
| 40 | `test_deployment_record_binding_and_gate_removals` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. Current deletion fixtures retain valid duplicate receipts and a populated UserDict record; missing-record input remains a separate rejection. |
| 41 | `test_dvt_closing_binds_pointer_and_stale_proposals` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 42 | `test_dvt_mock_rebuilt_runtime_gate` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 43 | `test_dvt_rebuilt_creation_gate` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 44 | `test_dvt_repo_must_be_configured` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 45 | `test_early_swap_detects_missing_eta_guard` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 46 | `test_early_swap_refuses_old_implementation` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 47 | `test_early_swap_requires_eta_revert_reason` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 48 | `test_early_swap_requires_valid_accounting` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 49 | `test_embedded_a3a_contract_call_gap_refused` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 50 | `test_empty_extraction_categories_stop` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 51 | `test_empty_range_discovery` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 52 | `test_endpoint_replay_reruns_predicates` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 53 | `test_endpoint_without_hostname` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 54 | `test_evidence_controls` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 55 | `test_evidence_full_creation_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 56 | `test_extra_token_closing` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Uses DiscoveryTests.gate; closing_timelock_inventory, then isolated old_timelock_inventory checks. No arbitrary-exception acceptance. |
| 57 | `test_fabricated_scope_hides_high_finding` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 58 | `test_factory_enumeration_must_stand_alone` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 59 | `test_factory_only_token_and_operator_union` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 60 | `test_finding_path_canonical_gate` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 61 | `test_finding_symlink_canonical_gate` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 62 | `test_fork_pin_positive_and_restore_gates` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 63 | `test_governance_evidence_revalidated_by_builder` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 64 | `test_grants_cancellation_union_and_truncation` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 65 | `test_guardian_inventory_and_anni_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. |
| 66 | `test_history_identity_gate_removals` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 67 | `test_history_standard_revoke_only` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 68 | `test_immutable_address_negative_controls_and_removals` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. Current immutable prerequisite controls use validate_immutable_inputs before decoding; no default declaration is injected. |
| 69 | `test_immutable_ast_and_malformed_reference_controls` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. Current value prerequisite controls use validate_immutable_inputs; empty-value dereference is not credited. |
| 70 | `test_immutable_repeated_values_must_agree` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 71 | `test_internal_nonce_hole_refused` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 72 | `test_layout_pair_identity_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 73 | `test_layout_pair_parity_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 74 | `test_legacy_timelock_source_targets` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 75 | `test_list_and_endpoint_controls` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 76 | `test_live_owner_code_on_one_endpoint` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 77 | `test_manifest_calldata_invalid_cast_output` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 78 | `test_mapping_enduser_without_control_holder` | `test_old_owner_isolation.py` | **CHANGED** | A (positive control): Expected successful ENDUSER observation; unexpected a.Gate becomes failure. Arbitrary exceptions propagate. Not a negative STOP test. |
| 79 | `test_metadata_bytes_cannot_be_masked_as_immutables` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 80 | `test_metadata_masked_requires_rule4` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 81 | `test_missing_transaction` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 82 | `test_named_clones_storage_authority_controls` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 83 | `test_negative_controls_and_gate_removal_probes` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 84 | `test_old_filtered_history_cannot_hide_grant` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 85 | `test_old_pointers_require_old_aggregator` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 86 | `test_old_timelock_approval_history` | `test_manifest_exec.py` | **CHANGED** | A (replaced): Old method absent; test_old_timelock_approval_history_range and test_old_timelock_approval_history_log now isolate the two failing sites. |
| 87 | `test_old_timelock_approval_incomplete` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 88 | `test_old_timelock_external_approval` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 89 | `test_old_timelock_external_approval_closing` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 90 | `test_old_timelock_external_approval_pre_send` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 91 | `test_old_timelock_inventory_new_token` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 92 | `test_old_timelock_log_replay` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 93 | `test_owner_swap_block_bound_to_chain` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 94 | `test_packet_semantic_controls` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 95 | `test_pair_and_independent_endpoint_failure` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 96 | `test_pin_pending_token_eta` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 97 | `test_pin_replay_both_endpoints_and_tampering` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. |
| 98 | `test_pin_time_immutable_gates` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 99 | `test_positive_controls_fail_closed` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 100 | `test_pre_send_bound_runtime_is_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 101 | `test_pre_send_delta_call` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 102 | `test_pre_send_enforces_exit_gate` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 103 | `test_pre_send_real_b2_is_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 104 | `test_pre_send_registry_owner_follows_completed_accept` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 105 | `test_pre_send_rereads_slots_and_time` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 106 | `test_proxy_runtime_extra_selector_stops` | `test_old_owner_isolation.py` | **CHANGED** | A (strict reporter): Former two-gate legacy diagnostic replaced by separate length/parity single-site probes, each with its own green baseline. |
| 107 | `test_proxy_slot_binds_parity_to_pinned_implementation` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 108 | `test_raw_absolute_mapping_rejected` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 109 | `test_raw_report_symlink_escape_rejected` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 110 | `test_real_chain_and_offline_replay` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 111 | `test_reconcile_direct_and_canonical_receipt` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 112 | `test_recursive_manifest_abi_controls` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. |
| 113 | `test_registered_wrong_data_length` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 114 | `test_registry_adopted_behavioral_claim` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 115 | `test_replay_duplicate_unused_and_endpoint_copy` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 116 | `test_replay_evidence_required_and_counts_checked` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 117 | `test_reproducible_reference_bytes_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 118 | `test_review_low_calldata_gates` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 119 | `test_review_low_endpoint_identity` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 120 | `test_review_low_registry_registered_exited` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 121 | `test_role_config_control` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 122 | `test_role_configure_emit` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 123 | `test_role_configured_coverage_per_emitter` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 124 | `test_role_control_case_without_path_gate` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 125 | `test_role_event_abi_and_inventory_source_seam` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. |
| 126 | `test_role_history_authentication_and_empty_probes` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 127 | `test_role_init_ids` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 128 | `test_role_init_standard` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 129 | `test_role_initializer_only` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 130 | `test_role_write_extraction_call` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 131 | `test_role_write_sites` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 132 | `test_run_manifest_final_frozen_check_requires_timelock_owner` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. |
| 133 | `test_runtime_mask_ranges_and_nonimmutable_mismatch` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Additional typed rejection subcases remain B semantics; they do not prove a named deletion. |
| 134 | `test_safe_mint_exit_and_regrant` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 135 | `test_safe_noncanonical_fallback_and_non_old_module` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 136 | `test_sampled_deployer_only` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 137 | `test_scope_empty_and_dependency_disjointness` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 138 | `test_slither_raw_rederived_gate` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 139 | `test_source_implementation_and_boundary_gate_removals` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 140 | `test_staged_source_rebuild` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 141 | `test_staged_timing_prefix` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 142 | `test_stale_dvt_proposals_accepted_only_exactly` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 143 | `test_stale_tree_evidence_refused` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 144 | `test_trace_rpc_failure_is_recorded_and_fails_closed` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 145 | `test_unchanged_old_activity_detects_new_activity_after_pin` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 146 | `test_unexpected_indirection_and_gate_removals` | `test_old_owner_isolation.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. Internal removed_probe is name-wide diagnostic only; separate single-site evidence required. |
| 147 | `test_unpause_outside_6d_refused` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 148 | `test_unsigned_dvt_proposal_stops` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 149 | `test_verifier_metadata_solc_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 150 | `test_verifier_segment_length_required` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 151 | `xpnts_owner_change` | `test_manifest_exec.py` | **CHANGED** | A (named STOP): Strict assert_stop, directly or through the named helper; non-Gate exceptions propagate. Historical crash-as-red claim withdrawn. |
| 152 | `test_extra_acceptance_schema_stop` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 153 | `test_duplicate_acceptance_schema_stop` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 154 | `test_wrong_acceptance_schema_stop` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 155 | `test_ci_schema_fields_stop` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 156 | `test_reference_single_line_stop` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 157 | `test_pop_selector_and_duplicates_refused` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 158 | `test_fraud_sample_format_only` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 159 | `test_fraud_sample_412_schema_and_bindings` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |
| 160 | `test_fraud_fixture_schema_and_binding` | `test_manifest_exec.py` | **UNCHANGED** | B (typed rejection): Explicit assertRaises(a.Gate); parser/schema or binding rejection only, no named-site deletion claim. |

#### F verification and explicit rejected evidence

The selected baseline loads only the three table-bearing test modules. It runs
existing `test_*` names from the table, the two approval-history replacements,
the five timelock-wrapper callers, NamedStopAssertionTests, and the gas reporter's
baseline-rejection regression. It does not run the gas reporter's all-probes
method or any driver's main batch. Helpers/bindings are source-audited above,
not miscounted as separately runnable tests. The existing proxy reporter runs
its two focused length/parity probes within the selected baseline.

Accepted foreground checks (exit 0):

| Command | Summary | Verbatim final line |
|---|---|---|
| `python3 -u /tmp/6d-f-baseline.py` | Before wrapper correction: 154 selected tests, 123.858s; zero failures/errors/skips. Ordinary baseline evidence only. | `COMMIT6D_F_BASELINE PASS tests=154 failures=0 errors=0 skipped=0` |
| `python3 -u script/upgrade/test_manifest_exec.py NamedStopAssertionTests ManifestTests.test_old_timelock_required ManifestTests.test_old_timelock_schema ManifestTests.test_old_timelock_block ManifestTests.test_old_timelock_replay_reads ManifestTests.test_old_timelock_replay_owners -v` | After correction: 10 affected tests, 17.844s; zero failures/errors. Includes exact exception-identity regression for all three former caught types. | `OK` |
| `python3 script/upgrade/test_swallow_exceptions.py` | Nine tests; zero failures/errors. | `OK` |

The focused runner imports `probe_phase_c_gates.run`, calls a green baseline
then one deletion for each of the following seven methods on ManifestTests,
and never calls the driver's main function. Source sites are identified from
the baseline STOP and deleted in memory. Its aggregate result is **rejected**
(exit 1); the six independently valid rows are retained as focused evidence.
All six fail specifically because execution reaches acceptance, not a later
STOP or an unprogrammed fake.

| Method | Deleted gate | Sites | Baseline | Failures | Errors | Disposition / verbatim exception message |
|---|---|---:|---|---:|---:|---|
| `test_old_timelock_required` | `old_timelock_required` | 1 | green | 0 | 1 | **REJECTED** — `KeyError: 'oldTimelock'` |
| `test_old_timelock_schema` | `old_timelock_schema` | 1 | green | 1 | 0 | Strict red — `AssertionError: old_timelock_schema: Gate not raised` |
| `test_old_timelock_block` | `old_timelock_block` | 1 | green | 1 | 0 | Strict red — `AssertionError: old_timelock_block: Gate not raised` |
| `test_old_timelock_replay_reads` | `old_timelock_replay` | 1 | green | 1 | 0 | Strict red — `AssertionError: old_timelock_replay: Gate not raised` |
| `test_old_timelock_replay_owners` | `old_timelock_replay` | 1 | green | 1 | 0 | Strict red — `AssertionError: old_timelock_replay: Gate not raised` |
| `test_old_timelock_approval_history_range` | `old_timelock_approval_history` | 1 | green | 1 | 0 | Strict red — `AssertionError: old_timelock_approval_history: Gate not raised` |
| `test_old_timelock_approval_history_log` | `old_timelock_approval_history` | 1 | green | 1 | 0 | Strict red — `AssertionError: old_timelock_approval_history: Gate not raised` |

`python3 -u /tmp/6d-f-probes.py`, verbatim final line:

```text
COMMIT6D_F_FOCUSED NOT_CERTIFIED strict=6/7 rejected=1
```

The rejected required-field mutation's verbatim unittest final line is
`FAILED (errors=1)`. Its green baseline remains a valid missing-input rejection
test; its deletion is **not** strict evidence. The deleted prerequisite leaves
an actual missing dictionary key at `validate_old_timelock`'s next statement.
This is not a missing fake response. The former wrapper disguised that crash;
this continuation exposes and records it without adding a production fallback.
Repair/certification of that deletion remains outstanding alongside G's probe
provenance work. No ERROR result is accepted. No other row gains strict
certification merely from this classification re-audit.

**Done: F (all 160 rows audited and explicitly marked; exception-conversion
wrapper removed). Undone: D's remaining 20 behavioural replacements, G's full
provenance/inventory work, and certification of old_timelock_required deletion.**
Incoming completed 0, A, A-fix, B, C, E and H are preserved. This supersedes the
earlier 6d outstanding list for F only. Overall 6d acceptance remains withheld.
Logs: `/tmp/6d-f-baseline.log`, `/tmp/6d-f-wrapper.log`,
`/tmp/6d-f-probes.log`, `/tmp/6d-f-swallow.log`. The table records durable findings
and the exact final lines independently of the temporary logs.

Only affected tests and focused probes ran sequentially in the foreground.
All command sessions exited; no background process was launched or retained.
No live RPC, environment-file/keystore access or chain operation was performed.
No production files were edited in this continuation. HEAD remains
`171807d936ef1b9d4fcecf0ff63d09cd99193884`; no commit or staging.

Final table reconciliation checks every original `(name, file)` pair in order,
requires exactly 151 CHANGED and nine UNCHANGED rows, and verifies the timelock
wrapper has no exception handlers. Verbatim final line:

```text
COMMIT6D_F_REAUDIT PASS rows=160 changed=151 unchanged=9 wrapper_catches=0
```

`git diff --check` passes (exit 0, no output).

### G: complete HEAD probe provenance (this continuation)

**Done this continuation: G only.** Audited the Python source at
`171807d936ef1b9d4fcecf0ff63d09cd99193884`, independently of the reviewed
uncommitted 6d implementation. The exact HEAD Python bytes are loaded through a
read-only import loader; source-inspecting tests receive those same bytes.
Non-Python tracked fixture inputs are unchanged. Socket connections are forbidden
in the audit process. No RPC, environment files, keystore or chain was used.

The audit runs selected test families directly, never a probe driver's `main()`
or its downstream batches. Each mutant replaces exactly one observed production
AST statement with `pass` in memory; only its containing function is recompiled.
The HEAD adverse fixtures and strict Gate-only `assert_stop` are unchanged.
One historical test-only exception-conversion wrapper is normalized below; this
is explicitly distinguished from literal HEAD results.
#601 rows are individual `removed_probe` invocations, including loop variants in
execution order (`[n]`), not the helper's name-wide suppression output. Each
outer test also completed green. #604 rows are every registered HEAD `CASES`
entry, including its later additions; no origin is inferred from a filename alone.

`ASSERT named` requires a green baseline, one observed/matched source statement,
mutant failures >= 1, errors == 0, and a FAIL assertion message naming the deleted
gate. `HAS-ERROR` is rejected. `ASSERT-UNNAMED` means the strict named-FAIL criterion
was not met; it includes a still-green test with zero failures. A wrong-Gate
assertion may qualify under the requested criterion; this is not a claim that
all deletion paths reached acceptance. #604 F/E counts are for a single wrapper
control preserving the nested unittest FAIL/ERROR distinction; the complete
nested diagnostics are retained in the evidence JSON.

An initial audit harness used `TestCase.run` directly, omitting `setUpClass` for
F05ExecuteB4Gates and DiscoveryTests. All 11 resulting baseline AttributeErrors
are rejected harness errors, not historical gate defects. The harness now uses
`TestSuite.run`; only those 11 controls were rerun with the real class fixtures.
The rejected diagnostics are retained separately, excluded from the final table.
Other audited classes have no class fixtures, so their completed results remain
valid. The final runner also seeds linecache with HEAD bytes; earlier traceback
source excerpts may reflect worktree text, so only actual FAIL messages and the
explicit HEAD statements/fixture source establish provenance.

HEAD's `assert_timelock_build_gate` catches KeyError/TypeError/IndexError and
converts them into named FAILs. The `old_timelock_required` row initially appeared
named (F=1/E=0), but its traceback exposed `KeyError: 'oldTimelock'`; that apparent
pass is rejected. A focused `--gate-only-wrapper` run removes only that helper's
catch in memory, preserving the HEAD adverse input and production gate. It gives
a green baseline, one source deletion, F=0/E=1: **HAS-ERROR**. The final table uses
this strict result; the literal HEAD result is retained separately. This confirms
the defect already recorded by F and does not re-certify it. It is an actual
missing dictionary key, not an unprogrammed fake response. No fallback was added.

The durable [COMMIT6G_PROVENANCE.json](COMMIT6G_PROVENANCE.json) stores every row,
HEAD source hashes, the exact deleted statement, the exact adverse fixture source
(method or generated-case expression), baseline diagnostics, mutant diagnostics,
and verbatim command final lines. Table line references below always refer to
**HEAD**, not current worktree line numbers. `M` = `manifest_exec.py`, `O` =
`old_owner_isolation.py`, `U` = `sp_upgrade_exec.py`, all under `script/upgrade`.
The fixture column names the exact HEAD input in that JSON; it is not a replacement
input invented for this audit.

Coverage: **27 #601 helper-user methods / 113 invocation variants; 205 / 205 #604 cases**. Combined: **315 ASSERT named, 1 HAS-ERROR, 2 ASSERT-UNNAMED**. All baselines green.

#### Per-probe table

| ID / origin | HEAD control / adverse fixture | Gate | HEAD deleted site | B / F / E | Classification |
|---|---|---|---|---|---|
| G001 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[1]`<br>fixture method L742 | `old_owner_role_TimelockController_PROPOSER_ROLE` | O:679 | green / 1 / 0 | ASSERT named |
| G002 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[2]`<br>fixture method L742 | `old_owner_authority_SuperPaymaster_pendingOwner` | O:694 | green / 1 / 0 | ASSERT named |
| G003 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[3]`<br>fixture method L742 | `old_owner_mapping_Registry_authorized` | O:699 | green / 1 / 0 | ASSERT named |
| G004 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[4]`<br>fixture method L742 | `old_owner_role_admin_ROLE_COMMUNITY` | O:647 | green / 1 / 0 | ASSERT named |
| G005 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[5]`<br>fixture method L742 | `old_owner_authority_GTokenStaking_owner` | O:694 | green / 1 / 0 | ASSERT named |
| G006 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[6]`<br>fixture method L742 | `old_owner_authority_GToken_owner` | O:694 | green / 1 / 0 | ASSERT named |
| G007 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[7]`<br>fixture method L742 | `old_owner_authority_xPNTsFactory_owner` | O:694 | green / 1 / 0 | ASSERT named |
| G008 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[8]`<br>fixture method L742 | `old_owner_xpnts_owner_pin` | O:806 | green / 1 / 0 | ASSERT named |
| G009 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[9]`<br>fixture method L742 | `old_owner_authority_MySBT_daoMultisig` | O:694 | green / 1 / 0 | ASSERT named |
| G010 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[10]`<br>fixture method L742 | `old_owner_authority_PaymasterFactory_owner` | O:694 | green / 1 / 0 | ASSERT named |
| G011 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[11]`<br>fixture method L742 | `old_owner_mapping_GTokenStaking_authorizedSlashers` | O:699 | green / 1 / 0 | ASSERT named |
| G012 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[12]`<br>fixture method L742 | `old_owner_mapping_xPNTsFactory_isXPNTs` | O:699 | green / 1 / 0 | ASSERT named |
| G013 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[13]`<br>fixture method L742 | `old_owner_mapping_xPNTsToken_autoApprovedSpenders` | O:699 | green / 1 / 0 | ASSERT named |
| G014 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[14]`<br>fixture method L742 | `old_owner_role_Registry_0x7777777777777777777777777777777777777777777777777777777777777777` | O:767 | green / 1 / 0 | ASSERT named |
| G015 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[15]`<br>fixture method L742 | `old_owner_role_admin_0x7777777777777777777777777777777777777777777777777777777777777777` | O:647 | green / 1 / 0 | ASSERT named |
| G016 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[16]`<br>fixture method L742 | `old_owner_allowance_0x2222222222222222222222222222222222222222_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` | O:827 | green / 1 / 0 | ASSERT named |
| G017 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[17]`<br>fixture method L742 | `old_owner_operator_treasury_0xb5600060e6de5e11d3636731964218e53caadf0e` | O:798 | green / 1 / 0 | ASSERT named |
| G018 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[18]`<br>fixture method L742 | `old_owner_operator` | O:784 | green / 1 / 0 | ASSERT named |
| G019 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[19]`<br>fixture method L742 | `old_owner_registry_user_roles` | O:777 | green / 1 / 0 | ASSERT named |
| G020 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[20]`<br>fixture method L742 | `old_owner_allowance_0x696a73701b104c6ccbbaaddd2216788ea08eab89_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` | O:827 | green / 1 / 0 | ASSERT named |
| G021 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[21]`<br>fixture method L742 | `old_owner_safe_owners` | O:840 | green / 1 / 0 | ASSERT named |
| G022 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[22]`<br>fixture method L742 | `old_owner_safe_modules` | O:845 | green / 1 / 0 | ASSERT named |
| G023 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[23]`<br>fixture method L742 | `old_owner_safe_guard` | O:850 | green / 1 / 0 | ASSERT named |
| G024 / #601 | `OldOwnerIsolationTests.test_negative_controls_and_gate_removal_probes[24]`<br>fixture method L742 | `old_owner_safe_fallback` | O:850 | green / 1 / 0 | ASSERT named |
| G025 / #601 | `OldOwnerIsolationTests.test_safe_noncanonical_fallback_and_non_old_module[1]`<br>fixture method L784 | `old_owner_fallback_canonical` | O:852 | green / 1 / 0 | ASSERT named |
| G026 / #601 | `OldOwnerIsolationTests.test_safe_noncanonical_fallback_and_non_old_module[2]`<br>fixture method L784 | `old_owner_module_page` | O:858 | green / 1 / 0 | ASSERT named |
| G027 / #601 | `OldOwnerIsolationTests.test_old_filtered_history_cannot_hide_grant[1]`<br>fixture method L801 | `old_owner_history_old_filter` | O:1365 | green / 1 / 0 | ASSERT named |
| G028 / #601 | `OldOwnerIsolationTests.test_role_history_authentication_and_empty_probes[1]`<br>fixture method L856 | `old_owner_role_log_address` | O:740 | green / 1 / 0 | ASSERT named |
| G029 / #601 | `OldOwnerIsolationTests.test_role_history_authentication_and_empty_probes[2]`<br>fixture method L856 | `old_owner_role_log_removed` | O:741 | green / 1 / 0 | ASSERT named |
| G030 / #601 | `OldOwnerIsolationTests.test_role_history_authentication_and_empty_probes[3]`<br>fixture method L856 | `old_owner_role_log_topic` | O:744 | green / 1 / 0 | ASSERT named |
| G031 / #601 | `OldOwnerIsolationTests.test_role_history_authentication_and_empty_probes[4]`<br>fixture method L856 | `old_owner_role_log_canonical` | O:751 | green / 1 / 0 | ASSERT named |
| G032 / #601 | `OldOwnerIsolationTests.test_role_history_authentication_and_empty_probes[5]`<br>fixture method L856 | `old_owner_role_log_range` | O:747 | green / 1 / 0 | ASSERT named |
| G033 / #601 | `OldOwnerIsolationTests.test_config_history_drop_truncation_both_endpoints[1]`<br>fixture method L903 | `old_owner_log_partition` | O:1324 | green / 1 / 0 | ASSERT named |
| G034 / #601 | `OldOwnerIsolationTests.test_config_history_drop_truncation_both_endpoints[2]`<br>fixture method L903 | `old_owner_log_partition` | O:1324 | green / 1 / 0 | ASSERT named |
| G035 / #601 | `OldOwnerIsolationTests.test_config_history_drop_truncation_both_endpoints[3]`<br>fixture method L903 | `old_owner_log_limit` | O:1314 | green / 1 / 0 | ASSERT named |
| G036 / #601 | `OldOwnerIsolationTests.test_unexpected_indirection_and_gate_removals[1]`<br>fixture method L957 | `unexpected_proxy` | O:1152 | green / 1 / 0 | ASSERT named |
| G037 / #601 | `OldOwnerIsolationTests.test_unexpected_indirection_and_gate_removals[2]`<br>fixture method L957 | `unexpected_proxy` | O:1152 | green / 0 / 0 | ASSERT-UNNAMED |
| G038 / #601 | `OldOwnerIsolationTests.test_unexpected_indirection_and_gate_removals[3]`<br>fixture method L957 | `old_owner_undeclared_clone` | O:1156 | green / 1 / 0 | ASSERT named |
| G039 / #601 | `OldOwnerIsolationTests.test_role_configured_coverage_per_emitter[1]`<br>fixture method L1190 | `old_owner_role_extraction_empty` | O:762 | green / 1 / 0 | ASSERT named |
| G040 / #601 | `OldOwnerIsolationTests.test_deployment_record_binding_and_gate_removals[1]`<br>fixture method L1243 | `old_owner_record_sha256` | O:979 | green / 1 / 0 | ASSERT named |
| G041 / #601 | `OldOwnerIsolationTests.test_deployment_record_binding_and_gate_removals[2]`<br>fixture method L1243 | `old_owner_record_commit` | O:987 | green / 1 / 0 | ASSERT named |
| G042 / #601 | `OldOwnerIsolationTests.test_deployment_record_binding_and_gate_removals[3]`<br>fixture method L1243 | `old_owner_record_address` | O:992 | green / 1 / 0 | ASSERT named |
| G043 / #601 | `OldOwnerIsolationTests.test_deployment_record_binding_and_gate_removals[4]`<br>fixture method L1243 | `old_owner_record_receipt` | O:1000 | green / 1 / 0 | ASSERT named |
| G044 / #601 | `OldOwnerIsolationTests.test_deployment_record_binding_and_gate_removals[5]`<br>fixture method L1243 | `old_owner_record_source_commit` | O:990 | green / 1 / 0 | ASSERT named |
| G045 / #601 | `OldOwnerIsolationTests.test_deployment_record_binding_and_gate_removals[6]`<br>fixture method L1243 | `old_owner_record_required` | O:985 | green / 1 / 0 | ASSERT named |
| G046 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[1]`<br>fixture method L1303 | `old_owner_control_GTokenStaking` | O:715 | green / 1 / 0 | ASSERT named |
| G047 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[2]`<br>fixture method L1303 | `old_owner_control_GToken` | O:715 | green / 1 / 0 | ASSERT named |
| G048 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[3]`<br>fixture method L1303 | `old_owner_control_xPNTsFactory` | O:715 | green / 1 / 0 | ASSERT named |
| G049 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[4]`<br>fixture method L1303 | `old_owner_control_PaymasterFactory` | O:715 | green / 1 / 0 | ASSERT named |
| G050 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[5]`<br>fixture method L1303 | `old_owner_control_MySBT` | O:715 | green / 1 / 0 | ASSERT named |
| G051 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[6]`<br>fixture method L1303 | `old_owner_control_xPNTsToken` | O:812 | green / 1 / 0 | ASSERT named |
| G052 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[7]`<br>fixture method L1303 | `old_owner_control_authority` | O:774 | green / 1 / 0 | ASSERT named |
| G053 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[8]`<br>fixture method L1303 | `old_owner_control_registration` | O:779 | green / 1 / 0 | ASSERT named |
| G054 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[9]`<br>fixture method L1303 | `old_owner_control_operator` | O:801 | green / 1 / 0 | ASSERT named |
| G055 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[10]`<br>fixture method L1303 | `old_owner_mapping_control_path` | O:703 | green / 1 / 0 | ASSERT named |
| G056 / #601 | `OldOwnerIsolationTests.test_positive_controls_fail_closed[11]`<br>fixture method L1303 | `old_owner_control_safe` | O:842 | green / 1 / 0 | ASSERT named |
| G057 / #601 | `OldOwnerIsolationTests.test_deployed_source_collection_replay_and_missing_source[1]`<br>fixture method L1347 | `old_owner_endpoint_distinct` | O:1605 | green / 1 / 0 | ASSERT named |
| G058 / #601 | `OldOwnerIsolationTests.test_deployed_source_collection_replay_and_missing_source[2]`<br>fixture method L1347 | `old_owner_runtime_parity` | O:1121 | green / 1 / 0 | ASSERT named |
| G059 / #601 | `OldOwnerIsolationTests.test_registry_adopted_behavioral_claim[1]`<br>fixture method L1375 | `old_owner_source_claim` | O:1141 | green / 1 / 0 | ASSERT named |
| G060 / #601 | `OldOwnerIsolationTests.test_immutable_address_negative_controls_and_removals[1]`<br>fixture method L1411 | `old_owner_immutable_not_old` | O:1076 | green / 1 / 0 | ASSERT named |
| G061 / #601 | `OldOwnerIsolationTests.test_immutable_address_negative_controls_and_removals[2]`<br>fixture method L1411 | `old_owner_immutable_expected` | O:1089 | green / 1 / 0 | ASSERT named |
| G062 / #601 | `OldOwnerIsolationTests.test_immutable_address_negative_controls_and_removals[3]`<br>fixture method L1411 | `old_owner_immutable_not_old` | O:1076 | green / 1 / 0 | ASSERT named |
| G063 / #601 | `OldOwnerIsolationTests.test_immutable_address_negative_controls_and_removals[4]`<br>fixture method L1411 | `old_owner_immutable_expectation_missing` | O:1086 | green / 1 / 0 | ASSERT named |
| G064 / #601 | `OldOwnerIsolationTests.test_immutable_address_negative_controls_and_removals[5]`<br>fixture method L1411 | `old_owner_immutable_ast` | O:1063 | green / 1 / 0 | ASSERT named |
| G065 / #601 | `OldOwnerIsolationTests.test_pin_time_immutable_gates[1]`<br>fixture method L1437 | `old_owner_immutable_not_old` | O:1076 | green / 1 / 0 | ASSERT named |
| G066 / #601 | `OldOwnerIsolationTests.test_pin_time_immutable_gates[2]`<br>fixture method L1437 | `old_owner_immutable_expected` | O:1089 | green / 1 / 0 | ASSERT named |
| G067 / #601 | `OldOwnerIsolationTests.test_immutable_ast_and_malformed_reference_controls[1]`<br>fixture method L1462 | `old_owner_immutable_address_encoding` | O:1074 | green / 1 / 0 | ASSERT named |
| G068 / #601 | `OldOwnerIsolationTests.test_immutable_ast_and_malformed_reference_controls[2]`<br>fixture method L1462 | `old_owner_immutable_values` | O:1064 | green / 1 / 0 | ASSERT named |
| G069 / #601 | `OldOwnerIsolationTests.test_clone_identity_and_factory_origin_controls[1]`<br>fixture method L1487 | `old_owner_clone_standard` | O:958 | green / 1 / 0 | ASSERT named |
| G070 / #601 | `OldOwnerIsolationTests.test_clone_identity_and_factory_origin_controls[2]`<br>fixture method L1487 | `old_owner_clone_standard` | O:958 | green / 1 / 0 | ASSERT named |
| G071 / #601 | `OldOwnerIsolationTests.test_clone_identity_and_factory_origin_controls[3]`<br>fixture method L1487 | `old_owner_clone_implementation` | O:969 | green / 1 / 0 | ASSERT named |
| G072 / #601 | `OldOwnerIsolationTests.test_clone_identity_and_factory_origin_controls[4]`<br>fixture method L1487 | `old_owner_clone_factory_nonce1` | O:970 | green / 1 / 0 | ASSERT named |
| G073 / #601 | `OldOwnerIsolationTests.test_clone_identity_and_factory_origin_controls[5]`<br>fixture method L1487 | `old_owner_clone_implementation` | O:969 | green / 1 / 0 | ASSERT named |
| G074 / #601 | `OldOwnerIsolationTests.test_clone_collection_and_post_upgrade_gate_removals[1]`<br>fixture method L1505 | `old_owner_clone_standard` | O:958 | green / 1 / 0 | ASSERT named |
| G075 / #601 | `OldOwnerIsolationTests.test_clone_collection_and_post_upgrade_gate_removals[2]`<br>fixture method L1505 | `old_owner_clone_standard` | O:958 | green / 1 / 0 | ASSERT named |
| G076 / #601 | `OldOwnerIsolationTests.test_clone_collection_and_post_upgrade_gate_removals[3]`<br>fixture method L1505 | `old_owner_clone_implementation` | O:969 | green / 1 / 0 | ASSERT named |
| G077 / #601 | `OldOwnerIsolationTests.test_clone_collection_and_post_upgrade_gate_removals[4]`<br>fixture method L1505 | `old_owner_clone_implementation` | O:969 | green / 1 / 0 | ASSERT named |
| G078 / #601 | `OldOwnerIsolationTests.test_clone_collection_and_post_upgrade_gate_removals[5]`<br>fixture method L1505 | `old_owner_clone_same_implementation` | O:1167 | green / 1 / 0 | ASSERT named |
| G079 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[1]`<br>fixture method L1538 | `old_owner_xpnts_owner_pin` | O:806 | green / 1 / 0 | ASSERT named |
| G080 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[2]`<br>fixture method L1538 | `old_owner_mapping_xPNTsToken_approvedFacilitators` | O:699 | green / 1 / 0 | ASSERT named |
| G081 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[3]`<br>fixture method L1538 | `old_owner_mapping_xPNTsToken_autoApprovedSpenders` | O:699 | green / 1 / 0 | ASSERT named |
| G082 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[4]`<br>fixture method L1538 | `old_owner_allowance_0x696a73701b104c6ccbbaaddd2216788ea08eab89_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` | O:827 | green / 1 / 0 | ASSERT named |
| G083 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[5]`<br>fixture method L1538 | `old_owner_xpnts_owner_pin` | O:806 | green / 1 / 0 | ASSERT named |
| G084 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[6]`<br>fixture method L1538 | `old_owner_mapping_xPNTsToken_approvedFacilitators` | O:699 | green / 1 / 0 | ASSERT named |
| G085 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[7]`<br>fixture method L1538 | `old_owner_mapping_xPNTsToken_autoApprovedSpenders` | O:699 | green / 1 / 0 | ASSERT named |
| G086 / #601 | `OldOwnerIsolationTests.test_named_clones_storage_authority_controls[8]`<br>fixture method L1538 | `old_owner_allowance_0xe6579a90dc498a710008de12119812d0fb7aa224_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` | O:827 | green / 1 / 0 | ASSERT named |
| G087 / #601 | `OldOwnerIsolationTests.test_metadata_bytes_cannot_be_masked_as_immutables[1]`<br>fixture method L1551 | `old_owner_source_rule4` | O:1015 | green / 1 / 0 | ASSERT named |
| G088 / #601 | `OldOwnerIsolationTests.test_metadata_bytes_cannot_be_masked_as_immutables[2]`<br>fixture method L1551 | `old_owner_metadata_unmasked` | O:1112 | green / 1 / 0 | ASSERT named |
| G089 / #601 | `OldOwnerIsolationTests.test_metadata_masked_requires_rule4[1]`<br>fixture method L1570 | `old_owner_source_rule4` | O:1015 | green / 1 / 0 | ASSERT named |
| G090 / #601 | `OldOwnerIsolationTests.test_metadata_masked_requires_rule4[2]`<br>fixture method L1570 | `old_owner_source_rule4` | O:1015 | green / 1 / 0 | ASSERT named |
| G091 / #601 | `OldOwnerIsolationTests.test_metadata_masked_requires_rule4[3]`<br>fixture method L1570 | `old_owner_source_rule4` | O:1015 | green / 1 / 0 | ASSERT named |
| G092 / #601 | `OldOwnerIsolationTests.test_recursive_manifest_abi_controls[1]`<br>fixture method L1619 | `old_owner_calldata_bytes` | O:1573 | green / 0 / 0 | ASSERT-UNNAMED |
| G093 / #601 | `OldOwnerIsolationTests.test_review_low_calldata_gates[1]`<br>fixture method L1643 | `old_owner_calldata_bytes` | O:1573 | green / 1 / 0 | ASSERT named |
| G094 / #601 | `OldOwnerIsolationTests.test_review_low_calldata_gates[2]`<br>fixture method L1643 | `old_owner_calldata_target` | O:1571 | green / 1 / 0 | ASSERT named |
| G095 / #601 | `OldOwnerIsolationTests.test_review_low_calldata_gates[3]`<br>fixture method L1643 | `old_owner_calldata_target` | O:1571 | green / 1 / 0 | ASSERT named |
| G096 / #601 | `OldOwnerIsolationTests.test_review_low_calldata_gates[4]`<br>fixture method L1643 | `old_owner_calldata_payload` | O:1562 | green / 1 / 0 | ASSERT named |
| G097 / #601 | `OldOwnerIsolationTests.test_review_low_endpoint_identity[1]`<br>fixture method L1715 | `old_owner_endpoint_distinct` | O:1605 | green / 1 / 0 | ASSERT named |
| G098 / #601 | `OldOwnerIsolationTests.test_review_low_endpoint_identity[2]`<br>fixture method L1715 | `old_owner_endpoint_distinct` | O:1605 | green / 1 / 0 | ASSERT named |
| G099 / #601 | `OldOwnerIsolationTests.test_review_low_registry_registered_exited[1]`<br>fixture method L1733 | `old_owner_uncancelled_grants` | O:1383 | green / 1 / 0 | ASSERT named |
| G100 / #601 | `OldOwnerIsolationTests.test_grants_cancellation_union_and_truncation[1]`<br>fixture method L1768 | `old_owner_uncancelled_grants` | O:1383 | green / 1 / 0 | ASSERT named |
| G101 / #601 | `OldOwnerIsolationTests.test_grants_cancellation_union_and_truncation[2]`<br>fixture method L1768 | `old_owner_log_partition` | O:1324 | green / 1 / 0 | ASSERT named |
| G102 / #601 | `OldOwnerIsolationTests.test_history_identity_gate_removals[1]`<br>fixture method L1861 | `old_owner_history_address` | O:1340 | green / 1 / 0 | ASSERT named |
| G103 / #601 | `OldOwnerIsolationTests.test_history_identity_gate_removals[2]`<br>fixture method L1861 | `old_owner_history_removed` | O:1341 | green / 1 / 0 | ASSERT named |
| G104 / #601 | `OldOwnerIsolationTests.test_history_identity_gate_removals[3]`<br>fixture method L1861 | `old_owner_history_signature` | O:1346 | green / 1 / 0 | ASSERT named |
| G105 / #601 | `OldOwnerIsolationTests.test_history_identity_gate_removals[4]`<br>fixture method L1861 | `old_owner_history_canonical` | O:1355 | green / 1 / 0 | ASSERT named |
| G106 / #601 | `OldOwnerIsolationTests.test_history_identity_gate_removals[5]`<br>fixture method L1861 | `old_owner_history_log_range` | O:1352 | green / 1 / 0 | ASSERT named |
| G107 / #601 | `OldOwnerIsolationTests.test_history_identity_gate_removals[6]`<br>fixture method L1861 | `old_owner_history_positive` | O:1369 | green / 1 / 0 | ASSERT named |
| G108 / #601 | `OldOwnerIsolationTests.test_source_implementation_and_boundary_gate_removals[1]`<br>fixture method L1885 | `old_owner_implementation` | O:1170 | green / 1 / 0 | ASSERT named |
| G109 / #601 | `OldOwnerIsolationTests.test_source_implementation_and_boundary_gate_removals[2]`<br>fixture method L1885 | `old_owner_creation_before` | O:1147 | green / 1 / 0 | ASSERT named |
| G110 / #601 | `OldOwnerIsolationTests.test_fork_pin_positive_and_restore_gates[1]`<br>fixture method L1900 | `old_owner_fork_pin` | O:1456 | green / 1 / 0 | ASSERT named |
| G111 / #601 | `OldOwnerIsolationTests.test_fork_pin_positive_and_restore_gates[2]`<br>fixture method L1900 | `old_owner_fork_head` | O:1457 | green / 1 / 0 | ASSERT named |
| G112 / #601 | `OldOwnerIsolationTests.test_fork_pin_positive_and_restore_gates[3]`<br>fixture method L1900 | `old_owner_fork_positive` | O:1482 | green / 1 / 0 | ASSERT named |
| G113 / #601 | `OldOwnerIsolationTests.test_fork_pin_positive_and_restore_gates[4]`<br>fixture method L1900 | `old_owner_fork_restore` | O:1499 | green / 1 / 0 | ASSERT named |
| G114 / #604 | `PhaseCTests.test_build_phase_c_inputs`<br>data_case(['phaseC', 'extra'], 1) | `phase_c_inputs` | M:1374 | green / 1 / 0 | ASSERT named |
| G115 / #604 | `PhaseCTests.test_build_phase_c_address_bundler`<br>data_case(['phaseC', 'bundler'], t.PC_BUNDLER.upper().replace('0X', '0x')) | `phase_c_address_bundler` | M:1357 | green / 1 / 0 | ASSERT named |
| G116 / #604 | `PhaseCTests.test_build_phase_c_identity_distinct`<br>data_case(['phaseC', 'bundler'], u.DEPLOYER) | `phase_c_identity_distinct` | M:1380 | green / 1 / 0 | ASSERT named |
| G117 / #604 | `PhaseCTests.test_build_phase_c_account_distinct`<br>data_case(['phaseC', 'account'], m.DEAD) | `phase_c_account_distinct` | M:1381 | green / 1 / 0 | ASSERT named |
| G118 / #604 | `PhaseCTests.test_build_phase_c_salt`<br>data_case(['phaseC', 'salt'], -1) | `phase_c_salt` | M:1369 | green / 1 / 0 | ASSERT named |
| G119 / #604 | `PhaseCTests.test_build_phase_c_runtime_keys`<br>data_case(['phaseC', 'runtimeKeccak', 'unexpected'], a.EMPTY_KECCAK) | `phase_c_runtime_keys` | M:1384 | green / 1 / 0 | ASSERT named |
| G120 / #604 | `PhaseCTests.test_build_phase_c_runtime_VerifyingPaymaster`<br>data_case(['phaseC', 'runtimeKeccak', 'VerifyingPaymaster'], a.EMPTY_KECCAK) | `phase_c_runtime_VerifyingPaymaster` | M:1363 | green / 1 / 0 | ASSERT named |
| G121 / #604 | `PhaseCTests.test_build_phase_c_account_evidence`<br>data_case(['phaseC', 'accountEvidence', 'sha256'], '9'*64) | `phase_c_account_evidence` | M:81 | green / 1 / 0 | ASSERT named |
| G122 / #604 | `PhaseCTests.test_build_phase_c_account_evidence_nonempty`<br>data_case(['phaseC', 'accountEvidence'], evidence('blank-account', ' \n')) | `phase_c_account_evidence_nonempty` | M:1388 | green / 1 / 0 | ASSERT named |
| G123 / #604 | `PhaseCTests.test_build_phase_c_rehearsal`<br>data_case(['phaseC', 'rehearsal', 'extra'], []) | `phase_c_rehearsal` | M:1391 | green / 1 / 0 | ASSERT named |
| G124 / #604 | `PhaseCTests.test_build_phase_c_rehearsal_evidence_nonempty`<br>data_case(['phaseC', 'rehearsal', 'evidence'], evidence('blank-rehearsal', '\n')) | `phase_c_rehearsal_evidence_nonempty` | M:1393 | green / 1 / 0 | ASSERT named |
| G125 / #604 | `PhaseCTests.test_build_phase_c_arms`<br>data_case(ARM+['extra'], {}) | `phase_c_arms` | M:1395 | green / 1 / 0 | ASSERT named |
| G126 / #604 | `PhaseCTests.test_build_phase_c_arm_fields_SP`<br>data_case(ARM+['SP', 'postOp'], 1) | `phase_c_arm_fields_SP` | M:1399 | green / 1 / 0 | ASSERT named |
| G127 / #604 | `PhaseCTests.test_build_phase_c_measurement`<br>data_case(ARM+['VPM', 'call'], 0) | `phase_c_measurement` | M:1369 | green / 1 / 0 | ASSERT named |
| G128 / #604 | `PhaseCTests.test_build_phase_c_owner_preparation`<br>data_case(['phaseC', 'rehearsal', 'ownerPreparation', 'extra'], 1) | `phase_c_owner_preparation` | M:1402 | green / 1 / 0 | ASSERT named |
| G129 / #604 | `PhaseCTests.test_build_phase_c_maintenance_list`<br>data_case(['phaseC', 'rehearsal', 'ownerMaintenance'], {}) | `phase_c_maintenance_list` | M:1406 | green / 1 / 0 | ASSERT named |
| G130 / #604 | `PhaseCTests.test_build_phase_c_maintenance_fields`<br>data_case(['phaseC', 'rehearsal', 'bundlerMaintenance'], [dict(name='x', gas=1, extra=1)]) | `phase_c_maintenance_fields` | M:1408 | green / 1 / 0 | ASSERT named |
| G131 / #604 | `PhaseCTests.test_build_phase_c_maintenance_name`<br>data_case(['phaseC', 'rehearsal', 'bundlerMaintenance'], [dict(name=' x', gas=1)]) | `phase_c_maintenance_name` | M:1409 | green / 1 / 0 | ASSERT named |
| G132 / #604 | `PhaseCTests.test_build_phase_c_maintenance_unique`<br>data_case(['phaseC', 'rehearsal', 'bundlerMaintenance'], [dict(name='x', gas=1), dict(name='x', gas=2)]) | `phase_c_maintenance_unique` | M:1412 | green / 1 / 0 | ASSERT named |
| G133 / #604 | `PhaseCTests.test_build_stage_inputs`<br>data_case(['phaseC'], delete=True) | `stage_inputs` | M:126 | green / 1 / 0 | ASSERT named |
| G134 / #604 | `PhaseCTests.test_build_sampled_deployer_only`<br>data_case(['sampled'], sorted([u.DEPLOYER, t.ANNI])) | `sampled_deployer_only` | M:659 | green / 1 / 0 | ASSERT named |
| G135 / #604 | `PhaseCTests.test_build_C_amax_cap`<br>data_case(ARM+['SP', 'call'], 10**9) | `C_amax_cap` | M:1520 | green / 1 / 0 | ASSERT named |
| G136 / #604 | `PhaseCTests.test_build_stage_pin_phase_c`<br>lambda data, pin, case: pin.pop('phaseC') | `stage_pin_phase_c` | M:2103 | green / 1 / 0 | ASSERT named |
| G137 / #604 | `PhaseCTests.test_build_phase_c_pin`<br>pin_case(['phaseC', 'extra'], 1) | `phase_c_pin` | M:1470 | green / 1 / 0 | ASSERT named |
| G138 / #604 | `PhaseCTests.test_build_phase_c_pin_identity_owner`<br>pin_case(['phaseC', 'owner', 'address'], '0x'+'99'*20) | `phase_c_pin_identity_owner` | M:1472 | green / 1 / 0 | ASSERT named |
| G139 / #604 | `PhaseCTests.test_build_phase_c_eoa_bundler`<br>pin_case(['phaseC', 'bundler', 'code'], '0x6000') | `phase_c_eoa_bundler` | M:1473 | green / 1 / 0 | ASSERT named |
| G140 / #604 | `PhaseCTests.test_build_C1_minter`<br>pin_case(['phaseC', 'capped', 'minter'], u.DEPLOYER) | `C1_minter` | M:1474 | green / 1 / 0 | ASSERT named |
| G141 / #604 | `PhaseCTests.test_build_C_price_shape`<br>pin_case(['phaseC', 'sp', 'cachedPrice'], [1, 2, 3]) | `C_price_shape` | M:1476 | green / 1 / 0 | ASSERT named |
| G142 / #604 | `PhaseCTests.test_build_C_price_bound`<br>pin_case(['phaseC', 'sp', 'cachedPrice'], [3500*10**8+1, 0, 1, 8]) | `C_price_bound` | M:1479 | green / 1 / 0 | ASSERT named |
| G143 / #604 | `PhaseCTests.test_build_C_pricing_nonzero`<br>pin_case(['phaseC', 'sp', 'aPNTsPriceUSD'], 0) | `C_pricing_nonzero` | M:1480 | green / 1 / 0 | ASSERT named |
| G144 / #604 | `PhaseCTests.test_build_C_operator_shape`<br>pin_case(['phaseC', 'sp', 'deployerOperator'], [0]*8) | `C_operator_shape` | M:1481 | green / 1 / 0 | ASSERT named |
| G145 / #604 | `PhaseCTests.test_build_C2_operator_role`<br>pin_case(['phaseC', 'roles', 'PAYMASTER_SUPER'], 0) | `C2_operator_role` | M:1482 | green / 1 / 0 | ASSERT named |
| G146 / #604 | `PhaseCTests.test_build_C3_community`<br>pin_case(['phaseC', 'roles', 'COMMUNITY'], 0) | `C3_community` | M:1483 | green / 1 / 0 | ASSERT named |
| G147 / #604 | `PhaseCTests.test_build_C7_enduser_active`<br>pin_case(['phaseC', 'endUser', 'roleConfig'], lambda case: config_raw(active=False)) | `C7_enduser_active` | M:1485 | green / 1 / 0 | ASSERT named |
| G148 / #604 | `PhaseCTests.test_build_C5_factory_runtime`<br>pin_case(['phaseC', 'account', 'factoryCodeHash'], '0x'+'77'*32) | `C5_factory_runtime` | M:1487 | green / 1 / 0 | ASSERT named |
| G149 / #604 | `PhaseCTests.test_build_C5_factory_implementation`<br>pin_case(['phaseC', 'account', 'implementation'], '0x'+'77'*20) | `C5_factory_implementation` | M:1488 | green / 1 / 0 | ASSERT named |
| G150 / #604 | `PhaseCTests.test_build_C5_implementation_runtime`<br>pin_case(['phaseC', 'account', 'implementationCodeHash'], '0x'+'77'*32) | `C5_implementation_runtime` | M:1489 | green / 1 / 0 | ASSERT named |
| G151 / #604 | `PhaseCTests.test_build_C5_implementation_entrypoint`<br>pin_case(['phaseC', 'account', 'implementationEntryPoint'], '0x'+'77'*20) | `C5_implementation_entrypoint` | M:1490 | green / 1 / 0 | ASSERT named |
| G152 / #604 | `PhaseCTests.test_build_C5_counterfactual`<br>pin_case(['phaseC', 'account', 'counterfactual'], '0x'+'77'*20) | `C5_counterfactual` | M:1491 | green / 1 / 0 | ASSERT named |
| G153 / #604 | `PhaseCTests.test_build_C5_existing_account`<br>pin_case(['phaseC', 'account', 'codeHash'], t.PC_RUNTIMES['account']) | `C5_existing_account` | M:1494 | green / 1 / 0 | ASSERT named |
| G154 / #604 | `PhaseCTests.test_build_C_account_status`<br>pin_case(['phaseC', 'account', 'status'], [1, 0, 0]) | `C_account_status` | M:1497 | green / 1 / 0 | ASSERT named |
| G155 / #604 | `PhaseCTests.test_build_C1_cap_headroom`<br>pin_case(['phaseC', 'capped', 'cap'], 10**18) | `C1_cap_headroom` | M:1526 | green / 1 / 0 | ASSERT named |
| G156 / #604 | `PhaseCTests.test_build_C6_gtoken_balance`<br>pin_case(['phaseC', 'endUser', 'deployerGToken'], 2) | `C6_gtoken_balance` | M:1540 | green / 1 / 0 | ASSERT named |
| G157 / #604 | `PhaseCTests.test_build_budget_deployer_values`<br>pin_case(['senders', 'deployer', 'balance'], 10**18) | `budget_deployer_values` | M:2502 | green / 1 / 0 | ASSERT named |
| G158 / #604 | `PhaseCTests.test_rebuild_baseline_forge_version`<br>'version' | `baseline_forge_version` | M:1309 | green / 1 / 0 | ASSERT named |
| G159 / #604 | `PhaseCTests.test_rebuild_baseline_offline_build`<br>'build' | `baseline_offline_build` | M:1318 | green / 1 / 0 | ASSERT named |
| G160 / #604 | `PhaseCTests.test_rebuild_baseline_immutables_F1TestToken`<br>'immutables' | `baseline_immutables_F1TestToken` | M:1324 | green / 1 / 0 | ASSERT named |
| G161 / #604 | `PhaseCTests.test_rebuild_baseline_source_VerifyingPaymaster`<br>'source' | `baseline_source_VerifyingPaymaster` | M:1330 | green / 1 / 0 | ASSERT named |
| G162 / #604 | `PhaseCTests.test_rebuild_baseline_constructor_count_TokenPaymaster`<br>'constructors' | `baseline_constructor_count_TokenPaymaster` | M:1332 | green / 1 / 0 | ASSERT named |
| G163 / #604 | `PhaseCTests.test_pin_price_zero`<br>fixture method L312 | `C_price_bound` | M:1479 | green / 1 / 0 | ASSERT named |
| G164 / #604 | `PhaseCTests.test_stage_c_boundary_and_prefix`<br>fixture method L380 | `prefix_boundary` | M:2085 | green / 1 / 0 | ASSERT named |
| G165 / #604 | `PhaseCTests.test_stage_c_prefix_must_end_in_phase_c`<br>fixture method L407 | `prefix_boundary_last` | M:2087 | green / 1 / 0 | ASSERT named |
| G166 / #604 | `PhaseCTests.test_stage_c_artifact_never_final`<br>fixture method L398 | `final_stage` | M:3592 | green / 1 / 0 | ASSERT named |
| G167 / #604 | `PhaseCTests.test_collect_phase_c_pending_nonce`<br>fixture method L464 | `phase_c_pending_nonce_owner` | M:1432 | green / 1 / 0 | ASSERT named |
| G168 / #604 | `LiveGateTests.test_live_C_after_activation`<br>('C2.approve', lambda c: c.context['passed'].discard('B4')) | `C_after_activation` | M:2943 | green / 1 / 0 | ASSERT named |
| G169 / #604 | `LiveGateTests.test_live_C_after_token_eta`<br>('C2.approve', lambda c: setattr(c, 'now', c.plan['pin']['pendingAPNTsTokenEta']-1)) | `C_after_token_eta` | M:2945 | green / 1 / 0 | ASSERT named |
| G170 / #604 | `LiveGateTests.test_live_C_token_swapped`<br>('C2.approve', lambda c: c.set(SP, 'APNTS_TOKEN()', value=int(m.DEAD, 16))) | `C_token_swapped` | M:2946 | green / 1 / 0 | ASSERT named |
| G171 / #604 | `LiveGateTests.test_live_C_gas_tuple`<br>('C2.approve', lambda c: c.set(SP, 'gasParams()', value=u.GAS+[1, 0, 0, 0, 0])) | `C_gas_tuple` | M:2948 | green / 1 / 0 | ASSERT named |
| G172 / #604 | `LiveGateTests.test_live_C_global_unpaused`<br>('C2.approve', lambda c: c.set(SP, 'paused()', value=1)) | `C_global_unpaused` | M:2949 | green / 1 / 0 | ASSERT named |
| G173 / #604 | `LiveGateTests.test_live_C_sampled_unpaused`<br>('C2.approve', lambda c: c.get(SP, 'operators(address)', D).__setitem__(2, 1)) | `C_sampled_unpaused` | M:2952 | green / 1 / 0 | ASSERT named |
| G174 / #604 | `LiveGateTests.test_live_C_unsampled_paused`<br>('C2.approve', lambda c: c.get(SP, 'operators(address)', t.ANNI).__setitem__(2, 0)) | `C_unsampled_paused` | M:2952 | green / 1 / 0 | ASSERT named |
| G175 / #604 | `LiveGateTests.test_live_C_price_decimals`<br>('C2.approve', lambda c: c.get(SP, 'cachedPrice()').__setitem__(3, 18)) | `C_price_decimals` | M:2936 | green / 1 / 0 | ASSERT named |
| G176 / #604 | `LiveGateTests.test_live_C_price_bound`<br>('C2.approve', lambda c: c.get(SP, 'cachedPrice()').__setitem__(0, 3500*10**8+1)) | `C_price_bound` | M:2937 | green / 1 / 0 | ASSERT named |
| G177 / #604 | `LiveGateTests.test_live_C_pricing_unchanged`<br>('C2.approve', lambda c: c.set(SP, 'protocolFeeBPS()', value=1001)) | `C_pricing_unchanged` | M:2956 | green / 1 / 0 | ASSERT named |
| G178 / #604 | `LiveGateTests.test_live_C1_minter`<br>('C1_approve', lambda c: c.set(c.plan['pin']['capped'], 'minter()', value=int(D, 16))) | `C1_minter` | M:2968 | green / 1 / 0 | ASSERT named |
| G179 / #604 | `LiveGateTests.test_live_C1_cap_headroom`<br>('C1_exec', lambda c: c.set(c.plan['pin']['capped'], 'totalSupply()', value=10**27)) | `C1_cap_headroom` | M:2969 | green / 1 / 0 | ASSERT named |
| G180 / #604 | `LiveGateTests.test_live_C1_pinned_balance`<br>('C1_approve', lambda c: c.set(c.plan['pin']['capped'], 'balanceOf(address)', D, value=0)) | `C1_pinned_balance` | M:2970 | green / 1 / 0 | ASSERT named |
| G181 / #604 | `LiveGateTests.test_live_C2_operator_role`<br>('C2.approve', lambda c: c.set(u.REG, 'hasRole(bytes32,address)', m.role_id('PAYMASTER_SUPER'), D, value=0)) | `C2_operator_role` | M:2972 | green / 1 / 0 | ASSERT named |
| G182 / #604 | `LiveGateTests.test_live_C2_token_balance`<br>('C2.approve', lambda c: c.set(c.plan['pin']['capped'], 'balanceOf(address)', D, value=c.plan['phaseC']['operatorTopUp']-1)) | `C2_token_balance` | M:2973 | green / 1 / 0 | ASSERT named |
| G183 / #604 | `LiveGateTests.test_live_C_operator_before`<br>('C3.configure', lambda c: c.get(SP, 'operators(address)', D).__setitem__(4, 1)) | `C_operator_before` | M:2984 | green / 1 / 0 | ASSERT named |
| G184 / #604 | `LiveGateTests.test_live_C3_factory_active`<br>('C3.deploy', lambda c: c.set(SP, 'xpntsFactory()', value=0)) | `C3_factory_active` | M:2978 | green / 1 / 0 | ASSERT named |
| G185 / #604 | `LiveGateTests.test_live_C3_community`<br>('C3.deploy', lambda c: c.set(u.REG, 'hasRole(bytes32,address)', m.role_id('COMMUNITY'), D, value=0)) | `C3_community` | M:2979 | green / 1 / 0 | ASSERT named |
| G186 / #604 | `LiveGateTests.test_live_C3_factory_fresh`<br>('C3.deploy', lambda c: c.set(c.factory, 'getDeployedCount()', value=1)) | `C3_factory_fresh` | M:2981 | green / 1 / 0 | ASSERT named |
| G187 / #604 | `LiveGateTests.test_live_C5_counterfactual`<br>('C5', lambda c: c.set(m.ACCOUNT_FACTORY, 'getAddress(address,uint256)', c.O, 7, value=1)) | `C5_counterfactual` | M:2986 | green / 1 / 0 | ASSERT named |
| G188 / #604 | `LiveGateTests.test_live_C5_absent`<br>('C5', lambda c: c.codes.__setitem__(c.S, '0x6000')) | `C5_absent` | M:2987 | green / 1 / 0 | ASSERT named |
| G189 / #604 | `LiveGateTests.test_live_C7_enduser_active`<br>('C6', lambda c: c.set(u.REG, 'getRoleConfig(bytes32)', m.role_id('ENDUSER'), value=config_raw(False))) | `C7_enduser_active` | M:2990 | green / 1 / 0 | ASSERT named |
| G190 / #604 | `LiveGateTests.test_live_C7_enduser_config`<br>('C7', lambda c: c.set(u.REG, 'getRoleConfig(bytes32)', m.role_id('ENDUSER'), value=config_raw(True, 5))) | `C7_enduser_config` | M:2991 | green / 1 / 0 | ASSERT named |
| G191 / #604 | `LiveGateTests.test_live_C_account_status`<br>('C6', lambda c: c.set(SP, 'sbtHolders(address)', c.S, value=1)) | `C_account_status` | M:2993 | green / 1 / 0 | ASSERT named |
| G192 / #604 | `LiveGateTests.test_live_C6_gtoken_balance`<br>('C6', lambda c: c.set(c.plan['pin']['phaseC']['endUser']['gtoken'], 'balanceOf(address)', D, value=1)) | `C6_gtoken_balance` | M:2995 | green / 1 / 0 | ASSERT named |
| G193 / #604 | `LiveGateTests.test_live_C8_community_owner`<br>('C8', lambda c: c.set(c.X, 'communityOwner()', value=1)) | `C8_community_owner` | M:2998 | green / 1 / 0 | ASSERT named |
| G194 / #604 | `LiveGateTests.test_live_C8_policy_off`<br>('C8', lambda c: c.set(c.X, 'pendingPolicyEta()', value=1)) | `C8_policy_off` | M:2999 | green / 1 / 0 | ASSERT named |
| G195 / #604 | `LiveGateTests.test_live_C8_user_clean`<br>('C8', lambda c: c.set(c.X, 'debts(address)', c.S, value=1)) | `C8_user_clean` | M:3000 | green / 1 / 0 | ASSERT named |
| G196 / #604 | `LiveGateTests.test_live_C8_amax_limit`<br>('C8', lambda c: c.set(c.X, 'maxSingleTxLimit()', value=c.plan['phaseC']['Amax']-1)) | `C8_amax_limit` | M:3002 | green / 1 / 0 | ASSERT named |
| G197 / #604 | `LiveGateTests.test_live_C9_account_owner`<br>('C9.allowance', lambda c: c.set(c.S, 'owner()', value=1)) | `C9_account_owner` | M:3004 | green / 1 / 0 | ASSERT named |
| G198 / #604 | `LiveGateTests.test_live_C_owner_budget`<br>('C9.allowance', lambda c: c.balances.__setitem__(c.O, c.balances[c.O]-1)) | `C_owner_budget` | M:3009 | green / 1 / 0 | ASSERT named |
| G199 / #604 | `LiveGateTests.test_live_C9_counters`<br>('C9.total', lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP, value=[m.PC_CAP_L, 1])) | `C9_counters` | M:3011 | green / 1 / 0 | ASSERT named |
| G200 / #604 | `LiveGateTests.test_live_C_create_unused`<br>('C10', lambda c: c.codes.__setitem__(c.plan['phaseC']['addresses']['T'], '0x6000')) | `C_create_unused` | M:3015 | green / 1 / 0 | ASSERT named |
| G201 / #604 | `LiveGateTests.test_live_C17_deposit_before`<br>('C17.vpm', lambda c: c.set(c.ep, 'balanceOf(address)', c.plan['phaseC']['addresses']['VPM'], value=1)) | `C17_deposit_before` | M:3019 | green / 1 / 0 | ASSERT named |
| G202 / #604 | `LiveGateTests.test_live_C18_fee_balance`<br>('C18.mint', lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'balanceOf(address)', c.S, value=1)) | `C18_fee_balance` | M:3022 | green / 1 / 0 | ASSERT named |
| G203 / #604 | `LiveGateTests.test_live_C19_recipient_balance`<br>('C19', lambda c: c.balances.__setitem__(c.B, 1)) | `C19_recipient_balance` | M:3026 | green / 1 / 0 | ASSERT named |
| G204 / #604 | `LiveGateTests.test_live_C19_recipient_eoa`<br>('C19', lambda c: c.codes.__setitem__(c.B, '0xef0100'+'11'*20)) | `C19_recipient_eoa` | M:3027 | green / 1 / 0 | ASSERT named |
| G205 / #604 | `LiveGateTests.test_live_C20_recipient_balance`<br>('C20', lambda c: c.balances.__setitem__(c.O, 1)) | `C20_recipient_balance` | M:3026 | green / 1 / 0 | ASSERT named |
| G206 / #604 | `LiveGateTests.test_live_C20_recipient_eoa`<br>('C20', lambda c: c.codes.__setitem__(c.O, '0x6000')) | `C20_recipient_eoa` | M:3027 | green / 1 / 0 | ASSERT named |
| G207 / #604 | `LiveGateTests.test_precheck_SP_RENEW_never`<br>(m.FLAG_SP_RENEW, lambda c: None) | `SP_RENEW_never` | M:3036 | green / 1 / 0 | ASSERT named |
| G208 / #604 | `LiveGateTests.test_precheck_precheck_renewal_mode`<br>(0, lambda c: c.set(c.X, 'renewalMode(address)', c.S, value=1)) | `precheck_renewal_mode` | M:3043 | green / 1 / 0 | ASSERT named |
| G209 / #604 | `LiveGateTests.test_precheck_precheck_allowance`<br>(0, lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP, value=[m.PC_CAP_L, m.PC_CAP_L-c.plan['phaseC']['Amax']+1])) | `precheck_allowance` | M:3050 | green / 1 / 0 | ASSERT named |
| G210 / #604 | `LiveGateTests.test_precheck_precheck_total`<br>(0, lambda c: c.set(c.X, 'userTotal(address)', c.S, value=[m.PC_CAP_L, m.PC_CAP_L-c.plan['phaseC']['Amax']+1])) | `precheck_total` | M:3051 | green / 1 / 0 | ASSERT named |
| G211 / #604 | `LiveGateTests.test_precheck_precheck_allowance_cap`<br>(0, lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP, value=[2*m.PC_CAP_L, m.PC_CAP_L])) | `precheck_allowance_cap` | M:3048 | green / 1 / 0 | ASSERT named |
| G212 / #604 | `LiveGateTests.test_precheck_precheck_total_cap`<br>(0, lambda c: c.set(c.X, 'userTotal(address)', c.S, value=[m.PC_CAP_L-1, 0])) | `precheck_total_cap` | M:3049 | green / 1 / 0 | ASSERT named |
| G213 / #604 | `LiveGateTests.test_precheck_precheck_allowance_cap__lowered`<br>(0, lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP, value=[m.PC_CAP_L-1, 0])) | `precheck_allowance_cap` | M:3048 | green / 1 / 0 | ASSERT named |
| G214 / #604 | `LiveGateTests.test_precheck_precheck_total_cap__raised`<br>(0, lambda c: c.set(c.X, 'userTotal(address)', c.S, value=[2*m.PC_CAP_L, m.PC_CAP_L])) | `precheck_total_cap` | M:3049 | green / 1 / 0 | ASSERT named |
| G215 / #604 | `LiveGateTests.test_funding_C_funding_entrypoint_SP`<br>lambda c: c.set(c.ep, 'balanceOf(address)', SP, value=c.plan['phaseC']['entryPointTargets']['SP']-1) | `C_funding_entrypoint_SP` | M:3067 | green / 1 / 0 | ASSERT named |
| G216 / #604 | `LiveGateTests.test_funding_C_funding_entrypoint_VPM`<br>lambda c: c.set(c.ep, 'balanceOf(address)', c.plan['phaseC']['addresses']['VPM'], value=0) | `C_funding_entrypoint_VPM` | M:3067 | green / 1 / 0 | ASSERT named |
| G217 / #604 | `LiveGateTests.test_funding_C_funding_entrypoint_TPM`<br>lambda c: c.set(c.ep, 'balanceOf(address)', c.plan['phaseC']['addresses']['TPM'], value=1) | `C_funding_entrypoint_TPM` | M:3067 | green / 1 / 0 | ASSERT named |
| G218 / #604 | `LiveGateTests.test_funding_C_funding_bundler`<br>lambda c: c.balances.__setitem__(c.B, c.plan['phaseC']['bundlerTarget']-1) | `C_funding_bundler` | M:3071 | green / 1 / 0 | ASSERT named |
| G219 / #604 | `LiveGateTests.test_funding_C_funding_owner`<br>lambda c: c.balances.__setitem__(c.O, c.plan['phaseC']['ownerMaintenanceWei']-1) | `C_funding_owner` | M:3071 | green / 1 / 0 | ASSERT named |
| G220 / #604 | `LiveGateTests.test_funding_C_funding_user`<br>lambda c: c.set(c.X, 'balanceOf(address)', c.S, value=1) | `C_funding_user` | M:3078 | green / 1 / 0 | ASSERT named |
| G221 / #604 | `LiveGateTests.test_funding_C_funding_feeToken`<br>lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'balanceOf(address)', c.S, value=1) | `C_funding_feeToken` | M:3078 | green / 1 / 0 | ASSERT named |
| G222 / #604 | `LiveGateTests.test_funding_C_funding_taskSender`<br>lambda c: c.set(c.plan['phaseC']['addresses']['T'], 'balanceOf(address)', c.S, value=300) | `C_funding_taskSender` | M:3078 | green / 1 / 0 | ASSERT named |
| G223 / #604 | `LiveGateTests.test_funding_C_funding_taskRecipient`<br>lambda c: c.set(c.plan['phaseC']['addresses']['T'], 'balanceOf(address)', m.DEAD, value=0) | `C_funding_taskRecipient` | M:3078 | green / 1 / 0 | ASSERT named |
| G224 / #604 | `LiveGateTests.test_funding_C_funding_feeAllowance`<br>lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'allowance(address,address)', c.S, c.plan['phaseC']['addresses']['TPM'], value=1) | `C_funding_feeAllowance` | M:3080 | green / 1 / 0 | ASSERT named |
| G225 / #604 | `LiveGateTests.test_funding_C_funding_feeAllowance__above`<br>lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'allowance(address,address)', c.S, c.plan['phaseC']['addresses']['TPM'], value=c.plan['phaseC']['feeTokenTarget']+1) | `C_funding_feeAllowance` | M:3080 | green / 1 / 0 | ASSERT named |
| G226 / #604 | `LiveGateTests.test_funding_C_funding_operator`<br>lambda c: c.get(SP, 'operators(address)', D).__setitem__(0, c.plan['phaseC']['operatorTarget']-1) | `C_funding_operator` | M:3074 | green / 1 / 0 | ASSERT named |
| G227 / #604 | `LiveGateTests.test_accounting`<br>fixture method L748 | `C_accounting` | M:3541 | green / 1 / 0 | ASSERT named |
| G228 / #604 | `LiveGateTests.test_owner_gas_bound`<br>fixture method L756 | `C_owner_gas_bound` | M:2931 | green / 1 / 0 | ASSERT named |
| G229 / #604 | `LiveGateTests.test_budget_owner_shortfall`<br>fixture method L769 | `budget_owner` | M:2876 | green / 1 / 0 | ASSERT named |
| G230 / #604 | `LiveGateTests.test_handover_requires_phase_c`<br>fixture method L805 | `handover_dependencies` | M:2579 | green / 1 / 0 | ASSERT named |
| G231 / #604 | `ManifestTests.test_rehearsal_phase_c_controls_complete`<br>fixture method L1773 | `phase_c_controls_complete` | M:3493 | green / 1 / 0 | ASSERT named |
| G232 / #604 | `ManifestTests.test_rehearsal_after_6d_accounting`<br>fixture method L1777 | `after_6d_accounting` | M:3460 | green / 1 / 0 | ASSERT named |
| G233 / #604 | `ManifestTests.test_rehearsal_accounting_unchanged_since_phase_c`<br>fixture method L1781 | `accounting_unchanged_since_phase_c` | M:3519 | green / 1 / 0 | ASSERT named |
| G234 / #604 | `ManifestTests.test_rehearsal_funding_rechecked_after_phase_c`<br>fixture method L1784 | `C_funding_bundler` | M:3071 | green / 1 / 0 | ASSERT named |
| G235 / #604 | `ManifestTests.test_pin_pending_token_eta`<br>fixture method L1588 | `pin_pending_token_eta` | M:2132 | green / 1 / 0 | ASSERT named |
| G236 / #604 | `ManifestTests.test_collect_direct_fake_chain`<br>fixture method L3000 | `old_aggregator_slash_policy_admin` | M:1933 | green / 1 / 0 | ASSERT named |
| G237 / #604 | `ManifestTests.test_dvt_closing_binds_pointer_and_stale_proposals`<br>fixture method L2263 | `closing_registry_pointer` | M:1211 | green / 1 / 0 | ASSERT named |
| G238 / #604 | `ManifestTests.test_dvt_closing_binds_pointer_and_stale_proposals`<br>fixture method L2263 | `closing_committee_pointer` | M:1213 | green / 1 / 0 | ASSERT named |
| G239 / #604 | `ManifestTests.test_old_timelock_holds_nothing`<br>fixture method L2246 | `old_timelock_holds_nothing` | M:1196 | green / 1 / 0 | ASSERT named |
| G240 / #604 | `ManifestTests.test_old_timelock_tl_roles`<br>fixture method L2225 | `old_timelock_tl_roles` | M:1151 | green / 1 / 0 | ASSERT named |
| G241 / #604 | `ManifestTests.test_old_timelock_authority`<br>fixture method L2230 | `old_timelock_authority` | M:1164 | green / 1 / 0 | ASSERT named |
| G242 / #604 | `ManifestTests.test_old_timelock_safe`<br>fixture method L2241 | `old_timelock_safe` | M:1194 | green / 1 / 0 | ASSERT named |
| G243 / #604 | `ManifestTests.test_old_timelock_schema`<br>fixture method L2019 | `old_timelock_schema` | M:897 | green / 1 / 0 | ASSERT named |
| G244 / #604 | `ManifestTests.test_old_timelock_block`<br>fixture method L2022 | `old_timelock_block` | M:907 | green / 1 / 0 | ASSERT named |
| G245 / #604 | `ManifestTests.test_old_timelock_unused`<br>fixture method L2031 | `old_timelock_unused` | M:919 | green / 1 / 0 | ASSERT named |
| G246 / #604 | `ManifestTests.test_old_timelock_allowance`<br>fixture method L2037 | `old_timelock_allowance` | M:1191 | green / 1 / 0 | ASSERT named |
| G247 / #604 | `ManifestTests.test_old_timelock_inventory_new_role`<br>fixture method L2208 | `old_timelock_inventory` | M:1079 | green / 1 / 0 | ASSERT named |
| G248 / #604 | `ManifestTests.test_old_timelock_inventory_new_token`<br>fixture method L2211 | `old_timelock_inventory` | M:1079 | green / 1 / 0 | ASSERT named |
| G249 / #604 | `ManifestTests.test_old_timelock_approval_history_range`<br>fixture method L2121 | `old_timelock_approval_history` | M:1178 | green / 1 / 0 | ASSERT named |
| G250 / #604 | `ManifestTests.test_old_timelock_external_approval`<br>fixture method L2066 | `old_timelock_allowance` | M:1191 | green / 1 / 0 | ASSERT named |
| G251 / #604 | `ManifestTests.test_old_timelock_approval_incomplete`<br>fixture method L2107 | `old_owner_log_partition` | O:1324 | green / 1 / 0 | ASSERT named |
| G252 / #604 | `ManifestTests.test_never_granted_closing_change`<br>fixture method L1921 | `old_owner_never_granted_recheck` | O:1437 | green / 1 / 0 | ASSERT named |
| G253 / #604 | `ManifestTests.test_never_granted_pre_send_change`<br>fixture method L1924 | `old_owner_never_granted_recheck` | O:1437 | green / 1 / 0 | ASSERT named |
| G254 / #604 | `ManifestTests.test_old_role_closing_change`<br>fixture method L1954 | `old_owner_role_recheck` | O:1440 | green / 1 / 0 | ASSERT named |
| G255 / #604 | `ManifestTests.test_old_role_pre_send_change`<br>fixture method L1957 | `old_owner_role_recheck` | O:1440 | green / 1 / 0 | ASSERT named |
| G256 / #604 | `ManifestTests.test_old_timelock_replay_reads`<br>fixture method L2025 | `old_timelock_replay` | M:912 | green / 1 / 0 | ASSERT named |
| G257 / #604 | `ManifestTests.test_old_timelock_replay_owners`<br>fixture method L2028 | `old_timelock_replay` | M:918 | green / 1 / 0 | ASSERT named |
| G258 / #604 | `ManifestTests.test_old_timelock_approval_history_log`<br>fixture method L2124 | `old_timelock_approval_history` | M:1184 | green / 1 / 0 | ASSERT named |
| G259 / #604 | `ManifestTests.test_xpnts_owner_pre_send`<br>fixture method L1951 | `old_owner_xpnts_owner_recheck` | O:1443 | green / 1 / 0 | ASSERT named |
| G260 / #604 | `ManifestTests.test_xpnts_owner_closing`<br>fixture method L1948 | `old_owner_xpnts_owner_recheck` | O:1443 | green / 1 / 0 | ASSERT named |
| G261 / #604 | `OldOwnerIsolationTests.test_legacy_timelock_source_targets`<br>fixture method L931 | `old_owner_source_targets` | O:1133 | green / 1 / 0 | ASSERT named |
| G262 / #604 | `OldOwnerIsolationTests.test_never_granted_range_grant`<br>fixture method L366 | `old_owner_never_granted_set` | O:1372 | green / 1 / 0 | ASSERT named |
| G263 / #604 | `OldOwnerIsolationTests.test_never_granted_control_holder`<br>fixture method L393 | `old_owner_never_granted_holder` | O:672 | green / 1 / 0 | ASSERT named |
| G264 / #604 | `OldOwnerIsolationTests.test_mapping_function_getter_rejected_per_role`<br>fixture method L524 | `old_owner_mapping_getter` | O:1391 | green / 1 / 0 | ASSERT named |
| G265 / #604 | `OldOwnerIsolationTests.test_role_control_case_without_path_gate`<br>fixture method L498 | `old_owner_role_control_case` | O:660 | green / 1 / 0 | ASSERT named |
| G266 / #604 | `OldOwnerIsolationTests.test_mapping_positive_zero`<br>fixture method L514 | `old_owner_mapping_positive` | O:1396 | green / 1 / 0 | ASSERT named |
| G267 / #604 | `OldOwnerIsolationTests.test_mapping_negative_one`<br>fixture method L519 | `old_owner_mapping_negative` | O:1397 | green / 1 / 0 | ASSERT named |
| G268 / #604 | `OldOwnerIsolationTests.test_never_granted_extra_zero`<br>fixture method L376 | `old_owner_history_positive` | O:1369 | green / 1 / 0 | ASSERT named |
| G269 / #604 | `OldOwnerIsolationTests.test_never_granted_missing_role`<br>fixture method L381 | `old_owner_never_granted_set` | O:1372 | green / 1 / 0 | ASSERT named |
| G270 / #604 | `OldOwnerIsolationTests.test_never_granted_old_holder`<br>fixture method L390 | `old_owner_never_granted_holder` | O:672 | green / 1 / 0 | ASSERT named |
| G271 / #604 | `OldOwnerIsolationTests.test_history_all_roles_zero`<br>fixture method L558 | `old_owner_history_positive` | O:1369 | green / 1 / 0 | ASSERT named |
| G272 / #604 | `OldOwnerIsolationTests.test_history_standard_revoke_only`<br>fixture method L539 | `old_owner_history_positive` | O:1369 | green / 1 / 0 | ASSERT named |
| G273 / #604 | `OldOwnerIsolationTests.test_proxy_runtime_length`<br>fixture method L1211 | `old_owner_runtime_length` | O:1098 | green / 1 / 0 | ASSERT named |
| G274 / #604 | `OldOwnerIsolationTests.test_proxy_runtime_parity`<br>fixture method L1214 | `old_owner_runtime_parity` | O:1121 | green / 1 / 0 | ASSERT named |
| G275 / #604 | `OldOwnerIsolationTests.test_role_write_key`<br>fixture method L1036 | `old_owner_role_write_key` | O:278 | green / 1 / 0 | ASSERT named |
| G276 / #604 | `OldOwnerIsolationTests.test_role_assembly`<br>fixture method L1071 | `old_owner_role_assembly` | O:209 | green / 1 / 0 | ASSERT named |
| G277 / #604 | `OldOwnerIsolationTests.test_role_lowlevel_call`<br>fixture method L1097 | `old_owner_role_lowlevel_call` | O:210 | green / 1 / 0 | ASSERT named |
| G278 / #604 | `OldOwnerIsolationTests.test_registry_source_commit`<br>fixture method L1105 | `old_owner_registry_source_commit` | O:904 | green / 1 / 0 | ASSERT named |
| G279 / #604 | `OldOwnerIsolationTests.test_role_write_sites`<br>fixture method L1018 | `old_owner_role_write_sites` | O:257 | green / 1 / 0 | ASSERT named |
| G280 / #604 | `OldOwnerIsolationTests.test_role_initializer_only`<br>fixture method L1108 | `old_owner_role_initializer_only` | O:291 | green / 1 / 0 | ASSERT named |
| G281 / #604 | `OldOwnerIsolationTests.test_role_init_ids`<br>fixture method L1133 | `old_owner_role_init_ids` | O:344 | green / 1 / 0 | ASSERT named |
| G282 / #604 | `OldOwnerIsolationTests.test_role_init_standard`<br>fixture method L1153 | `old_owner_role_init_standard` | O:497 | green / 1 / 0 | ASSERT named |
| G283 / #604 | `OldOwnerIsolationTests.test_role_configure_emit`<br>fixture method L1126 | `old_owner_role_configure_emit` | O:412 | green / 1 / 0 | ASSERT named |
| G284 / #604 | `OldOwnerIsolationTests.test_role_config_control`<br>fixture method L1001 | `old_owner_role_config_control` | O:760 | green / 1 / 0 | ASSERT named |
| G285 / #604 | `OldOwnerIsolationTests.test_xpnts_deployment_count`<br>fixture method L615 | `old_owner_xpnts_deployment_count` | O:1406 | green / 1 / 0 | ASSERT named |
| G286 / #604 | `OldOwnerIsolationTests.test_xpnts_deployment_log`<br>fixture method L621 | `old_owner_xpnts_deployment_log` | O:1422 | green / 1 / 0 | ASSERT named |
| G287 / #604 | `OldOwnerIsolationTests.test_xpnts_owner_pin`<br>fixture method L601 | `old_owner_xpnts_owner_pin` | O:806 | green / 1 / 0 | ASSERT named |
| G288 / #604 | `BaselineGateTests.test_build_C12_constructor_abi`<br>fixture method L636 | `C12_constructor_abi` | M:2353 | green / 1 / 0 | ASSERT named |
| G289 / #604 | `BaselineGateTests.test_build_C14_constructor_abi`<br>fixture method L639 | `C14_constructor_abi` | M:2354 | green / 1 / 0 | ASSERT named |
| G290 / #604 | `BaselineGateTests.test_build_C_baseline_commit_F1TestToken`<br>fixture method L642 | `C_baseline_commit_F1TestToken` | M:2356 | green / 1 / 0 | ASSERT named |
| G291 / #604 | `SnapshotControlTests.test_control_must_fire_named_gate`<br>fixture method L924 | `X_gate` | M:3110 | green / 1 / 0 | ASSERT named |
| G292 / #604 | `SnapshotControlTests.test_control_must_fire_named_gate`<br>fixture method L924 | `X_restore` | M:3112 | green / 1 / 0 | ASSERT named |
| G293 / #604 | `SnapshotControlTests.test_control_slot_readback`<br>fixture method L940 | `C_control_slot` | M:3143 | green / 1 / 0 | ASSERT named |
| G294 / #604 | `SnapshotControlTests.test_control_slot_readback`<br>fixture method L940 | `C_control_layout_cachedPrice` | M:3091 | green / 1 / 0 | ASSERT named |
| G295 / #604 | `DeltaTests.test_old_timelock_delta_address`<br>fixture method L292 | `old_timelock_delta_address` | M:1097 | green / 1 / 0 | ASSERT named |
| G296 / #604 | `DeltaTests.test_old_timelock_delta_removed`<br>fixture method L292 | `old_timelock_delta_removed` | M:1098 | green / 1 / 0 | ASSERT named |
| G297 / #604 | `DeltaTests.test_old_timelock_delta_topics`<br>fixture method L292 | `old_timelock_delta_topics` | M:1102 | green / 1 / 0 | ASSERT named |
| G298 / #604 | `DeltaTests.test_old_timelock_delta_range`<br>fixture method L292 | `old_timelock_delta_range` | M:1106 | green / 1 / 0 | ASSERT named |
| G299 / #604 | `DeltaTests.test_old_timelock_delta_canonical`<br>fixture method L292 | `old_timelock_delta_canonical` | M:1109 | green / 1 / 0 | ASSERT named |
| G300 / #604 | `DeltaTests.test_old_timelock_delta_number`<br>fixture method L292 | `old_timelock_delta_number` | M:1110 | green / 1 / 0 | ASSERT named |
| G301 / #604 | `DeltaTests.test_old_timelock_delta_allowance`<br>fixture method L292 | `old_timelock_delta_allowance` | M:1119 | green / 1 / 0 | ASSERT named |
| G302 / #604 | `DeltaTests.test_old_timelock_delta_config_owner`<br>fixture method L292 | `old_timelock_delta_config_owner` | M:1130 | green / 1 / 0 | ASSERT named |
| G303 / #604 | `DeltaTests.test_old_timelock_delta_timelock_role`<br>fixture method L292 | `old_timelock_delta_timelock_role` | M:1132 | green / 1 / 0 | ASSERT named |
| G304 / #604 | `DeltaTests.test_old_timelock_delta_old_role`<br>fixture method L292 | `old_timelock_delta_old_role` | M:1133 | green / 1 / 0 | ASSERT named |
| G305 / #604 | `DeltaTests.test_old_timelock_delta_targets`<br>fixture method L292 | `old_timelock_delta_targets` | M:1136 | green / 1 / 0 | ASSERT named |
| G306 / #604 | `DeltaTests.test_old_timelock_delta_xpnts`<br>fixture method L292 | `old_timelock_delta_xpnts` | M:1137 | green / 1 / 0 | ASSERT named |
| G307 / #604 | `F05ExecuteB4Gates.test_B4_timestamp`<br>fixture method L4521 | `B4_timestamp` | M:2743 | green / 1 / 0 | ASSERT named |
| G308 / #604 | `DiscoveryTests.test_discovery_step_table`<br>fixture method L4888 | `discovery_step_table` | M:946 | green / 1 / 0 | ASSERT named |
| G309 / #604 | `DiscoveryTests.test_discovery_unlisted_effect`<br>fixture method L4892 | `discovery_unlisted_effect` | M:964 | green / 1 / 0 | ASSERT named |
| G310 / #604 | `DiscoveryTests.test_discovery_factory_prediction`<br>fixture method L4898 | `discovery_factory_prediction` | M:966 | green / 1 / 0 | ASSERT named |
| G311 / #604 | `DiscoveryTests.test_discovery_factory_argument`<br>fixture method L4902 | `discovery_factory_argument` | M:970 | green / 1 / 0 | ASSERT named |
| G312 / #604 | `DiscoveryTests.test_discovery_token_prediction`<br>fixture method L4907 | `discovery_token_prediction` | M:974 | green / 1 / 0 | ASSERT named |
| G313 / #604 | `DiscoveryTests.test_discovery_operator_argument`<br>fixture method L4911 | `discovery_operator_argument` | M:979 | green / 1 / 0 | ASSERT named |
| G314 / #604 | `DiscoveryTests.test_discovery_old_authority`<br>fixture method L4915 | `discovery_old_authority` | M:1053 | green / 1 / 0 | ASSERT named |
| G315 / #604 | `DiscoveryTests.test_old_timelock_inventory_pinned_history`<br>fixture method L4877 | `old_timelock_inventory_pinned_history` | M:1078 | green / 1 / 0 | ASSERT named |
| G316 / #604 | `DiscoveryTests.test_old_owner_original_factory_enumeration`<br>fixture method L4970 | `old_owner_original_factory_enumeration` | M:1035 | green / 1 / 0 | ASSERT named |
| G317 / #604 | `DiscoveryTests.test_old_owner_release_factory_enumeration`<br>fixture method L4980 | `old_owner_release_factory_enumeration` | M:1036 | green / 1 / 0 | ASSERT named |
| G318 / #604 | `ManifestTests.test_old_timelock_required`<br>fixture method L2016 | `old_timelock_required` | M:895 | green / 0 / 1 | HAS-ERROR |

#### Known 16 and additional findings

The comparison set is the 14-row “Corrected COMMIT 5 classification findings” table retained in `31a4d578:script/upgrade/COMMIT6_RESULTS.md`, plus the cachedPrice-layout and legacy-Timelock-target findings recorded in 6c above. The first two of the 14 are #599 gas probes and are outside this run. The remaining 14 known findings map to the #601/#604 rows here. Their earlier defective inputs are historical; the table classifies the repaired inputs actually present at HEAD.

| Known finding | HEAD provenance row(s) |
|---|---|
| `test_gas_evidence_missing` | #599; outside G, not rerun |
| `test_remote_estimate_context` | #599; outside G, not rerun |
| `test_build_phase_c_runtime_keys` | G119 ASSERT named |
| `test_build_phase_c_arms` | G125 ASSERT named |
| `test_build_phase_c_owner_preparation` | G128 ASSERT named |
| `test_build_phase_c_maintenance_fields` | G130 ASSERT named |
| `test_build_stage_inputs` | G133 ASSERT named |
| `test_build_stage_pin_phase_c` | G136 ASSERT named |
| `test_build_C_pricing_nonzero` | G143 ASSERT named |
| `test_xpnts_deployment_count` | G285 ASSERT named |
| `old_owner_record_receipt` | G043 ASSERT named |
| `old_owner_record_required` | G045 ASSERT named |
| `old_owner_immutable_ast` | G064 ASSERT named |
| `old_owner_immutable_values` | G068 ASSERT named |
| `C_control_layout_cachedPrice` | G294 ASSERT named |
| `old_owner_source_targets` | G261 ASSERT named |

| Additional uncertified HEAD probe | Finding |
|---|---|
| G037 `OldOwnerIsolationTests.test_unexpected_indirection_and_gate_removals[2]` / `unexpected_proxy` | ASSERT-UNNAMED: Beacon-slot variant: deleting O:1152 still reaches the beacon-specific `unexpected_proxy` at O:1154. Test stays green (F=0/E=0). Name-wide suppression hid the redundant source site. |
| G092 `OldOwnerIsolationTests.test_recursive_manifest_abi_controls[1]` / `old_owner_calldata_bytes` | ASSERT-UNNAMED: Deleting the outer transaction check O:1573 still reaches the recursive payload check O:1541 with the same gate. Test stays green (F=0/E=0). Name-wide suppression is not single-site evidence. |
| G318 `ManifestTests.test_old_timelock_required` / `old_timelock_required` | HAS-ERROR: Already identified in F, additional to the known 16: the HEAD helper converts a missing oldTimelock KeyError into a named FAIL. Gate-only helper rerun: green baseline, one site, F=0/E=1; rejected. |

These rejected rows are not accepted as strict deletion evidence. G is the complete provenance inventory, not certification of these controls or a release gate. No production gates or fallbacks were changed.

#### Foreground verification and verbatim final lines

Each invocation used `python3 -u script/upgrade/audit_probe_provenance.py --origin ORIGIN --family FAMILY --output /tmp/6d-g-NAME.json`, with stdout/stderr redirected to the matching `.log`. The required-field confirmation additionally passes `--gate-only-wrapper`. Exit status was zero for completed classification, **not** a PASS assertion for rejected probes. The initial ManifestTests summary’s named count includes the subsequently rejected exception conversion; only 30 of those 31 literal results are strict evidence. The first combined small-family summary includes the 11 rejected harness errors; its 19 successful controls are retained, and the following class-fixture rerun replaces only those 11 rows.

```text
COMMIT6D_G_AUDIT origin=601 family=OldOwnerIsolationTests rows=113 named=111 has_error=0 unnamed=2
COMMIT6D_G_AUDIT origin=604 family=PhaseCTests rows=54 named=54 has_error=0 unnamed=0
COMMIT6D_G_AUDIT origin=604 family=LiveGateTests rows=63 named=63 has_error=0 unnamed=0
COMMIT6D_G_AUDIT origin=604 family=ManifestTests rows=31 named=31 has_error=0 unnamed=0
COMMIT6D_G_AUDIT origin=604 family=OldOwnerIsolationTests rows=27 named=27 has_error=0 unnamed=0
COMMIT6D_G_AUDIT origin=604 family=BaselineGateTests,SnapshotControlTests,F05ExecuteB4Gates,DeltaTests,DiscoveryTests rows=30 named=19 has_error=11 unnamed=0
COMMIT6D_G_AUDIT origin=604 family=F05ExecuteB4Gates,DiscoveryTests rows=11 named=11 has_error=0 unnamed=0
COMMIT6D_G_AUDIT origin=604 family=ManifestTests.test_old_timelock_required rows=1 named=0 has_error=1 unnamed=0
```

**Done:** G, with every HEAD row classified and additional defects explicitly listed. **Undone:** D’s remaining 20 behavioural replacements, certification of `old_timelock_required`, and the two additional single-site probe defects listed above. Overall 6d acceptance remains withheld; completed 0, A, A-fix, B, C, E, F and H are preserved. No full probe-driver batch, commit, staging, or production mutation was performed. All audit commands completed; no audit background process was left running.

Final runner checks repeated only the two additional #601 controls (four variants) and the literal HEAD timelock conversion control. The four results match the table; the final auditor rejects the converted error even when literal unittest reports F=1/E=0. Verbatim final lines:

```text
COMMIT6D_G_AUDIT origin=601 family=OldOwnerIsolationTests.test_unexpected_indirection_and_gate_removals,OldOwnerIsolationTests.test_recursive_manifest_abi_controls rows=4 named=2 has_error=0 unnamed=2
COMMIT6D_G_AUDIT origin=604 family=ManifestTests.test_old_timelock_required rows=1 named=0 has_error=1 unnamed=0
COMMIT6D_G_INVENTORY PASS users=27 variants=113 cases=205 rows=318 named=315 has_error=1 unnamed=2
COMMIT6D_G_VERIFY PASS rows=318 strict=315 rejected=3 fixture_users=27 phase_cases=205
```

`git diff --check` passed (exit 0, no output).

Final artifact reconciliation, verbatim final line:

```text
COMMIT6D_G_ARTIFACTS PASS table_rows=318 source_hash=matched
```


### #17 — `old_timelock_required` (G318)

Only `ManifestTests.test_old_timelock_required` was changed in this continuation.
Its test-local `UndeclaredTimelock` dictionary reports `oldTimelock` absent to
membership checks while retaining the valid replay evidence for ordinary lookup.
This deliberately synthetic mapping isolates the membership guard; it is not a
claim that a JSON dictionary can omit a key and still index it. With the one gate
statement deleted, `build_plan` returns normally and the unchanged Gate-only
`assert_stop` fails with `old_timelock_required: Gate not raised`. No production
code, missing-key default, gate, or assertion helper was changed.

The requested provenance command was run in the foreground:
`python3 -u script/upgrade/audit_probe_provenance.py --origin 604 --family ManifestTests.test_old_timelock_required --gate-only-wrapper --output /tmp/6d-17-provenance.json`.
It deliberately loads HEAD `171807d9`, including the old test, rather than the
reviewed uncommitted diff. Its rejected historical result is retained verbatim;
exit 0 means classification completed, not certification:

```text
ManifestTests.test_old_timelock_required gate=old_timelock_required sites=1 baseline=green failures=0 errors=1 HAS-ERROR
COMMIT6D_G_AUDIT origin=604 family=ManifestTests.test_old_timelock_required rows=1 named=0 has_error=1 unnamed=0
```

For working-tree verification, imported `probe_phase_c_gates`, selected exactly
`(ManifestTests, 'test_old_timelock_required', 'old_timelock_required')` from
`CASES`, ran `run(cls, name)` and then `run(cls, name, gate)`, and asserted a green
baseline, exactly one recorded source site, and the driver's strict-red result.
The driver deletes one AST statement in memory and requires failures >= 1,
errors == 0, and a FAIL assertion naming the gate. Its full batch/main was not
invoked. Verbatim mutant assertion and final lines from `/tmp/6d-17-phase-c.log`:

```text
AssertionError: old_timelock_required: Gate not raised
Ran 1 test in 2.035s

FAILED (failures=1)
COMMIT6D_17_PHASE_C PASS cases=1 sites=1 baseline=green failures=1 errors=0 named=old_timelock_required
```

The first suite launch from `script/upgrade` resolved an older Python lacking
`tomllib`; this was a rejected runner error, not test evidence. Verbatim final
lines in `/tmp/6d-17-manifest.log`:

```text
Ran 1 test in 0.000s

FAILED (errors=1)
```


Reran the full `ManifestTests` class from the worktree root with Python 3.11.9,
adding `script/upgrade` to `sys.path` and using
`unittest.defaultTestLoader.loadTestsFromTestCase(t.ManifestTests)` with
`TextTestRunner`. Exit 0; verbatim final lines from
`/tmp/6d-17-manifest-final.log`:

```text
Ran 177 tests in 278.600s

OK
COMMIT6D_17_MANIFEST PASS tests=177 failures=0 errors=0 skipped=0
```

**#17 working-tree fixture repair verified:** one source site, green baseline,
F=1/E=0, named FAIL after normal return. Historical G318 remains rejected for
HEAD; this entry does not rewrite that provenance. Overall 6d acceptance remains
withheld for the other outstanding items. `git diff --check` passed (exit 0,
no output). All launched processes exited; no background process remains from
this continuation. No full probe-driver batch, RPC, environment-file, keystore,
or chain access, staging, or commit was performed.

### DSR continuation — duplicate-count stop (2026-11-07)

**Stopped under the explicit >15 rule; no duplicate was fixed.** The AST inventory found 47 duplicated literal gate names across the two requested files. Direct `a.need` / `a.Gate` calls alone already contain 35 duplicated names (76 source sites; 41 excess sites). This exceeds 15 under either name-count or excess-site counting. The reviewed uncommitted implementation and tests were preserved.

Inventory includes `a.need`, `a.Gate`, `a.exact_keys`, `a.typed` (explicit gate argument), `reviewed_bytes`, `reviewed_file`, `required`, `pc_address`, `pc_hash`, `pc_integer`, `role_owner`, and `absent`: these raise gates or forward a gate name to a raising helper. Argument positions are respectively 0, 0, 0, 2, 2, 2, 2, 0, 0, 0, 2, 1 (zero-based); explicit `gate=` is also inspected. Repeated runtime executions of one AST call count as one source site. Dynamic expressions and generated suffixes are not counted as literal duplicates here; a complete dynamic-template registry and probe audit remains undone. Control/probe labels and expected gate references are not definitions of that gate.

All literal duplicates found by this inventory (paths relative to `script/upgrade`; working-tree lines):

| Gate name | Source sites |
|---|---|
| `C1_cap_headroom` | `manifest_exec.py:1528`, `manifest_exec.py:2978` |
| `C1_minter` | `manifest_exec.py:1476`, `manifest_exec.py:2977` |
| `C2_operator_role` | `manifest_exec.py:1484`, `manifest_exec.py:2981` |
| `C3_community` | `manifest_exec.py:1485`, `manifest_exec.py:2988` |
| `C5_counterfactual` | `manifest_exec.py:1493`, `manifest_exec.py:2995` |
| `C6_gtoken_balance` | `manifest_exec.py:1542`, `manifest_exec.py:3004` |
| `C7_enduser_active` | `manifest_exec.py:1487`, `manifest_exec.py:2999` |
| `C_account_status` | `manifest_exec.py:1499`, `manifest_exec.py:3002` |
| `C_control_slot` | `manifest_exec.py:3152`, `manifest_exec.py:3196` |
| `C_operator_before` | `manifest_exec.py:2985`, `manifest_exec.py:2993` |
| `C_price_bound` | `manifest_exec.py:1481`, `manifest_exec.py:2946` |
| `a3a_gap_mined_before_pin` | `manifest_exec.py:1882`, `manifest_exec.py:1904` |
| `a3a_plan` | `manifest_exec.py:633`, `manifest_exec.py:1814`, `manifest_exec.py:1837` |
| `built_aggregator_version` | `manifest_exec.py:707`, `manifest_exec.py:741` |
| `evidence_scope_recomputed` | `manifest_exec.py:244`, `manifest_exec.py:698` |
| `evidence_slither_rederived` | `manifest_exec.py:257`, `manifest_exec.py:258`, `manifest_exec.py:262`, `manifest_exec.py:265`, `manifest_exec.py:266`, `manifest_exec.py:268`, `manifest_exec.py:273`, `manifest_exec.py:276`, `manifest_exec.py:277` |
| `evidence_unique_findings` | `manifest_exec.py:226`, `manifest_exec.py:253` |
| `fixed_old_aggregator` | `manifest_exec.py:1928`, `manifest_exec.py:2129` |
| `fraud_token_fields` | `manifest_exec.py:473`, `manifest_exec.py:481` |
| `manifest_local_only` | `manifest_exec.py:3220`, `manifest_exec.py:3413` |
| `old_owner_calldata_bytes` | `old_owner_isolation.py:1560`, `old_owner_isolation.py:1592` |
| `old_owner_deployed_build` | `old_owner_isolation.py:933`, `old_owner_isolation.py:934` |
| `old_owner_evidence_present` | `old_owner_isolation.py:886`, `old_owner_isolation.py:1227` |
| `old_owner_factory_enumeration` | `old_owner_isolation.py:805`, `old_owner_isolation.py:957` |
| `old_timelock_approval_history` | `manifest_exec.py:1179`, `manifest_exec.py:1185` |
| `old_timelock_replay` | `manifest_exec.py:913`, `manifest_exec.py:919` |
| `phase_c_account_evidence` | `manifest_exec.py:1389`, `manifest_exec.py:1390` |
| `phase_c_measurement` | `manifest_exec.py:1403`, `manifest_exec.py:1406`, `manifest_exec.py:1412` |
| `phase_c_rehearsal_evidence` | `manifest_exec.py:1394`, `manifest_exec.py:1395` |
| `prefix_boundary` | `manifest_exec.py:2089`, `manifest_exec.py:2093` |
| `safe_gap_endpoints` | `manifest_exec.py:1695`, `manifest_exec.py:1770` |
| `safe_gap_gas_price` | `manifest_exec.py:1628`, `manifest_exec.py:1733` |
| `safe_gap_gas_used` | `manifest_exec.py:1627`, `manifest_exec.py:1732` |
| `safe_gap_hash` | `manifest_exec.py:1585`, `manifest_exec.py:1703` |
| `safe_gap_log_data` | `manifest_exec.py:1683`, `manifest_exec.py:1685`, `manifest_exec.py:1690` |
| `safe_gap_log_logIndex` | `manifest_exec.py:1676`, `manifest_exec.py:1678` |
| `safe_gap_miner_balance` | `manifest_exec.py:1633`, `manifest_exec.py:1635`, `manifest_exec.py:1636` |
| `safe_gap_owner_eoa` | `manifest_exec.py:1760`, `manifest_exec.py:1761` |
| `safe_gap_pin_nonce` | `manifest_exec.py:1754`, `manifest_exec.py:1758` |
| `safe_gap_pin_owners` | `manifest_exec.py:1752`, `manifest_exec.py:1756` |
| `safe_gap_pin_threshold` | `manifest_exec.py:1753`, `manifest_exec.py:1757` |
| `safe_gap_receipt_identity` | `manifest_exec.py:1717`, `manifest_exec.py:1726`, `manifest_exec.py:1727` |
| `safe_gap_trace_storage` | `manifest_exec.py:1619`, `manifest_exec.py:1621`, `manifest_exec.py:1622` |
| `stage_not_final` | `manifest_exec.py:3620`, `manifest_exec.py:3634` |
| `stake_not_unlocking` | `manifest_exec.py:1944`, `manifest_exec.py:2149` |
| `unexpected_proxy` | `old_owner_isolation.py:1171`, `old_owner_isolation.py:1173` |
| `verifier_commit` | `manifest_exec.py:91`, `manifest_exec.py:641` |

**Done:** read-only AST inventory and this stop report. **Undone:** #18/#19 renaming and named G037/G092 reruns; permanent uniqueness test, reviewed dynamic-template JSON, label probes and uniqueness deletion probe; C-function extraction and order tests. No affected suite or mutation probe was run because the requested stop threshold was reached before implementation. No ERROR is accepted as evidence and no strict-red result is claimed.

Current order, unchanged: `run_manifest` definition at manifest_exec.py:3412; `validate_plan` call at 3414; inline C reads/checks at 3416–3421; guard entry at 3422. `execution_tree_gates` does not yet exist.

Verbatim final inventory line (foreground AST-only command; no production module imported):

```text
COMMIT6D_DSR_INVENTORY STOP duplicate_names=47 threshold=15 fixed=0
```

No full probe-driver batch, RPC, environment-file, keystore, or chain access; no background process launched; no staging or commit. Overall 6d acceptance remains withheld.

### #17 (redo)

The prior #17 `UndeclaredTimelock` fixture and its certification are rejected and
superseded here. Historical **G318 = HAS-ERROR** above is unchanged.

Removed the dict subclass. `test_old_timelock_required` round-trips the pin
through JSON to a plain dict, then really deletes `oldTimelock`. The sole patched
function is `old_timelock_section`, a strict accessor returning
`pin['oldTimelock']` with no fallback. Its fixed test return value is a copy of the
valid pin fixture's evidence, sourced before the patch; neither the accessor nor
anything it calls computes that substitute. The required gate stays in
`validate_old_timelock`. The validation lookup and both `post_pin_delta` lookups
now share that accessor, preserving their strict missing-key behavior.

The test AST-counts every exact `oldTimelock` string constant throughout
`manifest_exec.py`, conservatively including unknown key-consuming calls as well
as subscripts, `.get`, and membership tests. Only direct Store subscripts are
excluded (writes, not reads). Unique line/column coordinates distinguish repeated
expressions. The asserted set is exactly the required gate and accessor lookup.
New reads fail with `old_timelock_read_sites: patch needs updating`. A separate
control injects each of four read forms into the inspected source and requires
that failure. Deleting the one count assertion makes all four controls fail by
named assertion, without errors. Production source is never mutated by probes.

Focused foreground command (exit 0):
`python3 -u script/upgrade/probe_old_timelock_required.py`.
This calls `probe_phase_c_gates.run(cls, name)` and `run(cls, name, gate)` for
only `ManifestTests.test_old_timelock_required` / `old_timelock_required`, then
runs only the count-assertion deletion control. No full driver batch.

Verbatim gate baseline, mutant and final lines from
`/tmp/6d-17-redo-probes.log`:

```text
Ran 1 test in 12.374s

OK
AssertionError: old_timelock_required: Gate not raised
Ran 1 test in 2.019s

FAILED (failures=1)
OLD_TIMELOCK_REQUIRED PASS sites=1 baseline=green
```

Verbatim count-assertion baseline, mutant and final lines from the same log:

```text
Ran 1 test in 1.950s

OK
AssertionError: AssertionError not raised : old_timelock_read_sites: count assertion not raised
Ran 1 test in 2.143s

FAILED (failures=4)
OLD_TIMELOCK_READ_SITES PASS sites=1 baseline=green failures=4 errors=0
COMMIT6D_17_REDO PASS 2/2 strict deletion probes
```

Both probes meet one source site, green baseline, failures >= 1, errors == 0,
and a FAIL message naming the deleted gate/assertion. The required-gate deletion
allows `build_plan` to return normally (ACCEPTANCE); `assert_stop` remains Gate-only.

Affected suites, foreground (exit 0):
`python3 -u script/upgrade/test_manifest_exec.py ManifestTests DeltaTests -v`.
DeltaTests additionally covers the two lookups consolidated into the accessor.
Verbatim final lines from `/tmp/6d-17-redo-manifest.log`:

```text
----------------------------------------------------------------------
Ran 193 tests in 292.498s

OK
```

**Done:** #17 redo, both strict single-site deletion probes, ManifestTests and
DeltaTests (193 tests, zero failures/errors), and `git diff --check`.
**Undone:** all other outstanding 6d items remain outside this one-item scope;
overall 6d acceptance remains withheld. Historical G318 remains HAS-ERROR.
No commit or staging, RPC/environment-file/keystore/chain access, full probe-driver
batch, production fallback, or weakened gate. All launched commands exited;
no background process was launched or left running.

### B/C order — isolated continuation (2026-11-07)

Extracted the existing C checks unchanged into `execution_tree_gates(plan)`.
No gate names changed. Both git commands retain `cwd=u.ROOT`, `check=True`,
and their exact arguments; HEAD must equal `plan['rebuild']['commit']`, and
status including all untracked files must be empty. `assert_stop` remains
restricted to `a.Gate`.

Final source locations in `manifest_exec.py`: helper definition **3416**;
within `run_manifest`, `validate_plan` **3427**, `execution_tree_gates` **3429**,
and `with execution_reads.guard(allowlist)` **3430**.

Added two tests: calling the real helper inside the real guard STOPs at
`execution_repo_read`; call recording confirms the real helper completes before
real guard entry and the staged runner reaches PASS. The inside-guard test also
joins the focused B deletion probe. Its target is a real clean temporary git
repository: deleting the read barrier permits both git commands and helper
acceptance, without an unprogrammed fake. Existing C tests and probes are retained.

Foreground affected B/C suites (exit 0):
`python3 -u -m unittest discover -s script/upgrade -p 'test_execution_*.py' -v`.
Verbatim final lines from `/tmp/6d-bc-order-tests.log`:

```text
----------------------------------------------------------------------
Ran 16 tests in 0.909s

OK
```

Focused foreground probes (each exit 0),
`python3 -u script/upgrade/probe_execution_head.py` and
`python3 -u script/upgrade/probe_execution_reads.py`.
Verbatim output from `/tmp/6d-bc-order-c-probes.log` and
`/tmp/6d-bc-order-b-probe.log`:

```text
execution_head: sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: execution_head: Gate not raised
execution_clean_tree: sites=1 baseline=green failures=1 errors=0 ASSERT named
AssertionError: execution_clean_tree: Gate not raised
COMMIT6D_C_PROBES PASS 2/2 strict red
execution_repo_read: sites=1 baseline=green failures=14 errors=0 ASSERT named
AssertionError: execution_repo_read: Gate not raised
COMMIT6D_B_PROBE PASS 1/1 strict red
```

Each deletion has one source site, green baseline, failures >= 1, errors == 0,
and an assertion failure message naming the deleted gate. C deletions still
reach runner ACCEPTANCE. No ERROR was accepted.

Broader affected suite, foreground (exit 1; **not accepted as green**):
`python3 -u script/upgrade/test_manifest_exec.py`.
Verbatim final lines from `/tmp/6d-bc-order-manifest.log`:

```text
----------------------------------------------------------------------
Ran 535 tests in 414.922s

FAILED (failures=7, skipped=2)
```

All seven failures are in `ExceptionStopTests.test_first_pre_send_exception`
and the six subcases of `test_later_rehearsal_exceptions`. Their rehearsal plan
omits `rebuild.commit`, so the intended injected fault/send is not reached.
To check attribution, `/tmp/6d-bc-order-baseline.py` reconstructs the exact
pre-extraction `run_manifest` in memory by replacing the helper call with its
unchanged body, then reruns only those two tests. No production file is reverted.
Foreground baseline command (exit 1):
`python3 -u /tmp/6d-bc-order-baseline.py`.
Verbatim final lines from `/tmp/6d-bc-order-baseline.log`:

```text
----------------------------------------------------------------------
Ran 2 tests in 0.185s

FAILED (failures=7)
```

The same seven assertion failures reproduce before the extraction; neither run
reports unittest errors. These existing fixtures remain unchanged in this
one-item scope. The broader suite remains failed, not waived or counted green.

**Done:** B/C order extraction; both requested tests; 16 passing B/C tests;
existing C deletion probes and expanded focused B deletion probe meeting the
strict criterion; final call-site line numbers; `git diff --check`.
**Undone:** existing exception-injection fixture failures above and all other
outstanding 6d items. Overall 6d acceptance remains withheld.
No gate names, production fallbacks, or Gate-only assertion semantics changed.
No worktree commit or staging, RPC/environment-file/keystore/chain access, or full
probe-driver batch. All launched commands exited; no background process remains.


### 6e continuation of 6d #18/#19 (2026-11-07)

**Done:** `unexpected_proxy_other` / `unexpected_proxy_beacon` and
`old_owner_calldata_bytes_outer_tx` / `old_owner_calldata_bytes_payload` now have
separate literal source sites. The focused foreground command was
`python3 -u script/upgrade/probe_gate_rename_controls.py` (exit 0).
Each baseline is green; each mutant deletes exactly one source statement and
has failures >= 1, errors == 0, with a failing assertion naming the deleted gate.
The proxy and outer-transaction deletions reach acceptance. The payload helper
unit control uses the actual nested production code object, with its normal
closure and all its guards; deleting its bytes gate reaches the argument gate,
which produces a named wrong-Gate assertion. This is a helper unit control, not
an assertion that a transaction bypasses the earlier outer-transaction gate.
No production gate was suppressed to make a baseline pass.

Verbatim final lines from `/tmp/commit6e-checks/rename_controls.log`:

```text
GATE_RENAME_CONTROL unexpected_proxy_other PASS baseline=green sites=1
GATE_RENAME_CONTROL unexpected_proxy_beacon PASS baseline=green sites=1
GATE_RENAME_CONTROL old_owner_calldata_bytes_outer_tx PASS baseline=green sites=1
GATE_RENAME_CONTROL old_owner_calldata_bytes_payload PASS baseline=green sites=1
GATE_RENAME_CONTROLS PASS 4/4 strict red
```

**Undone:** all other pre-existing 6d acceptance issues remain outside this
one-item rename. Overall 6d acceptance remains withheld.

## 6e

**INCOMPLETE — acceptance withheld. No commit or staging.**

Base HEAD: `2acc71afb62b23e72a5c610522be0e21dc87e119` (clean at entry).
Before editing, the AST inventory re-derived exactly the recorded **47 duplicated
literal names / 107 source sites**, using all twelve specified helpers and their
explicit gate argument positions, including `gate=`. No duplicate-name set
changed. Historical line offsets differ because committed 6d includes the #17
accessor and B/C-order extraction. Rechecking HEAD against the map gives:

```text
COMMIT6E_HEAD_INVENTORY duplicate_names=47 source_sites=107 map_names=47
```

All 107 definition sites now have unique names of the form `OLD_NAME_suffix`.
`gate_rename_map.json` records old name -> `{new, file, function, line}` entries,
including the innermost function for nested gates. The current scan finds 862
literal sites and `duplicate_names=0`. No gate condition, comparison, ordering,
exception type, or `assert_stop` behavior was changed. `assert_stop` still catches
only `a.Gate`.

The rename also updates four production expected-gate references passed through
`phase_c_controls.add()` (manifest_exec.py:3158, 3166, 3174, 3175). These references
must match the execution gates for the negative controls to work. They are not
additional gate definitions and do not change plan fields.

### Strict AST comparison and unresolved requirements

`gate_rename_ast_diff.py BEFORE AFTER` reads every changed Python file under
`script/` from both revisions, parses and compares location-independent ASTs,
prints each allowed change, and rejects anything beyond mapped gate-position
string changes or exact mapped old-name strings in test/probe files. It supports
`HEAD WORKTREE` for this explicitly uncommitted review. It fails closed on added
or deleted Python files; no implicit infrastructure exemption exists.

Foreground command:
`python3 script/upgrade/gate_rename_ast_diff.py HEAD WORKTREE`.
The final result below is **FAIL**, not waived:

```text
GATE_RENAME_AST_DIFF FAIL n_changes=215
```

Three literal-rule conflicts remain pending the user's clarification:

1. Required new checker/test/probe files have no before-AST. Comparing every
   changed `.py` file under strict identity necessarily rejects these additions.
2. Four expected-gate references go through the local `add()` wrapper, which is
   outside the stipulated helper set. The checker reports them as rejected
   changes rather than broadening the helper set silently.
3. Existing test loops share one old expected name across newly distinct gates:
   `approval_history_control` (creation/log), `test_old_timelock_log_replay`
   (reads/owners), `test_slither_raw_rederived_gate` (file/findings),
   `test_factory_enumeration_must_stand_alone` (audit/discovery), and
   `test_list_and_endpoint_controls` (check/collection). `test_log_identity_fields`
   computes the old logIndex name from the field being mutated. Making all those
   expectations exact requires test structure changes, not just replacement of
   existing string literals. No prefix-matching or multi-Gate acceptance was added.

Also pending are raw-source selectors in
`script/evidence/enduser_mapping_probes.py:148` and
`script/evidence/inventory_replay_probes.py:19`, which embed an old name inside a
larger source-code string (not a string equal to an old gate name). The
`audit605_probes.py` paired REQUIRED entries and F05-derived test-method names
need explicit per-site bindings after the test/probe structure ruling. The full
probe batch was not run, and these incomplete references are not certified.

### Stored plan/manifest content

**Yes**, gate names can be stored in plan content. Source evidence:

- `old_owner_isolation.py:613` stores `negativeControl.gate` in a read record;
  `old_owner_isolation.py:882` returns those reads in isolation evidence.
- `manifest_exec.py:1952` stores isolation evidence in `pin['oldOwnerIsolation']`;
  `manifest_exec.py:2173` copies that pin into the plan dictionary.
- `sp_upgrade_exec.py:1180` serializes the entire plan to `plan.json`;
  `manifest_exec.py:3630` serializes staged plans, and :3635 delegates final plans
  to `u.save_plan`.
- `manifest_exec.py:3127` also stores a caught gate in a negative-control result;
  :3558 places controls in the simulation result (separate from the plan).

A recursive scan of tracked JSON files whose filenames contain plan/manifest/stage
found no literal `gate` fields in those existing files. Historical probe reports
and provenance JSON do contain old names; they describe old runs and were not
rewritten. No plan, frozen manifest, deployment, or evidence JSON was changed.
Only the new rename map and dynamic-template registry are JSON changes.

### Uniqueness and dynamic templates

`test_gate_names.py` scans both production modules with the same helper set.
Literal duplicate names fail by `gate_name_uniqueness`; unregistered dynamic
sites fail by `gate_templates`. Registered finite templates must enumerate the
actual containing loop's labels (checked statically, including tuple columns and
module-level constant tuples), with a probe location for every label. Missing,
stale, duplicate, or changed registrations fail. Tests also verify that the AST
checker rejects condition changes and non-gate production strings.

There are **100 dynamic sites**. The registry currently covers **9 finite
template sites / 32 labels**. The remaining **91 sites are unregistered**, so the
full gate-names suite intentionally remains FAIL; this is unfinished work, not
a waiver. Some remaining domains are open-ended, for example `error['gate']`,
role addresses, and recursive schema paths. Whether those may register a domain
plus enumerated reviewed cases rather than an exhaustive label list is pending
user clarification. Other unregistered finite templates also remain undone.

Focused foreground commands (not the full probe batch):

```sh
python3 -u script/upgrade/probe_gate_names.py
python3 -u script/upgrade/probe_gate_templates.py
python3 -u script/upgrade/probe_gate_rename_controls.py
```

Verbatim final focused lines:

```text
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
GATE_TEMPLATE_PROBES PASS 23/23 strict red
```

The uniqueness probe deletes exactly the one explicit FAIL statement, then runs
the seeded duplicate test. Baseline is green; the mutant fails by
`gate_name_uniqueness: duplicate accepted`, with zero errors. No failed baseline,
ERROR, or unprogrammed fake crash is accepted as strict-red evidence.

Operator command for the external run-all.sh (listed only; **outside-repo file
not read or modified**):

```sh
python3 -u /Users/jason/Dev/aastar/sp-wt/auditfix2/script/upgrade/test_gate_names.py
```

This command currently fails on the unregistered templates; do not treat it as
an accepted run-all addition until the remaining work is completed.

### Affected suites — foreground final lines

Logs are under `/tmp/commit6e-checks/`. Each command below ran in the foreground;
all final lines are copied verbatim. FAIL/ERROR results are not accepted.

`python3 -u script/upgrade/test_old_owner_isolation.py` — `old_owner_isolation.log`:

```text
----------------------------------------------------------------------
Ran 143 tests in 41.907s

FAILED (failures=2, skipped=2)
```

`python3 -u script/upgrade/test_manifest_exec.py` — `manifest_exec-final.log`:

```text
----------------------------------------------------------------------
Ran 535 tests in 413.649s

FAILED (failures=8, skipped=2)
```

`python3 -u script/upgrade/test_manifest_phase_c.py` — `manifest_phase_c-final.log`:

```text
----------------------------------------------------------------------
Ran 141 tests in 194.279s

OK
```

`python3 -u script/a3a/test_a3a_exec.py` — `a3a.log`:

```text
----------------------------------------------------------------------
Ran 102 tests in 3.025s

OK
```

`python3 -u script/upgrade/test_sp_upgrade_exec.py` — `sp_upgrade.log`:

```text
----------------------------------------------------------------------
Ran 141 tests in 1.428s

OK
```

`python3 -u script/upgrade/test_authority_checkpoints.py` — `authority_checkpoints.log`:

```text
----------------------------------------------------------------------
Ran 10 tests in 16.595s

OK
```

`python3 -u script/upgrade/test_swallow_exceptions.py` — `swallow.log`:

```text
----------------------------------------------------------------------
Ran 9 tests in 2.675s

OK
```

`python3 -u script/upgrade/test_execution_head.py` — `execution_head.log`:

```text
----------------------------------------------------------------------
Ran 6 tests in 0.863s

OK
```

`python3 -u script/upgrade/test_execution_reads.py` — `execution_reads.log`:

```text
----------------------------------------------------------------------
Ran 10 tests in 0.085s

OK
```

`python3 -u script/upgrade/test_gate_names.py` — `gate_names.log`:

```text
----------------------------------------------------------------------
Ran 6 tests in 0.947s

FAILED (failures=1)
```

The first Phase C run had two errors from the stale production control
references and two expectation failures; that run was rejected. After updating
the references and correcting the literal expectations, its full final rerun is
recorded above. The first manifest run had ten failures; correcting the two
log-data references reduced the focused seven-test rerun to eight failures and
zero errors. The full final manifest rerun above is authoritative. The remaining
failures correspond to the shared/computed expectations described above.

**Done:** re-derived inventory; 47-name/107-site rename and source map; strict AST
checker; literal uniqueness guard and strict deletion probe; registered finite
label controls listed above; four focused #18/#19 probes; plan-storage evidence;
all ten affected suites run; operator command; `git diff --check`.

**Undone:** resolving the AST-rule conflicts; exact shared/computed test
expectations and remaining probe selectors; registration and per-label probes for
all remaining dynamic sites; all-green affected suites; full 6e acceptance.

No RPC, environment-file, keystore, or chain access; no production fallback;
no full probe-driver batch; no outside-repository run-all edit; no commit or
staging. All launched foreground commands exited before handoff; no background
process was launched or left running.


### DSR continuation: dynamic-domain STOP (2026-11-07)

This continuation preserves the entire inherited 6e diff. The historical results above are not new verification. Only this results document was changed during this continuation.

Ruling 4(iii) requires: **“If (iii) exceeds 10 sites, STOP after categorising all 91 sites and report.”** The census below triggers that stop. No acceptance or all-green claim is made. The final suite/probe run and rulings 1–3 implementation are not performed after this stop.

**Method:** read-only AST inventory using the retained gate_sites helper, subtracting the nine exact (file, function, line, expression) registry entries. Categorised every remaining site by inspecting enclosing loops, branches, module constants, helper callers and parameter/data origins. No production module was imported or executed. Finite rows are categorisations, not completed registrations or verified deletion probes. Generic parameter sites remain counted as open obligations, not excluded forwarding references; per-call-site binding may later close some of those domains. The threshold does not depend on that choice: the nine schema-path sites plus M:2691, O:816 and O:845 alone give 12 open sites.

**Forwarding:** a temporary AST census automatically identified direct record reconstruction by the shape a.Gate(record["gate"], record["observed"], record["expected"]) with the same record base and no intervening string operation. Exactly O:908 and O:1650 qualify in these 91 sites. Source inspection confirms both records originate from recorded rangeError. case["gate"] at O:1510 is a control specification and does not qualify. Bare formal parameters do not qualify. This is census evidence only: the permanent scanner still needs the required AST implementation and counter-example/deletion tests.

**Scope:** M = script/upgrade/manifest_exec.py; O = script/upgrade/old_owner_isolation.py. Census remains the requested original 91 sites; future automatic wrapper discovery may add call-site definitions and must report that delta, not silently replace this denominator.

| # | Site / function | Expression | Category | Domain / reason |
|---|---|---|---|---|
| 1 | M:78 / reviewed_bytes | `gate + '_hash'` | iii: open | Caller-provided gate string plus _hash; no closed domain in helper signature; string operation prevents forwarding exclusion. |
| 2 | M:80 / reviewed_bytes | `gate + '_path'` | iii: open | Caller-provided gate string plus _path; no closed domain in helper signature; string operation prevents forwarding exclusion. |
| 3 | M:82 / reviewed_bytes | `gate` | iii: open | Caller-provided gate parameter; no Gate-record origin. Must retain and bind wrapper definitions; not an exclusion. |
| 4 | M:87 / reviewed_file | `gate` | iii: open | Caller-provided gate parameter forwarded to reviewed_bytes; no Gate-record origin; not an exclusion. |
| 5 | M:127 / required | `label` | iii: open | Caller-provided label parameter forwarded to a.need; no Gate-record origin; not an exclusion. |
| 6 | M:132 / evidence_file | `'evidence_' + kind` | i: finite | EVIDENCE_KINDS (six kind labels; validated evidence dispatch). |
| 7 | M:203 / validate_evidence_details | `'evidence_mutation_' + name` | i: finite | Keys of module constant MUTATIONS (seven labels). |
| 8 | M:211 / validate_evidence_details | `'evidence_suite_' + name` | i: finite | Keys of module constant DVT_SUITES (three labels). |
| 9 | M:295 / validate_evidence_details | `'evidence_full_creation_' + name` | i: finite | NAMES; OverIssueFraudProofVerifier excluded by branch. |
| 10 | M:343 / compare_build_evidence | `'reproducible_bytes_' + name` | iii: open | Caller-supplied contracts mapping keys; no fixed key whitelist in compare_build_evidence. |
| 11 | M:345 / compare_build_evidence | `'rebuild_record_' + name` | iii: open | Caller-supplied contracts mapping keys; no fixed key whitelist in compare_build_evidence. |
| 12 | M:347 / compare_build_evidence | `'reproducible_executable_' + name` | iii: open | Caller-supplied contracts mapping keys; no fixed key whitelist in compare_build_evidence. |
| 13 | M:349 / compare_build_evidence | `'reproducible_full_' + name` | iii: open | Caller-supplied contracts mapping keys except verifier; no fixed key whitelist in compare_build_evidence. |
| 14 | M:379 / _fraud_schema | `'fraud_schema_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 15 | M:381 / _fraud_schema | `'fraud_schema_enum_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 16 | M:384 / _fraud_schema | `'fraud_schema_type_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 17 | M:388 / _fraud_schema | `'fraud_schema_required_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 18 | M:389 / _fraud_schema | `'fraud_schema_properties_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 19 | M:394 / _fraud_schema | `'fraud_schema_fields_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 20 | M:398 / _fraud_schema | `'fraud_schema_length_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 21 | M:403 / _fraud_schema | `'fraud_schema_pattern_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 22 | M:405 / _fraud_schema | `'fraud_schema_range_' + path` | iii: open | Recursive schema path: input object keys and array indices appended to path; arbitrary keys/lengths cannot be exhaustively enumerated. |
| 23 | M:439 / fraud_fixture | `'fraud_' + n['id'] + '_guardians'` | i: finite | Schema mustReject IDs N1..N4; branch excludes N1. |
| 24 | M:441 / fraud_fixture | `'fraud_' + n['id'] + '_proof'` | i: finite | Schema mustReject IDs N1..N4; branch excludes N3. |
| 25 | M:460 / fraud_fixture | `'fraud_uint_' + key` | i: finite | pid, fraudProofId, signerMask. |
| 26 | M:494 / fraud_fixture | `'fraud_token_zero_owner_' + str(offset)` | i: finite | 130, 210, converted to strings. |
| 27 | M:536 / fraud_rehearsal | `'fraud_runtime_' + sid` | i: finite | A7, A12a (tuple first column). |
| 28 | M:592 / fraud_rehearsal | `'fraud_revert_' + name` | i: finite | N1, N2, N3 (valid handled separately; N4 has a separate branch). |
| 29 | M:640 / validate_external | `'verifier_' + key` | i: finite | ciSha256, buildSha256. |
| 30 | M:644 / validate_external | `'canonical_' + key` | i: finite | anni, dvt, committee. |
| 31 | M:645 / validate_external | `'nonzero_' + key` | i: finite | anni, dvt, committee. |
| 32 | M:659 / validate_external | `'pop_unique_' + key` | i: finite | validator, slot. |
| 33 | M:1330 / rebuild_baselines | `'baseline_immutables_' + name` | i: finite | F1TestToken, F1Oracle. |
| 34 | M:1336 / rebuild_baselines | `'baseline_source_' + name` | i: finite | BASELINE_ARTIFACTS keys: VerifyingPaymaster, TokenPaymaster. |
| 35 | M:1338 / rebuild_baselines | `'baseline_constructor_count_' + name` | i: finite | BASELINE_ARTIFACTS keys: VerifyingPaymaster, TokenPaymaster. |
| 36 | M:1363 / pc_address | `gate` | iii: open | Caller-provided gate parameter; no Gate-record origin. Must retain and bind wrapper definitions; not an exclusion. |
| 37 | M:1369 / pc_hash | `gate` | iii: open | Caller-provided gate parameter; no Gate-record origin. Must retain and bind wrapper definitions; not an exclusion. |
| 38 | M:1375 / pc_integer | `gate` | iii: open | Caller-provided gate parameter; no Gate-record origin. Must retain and bind wrapper definitions; not an exclusion. |
| 39 | M:1438 / collect_phase_c | `'phase_c_pending_nonce_' + label` | i: finite | owner, bundler, verifyingSigner. |
| 40 | M:1710 / check_governance | `'safe_gap_' + field` | i: finite | from, to, nonce, gas, maxFeePerGas, maxPriorityFeePerGas, value, chainId. |
| 41 | M:1824 / nonce_expectations | `'a3a_last_' + label` | i: finite | deployer, approver, executor. |
| 42 | M:1831 / nonce_expectations | `'prepin_nonce_' + label` | i: finite | deployer, approver, executor. |
| 43 | M:1832 / nonce_expectations | `'prepin_nonce_floor_' + label` | i: finite | deployer, approver, executor. |
| 44 | M:1848 / history_steps | `'a3a_nonce_complete_' + label` | i: finite | deployer, approver, executor. |
| 45 | M:1873 / validate_nonce_history | `'a3a_mined_' + step['id']` | i: finite | a.STEP_IDS: S1,S2,S3,S4,S5a,S5b,S6a,S6b,S7; history_steps validates IDs. |
| 46 | M:1876 / validate_nonce_history | `'a3a_status_' + step['id']` | i: finite | a.STEP_IDS: S1,S2,S3,S4,S5a,S5b,S6a,S6b,S7; history_steps validates IDs. |
| 47 | M:1899 / reconcile_nonces | `'a3a_mined_' + step['id']` | i: finite | a.STEP_IDS: S1,S2,S3,S4,S5a,S5b,S6a,S6b,S7; history_steps validates IDs. |
| 48 | M:1993 / runtime_bytes | `'immutable_supplied_' + entry['name']` | iii: open | Artifact runtimeIdentity range names supplied to runtime_bytes; names originate in build metadata, not a closed literal loop. |
| 49 | M:2148 / build_plan | `'sender_fields_' + label` | i: finite | deployer, anni, approver, executor; preceding sender_labels validates keys. |
| 50 | M:2155 / build_plan | `'sender_' + label` | i: finite | a.SENDERS keys: deployer, approver, executor. |
| 51 | M:2211 / deploy | `'nonempty_runtime_' + name` | i: finite | Literal deploy call names: SuperPaymaster, GlobalTierSource, AOAProtocolRegistry, xPNTsTokenV2Ext, xPNTsTokenV2, xPNTsFactoryV2, SuperPaymasterLens, Registry, BLSAggregator, OverIssueFraudProofVerifier. |
| 52 | M:2300 / build_plan | `'drain_operator_present_' + label` | i: finite | deployer, anni. |
| 53 | M:2366 / build_plan | `'C_baseline_commit_' + name` | i: finite | F1TestToken, F1Oracle, VerifyingPaymaster, TokenPaymaster. |
| 54 | M:2597 / handover_trace | `'handover_trace_' + key` | i: finite | from, to, input. |
| 55 | M:2661 / handover_controls | `label + '_status'` | i: finite | handover_sp_setProtocolFee; handover_{aggregator,old_aggregator}_{setSlashThreshold,setGuardianSlashBps}; append _status (five). |
| 56 | M:2691 / b2_gate | `'B2_pending_slash_' + who` | iii: open | Addresses from plan.pin.pauseList; runtime inventory, not statically enumerable. |
| 57 | M:2841 / check_predicate | `'readback_' + p.get('signature', kind)` | iii: open | Predicate signature or kind supplied by caller; arbitrary signature strings, not a closed literal loop. |
| 58 | M:2886 / budget | `'budget_' + label` | iii: open | plan.pin.senders keys plus optional owner; budget does not itself bound caller-supplied sender keys. |
| 59 | M:2897 / validate_plan | `'manifest_' + key` | iii: open | Keys of expected plan; caller may supply expected explicitly, so no exhaustive static key set. |
| 60 | M:2910 / validate_plan | `'manifest_step_' + key` | iii: open | Keys of expected step; derived from caller-supplied expected plan, no exhaustive static key set. |
| 61 | M:2913 / validate_plan | `'manifest_tx_' + key` | iii: open | Keys of expected transaction; derived from caller-supplied expected plan, no exhaustive static key set. |
| 62 | M:2920 / validate_plan | `'B4_variant_' + key` | iii: open | Keys of expected variant transaction; derived from caller-supplied expected plan, no exhaustive static key set. |
| 63 | M:2965 / phase_c_state | `'C_sampled_unpaused' if who in sampled else 'C_unsampled_paused'` | i: finite | C_sampled_unpaused, C_unsampled_paused (conditional literal branches). |
| 64 | M:3039 / phase_c_pre_send | `sid + '_recipient_balance'` | i: finite | C19, C20; branch bounds sid. |
| 65 | M:3040 / phase_c_pre_send | `sid + '_recipient_eoa'` | i: finite | C19, C20; branch bounds sid. |
| 66 | M:3104 / layout_slot | `'C_control_layout_' + label` | i: finite | Existing callers: cachedPrice, _auto, _budget (tuple label captured by exhaust). |
| 67 | M:3123 / stop_control | `name + '_gate'` | iii: open | Caller-supplied control name plus _gate; public helper has no bounded name domain; string operation prevents forwarding exclusion. |
| 68 | M:3125 / stop_control | `name + '_restore'` | iii: open | Caller-supplied control name plus _restore; public helper has no bounded name domain; string operation prevents forwarding exclusion. |
| 69 | O:491 / extract | `'old_owner_role_expression_' + label` | iii: open | Solidity AST role declaration labels; build input identifiers are not a fixed Python label tuple. |
| 70 | O:493 / extract | `'old_owner_getter_abi_' + name + '_' + label` | iii: open | Contract name and Solidity AST getter label; names argument/build input identifiers are not a closed domain. |
| 71 | O:494 / extract | `'old_owner_getter_output_' + label` | iii: open | Solidity AST getter label; build input identifiers are not a fixed Python label tuple. |
| 72 | O:525 / extract | `'old_owner_duplicate_source_' + name` | iii: open | Contract names selected by caller-supplied names argument; default NAMES is not the complete accepted domain. |
| 73 | O:530 / extract | `'old_owner_extraction_roles_' + name` | iii: open | Caller-supplied names argument; default NAMES is not the complete accepted domain. |
| 74 | O:648 / audit | `'old_owner_target_' + name` | i: finite | GTokenStaking, GToken, xPNTsFactory, MySBT, PaymasterFactory. |
| 75 | O:665 / role_owner | `gate` | iii: open | Caller-provided gate parameter; no Gate-record origin; retain and bind role_owner wrapper definitions. |
| 76 | O:697 / check_target | `gate` | iii: open | old_owner_role_ + target name + extracted role name; target inventory and build role labels are input-dependent. |
| 77 | O:699 / check_target | `'old_owner_role_admin_' + role['name']` | iii: open | Extracted role name; inventory role declarations are not a closed Python literal set. |
| 78 | O:704 / check_target | `'old_owner_event_role_' + name` | iii: open | Target name from targets plus isolationExtraTargets input keys; extra target names are not statically bounded. |
| 79 | O:712 / check_target | `gate` | iii: open | old_owner_authority_ + target name + authority row name; extracted build identifiers are input-dependent. |
| 80 | O:717 / check_target | `gate` | iii: open | old_owner_mapping_ + target name + mapping row name; extracted build identifiers are input-dependent. |
| 81 | O:733 / audit | `'old_owner_control_' + name` | i: finite | GTokenStaking, GToken, xPNTsFactory, MySBT, PaymasterFactory. |
| 82 | O:785 / audit | `'old_owner_role_' + name + '_' + role` | iii: open | Target name and configured/event role bytes32; runtime role inventory is not statically enumerable. |
| 83 | O:787 / audit | `'old_owner_role_admin_' + role` | iii: open | Configured/event role bytes32; runtime role inventory is not statically enumerable. |
| 84 | O:816 / audit | `'old_owner_operator_treasury_' + who` | iii: open | Address from pin.pauseList; runtime operator inventory is not statically enumerable. |
| 85 | O:845 / audit | `gate` | iii: open | old_owner_allowance_ + token address + holder address; runtime token/holder inventories are not statically enumerable. |
| 86 | O:868 / audit | `'old_owner_safe_' + label` | i: finite | guard, fallback. |
| 87 | O:908 / replay | `error['gate']` | ii: record forwarding | AST: a.Gate(record[gate], record[observed], record[expected]), identical record base, direct subscripts, no string operation. Source assigns record from rangeError. |
| 88 | O:916 / validate | `'old_owner_revalidated_' + endpoint` | i: finite | primary, secondary; preceding old_owner_endpoints bounds keys. |
| 89 | O:1468 / absent | `gate` | iii: open | Caller-provided gate parameter; no Gate-record origin; retain and bind absent wrapper definitions. |
| 90 | O:1510 / fork_probe | `case['gate']` | iii: open | case['gate'] is a caller-provided control specification, NOT a Gate error record; unrestricted string domain, no exclusion. |
| 91 | O:1650 / replay | `error['gate']` | ii: record forwarding | AST: a.Gate(record[gate], record[observed], record[expected]), identical record base, direct subscripts, no string operation. Source assigns record from rangeError. |

**Source fingerprints (SHA-256; retained bytes at this stop):**

- `script/upgrade/manifest_exec.py`: `e03ade0628501e62542b07e87465f36da276a28af7611316665c491668fa45e7`
- `script/upgrade/old_owner_isolation.py`: `2a632c8dc84c85bafa9af3cf2e8c761fde67ddbf37b5a106ff1b7ee25b1c69cb`

**Verbatim final census lines** (foreground offline Python AST/read-only source inspection):

```text
COMMIT6E_DYNAMIC_CENSUS total=100 registered=9 remaining=91 categorized=91
COMMIT6E_DYNAMIC_CATEGORIES finite=41 record_forwarding=2 open=48
COMMIT6E_FORWARDING_EXCLUDED script/upgrade/old_owner_isolation.py:908 script/upgrade/old_owner_isolation.py:1650
COMMIT6E_DYNAMIC_THRESHOLD STOP open_sites_gt_10=true independent_lower_bound=12
COMMIT6E_ACCEPTANCE INCOMPLETE final_suites_not_run=true focused_probes_not_run=true
```

**Remaining work, deliberately not certified:** common-file AST comparison and added-file hashes/line counts; automatic transitive wrapper definitions and duplicate counter-example/probe; exact shared-expectation repairs with before/after subcase/assertion tables and explicit operator-review exclusions; complete template registrations and per-label/per-fixture probes; prefix-disjointness rule and counter-example/deletion probe; raw-source selector replacements and sites=1 checks; audit605 REQUIRED/F05 per-site bindings; every requested final suite and focused strict probe. Existing failing results remain failures, not waived. No ERROR accepted. assert_stop unchanged and still catches only a.Gate.

No RPC, env-file, keystore, chain access, production fallback, commit, staging, full probe-driver batch, or background process. All commands in this continuation finished in the foreground.

### 6e DSR continuation — no stop threshold

This continuation preserves the preceding uncommitted diff on HEAD
`2acc71afb62b23e72a5c610522be0e21dc87e119`. The historical threshold stop above
is superseded for this run. No commit or staging. Acceptance remains withheld
until the final evidence below; a blocked label does not stop other labels.

Ruling 1: compare only common Python files. All added files under `script/` are
reported with path, SHA-256 of actual bytes and line count. Deleted paths are
reported separately. Added infrastructure does not receive a fictitious before AST.

Ruling 2: `gate_name_flow.py` resolves local function names lexically (including
the two unrelated `add` functions), iterates parameter forwarding to a fixed
point, and handles positional and keyword arguments. Forwarded call-site literals
are definitions. Suffixes compose transitively; `reviewed_bytes`/`reviewed_file`
produce the base, `_hash`, and `_path` definitions, and `stop_control`/its nested
`add` produce `_gate` and `_restore` definitions. The two loop-supplied control
names at M:3202 are finite expansions, not R exemptions. Forwarding cycles with
unbounded suffix growth fail closed. Seeded new-wrapper, transitive-wrapper,
lexical-shadow, suffix-collision and AST-rename controls exercise this mechanism.

Expected gate references are tracked separately: a comparison against a variable
assigned from `error.record['gate']` inside `except a.Gate` propagates through
local wrappers. This admits the four Phase C expected-name changes without
counting their references as additional definitions. Direct reconstruction
`a.Gate(record['gate'], record['observed'], record['expected'])` with the same
record base and no string operation excludes precisely O:908 and O:1650.
Counterexamples retain computed record names and control-specification gates.

O:1510 remains R. `audit.role_control` reads
`pin['isolationControlCases'][target+':'+role]` (O:673); `check_target` also reads
caller-provided control cases (O:720). They pass through `probe` (O:609) to
`fork_probe`. Some calls construct dictionaries locally, but the complete domain
is runtime-dependent; it is not a literal case list.

The original 41 finite sites are registered in addition to the existing nine.
Suffix expansion adds two evidence-file sites at M:132 and two finite control
suffixes at M:3202: **54 registered expressions / 210 enumerated labels**.
`gate_finite_domains.json` binds reviewed nontrivial domains to the enclosing
function AST fingerprint; containing literal loops retain the existing static
enumerator. Registry validation rejects stale scope fingerprints, missing labels,
missing probe functions and incorrect expanded probe names. Finite expansions
participate in uniqueness together with literals. This exposed nine shared
`a3a_mined_<sid>` names and the literal/template collision
`safe_gap_log_transactionIndex`. Their new names are respectively
`a3a_mined_history_<sid>`, `a3a_mined_reconcile_<sid>`, and
`safe_gap_log_transactionIndex_typed` (the comparison keeps its name).
Only gate-name strings changed in production.

Ruling 3 allows only the recorded before/after AST fingerprints of the six
specified test functions and the `audit605` REQUIRED assignment. The checker
prints `REVIEWED_STRUCTURE` for each; a further edit invalidates the fingerprint.
These are explicit review boundaries, not a blanket test-file AST exemption.

Counts below count executed negative subcases, not Python loop statements.
An `assert_stop` contributes one exact-name assertion; an explicit subsequent
`assertEqual(record['gate'], expected)` contributes another. The shared `stop`
helper contains both. Successful fixture setup is not a negative subcase.

| Test/helper | Subcases before → after | Exact-name assertions before → after | Exact expectations after |
|---|---:|---:|---|
| `approval_history_control` | 2 → 2 | 2 → 2 | range: `old_timelock_approval_history_creation`; log: `old_timelock_approval_history_log` |
| `test_old_timelock_log_replay` | 4 → 4 | 8 → 8 | omit/mismatch: `old_timelock_replay_reads`; unused: `old_timelock_unused`; owners: `old_timelock_replay_owners` |
| `test_slither_raw_rederived_gate` | 3 → 3 | 6 → 6 | hash: `evidence_slither_rederived_file`; drop/move: `evidence_slither_rederived_findings` |
| `test_factory_enumeration_must_stand_alone` | 4 → 4 | 8 → 8 | each of two lists × audit/discovery: `old_owner_factory_enumeration_audit` / `old_owner_factory_enumeration_discover_targets` |
| `test_list_and_endpoint_controls` | 4 → 4 | 8 → 8 | list: `safe_gap_list`; check: `safe_gap_endpoints_check_governance`; collection: `safe_gap_endpoints_governance_evidence`; swap: `safe_gap_swap_required` |
| `test_log_identity_fields` | 5 → 5 | 10 → 10 | four fields: exact `safe_gap_log_<field>`; logIndex: `safe_gap_log_logIndex_sequence` |

Before-name expectations were the shared old names: `old_timelock_approval_history`,
`old_timelock_replay` (unused already separate), `evidence_slither_rederived`,
`old_owner_factory_enumeration`, `safe_gap_endpoints`, and computed
`safe_gap_log_<field>`. No subcase or exact-name assertion was removed; no prefix
or any-of assertion was introduced. `gate_assertions.assert_stop` is unchanged
and accepts only `a.Gate`.

Raw-source selectors now name the exact discovery and replay-owner gates.
`audit605` has separate REQUIRED bindings for creation/log and reads/owners;
renamed F05 collect/build gates retain their existing `test_stake_not_unlocking`
method bindings. The full audit605/probe-driver batch is not run.

### 6e final results for this continuation

**INCOMPLETE — 193/210 finite-label probes meet the strict criterion; 17 remain blocked. Acceptance is withheld.** All 210 labels have explicit test-file/class/method bindings, and all were attempted. No stop threshold was used. The 36 R sites are separately deferred as requested. No ERROR, failed baseline, surviving mutation, or unnamed assertion was accepted.

The final suite state is eleven green suites and `gate_names` failing solely on the 36 unregistered R sites. The final template-control suite contains 171 tests, all green. Its focused deletion runs pass 74/74 + 67/67 + 30/30. Six additional boundary controls pass, including all five old-owner target labels and the `anni` drain label. The other sixteen strict passes come from existing focused controls.

The initial finite discovery pass was **38/210**, not accepted as completion. Named per-label controls replaced broad `assertRaises` families and subtest loops that produced unnamed failures or secondary errors. Two target fixtures initially produced `KeyError`; these results were rejected. Their final fixtures assert the specific forbidden downstream zero-target read before consulting a sparse response table. Staking/SBT tests supply invalid caller-provided expected targets to exercise the local aggregate guard; the staking fixture models its explicit pre-guard `GTOKEN()` read. No earlier gate is disabled. The fixed PaymasterFactory address is varied only as a test configuration. The `anni` drain fixture rebuilds dependent offline inventory/transcript evidence and runs all revalidation gates.

The receipt-index literal/template collision has its own fifth rename control: malformed receipt `transactionIndex` with matching log fields must raise exactly `safe_gap_log_transactionIndex_typed`. Its deletion must fail by a named assertion.

Reviewed finite domains are also bound to byte fingerprints of their production module, the A3A source and the fraud schema, so changing a global constant or external enumerated domain cannot silently retain a stale registration.

#### Blocked finite labels — precise final baseline failures

These are failed probe candidates, not waivers. With ordinary decoded input values, earlier checks constrain the later predicate. The current run does not bypass those checks to manufacture a green baseline. For sender identities, the recorded candidate first fails nonce-history lookup; the subsequent `u.validate_pin` identity check also precedes the selected manifest identity check. For the deployer drain check, sampled-deployer membership plus exact pause-list/balance-key equality already require that key.

| Source | Deleted gate sought | Earlier failure in final candidate |
|---|---|---|
| M:494 | `fraud_token_zero_owner_130` | `AssertionError: 'fraud_token_pinned_runtime' != 'fraud_token_zero_owner_130' ` |
| M:494 | `fraud_token_zero_owner_210` | `AssertionError: 'fraud_token_pinned_runtime' != 'fraud_token_zero_owner_210' ` |
| M:640 | `verifier_ciSha256` | `AssertionError: 'evidence_dvt-ci_hash' != 'verifier_ciSha256' ` |
| M:640 | `verifier_buildSha256` | `AssertionError: 'verifier_build_identity' != 'verifier_buildSha256' ` |
| M:644 | `canonical_anni` | `AssertionError: 'fixed_anni' != 'canonical_anni' ` |
| M:644 | `canonical_dvt` | `AssertionError: 'fixed_dvt' != 'canonical_dvt' ` |
| M:644 | `canonical_committee` | `AssertionError: 'fixed_committee' != 'canonical_committee' ` |
| M:645 | `nonzero_anni` | `AssertionError: 'fixed_anni' != 'nonzero_anni' ` |
| M:645 | `nonzero_dvt` | `AssertionError: 'fixed_dvt' != 'nonzero_dvt' ` |
| M:645 | `nonzero_committee` | `AssertionError: 'fixed_committee' != 'nonzero_committee' ` |
| M:2148 | `sender_fields_deployer` | `AssertionError: 'sender' != 'sender_fields_deployer' ` |
| M:2148 | `sender_fields_approver` | `AssertionError: 'sender' != 'sender_fields_approver' ` |
| M:2148 | `sender_fields_executor` | `AssertionError: 'sender' != 'sender_fields_executor' ` |
| M:2155 | `sender_deployer` | `AssertionError: 'a3a_sender_history' != 'sender_deployer' ` |
| M:2155 | `sender_approver` | `AssertionError: 'a3a_sender_history' != 'sender_approver' ` |
| M:2155 | `sender_executor` | `AssertionError: 'a3a_sender_history' != 'sender_executor' ` |
| M:2300 | `drain_operator_present_deployer` | `AssertionError: 'drain_inventory' != 'drain_operator_present_deployer' ` |

No gate was removed or weakened to resolve these blockers. The 17 finite probes remain required work; they are **not** part of the deferred R group.

#### Final commands and verbatim suite lines

All commands below are offline foreground Python runs. Logs are in `/tmp/commit6e-rulings/`. The full probe-driver/audit605 batch was not run.

`python3 -B script/upgrade/test_old_owner_isolation.py`

```text
Ran 143 tests in 48.181s
OK (skipped=2)
```

`python3 -B script/upgrade/test_manifest_exec.py`

```text
Ran 535 tests in 484.409s
OK (skipped=2)
```

`python3 -B script/upgrade/test_manifest_phase_c.py`

```text
Ran 141 tests in 233.715s
OK
```

`python3 -B script/a3a/test_a3a_exec.py`

```text
Ran 102 tests in 3.254s
OK
```

`python3 -B script/upgrade/test_sp_upgrade_exec.py`

```text
Ran 141 tests in 1.652s
OK
```

`python3 -B script/upgrade/test_authority_checkpoints.py`

```text
Ran 10 tests in 20.508s
OK
```

`python3 -B script/upgrade/test_swallow_exceptions.py`

```text
Ran 9 tests in 3.075s
OK
```

`python3 -B script/upgrade/test_execution_head.py`

```text
Ran 6 tests in 1.069s
OK
```

`python3 -B script/upgrade/test_execution_reads.py`

```text
Ran 10 tests in 0.107s
OK
```

`python3 -B script/upgrade/test_gate_names.py`

```text
Ran 11 tests in 4.081s
FAILED (failures=1)
```

`python3 -B script/upgrade/test_gate_rename_controls.py`

```text
Ran 5 tests in 5.990s
OK
```

`python3 -B script/upgrade/test_gate_template_controls.py`

```text
Ran 171 tests in 206.906s
OK
```

`python3 -B script/upgrade/gate_rename_ast_diff.py HEAD WORKTREE`

```text
ADDED script/upgrade/gate_finite_domains.json sha256=5ba687d367681ba85c3eaacc4fc5194bfc3dbe996d6e63b322b5f0ac9aeedbde lines=810
ADDED script/upgrade/gate_name_flow.py sha256=2fb53fe0077858160909b9d906e9c25830295ef4a96b0bc046f7343a8e5d34c4 lines=101
ADDED script/upgrade/gate_probe_trace.py sha256=5603c564b6184ac201052710d6a45d106321bc04a27bd29d12ac5f650755b53e lines=23
ADDED script/upgrade/gate_rename_ast_diff.py sha256=875cf684749ef7aa8c31110f6fac53b6b1ca90cedf5a1451a551ae4ea1802edb lines=184
ADDED script/upgrade/gate_rename_map.json sha256=756ac5bdc3c86c550b0dc79f4e1e4efc26fc8a178bcb57bc4701de33328ece89 lines=760
ADDED script/upgrade/gate_rename_structural.json sha256=7d29202ace78827329bc92cbe3df98c24ec2511c23a3d8abc667c87eaac93bb3 lines=65
ADDED script/upgrade/gate_templates.json sha256=c5048a1ebf24f6747f756ce75ef6df82643dbb61214b72865d6e13aef6e4573e lines=2432
ADDED script/upgrade/probe_finite_gate_blockers.py sha256=ce5ba67226409ee9f7facc2ff027858bfa8165d31011073d01f77fc351c06bcb lines=187
ADDED script/upgrade/probe_finite_gate_labels.py sha256=64fd711e96932830e2fe0ac993e94dba37e8f1f65cd8e7af8b143cc5227fc358 lines=116
ADDED script/upgrade/probe_gate_bindings.py sha256=d01bd6a7206cfae8e041d515f9351aefa336f5ccd19c49c10eb460f25e8e4e1c lines=35
ADDED script/upgrade/probe_gate_names.py sha256=2408db76141fa26db0eba9ab0224e0ae200ca622177cdd84191338abf7feb012 lines=74
ADDED script/upgrade/probe_gate_rename_controls.py sha256=2b2f91cb1e89a11d8f3faf85043a9c7801daf239fb4a3092c381be67a5e18639 lines=50
ADDED script/upgrade/probe_gate_templates.py sha256=91f9900598da04f985055887b537744077c93b14ded64f6e67b9f2903b8b55e6 lines=46
ADDED script/upgrade/test_gate_names.py sha256=babeedcfd2d0825df16b7509441ac3bbfac9eeef47122c92ba919946a87e546e lines=215
ADDED script/upgrade/test_gate_rename_controls.py sha256=011881a959082a7473709b6afd5e3937137dfe40db43331b4a8636915212fab6 lines=75
ADDED script/upgrade/test_gate_template_controls.py sha256=2a10e3c11457a0f8a569d91adb66018df328a8304d19b11e68313533fced68f7 lines=646
GATE_RENAME_AST_DIFF PASS n_changes=220
```

#### Verbatim focused probe and binding final lines

Commands: `probe_gate_names.py`, `probe_gate_rename_controls.py`, `probe_gate_bindings.py`, `script/evidence/inventory_replay_probes.py`, `probe_finite_gate_labels.py`, `probe_finite_gate_blockers.py`, and `probe_gate_templates.finite_label_probes()` for the 74 initial, 67 supplemental and 30 final controls. Supplemental calls select only cases not already certified by the previous focused log.

```text
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
GATE_RENAME_CONTROL safe_gap_log_transactionIndex_typed PASS baseline=green sites=1
GATE_RENAME_CONTROL unexpected_proxy_other PASS baseline=green sites=1
GATE_RENAME_CONTROL unexpected_proxy_beacon PASS baseline=green sites=1
GATE_RENAME_CONTROL old_owner_calldata_bytes_outer_tx PASS baseline=green sites=1
GATE_RENAME_CONTROL old_owner_calldata_bytes_payload PASS baseline=green sites=1
GATE_RENAME_CONTROLS PASS 5/5 strict red
GATE_BINDING old_timelock_approval_history_creation PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_BINDING old_timelock_approval_history_log PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_BINDING old_timelock_replay_reads PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_BINDING old_timelock_replay_owners PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_BINDING stake_not_unlocking_collect PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_BINDING stake_not_unlocking_build_plan PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_BINDING old_owner_factory_enumeration_discover_targets PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_BINDING_PROBES PASS 7/7 strict red
inventory_drift: matches=1, baseline OK, mutated FAILED (failures=1)
replay_owners: matches=1, baseline OK, mutated FAILED (failures=1)
replay_unused: matches=1, baseline OK, mutated FAILED (failures=1)
INVENTORY_REPLAY_PROBES PASS
GATE_TEMPLATE_PROBES PASS 74/74 strict red
GATE_TEMPLATE_PROBES PASS 67/67 strict red
GATE_TEMPLATE_PROBES PASS 30/30 strict red
FINITE_BOUNDARY_PROBES FAIL 6/23 strict red
AUDIT605_BINDINGS PASS pairs=94 missing=[]
RAW_SELECTOR inventory_drift sites=1
RAW_SELECTOR replay_owners sites=1
RAW_SELECTOR replay_unused sites=1
FINITE_PROBE_BINDINGS PASS labels=210
RAW_SELECTOR discovery_preswitch_gate sites=1
```

#### Every registered label — verbatim final proof line

For forwarded definitions, `source_sites=1` means one statically selected call site and one recorded failing primitive statement; the recorded production call stack must connect them. The deletion removes that primitive only. Each PASS also requires green baseline, failures ≥ 1, errors = 0, and an assertion message naming the deleted gate. The three template logs contain the complete unittest summaries and assertion messages.

```text
FINITE_LABEL script/upgrade/manifest_exec.py:3080 SP C_funding_entrypoint_SP PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3080 VPM C_funding_entrypoint_VPM PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3080 TPM C_funding_entrypoint_TPM PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3084 bundler C_funding_bundler PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3084 owner C_funding_owner PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3091 user C_funding_user PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3091 feeToken C_funding_feeToken PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3091 taskSender C_funding_taskSender PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3091 taskRecipient C_funding_taskRecipient PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL phase_c_address_bundler PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_address_accountOwner PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_address_verifyingSigner PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_address_account PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_address_accountImplementation PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_runtime_accountFactory PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_runtime_accountImplementation PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_runtime_account PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_runtime_VerifyingPaymaster PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_runtime_TokenPaymaster PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_arm_fields_SP PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_arm_fields_VPM PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_arm_fields_TPM PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_pin_identity_owner PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_pin_identity_bundler PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_pin_identity_verifyingSigner PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_eoa_owner PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_eoa_bundler PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL phase_c_eoa_verifyingSigner PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL safe_gap_log_transactionHash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL safe_gap_log_blockHash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL safe_gap_log_blockNumber PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL safe_gap_log_transactionIndex PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_conformance PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_mutation PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_slither PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_reproducible-build PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_dvt-ci PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_dvt-conformance-4.12 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_conformance_hash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_mutation_hash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_slither_hash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_reproducible-build_hash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_dvt-ci_hash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_dvt-conformance-4.12_hash PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_conformance_path PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_mutation_path PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_slither_path PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_reproducible-build_path PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_dvt-ci_path PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_dvt-conformance-4.12_path PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL evidence_mutation_remove_B2 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_mutation_remove_AGGREGATOR_getter PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_mutation_remove_REGISTRY_getter PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_mutation_remove_bound_runtime_loop PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_mutation_remove_isEqualSet PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_mutation_subset_comparison PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_mutation_length_not_equal_to_less_than PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_suite_CC115CrossRepoConformance PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_suite_CC115GenuinePragueCrossRepo PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_suite_provenance PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_SuperPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_SuperPaymasterAdmin PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_GlobalTierSource PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_AOAProtocolRegistry PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_xPNTsTokenV2Ext PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_xPNTsTokenV2 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_xPNTsFactoryV2 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_SuperPaymasterLens PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_Registry PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL evidence_full_creation_BLSAggregator PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL fraud_N2_guardians PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL fraud_N3_guardians PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL fraud_N4_guardians PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL fraud_N1_proof PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL fraud_N2_proof PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL fraud_N4_proof PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL fraud_uint_pid PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL fraud_uint_fraudProofId PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL fraud_uint_signerMask PASS baseline=green source_sites=1 failures=1 errors=0 named=True
FINITE_BOUNDARY fraud_token_zero_owner_130 BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY fraud_token_zero_owner_210 BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
GATE_TEMPLATE_CONTROL fraud_runtime_A7 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL fraud_runtime_A12a PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL fraud_revert_N1 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL fraud_revert_N2 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL fraud_revert_N3 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
FINITE_BOUNDARY verifier_ciSha256 BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY verifier_buildSha256 BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY canonical_anni BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY canonical_dvt BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY canonical_committee BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY nonzero_anni BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY nonzero_dvt BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY nonzero_committee BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
GATE_TEMPLATE_CONTROL pop_unique_validator PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL pop_unique_slot PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL baseline_immutables_F1TestToken PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL baseline_immutables_F1Oracle PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL baseline_source_VerifyingPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL baseline_source_TokenPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL baseline_constructor_count_VerifyingPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL baseline_constructor_count_TokenPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL phase_c_pending_nonce_owner PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL phase_c_pending_nonce_bundler PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL phase_c_pending_nonce_verifyingSigner PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_from PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_to PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_nonce PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_gas PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_maxFeePerGas PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_maxPriorityFeePerGas PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_value PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL safe_gap_chainId PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL a3a_last_deployer PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL a3a_last_approver PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL a3a_last_executor PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL prepin_nonce_deployer PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL prepin_nonce_approver PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL prepin_nonce_executor PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL prepin_nonce_floor_deployer PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL prepin_nonce_floor_approver PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL prepin_nonce_floor_executor PASS baseline=green source_sites=1 failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:1848 deployer a3a_nonce_complete_deployer PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL a3a_nonce_complete_approver PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL a3a_nonce_complete_executor PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL a3a_mined_history_S1 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S2 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S3 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S4 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S5a PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S5b PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S6a PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S6b PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_history_S7 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S1 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S2 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S3 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S4 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S5a PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S5b PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S6a PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S6b PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_status_S7 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S1 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S2 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S3 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S4 PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S5a PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S5b PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S6a PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S6b PASS baseline=green source_sites=1
GATE_TEMPLATE_CONTROL a3a_mined_reconcile_S7 PASS baseline=green source_sites=1
FINITE_BOUNDARY sender_fields_deployer BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
GATE_TEMPLATE_CONTROL sender_fields_anni PASS baseline=green source_sites=1 failures=1 errors=0 named=True
FINITE_BOUNDARY sender_fields_approver BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY sender_fields_executor BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY sender_deployer BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY sender_approver BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY sender_executor BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
GATE_TEMPLATE_CONTROL nonempty_runtime_SuperPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_GlobalTierSource PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_AOAProtocolRegistry PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_xPNTsTokenV2Ext PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_xPNTsTokenV2 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_xPNTsFactoryV2 PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_SuperPaymasterLens PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_Registry PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_BLSAggregator PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL nonempty_runtime_OverIssueFraudProofVerifier PASS baseline=green source_sites=1 failures=1 errors=0 named=True
FINITE_BOUNDARY drain_operator_present_deployer BLOCKED definitions=1 sites=0 baseline=RED failures=0 errors=0 named=False
FINITE_BOUNDARY drain_operator_present_anni PASS definitions=1 sites=1 baseline=green failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_baseline_commit_F1TestToken PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_baseline_commit_F1Oracle PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_baseline_commit_VerifyingPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_baseline_commit_TokenPaymaster PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_trace_from PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_trace_to PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_trace_input PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_sp_setProtocolFee_status PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_aggregator_setSlashThreshold_status PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_aggregator_setGuardianSlashBps_status PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_old_aggregator_setSlashThreshold_status PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL handover_old_aggregator_setGuardianSlashBps_status PASS baseline=green source_sites=1 failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:2965 C_sampled_unpaused C_sampled_unpaused PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:2965 C_unsampled_paused C_unsampled_paused PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3039 C19 C19_recipient_balance PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3039 C20 C20_recipient_balance PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3040 C19 C19_recipient_eoa PASS sites=1 baseline=green failures=1 errors=0 named=True
FINITE_LABEL script/upgrade/manifest_exec.py:3040 C20 C20_recipient_eoa PASS sites=1 baseline=green failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_control_layout_cachedPrice PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_control_layout__auto PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_control_layout__budget PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_allowance_exhausted_gate PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_total_exhausted_gate PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_allowance_exhausted_restore PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL C_total_exhausted_restore PASS baseline=green source_sites=1 failures=1 errors=0 named=True
FINITE_BOUNDARY old_owner_target_GTokenStaking PASS definitions=1 sites=1 baseline=green failures=1 errors=0 named=True
FINITE_BOUNDARY old_owner_target_GToken PASS definitions=1 sites=1 baseline=green failures=1 errors=0 named=True
FINITE_BOUNDARY old_owner_target_xPNTsFactory PASS definitions=1 sites=1 baseline=green failures=1 errors=0 named=True
FINITE_BOUNDARY old_owner_target_MySBT PASS definitions=1 sites=1 baseline=green failures=1 errors=0 named=True
FINITE_BOUNDARY old_owner_target_PaymasterFactory PASS definitions=1 sites=1 baseline=green failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_control_GTokenStaking PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_control_GToken PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_control_xPNTsFactory PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_control_MySBT PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_control_PaymasterFactory PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_safe_guard PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_safe_fallback PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_revalidated_primary PASS baseline=green source_sites=1 failures=1 errors=0 named=True
GATE_TEMPLATE_CONTROL old_owner_revalidated_secondary PASS baseline=green source_sites=1 failures=1 errors=0 named=True
```

#### Exactly the deferred R sites

M = `script/upgrade/manifest_exec.py`; O = `script/upgrade/old_owner_isolation.py`. The gate-names suite prints these same 36 unregistered sites and no others.

| Site | Function | Expression |
|---|---|---|
| M:343 | `compare_build_evidence` | `'reproducible_bytes_' + name` |
| M:345 | `compare_build_evidence` | `'rebuild_record_' + name` |
| M:347 | `compare_build_evidence` | `'reproducible_executable_' + name` |
| M:349 | `compare_build_evidence` | `'reproducible_full_' + name` |
| M:379 | `_fraud_schema` | `'fraud_schema_' + path` |
| M:381 | `_fraud_schema` | `'fraud_schema_enum_' + path` |
| M:384 | `_fraud_schema` | `'fraud_schema_type_' + path` |
| M:388 | `_fraud_schema` | `'fraud_schema_required_' + path` |
| M:389 | `_fraud_schema` | `'fraud_schema_properties_' + path` |
| M:394 | `_fraud_schema` | `'fraud_schema_fields_' + path` |
| M:398 | `_fraud_schema` | `'fraud_schema_length_' + path` |
| M:403 | `_fraud_schema` | `'fraud_schema_pattern_' + path` |
| M:405 | `_fraud_schema` | `'fraud_schema_range_' + path` |
| M:1993 | `runtime_bytes` | `'immutable_supplied_' + entry['name']` |
| M:2691 | `b2_gate` | `'B2_pending_slash_' + who` |
| M:2841 | `check_predicate` | `'readback_' + p.get('signature', kind)` |
| M:2886 | `budget` | `'budget_' + label` |
| M:2897 | `validate_plan` | `'manifest_' + key` |
| M:2910 | `validate_plan` | `'manifest_step_' + key` |
| M:2913 | `validate_plan` | `'manifest_tx_' + key` |
| M:2920 | `validate_plan` | `'B4_variant_' + key` |
| O:491 | `extract` | `'old_owner_role_expression_' + label` |
| O:493 | `extract` | `'old_owner_getter_abi_' + name + '_' + label` |
| O:494 | `extract` | `'old_owner_getter_output_' + label` |
| O:525 | `extract` | `'old_owner_duplicate_source_' + name` |
| O:530 | `extract` | `'old_owner_extraction_roles_' + name` |
| O:697 | `check_target` | `gate` |
| O:699 | `check_target` | `'old_owner_role_admin_' + role['name']` |
| O:704 | `check_target` | `'old_owner_event_role_' + name` |
| O:712 | `check_target` | `gate` |
| O:717 | `check_target` | `gate` |
| O:785 | `audit` | `'old_owner_role_' + name + '_' + role` |
| O:787 | `audit` | `'old_owner_role_admin_' + role` |
| O:816 | `audit` | `'old_owner_operator_treasury_' + who` |
| O:845 | `audit` | `gate` |
| O:1510 | `fork_probe` | `case['gate']` |

Final production SHA-256 fingerprints:

- `script/upgrade/manifest_exec.py`: `3f3949fbbba242d9802bb2ac92baa526b741b5411918aea50eafdc0601e78d4e`
- `script/upgrade/old_owner_isolation.py`: `2a632c8dc84c85bafa9af3cf2e8c761fde67ddbf37b5a106ff1b7ee25b1c69cb`

`git diff --check` passes. `gate_assertions.py` has no diff; `assert_stop` still catches only `a.Gate`. HEAD is unchanged, index is unchanged, and no commit was made. No RPC, env-file, keystore or chain operations were used. Every launched test/probe process completed in the foreground; no process was left running.

Verbatim final aggregation lines:

```text
COMMIT6E_GATE_INVENTORY definitions=1114 duplicate_names=0 finite_sites=54 finite_labels=210 deferred_R=36
COMMIT6E_FINITE_PROBES FAIL passed=193 total=210 blocked=17 errors_accepted=0
COMMIT6E_ACCEPTANCE INCOMPLETE finite_probe_blockers=17 deferred_R=36 committed=false background_processes=0
```

### 6e R-domain continuation — final DSR classification (2026-11-07)
HEAD remains `2acc71af`. The earlier uncommitted 6e diff is preserved; nothing is committed or staged. This continuation used offline Python tests, local synthetic RPC doubles, local AST/ABI fixtures and local git/cast operations only. No RPC endpoint, env file, keystore, live chain, full probe-driver batch, or background job was used. `gate_assertions.py` is unchanged: `assert_stop` catches only `a.Gate`.

**Classification is complete: 23 of the original 36 candidates moved to (i), leaving 13 R sites.** The final registry contains 77 finite sites / 765 labels. `gate_r_review.json` preserves the original 36-site review input, not the final R list. `gate_open_templates.json` is the authoritative final R registry, including each expression, source site, fixed prefix, open-domain justification, fixture probe and two-label positive test.

| Moved source sites | Constant domain |
|---|---|
| M:343,345,347,349 | `NAMES` plus the verifier, excluding verifier from the full-byte comparison branch |
| M:379,381,384,388,389,394,398,403,405 | Fixed fixture JSON schema, both `fixture` and format-only `export` paths; bounded array indices; enum domain is empty |
| M:1993 | `IMMUTABLES`, including imported EIP-712/SP constants, plus verifier `AGGREGATOR` and baseline `MINTER` |
| M:2841 | Literal predicate-constructor signatures and finite getter tuples; `upgrade` / `activation` dispatch to `batch_readback` and are excluded; batch and handover signatures are included |
| M:2886 | Validated sender keys `deployer`, `anni`, `approver`, `executor`, plus Phase C `owner` |
| M:2897,2910,2913,2920 | `build_plan.finish/add`, timing fields, transaction dictionary and B4 variant dictionary keys |
| O:525,530 | `NAMES ∪ manifest.NAMES`, plus the explicit `GTokenAuthorization` artifact alias |
| O:704 | Audit target names from `NAMES ∪ manifest.NAMES`; post-upgrade extra targets are checked against `manifest.NAMES` |

M = `script/upgrade/manifest_exec.py`; O = `script/upgrade/old_owner_isolation.py`. The finite-domain records bind reviewed scopes and source dependencies by SHA-256. New domain tests also compare registry labels against `gate_r_domains` derivation. The R prefix check compares every R prefix against literal names, expanded finite names, other R prefixes and finite template fixed prefixes, in both prefix directions. Its counterexamples cover a literal collision and both directions of R/R and R/finite collisions.

#### Prefix renames in this continuation

Every production prefix change and the corresponding expected-name references are recorded in `gate_rename_map.json`. Fixed prefixes retain their old prefix wherever possible. Exact generated expected names and the fork caller-name expression need explicit migration; their map entries document why disjointness takes priority. No predicate, comparison value or production fallback was changed.

| Before | After |
|---|---|
| `case['gate']` | `'old_owner_fork_case_' + case['gate']` |
| `manifest_` | `manifest_plan_key_` |
| `manifest_step_` | `manifest_step_key_` |
| `manifest_tx_` | `manifest_tx_field_` |
| `old_owner_allowance_` | `old_owner_allowance_pair_` |
| `old_owner_authority_` | `old_owner_authority_member_` |
| `old_owner_event_role_` | `old_owner_event_role_member_` |
| `old_owner_mapping_` | `old_owner_mapping_member_` |
| `old_owner_role_` | `old_owner_role_member_configured_` |
| `old_owner_role_` | `old_owner_role_member_declared_` |
| `old_owner_role_admin_` | `old_owner_role_admin_configured_` |
| `old_owner_role_admin_` | `old_owner_role_admin_declared_` |
| `readback_` | `readback_value_` |

#### Final R sites

| Site / function | Template expression | Prefix | Fixture gate / final strict result |
|---|---|---|---|
| M:2691 `b2_gate` | `'B2_pending_slash_' + who` | `B2_pending_slash_` | `B2_pending_slash_0x1111111111111111111111111111111111111111` — PASS |
| O:491 `extract` | `'old_owner_role_expression_' + label` | `old_owner_role_expression_` | `old_owner_role_expression_PROPOSER_ROLE` — PASS |
| O:493 `extract` | `'old_owner_getter_abi_' + name + '_' + label` | `old_owner_getter_abi_` | `old_owner_getter_abi_GToken_owner` — BLOCKED |
| O:494 `extract` | `'old_owner_getter_output_' + label` | `old_owner_getter_output_` | `old_owner_getter_output_owner` — PASS |
| O:697 `check_target` | `'old_owner_role_member_declared_' + name + '_' + role['name']` | `old_owner_role_member_declared_` | `old_owner_role_member_declared_TimelockController_PROPOSER_ROLE` — PASS |
| O:699 `check_target` | `'old_owner_role_admin_declared_' + role['name']` | `old_owner_role_admin_declared_` | `old_owner_role_admin_declared_ROLE_COMMUNITY` — PASS |
| O:712 `check_target` | `'old_owner_authority_member_' + name + '_' + row['name']` | `old_owner_authority_member_` | `old_owner_authority_member_SuperPaymaster_pendingOwner` — PASS |
| O:717 `check_target` | `'old_owner_mapping_member_' + name + '_' + row['name']` | `old_owner_mapping_member_` | `old_owner_mapping_member_Registry_authorized` — PASS |
| O:785 `audit` | `'old_owner_role_member_configured_' + name + '_' + role` | `old_owner_role_member_configured_` | `old_owner_role_member_configured_Registry_0x7777777777777777777777777777777777777777777777777777777777777777` — PASS |
| O:787 `audit` | `'old_owner_role_admin_configured_' + role` | `old_owner_role_admin_configured_` | `old_owner_role_admin_configured_0x7777777777777777777777777777777777777777777777777777777777777777` — PASS |
| O:816 `audit` | `'old_owner_operator_treasury_' + who` | `old_owner_operator_treasury_` | `old_owner_operator_treasury_0xb5600060e6de5e11d3636731964218e53caadf0e` — PASS |
| O:845 `audit` | `'old_owner_allowance_pair_' + token + '_' + who` | `old_owner_allowance_pair_` | `old_owner_allowance_pair_0x2222222222222222222222222222222222222222_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf` — PASS |
| O:1510 `fork_probe` | `'old_owner_fork_case_' + case['gate']` | `old_owner_fork_case_` | `old_owner_fork_case_old_owner_event_role_member_TimelockController` — PASS |

#### Remaining strict-probe blockers (all other items continued)

- **19 `fraud_schema_properties_*` labels, M:389:** the checked-in schema contains no positive `minProperties`. The expression is `len(value) >= 0` for every corresponding dict. A valid fixture therefore cannot trip this gate: each baseline fails with the full generated `...: Gate not raised` message. These are finite, unprovable deletion controls, not R and not passing probes.
- **`old_owner_extraction_roles_Registry`, O:530:** removing the Registry role constants reaches `old_owner_role_init_ids` at O:344 through `registry_role_writes` first. The named baseline is red; that earlier security gate was not bypassed.
- **`old_owner_getter_abi_GToken_owner`, O:493 (R):** baseline is green and the site is unique, but deleting it causes `KeyError: 'owner()'` at O:494 (`signatures[sig]['outputs']`). The mutant has zero FAILs and one ERROR. It is rejected, never counted as strict red; no catch-all assertion or production fallback was introduced.
- **Empty finite domain at M:381:** the checked-in schema has no `enum` nodes. It is registered as (i) with a verified empty label set and an explicit unreachable reason. There is no real fixture label for a deletion probe; no invented enum label is counted.
- The **17 finite-label blockers from the previous 6e continuation remain unresolved**. This run does not relabel those prior failures as success.

Initial fixture problems (None causing downstream schema TypeErrors, noncanonical fake balance quantities, stale exact expected names, and shared inventory mutation) were repaired and the affected controls rerun. Final results below select the latest completed result for each currently registered label/site. The first interrupted probe attempts were stopped for fixture correction, not used as evidence, and left no process running. All 568 current new-label/R controls were attempted; 547 passed and 21 are blocked. The focused runner never accepts ERROR.

#### Final suites and verifier — verbatim lines

Logs are in `/tmp/commit6e-r-final/`. Initial manifest, Phase C, authority-checkpoint and execution-read runs found stale expected-name references. The corrected full-suite reruns below supersede those failures; the original logs remain as `*-initial.log`.

`old_owner_isolation`

```text
Ran 143 tests in 41.106s
OK (skipped=2)
```

`manifest_exec`

```text
Ran 535 tests in 431.786s
OK (skipped=2)
```

`manifest_phase_c`

```text
Ran 141 tests in 207.499s
OK
```

`a3a`

```text
Ran 102 tests in 3.132s
OK
```

`sp_upgrade`

```text
Ran 141 tests in 1.461s
OK
```

`authority_checkpoints`

```text
Ran 10 tests in 16.045s
OK
```

`swallow`

```text
Ran 9 tests in 2.656s
OK
```

`execution_head`

```text
Ran 6 tests in 0.852s
OK
```

`execution_reads`

```text
Ran 10 tests in 0.083s
OK
```

`gate_names`

```text
Ran 27 tests in 12.941s
OK
```

`gate_rename_controls`

```text
Ran 5 tests in 6.416s
OK
```

`gate_template_controls`

```text
Ran 171 tests in 212.731s
OK
```

```text
GATE_RENAME_AST_DIFF PASS n_changes=267
```

```text
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
```

```text
GATE_RENAME_CONTROLS PASS 5/5 strict red
```

```text
GATE_PREFIX_PROBE PASS source_sites=1 baseline=green failures=4 errors=0 named=True
```

#### Every current new finite-label / R site — verbatim final probe lines

```text
R_SITE_PROBE B2_pending_slash_0x1111111111111111111111111111111111111111 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_chainId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_data PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_from PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_maxFeePerGas PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_maxPriorityFeePerGas PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_nonce PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_to PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE B4_variant_value PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE budget_anni PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE budget_approver PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE budget_deployer PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE budget_executor PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE budget_owner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.chainId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.forkState.commitment.check PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.forkState.commitment.mapping PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.forkState.token.overIssuedStorageSlot PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.0.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.0.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.0.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.1.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.1.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.1.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.2.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.2.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.2.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.3.call PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.3.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.3.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.mustReject.3.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.purpose PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.valid.call PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_export.valid.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.forkState PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.forkState.commitment PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.forkState.token PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.mustReject.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.mustReject.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.mustReject.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.mustReject.3 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_export.valid PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.forkState PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.forkState.commitment PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.forkState.token PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.mustReject.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.mustReject.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.mustReject.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.mustReject.3 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fields_fixture.export.valid PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.chainId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.forkState.commitment.check PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.forkState.commitment.mapping PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.forkState.token.overIssuedStorageSlot PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.0.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.0.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.0.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.1.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.1.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.1.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.2.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.2.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.2.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.3.call PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.3.change PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.3.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.mustReject.3.id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.purpose PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.valid.call PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.valid.expect PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.export.version PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_fixture.verifierCommit PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_export.mustReject PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_export.mustReject.0.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_export.mustReject.1.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_export.mustReject.2.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_export.mustReject.3.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_export.valid.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_fixture.export.mustReject PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_fixture.export.mustReject.0.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_fixture.export.mustReject.1.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_fixture.export.mustReject.2.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_fixture.export.mustReject.3.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_length_fixture.export.valid.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.aggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.domainSeparator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.forkState.commitment.key PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.forkState.commitment.value PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.forkState.token.address PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.forkState.token.runtimeBytecode PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.0.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.0.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.0.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.1.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.1.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.1.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.1.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.2.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.2.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.2.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.2.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.3.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.3.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.3.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.3.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.mustReject.3.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.owner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.epoch PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.fraudProofId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.operator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.proposalId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.valid.signerMask PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.verifier PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_export.version PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.aggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.domainSeparator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.forkState.commitment.key PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.forkState.commitment.value PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.forkState.token.address PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.forkState.token.runtimeBytecode PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.0.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.0.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.0.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.1.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.1.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.1.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.1.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.2.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.2.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.2.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.2.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.3.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.3.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.3.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.3.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.mustReject.3.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.owner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.epoch PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.fraudProofId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.operator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.proposalId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.valid.signerMask PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.export.verifier PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_pattern_fixture.toolCommit PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_properties_export BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.forkState BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.forkState.commitment BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.forkState.token BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.mustReject.0 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.mustReject.1 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.mustReject.2 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.mustReject.3 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_export.valid BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.forkState BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.forkState.commitment BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.forkState.token BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.mustReject.0 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.mustReject.1 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.mustReject.2 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.mustReject.3 BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_properties_fixture.export.valid BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE fraud_schema_range_export.block PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_range_export.valid.slashLevel PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_range_fixture.export.block PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_range_fixture.export.valid.slashLevel PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.forkState PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.forkState.commitment PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.forkState.token PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.mustReject.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.mustReject.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.mustReject.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.mustReject.3 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_export.valid PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.forkState PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.forkState.commitment PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.forkState.token PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.mustReject.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.mustReject.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.mustReject.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.mustReject.3 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_required_fixture.export.valid PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.aggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.block PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.domainSeparator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.forkState PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.forkState.commitment PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.forkState.commitment.key PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.forkState.commitment.value PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.forkState.token PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.forkState.token.address PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.forkState.token.runtimeBytecode PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.0.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.0.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.0.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.0.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.1.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.1.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.1.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.1.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.1.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.2.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.2.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.2.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.2.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.2.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.3 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.3.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.3.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.3.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.3.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.3.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.mustReject.3.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.owner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.epoch PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.fraudProofId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.operator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.proposalId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.signerMask PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.valid.slashLevel PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.verifier PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_export.version PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.aggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.block PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.domainSeparator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.forkState PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.forkState.commitment PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.forkState.commitment.key PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.forkState.commitment.value PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.forkState.token PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.forkState.token.address PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.forkState.token.runtimeBytecode PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.0.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.0.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.0.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.0.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.1.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.1.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.1.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.1.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.1.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.2.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.2.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.2.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.2.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.2.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.3 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.3.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.3.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.3.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.3.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.3.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.mustReject.3.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.owner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.domainDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.epoch PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.fraudProof PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.fraudProofId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.guiltyGuardians PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.guiltyGuardians.0 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.guiltyGuardians.1 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.guiltyGuardians.2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.operator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.proposalId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.signerMask PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.valid.slashLevel PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.export.verifier PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE fraud_schema_type_fixture.toolCommit PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_AGGREGATOR PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_ETH_USD_PRICE_FEED PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_EXTENSION PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_MINTER PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_PROTOCOL_REGISTRY PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_REGISTRY PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied___self PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied__cachedChainId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied__cachedDomainSeparator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied__cachedThis PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied__hashedName PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied__hashedVersion PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied__name PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied__version PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_entryPoint PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_extensionCodehash PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_implementation PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE immutable_supplied_implementationCodehash PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_activationScheduleNotBefore PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_addresses PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_b4Disclosure PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_controls PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_creationMetadataLayouts PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_expectedDiscoveryAfter PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_expectedDomainSeparator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_extension PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_externalInputs PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_final PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_gasParams PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_gasPolicy PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_implementation PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_operations PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_phaseC PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_pin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_prefixDigest PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_rebuild PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_route PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_schema PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_stage PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_stageSources PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_plan_key_timelockRuntimeIdentity PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_constructor PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_creates PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_executionTimestamp PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_gasBound PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_id PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_inner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_operation PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_phase PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_readbacks PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_safeHash PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_safeNonce PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_safeTarget PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_sender PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_step_key_warpTarget PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_chainId PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_data PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_from PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_maxFeePerGas PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_maxPriorityFeePerGas PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_nonce PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_to PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE manifest_tx_field_value PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_allowance_pair_0x2222222222222222222222222222222222222222_0x16df788ed4ed1fc384e52dc832a6a6c3a23bdebf PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_authority_member_SuperPaymaster_pendingOwner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_AOAProtocolRegistry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_APNTsCapped PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_BLSAggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_GToken PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_GTokenAuthorization PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_GTokenStaking PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_GlobalTierSource PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_MySBT PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_PaymasterFactory PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_Registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_SuperPaymaster PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_SuperPaymasterAdmin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_SuperPaymasterLens PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_TimelockController PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_xPNTsFactory PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_xPNTsFactoryV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_xPNTsToken PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_xPNTsTokenV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_duplicate_source_xPNTsTokenV2Ext PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_AOAProtocolRegistry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_APNTsCapped PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_BLSAggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_GToken PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_GTokenStaking PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_GlobalTierSource PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_MySBT PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_PaymasterFactory PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_Registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_SuperPaymaster PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_SuperPaymasterAdmin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_SuperPaymasterLens PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_TimelockController PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_xPNTsFactory PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_xPNTsFactoryV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_xPNTsToken PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_xPNTsTokenV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_event_role_member_xPNTsTokenV2Ext PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_AOAProtocolRegistry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_APNTsCapped PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_BLSAggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_GToken PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_GTokenAuthorization PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_GTokenStaking PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_GlobalTierSource PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_MySBT PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_PaymasterFactory PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_Registry BLOCKED source_sites=1 baseline=RED failures=0 errors=0 named=False
R_SITE_PROBE old_owner_extraction_roles_SuperPaymaster PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_SuperPaymasterAdmin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_SuperPaymasterLens PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_TimelockController PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_xPNTsFactory PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_xPNTsFactoryV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_xPNTsToken PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_xPNTsTokenV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_extraction_roles_xPNTsTokenV2Ext PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_fork_case_old_owner_event_role_member_TimelockController PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_getter_abi_GToken_owner BLOCKED source_sites=1 baseline=green failures=0 errors=1 named=False
R_SITE_PROBE old_owner_getter_output_owner PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_mapping_member_Registry_authorized PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_operator_treasury_0xb5600060e6de5e11d3636731964218e53caadf0e PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_role_admin_configured_0x7777777777777777777777777777777777777777777777777777777777777777 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_role_admin_declared_ROLE_COMMUNITY PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_role_expression_PROPOSER_ROLE PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_role_member_configured_Registry_0x7777777777777777777777777777777777777777777777777777777777777777 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE old_owner_role_member_declared_TimelockController_PROPOSER_ROLE PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_AGGREGATOR() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_APNTS_TOKEN() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_BALANCE_MODE_VERSION() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_BLS_AGGREGATOR() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_DVT_VALIDATOR() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_EXTENSION() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_FACTORY() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_MINTER() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_REGISTRY() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_SUPERPAYMASTER() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_SUPERPAYMASTER_ADDRESS() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_allowance(address,address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_approved(uint8,bytes32) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_approvedHashes(address,bytes32) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_autoAllowance(address,address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_autoRenewUsed(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_balance PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_balanceOf(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_blsAggregator() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_cachedPrice() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_cap() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_code PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_codeHash PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_community() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_communityENS() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_communityName() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_communityOwner() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_creditPolicy() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_creditTierSource() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_debts(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_decimals() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_defaultThreshold() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_defaultTierSource() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_domainSeparator() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_entryPoint() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_exchangeRate() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_fraudProofVerifier() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_getBLSPublicKey(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_getDeployedCount() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_getDepositInfo(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_getOperationState(bytes32) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_getRoleConfig(bytes32) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_getRoleStake(bytes32,address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_getTokenAddress(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_guardianSlashBps() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_hasRole(bytes32,address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_isEligibleForSponsorship(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_isReputationSource(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_isXPNTs(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_latestRoundData() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_maxSingleTxLimit() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_minThreshold() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_minter() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_name() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_operators(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_owner() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_paused() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingAPNTsToken() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingAPNTsTokenEta() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingBLSAgg() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingBLSAggEta() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingFraudProofVerifier() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingFraudProofVerifierReadyAt() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingOwner() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_pendingPolicyEta() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_protocolFeeBPS() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_protocolRevenue() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_renewalMode(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_sbtHolders(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_sealed_() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_slashPolicyAdmin() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_slashThresholds(uint8) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_storage PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_symbol() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_token() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_tokenPaymasterConfig() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_totalSupply() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_totalTrackedBalance() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_uniswap() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_userTotal(address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_validatorAtSlot(uint8) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_verifyCommunityMembership(address,address) PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_verifyingSigner() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_version() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_wrappedNative() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE readback_value_xpntsFactory() PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_AOAProtocolRegistry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_BLSAggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_GlobalTierSource PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_OverIssueFraudProofVerifier PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_Registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_SuperPaymaster PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_SuperPaymasterAdmin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_SuperPaymasterLens PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_xPNTsFactoryV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_xPNTsTokenV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE rebuild_record_xPNTsTokenV2Ext PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_AOAProtocolRegistry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_BLSAggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_GlobalTierSource PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_OverIssueFraudProofVerifier PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_Registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_SuperPaymaster PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_SuperPaymasterAdmin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_SuperPaymasterLens PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_xPNTsFactoryV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_xPNTsTokenV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_bytes_xPNTsTokenV2Ext PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_AOAProtocolRegistry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_BLSAggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_GlobalTierSource PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_OverIssueFraudProofVerifier PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_Registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_SuperPaymaster PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_SuperPaymasterAdmin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_SuperPaymasterLens PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_xPNTsFactoryV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_xPNTsTokenV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_executable_xPNTsTokenV2Ext PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_AOAProtocolRegistry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_BLSAggregator PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_GlobalTierSource PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_Registry PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_SuperPaymaster PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_SuperPaymasterAdmin PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_SuperPaymasterLens PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_xPNTsFactoryV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_xPNTsTokenV2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
R_SITE_PROBE reproducible_full_xPNTsTokenV2Ext PASS source_sites=1 baseline=green failures=1 errors=0 named=True
```

#### Final aggregation — verbatim

```text
COMMIT6E_R_RECLASSIFICATION moved_to_i=23 final_R=13 finite_sites=77 finite_labels=765
COMMIT6E_R_PROBES FAIL passed=12 total=13 blocked=1 errors_accepted=0
COMMIT6E_RECLASSIFIED_PROBES FAIL passed=535 total=555 blocked=20 empty_domains=1 errors_accepted=0
COMMIT6E_R_FOCUSED_PROBES FAIL passed=547 total=568 blocked=21 missing=0 errors_accepted=0
COMMIT6E_R_ACCEPTANCE INCOMPLETE strict_probe_blockers=21 unreachable_enum_sites=1 prior_finite_blockers=17 committed=false background_processes=0
```


### DSR ruling 1 — empty schema checks (continuation at 2acc71af, uncommitted)

M:389 and M:381 now have synthetic-schema positive controls in
`test_gate_empty_schema.py`. Each copies the real schema to a temporary file,
adds one optional `export.synthetic` constraint, verifies an allowed input, then
requires `assert_stop` with exactly `fraud_schema_properties_export.synthetic`
or `fraud_schema_enum_export.synthetic` for a violating input. The loader is not
parameterisable: the tests patch only `Path.read_text` for the exact schema path
used by `manifest_exec.fraud_format_only`; all other reads delegate unchanged.
Production `json.loads`, format adaptation, and `_fraud_schema` execute normally.
The checked-in schema, production gates, and `assert_stop` are unchanged.

`probe_gate_empty_schema.py` copies `script/` into temporary trees and deletes
exactly one matching gate statement per site there. Separate real-schema
tripwires require zero positive minProperties and zero enum nodes; their mutation
controls add one constraint to the copied schema and require a named assertion
failure. Temporary trees are cleaned on completion. No full probe-driver batch
was run. An initial synthetic sample-builder KeyError was fixed before the final
probe run; that ERROR was not accepted as evidence.

`gate_templates.json` registers both site proofs and their tripwires. The finite
and R acceptance drivers invoke the focused empty-schema acceptance, and omit
the obsolete impossible per-label controls. Registry validation also checks the
real schema counts and registered test methods. This resolves 19 actual
minProperties labels and the empty enum site (20 entries); it does not invent an
enum label or claim 20 real minProperties labels. Prior unrelated blockers remain
unchanged: O:530 Registry extraction encounters `old_owner_role_init_ids` first;
O:493 getter deletion yields a KeyError, which remains rejected; the earlier 17
finite-label blockers have not been rerun or accepted in this ruling.

Final focused probe lines, verbatim (`/tmp/commit6e-rulings/empty-schema.log`):

```text
EMPTY_SCHEMA_PROBE fraud_schema_properties_export.synthetic PASS source_sites=1 baseline=green failures=1 errors=0 named=True
EMPTY_SCHEMA_TRIPWIRE schema_tripwire_min_properties PASS source_sites=1 baseline=green failures=1 errors=0 named=True
EMPTY_SCHEMA_PROBE fraud_schema_enum_export.synthetic PASS source_sites=1 baseline=green failures=1 errors=0 named=True
EMPTY_SCHEMA_TRIPWIRE schema_tripwire_enum PASS source_sites=1 baseline=green failures=1 errors=0 named=True
EMPTY_SCHEMA_ACCEPTANCE PASS sites=2 controls=4/4 resolved_labels=19 blocked_labels=0 empty_enum_sites_resolved=1 errors_accepted=0
```

Final verifier lines, verbatim (foreground commands):

```text
python3 script/upgrade/gate_rename_ast_diff.py 2acc71af WORKTREE
GATE_RENAME_AST_DIFF PASS n_changes=267
python3 script/upgrade/probe_gate_names.py
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

Final requested suite summaries, verbatim. Each ran in the foreground via `python3 -B <test-file> -v`; logs are `/tmp/commit6e-rulings/dsr1-<name>.log`. Buffered fixture diagnostics after some summaries are not additional acceptance results.

`old_owner_isolation`:

```text
Ran 143 tests in 41.300s
OK (skipped=2)
```

`manifest_exec`:

```text
Ran 535 tests in 409.567s
OK (skipped=2)
```

`manifest_phase_c`:

```text
Ran 141 tests in 193.479s
OK
```

`a3a`:

```text
Ran 102 tests in 2.916s
OK
```

`sp_upgrade_exec`:

```text
Ran 141 tests in 1.380s
OK
```

`authority_checkpoints`:

```text
Ran 10 tests in 16.161s
OK
```

`swallow_exceptions`:

```text
Ran 9 tests in 2.579s
OK
```

`execution_head`:

```text
Ran 6 tests in 0.824s
OK
```

`execution_reads`:

```text
Ran 10 tests in 0.083s
OK
```

`gate_names`:

```text
Ran 27 tests in 12.339s
OK
```

`gate_rename_controls`:

```text
Ran 5 tests in 6.001s
OK
```

`gate_template_controls`:

```text
Ran 171 tests in 195.468s
OK
```

`gate_empty_schema`:

```text
Ran 4 tests in 0.004s
OK
```

Additional new-file suites from the preserved 6e diff were also run in the foreground. `gate_extra_finite` remains blocked at `test_extra_530_Registry`: the exact-gate assertion expects `old_owner_extraction_roles_Registry`, but production first raises `old_owner_role_init_ids` from `registry_role_writes` at O:344 (called at O:457). This is one assertion failure, zero errors; it is not a passing deletion probe. All other suites continued. The R-controls suite is green after the obsolete empty-domain per-label cases were replaced by the registered site proofs.

`gate_extra_finite`:

```text
Ran 56 tests in 4.202s
FAILED (failures=1)
```

`gate_r_controls`:

```text
Ran 608 tests in 162.999s
OK
```

Final scoped acceptance (all foreground processes completed; no background job was started):

```text
COMMIT6E_DSR1_ACCEPTANCE PASS strict_controls=4/4 schema_sites=2 resolved_finite_labels=19 resolved_empty_domains=1 requested_suites=13/13 additional_suites=1/2 errors_accepted=0
COMMIT6E_ACCEPTANCE INCOMPLETE unrelated_blockers_preserved=true committed=false background_processes=0
```

### 6e DSR ruling 3 — crash-red #20 / getter accessor pair (2026-11-07)

**Crash-red #20:** O:493, `old_owner_getter_abi_<name>_<label>`.
The preserved pre-addition probe for `old_owner_getter_abi_GToken_owner`
had baseline green and one source site; deleting O:493 reached O:494
`signatures[sig]['outputs']` and raised `KeyError: 'owner()'` (failures=0,
errors=1). That historical result remains rejected, not strict red.

Added production gate **A = `old_owner_getter_signature_present`**, the only
non-rename production addition in this continuation. It checks `sig in
signatures` immediately before the lookup, without changing the lookup,
exception handling, or any existing gate. It is a fixed literal, automatically
registered by the literal gate-name inventory; no dynamic template or rename-map
entry is appropriate. `gate_production_additions.json` separately declares the
reviewed addition at `script/upgrade/old_owner_isolation.py:494:20` in `extract`,
with statement AST SHA256
`e07c54d15b43bf2c80ac93eafa655700ac4db26bd8cf1bf5eb166f42ba6b9068`.
The semicolon keeps the retained O-site line coordinates stable. The R-probe
selector distinguishes literal statements on the shared line before selecting
an expression, rather than deleting by line number alone.

`gate_rename_ast_diff.py` removes only the exactly declared new statement from
its comparison tree after matching file, function, line, column and AST hash;
it rejects missing, moved, altered or duplicate additions, and continues the
ordinary gate-only comparison for all remaining AST nodes. New tests cover
these rejection cases and literal registration. There is no blanket production
exemption. The gate uniqueness/prefix-disjointness suite also covers A.

`test_getter_accessor.test_getter_pair` first requires the missing-ABI fixture
to fire the exact name `old_owner_getter_abi_GToken_owner`. A valid extraction
then must execute that gate immediately followed by A. The positive path records
and delegates every `a.need` call; no gate is suppressed. The ordered-pair
assertion makes deletion of A observable even though O:493 still protects the
missing-ABI path. `assert_stop` remains unchanged and accepts only `a.Gate`.

`probe_getter_accessor.py` runs only the two requested deletions. Each mutant is
written to its own temporary source copy, loaded for its single test, and
restored/removed in `finally`/temporary-directory cleanup. The real production
sources retain both gates. Delete O:493 only: the exact-name assertion fails
with A as the actual gate. Delete A only: the ordered-pair assertion fails and
names O:493 and A. Both results require one source site, baseline green,
failures>=1, errors==0 and a FAIL message naming the deleted gate and its pair.
The full probe-driver batch was not run.

Verbatim final check lines (expected mutant FAILs are the strict-red evidence,
not passing test suites):

```text
GETTER_ACCESSOR_PROBE old_owner_getter_abi_GToken_owner PASS source_sites=1 baseline=green failures=1 errors=0 named=True pair_named=True
GETTER_ACCESSOR_PROBE old_owner_getter_signature_present PASS source_sites=1 baseline=green failures=1 errors=0 named=True pair_named=True
GETTER_ACCESSOR_PROBES PASS passed=2/2 errors_accepted=0
ALLOWED script/upgrade/old_owner_isolation.py:494:20 REVIEWED_PRODUCTION_ADDITION old_owner_getter_signature_present ast_sha256=e07c54d15b43bf2c80ac93eafa655700ac4db26bd8cf1bf5eb166f42ba6b9068
GATE_RENAME_AST_DIFF PASS n_changes=268
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

The first final `gate_names` suite correctly rejected stale reviewed-domain
source hashes (two FAILs, zero ERRORs). All seven stale bindings in
`gate_finite_domains.json` referenced `old_owner_isolation.py`. Removing exactly
the newly declared accessor statement in memory reproduces the old source hash
`3b1475fcc056fa060963e8f492e6a921535f9d903580e4bd50b173069def62fd`.
After that check, those seven bindings were updated to
`a07a25f9330bcd597099efa36c24553a3d955f0ff7dfb64e6bc288122c289404`.
The domain labels are unchanged; the complete gate-name suite was rerun and
passed. No stale binding was ignored or exempted.

### 6e DSR ruling 3 — final foreground suite results

Verbatim unittest summary lines, including the initial stale-binding failure
and its corrected rerun:

`old_owner_isolation`:

```text
Ran 143 tests in 36.800s
OK (skipped=2)
```

`manifest_exec`:

```text
Ran 535 tests in 399.859s
OK (skipped=2)
```

`manifest_phase_c`:

```text
Ran 141 tests in 188.573s
OK
```

`a3a`:

```text
Ran 102 tests in 2.951s
OK
```

`sp_upgrade`:

```text
Ran 141 tests in 1.391s
OK
```

`authority_checkpoints`:

```text
Ran 10 tests in 15.978s
OK
```

`swallow`:

```text
Ran 9 tests in 2.590s
OK
```

`execution_head`:

```text
Ran 6 tests in 0.817s
OK
```

`execution_reads`:

```text
Ran 10 tests in 0.084s
OK
```

`gate_names`:

```text
Ran 27 tests in 7.678s
FAILED (failures=2)
```

`gate_names-rerun`:

```text
Ran 27 tests in 12.622s
OK
```

`gate_rename_controls`:

```text
Ran 5 tests in 5.880s
OK
```

`gate_template_controls`:

```text
Ran 171 tests in 194.244s
OK
```

`gate_empty_schema`:

```text
Ran 4 tests in 0.004s
OK
```

`gate_extra_finite`:

```text
Ran 56 tests in 4.065s
FAILED (failures=1)
```

`gate_r_controls`:

```text
Ran 608 tests in 161.255s
OK
```

`getter_accessor`:

```text
Ran 2 tests in 3.396s
OK
```

The remaining extra-finite blocker is unchanged: `test_extra_530_Registry`
expects `old_owner_extraction_roles_Registry`, but `extract` calls
`registry_role_writes` at O:457 and the earlier `old_owner_role_init_ids`
gate fires at O:344. This is one FAIL, zero ERRORs, and a red baseline; it
is not accepted as a strict deletion result. The runner continued through
R-controls and the new accessor suite after recording the blocker.

The final AST comparison after refreshing the reviewed source bindings:

```text
GATE_RENAME_AST_DIFF PASS n_changes=268
```

All launched commands and their foreground children finished. Temporary getter
probe trees were removed by context-manager cleanup. No background job was
started or left running, and the full probe-driver batch was not run. HEAD
remains `2acc71af`; nothing was committed or staged. The retained 6e diff is
preserved. No RPC endpoint, env file, keystore or chain was accessed.

```text
COMMIT6E_DSR3_ACCEPTANCE PASS strict_pair_probes=2/2 requested_suites=12/12 new_suites=1/1 additional_suites=2/3 errors_accepted=0
COMMIT6E_ACCEPTANCE INCOMPLETE extra_finite_registry_blocker_preserved=true committed=false background_processes=0
```

### 6e DSR ruling 2 — eighteen earlier-gate blockers (2026-11-07)

Scope: preserved HEAD `2acc71af` and the existing uncommitted 6e diff. No commit,
RPC endpoint, environment file, keystore, or chain operation. No production gate
was removed, replaced, or weakened. Only temporary copies under the system temp
directory receive AST statement deletions. `assert_stop` remains unchanged and
catches only `a.Gate`. The full probe-driver batch was not run.

Reproducible controls: `test_gate_dsr2.py` reuses the exact eighteen previously
blocked bad-input constructors. Its normal suite runs only real-tree shadow
controls, requiring the precise E name. `probe_gate_dsr2.py` runs each case in a
separate temporary source tree; it deletes one AST statement for E, then deletes
one AST statement for T only if the E-only tree reaches T. Source line numbers
below refer to this 6e worktree. Deletions preserve line numbers. An E-only
exact-T control must be green before the E+T deletion can count. Accepted mutant
results require at least one unittest FAIL, zero ERRORs, and an assertion message
naming T. Neither an unrelated exception nor a blocked baseline counts.

Preferred method (a) feasibility review, using ordinary JSON-decoded values and
unchanged production constants:

- `fraud_token_zero_owner_{130,210}`: the input changes one runtime byte at the
  named offset to `01`. The pinned full runtime and stripped executable hashes
  constrain that byte before T; passing those checks with changed executable
  bytes would require defeating the hash pin. The second hash is a further gate.
- `verifier_ciSha256`: the input sets the digest to `invalid`. The earlier
  `reviewed_bytes` format predicate is identical to T's format predicate; the
  subsequent file-hash equality also constrains it.
- `verifier_buildSha256`: the input sets the digest to `invalid`. The pinned
  `VERIFIER_SHA256` accepted by E is already a nonzero lowercase 64-digit digest.
- `canonical_{anni,dvt,committee}`: uppercase address hex violates T, but E
  requires equality with the fixed lowercase address. `nonzero_*` uses the zero
  address, which cannot equal the fixed nonzero address. No constants are patched.
- `sender_fields_{deployer,approver,executor}`: an extra `extra: true` field
  violates both the earlier `sender` exact-key check and T's identical check.
- `sender_{deployer,approver,executor}`: the original candidate replaces the
  address with zero. This removes its matching nonce-history rows. Even rebuilding
  that evidence cannot reach T with a different identity: `u.validate_pin` checks
  `sender_identity` against the same `a.SENDERS` values before T. Removing the
  history guard alone can expose `max([])`; that is an ERROR, never acceptance.
- `drain_operator_present_deployer`: the input removes the deployer balance key
  and subtracts its balance from the total. Passing `drain_inventory` requires
  removing it from the pause list too, but `sampled_deployer_only` and
  `sampled_inventory` together require deployer membership in that list.
- `old_owner_extraction_roles_Registry`: the input removes the Registry constant
  declarations from the synthetic AST while retaining `hasRole`. The initializer
  analysis requires nonempty resolved role-constant references, and
  `old_owner_role_init_standard` binds their names to the extracted roles. No
  production initializer or extraction predicate is bypassed in the real tree.

All eighteen sub-items are processed regardless of blockers. Logs and structured
results for this run are in `/tmp/commit6e-dsr2/`; the initial focused probe log is
`/tmp/commit6e-dsr2-probes.log`. These are local transient evidence, not release
attestations. Final tables and verbatim result lines follow below.

#### DSR2 final eighteen-target table

`b` requires all three stages: E-only exact-T baseline green, E-only explicit
unittest FAIL naming T with zero errors, and E+T deletion FAIL naming T with zero
errors; the real-tree shadow control separately requires E's exact name. The
explicit E-only red output was confirmed in a separate bounded pass over the
12 reachable targets (`DSR2_B1_RED`); the checked-in runner now includes that
confirmation directly. `DSR2_PAIR` lines below are verbatim from the initial
focused run; `DSR2_B1_RED` lines are verbatim from that confirmation pass.

`chain` means no third gate was deleted. `c (ERROR-blocked)` routes the three
sender-identity targets to ruling (c)'s DSR review: T did not fire after E was
removed, but the reason was a non-Gate exception. This is not accepted evidence
of a successful probe or a proof of dead code for every input. T remains intact.
The runner's raw `method=blocked-error` distinguishes this from a gate chain.

| T | E | Method | Probe result lines (verbatim) |
|---|---|---|---|
| `fraud_token_zero_owner_130` | `fraud_token_pinned_runtime` | chain | `DSR2_PAIR fraud_token_zero_owner_130 BLOCKED E=fraud_token_pinned_runtime method=chain E_sites=1 shadow=green b1_failures=1 b1_errors=0 T_reached=False` |
| `fraud_token_zero_owner_210` | `fraud_token_pinned_runtime` | chain | `DSR2_PAIR fraud_token_zero_owner_210 BLOCKED E=fraud_token_pinned_runtime method=chain E_sites=1 shadow=green b1_failures=1 b1_errors=0 T_reached=False` |
| `verifier_ciSha256` | `evidence_dvt-ci_hash` | chain | `DSR2_PAIR verifier_ciSha256 BLOCKED E=evidence_dvt-ci_hash method=chain E_sites=1 shadow=green b1_failures=1 b1_errors=0 T_reached=False` |
| `verifier_buildSha256` | `verifier_build_identity` | b | `DSR2_PAIR verifier_buildSha256 PASS E=verifier_build_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED verifier_buildSha256 PASS E_sites=1 failures=1 errors=0 named=True` |
| `canonical_anni` | `fixed_anni` | b | `DSR2_PAIR canonical_anni PASS E=fixed_anni source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED canonical_anni PASS E_sites=1 failures=1 errors=0 named=True` |
| `nonzero_anni` | `fixed_anni` | b | `DSR2_PAIR nonzero_anni PASS E=fixed_anni source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED nonzero_anni PASS E_sites=1 failures=1 errors=0 named=True` |
| `canonical_dvt` | `fixed_dvt` | b | `DSR2_PAIR canonical_dvt PASS E=fixed_dvt source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED canonical_dvt PASS E_sites=1 failures=1 errors=0 named=True` |
| `nonzero_dvt` | `fixed_dvt` | b | `DSR2_PAIR nonzero_dvt PASS E=fixed_dvt source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED nonzero_dvt PASS E_sites=1 failures=1 errors=0 named=True` |
| `canonical_committee` | `fixed_committee` | b | `DSR2_PAIR canonical_committee PASS E=fixed_committee source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED canonical_committee PASS E_sites=1 failures=1 errors=0 named=True` |
| `nonzero_committee` | `fixed_committee` | b | `DSR2_PAIR nonzero_committee PASS E=fixed_committee source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED nonzero_committee PASS E_sites=1 failures=1 errors=0 named=True` |
| `sender_fields_deployer` | `sender` | b | `DSR2_PAIR sender_fields_deployer PASS E=sender source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED sender_fields_deployer PASS E_sites=1 failures=1 errors=0 named=True` |
| `sender_deployer` | `a3a_sender_history` | c (ERROR-blocked) | `DSR2_PAIR sender_deployer BLOCKED E=a3a_sender_history method=blocked-error E_sites=1 shadow=green b1_failures=0 b1_errors=1 T_reached=False` |
| `sender_fields_approver` | `sender` | b | `DSR2_PAIR sender_fields_approver PASS E=sender source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED sender_fields_approver PASS E_sites=1 failures=1 errors=0 named=True` |
| `sender_approver` | `a3a_sender_history` | c (ERROR-blocked) | `DSR2_PAIR sender_approver BLOCKED E=a3a_sender_history method=blocked-error E_sites=1 shadow=green b1_failures=0 b1_errors=1 T_reached=False` |
| `sender_fields_executor` | `sender` | b | `DSR2_PAIR sender_fields_executor PASS E=sender source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED sender_fields_executor PASS E_sites=1 failures=1 errors=0 named=True` |
| `sender_executor` | `a3a_sender_history` | c (ERROR-blocked) | `DSR2_PAIR sender_executor BLOCKED E=a3a_sender_history method=blocked-error E_sites=1 shadow=green b1_failures=0 b1_errors=1 T_reached=False` |
| `drain_operator_present_deployer` | `drain_inventory` | b | `DSR2_PAIR drain_operator_present_deployer PASS E=drain_inventory source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED drain_operator_present_deployer PASS E_sites=1 failures=1 errors=0 named=True` |
| `old_owner_extraction_roles_Registry` | `old_owner_role_init_ids` | b | `DSR2_PAIR old_owner_extraction_roles_Registry PASS E=old_owner_role_init_ids source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED old_owner_extraction_roles_Registry PASS E_sites=1 failures=1 errors=0 named=True` |

#### Remaining DSR decisions — exact input and stopping reason

- `fraud_token_zero_owner_130`: set runtime byte 130 to `01`. Chain:
  `fraud_token_pinned_runtime` (M:487) → `fraud_token_stripped_runtime` (M:491)
  → T (M:494). Only the first gate was deleted in the temporary tree.
- `fraud_token_zero_owner_210`: set runtime byte 210 to `01`. The same chain
  stops before T. No deletion of the stripped-runtime gate was attempted.
- `verifier_ciSha256`: set `verifier.ciSha256` to `invalid`. Chain:
  `evidence_dvt-ci_hash` (M:78) → `evidence_dvt-ci` (M:82) → T (M:640).
  The second guard compares the file's actual SHA-256 to the supplied digest;
  it was not deleted.
- `sender_deployer`, `sender_approver`, `sender_executor`: separately set that
  sender's address to the zero address while retaining its original nonce-history
  fixture. E is `a3a_sender_history` (M:1822). Removing E leaves `rows=[]`, and
  `max(rows, ...)` at M:1823 raises `ValueError` before T (M:2155). Each result is
  zero failures and one ERROR, so no E+T deletion was attempted. The real tree
  stops each identical input at E with its exact name. Additionally, for ordinary
  decoded inputs the later `sender_identity` check at U:735 enforces the same
  identity as T; it was not removed. These are retained redundant/dead-code
  candidates for DSR, not accepted deletion probes. No exception was converted
  into a passing `assert_stop`, and no fallback was introduced.

Verbatim blocker exception-message lines:

```text
fraud_token_zero_owner_130:
AssertionError: 'fraud_token_stripped_runtime' != 'fraud_token_zero_owner_130'
fraud_token_zero_owner_210:
AssertionError: 'fraud_token_stripped_runtime' != 'fraud_token_zero_owner_210'
verifier_ciSha256:
AssertionError: 'evidence_dvt-ci' != 'verifier_ciSha256'
sender_deployer:
ValueError: max() arg is an empty sequence
sender_approver:
ValueError: max() arg is an empty sequence
sender_executor:
ValueError: max() arg is an empty sequence
```

Verbatim focused-run final lines:

```text
DSR2_PROBES COMPLETE accepted=12/18 blocked=6 errors_accepted=0
DSR2_B1_RED_COMPLETE accepted=12/12 errors_accepted=0
```

#### DSR2 final foreground validation — verbatim final lines

Every command below finished in the foreground. No full probe-driver batch was
run. The requested twelve suites all passed, and the new eighteen-case shadow
suite passed. All pre-existing untracked 6e test files were also run: the extra
finite-label suite retains its one ordinary Registry baseline failure; the
other additional suites passed. A paired probe does not make that ordinary
baseline green, so its expectation was not weakened or rewritten.

`python3 -B script/upgrade/gate_rename_ast_diff.py 2acc71af WORKTREE` (exit 0):

```text
GATE_RENAME_AST_DIFF PASS n_changes=268
```

`python3 -B script/upgrade/probe_gate_names.py` (exit 0):

```text
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

`python3 -B script/upgrade/test_old_owner_isolation.py` (exit 0):

```text
Ran 143 tests in 43.832s
OK (skipped=2)
```

`python3 -B script/upgrade/test_manifest_exec.py` (exit 0):

```text
Ran 535 tests in 442.190s
OK (skipped=2)
```

`python3 -B script/upgrade/test_manifest_phase_c.py` (exit 0):

```text
Ran 141 tests in 205.988s
OK
```

`python3 -B script/a3a/test_a3a_exec.py` (exit 0):

```text
Ran 102 tests in 2.938s
OK
```

`python3 -B script/upgrade/test_sp_upgrade_exec.py` (exit 0):

```text
Ran 141 tests in 1.401s
OK
```

`python3 -B script/upgrade/test_authority_checkpoints.py` (exit 0):

```text
Ran 10 tests in 15.924s
OK
```

`python3 -B script/upgrade/test_swallow_exceptions.py` (exit 0):

```text
Ran 9 tests in 2.560s
OK
```

`python3 -B script/upgrade/test_execution_head.py` (exit 0):

```text
Ran 6 tests in 0.820s
OK
```

`python3 -B script/upgrade/test_execution_reads.py` (exit 0):

```text
Ran 10 tests in 0.083s
OK
```

`python3 -B script/upgrade/test_gate_names.py` (exit 0):

```text
Ran 27 tests in 12.479s
OK
```

`python3 -B script/upgrade/test_gate_rename_controls.py` (exit 0):

```text
Ran 5 tests in 5.901s
OK
```

`python3 -B script/upgrade/test_gate_template_controls.py` (exit 0):

```text
Ran 171 tests in 192.503s
OK
```

`python3 -B script/upgrade/test_gate_dsr2.py` (exit 0):

```text
Ran 18 tests in 31.481s
OK
```

`python3 -B script/upgrade/test_gate_empty_schema.py` (exit 0):

```text
Ran 4 tests in 0.005s
OK
```

`python3 -B script/upgrade/test_gate_extra_finite.py` (exit 1):

```text
Ran 56 tests in 4.578s
FAILED (failures=1)
```

`python3 -B script/upgrade/test_gate_r_controls.py` (exit 0):

```text
Ran 608 tests in 179.767s
OK
```

`python3 -B script/upgrade/test_getter_accessor.py` (exit 0):

```text
Ran 2 tests in 3.730s
OK
```

The failing additional-suite test is `test_extra_530_Registry`. Its exact
exception-message line in this run is:

```text
AssertionError: 'old_owner_role_init_ids' != 'old_owner_extraction_roles_Registry'
```

The final repeat of `python3 -B script/upgrade/gate_rename_ast_diff.py 2acc71af WORKTREE`
after the focused runner and report additions also returned exit 0:

```text
GATE_RENAME_AST_DIFF PASS n_changes=268
```

`git diff --check` returned exit 0 with no output. HEAD remains `2acc71af`.
The pre-existing 6e diff is preserved and uncommitted. This continuation adds
only the two focused DSR2 Python files and this results subsection. All owned
foreground processes finished; the temporary DSR2 source-tree count is zero.
No production gate, `assert_stop`, environment file, keystore, or deployment
configuration was changed. No live RPC/chain operation was performed.

All eighteen targets were processed without a stop threshold. Six remain for
DSR: three gate chains and three ERROR-blocked sender-identity candidates.
Their gates remain intact. This is incomplete probe acceptance, not a waiver.

```text
COMMIT6E_DSR2_RESULT INCOMPLETE targets_processed=18 strict_pairs=12/18 chain_blocked=3 error_blocked=3 requested_suites=12/12 new_shadow_suite=18/18 additional_suites=3/4 errors_accepted=0
```

### 6e final six-target DSR continuation (2026-11-07)

This continuation preserves HEAD `2acc71af`, the uncommitted 6e changes, and the
twelve accepted DSR2 pair results above. No commit or RPC/env/keystore/chain
operation was performed. No full probe-driver batch was run. Only the six
remaining targets were selected by `probe_gate_dsr2.py --remaining`; the new
accessor has its own single-deletion probe. All source deletions occur in
temporary copies, with line numbers preserved, including same-line statements.
`assert_stop` still catches only `a.Gate`.

The only new production statement is the named guard
`a3a_sender_history_rows_present` immediately before `max(rows, ...)` at
M:1823. It retains the existing history gate at M:1822 and adds no fallback.
Its exact location, enclosing function, and AST SHA-256 are registered in
`gate_production_additions.json`, using the same fail-closed comparator path
as the O:494 accessor. Positive tests verify its exact-name stop after E is
removed in a temporary copy, its ordered pair on valid input, inventory
uniqueness/prefix disjointness, and rejection of missing, moved, duplicated,
or predicate-altered additions. The existing getter registration test now
selects its own registry row rather than assuming that only one addition exists.
The finite-domain dependency hashes were refreshed for this single production
addition; all reviewed domains are unchanged. The nonce_expectations scope fingerprint is also refreshed after proving that removing only the declared accessor reproduces its previous fingerprint (see the initial gate_names failure and corrected rerun below).

For three-level chains, the exact-T control must be green with E1+E2 removed.
The same bad input must also produce an explicit unittest FAIL naming T with
zero ERRORs. Removing T as well must remain red, with a FAIL message naming T
and zero ERRORs. Each deleted statement must have one source site. The real
tree must stop at E1's exact name. The E1-only observation separately requires
E2's exact name. No fourth prerequisite is deleted.

For sender targets, only E at M:1822 and `sender_identity` at U:735 are removed
before checking T. The new accessor remains enabled. A red exact-T baseline
is a blocker, even when deleting T also produces a named assertion failure.
These results do not prove universal unreachability and do not authorize
deleting any sender gate.

#### Before/after subcase and exact-name assertion accounting

“Before” is the preceding recorded 56-case extra-finite suite plus the existing
18 shadow and 18 target DSR2 controls. “After” is the current callable control
inventory. Counts are registered subcases, not repeated probe invocations or
accepted mutation results. Every counted control executes one `assert_stop`
with an exact gate name; blocked target controls are included as controls,
never as passing probes.

| Control family | Subcases before | Subcases after | Exact-name assertions before | Exact-name assertions after |
|---|---:|---:|---:|---:|
| extra-finite | 56 | 55 | 56 | 55 |
| DSR2 real-tree shadow | 18 | 18 | 18 | 18 |
| DSR2 target/pair | 18 | 18 | 18 | 18 |
| DSR2 E1-only second stop | 0 | 6 | 0 | 6 |
| **Total** | **92** | **97** | **92** | **97** |

The removed `test_extra_530_Registry` was an invalid direct-T expectation:
the unchanged real tree stops at `old_owner_role_init_ids`. Registry coverage
remains in `test_shadow_old_owner_extraction_roles_Registry` and
`test_target_old_owner_extraction_roles_Registry`, with its accepted strict
pair result preserved above. Both aggregate totals increase by five.
The accessor's two new tests and its deletion probe are additional and are
not used to inflate this accounting.

#### Crash-red #21 accessor evidence

The single-deletion probe returned exit 0. Its verbatim final line:

```text
SENDER_ACCESSOR_PROBE a3a_sender_history_rows_present PASS source_sites=1 baseline=green failures=1 errors=0 named=True
```

Initial positive and fingerprint suite (exit 0), verbatim final lines:

```text
Ran 2 tests in 19.726s
OK
```

#### Final T / chain / method / verbatim result lines

The twelve earlier accepted rows are preserved verbatim below; they were not rerun by the six-target command. The six remaining rows are new results. M, O, and U denote manifest_exec.py, old_owner_isolation.py, and sp_upgrade_exec.py.

| T | Chain | Method | Verbatim result lines |
|---|---|---|---|
| `verifier_buildSha256` | `verifier_build_identity`  → T | preserved strict pair | `DSR2_PAIR verifier_buildSha256 PASS E=verifier_build_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED verifier_buildSha256 PASS E_sites=1 failures=1 errors=0 named=True` |
| `canonical_anni` | `fixed_anni`  → T | preserved strict pair | `DSR2_PAIR canonical_anni PASS E=fixed_anni source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED canonical_anni PASS E_sites=1 failures=1 errors=0 named=True` |
| `nonzero_anni` | `fixed_anni`  → T | preserved strict pair | `DSR2_PAIR nonzero_anni PASS E=fixed_anni source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED nonzero_anni PASS E_sites=1 failures=1 errors=0 named=True` |
| `canonical_dvt` | `fixed_dvt`  → T | preserved strict pair | `DSR2_PAIR canonical_dvt PASS E=fixed_dvt source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED canonical_dvt PASS E_sites=1 failures=1 errors=0 named=True` |
| `nonzero_dvt` | `fixed_dvt`  → T | preserved strict pair | `DSR2_PAIR nonzero_dvt PASS E=fixed_dvt source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED nonzero_dvt PASS E_sites=1 failures=1 errors=0 named=True` |
| `canonical_committee` | `fixed_committee`  → T | preserved strict pair | `DSR2_PAIR canonical_committee PASS E=fixed_committee source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED canonical_committee PASS E_sites=1 failures=1 errors=0 named=True` |
| `nonzero_committee` | `fixed_committee`  → T | preserved strict pair | `DSR2_PAIR nonzero_committee PASS E=fixed_committee source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED nonzero_committee PASS E_sites=1 failures=1 errors=0 named=True` |
| `sender_fields_deployer` | `sender`  → T | preserved strict pair | `DSR2_PAIR sender_fields_deployer PASS E=sender source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED sender_fields_deployer PASS E_sites=1 failures=1 errors=0 named=True` |
| `sender_fields_approver` | `sender`  → T | preserved strict pair | `DSR2_PAIR sender_fields_approver PASS E=sender source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED sender_fields_approver PASS E_sites=1 failures=1 errors=0 named=True` |
| `sender_fields_executor` | `sender`  → T | preserved strict pair | `DSR2_PAIR sender_fields_executor PASS E=sender source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED sender_fields_executor PASS E_sites=1 failures=1 errors=0 named=True` |
| `drain_operator_present_deployer` | `drain_inventory`  → T | preserved strict pair | `DSR2_PAIR drain_operator_present_deployer PASS E=drain_inventory source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED drain_operator_present_deployer PASS E_sites=1 failures=1 errors=0 named=True` |
| `old_owner_extraction_roles_Registry` | `old_owner_role_init_ids`  → T | preserved strict pair | `DSR2_PAIR old_owner_extraction_roles_Registry PASS E=old_owner_role_init_ids source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E failures=1 errors=0 named=True`<br>`DSR2_B1_RED old_owner_extraction_roles_Registry PASS E_sites=1 failures=1 errors=0 named=True` |
| fraud_token_zero_owner_130 | fraud_token_pinned_runtime M:487 → fraud_token_stripped_runtime M:491 → T M:494 | three-level | `DSR2_SECOND fraud_token_zero_owner_130 PASS delete_only=fraud_token_pinned_runtime exact_stop=fraud_token_stripped_runtime`<br>`DSR2_FINAL fraud_token_zero_owner_130 PASS method=three-level source_sites=1 E_sites=1 second_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| fraud_token_zero_owner_210 | fraud_token_pinned_runtime M:487 → fraud_token_stripped_runtime M:491 → T M:494 | three-level | `DSR2_SECOND fraud_token_zero_owner_210 PASS delete_only=fraud_token_pinned_runtime exact_stop=fraud_token_stripped_runtime`<br>`DSR2_FINAL fraud_token_zero_owner_210 PASS method=three-level source_sites=1 E_sites=1 second_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| verifier_ciSha256 | evidence_dvt-ci_hash M:78 → evidence_dvt-ci M:82 → T M:640 | three-level | `DSR2_SECOND verifier_ciSha256 PASS delete_only=evidence_dvt-ci_hash exact_stop=evidence_dvt-ci`<br>`DSR2_FINAL verifier_ciSha256 PASS method=three-level source_sites=1 E_sites=1 second_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| sender_deployer | sender_identity U:735 → T M:2155; E and #21 intact | rebuilt non-zero fixture, strict pair | `DSR2_PAIR sender_deployer PASS E=sender_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E b1_failures=1 b1_errors=0 b1_named=True failures=1 errors=0 named=True` |
| sender_approver | sender_identity U:735 → T M:2155; E and #21 intact | rebuilt non-zero fixture, strict pair | `DSR2_PAIR sender_approver PASS E=sender_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E b1_failures=1 b1_errors=0 b1_named=True failures=1 errors=0 named=True` |
| sender_executor | sender_identity U:735 → T M:2155; E and #21 intact | rebuilt non-zero fixture, strict pair | `DSR2_PAIR sender_executor PASS E=sender_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E b1_failures=1 b1_errors=0 b1_named=True failures=1 errors=0 named=True` |

The E1-only observations are also recorded as their own verbatim lines:

```text
DSR2_SECOND fraud_token_zero_owner_130 PASS delete_only=fraud_token_pinned_runtime exact_stop=fraud_token_stripped_runtime
DSR2_SECOND fraud_token_zero_owner_210 PASS delete_only=fraud_token_pinned_runtime exact_stop=fraud_token_stripped_runtime
DSR2_SECOND verifier_ciSha256 PASS delete_only=evidence_dvt-ci_hash exact_stop=evidence_dvt-ci
DSR2_SECOND sender_deployer PASS delete_only=a3a_sender_history exact_stop=a3a_sender_history_rows_present
DSR2_SECOND sender_approver PASS delete_only=a3a_sender_history exact_stop=a3a_sender_history_rows_present
DSR2_SECOND sender_executor PASS delete_only=a3a_sender_history exact_stop=a3a_sender_history_rows_present
```

Historical fixture diagnosis (superseded by the non-zero sender fixture continuation below): the former sender dead-code candidates used the offline ManifestTemplateTests fixture: deepcopy(self.pin), replace only pin["senders"][role]["address"] with a.ZERO (0x0000000000000000000000000000000000000000), then call m.build_plan(pin, self.inputs). No evidence, nonce, sender constants, or input fields are repaired.

- `sender_deployer`: with M:1822 and U:735 deleted in the temporary tree, the address has no matching plan history rows, so M:1823 raises `a3a_sender_history_rows_present` before max and before T. Exact baseline failure message:

    `AssertionError: 'a3a_sender_history_rows_present' != 'sender_deployer'`

- `sender_approver`: with M:1822 and U:735 deleted in the temporary tree, the address has no matching plan history rows, so M:1823 raises `a3a_sender_history_rows_present` before max and before T. Exact baseline failure message:

    `AssertionError: 'a3a_sender_history_rows_present' != 'sender_approver'`

- `sender_executor`: with M:1822 and U:735 deleted in the temporary tree, the address has no matching plan history rows, so M:1823 raises `a3a_sender_history_rows_present` before max and before T. Exact baseline failure message:

    `AssertionError: 'a3a_sender_history_rows_present' != 'sender_executor'`

These are bounded dead-code candidates for the exact inputs above. They are not accepted deletion probes and not a proof about every possible input. No deeper chain was deleted. All six targets completed despite these blockers.

```text
DSR2_REMAINING COMPLETE processed=6 accepted=3 blocked=3 preserved_accepted=12 errors_accepted=0
```

#### Gate-name fingerprint correction during final verification

The first gate_names suite failed two assertions with `gate_templates: reviewed domain source changed`. The whole-file dependency hash had been refreshed, but the three records bound to nonce_expectations still contained its old AST fingerprint. For each affected record (M:1824, M:1831, M:1832), removing only the registered M:1823 accessor from the parsed function reproduced the old fingerprint exactly. Only those three scope hashes were then refreshed; domains, labels, predicates, and assertion behavior were unchanged. Other suites continued throughout.

Initial gate_names run (exit 1), verbatim final lines:

```text
Ran 27 tests in 5.003s
FAILED (failures=2)
```

Corrected gate_names rerun (exit 0), verbatim final lines:

```text
Ran 27 tests in 23.271s
OK
```

#### Final foreground verification — verbatim final lines

All commands ran in the foreground and completed. The final gate_names result below is its corrected rerun; the initial failure remains recorded above. These are suite results, distinct from intentional mutation FAILs. Logs are under /tmp/commit6e-final-checks/, with the corrected gate-name log at /tmp/commit6e-gate-names-rerun.log and final AST log at /tmp/commit6e-final-ast.log. No full probe-driver batch was run.

`python3 -B script/upgrade/gate_rename_ast_diff.py 2acc71af WORKTREE` — final exit 0:

```text
GATE_RENAME_AST_DIFF PASS n_changes=269
```

`python3 -B script/upgrade/probe_gate_names.py` — final exit 0:

```text
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

`python3 -B script/upgrade/test_old_owner_isolation.py` — final exit 0:

```text
Ran 143 tests in 42.686s
OK (skipped=2)
```

`python3 -B script/upgrade/test_manifest_exec.py` — final exit 0:

```text
Ran 535 tests in 538.896s
OK (skipped=2)
```

`python3 -B script/upgrade/test_manifest_phase_c.py` — final exit 0:

```text
Ran 141 tests in 202.996s
OK
```

`python3 -B script/a3a/test_a3a_exec.py` — final exit 0:

```text
Ran 102 tests in 2.974s
OK
```

`python3 -B script/upgrade/test_sp_upgrade_exec.py` — final exit 0:

```text
Ran 141 tests in 1.405s
OK
```

`python3 -B script/upgrade/test_authority_checkpoints.py` — final exit 0:

```text
Ran 10 tests in 16.374s
OK
```

`python3 -B script/upgrade/test_swallow_exceptions.py` — final exit 0:

```text
Ran 9 tests in 2.657s
OK
```

`python3 -B script/upgrade/test_execution_head.py` — final exit 0:

```text
Ran 6 tests in 0.851s
OK
```

`python3 -B script/upgrade/test_execution_reads.py` — final exit 0:

```text
Ran 10 tests in 0.086s
OK
```

`python3 -B script/upgrade/test_gate_names.py` — final exit 0:

```text
Ran 27 tests in 23.271s
OK
```

`python3 -B script/upgrade/test_gate_rename_controls.py` — final exit 0:

```text
Ran 5 tests in 6.138s
OK
```

`python3 -B script/upgrade/test_gate_template_controls.py` — final exit 0:

```text
Ran 171 tests in 260.279s
OK
```

`python3 -B script/upgrade/test_gate_dsr2.py` — final exit 0:

```text
Ran 18 tests in 34.896s
OK
```

`python3 -B script/upgrade/test_gate_empty_schema.py` — final exit 0:

```text
Ran 4 tests in 0.004s
OK
```

`python3 -B script/upgrade/test_gate_extra_finite.py` — final exit 0:

```text
Ran 55 tests in 4.170s
OK
```

`python3 -B script/upgrade/test_gate_r_controls.py` — final exit 0:

```text
Ran 608 tests in 176.000s
OK
```

`python3 -B script/upgrade/test_getter_accessor.py` — final exit 0:

```text
Ran 2 tests in 3.727s
OK
```

`python3 -B script/upgrade/test_sender_accessor.py` — final exit 0:

```text
Ran 2 tests in 20.552s
OK
```

Cleanup and worktree verification: all processes launched for this continuation were waited to completion; none remain running. The temporary probe-tree check and HEAD check returned these verbatim lines:

```text
TEMP_PROBE_TREES remaining=0
2acc71af
```

git diff --check passed with no output. HEAD remains unchanged and the complete 6e diff remains uncommitted. No real-tree gate was deleted; assert_stop remains unchanged. Three sender targets remain explicitly blocked by the new accessor for the exact zero-address inputs, and are not counted as accepted.

```text
COMMIT6E_FINAL_RESULT COMPLETE_WITH_BLOCKERS targets_processed=18 accepted_targets=15/18 preserved_pairs=12/12 dead_code_candidates=3 accessor_probes=1/1 suites=18/18 ast_diff=PASS gate_name_probes=PASS errors_accepted=0
```


### 6e independent tooling review follow-up (2026-11-07)

HEAD remains `2acc71afb62b23e72a5c610522be0e21dc87e119`; no commit was made. The incoming uncommitted 6e production/test diff is preserved. This follow-up changes offline tooling, adds regression tests and explicit reference declarations, and records results. No RPC, chain, keystore or environment configuration was used. No full probe-driver batch was run. Gate deletion controls operate on copied ASTs/temporary fixtures, never on real production source files. `gate_assertions.assert_stop` is unchanged and catches only `a.Gate` (through `u.a.Gate`). Errors never count as successful deletion controls.

Fixes:

1. Automatic AST acceptance no longer walks descendants of lookups or arbitrary expressions, exempts test filenames, accepts arbitrary `dict(gate=...)`, or accepts raw-source selectors implicitly. Direct label literals/concatenation components and restricted expected-name forwarding are checked. Parameters with non-label consumers are rejected. Other legitimate gate-name references require an exact file, line, AST path, before/after node fingerprint and before/after complete-source fingerprint in `gate_rename_references.json`.
2. Forwarding rules carry the primitive guard's line and column. Two distinct guards sharing a parameter/suffix remain two inventory entries; inventory exposes primitive provenance alongside the caller site.
3. Simple helper aliases and positional/keyword-only wrapper defaults are bound. Ambiguous aliases, helper escapes and unsupported argument bindings fail explicitly. The implicit `a.typed` default is read from the helper's source AST rather than invented or ignored.
4. R registrations validate the actual local runner callable, test class and method, exact CASES binding, production file and source line. Finite registrations routed through the R runner receive the same checks. The runner reconciles the multiset of registered and attempted/executed bindings by production file, source line, gate, test class and method, rejecting missing, extra and duplicate bindings. Passing still requires every strict deletion result: one source site, green baseline, failures >= 1, errors == 0, and an assertion failure message naming the deleted gate.
5. Deleted files now enter AST-diff faults and force FAIL.

Each requested finding has an independently named counterexample in `test_gate_review_controls.py`. The original eight tests were run before the fixes: all eight failed assertions, zero errors. Additional wrong-source-site and shared-parameter counterexamples were also run red before their respective fixes. Three supplemental tests cover reconciliation mismatches, keyword-only defaults and explicit rejection of escaped aliases.

Verbatim pre-fix counterexample failure headers and final lines:

`red.log`:

```text
FAIL: test_deleted_file_rejected (__main__.ReviewControls.test_deleted_file_rejected)
FAIL: test_distinct_forwarded_guards (__main__.ReviewControls.test_distinct_forwarded_guards)
FAIL: test_helper_alias (__main__.ReviewControls.test_helper_alias)
FAIL: test_lookup_in_label_rejected (__main__.ReviewControls.test_lookup_in_label_rejected)
FAIL: test_stale_open_binding (__main__.ReviewControls.test_stale_open_binding)
FAIL: test_test_lookup_rejected (__main__.ReviewControls.test_test_lookup_rejected)
FAIL: test_unproven_record_rejected (__main__.ReviewControls.test_unproven_record_rejected)
FAIL: test_wrapper_default (__main__.ReviewControls.test_wrapper_default)
----------------------------------------------------------------------
Ran 8 tests in 0.004s

FAILED (failures=8)
```

`red-binding.log`:

```text
FAIL: test_wrong_executable_site_binding (test_gate_review_controls.ReviewControls.test_wrong_executable_site_binding)
----------------------------------------------------------------------
Ran 1 test in 1.907s

FAILED (failures=1)
```

`red-shared.log`:

```text
FAIL: test_shared_label_parameter_rejected (test_gate_review_controls.ReviewControls.test_shared_label_parameter_rejected)
FAIL: test_shared_expected_parameter_rejected (test_gate_review_controls.ReviewControls.test_shared_expected_parameter_rejected)
----------------------------------------------------------------------
Ran 2 tests in 0.006s

FAILED (failures=2)
```

Strict real-diff review: all 143 rejected changes below are classification **(y)**: legitimate gate-name labels/references requiring precise declarations. No rejected change was classification (x), and no production change was reverted. The exact declarations include `classification: "y"`, the before/after text, full source hashes, node hashes, location and rationale. Source-removal selectors remain explicit declarations rather than test-file exemptions. Production expected labels, label assignments, `negative`/`role_owner` arguments and fixture `gate` values remain explicit declarations rather than generic string privileges.

Verbatim first strict AST rejection list (every entry is y):

```text
REJECTED script/evidence/audit605_probes.py:38: 'stake_not_unlocking' -> 'stake_not_unlocking_collect'
REJECTED script/evidence/audit605_probes.py:39: 'stake_not_unlocking' -> 'stake_not_unlocking_build_plan'
REJECTED script/evidence/enduser_mapping_probes.py:148: "    a.need('old_owner_factory_enumeration',switched or bool(enumerated) and set(ROUND_CLONES) <= enumerated,True)\n" -> "    a.need('old_owner_factory_enumeration_discover_targets',switched or bool(enumerated) and set(ROUND_CLONES) <= enumerated,True)\n"
REJECTED script/evidence/enduser_mapping_probes.py:214: 'old_owner_factory_enumeration' -> 'old_owner_factory_enumeration_discover_targets'
REJECTED script/evidence/enduser_mapping_probes.py:215: 'old_owner_factory_enumeration' -> 'old_owner_factory_enumeration_discover_targets'
REJECTED script/evidence/inventory_replay_probes.py:19: "    a.need('old_timelock_replay', actual['approvalOwners'], section['approvalOwners'])\n" -> "    a.need('old_timelock_replay_owners', actual['approvalOwners'], section['approvalOwners'])\n"
REJECTED script/upgrade/manifest_exec.py:2799: 'readback_fraudProofVerifier()' -> 'readback_value_fraudProofVerifier()'
REJECTED script/upgrade/manifest_exec.py:3158: 'C_price_bound' -> 'C_price_bound_exec'
REJECTED script/upgrade/manifest_exec.py:3166: 'C1_cap_headroom' -> 'C1_cap_headroom_exec'
REJECTED script/upgrade/manifest_exec.py:3174: 'C7_enduser_active' -> 'C7_enduser_active_exec'
REJECTED script/upgrade/manifest_exec.py:3175: 'C_account_status' -> 'C_account_status_exec'
REJECTED script/upgrade/old_owner_isolation.py:674: 'old_owner_event_role_' -> 'old_owner_event_role_member_'
REJECTED script/upgrade/old_owner_isolation.py:680: 'old_owner_event_role_' -> 'old_owner_event_role_member_'
REJECTED script/upgrade/old_owner_isolation.py:695: 'old_owner_role_' -> 'old_owner_role_member_declared_'
REJECTED script/upgrade/old_owner_isolation.py:703: 'old_owner_event_role_' -> 'old_owner_event_role_member_'
REJECTED script/upgrade/old_owner_isolation.py:710: 'old_owner_authority_' -> 'old_owner_authority_member_'
REJECTED script/upgrade/old_owner_isolation.py:714: 'old_owner_mapping_' -> 'old_owner_mapping_member_'
REJECTED script/upgrade/old_owner_isolation.py:784: 'old_owner_role_' -> 'old_owner_role_member_configured_'
REJECTED script/upgrade/old_owner_isolation.py:843: 'old_owner_allowance_' -> 'old_owner_allowance_pair_'
REJECTED script/upgrade/old_owner_isolation.py:848: 'old_owner_allowance_' -> 'old_owner_allowance_pair_'
REJECTED script/upgrade/old_owner_isolation.py:1512: "case['gate']" -> "'old_owner_fork_case_' + case['gate']" (AST node type changed)
REJECTED script/upgrade/probe_phase_c_gates.py:34: 'C_price_bound' -> 'C_price_bound_pin'
REJECTED script/upgrade/probe_phase_c_gates.py:35: 'prefix_boundary' -> 'prefix_boundary_phase_c'
REJECTED script/upgrade/probe_phase_c_gates.py:45: 'C_control_slot' -> 'C_control_slot_cached_price'
REJECTED script/upgrade/probe_phase_c_gates.py:66: 'old_timelock_approval_history' -> 'old_timelock_approval_history_creation'
REJECTED script/upgrade/probe_phase_c_gates.py:86: 'old_timelock_replay' -> 'old_timelock_replay_reads'
REJECTED script/upgrade/probe_phase_c_gates.py:87: 'old_timelock_replay' -> 'old_timelock_replay_owners'
REJECTED script/upgrade/probe_phase_c_gates.py:88: 'old_timelock_approval_history' -> 'old_timelock_approval_history_log'
REJECTED script/upgrade/test_authority_checkpoints.py:35: 'old_owner_role_admin_' -> 'old_owner_role_admin_declared_'
REJECTED script/upgrade/test_authority_checkpoints.py:35: 'old_owner_authority_Registry_' -> 'old_owner_authority_member_Registry_'
REJECTED script/upgrade/test_execution_reads.py:126: 'manifest_externalInputs' -> 'manifest_plan_key_externalInputs'
REJECTED script/upgrade/test_manifest_exec.py:1034: 'stage_not_final' -> 'stage_not_final_load_artifact'
REJECTED script/upgrade/test_manifest_exec.py:1613: 'manifest_tx_data' -> 'manifest_tx_field_data'
REJECTED script/upgrade/test_manifest_exec.py:1615: 'manifest_tx_data' -> 'manifest_tx_field_data'
REJECTED script/upgrade/test_manifest_exec.py:2073: 'old_timelock_replay' -> 'old_timelock_replay_reads'
REJECTED script/upgrade/test_manifest_exec.py:2076: 'old_timelock_replay' -> 'old_timelock_replay_owners'
REJECTED script/upgrade/test_manifest_exec.py:2638: 'built_aggregator_version' -> 'built_aggregator_version_release_gate'
REJECTED script/upgrade/test_manifest_exec.py:2639: 'built_aggregator_version' -> 'built_aggregator_version_release_gate'
REJECTED script/upgrade/test_manifest_exec.py:3204: 'evidence_slither_rederived' -> 'evidence_slither_rederived_filename'
REJECTED script/upgrade/test_manifest_exec.py:3206: 'evidence_slither_rederived' -> 'evidence_slither_rederived_filename'
REJECTED script/upgrade/test_manifest_exec.py:3219: 'evidence_slither_rederived' -> 'evidence_slither_rederived_path_containment'
REJECTED script/upgrade/test_manifest_exec.py:3221: 'evidence_slither_rederived' -> 'evidence_slither_rederived_path_containment'
REJECTED script/upgrade/test_manifest_exec.py:3242: 'evidence_scope_recomputed' -> 'evidence_scope_recomputed_validate_evidence_details'
REJECTED script/upgrade/test_manifest_exec.py:3244: 'evidence_scope_recomputed' -> 'evidence_scope_recomputed_validate_evidence_details'
REJECTED script/upgrade/test_manifest_exec.py:3259: 'evidence_scope_recomputed' -> 'evidence_scope_recomputed_validate_evidence_details'
REJECTED script/upgrade/test_manifest_exec.py:3261: 'evidence_scope_recomputed' -> 'evidence_scope_recomputed_validate_evidence_details'
REJECTED script/upgrade/test_manifest_exec.py:3542: 'safe_gap_receipt_identity' -> 'safe_gap_receipt_identity_fields'
REJECTED script/upgrade/test_manifest_exec.py:3548: 'safe_gap_trace_storage' -> 'safe_gap_trace_storage_mapping'
REJECTED script/upgrade/test_manifest_exec.py:3548: 'safe_gap_trace_storage' -> 'safe_gap_trace_storage_key'
REJECTED script/upgrade/test_manifest_exec.py:3549: 'safe_gap_trace_storage' -> 'safe_gap_trace_storage_value'
REJECTED script/upgrade/test_manifest_exec.py:3551: 'safe_gap_miner_balance' -> 'safe_gap_miner_balance_post'
REJECTED script/upgrade/test_manifest_exec.py:3551: 'safe_gap_miner_balance' -> 'safe_gap_miner_balance_delta'
REJECTED script/upgrade/test_manifest_exec.py:3552: 'safe_gap_miner_balance' -> 'safe_gap_miner_balance_delta'
REJECTED script/upgrade/test_manifest_exec.py:3624: 'safe_gap_pin_owners' -> 'safe_gap_pin_owners_pin'
REJECTED script/upgrade/test_manifest_exec.py:3626: 'safe_gap_owner_eoa' -> 'safe_gap_owner_eoa_pin'
REJECTED script/upgrade/test_manifest_exec.py:3628: 'safe_gap_pin_nonce' -> 'safe_gap_pin_nonce_pin'
REJECTED script/upgrade/test_manifest_exec.py:3630: 'safe_gap_pin_threshold' -> 'safe_gap_pin_threshold_pin'
REJECTED script/upgrade/test_manifest_exec.py:3638: 'safe_gap_owner_eoa' -> 'safe_gap_owner_eoa_live'
REJECTED script/upgrade/test_manifest_exec.py:3640: 'safe_gap_owner_eoa' -> 'safe_gap_owner_eoa_live'
REJECTED script/upgrade/test_manifest_exec.py:3664: 'safe_gap_miner_balance' -> 'safe_gap_miner_balance_delta'
REJECTED script/upgrade/test_manifest_exec.py:3709: 'safe_gap_miner_balance' -> 'safe_gap_miner_balance_delta'
REJECTED script/upgrade/test_manifest_exec.py:3815: 'safe_gap_log_data' -> 'safe_gap_log_data_approval'
REJECTED script/upgrade/test_manifest_exec.py:3816: 'safe_gap_log_data' -> 'safe_gap_log_data_swap_execution'
REJECTED script/upgrade/test_manifest_exec.py:3817: 'safe_gap_log_data' -> 'safe_gap_log_data_swap_tail'
REJECTED script/upgrade/test_manifest_exec.py:3836: 'safe_gap_pin_owners' -> 'safe_gap_pin_owners_live'
REJECTED script/upgrade/test_manifest_exec.py:3836: 'safe_gap_pin_threshold' -> 'safe_gap_pin_threshold_live'
REJECTED script/upgrade/test_manifest_exec.py:3837: 'safe_gap_pin_nonce' -> 'safe_gap_pin_nonce_live'
REJECTED script/upgrade/test_manifest_exec.py:3837: 'safe_gap_owner_eoa' -> 'safe_gap_owner_eoa_live'
REJECTED script/upgrade/test_manifest_exec.py:3850: 'safe_gap_hash' -> 'safe_gap_hash_check_governance'
REJECTED script/upgrade/test_manifest_exec.py:3853: 'safe_gap_gas_used' -> 'safe_gap_gas_used_check_governance'
REJECTED script/upgrade/test_manifest_exec.py:3854: 'safe_gap_gas_price' -> 'safe_gap_gas_price_check_governance'
REJECTED script/upgrade/test_manifest_exec.py:3906: 'safe_gap_endpoints' -> 'safe_gap_endpoints_governance_evidence'
REJECTED script/upgrade/test_manifest_exec.py:3908: 'safe_gap_endpoints' -> 'safe_gap_endpoints_governance_evidence'
REJECTED script/upgrade/test_manifest_exec.py:4635: 'stake_not_unlocking' -> 'stake_not_unlocking_build_plan'
REJECTED script/upgrade/test_manifest_exec.py:4651: 'stake_not_unlocking' -> 'stake_not_unlocking_collect'
REJECTED script/upgrade/test_manifest_exec.py:4676: 'stake_not_unlocking' -> 'stake_not_unlocking_collect'
REJECTED script/upgrade/test_manifest_exec.py:5119: 'old_owner_factory_enumeration' -> 'old_owner_factory_enumeration_discover_targets'
REJECTED script/upgrade/test_manifest_phase_c.py:315: 'C_price_bound' -> 'C_price_bound_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:338: 'manifest_phaseC' -> 'manifest_plan_key_phaseC'
REJECTED script/upgrade/test_manifest_phase_c.py:339: 'manifest_phaseC' -> 'manifest_plan_key_phaseC'
REJECTED script/upgrade/test_manifest_phase_c.py:340: 'manifest_tx_value' -> 'manifest_tx_field_value'
REJECTED script/upgrade/test_manifest_phase_c.py:341: 'manifest_tx_data' -> 'manifest_tx_field_data'
REJECTED script/upgrade/test_manifest_phase_c.py:388: 'prefix_boundary' -> 'prefix_boundary_phase_c'
REJECTED script/upgrade/test_manifest_phase_c.py:392: 'prefix_boundary' -> 'prefix_boundary_phase_c'
REJECTED script/upgrade/test_manifest_phase_c.py:405: 'stage_not_final' -> 'stage_not_final_save_artifact'
REJECTED script/upgrade/test_manifest_phase_c.py:559: 'phase_c_account_evidence' -> 'phase_c_account_evidence_bytes'
REJECTED script/upgrade/test_manifest_phase_c.py:565: 'phase_c_measurement' -> 'phase_c_measurement_arms'
REJECTED script/upgrade/test_manifest_phase_c.py:579: 'C1_minter' -> 'C1_minter_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:581: 'C_price_bound' -> 'C_price_bound_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:584: 'C2_operator_role' -> 'C2_operator_role_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:585: 'C3_community' -> 'C3_community_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:586: 'C7_enduser_active' -> 'C7_enduser_active_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:591: 'C5_counterfactual' -> 'C5_counterfactual_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:593: 'C_account_status' -> 'C_account_status_pin'
REJECTED script/upgrade/test_manifest_phase_c.py:594: 'C1_cap_headroom' -> 'C1_cap_headroom_worksheet'
REJECTED script/upgrade/test_manifest_phase_c.py:595: 'C6_gtoken_balance' -> 'C6_gtoken_balance_worksheet'
REJECTED script/upgrade/test_manifest_phase_c.py:660: 'C_price_bound' -> 'C_price_bound_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:662: 'C1_minter' -> 'C1_minter_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:663: 'C1_cap_headroom' -> 'C1_cap_headroom_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:665: 'C2_operator_role' -> 'C2_operator_role_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:668: 'C_operator_before' -> 'C_operator_before_configure'
REJECTED script/upgrade/test_manifest_phase_c.py:670: 'C3_community' -> 'C3_community_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:672: 'C5_counterfactual' -> 'C5_counterfactual_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:674: 'C7_enduser_active' -> 'C7_enduser_active_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:676: 'C_account_status' -> 'C_account_status_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:677: 'C6_gtoken_balance' -> 'C6_gtoken_balance_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:904: 'C_price_bound' -> 'C_price_bound_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:904: 'C1_cap_headroom' -> 'C1_cap_headroom_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:905: 'C7_enduser_active' -> 'C7_enduser_active_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:906: 'C_account_status' -> 'C_account_status_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:928: 'C_price_bound' -> 'C_price_bound_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:930: 'C_price_bound' -> 'C_price_bound_exec'
REJECTED script/upgrade/test_manifest_phase_c.py:947: 'C_control_slot' -> 'C_control_slot_cached_price'
REJECTED script/upgrade/test_old_owner_isolation.py:518: 'old_owner_event_role_Registry' -> 'old_owner_event_role_member_Registry'
REJECTED script/upgrade/test_old_owner_isolation.py:711: 'old_owner_event_role_TimelockController' -> 'old_owner_event_role_member_TimelockController'
REJECTED script/upgrade/test_old_owner_isolation.py:734: 'old_owner_role_TimelockController_PROPOSER_ROLE' -> 'old_owner_role_member_declared_TimelockController_PROPOSER_ROLE'
REJECTED script/upgrade/test_old_owner_isolation.py:735: 'old_owner_authority_SuperPaymaster_pendingOwner' -> 'old_owner_authority_member_SuperPaymaster_pendingOwner'
REJECTED script/upgrade/test_old_owner_isolation.py:736: 'old_owner_mapping_Registry_authorized' -> 'old_owner_mapping_member_Registry_authorized'
REJECTED script/upgrade/test_old_owner_isolation.py:740: 'old_owner_role_admin_ROLE_COMMUNITY' -> 'old_owner_role_admin_declared_ROLE_COMMUNITY'
REJECTED script/upgrade/test_old_owner_isolation.py:743: 'old_owner_authority_' -> 'old_owner_authority_member_'
REJECTED script/upgrade/test_old_owner_isolation.py:745: 'old_owner_mapping_' -> 'old_owner_mapping_member_'
REJECTED script/upgrade/test_old_owner_isolation.py:746: 'old_owner_role_Registry_' -> 'old_owner_role_member_configured_Registry_'
REJECTED script/upgrade/test_old_owner_isolation.py:747: 'old_owner_role_admin_' -> 'old_owner_role_admin_configured_'
REJECTED script/upgrade/test_old_owner_isolation.py:748: 'old_owner_allowance_' -> 'old_owner_allowance_pair_'
REJECTED script/upgrade/test_old_owner_isolation.py:752: 'old_owner_allowance_' -> 'old_owner_allowance_pair_'
REJECTED script/upgrade/test_old_owner_isolation.py:774: 'old_owner_mapping_xPNTsToken_autoApprovedSpenders' -> 'old_owner_mapping_member_xPNTsToken_autoApprovedSpenders'
REJECTED script/upgrade/test_old_owner_isolation.py:776: 'old_owner_mapping_xPNTsToken_autoApprovedSpenders' -> 'old_owner_mapping_member_xPNTsToken_autoApprovedSpenders'
REJECTED script/upgrade/test_old_owner_isolation.py:986: 'unexpected_proxy' -> 'unexpected_proxy_other'
REJECTED script/upgrade/test_old_owner_isolation.py:987: 'unexpected_proxy' -> 'unexpected_proxy_other'
REJECTED script/upgrade/test_old_owner_isolation.py:988: 'unexpected_proxy' -> 'unexpected_proxy_other'
REJECTED script/upgrade/test_old_owner_isolation.py:1389: 'old_owner_deployed_build' -> 'old_owner_deployed_build_launch'
REJECTED script/upgrade/test_old_owner_isolation.py:1390: 'old_owner_deployed_build' -> 'old_owner_deployed_build_launch'
REJECTED script/upgrade/test_old_owner_isolation.py:1391: 'old_owner_deployed_build' -> 'old_owner_deployed_build_launch'
REJECTED script/upgrade/test_old_owner_isolation.py:1559: 'old_owner_mapping_xPNTsToken_approvedFacilitators' -> 'old_owner_mapping_member_xPNTsToken_approvedFacilitators'
REJECTED script/upgrade/test_old_owner_isolation.py:1560: 'old_owner_mapping_xPNTsToken_autoApprovedSpenders' -> 'old_owner_mapping_member_xPNTsToken_autoApprovedSpenders'
REJECTED script/upgrade/test_old_owner_isolation.py:1561: 'old_owner_allowance_' -> 'old_owner_allowance_pair_'
REJECTED script/upgrade/test_old_owner_isolation.py:1649: 'old_owner_calldata_bytes' -> 'old_owner_calldata_bytes_outer_tx'
REJECTED script/upgrade/test_old_owner_isolation.py:1650: 'old_owner_calldata_bytes' -> 'old_owner_calldata_bytes_outer_tx'
REJECTED script/upgrade/test_old_owner_isolation.py:1651: 'old_owner_calldata_bytes' -> 'old_owner_calldata_bytes_outer_tx'
REJECTED script/upgrade/test_old_owner_isolation.py:1663: 'old_owner_calldata_bytes' -> 'old_owner_calldata_bytes_outer_tx'
REJECTED script/upgrade/test_old_owner_isolation.py:1848: 'old_owner_allowance_' -> 'old_owner_allowance_pair_'
GATE_RENAME_AST_DIFF FAIL n_changes=128
REJECTED script/upgrade/old_owner_isolation.py:699: 'old_owner_role_admin_' -> 'old_owner_role_admin_declared_'
REJECTED script/upgrade/old_owner_isolation.py:787: 'old_owner_role_admin_' -> 'old_owner_role_admin_configured_'
GATE_RENAME_AST_DIFF FAIL n_changes=267
```

Newly exposed acceptance blockers (not waived):

- The old inventory counted explicit `a.typed` labels only. Binding its actual omitted default exposes `rpc_result` at the 46 source sites below. A uniqueness PASS would require distinct reviewed labels and corresponding coverage at those sites; silently excluding the default would recreate finding 3. This follow-up preserves the real 6e source diff and reports the collision rather than claiming uniqueness.
- `old_owner_extraction_roles_Registry`, `old_owner_isolation.py:530`, has stale finite-domain metadata claiming `FiniteIsolationTests.test_extra_530_Registry`. That method is deliberately not generated at `test_gate_extra_finite.py:78`; the attempted negative input trips `old_owner_role_init_ids` at production line 344 first. The real-tree target baseline was independently run and is RED by assertion, not error. The existing DSR2 paired/shadow controls are not substituted for a one-site green-baseline proof. No registration or gate was removed to obtain PASS.

Verbatim duplicate inventory:

```text
DUPLICATE_GATE rpc_result sites=46
script/upgrade/manifest_exec.py:293 validate_evidence_details
script/upgrade/manifest_exec.py:306 verifier_executable
script/upgrade/manifest_exec.py:457 fraud_fixture
script/upgrade/manifest_exec.py:458 fraud_fixture
script/upgrade/manifest_exec.py:464 fraud_fixture
script/upgrade/manifest_exec.py:472 fraud_fixture
script/upgrade/manifest_exec.py:474 fraud_fixture
script/upgrade/manifest_exec.py:482 fraud_fixture
script/upgrade/manifest_exec.py:484 fraud_fixture
script/upgrade/manifest_exec.py:510 fraud_fixture
script/upgrade/manifest_exec.py:517 fraud_fixture
script/upgrade/manifest_exec.py:635 validate_external
script/upgrade/manifest_exec.py:643 validate_external
script/upgrade/manifest_exec.py:650 validate_external
script/upgrade/manifest_exec.py:651 validate_external
script/upgrade/manifest_exec.py:664 validate_external
script/upgrade/manifest_exec.py:1110 scan
script/upgrade/manifest_exec.py:1151 call
script/upgrade/manifest_exec.py:1193 old_timelock_holds_nothing
script/upgrade/manifest_exec.py:2119 build_plan
script/upgrade/manifest_exec.py:2131 build_plan
script/upgrade/old_owner_isolation.py:615 call
script/upgrade/old_owner_isolation.py:627 storage
script/upgrade/old_owner_isolation.py:763 audit
script/upgrade/old_owner_isolation.py:764 audit
script/upgrade/old_owner_isolation.py:769 audit
script/upgrade/old_owner_isolation.py:976 clone_implementation
script/upgrade/old_owner_isolation.py:1012 verify_deployment_record
script/upgrade/old_owner_isolation.py:1115 runtime_parity
script/upgrade/old_owner_isolation.py:1116 runtime_parity
script/upgrade/old_owner_isolation.py:1168 deployed_inventory
script/upgrade/old_owner_isolation.py:1169 deployed_inventory
script/upgrade/old_owner_isolation.py:1170 deployed_inventory
script/upgrade/old_owner_isolation.py:1241 validate_deployed
script/upgrade/old_owner_isolation.py:1250 post_upgrade_check
script/upgrade/old_owner_isolation.py:1255 post_upgrade_check
script/upgrade/old_owner_isolation.py:1364 role_history
script/upgrade/old_owner_isolation.py:1367 role_history
script/upgrade/old_owner_isolation.py:1370 role_history
script/upgrade/old_owner_isolation.py:1376 role_history
script/upgrade/old_owner_isolation.py:1377 role_history
script/upgrade/old_owner_isolation.py:1378 role_history
script/upgrade/old_owner_isolation.py:1493 fork_probe
script/upgrade/old_owner_isolation.py:1500 fork_probe
script/upgrade/old_owner_isolation.py:1558 inspect
script/upgrade/old_owner_isolation.py:1591 assert_manifest_calldata
```

Verbatim exhaustive R binding audit (all registrations inspected despite the missing binding):

```text
R_BINDING BLOCKED ["script/upgrade/old_owner_isolation.py", 530, {"file": "script/upgrade/probe_gate_r.py", "function": "run_probes", "gate": "old_owner_extraction_roles_Registry", "test_class": "FiniteIsolationTests", "test_file": "script/upgrade/test_gate_extra_finite.py", "test_method": "test_extra_530_Registry"}, "gate_templates: test binding missing"]
R_BINDING MISSING ('script/upgrade/old_owner_isolation.py', 530, 'old_owner_extraction_roles_Registry', 'FiniteIsolationTests', 'test_extra_530_Registry') count=1
R_BINDING_AUDIT FAIL registered=549 valid=548 executable=548 missing=1 extra=0 invalid=1
```

Verbatim targeted Registry baseline final lines:

```text
----------------------------------------------------------------------
Ran 1 test in 1.318s

FAILED (failures=1)
REGISTRY_BINDING_BASELINE BLOCKED failures=1 errors=0 expected=old_owner_extraction_roles_Registry earlier=old_owner_role_init_ids
```

Accessor-suite integration adjustment: the first runs of `getter_accessor` and `sender_accessor` each failed one assertion (zero errors) because their exact inventory-record expectations omitted the newly exposed primitive source line/column. The assertions were updated to require those fields to equal the production-addition registry's exact line/column. No guard or fingerprint check was relaxed. Both entire accessor suites were rerun; final outcomes follow below.

Verbatim initial accessor failure identities and final lines:

```text
FAIL: test_addition_registry_and_fingerprint (__main__.GetterAccessorTests.test_addition_registry_and_fingerprint)
----------------------------------------------------------------------
Ran 2 tests in 1.773s

FAILED (failures=1)
```

```text
FAIL: test_sender_accessor_registration (__main__.SenderAccessorTests.test_sender_accessor_registration)
----------------------------------------------------------------------
Ran 2 tests in 14.365s

FAILED (failures=1)
```

Final verification for this tooling-review follow-up (foreground, continued through every suite):

Verbatim per-test green counterexample output (the final suite execution is also recorded below):

```text
test_deleted_file_rejected (__main__.ReviewControls.test_deleted_file_rejected) ... ok
test_distinct_forwarded_guards (__main__.ReviewControls.test_distinct_forwarded_guards) ... ok
test_execution_binding_multiset (__main__.ReviewControls.test_execution_binding_multiset) ... ok
test_helper_alias (__main__.ReviewControls.test_helper_alias) ... ok
test_keyword_only_default (__main__.ReviewControls.test_keyword_only_default) ... ok
test_lookup_in_label_rejected (__main__.ReviewControls.test_lookup_in_label_rejected) ... ok
test_shared_expected_parameter_rejected (__main__.ReviewControls.test_shared_expected_parameter_rejected) ... ok
test_shared_label_parameter_rejected (__main__.ReviewControls.test_shared_label_parameter_rejected) ... ok
test_stale_open_binding (__main__.ReviewControls.test_stale_open_binding) ... ok
test_test_lookup_rejected (__main__.ReviewControls.test_test_lookup_rejected) ... ok
test_unproven_record_rejected (__main__.ReviewControls.test_unproven_record_rejected) ... ok
test_unsupported_alias_escape_rejected (__main__.ReviewControls.test_unsupported_alias_escape_rejected) ... ok
test_wrapper_default (__main__.ReviewControls.test_wrapper_default) ... ok
test_wrong_executable_site_binding (__main__.ReviewControls.test_wrong_executable_site_binding) ... ok

----------------------------------------------------------------------
Ran 14 tests in 2.017s

OK
```

One intermediate diagnostic run rejected omitted `a.typed` labels as unsupported and produced four unittest errors. That was not accepted: the analyzer was corrected to bind the source-declared default, exposing the duplicate label instead. Its diagnostic final lines were:

```text
----------------------------------------------------------------------
Ran 27 tests in 0.788s

FAILED (errors=4)
```

`python3 -B script/upgrade/gate_rename_ast_diff.py 2acc71af WORKTREE` — exit 0:

```text
ALLOWED script/upgrade/test_old_owner_isolation.py:1650 REVIEWED_GATE_REFERENCE 'old_owner_calldata_bytes' -> 'old_owner_calldata_bytes_outer_tx'
ALLOWED script/upgrade/test_old_owner_isolation.py:1651 REVIEWED_GATE_REFERENCE 'old_owner_calldata_bytes' -> 'old_owner_calldata_bytes_outer_tx'
ALLOWED script/upgrade/test_old_owner_isolation.py:1663 REVIEWED_GATE_REFERENCE 'old_owner_calldata_bytes' -> 'old_owner_calldata_bytes_outer_tx'
ALLOWED script/upgrade/test_old_owner_isolation.py:1848 REVIEWED_GATE_REFERENCE 'old_owner_allowance_' -> 'old_owner_allowance_pair_'
GATE_RENAME_AST_DIFF PASS n_changes=269
```

`python3 -B script/upgrade/probe_gate_names.py` — exit 0:

```text
Ran 3 tests in 0.001s
OK
Ran 3 tests in 0.001s
FAILED (failures=3)
Ran 1 test in 12.776s
OK
Ran 1 test in 1.625s
Ran 1 test in 1.549s
OK
Ran 1 test in 1.645s
Ran 1 test in 1.556s
OK
Ran 1 test in 1.632s
Ran 1 test in 1.596s
OK
Ran 1 test in 1.585s
Ran 1 test in 1.616s
OK
Ran 1 test in 1.619s
Ran 1 test in 1.671s
OK
Ran 1 test in 1.678s
Ran 1 test in 1.613s
OK
Ran 1 test in 1.670s
Ran 1 test in 1.542s
OK
Ran 1 test in 1.546s
Ran 1 test in 1.577s
OK
Ran 1 test in 1.563s

FAILED (failures=1)
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

`python3 -B script/upgrade/test_old_owner_isolation.py` — exit 0:

```text
Ran 143 tests in 41.317s
OK (skipped=2)
L1_CONTROL old_owner_implementation removed=assertion-failure errors=0
L1_CONTROL old_owner_creation_before removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0
```

`python3 -B script/upgrade/test_manifest_exec.py` — exit 0:

```text
Ran 535 tests in 462.319s
OK (skipped=2)
L1_CONTROL old_owner_implementation removed=assertion-failure errors=0
L1_CONTROL old_owner_creation_before removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0
```

`python3 -B script/upgrade/test_manifest_phase_c.py` — exit 0:

```text
..............
----------------------------------------------------------------------
Ran 141 tests in 200.427s

OK
```

`python3 -B script/a3a/test_a3a_exec.py` — exit 0:

```text

----------------------------------------------------------------------
Ran 102 tests in 3.024s

OK
```

`python3 -B script/a3a/test_a3a_send.py` — exit 0:

```text
...................................
----------------------------------------------------------------------
Ran 73 tests in 31.276s

OK
```

`python3 -B script/upgrade/test_sp_upgrade_exec.py` — exit 0:

```text

----------------------------------------------------------------------
Ran 141 tests in 1.441s

OK
```

`python3 -B script/upgrade/test_authority_checkpoints.py` — exit 0:

```text
..........
----------------------------------------------------------------------
Ran 10 tests in 17.781s

OK
```

`python3 -B script/upgrade/test_swallow_exceptions.py` — exit 0:

```text
.........
----------------------------------------------------------------------
Ran 9 tests in 2.669s

OK
```

`python3 -B script/upgrade/test_execution_head.py` — exit 0:

```text
......
----------------------------------------------------------------------
Ran 6 tests in 0.867s

OK
```

`python3 -B script/upgrade/test_execution_reads.py` — exit 0:

```text
..........
----------------------------------------------------------------------
Ran 10 tests in 0.088s

OK
```

`python3 -B script/upgrade/test_gate_names.py` — exit 1:

```text

----------------------------------------------------------------------
Ran 27 tests in 23.500s

FAILED (failures=3)
```

Verbatim failing test identities:

```text
FAIL: test_dynamic_templates_registered (__main__.GateNameTests.test_dynamic_templates_registered)
FAIL: test_literal_names_unique (__main__.GateNameTests.test_literal_names_unique)
FAIL: test_registered_finite_templates_labels_and_probes (__main__.GateNameTests.test_registered_finite_templates_labels_and_probes)
```

`python3 -B script/upgrade/test_gate_rename_controls.py` — exit 0:

```text
Ran 5 tests in 6.299s

OK
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0
```

`python3 -B script/upgrade/test_gate_template_controls.py` — exit 0:

```text
...........................................................................................................................................................................
----------------------------------------------------------------------
Ran 171 tests in 203.595s

OK
```

`python3 -B script/upgrade/test_gate_dsr2.py` — exit 0:

```text
..................
----------------------------------------------------------------------
Ran 18 tests in 33.726s

OK
```

`python3 -B script/upgrade/test_gate_empty_schema.py` — exit 0:

```text
....
----------------------------------------------------------------------
Ran 4 tests in 0.003s

OK
```

`python3 -B script/upgrade/test_gate_extra_finite.py` — exit 0:

```text
.......................................................
----------------------------------------------------------------------
Ran 55 tests in 4.248s

OK
```

`python3 -B script/upgrade/test_gate_review_controls.py` — exit 0:

```text
..............
----------------------------------------------------------------------
Ran 14 tests in 1.891s

OK
```

`python3 -B script/upgrade/test_gate_r_controls.py` — exit 0:

```text
................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................................
----------------------------------------------------------------------
Ran 608 tests in 170.462s

OK
```

`python3 -B script/upgrade/test_getter_accessor.py` — exit 0:

```text
..
----------------------------------------------------------------------
Ran 2 tests in 4.727s

OK
```

`python3 -B script/upgrade/test_sender_accessor.py` — exit 0:

```text
..
----------------------------------------------------------------------
Ran 2 tests in 25.649s

OK
```

This is **not acceptance of COMMIT 6e uniqueness/coverage**. AST and focused deletion probes pass; gate_names remains failed on the two documented root causes (duplicate default label and nonexistent registered executable binding). All other requested/extra suites were still run. No unittest ERROR is accepted as a deletion success. No production gate was deleted, no commit was made, and the incoming production source changes were retained.

```text
COMMIT6E_TOOLING_REVIEW_RESULT BLOCKED requested_findings_fixed=5 counterexamples_red_then_green=11 supplemental_tests=3 ast_diff=PASS gate_name_probes=PASS suites_passed=19/20 duplicate_default_sites=46 missing_probe_bindings=1 errors_accepted=0
```

Final worktree/process verification (verbatim):

```text
2acc71afb62b23e72a5c610522be0e21dc87e119
ASSERT_STOP_UNCHANGED catches=a.Gate
INDEX_UNCHANGED staged_files=0
GIT_DIFF_CHECK PASS
LAUNCHED_FOREGROUND_SESSIONS remaining=0
PROCESS_TABLE_UNAVAILABLE ps rejected by filesystem sandbox (PermissionError: Operation not permitted)
```

All launched foreground sessions were waited to completion; no background command was started or left running. A global process-table scan was unavailable because the sandbox rejected `ps`; no escalation was attempted. Temporary gate mutations were confined to copied ASTs or context-managed temporary trees. `/tmp/commit6e-review` retains logs and orchestration scripts, not a mutated production tree.


### 6e non-zero sender fixture continuation (2026-11-07)

Scope: preserve HEAD `2acc71af` and the incoming uncommitted 6e diff; no
commit, RPC, environment-file, keystore, or chain access. Only test fixtures,
the bounded sender probe selection, and this report changed in this continuation.
Production constants, predicates, and `assert_stop` were not changed.

The old zero-address fixture classification is superseded. Each replacement
address is valid lowercase hex but non-canonical for the approved sender role:

| Role | Exact input X |
|---|---|
| deployer | `0x0000000000000000000000000000000000d5a201` |
| approver | `0x0000000000000000000000000000000000d5a202` |
| executor | `0x0000000000000000000000000000000000d5a203` |

The fixture asserts X is non-zero and absent from the original pin, inputs,
artifact identities, and string constants in `a` (including all `a.SENDERS`
values represented in the pin). The three X values are distinct.

Rebuilt evidence fields, test-only:

- `pin.senders[role].address` becomes X.
- Every matching `a3aPlan.steps[*].tx.from` and corresponding
  `pin.a3aHistory[step.id].transaction.from` becomes X. Step IDs, nonces,
  receipt hashes, block identities, status, and nonce-range boundaries remain
  self-consistent and unchanged. The plan has no nonce gaps, and the fixture
  asserts both plan/spec gap lists and `a3aGapReads` are empty.
- `inputs.data.a3aPlan.path` and `.sha256` are rebuilt from the rewritten
  reviewed plan; the external input JSON and `inputs.sha256` are rebuilt via
  `m.external`.
- For deployer only, the old deployer's `operatorBalances` entry becomes zero
  and its amount is added to the existing `anni` entry. Inventory keys and
  `totalTrackedBalance` remain unchanged. This passes `drain_senders` after U
  is removed without changing any production authorization.

`validate_nonce_history` runs on the rebuilt fixture, followed by `build_plan`.
Real-tree b3 requires exactly `sender_identity` at U:735, proving E M:1822,
accessor #21 M:1823, and all preceding gates passed. Temporary copies delete
only U for b1 and then the single T statement M:2155 for b2. E and #21 remain
intact throughout. The first deployer attempt exposed `drain_senders` after U;
that result was not accepted, and its log is retained at
`/tmp/commit6e-sender-final/senders-initial.log`. The final corrected fixture
preserves the balance sum as described above.

Final sender probe command: `python3 -B script/upgrade/probe_gate_dsr2.py --senders` (exit 0). No full probe-driver batch was run. Verbatim final result lines:

```text
DSR2_PAIR sender_deployer PASS E=sender_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E b1_failures=1 b1_errors=0 b1_named=True failures=1 errors=0 named=True
DSR2_PAIR sender_approver PASS E=sender_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E b1_failures=1 b1_errors=0 b1_named=True failures=1 errors=0 named=True
DSR2_PAIR sender_executor PASS E=sender_identity source_sites=1 E_sites=1 baseline=green b1=exact_T b3=exact_E b1_failures=1 b1_errors=0 b1_named=True failures=1 errors=0 named=True
DSR2_AGGREGATE accepted=18/18 preserved_accepted=15 rerun=3 blocked=0 errors_accepted=0
```

After U + T deletion, `sender_deployer` produced `AssertionError: 'drain_operator_present_deployer' != 'sender_deployer'` (one FAIL, zero ERROR).

After U + T deletion, `sender_approver` produced `AssertionError: sender_approver: Gate not raised` (one FAIL, zero ERROR).

After U + T deletion, `sender_executor` produced `AssertionError: sender_executor: Gate not raised` (one FAIL, zero ERROR).


#### Final foreground verification for the non-zero sender continuation

All 22 commands completed; the final-state AST recheck also completed. No full probe-driver batch ran. Logs: `/tmp/commit6e-sender-final/`.

`python3 -B script/upgrade/gate_rename_ast_diff.py 2acc71af WORKTREE` — exit 0:

```text
GATE_RENAME_AST_DIFF PASS n_changes=269
```

`python3 -B script/upgrade/probe_gate_names.py` — exit 0:

```text
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

`python3 -B script/upgrade/test_old_owner_isolation.py` — exit 0:

```text
Ran 143 tests in 43.120s

OK (skipped=2)
L1_CONTROL old_owner_calldata_payload removed=assertion-failure errors=0
L1_CONTROL old_owner_endpoint_distinct removed=assertion-failure errors=0
L1_CONTROL old_owner_endpoint_distinct removed=assertion-failure errors=0
L1_CONTROL old_owner_uncancelled_grants removed=assertion-failure errors=0
L1_CONTROL old_owner_role_extraction_empty removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_address removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_removed removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_topic removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_canonical removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_range removed=assertion-failure errors=0
L1_CONTROL old_owner_fallback_canonical removed=assertion-failure errors=0
L1_CONTROL old_owner_module_page removed=assertion-failure errors=0
L1_CONTROL old_owner_implementation removed=assertion-failure errors=0
L1_CONTROL old_owner_creation_before removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0
```

`python3 -B script/upgrade/test_manifest_exec.py` — exit 0:

```text
Ran 535 tests in 552.106s

OK (skipped=2)
L1_CONTROL old_owner_calldata_bytes_outer_tx removed=assertion-failure errors=0
L1_CONTROL old_owner_source_claim removed=assertion-failure errors=0
L1_CONTROL old_owner_calldata_bytes_outer_tx removed=assertion-failure errors=0
L1_CONTROL old_owner_calldata_target removed=assertion-failure errors=0
L1_CONTROL old_owner_calldata_target removed=assertion-failure errors=0
L1_CONTROL old_owner_calldata_payload removed=assertion-failure errors=0
L1_CONTROL old_owner_endpoint_distinct removed=assertion-failure errors=0
L1_CONTROL old_owner_endpoint_distinct removed=assertion-failure errors=0
L1_CONTROL old_owner_uncancelled_grants removed=assertion-failure errors=0
L1_CONTROL old_owner_role_extraction_empty removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_address removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_removed removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_topic removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_canonical removed=assertion-failure errors=0
L1_CONTROL old_owner_role_log_range removed=assertion-failure errors=0
L1_CONTROL old_owner_fallback_canonical removed=assertion-failure errors=0
L1_CONTROL old_owner_module_page removed=assertion-failure errors=0
L1_CONTROL old_owner_implementation removed=assertion-failure errors=0
L1_CONTROL old_owner_creation_before removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0
```

`python3 -B script/upgrade/test_manifest_phase_c.py` — exit 0:

```text
Ran 141 tests in 241.032s

OK
```

`python3 -B script/a3a/test_a3a_exec.py` — exit 0:

```text
Ran 102 tests in 3.183s

OK
```

`python3 -B script/a3a/test_a3a_send.py` — exit 0:

```text
Ran 73 tests in 32.272s

OK
```

`python3 -B script/upgrade/test_sp_upgrade_exec.py` — exit 0:

```text
Ran 141 tests in 1.629s

OK
```

`python3 -B script/upgrade/test_authority_checkpoints.py` — exit 0:

```text
Ran 10 tests in 19.026s

OK
```

`python3 -B script/upgrade/test_swallow_exceptions.py` — exit 0:

```text
Ran 9 tests in 2.819s

OK
```

`python3 -B script/upgrade/test_execution_head.py` — exit 0:

```text
Ran 6 tests in 1.043s

OK
```

`python3 -B script/upgrade/test_execution_reads.py` — exit 0:

```text
Ran 10 tests in 0.097s

OK
```

`python3 -B script/upgrade/test_gate_names.py` — exit 1:

```text
Ran 27 tests in 25.869s

FAILED (failures=3)
```

`python3 -B script/upgrade/test_gate_rename_controls.py` — exit 0:

```text
Ran 5 tests in 7.863s

OK
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0
```

`python3 -B script/upgrade/test_gate_template_controls.py` — exit 0:

```text
Ran 171 tests in 254.928s

OK
```

`python3 -B script/upgrade/test_gate_dsr2.py` — exit 0:

```text
Ran 18 tests in 36.302s

OK
```

`python3 -B script/upgrade/test_gate_empty_schema.py` — exit 0:

```text
Ran 4 tests in 0.006s

OK
```

`python3 -B script/upgrade/test_gate_extra_finite.py` — exit 0:

```text
Ran 55 tests in 4.739s

OK
```

`python3 -B script/upgrade/test_gate_review_controls.py` — exit 0:

```text
Ran 14 tests in 2.132s

OK
```

`python3 -B script/upgrade/test_gate_r_controls.py` — exit 0:

```text
Ran 608 tests in 186.918s

OK
```

`python3 -B script/upgrade/test_getter_accessor.py` — exit 0:

```text
Ran 2 tests in 5.121s

OK
```

`python3 -B script/upgrade/test_sender_accessor.py` — exit 0:

```text
Ran 2 tests in 24.938s

OK
```

The gate-name suite remains BLOCKED, with three assertion failures and zero errors. Two registration assertions fail because `gate_templates.json` registers `FiniteIsolationTests.test_extra_530_Registry` for `old_owner_extraction_roles_Registry` at O:530, while `test_gate_extra_finite.py:78` explicitly skips `(530, 'Registry')`. The uniqueness assertion reports one repeated label, `rpc_result`, at 46 source sites where the actual `a.typed` default is used (21 in manifest_exec.py and 25 in old_owner_isolation.py). The detailed site inventory is preserved in the preceding tooling-review section and the current test_gate_names.log. These were not treated as passing coverage or hidden by weakening the checker. All later suites completed despite the failures.

Verbatim failing test identities:

```text
FAIL: test_dynamic_templates_registered (__main__.GateNameTests.test_dynamic_templates_registered)
FAIL: test_literal_names_unique (__main__.GateNameTests.test_literal_names_unique)
FAIL: test_registered_finite_templates_labels_and_probes (__main__.GateNameTests.test_registered_finite_templates_labels_and_probes)
```

```text
COMMIT6E_SENDER_RESULT DSR2=18/18 sender_pairs=3/3 ast_diff=PASS gate_name_probes=PASS suites_passed=19/20 gate_names=BLOCKED failures=3 errors=0 errors_accepted=0
```

Final verification (verbatim):

```text
HEAD_UNCHANGED 2acc71afb62b23e72a5c610522be0e21dc87e119
ASSERT_STOP_UNCHANGED catches=a.Gate
INDEX_UNCHANGED staged_files=0
GIT_DIFF_CHECK PASS
LAUNCHED_FOREGROUND_SESSIONS remaining=0
```

All launched command sessions were collected to exit 0, including the orchestration runner (whose individual gate_names exit 1 is explicitly recorded above). No background command was launched. Sender mutation trees were context-managed temporary copies and were removed on completion. No production gate was deleted in the real worktree. No commit was made.


### DSR 8a900e9c continuation — required typed gates and declaration integrity

The existing 6e diff was preserved on HEAD `2acc71afb62b23e72a5c610522be0e21dc87e119`.
No commit, RPC connection, environment-file read, keystore access, or chain operation was made.
Only named offline suites and focused probes were invoked; the full probe-driver batch was not run.

The AST inventory covers tracked and untracked Python files and follows module aliases,
imported-function aliases, and assigned aliases. It finds 120 actual `typed` call sites:
88 formerly defaulted calls now have unique literal `gate=` keywords, while the 32
already explicit calls retain their gate names. The 88 sites comprise 25 in `a3a_exec`,
2 in `a3a_send`, 21 in `manifest_exec`, 25 in `old_owner_isolation`, and 15 in
`sp_upgrade_exec`. `typed` has no default gate parameter. The new names participate
in uniqueness and prefix-disjointness checks. Negative controls require a missing
argument to raise `TypeError` and the uniqueness inventory to reject missing gates,
including calls through aliases. The negative runtime test deliberately uses `getattr`
to call without the required argument; it is not a production gate site.

`gate_typed_changes.json` declares each of the 88 added keywords individually, with
file, function, line, column, gate, and AST fingerprint. The required-parameter signature
change has its own exact before/after fingerprint declaration. There is no blanket
keyword exemption. Test instrumentation uses tracing/profiling rather than an additional
forwarding call to `typed`.

All 143 `(y)` reference declarations are retained. Reference, structural, signature,
keyword, production-addition, and rename-map declarations are checked for use; fingerprint,
source, or location mismatches cannot silently fall through to ordinary rename acceptance.
The stronger checker exposed one stale map entry: the old `autoApprovedSpenders` name
incorrectly mapped to the `approvedFacilitators` reference at O-test:1559. That unused
entry was removed, and two `test_placeholder` function metadata values were corrected
to `test_named_clones_storage_authority_controls`. No gate registration was removed.
Reviewed finite-domain digests were rebound only after stripping the new keywords
(and restoring the old signature for the dependency check) reproduced the previous digests.

The O:530 Registry registration now binds `test_gate_dsr2.RegistryShadowTests` shadow
and target methods to the existing DSR2 pair runner, including the exact earlier gate
`old_owner_role_init_ids`. The validator checks source file, line, gate, class, both methods,
runner function, and earlier gate. Wrong bindings remain rejected.

The RPC probes use temporary script-tree copies plus the three existing offline JSON
fixtures needed by the A3a and upgrade suites. Final probes inject malformed values through
original function inputs or immediate RPC/cast return boundaries, so every later read sees
the malformed value. Field reads are not independently overwritten after earlier validation.
The mutant removes only the selected `typed` call. `assert_stop` is unchanged and accepts
only `a.Gate`. Acceptance requires one source site, a green exact-Gate baseline, at least
one failure, zero errors, and a failure message naming the deleted gate. The mutation helper
refuses paths inside the real worktree. Earlier schema/fixed-value stops are blockers, not passes.

An initial diagnostic attempted argument-boundary substitution, which could bypass earlier
checks of the same value. That diagnostic was rejected, interrupted (exit 130), and none of
its apparent passes count below. The corrected sweep retained completed per-site records;
its slow candidate searches were interrupted (exit 130) and resumed at the first
unfinished site with real malformed-provider fixtures. This was a harness replacement, not
a stop threshold: every remaining site was processed. All mutation trees are context-managed.

Deployed-inventory mutants exposed a missing fixture dependency: provenance reads used
`git show` inside the temporary tree, which initially had no Git history. Those ERROR
results were rejected. The focused retry uses a local, checkout-free repository copy
(`git clone --local --no-hardlinks --no-checkout`) with the script sources overlaid.
Git provenance gates remain intact and read from the temporary repository. The first
clone attempt used hardlinks, which the sandbox rejected; the retry copies objects.
No source redirection, production fallback, network clone, or commit was used.

The first combined suite-discovery process exited 129 during the sender PTY test. The sender
suite and remaining suites were rerun as isolated foreground child processes. Strengthened
unused-declaration checks initially rejected the getter/sender synthetic accessor comparisons
because they loaded unrelated real-tree declarations. Those synthetic fixtures now load only
their exact relevant production-addition declaration; the complete real-tree comparator still
checks every declaration. Both accessor suites passed on rerun. No ERROR was accepted as a
successful gate probe or suite result.

Real declared-location counterexamples (temporary metadata/source only): changing the
`case['gate']` lookup key at O:1512 while rebinding only the source digest leaves its node
fingerprint mismatched and must fail; adding an unused declaration must also fail.
Verbatim output:

```text
REJECTED script/upgrade/old_owner_isolation.py: declaration fingerprint/location mismatch script/upgrade/old_owner_isolation.py.body[82].body[5].body[2].body[8].body[0].handlers[0].body[0].value.args[2]
REJECTED script/upgrade/old_owner_isolation.py: stale/unused or mismatched reference declaration script/upgrade/old_owner_isolation.py.body[82].body[5].body[2].body[8].body[0].handlers[0].body[0].value.args[2]
REJECTED script/upgrade/old_owner_isolation.py: stale/unused or mismatched mapping declaration {'new': "'old_owner_fork_case_' + case['gate']", 'file': 'script/upgrade/old_owner_isolation.py', 'function': 'fork_probe', 'line': 1512, 'kind': 'prefix_expression', 'reason': 'Disjointness wins: fork STOP definition must not reuse caller gate namespaces.'}
GATE_RENAME_AST_DIFF FAIL counterexample=declared_lookup_key
REJECTED script/upgrade/old_owner_isolation.py: stale/unused or mismatched reference declaration script/upgrade/old_owner_isolation.py.body[82].body[5].body[2].body[8].body[0].handlers[0].body[0].value.args[2].unused
GATE_RENAME_AST_DIFF FAIL counterexample=stale_declaration
GATE_DECLARATION_COUNTEREXAMPLES PASS baseline=green lookup=red stale=red
```

Focused verification final lines (verbatim):

```text
REGISTRY_DSR2_PAIR PASS sites=1 earlier_sites=1 baseline=green shadow=green failures=1 errors=0 named=True
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
GATE_RENAME_CONTROL safe_gap_log_transactionIndex_typed PASS baseline=green sites=1
GATE_RENAME_CONTROL unexpected_proxy_other PASS baseline=green sites=1
GATE_RENAME_CONTROL unexpected_proxy_beacon PASS baseline=green sites=1
GATE_RENAME_CONTROL old_owner_calldata_bytes_outer_tx PASS baseline=green sites=1
GATE_RENAME_CONTROL old_owner_calldata_bytes_payload PASS baseline=green sites=1
GATE_RENAME_CONTROLS PASS 5/5 strict red
```

Final DSR verification results

The final RPC evidence is in `gate_typed_probe_results.json`: 88 individually located
source sites, 69 strict deletion passes, and 19 blockers. Eleven blockers have a real
malformed-input fixture proving an earlier named gate stops first; eight have no
established independent malformed-input fixture. The latter are not claims of
unreachability. None are passes. Every site was processed; there was no global stop
threshold. `validate_external_key` also has green shadow controls for `fixed_dvt`
and `fixed_committee`, in addition to the probed `fixed_anni` input.

Each accepted record retains its exact fixture, green baseline log, mutant log, and
verbatim final line. Blocked records retain their baseline diagnostics or the exact
missing fixture boundary. The initial argument-injection diagnostic is excluded.
The local-history retries supersede the three deployed-inventory ERROR results.

Precise remaining blockers:

| Site | Gate | Reason |
| --- | --- | --- |
| `script/a3a/a3a_exec.py:668:33` | `rpc_result_rebuild_artifacts_object` | No independent malformed current-artifact fixture was established through the intact rebuild_head, pinned Forge-version, compile_commit, and committed-config path; argument substitution after these checks is prohibited. |
| `script/a3a/a3a_exec.py:669:34` | `rpc_result_rebuild_artifacts_object_2` | No independent malformed rebuilt-artifact fixture was established through compile_commit and its artifact validation; replacing the field after that producer would bypass earlier checks. |
| `script/a3a/a3a_exec.py:1525:30` | `rpc_result_scheduled_eta_data` | No independent malformed log-data fixture was established through find_step_schedule while preserving its schedule/receipt binding and the earlier schedule metadata checks. |
| `script/upgrade/manifest_exec.py:457:43` | `rpc_result_fraud_fixture_key` | Malformed original input stops first at fraud_schema_pattern_fixture.export.aggregator; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:458:51` | `rpc_result_fraud_fixture_key_2` | Malformed original input stops first at fraud_schema_pattern_fixture.export.domainSeparator; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:464:26` | `rpc_result_fraud_fixture_who` | Malformed original input stops first at fraud_schema_pattern_fixture.export.valid.guiltyGuardians.0; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:472:4` | `rpc_result_fraud_fixture_fraudProof` | Malformed original input stops first at fraud_schema_pattern_fixture.export.valid.fraudProof; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:474:4` | `rpc_result_fraud_fixture_address` | Malformed original input stops first at fraud_schema_pattern_fixture.export.forkState.token.address; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:482:4` | `rpc_result_fraud_fixture_address_2` | Malformed original input stops first at fraud_schema_pattern_fixture.export.forkState.token.address; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:484:4` | `rpc_result_fraud_fixture_runtime` | Malformed original input stops first at fraud_schema_pattern_fixture.export.forkState.token.runtimeBytecode; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:510:4` | `rpc_result_fraud_fixture_fraudProof_2` | Malformed original input stops first at fraud_schema_pattern_fixture.export.mustReject.2.fraudProof; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:517:4` | `rpc_result_fraud_fixture_domainDigest` | Malformed original input stops first at fraud_schema_pattern_fixture.export.mustReject.3.domainDigest; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:643:8` | `rpc_result_validate_external_key` | Malformed original input stops first at fixed_anni; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/manifest_exec.py:664:8` | `rpc_result_validate_external_who` | Malformed original input stops first at sampled_deployer_only; exact-target baseline is red, so deletion cannot be accepted. |
| `script/upgrade/old_owner_isolation.py:1012:4` | `rpc_result_verify_deployment_record_txHash` | No standalone malformed txHash fixture was established with a committed deployment record, matching source commit and address. The local-history retry fixes fixture availability but does not itself prove this site. |
| `script/upgrade/old_owner_isolation.py:1241:8` | `rpc_result_validate_deployed_identity` | No malformed endpoint-identity fixture was established with complete sourceReads/sourceSelection replay and intact endpoint-identity checks. |
| `script/upgrade/old_owner_isolation.py:1250:4` | `rpc_result_post_upgrade_check_stateBlock` | No independent malformed stateBlock fixture was established for the complete release post-upgrade path; existing discovery reached this site only with valid input. No deletion probe is claimed. |
| `script/upgrade/old_owner_isolation.py:1255:12` | `rpc_result_post_upgrade_check_target` | No independent malformed release-target fixture was established for the complete release post-upgrade path; existing discovery reached this site only with valid input. No deletion probe is claimed. |
| `script/upgrade/old_owner_isolation.py:1558:8` | `rpc_result_inspect_data` | No malformed decoded nested-call fixture was established: outer tx data is typed before inspect, explicit payload children pass old_owner_calldata_payload_shape, and no independent malformed recursive decoded-value route was demonstrated. |

Final lines for all 88 RPC sites, followed by the merged aggregate (verbatim):

```text
RPC_RESULT_PROBE rpc_result_qty_value PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_keccak_keccak PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_rpc_keccak_web3_sha3 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_rpc_keccak_data PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_verify_runtime_artifactRuntime PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_verify_runtime_code PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_calldata_calldata PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_call_eth_call PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_block_data_hash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_artifact_sources_keccak256 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_cbor_tail_code PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_rebuild_artifacts_object BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for current[field]['object'] in rebuild_artifacts; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_rebuild_artifacts_object_2 BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for fresh[field]['object'] in rebuild_artifacts; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_safe_extensions_eth_getStorageAt PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_preflight_eth_getCode PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_receipt_eth_sendTransaction PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_roles_readback_1 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_roles_readback_2 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_roles_readback_3 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_pin_blockHash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_gaps_hash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_check_gaps_eth_getCode PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_scheduled_eta_data BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for log['data'] in scheduled_eta; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_pre_send_eth_getCode PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_require_deployed_eth_getCode PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_local_keccak_value PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_check_signed_hash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_evidence_details_value PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_verifier_executable_code PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_fraud_fixture_key BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_key_2 BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_who BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_fraudProof BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_address BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_address_2 BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_runtime BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_fraudProof_2 BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_fraud_fixture_domainDigest BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_validate_external_sid PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_external_key BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_validate_external_validator PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_external_calldata PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_external_who BLOCKED sites=1 candidates=1 attempts=1 reason=real fixture failed exact-target baseline or strict deletion criterion; see per-attempt logs
RPC_RESULT_PROBE rpc_result_scan_blockNumber PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_call_eth_call_2 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_old_timelock_holds_nothing_1 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_build_plan_value PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_build_plan_code PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_call_eth_call_3 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_storage_eth_getStorageAt PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_audit_1 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_audit_blockNumber PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_audit_blockHash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_clone_implementation_code PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_verify_deployment_record_txHash BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for ref['txHash'] in verify_deployment_record; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_runtime_parity_code PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_runtime_parity_object PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_deployed_inventory_eth_getCode PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_deployed_inventory_eth_getStorageAt PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_deployed_inventory_eth_getStorageAt_2 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_deployed_identity BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for identity in validate_deployed; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_post_upgrade_check_stateBlock BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for pin['stateBlock'] in post_upgrade_check; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_post_upgrade_check_target BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for target in post_upgrade_check; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_role_history_data PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_role_history_topic PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_role_history_blockNumber PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_role_history_transactionHash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_role_history_transactionIndex PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_role_history_logIndex PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_fork_probe_raw PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_fork_probe_raw_2 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_inspect_data BLOCKED sites=1 candidates=0 attempts=0 reason=no independent malformed original-input fixture for data in inspect; field-boundary injection prohibited
RPC_RESULT_PROBE rpc_result_assert_manifest_calldata_data PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_uints_raw PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_code_eth_getCode PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_scan_blockHash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_scan_transactionHash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_inventory_2 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_inventory_1 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_safe_state_eth_getStorageAt PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_pending_operations_1 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_initial_guardian_eth_getStorageAt PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_gas_transactionHash PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_admission_gas_data PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_pin_field PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_pin_who PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_pin_who_2 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBE rpc_result_validate_pin_who_3 PASS sites=1 baseline=green failures=1 errors=0 named=True
RPC_RESULT_PROBES passed=69 total=88 blocked=19 errors_accepted=0
```

All requested suites and all new test files ran in the foreground. Four existing
opt-in tests were skipped; no skipped test was used as a passing deletion probe.
Production sources did not change between the full suite runs and the final focused
checks. Final suite summary lines (verbatim):

```text
test_old_owner_isolation
Ran 143 tests in 99.896s
OK (skipped=2)

test_manifest_exec
Ran 535 tests in 577.144s
OK (skipped=2)

test_manifest_phase_c
Ran 141 tests in 207.760s
OK

test_a3a_exec
Ran 102 tests in 4.143s
OK

test_a3a_send
Ran 73 tests in 31.772s
OK

test_sp_upgrade_exec
Ran 141 tests in 1.797s
OK

test_authority_checkpoints
Ran 10 tests in 25.185s
OK

test_swallow_exceptions
Ran 9 tests in 6.792s
OK

test_execution_head
Ran 6 tests in 0.920s
OK

test_execution_reads
Ran 10 tests in 0.102s
OK

test_gate_names
Ran 27 tests in 57.677s
OK

test_gate_rename_controls
Ran 5 tests in 7.115s
OK

test_gate_template_controls
Ran 171 tests in 264.830s
OK

test_gate_dsr2
Ran 18 tests in 42.801s
OK

test_gate_empty_schema
Ran 4 tests in 0.006s
OK

test_gate_extra_finite
Ran 55 tests in 7.396s
OK

test_gate_review_controls
Ran 14 tests in 2.562s
OK

test_gate_r_controls
Ran 608 tests in 250.059s
OK

test_getter_accessor
Ran 2 tests in 15.856s
OK

test_sender_accessor
Ran 2 tests in 46.979s
OK

test_gate_typed_controls
Ran 5 tests in 3.616s
OK

test_gate_declaration_controls
Ran 8 tests in 0.048s
OK

test_gate_typed_boundaries
Ran 14 tests in 0.003s
OK

test_gate_typed_fields
Ran 30 tests in 21.534s
OK

test_gate_typed_shadow_controls
Ran 12 tests in 30.303s
OK

test_gate_typed_log_fields
Ran 18 tests in 14.703s
OK

OFFLINE_SUITES PASS suites=26 tests=2163 failures=0 errors=0
```

Final checker and workspace lines (verbatim):

```text
GATE_RENAME_AST_DIFF PASS n_changes=358
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
TYPED_AST_INVENTORY PASS calls=120 renamed_defaults=88 preserved_explicit=32 bare_rpc_result=0
HEAD_UNCHANGED 2acc71afb62b23e72a5c610522be0e21dc87e119
ASSERT_STOP_UNCHANGED catches=a.Gate
INDEX_UNCHANGED staged_files=0
GIT_DIFF_CHECK PASS
OWNED_PROBE_TEMP_TREES remaining=0
LAUNCHED_FOREGROUND_SESSIONS remaining=0
```

No commit was made. All owned foreground sessions were collected; no background
job was launched. One interrupted probe directory required explicit cleanup after
the owning session exited; no owned probe directories remain. System-wide process
enumeration was unavailable in the sandbox, so lifecycle verification is based on
the owned command sessions, synchronous child-process completion, and temporary-tree
cleanup. The worktree retains the existing 6e diff plus this continuation.


### DSR ruling df8c67a9, part 1 — rpc_result continuation (2026-11-07)

Scope: the requested call sites in `script/upgrade/manifest_exec.py` at
457, 458, 464, 472, 474, 482, 484, 510, 517, 643 and 664. The new
`test_gate_dsr2_rpc.py` and bounded `probe_gate_dsr2_rpc.py` reuse the existing
DSR-2 `delete` / `strict` machinery and unchanged `gate_assertions.assert_stop`
(which catches only `a.Gate`). Production files and the incoming uncommitted 6e
diff were preserved. Gate deletion occurred only in temporary script-tree copies.
No commit, RPC, env-file, keystore or chain operation was performed; local cast
was used only for offline ABI encoding and hashing. No full probe-driver batch
was run and no failure threshold was applied.

Preferred-method assessment: schema patterns are identical to or stricter than
these address/hash/hex-data wire checks; derived messageHash is already checked by
`a.keccak`. The external address loop follows fixed identity gates, and the
sampled-address loop follows exact `[DEPLOYER]` equality. No input passing these
preceding checks while violating T was identified, so paired deletion is used.
Schema E deletion removes the single pattern-check source statement M:403 in the
temporary copy (all dynamic invocations of that statement), not the schema
validator or production schema. Malformed guardian/proof inputs also update their
corresponding negative-fixture copies to preserve unrelated consistency checks.

The first M:458 input used an uppercase `0X` prefix. Deleting E exposed
`local_encoding`, not T, so that attempt was rejected and T was not deleted.
A local encoding check showed that prefixless domain/token values are accepted
by the ABI parser while violating wire regexes. Those inputs are used in the
final controls; no parser or production fallback was added. M:482 uses the
three-stage chain through M:474, with an explicit E1-only observation.

Tooling diagnostics were not accepted as evidence: a Python 3.9 direct diagnostic
failed import with `ModuleNotFoundError: No module named 'tomllib'`; a Python 3.14
AST check rejected declaration fingerprints/AST forms. The shim-started attempt
and Python 3.14 processes were interrupted and collected. Final checks use the
installed `/Users/jason/.pyenv/versions/3.11.9/bin/python3`; no review declaration
was relaxed to accommodate interpreter differences.

An initial `test_gate_rename_controls.py` run from `script/upgrade` raised
`a3a_exec.Gate: safe_gap_packet_path` because governance packet references are
repository-relative. This was rejected, not counted as a passing control. The
launcher was corrected to use root-based unittest discovery; the failed suite
and all remaining suites were then run from the repository root. The ongoing
template-suite attempt was interrupted and restarted with the corrected cwd.
Previously completed green suites were retained without redundant reruns.

Rejected diagnostic final lines (verbatim; AST scope is tracked/eligible untracked
files under `script/`, with changed/common Python files compared):

```text
Ran 1 test in 0.000s
FAILED (errors=1)
GATE_RENAME_AST_DIFF FAIL n_changes=168
Ran 5 tests in 7.842s
FAILED (errors=1)
```

Final target table. Each source-site count scans the indicated target statement
in `script/upgrade/manifest_exec.py` in its temporary copy; the schema E source
statement is M:403, fixed_anni is M:631, and sampled_deployer_only is M:660.
The `source_sites=0` in the rejected exploratory line means no T deletion was
attempted, not that the source definition is absent. No final target is blocked.

| T | E chain | Method | Verbatim result lines |
|---|---|---|---|
| `rpc_result_fraud_fixture_key` | `fraud_schema_pattern_fixture.export.aggregator` | paired | `DSR2_RPC rpc_result_fraud_fixture_key PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_key_2` | `fraud_schema_pattern_fixture.export.domainSeparator` | paired | `DSR2_RPC rpc_result_fraud_fixture_key_2 PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_who` | `fraud_schema_pattern_fixture.export.valid.guiltyGuardians.0` | paired | `DSR2_RPC rpc_result_fraud_fixture_who PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_fraudProof` | `fraud_schema_pattern_fixture.export.valid.fraudProof` | paired | `DSR2_RPC rpc_result_fraud_fixture_fraudProof PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_address` | `fraud_schema_pattern_fixture.export.forkState.token.address` | paired | `DSR2_RPC rpc_result_fraud_fixture_address PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_address_2` | `fraud_schema_pattern_fixture.export.forkState.token.address → rpc_result_fraud_fixture_address` | three-level | `DSR2_RPC_SECOND rpc_result_fraud_fixture_address_2 delete_only=fraud_schema_pattern_fixture.export.forkState.token.address exact_stop=rpc_result_fraud_fixture_address baseline=green failures=0 errors=0`<br>`DSR2_RPC rpc_result_fraud_fixture_address_2 PASS method=three-level source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_runtime` | `fraud_schema_pattern_fixture.export.forkState.token.runtimeBytecode` | paired | `DSR2_RPC rpc_result_fraud_fixture_runtime PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_fraudProof_2` | `fraud_schema_pattern_fixture.export.mustReject.2.fraudProof` | paired | `DSR2_RPC rpc_result_fraud_fixture_fraudProof_2 PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_fraud_fixture_domainDigest` | `fraud_schema_pattern_fixture.export.mustReject.3.domainDigest` | paired | `DSR2_RPC rpc_result_fraud_fixture_domainDigest PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_validate_external_key` | `fixed_anni` | paired | `DSR2_RPC rpc_result_validate_external_key PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |
| `rpc_result_validate_external_who` | `sampled_deployer_only` | paired | `DSR2_RPC rpc_result_validate_external_who PASS method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True` |

Verbatim aggregate after replacing the rejected M:458 attempt with its passing
focused rerun (scope: only the target sites listed in the aggregate):

```text
DSR2_RPC_FINAL scope=script/upgrade/manifest_exec.py:457,458,464,472,474,482,484,510,517,643,664 processed=11 accepted=11 blocked=0 errors_accepted=0
```

Superseded first-attempt lines, preserved verbatim and not accepted:

```text
DSR2_RPC rpc_result_fraud_fixture_key_2 BLOCKED method=dead-code-candidate source_sites=0 baseline=RED shadow=exact_E s1_failures=0 s1_errors=0 s1_named=False failures=0 errors=0 named=False
FAIL: test_target_rpc_result_fraud_fixture_key_2 (test_gate_dsr2_rpc.RpcShadowTests.test_target_rpc_result_fraud_fixture_key_2)
AssertionError: 'local_encoding' != 'rpc_result_fraud_fixture_key_2'
FAILED (failures=1)
DSR2_RPC_AGGREGATE scope=manifest_exec.py:457,458,464,472,474,482,484,510,517,643,664 processed=11 accepted=10 blocked=1 errors_accepted=0
```

Full per-stage outputs: `/tmp/commit6e-dsr2-rpc/probes.json`,
`/tmp/commit6e-dsr2-rpc-domain/probes.json`; merged final records:
`/tmp/commit6e-dsr2-rpc/final.json`. Temporary mutated source trees were removed
by their context managers; these report files contain logs only.

The suite summaries retain opt-in fork-control skips. In
`test_old_owner_isolation.py`, `test_optional_anvil_fork_role_grant` requires
`OLD_OWNER_FORK_PIN/RPC` and an Anvil engine; `test_optional_all_fork_controls`
requires `OLD_OWNER_CONTROL_RPC`, a fixed pin, and the engine. They remain disabled
under this run's no-RPC/no-chain instruction. `test_manifest_exec.py` imports the
same test class, so its summary also includes these skips. They are not counted
as executed fork coverage or accepted deletion probes.

Final regression scope: every top-level `test_*.py` in `script/upgrade/`,
`script/a3a/`, and `script/upgrade/audit/`, plus the only other `test_gate_*.py`
found by scanning `script/`: `script/a6-collector/reproduction/scripts/test_gate_stats_from_csv.py`.
The exact file list and verbatim unittest final lines follow. These suite totals
count the final run of each file, excluding probe mutations, interrupted runs,
and superseded diagnostics. The new shadow suite was rerun after its final edits.

```text
OFFLINE_SUITES PASS scope=explicit_file_list_below suites=32 tests=2311 skipped=4 failed_suites=0

script/a3a/test_a3a_exec.py
Ran 102 tests in 3.070s
OK

script/a3a/test_a3a_send.py
Ran 73 tests in 32.540s
OK

script/a6-collector/reproduction/scripts/test_gate_stats_from_csv.py
Ran 3 tests in 0.304s
OK

script/upgrade/audit/test_audit_findings.py
Ran 6 tests in 19.784s
OK

script/upgrade/test_authority_checkpoints.py
Ran 10 tests in 23.273s
OK

script/upgrade/test_execution_head.py
Ran 6 tests in 0.970s
OK

script/upgrade/test_execution_reads.py
Ran 10 tests in 0.116s
OK

script/upgrade/test_gate_declaration_controls.py
Ran 8 tests in 0.034s
OK

script/upgrade/test_gate_dsr2.py
Ran 18 tests in 39.776s
OK

script/upgrade/test_gate_dsr2_rpc.py
Ran 11 tests in 27.518s
OK

script/upgrade/test_gate_empty_schema.py
Ran 4 tests in 0.005s
OK

script/upgrade/test_gate_extra_finite.py
Ran 55 tests in 5.407s
OK

script/upgrade/test_gate_names.py
Ran 27 tests in 35.802s
OK

script/upgrade/test_gate_r_controls.py
Ran 608 tests in 178.070s
OK

script/upgrade/test_gate_rename_controls.py
Ran 5 tests in 8.921s
OK

script/upgrade/test_gate_review_controls.py
Ran 14 tests in 2.486s
OK

script/upgrade/test_gate_template_controls.py
Ran 171 tests in 236.455s
OK

script/upgrade/test_gate_typed_boundaries.py
Ran 14 tests in 0.002s
OK

script/upgrade/test_gate_typed_controls.py
Ran 5 tests in 3.294s
OK

script/upgrade/test_gate_typed_fields.py
Ran 30 tests in 20.765s
OK

script/upgrade/test_gate_typed_log_fields.py
Ran 18 tests in 13.908s
OK

script/upgrade/test_gate_typed_shadow_controls.py
Ran 12 tests in 28.787s
OK

script/upgrade/test_getter_accessor.py
Ran 2 tests in 5.879s
OK

script/upgrade/test_manifest_exec.py
Ran 535 tests in 425.345s
OK (skipped=2)

script/upgrade/test_manifest_phase_c.py
Ran 141 tests in 203.526s
OK

script/upgrade/test_no_legacy_timelock.py
Ran 6 tests in 5.477s
OK

script/upgrade/test_old_owner_isolation.py
Ran 143 tests in 38.638s
OK (skipped=2)

script/upgrade/test_pop_adapter.py
Ran 53 tests in 0.305s
OK

script/upgrade/test_release_evidence.py
Ran 69 tests in 2.562s
OK

script/upgrade/test_sender_accessor.py
Ran 2 tests in 24.336s
OK

script/upgrade/test_sp_upgrade_exec.py
Ran 141 tests in 1.596s
OK

script/upgrade/test_swallow_exceptions.py
Ran 9 tests in 2.739s
OK
```

Final checker output (verbatim). AST scan scope: Git-tracked and eligible
untracked files under `script/`, with common changed/declared Python ASTs compared
against `2acc71af` and added files fingerprinted. Name-inventory scope:
`manifest_exec.py` and `old_owner_isolation.py` plus the repository-wide tracked/
eligible untracked Python typed-call scan in `gate_typed_sites.inventory`; the
focused name probe uses synthetic uniqueness controls and Phase C funding labels.

```text
GATE_RENAME_AST_DIFF PASS n_changes=358
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

Full regression logs: `/tmp/commit6e-final-rpc/`; rejected Python 3.14 diagnostics:
`/tmp/commit6e-final-rpc-python314/`.

Exact Python files contributing the accepted AST changes above:

```text
script/a3a/a3a_exec.py
script/a3a/a3a_send.py
script/evidence/audit605_probes.py
script/evidence/enduser_mapping_probes.py
script/evidence/inventory_replay_probes.py
script/upgrade/manifest_exec.py
script/upgrade/old_owner_isolation.py
script/upgrade/probe_phase_c_gates.py
script/upgrade/sp_upgrade_exec.py
script/upgrade/test_authority_checkpoints.py
script/upgrade/test_execution_reads.py
script/upgrade/test_manifest_exec.py
script/upgrade/test_manifest_phase_c.py
script/upgrade/test_old_owner_isolation.py
```

The raw launcher aggregate retains the superseded cwd failure as an attempt;
its attempt count is not the final suite/file count. Verbatim:

```text
OFFLINE_CHECKS COMPLETE commands=34 passed=33 failed=1
```

Final workspace/lifecycle checks (verbatim; index scope is this worktree,
source assertion scope is `script/upgrade/gate_assertions.py`):

```text
HEAD_UNCHANGED 2acc71afb62b23e72a5c610522be0e21dc87e119
ASSERT_STOP_UNCHANGED catches=a.Gate
INDEX_UNCHANGED staged_files=0
GIT_DIFF_CHECK PASS
OWNED_PROBE_TEMP_TREES scope=commit6e-dsr2-rpc-* containing_script remaining=0
LAUNCHED_FOREGROUND_SESSIONS scope=this_continuation remaining=0
```

No commit was made. The incoming uncommitted 6e diff is retained, with only
the bounded RPC DSR runner, its shadow tests, and this results continuation added
by this task. All owned sessions were collected, including interrupted diagnostics;
no background job was launched. Lifecycle verification uses the owned sessions
and temporary-tree paths, not a system-wide process census.

### DSR ruling df8c67a9, part 2 — producer-only continuation (2026-11-07)

This continuation preserves the incoming 6e changes and does not commit. No RPC,
env-file, keystore, or chain operations are used. Local `cast` supplies offline
encoding/hashing only. `assert_stop` is unchanged and catches only `a.Gate`.
The full probe-driver batch is not run. Individual blockers do not stop the
remaining checks. Deletion occurs only in an owned temporary script-tree copy.

The new `test_gate_producer_controls.py` uses the real `find_step_schedule` on
`FakeChain`, saves its return, and replaces that one producer inside a test-local
`patch.object` context. The control returns a deep copy of the real return. The
negative changes only the returned log data to prefixless hex. All intervening
checks remain enabled. Each exercise asserts producer identity after leaving the
context; `test_original_restored` also exercises both modes and checks identity.
`prove_schedule_flow` checks the AST's unique `log` assignment, the exact producer
call and tuple position, the target argument, and every intervening use of `log`.
The baseline suite includes this proof. The deletion run removes only the target
`typed` call, preserving its value expression and the surrounding `need` call.

Scan scope for the following table: the eight specified typed-call sites in
`script/a3a/a3a_exec.py` and `script/upgrade/old_owner_isolation.py`. The AST
extraction with parameters, preceding assignments, and target expressions is
saved in `/tmp/commit6e-producer-controls/dataflow.json`. A parameter is not
credited as the return of an unrelated producer called by the same function.

| Site | Gate | Producer/dataflow assessment | Result |
| --- | --- | --- | --- |
| a3a_exec.py:668 | `rpc_result_rebuild_artifacts_object` | `current = artifacts[name]`: `artifacts` is a parameter. `build_plan` supplies either `compile_commit` output (historical branch) or two `artifact` calls (current branch). No single unconditional producer across these paths. The current `artifact` loader also stops at `build_artifact` for both required artifacts in this worktree. | BLOCKED; not counted |
| a3a_exec.py:669 | `rpc_result_rebuild_artifacts_object_2` | `fresh = rebuilt[name]`; `rebuilt, config = compile_commit(...)`. This is a single producer path; real offline producer baseline assessed separately below. | See compiler outcome below |
| a3a_exec.py:1525 | `rpc_result_scheduled_eta_data` | `log` is tuple element 1 from `find_step_schedule`; unique assignment and intervening consumers checked by AST. | PASS |
| old_owner_isolation.py:1012 | `rpc_result_verify_deployment_record_txHash` | `ref = spec.get('deploymentRecord')`; target reads `ref['txHash']`. `spec` is a parameter. `committed_record` produces `record`, not `ref`; replacing it cannot alter this target value. Caller `deployed_inventory` selects `spec` from its `sources` argument. | BLOCKED; not counted |
| old_owner_isolation.py:1241 | `rpc_result_validate_deployed_identity` | `identity` iterates `section.get('endpointIdentities', {}).values()`; `section` is a parameter. `inventory_source` returns `inventory`, not these identities. `assert_endpoint_identities` is a check whose return is discarded. | BLOCKED; not counted |
| old_owner_isolation.py:1250 | `rpc_result_post_upgrade_check_stateBlock` | Target reads the `pin` parameter before any producer call. No returned producer value supplies it inside this function. | BLOCKED; not counted |
| old_owner_isolation.py:1255 | `rpc_result_post_upgrade_check_target` | `target` iterates groups in the `release_targets` parameter before `inventory_source` or `discover_targets` runs. Neither return supplies this value. | BLOCKED; not counted |
| old_owner_isolation.py:1558 | `rpc_result_inspect_data` | Nested `inspect(data)` has multiple callers: outer transaction data, constructor selector plus tail, recursive decoded values via `visit`, and payload children. `decoded_arguments` covers only the recursive route; outer values derive from `steps`, constructor paths also use `a.keccak`. No sole producer covers this source site. | BLOCKED; not counted |

Existing test coverage by producer (names are from scanning
`script/a3a/test_a3a_exec.py` and `script/upgrade/test_old_owner_isolation.py`):

- `find_step_schedule`: `ExecutorTests.test_schedule_logs_query_reuses_indexed_lookup`,
  `test_indexed_schedule_receipt_bounded_calls`, `test_indexed_schedule_receipt_guards`,
  `test_schedule_canonical_membership_and_identity`, `test_fake_blocks_share_full_and_header_data`.
  These exercise the real producer using the offline chain fixture.
- `compile_commit`: `ExecutorTests.test_compile_uses_offline_forge_default_profile_and_cleans_temp`
  exercises the real function with archive/compiler/artifact boundaries doubled.
  `test_rebuild_compares_all_bytecode_and_reference_fields` doubles this producer;
  it does not establish a real compiler-return baseline for this ruling.
- Current `artifact` loader: orchestration tests including
  `ExecutorTests.test_amend_requires_a_valid_ungapped_source_and_well_formed_gaps`
  and `test_amend_follows_renumbered_ast_ids_only` replace `artifact` with their
  fixture. They are caller coverage, not proof of a real-loader baseline.
- The five blocked `old_owner_isolation.py` targets have no qualifying sole
  producer. Related consumer coverage is
  `OldOwnerTests.test_deployment_record_binding_and_gate_removals`,
  `test_clone_collection_and_post_upgrade_gate_removals`,
  `test_review_low_endpoint_identity`, `test_manifest_calldata_invalid_cast_output`,
  and `test_calldata_payload_removal_hits_named_gate` (class names verified below).

Verbatim focused probe final line:

```text
PRODUCER_PROBE scope=script/a3a/a3a_exec.py:1525 gate=rpc_result_scheduled_eta_data PASS source_sites=1 baseline=green failures=1 errors=0 named=True
```

Full baseline and deletion output: `/tmp/commit6e-producer-controls/result.json`.


### DSR ruling df8c67a9, part 2 — resumed verification (2026-11-08)

This subsection supersedes the incomplete producer-only continuation above.
HEAD remains `2acc71af`; the incoming uncommitted 6e diff is retained. No commit,
RPC connection, env-file access, keystore or chain operation is authorized or used.
Only offline test boundaries and local cast encoding/hashing are used. Production
gates and `assert_stop` (only `a.Gate`) remain unchanged. No full probe-driver
batch is run. Each blocked item is recorded independently; it does not halt the
remaining work.

The prior schedule test inherited `ExecutorTests.setUp`, which installed an
additional `rebuild_artifacts` double; `chain_and_plan` also installed fixture
patches. The prior PASS therefore was not sufficient evidence of the exactly-one-
producer rule. Removing that setup exposed `rebuild_head` in the temporary tree
(the rejected attempt had baseline errors and was not accepted). The final test
uses a standalone deterministic in-memory remote boundary, without inheriting
fixture patches or replacing any production function during setup. It invokes
the real `find_step_schedule` to obtain the real return before installing exactly
one test-local `patch.object(a, 'find_step_schedule', ...)`. The real-return control,
malformed-return control, and restoration test run with every intervening check
enabled. `test_original_restored` asserts object identity after both contexts.
`test_flow` proves the unique producer assignment, returned tuple slot, target
expression, every intervening `log` use, and nesting within `schedule_log_data`.
`test_compile_flow` separately proves the unique `rebuilt` and `fresh` assignments,
producer call, indexing path, and absence of another pre-target use or alias escape.

The claimed intermediate schedule gate has the reverse execution order in this
worktree: `need('schedule_log_data', typed(log['data'], ..., gate=T).lower(), ...)`
evaluates T before invoking E. With the same malformed producer return, real-tree
`assert_stop(..., E)` FAILs naming T; E is observed only after deleting T. The
requested paired experiment was nevertheless performed in temporary copies:
deleting just E preserves evaluation of its checked argument (including T), then
deleting E+T remains red without ERROR. Because the real-tree exact-E shadow is
red, the paired method is BLOCKED, not accepted. The independently passing direct
T-deletion method supplies this site's credit. No greater-than-three-level chain
is traversed.

Existing producer coverage (scan scope: `script/a3a/test_a3a_exec.py` and
`script/upgrade/test_old_owner_isolation.py`; names below are test methods):

- `find_step_schedule`: `ExecutorTests.test_schedule_logs_query_reuses_indexed_lookup`,
  `test_indexed_schedule_receipt_bounded_calls`, `test_indexed_schedule_receipt_guards`,
  `test_schedule_canonical_membership_and_identity`, `test_schedule_filters_foreign_history`,
  `test_schedule_log_range_splitting_and_errors`, `test_schedule_range_bounds_and_chunk_order`.
- `compile_commit`: `ExecutorTests.test_compile_uses_offline_forge_default_profile_and_cleans_temp`
  covers the real function with lower boundaries doubled;
  `test_rebuild_compares_all_bytecode_and_reference_fields` replaces the producer.
  Neither is counted as an undoubled real compiler baseline for this ruling.
- `artifact`: `ExecutorTests.test_amend_requires_a_valid_ungapped_source_and_well_formed_gaps`
  and `test_amend_follows_renumbered_ast_ids_only` are caller coverage with the loader
  replaced, not an undoubled loader baseline.
- No sole producer qualifies for the specified old-owner targets. Related consumer
  tests belong to `OldOwnerIsolationTests` (correcting the prior class label):
  `test_deployment_record_binding_and_gate_removals`,
  `test_clone_collection_and_post_upgrade_gate_removals`, `test_review_low_endpoint_identity`,
  `test_manifest_calldata_invalid_cast_output`, `test_calldata_payload_removal_hits_named_gate`.

Verbatim focused producer lines (source-site scope is the named statement in
`script/a3a/a3a_exec.py`, in owned temporary copies):

```text
PRODUCER_PROBE scope=script/a3a/a3a_exec.py:1525 gate=rpc_result_scheduled_eta_data PASS source_sites=1 baseline=green failures=1 errors=0 named=True
PRODUCER_PAIR scope=script/a3a/a3a_exec.py:1525 BLOCKED E=schedule_log_data T=rpc_result_scheduled_eta_data E_sites=1 real_shadow_E=RED delete_E_exact_T=True delete_E_failures=1 delete_E_errors=0 delete_E_named=True delete_ET_failures=1 delete_ET_errors=0 delete_ET_named=True reason=T_evaluates_before_E
```

Verbatim real current-loader observations (scope: the local `out` paths shown):

```text
CURRENT_ARTIFACT scope=out/APNTsCapped.sol producer=artifact contract=APNTsCapped BLOCKED gate=build_artifact observed=APNTsCapped missing
CURRENT_ARTIFACT scope=out/TimelockController.sol producer=artifact contract=TimelockController BLOCKED gate=build_artifact observed=TimelockController missing
```

The undoubled `compile_commit('2acc71af', forge_version)` completed successfully
using the existing offline archive/compiler path. Its exact returned artifact and
config values are preserved as test-only data in
`script/upgrade/fixtures/gate-producer-compile.json`, with the full commit and Forge
version. SHA256 of this capture:
`19786182591b6522357f7129416909cdee21e3bb3a0250cee329735cd22fd841`.
No synthesized compiler result, production fallback, or additional producer double
was used. `CompileProducerTests` replaces only `compile_commit` in a test-local
context; it retains real HEAD/Forge/config/bytecode/metadata checks. The malformed
return changes only the first bytecode object's two-character prefix to `zz`,
which violates T but preserves decoded bytes after T deletion. Its separate
restoration test asserts the original function identity after both control modes.
Temporary probe copies include a copy of the worktree's `.git` pointer solely for
the consumer's read-only `rev-parse` and `show` calls. No Git mutation is invoked.

Verbatim compiler observation and final combined producer results:

```text
FORGE_VERSION forge Version: 1.7.1
COMPILE_REAL_RETURN PASS
PRODUCER_PROBE scope=script/a3a/a3a_exec.py:1525 gate=rpc_result_scheduled_eta_data PASS source_sites=1 baseline=green failures=1 errors=0 named=True
PRODUCER_PAIR scope=script/a3a/a3a_exec.py:1525 BLOCKED E=schedule_log_data T=rpc_result_scheduled_eta_data E_sites=1 real_shadow_E=RED delete_E_exact_T=True delete_E_failures=1 delete_E_errors=0 delete_E_named=True delete_ET_failures=1 delete_ET_errors=0 delete_ET_named=True reason=T_evaluates_before_E
PRODUCER_PROBE scope=script/a3a/a3a_exec.py:669 gate=rpc_result_rebuild_artifacts_object_2 PASS source_sites=1 baseline=green failures=1 errors=0 named=True
```

Final per-site assessment. Scan scope: exactly the specified statements in
`script/a3a/a3a_exec.py` and `script/upgrade/old_owner_isolation.py`; the saved
`/tmp/commit6e-producer-controls/dataflow.json` locations and value expressions
were checked against the current AST. Each credited deletion matches one source
call, and requires a green baseline, at least one failure, zero errors, and an
assertion message naming the deleted gate.

| Source site | Gate | Sole-producer assessment and final result |
| --- | --- | --- |
| `a3a_exec.py:668` | `rpc_result_rebuild_artifacts_object` | BLOCKED: `current = artifacts[name]` uses a function parameter. `build_plan` supplies historical `compile_commit` results or separate current `artifact` loads; no single unconditional producer supplies the site's value. Both real current loader calls additionally stop at `build_artifact` because local artifacts are absent. No credit. |
| `a3a_exec.py:669` | `rpc_result_rebuild_artifacts_object_2` | PASS: `compile_commit` return element 0 → `rebuilt[name]` → `fresh[field]['object']`; AST proof, real captured return control, single scoped double, restoration, and strict deletion all pass. |
| `a3a_exec.py:1525` | `rpc_result_scheduled_eta_data` | PASS by direct strict deletion: `find_step_schedule` return element 1 → `log['data']`. Single scoped double, real-return control, restoration and AST proof pass. Proposed E=`schedule_log_data` paired method is separately BLOCKED because E follows T; no paired credit is claimed. |
| `old_owner_isolation.py:1012` | `rpc_result_verify_deployment_record_txHash` | BLOCKED: target `ref['txHash']` derives from parameter `spec.get('deploymentRecord')`. `committed_record` returns the separate `record` object and does not supply `ref`. No qualifying sole producer. |
| `old_owner_isolation.py:1241` | `rpc_result_validate_deployed_identity` | BLOCKED: identity iterates `section.get('endpointIdentities', {}).values()`, from parameter `section`. `inventory_source` supplies `inventory`; `assert_endpoint_identities` has no used return. Neither supplies identity. |
| `old_owner_isolation.py:1250` | `rpc_result_post_upgrade_check_stateBlock` | BLOCKED: `pin['stateBlock']` reads the parameter before a producer call. No qualifying returned value. |
| `old_owner_isolation.py:1255` | `rpc_result_post_upgrade_check_target` | BLOCKED: target iterates groups from parameter `release_targets`, before `inventory_source`/`discover_targets`. Neither return supplies the value. |
| `old_owner_isolation.py:1558` | `rpc_result_inspect_data` | BLOCKED: nested `inspect` receives outer transaction data, constructor selector plus tail, recursive decoded values, and payload children. `decoded_arguments` supplies only recursive routes; other routes use `steps` and `a.keccak`. No single producer supplies all routes. |

The merged RPC count retains the previously accepted direct results in
`gate_typed_probe_results.json` and the final part-1 paired results recorded above
(`/tmp/commit6e-dsr2-rpc/final.json`), then adds the two distinct producer passes.
It does not rerun the full probe-driver batch or count the failed proposed schedule
pair. Aggregate scan scope: the 88 formerly defaulted typed-call sites in
`script/a3a/a3a_exec.py` (25), `script/a3a/a3a_send.py` (2),
`script/upgrade/manifest_exec.py` (21), `script/upgrade/old_owner_isolation.py` (25),
and `script/upgrade/sp_upgrade_exec.py` (15). Existing explicitly named typed calls
are excluded from this aggregate. The union and its per-site provenance are saved
in `/tmp/commit6e-producer-final/rpc-merged.json`.

```text
RPC_RESULT_PROBES scope=script/a3a/a3a_exec.py,script/a3a/a3a_send.py,script/upgrade/manifest_exec.py,script/upgrade/old_owner_isolation.py,script/upgrade/sp_upgrade_exec.py passed=82 total=88 blocked=6 errors_accepted=0
```

Rejected fixture-setup diagnostic, verbatim (scope: the schedule target at
`script/a3a/a3a_exec.py:1525` in the temporary copy, after removing inherited
patches but before replacing the fixture construction). This is not accepted
probe evidence; the final standalone fixture supersedes it:

```text
PRODUCER_PROBE scope=script/a3a/a3a_exec.py:1525 gate=rpc_result_scheduled_eta_data BLOCKED source_sites=1 baseline=RED failures=0 errors=1 named=False
```

The final shared producer baseline includes both producers and both restoration
tests. Verbatim (test-file scope: `script/upgrade/test_gate_producer_controls.py`):

```text
Ran 8 tests in 0.456s
OK
```

Consolidated per-site RPC ledger. Scope: the formerly defaulted typed calls in
`script/a3a/a3a_exec.py`, `script/a3a/a3a_send.py`,
`script/upgrade/manifest_exec.py`, `script/upgrade/old_owner_isolation.py`, and
`script/upgrade/sp_upgrade_exec.py`. `prior-direct` and `part1-paired` retain the
accepted evidence recorded above; `part2-producer` is verified in this continuation.
`BLOCKED` rows receive no credit and use the detailed explanations in the preceding
producer table. This is an evidence union, not a full probe-driver rerun.

| Source site | Gate | Result | Evidence |
| --- | --- | --- | --- |
| `a3a_exec.py:103` | `rpc_result_qty_value` | PASS | prior-direct |
| `a3a_exec.py:186` | `rpc_result_keccak_keccak` | PASS | prior-direct |
| `a3a_exec.py:211` | `rpc_result_rpc_keccak_web3_sha3` | PASS | prior-direct |
| `a3a_exec.py:211` | `rpc_result_rpc_keccak_data` | PASS | prior-direct |
| `a3a_exec.py:334` | `rpc_result_verify_runtime_artifactRuntime` | PASS | prior-direct |
| `a3a_exec.py:335` | `rpc_result_verify_runtime_code` | PASS | prior-direct |
| `a3a_exec.py:367` | `rpc_result_calldata_calldata` | PASS | prior-direct |
| `a3a_exec.py:371` | `rpc_result_call_eth_call` | PASS | prior-direct |
| `a3a_exec.py:394` | `rpc_result_block_data_hash` | PASS | prior-direct |
| `a3a_exec.py:451` | `rpc_result_artifact_sources_keccak256` | PASS | prior-direct |
| `a3a_exec.py:471` | `rpc_result_cbor_tail_code` | PASS | prior-direct |
| `a3a_exec.py:668` | `rpc_result_rebuild_artifacts_object` | BLOCKED | blocked |
| `a3a_exec.py:669` | `rpc_result_rebuild_artifacts_object_2` | PASS | part2-producer |
| `a3a_exec.py:711` | `rpc_result_safe_extensions_eth_getStorageAt` | PASS | prior-direct |
| `a3a_exec.py:763` | `rpc_result_preflight_eth_getCode` | PASS | prior-direct |
| `a3a_exec.py:1123` | `rpc_result_receipt_eth_sendTransaction` | PASS | prior-direct |
| `a3a_exec.py:1196` | `rpc_result_roles_readback_1` | PASS | prior-direct |
| `a3a_exec.py:1196` | `rpc_result_roles_readback_2` | PASS | prior-direct |
| `a3a_exec.py:1201` | `rpc_result_roles_readback_3` | PASS | prior-direct |
| `a3a_exec.py:1322` | `rpc_result_validate_pin_blockHash` | PASS | prior-direct |
| `a3a_exec.py:1346` | `rpc_result_validate_gaps_hash` | PASS | prior-direct |
| `a3a_exec.py:1377` | `rpc_result_check_gaps_eth_getCode` | PASS | prior-direct |
| `a3a_exec.py:1525` | `rpc_result_scheduled_eta_data` | PASS | part2-producer |
| `a3a_exec.py:1559` | `rpc_result_pre_send_eth_getCode` | PASS | prior-direct |
| `a3a_exec.py:1728` | `rpc_result_require_deployed_eth_getCode` | PASS | prior-direct |
| `a3a_send.py:134` | `rpc_result_local_keccak_value` | PASS | prior-direct |
| `a3a_send.py:147` | `rpc_result_check_signed_hash` | PASS | prior-direct |
| `manifest_exec.py:293` | `rpc_result_validate_evidence_details_value` | PASS | prior-direct |
| `manifest_exec.py:306` | `rpc_result_verifier_executable_code` | PASS | prior-direct |
| `manifest_exec.py:457` | `rpc_result_fraud_fixture_key` | PASS | part1-paired |
| `manifest_exec.py:458` | `rpc_result_fraud_fixture_key_2` | PASS | part1-paired |
| `manifest_exec.py:464` | `rpc_result_fraud_fixture_who` | PASS | part1-paired |
| `manifest_exec.py:472` | `rpc_result_fraud_fixture_fraudProof` | PASS | part1-paired |
| `manifest_exec.py:474` | `rpc_result_fraud_fixture_address` | PASS | part1-paired |
| `manifest_exec.py:482` | `rpc_result_fraud_fixture_address_2` | PASS | part1-paired |
| `manifest_exec.py:484` | `rpc_result_fraud_fixture_runtime` | PASS | part1-paired |
| `manifest_exec.py:510` | `rpc_result_fraud_fixture_fraudProof_2` | PASS | part1-paired |
| `manifest_exec.py:517` | `rpc_result_fraud_fixture_domainDigest` | PASS | part1-paired |
| `manifest_exec.py:635` | `rpc_result_validate_external_sid` | PASS | prior-direct |
| `manifest_exec.py:643` | `rpc_result_validate_external_key` | PASS | part1-paired |
| `manifest_exec.py:650` | `rpc_result_validate_external_validator` | PASS | prior-direct |
| `manifest_exec.py:651` | `rpc_result_validate_external_calldata` | PASS | prior-direct |
| `manifest_exec.py:664` | `rpc_result_validate_external_who` | PASS | part1-paired |
| `manifest_exec.py:1110` | `rpc_result_scan_blockNumber` | PASS | prior-direct |
| `manifest_exec.py:1151` | `rpc_result_call_eth_call_2` | PASS | prior-direct |
| `manifest_exec.py:1193` | `rpc_result_old_timelock_holds_nothing_1` | PASS | prior-direct |
| `manifest_exec.py:2119` | `rpc_result_build_plan_value` | PASS | prior-direct |
| `manifest_exec.py:2131` | `rpc_result_build_plan_code` | PASS | prior-direct |
| `old_owner_isolation.py:615` | `rpc_result_call_eth_call_3` | PASS | prior-direct |
| `old_owner_isolation.py:627` | `rpc_result_storage_eth_getStorageAt` | PASS | prior-direct |
| `old_owner_isolation.py:763` | `rpc_result_audit_1` | PASS | prior-direct |
| `old_owner_isolation.py:764` | `rpc_result_audit_blockNumber` | PASS | prior-direct |
| `old_owner_isolation.py:769` | `rpc_result_audit_blockHash` | PASS | prior-direct |
| `old_owner_isolation.py:976` | `rpc_result_clone_implementation_code` | PASS | prior-direct |
| `old_owner_isolation.py:1012` | `rpc_result_verify_deployment_record_txHash` | BLOCKED | blocked |
| `old_owner_isolation.py:1115` | `rpc_result_runtime_parity_code` | PASS | prior-direct |
| `old_owner_isolation.py:1116` | `rpc_result_runtime_parity_object` | PASS | prior-direct |
| `old_owner_isolation.py:1168` | `rpc_result_deployed_inventory_eth_getCode` | PASS | prior-direct |
| `old_owner_isolation.py:1169` | `rpc_result_deployed_inventory_eth_getStorageAt` | PASS | prior-direct |
| `old_owner_isolation.py:1170` | `rpc_result_deployed_inventory_eth_getStorageAt_2` | PASS | prior-direct |
| `old_owner_isolation.py:1241` | `rpc_result_validate_deployed_identity` | BLOCKED | blocked |
| `old_owner_isolation.py:1250` | `rpc_result_post_upgrade_check_stateBlock` | BLOCKED | blocked |
| `old_owner_isolation.py:1255` | `rpc_result_post_upgrade_check_target` | BLOCKED | blocked |
| `old_owner_isolation.py:1364` | `rpc_result_role_history_data` | PASS | prior-direct |
| `old_owner_isolation.py:1367` | `rpc_result_role_history_topic` | PASS | prior-direct |
| `old_owner_isolation.py:1370` | `rpc_result_role_history_blockNumber` | PASS | prior-direct |
| `old_owner_isolation.py:1376` | `rpc_result_role_history_transactionHash` | PASS | prior-direct |
| `old_owner_isolation.py:1377` | `rpc_result_role_history_transactionIndex` | PASS | prior-direct |
| `old_owner_isolation.py:1378` | `rpc_result_role_history_logIndex` | PASS | prior-direct |
| `old_owner_isolation.py:1493` | `rpc_result_fork_probe_raw` | PASS | prior-direct |
| `old_owner_isolation.py:1500` | `rpc_result_fork_probe_raw_2` | PASS | prior-direct |
| `old_owner_isolation.py:1558` | `rpc_result_inspect_data` | BLOCKED | blocked |
| `old_owner_isolation.py:1591` | `rpc_result_assert_manifest_calldata_data` | PASS | prior-direct |
| `sp_upgrade_exec.py:58` | `rpc_result_uints_raw` | PASS | prior-direct |
| `sp_upgrade_exec.py:106` | `rpc_result_code_eth_getCode` | PASS | prior-direct |
| `sp_upgrade_exec.py:135` | `rpc_result_scan_blockHash` | PASS | prior-direct |
| `sp_upgrade_exec.py:135` | `rpc_result_scan_transactionHash` | PASS | prior-direct |
| `sp_upgrade_exec.py:150` | `rpc_result_inventory_2` | PASS | prior-direct |
| `sp_upgrade_exec.py:164` | `rpc_result_inventory_1` | PASS | prior-direct |
| `sp_upgrade_exec.py:189` | `rpc_result_safe_state_eth_getStorageAt` | PASS | prior-direct |
| `sp_upgrade_exec.py:207` | `rpc_result_pending_operations_1` | PASS | prior-direct |
| `sp_upgrade_exec.py:309` | `rpc_result_initial_guardian_eth_getStorageAt` | PASS | prior-direct |
| `sp_upgrade_exec.py:468` | `rpc_result_validate_gas_transactionHash` | PASS | prior-direct |
| `sp_upgrade_exec.py:588` | `rpc_result_admission_gas_data` | PASS | prior-direct |
| `sp_upgrade_exec.py:730` | `rpc_result_validate_pin_field` | PASS | prior-direct |
| `sp_upgrade_exec.py:745` | `rpc_result_validate_pin_who` | PASS | prior-direct |
| `sp_upgrade_exec.py:755` | `rpc_result_validate_pin_who_2` | PASS | prior-direct |
| `sp_upgrade_exec.py:766` | `rpc_result_validate_pin_who_3` | PASS | prior-direct |

```text
RPC_RESULT_PROBES scope=script/a3a/a3a_exec.py,script/a3a/a3a_send.py,script/upgrade/manifest_exec.py,script/upgrade/old_owner_isolation.py,script/upgrade/sp_upgrade_exec.py passed=82 total=88 blocked=6 errors_accepted=0
```

Final checker lines (verbatim). AST scan scope: Git-tracked and eligible untracked
files under `script/`, with changed/common Python ASTs compared against `2acc71af`
and additions fingerprinted. Name-probe scope: `manifest_exec.py` and
`old_owner_isolation.py` name inventories, repository Python typed-call inventory,
synthetic uniqueness controls, and Phase C funding-label controls.

```text
GATE_RENAME_AST_DIFF PASS n_changes=358
GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
```

Verbatim ledger verification (scopes are in each line):

```text
RPC_LEDGER_AST_MATCH scope=script/a3a/a3a_exec.py,script/a3a/a3a_send.py,script/upgrade/manifest_exec.py,script/upgrade/old_owner_isolation.py,script/upgrade/sp_upgrade_exec.py PASS source_sites=88
RPC_RETAINED_STRICT_FIELDS scope=script/upgrade/gate_typed_probe_results.json,/tmp/commit6e-dsr2-rpc/final.json PASS retained_sites=80 errors_accepted=0
```

Final foreground suite lines (verbatim). Scan/execution scope is all top-level
`script/upgrade/test_*.py` and `script/a3a/test_*.py` files, plus the audit-findings
suite and the additional repository `test_gate_*` file under the A6 collector.
A Git-tracked/eligible-untracked `*test_gate_*.py` scan and untracked `*test*.py`
scan confirmed coverage of every such gate/new test file. Every requested suite
completed. Existing skips are retained and shown. The producer file's final
expanded suite supersedes its earlier narrower run and is counted once.
No full probe-driver batch was run; no failure threshold terminated the queue.

```text
script/a3a/test_a3a_exec.py
Ran 102 tests in 3.609s
OK

script/a3a/test_a3a_send.py
Ran 73 tests in 31.970s
OK

script/upgrade/test_authority_checkpoints.py
Ran 10 tests in 20.037s
OK

script/upgrade/test_execution_head.py
Ran 6 tests in 1.225s
OK

script/upgrade/test_execution_reads.py
Ran 10 tests in 0.108s
OK

script/upgrade/test_gate_declaration_controls.py
Ran 8 tests in 0.026s
OK

script/upgrade/test_gate_dsr2.py
Ran 18 tests in 44.114s
OK

script/upgrade/test_gate_dsr2_rpc.py
Ran 11 tests in 33.942s
OK

script/upgrade/test_gate_empty_schema.py
Ran 4 tests in 0.005s
OK

script/upgrade/test_gate_extra_finite.py
Ran 55 tests in 7.707s
OK

script/upgrade/test_gate_names.py
Ran 27 tests in 48.335s
OK

script/upgrade/test_gate_producer_controls.py
Ran 8 tests in 0.527s
OK

script/upgrade/test_gate_r_controls.py
Ran 608 tests in 182.359s
OK

script/upgrade/test_gate_rename_controls.py
Ran 5 tests in 6.481s
OK

script/upgrade/test_gate_review_controls.py
Ran 14 tests in 1.976s
OK

script/upgrade/test_gate_template_controls.py
Ran 171 tests in 231.433s
OK

script/upgrade/test_gate_typed_boundaries.py
Ran 14 tests in 0.001s
OK

script/upgrade/test_gate_typed_controls.py
Ran 5 tests in 3.333s
OK

script/upgrade/test_gate_typed_fields.py
Ran 30 tests in 19.057s
OK

script/upgrade/test_gate_typed_log_fields.py
Ran 18 tests in 13.599s
OK

script/upgrade/test_gate_typed_shadow_controls.py
Ran 12 tests in 27.620s
OK

script/upgrade/test_getter_accessor.py
Ran 2 tests in 5.749s
OK

script/upgrade/test_manifest_exec.py
Ran 535 tests in 433.852s
OK (skipped=2)

script/upgrade/test_manifest_phase_c.py
Ran 141 tests in 212.625s
OK

script/upgrade/test_no_legacy_timelock.py
Ran 6 tests in 5.446s
OK

script/upgrade/test_old_owner_isolation.py
Ran 143 tests in 40.929s
OK (skipped=2)

script/upgrade/test_pop_adapter.py
Ran 53 tests in 0.272s
OK

script/upgrade/test_release_evidence.py
Ran 69 tests in 2.505s
OK

script/upgrade/test_sender_accessor.py
Ran 2 tests in 24.681s
OK

script/upgrade/test_sp_upgrade_exec.py
Ran 141 tests in 1.432s
OK

script/upgrade/test_swallow_exceptions.py
Ran 9 tests in 2.652s
OK

script/upgrade/audit/test_audit_findings.py
Ran 6 tests in 21.122s
OK

script/a6-collector/reproduction/scripts/test_gate_stats_from_csv.py
Ran 3 tests in 0.360s
OK

FOREGROUND_SUITES scope=script/upgrade/test_*.py,script/a3a/test_*.py passed=31 total=31 blocked=0
FINAL_SUITES scope=script/upgrade/test_*.py,script/a3a/test_*.py,script/upgrade/audit/test_audit_findings.py,script/a6-collector/reproduction/scripts/test_gate_stats_from_csv.py passed=33 total=33 blocked=0
```

Final workspace/lifecycle checks (verbatim; each scope is identified):

```text
HEAD_UNCHANGED 2acc71afb62b23e72a5c610522be0e21dc87e119
ASSERT_STOP_UNCHANGED scope=script/upgrade/gate_assertions.py catches=a.Gate
INDEX_UNCHANGED scope=this_worktree staged_files=0
OWNED_PROBE_TEMP_TREES scope=commit6e-producer-probe-* remaining=0
OWNED_COMPILE_TEMP_TREE scope=a3a-head-rebuild-oq4rajcv removed=True
```

All launched foreground tool sessions returned completion, including the real
compiler and rejected fixture diagnostics; no background job was launched or left
by this continuation. Owned temporary probe and compiler trees were cleaned by
their context managers. Lifecycle verification uses this continuation's owned
sessions and paths, not a system-wide process census. No commit was made; the
incoming 6e production diff is retained. This continuation changes only the
producer runner/tests, their captured compiler fixture, and this results record.
Full logs and machine-readable merged evidence: `/tmp/commit6e-producer-final/`
and `/tmp/commit6e-producer-controls/`.

```text
GIT_DIFF_CHECK scope=this_worktree PASS
```

### 6e closure — known gaps (DSR-agreed scope cap, 2026-11-08)

6e adds no further proof requirements (author instruction 2026-11-08, accepted by DSR).
The sites below have no accepted strict deletion probe. Each is a defence-in-depth
`typed` check whose input is already constrained by the named earlier check; the gap is
recorded, not waived, and receives no credit in any aggregate.
Scan scope for these rows: `script/a3a/a3a_exec.py`, `script/a3a/a3a_send.py`,
`script/upgrade/manifest_exec.py`, `script/upgrade/old_owner_isolation.py`,
`script/upgrade/sp_upgrade_exec.py` (`RPC_RESULT_PROBES ... passed=82 total=88 blocked=6`).

| Site | Gate | Why no probe | Covered by |
|---|---|---|---|
| `a3a_exec.py:668` | `rpc_result_rebuild_artifacts_object` | `artifacts[name]` is a parameter with two producers (historical `compile_commit` / current `artifact` load); no single producer | `build_artifact` on the current load; `rpc_result_rebuild_artifacts_object_2` (probed) and the rebuilt-vs-current equality |
| `old_owner_isolation.py:1012` | `rpc_result_verify_deployment_record_txHash` | `ref` comes from caller-supplied `spec['deploymentRecord']`, not from a producer return | `committed_record` and the deployment-record receipt checks in `verify_deployment_record` |
| `old_owner_isolation.py:1241` | `rpc_result_validate_deployed_identity` | identity iterates the `section` parameter | `assert_endpoint_identities` |
| `old_owner_isolation.py:1250` | `rpc_result_post_upgrade_check_stateBlock` | `pin['stateBlock']` is a parameter read before any producer call | `u.validate_pin` on the same pin |
| `old_owner_isolation.py:1255` | `rpc_result_post_upgrade_check_target` | targets iterate the `release_targets` parameter | `inventory_source` / `discover_targets` target checks |
| `old_owner_isolation.py:1558` | `rpc_result_inspect_data` | nested `inspect` has several input routes (outer tx data, constructor tail, decoded values, payload children); no single producer | outer-tx `typed` check and `old_owner_calldata_payload_shape` |

## 6f

H1/H2: `execution_integrity.check(rebuild_commit)` runs sanitized Git checkout
checks followed by a scan of the current `sys.modules` snapshot. Git runs with
`cwd=u.ROOT`, every inherited `GIT_*` variable removed, and
`GIT_CONFIG_NOSYSTEM=1`. The resolved top-level must match `u.ROOT`; lowercase
index tags and `S`/`s` are refused. Existing `execution_head` and
`execution_clean_tree` checks remain. Each loaded module whose `__file__`
resolves inside the repository must have a Python source file tracked at the
rebuild commit, with bytes identical to `git show`. Untracked/ignored modules
and bytecode-only imports without source are refused. This checks on-disk
sources, not in-memory bytecode; it is not an OS sandbox.

The live sender calls the shared helper before its first `signing_transaction`
and again after confirmation and the final transaction/fee checks, immediately
before entering the broadcast block. `run_manifest` retains its
`execution_tree_gates` entry point, which delegates to the shared helper before
the read guard starts. M: the guard also intercepts read-mode `os.open` and
`subprocess.Popen`, preserving the git-command refusal for the existing `run`
path and the subprocess convenience APIs. Its docstring states the
accidental-read scope.

New gate names (scope: `execution_integrity.py`): `execution_root`,
`execution_index_flags`, `execution_module_tracked`, `execution_module_bytes`.
The new uniqueness test scans these seven executor source files together:
`a3a_exec.py`, `a3a_send.py`, `sp_upgrade_exec.py`, `manifest_exec.py`,
`old_owner_isolation.py`, `execution_reads.py`, and `execution_integrity.py`.
The existing gate-name suite/probe keeps its original scope. The deletion runner
uses temporary source trees exclusively and requires one source site, a green
baseline, at least one named assertion failure, zero errors, and exit status 1
for each mutant. It probes the four new gates and the existing
`execution_repo_read` gate (both `os.open` and direct `Popen`).

The statement-only declaration format cannot represent the helper extraction,
new module, and call-site changes. `gate_6f_additions.json` explicitly records
six file deltas against `81d074ce`, exact pre/post byte hashes, whole-module AST
fingerprints and locations, and individual gate locations/fingerprints. The
rename audit verifies those declarations before checking their preimages using
all existing rename rules. Declaration tests reject changed bytes and changed
gate locations. No wildcard exemption was added. The 64 manifest dependency
hashes in `gate_finite_domains.json` were repinned after checking each enclosing
function AST against its existing fingerprint; labels and scope fingerprints
are unchanged. Count scope: that JSON file's `source_sha256` entries referring
to `script/upgrade/manifest_exec.py`.

Minimal fixture substitutions:

- `execution_git_fixture.clean_checkout`: patch `execution_integrity.check` for
  synthetic plans, replacing the two fake Git subprocess responses. Existing
  callers in manifest/read tests are unchanged.
- `test_a3a_send.SenderTests.setUp` and `SenderS7Integration.setUp`: patch the
  shared integrity helper; the synthetic sender plan now includes a rebuild
  commit. The dedicated integrity tests exercise the real helper at both sender
  checkpoints and assert no broadcast after a stop.
- The existing `rehearsal_fault` patch of `execution_tree_gates` is unchanged.

No commit, real RPC, chain operation, environment-file read, or real keystore
access was performed. Tests use offline fixtures and temporary Git repositories;
the sender suite retains its existing offline signing fixtures. `assert_stop`
is unchanged and catches only `a.Gate`. Early fixture failures and an interrupted
combined suite run were not accepted. A later session-leader sender run received
SIGHUP from the real-PTY test; rerunning without session leadership passed, with
no test or gate disabled.

Final foreground results (verbatim final lines; accepted reruns only):

The sequential driver reported 11/12 because it retained the interrupted
sender attempt. This accepted ledger substitutes only its successful foreground
rerun (tool session 60565, exit 0); all other suite exits were 0. Suite summary
lines below are copied verbatim from their logs; some suites print buffered
control diagnostics after the unittest summary. Intentional mutant FAIL output
is not a passing-suite error.

```text
test_a3a_exec
Ran 102 tests in 3.006s
OK

test_a3a_send
Ran 73 tests in 31.636s
OK

test_manifest_exec
Ran 535 tests in 450.792s
OK (skipped=2)

test_manifest_phase_c
Ran 141 tests in 205.499s
OK

test_old_owner_isolation
Ran 143 tests in 39.395s
OK (skipped=2)

test_sp_upgrade_exec
Ran 141 tests in 1.725s
OK

test_execution_head
Ran 6 tests in 1.283s
OK

test_execution_reads
Ran 10 tests in 0.101s
OK

test_swallow_exceptions
Ran 9 tests in 2.604s
OK

test_authority_checkpoints
Ran 10 tests in 17.422s
OK

test_gate_names
Ran 27 tests in 30.628s
OK

test_execution_integrity
Ran 14 tests in 3.845s
OK

FOREGROUND_SUITES scope=11_requested_suites+test_execution_integrity passed=12 total=12
execution_root PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_index_flags PASS sites=1 baseline=green failures=2 errors=0 named=True
execution_module_tracked PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_module_bytes PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_repo_read PASS sites=1 baseline=green failures=2 errors=0 named=True
EXECUTION_INTEGRITY_PROBES PASS scope=4_new_integrity_gates+existing_read_gate passed=5 total=5
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS
GATE_RENAME_AST_DIFF PASS n_changes=364
HEAD_UNCHANGED 81d074ce3387f874a02a02606083bf598bbec6b9
ASSERT_STOP_UNCHANGED scope=script/upgrade/gate_assertions.py catches=a.Gate
INDEX_UNCHANGED scope=this_worktree staged_files=0
OWNED_TEMP_TREES scope=commit6f-tree-*,commit6f-probe-* remaining=0
GIT_DIFF_CHECK scope=this_worktree PASS
```

AST audit count scope: Python files under `script` shared by `2acc71af`
and WORKTREE, with added files fingerprinted and the explicit 6f declarations
verified. `n_changes` counts audit change records, not new gate names.

All owned foreground tool sessions completed. Blocking probe/helper subprocess
calls were reaped, and owned temporary trees were removed. No background job
was launched or left running. Lifecycle scope is this task’s owned sessions
and temporary paths, not a system-wide process census. Full accepted suite logs:
`/tmp/commit6f-final/`; probe/audit logs: `/tmp/commit6f-final-probes.log`,
`/tmp/commit6f-final-names.log`, `/tmp/commit6f-final-ast.log`; consolidated
accepted ledger: `/tmp/commit6f-accepted-final.txt`.


## 6g

Daybreak round 2 High: the sender now creates a fresh integrity module from the
exact repository `script/upgrade/execution_integrity.py` file with
`spec_from_file_location` under a private name on each check. It never imports
that helper from `sys.modules`. The existing pre-signing and post-confirmation
checks remain in place.

`execution_module_origin` enumerates Python basenames tracked at the reviewed
commit under `script/a3a` and `script/upgrade`. Every loaded exact name must have
a file whose resolved path equals its repository path; external and missing
origins stop. Existing tracked-source and byte gates remain unchanged. Exact-name
regressions cover an external `a3a_exec`, a missing origin, and a permissive
preloaded `execution_integrity` (also preloaded under the private loader name).
The sender regression asserts that signing and broadcasting are never reached.
The new gate's strict single-site deletion probe uses only temporary source trees
and requires named assertion failures with zero errors. `assert_stop` is unchanged
and accepts only `a.Gate`.

Updated `gate_6f_additions.json` declarations retain their pinned preimages and
record the current byte/AST fingerprints and explicit gate locations, with 6g
reasons. Sender fixtures patch the sender wrapper; the integrity regressions use
the real loader. The only change to `execution_reads.py` is one docstring sentence
listing the accepted case-alias path and `sh -c git` bypasses.

All requested commands ran in the foreground using offline fixtures, with no live
RPC, environment-file, keystore, or chain access. No commit, staging, or background
job was performed. Full command logs: `/tmp/commit6g-final/`.

Verbatim final lines from the requested checks:

```text
GATE_RENAME_AST_DIFF PASS n_changes=364

GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS

execution_module_origin PASS sites=1 baseline=green failures=2 errors=0 named=True
execution_root PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_index_flags PASS sites=1 baseline=green failures=2 errors=0 named=True
execution_module_tracked PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_module_bytes PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_repo_read PASS sites=1 baseline=green failures=2 errors=0 named=True
EXECUTION_INTEGRITY_PROBES PASS scope=5_integrity_gates+existing_read_gate passed=6 total=6

test_execution_integrity
Ran 16 tests in 5.561s
OK

test_a3a_send
Ran 74 tests in 34.019s
OK

test_a3a_exec
Ran 102 tests in 3.448s
OK

test_manifest_exec
Ran 535 tests in 423.279s
OK (skipped=2)
L1_CONTROL old_owner_creation_before removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0

test_execution_head
Ran 6 tests in 1.247s
OK

test_execution_reads
Ran 10 tests in 0.087s
OK

test_gate_names
Ran 27 tests in 31.385s
OK

FOREGROUND_6G_CHECKS PASS passed=9 total=9
HEAD_UNCHANGED 383315b0005bee77e26c42e894106aa10e79803f
INDEX_UNCHANGED staged_files=0
ASSERT_STOP_UNCHANGED catches=a.Gate
```


## 6h

Daybreak round 3 trusted bootstrap: manifest execution exact-loads the repository
integrity helper under a private module name. The helper starts with stdlib-only
origin/committed-byte checks rooted at its own resolved `__file__`, using sanitized
Git environment variables before invoking first-party modules. It exact-loads the
verified Gate implementation and its verified RPC-classification dependency;
the private Gate subclasses the authenticated canonical Gate, preserving strict
`assert_stop` compatibility. Bootstrap rejection is `execution_bootstrap_origin`.

Real temporary repositories cover clean sender/manifest checks, external integrity
modules through both entry points, and external `sp_upgrade_exec` with permissive
`a.need` through the sender. The new single-site deletion probe requires a named
assertion failure and zero errors. Existing gate assertions remain intact.
Byte/AST declarations and explicit gate locations are updated in
`gate_6f_additions.json`; finite-domain dependency hashes are refreshed without
changing labels or scopes. Synthetic fixtures patch their public wrappers.

All requested commands ran in the foreground, offline. After preserving existing
manifest template line locations and refreshing dependency hashes, the AST audit,
both probes, gate-name suite and integrity suite were rerun successfully. No RPC,
environment-file, keystore or chain access; no commit, staging or background job.
Full logs: `/tmp/commit6h-final/`.

Verbatim final lines:

```text
GATE_RENAME_AST_DIFF PASS n_changes=366

GATE_UNIQUENESS_PROBE PASS sites=1 baseline=green failures=3 errors=0 named=True
GATE_FUNDING_LABEL_PROBES PASS 9/9 strict red
GATE_NAME_PROBES PASS

execution_bootstrap_origin PASS sites=1 baseline=green failures=2 errors=0 named=True
execution_module_origin PASS sites=1 baseline=green failures=2 errors=0 named=True
execution_root PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_index_flags PASS sites=1 baseline=green failures=2 errors=0 named=True
execution_module_tracked PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_module_bytes PASS sites=1 baseline=green failures=1 errors=0 named=True
execution_repo_read PASS sites=1 baseline=green failures=2 errors=0 named=True
EXECUTION_INTEGRITY_PROBES PASS scope=6_integrity_gates+existing_read_gate passed=7 total=7

test_execution_integrity
Ran 18 tests in 18.966s

OK

test_a3a_send
Ran 74 tests in 31.839s

OK

test_a3a_exec
Ran 102 tests in 3.070s

OK

test_manifest_exec
Ran 535 tests in 427.306s

OK (skipped=2)
L1_CONTROL old_owner_creation_before removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0

test_manifest_phase_c
Ran 141 tests in 213.048s

OK

test_execution_head
Ran 6 tests in 1.216s

OK

test_execution_reads
Ran 10 tests in 0.090s

OK

test_gate_names
Ran 27 tests in 33.577s

OK

FOREGROUND_6H_CHECKS PASS passed=11 total=11

HEAD_UNCHANGED 6aff70e4f57051d642032e401e9c016e7db6afe6
INDEX_UNCHANGED staged_files=0
ASSERT_STOP_UNCHANGED catches=a.Gate
```

## 6i — helper bytes verified before the helper runs (operator, 2026-11-08)

Daybreak Blue round 4: `REVIEW_608_DAYBREAK4 Critical=0 High=1 Medium=0 Low=1`.
High: both entry points executed the working-tree `execution_integrity.py` before
authenticating it. Fix (operator-written): `a3a_send.integrity_check` and
`manifest_exec.execution_tree_gates` compare the helper's bytes with
`git show <rebuild commit>:script/upgrade/execution_integrity.py` (sanitized GIT env,
stdlib only) before `exec_module`; gates `execution_integrity_source` and
`execution_integrity_source_manifest`. The helper then attests every loaded repository
module, the entry point included, which closes the loop.
Low (a legitimate external harness module whose basename collides with a tracked
`script/**.py` causes `execution_bootstrap_origin`): accepted residual — it fails closed
and no tracked basename collides in CLI execution.

Positive tests (`HelperSourceTests`, edited helper with a leftover early `return`):
`Ran 2 tests ... OK`. Strict deletion probes (temporary copy of `script/`, gate line
replaced by `pass`):
```text
PROBE test_execution_integrity_source sites=1 FAILED (failures=1)
PROBE test_execution_integrity_source_manifest sites=1 FAILED (failures=1)
```
Suites: test_execution_integrity `Ran 20 ... OK`; test_a3a_send `Ran 74 ... OK`;
test_a3a_exec `Ran 102 ... OK`; test_execution_head `Ran 6 ... OK`;
test_execution_reads `Ran 10 ... OK`; test_gate_names `Ran 27 ... OK` (after refreshing
the 64 `manifest_exec.py` dependency digests in gate_finite_domains.json).
`GATE_RENAME_AST_DIFF PASS n_changes=366`; `GATE_NAME_PROBES PASS`.


## 6j

DSR ruling `9fa206f9`, D / M7, test-only continuation. No commit, production edits,
RPC endpoints, environment files, keystores, chain access, or background jobs.
`assert_stop` is unchanged and catches only `a.Gate`; ERROR is never accepted.
The 20 remaining source-spelling controls are all retained. Nine sites have
additional method (a) behavioural controls; eleven remain known gaps. This is
not a claim of full M7 completion.

`DiscoverySubstitutionTests` supplies an independent, explicit good state:
`FACTORY=0x1111111111111111111111111111111111111111`,
`RELEASE=0x2222222222222222222222222222222222222222`,
`OTHER=0x3333333333333333333333333333333333333333`, zero ABI word, and `0x6000`
code. `setUp.targets` lists each target explicitly using these literals and
existing address constants `u.REG`, `u.SP`, `u.TL`, and
`isolation.PAYMASTER_FACTORY`; `setUp.tokens` is the sorted literal
`isolation.ROUND_CLONES` tuple. `setUp.good` contains those targets and tokens;
`setUp.pin` declares their empty role/approval histories and inventories.
The fixture `array` helper only ABI-encodes these supplied literal token lists.
None of the substitute values comes from the mutated function or a function
it calls. Each probe line identifies its exact fixture source.

Adverse fake-RPC replies change the factory pointer (4, 6, 23), add a token
(15, 24, 25), remove release-factory code (16), return OLD as owner (18), or
return a nonzero allowance (19). Real-tree tests demand the exact listed STOP.
For 4 and 23, role-history scanning is held at an empty fixture history so it
cannot mask discovery drift. For 23, unrelated DVT/pointer/authority checks and
the pure coverage input are stubbed; the real `dvt_closing` inventory call and
real `closing_timelock_inventory` discovery/comparison remain exercised.

`probe_discovery_substitutions.py` copies tracked files (excluding `.env*`) into
a temporary tree, includes the new untracked probe, locates exactly one AST
call in its named function, and replaces only that expression with the literal
fixture value. Each mutant runs in a fresh foreground interpreter against the
copied tests and production modules. The real worktree is never mutated by the
probe. Acceptance requires a green real-tree baseline, one source site,
failures >= 1, errors == 0, and an assertion message naming the expected gate.

### 6j known gaps

These are limitations of method (a) with a good-state substitute and an
adversarial RPC state, not untested claims of equivalent behavioural coverage.
Changing plan inputs or substituting an intentionally incomplete inventory is
not counted as the requested method.

| Site | Gate | Why method (a) fails | Retained coverage |
|---|---|---|---|
| 0: `rebuild_commit / inventory_source` | `discovery_old_authority` | Release source inventory is read from a build tree, not RPC. A good inventory still feeds the later authority reads; an RPC-only attack does not distinguish the substitution. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_0` |
| 1: `build_expected_discovery / pin_discovery` | `discovery_step_table` | The named gate compares step IDs and required IDs, independently of the initial discovery state and RPC. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_1` |
| 2: `expected_discovery / pin_discovery` | `old_timelock_delta_targets` | This is a pure pinned-state initializer. Passed-step snapshots replace it; otherwise an identical good pinned state leaves the live target comparison intact. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_2` |
| 3: `discovery_coverage / expected_discovery` | `old_timelock_delta_targets` | Expected state depends only on the plan and passed steps. Substituting its good-state value does not bypass live discovery or target comparison. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_3` |
| 5: `closing_timelock_inventory / pin_discovery` | `old_timelock_inventory` | With discoveryExpected present the eagerly evaluated default is unused. Without it the good pinned default is the same comparison operand; live drift still stops. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_5` |
| 7: `post_pin_delta / pin_discovery` | `old_timelock_delta_xpnts` | With discoveryExpected present the default is unused. Otherwise a good pinned default preserves the token comparison against adversarial RPC discovery. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_7` |
| 8: `dvt_closing / discovery_coverage` | `old_timelock_inventory` | Coverage is a pure plan-derived value. A matching good coverage substitute still reaches the real closing inventory comparison and rejects RPC drift. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_8` |
| 10: `finish / build_expected_discovery` | `discovery_step_table` | The step-table gate validates plan structure during construction, without live RPC input. An adversarial RPC state cannot trigger this named gate. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_10` |
| 11: `pre_send / discovery_coverage` | `old_timelock_delta_targets` | A good coverage value retains the expected targets; real post-pin discovery still rejects adversarial RPC targets. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_11` |
| 17: `discovery_old_authority / authority_rows` | `discovery_old_authority` | Rows depend on the pinned inventory, not RPC results. Substituting the same complete good row list retains the bad authority read; omitting the affected row would be an incomplete rather than good inventory. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_17` |
| 20: `build_expected_discovery / assert_manifest_calldata` | `discovery_unlisted_effect` | This decoder and its named gate operate on plan calldata/step IDs, not RPC. The existing adverse plan control is outside the requested RPC-state method. | covered by the existing source-spelling control `DiscoveryCallSourceTests.test_call_20` |

### Foreground verification

`python3 script/upgrade/probe_discovery_substitutions.py` — per-site records and aggregate, verbatim:

```text
4: gate=old_timelock_inventory sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.setUp.good PASS
6: gate=old_timelock_delta_targets sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.setUp.good PASS
15: gate=old_timelock_delta_xpnts sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.setUp.targets+tokens PASS
16: gate=old_timelock_delta_targets sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.CODE PASS
18: gate=discovery_old_authority sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.WORD_ZERO PASS
19: gate=discovery_old_authority sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.WORD_ZERO PASS
23: gate=old_timelock_inventory sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.setUp.pin (literal clean inventory) PASS
24: gate=old_timelock_delta_xpnts sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.array([]) PASS
25: gate=old_timelock_delta_xpnts sites=1 baseline=green failures=1 errors=0 named=true substitute=DiscoverySubstitutionTests.array(setUp.tokens=sorted(ROUND_CLONES)) PASS
0: gate=discovery_old_authority GAP source-control=DiscoveryCallSourceTests.test_call_0
1: gate=discovery_step_table GAP source-control=DiscoveryCallSourceTests.test_call_1
2: gate=old_timelock_delta_targets GAP source-control=DiscoveryCallSourceTests.test_call_2
3: gate=old_timelock_delta_targets GAP source-control=DiscoveryCallSourceTests.test_call_3
5: gate=old_timelock_inventory GAP source-control=DiscoveryCallSourceTests.test_call_5
7: gate=old_timelock_delta_xpnts GAP source-control=DiscoveryCallSourceTests.test_call_7
8: gate=old_timelock_inventory GAP source-control=DiscoveryCallSourceTests.test_call_8
10: gate=discovery_step_table GAP source-control=DiscoveryCallSourceTests.test_call_10
11: gate=old_timelock_delta_targets GAP source-control=DiscoveryCallSourceTests.test_call_11
17: gate=discovery_old_authority GAP source-control=DiscoveryCallSourceTests.test_call_17
20: gate=discovery_unlisted_effect GAP source-control=DiscoveryCallSourceTests.test_call_20
COMMIT6J_PROBES PASS method_a=9/9 gaps=11 total=20
```

`python3 script/upgrade/test_gate_names.py` — verbatim final lines:

```text
----------------------------------------------------------------------
Ran 27 tests in 36.098s

OK
```

`python3 script/upgrade/test_manifest_exec.py` — verbatim unittest summary:

```text
Ran 544 tests in 549.428s

OK (skipped=2)
```

Buffered control stdout followed the unittest summary in the combined capture.
Verbatim final output lines:

```text
L1_CONTROL old_owner_implementation removed=assertion-failure errors=0
L1_CONTROL old_owner_creation_before removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL unexpected_proxy_other removed=assertion-failure errors=0
L1_CONTROL old_owner_undeclared_clone removed=assertion-failure errors=0
```

All three foreground commands exited 0. `git diff --check` passed.
The tracked diff contains only `script/upgrade/test_manifest_exec.py` and this
results file; the only new untracked file is
`script/upgrade/probe_discovery_substitutions.py`. Production modules and
`gate_assertions.py` are unchanged. HEAD remains `d21042ad`; no commit made.

## 6k — d21042ad full-run triage: harness and stale-driver fixes (2026-11-08)

Scope: `script/evidence/run_all_6j.sh` predecessor run at d21042ad, bin engine, every
`script/upgrade/probe_*.py` plus the enduser / inventory / registry drivers. Ten drivers were
red. None was a defect in executor or sender logic and no Solidity contract is involved; one
was a real coverage gap (6i source gates without a committed deletion probe).

| Driver | Red result | Cause | Fix in 6k |
|---|---|---|---|
| `test_gate_typed_controls` | `FAILED (failures=1)` | `gate_typed_inventory.json` held pre-6g `a3a_send.py` lines | lines 134→151, 147→164 |
| `probe_typed_gates` | `FileNotFoundError candidates.json` | harness never ran `--discover` | harness runs `--discover` first; expected `passed=82 total=88 blocked=6` (6e known gaps) |
| `probe_execution_head` | `FAIL 0/2` sites=0 | gates moved to `execution_integrity.py` in 6f | probe reads `t.integrity` |
| `probe_finite_gate_blockers` | `FAIL 6/23` | identical to the 6e record; superseded by `probe_gate_dsr2` + `--remaining` | harness tags it INFO; `mkdir` before writing its report |
| `probe_finite_gate_labels` | `INCOMPLETE 181/746` | prefix-discovery helper, never an acceptance gate | harness tags it INFO |
| `probe_gate_templates` | `FAIL 159/171` | harness ran probes from `script/upgrade/`; safe-governance fixture paths are repo-root relative | harness runs every driver from the repo root |
| `probe_gate_rename_controls` | `FAIL 4/5` | same cwd cause | same |
| `probe_phase_c_gates 616e7979` | 54 "uncovered new gates" | `new_gates()` ignored `gate_rename_map.json` | renames excluded and printed; `COVERED_ELSEWHERE` requires the gate literal in the covering driver; base 645ff3a1 |
| (gap) `execution_integrity_source`, `execution_integrity_source_manifest` | no committed probe | 6i probes were ad hoc | added to `probe_execution_integrity.py` (9/9) |
| `enduser_mapping_probes` | `discovery_call_1/_20` errors=1 | since 6d the source-only tests shared a plan-building `setUpClass` | source-only tests moved to `DiscoveryCallSourceTests`; summary labels split |

### 6k known gap — renamed gates without a by-name deletion probe (DSR log c0cff66a)

The 52 gates below are 6e renames (old name present at 645ff3a1, mapped in
`gate_rename_map.json`). Neither the old nor the new name has a by-name deletion probe; the
rename itself is proven name-only by `gate_rename_ast_diff.py`. Recorded, not waived; no
aggregate credits them. Not addressed in this release.

`C_control_slot_allowance_used`, `C_operator_before_approve`, `a3a_gap_mined_before_pin_recording`, `a3a_gap_mined_before_pin_replay`, `a3a_mined_history_`, `a3a_mined_reconcile_`, `built_aggregator_version_rebuild_commit`, `built_aggregator_version_release_gate`, `evidence_scope_recomputed_validate_evidence_details`, `evidence_slither_rederived_filename`, `evidence_slither_rederived_findings`, `evidence_slither_rederived_path_containment`, `evidence_slither_rederived_path_syntax`, `evidence_slither_rederived_reference_fields`, `evidence_slither_rederived_success`, `evidence_unique_findings_all_scope`, `evidence_unique_findings_in_scope`, `fixed_old_aggregator_build_plan`, `fixed_old_aggregator_collect`, `fraud_token_fields_arm`, `fraud_token_fields_mock`, `manifest_local_only_pre_send`, `manifest_local_only_run_manifest`, `manifest_plan_key_`, `manifest_step_key_`, `manifest_tx_field_`, `prefix_boundary_prior_stage`, `readback_value_`, `safe_gap_endpoints_check_governance`, `safe_gap_endpoints_governance_evidence`, `safe_gap_hash_check_governance`, `safe_gap_log_data_approval`, `safe_gap_log_data_swap_execution`, `safe_gap_log_data_swap_tail`, `safe_gap_log_logIndex_sequence`, `safe_gap_miner_balance_delta`, `safe_gap_owner_eoa_live`, `safe_gap_owner_eoa_pin`, `safe_gap_pin_nonce_live`, `safe_gap_pin_nonce_pin`, `safe_gap_pin_owners_live`, `safe_gap_pin_owners_pin`, `safe_gap_pin_threshold_live`, `safe_gap_pin_threshold_pin`, `safe_gap_receipt_identity_fields`, `safe_gap_trace_storage_mapping`, `stage_not_final_load_artifact`, `stage_not_final_save_artifact`, `stake_not_unlocking_build_plan`, `stake_not_unlocking_collect`, `verifier_commit_validate_external`, `verifier_commit_verifier_artifact`

## 6l — 678e68b0 full-run triage (evidence/probe scripts only; no production module changed)

Full run 678e68b0 (run_all_6j.sh, bin = forge 1.7.1, nightly = 1.8.7-nightly). Every suite rc=0 on both engines
(e.g. test_manifest_exec `Ran 544 tests` / `OK (skipped=2)`). Three findings, none in product code:

| # | Item | Class | Fix |
|---|------|-------|-----|
| T1 | probe_typed_gates `passed=69 total=88 blocked=19` (both engines) | expectation error: the 6e `82/88/6` is the union of three drivers | `script/evidence/rpc_result_merge.py` (union; exit 0 iff remaining blocked == the 6 known gaps and 88 sites); run_all_6j.sh calls it per engine |
| T2 | audit605 `PROBED 85 OK 85 MISSING [9 × ('run_manifest', …)]` | probe stale since 2acc71af split run_manifest into a wrapper + `_run_manifest`; the 9 gates were silently absent from the deletion probes | probe_gate_removal.py PHASE_FUNCTIONS += `_run_manifest`; audit605 F05 key → `_run_manifest` |
| T3 | ast-diff `GATE_RENAME_AST_DIFF FAIL n_changes=310` (first red at f745c729/6j; d21042ad PASS 366) | 6j/6k test/probe edits never declared | 6 rows in gate_6f_additions.json, baseline d21042ad, pinned before/after/AST sha256, gates=[] |

Checks (scan scope: the named files):
- No `a.need/a.typed/a.exact_keys/a.address` call added in the 6 declared files since d21042ad; no production
  file (a3a_exec, a3a_send, manifest_exec, old_owner_isolation, sp_upgrade_exec, execution_integrity,
  execution_reads) changed since d21042ad. The 10 `'x' -> 'y'` REJECTED rows in probe_phase_c_gates.py are
  list-position shifts from inserted rows, not gate renames.
- `GATE_RENAME_AST_DIFF PASS n_changes=372`; control: one appended byte in test_manifest_exec.py →
  `REJECTED 6f after fingerprint mismatch: script/upgrade/test_manifest_exec.py`.
- rpc_result_merge on 678e68b0 logs: `RPC_RESULT_MERGED [bin] passed=82 total=88 blocked=6` and
  `[nightly]` identical, `RPC_RESULT_MERGE PASS blocked_equals_known_gaps=True`; control with the
  scheduled_eta producer PASS removed → `passed=81 … blocked=7`, `RPC_RESULT_MERGE FAIL`, rc=1.
- T2 targeted (9 `_run_manifest` rows, same criterion as audit605): `RUN_MANIFEST_PROBES PASS 9/9` on bin and nightly.
- test_execution_integrity now asserts the exact 14 declared files: bin/nightly `Ran 20 tests` / `OK`;
  probe_execution_integrity bin/nightly `PASS … passed=9 total=9`.
