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
