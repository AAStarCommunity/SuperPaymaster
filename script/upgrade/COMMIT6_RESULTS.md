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
