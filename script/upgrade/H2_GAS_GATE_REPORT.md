# DSR H-2: real-chain gas gate

Base: `cc125/chain-gas-gate`, `9edde2b18eec455faf993d65aa81bc7a30b931c7`.
No commits, remote RPC calls, fork launches, signing, or broadcasting were performed for this change. Tests use offline fixtures and local ABI tools.

## Survey at the base commit

The existing field names are retained: `estimateGas` means the **remote chain estimate**, `localEstimateGas` means the **fork estimate**, and `forkGasUsed` means the mined fork receipt's consumption. An uncalibrated plan deliberately has no gas limits or fabricated measurements; only a calibrated/frozen artifact is eligible for measured validation.

| Executor / complete step families | Limit calculation | Remote estimate and dependencies | Frozen validation / pre-send |
|---|---|---|---|
| A3a: S1, S2, S3, S4, S5a/b, S6a/b, S7 | ceil(13/10 × max(remote, local, fork used)); pilot then final execution | `eth_estimateGas(tx, pin.block, cumulative stateOverrides, {time: executionTimestamp})`; traces accumulate earlier effects | Exact margin checked offline. Context is only in rehearsal log, not bound by offline plan validator. Latest estimate checked by `pre_send` and future `signing_transaction`. No separate block ceiling check in that validator. |
| A6e: deploy, freeze, pause_*, transfer, upgrade/activation schedule/execute approve/exec | Shared `measure_step` / `margin_limit`; CREATE also includes independently searched mined minimum, RR witness and caps | Same pin/override mechanism; inherits `archive_overrides` from A3a | Records all three measurements; exact margin checked by `validate_gas`. Context only logged. `pre_send_gas` and latest block ceiling checked. Rehearsal calls use the fork RPC. |
| Manifest a7 prefix: A1, A2, A3.create/sp/tier/seal, A4.ext/token/factory, A5, A6.create/upgrade, A7 | Reuses A6e `measure_step`, including CREATE protections | Remote at pin, cumulative trace overrides and block time | Reuses `validate_gas`; context not persisted in frozen step. Measured pre-send checks fork latest. |
| Manifest b4/full continuation: A8.registry/dvt/committee, A9.new/old, A10.*, A11.min/default, A12a/b, A13.stake/deposit, A14.*, A15.deployer/anni/revenue, A16, A17 | Same shared measurement | Same | Same |
| Manifest Phase B: upgrade/activation schedule/execute approve/exec, B2a_approve/exec | Same shared measurement, including every Safe approveHash | Same | Same |
| B4 apply | Shared measurement during calibration; frozen execution retains prior measurement | Remote pinned estimate during calibration | Ordinary frozen step validates apply margin, but B4 execution skipped measured pre-send. |
| B4 placeholder | Local estimate, pilot, exact intrinsic gas (no 1.3 margin) | **No remote estimate** | Only intrinsic floor and transaction quantity checks; no three-measurement validation or fresh estimate. |
| Full-only Phase D: D.registry.transfer, D.registry_schedule/execute approve/exec, D.*.admin/transfer | Shared measurement | Same | Same |

`a7` ends at A7; `b4` includes the prefix through B4; `full` additionally includes Phase D. Phase C is explicitly absent from this executor. All ordinary manifest steps already reused A6e measurement; B4 placeholder was the exception. Both manifest and upgrade CLI signing/sending remain disabled. Rehearsal pre-send checks must not be described as actual live broadcasts.

## Implementation

- Shared `measure_step` now attaches manifest `gasEvidence`: exact estimate context, preceding step IDs, and real-chain pinned block gas limit. Frozen replay compares this evidence to newly measured context. Unsupported remote estimates stop at `remote_estimate_unavailable`.
- Manifest frozen validation requires the remote measurement, matching pin, preceding prefix, state overrides for dependent steps (also when continuing from a later state block), matching time override, all three positive integer measurements, exact 13/10 margin, and the recorded block ceiling.
- CREATE's existing mined minimum and RR witness remain additional requirements. Its exact limit remains ceil(13/10 × max(remote estimate, fork estimate, fork gas used, mined minimum)).
- Both B4 payloads use the shared measurement mechanism. Placeholder evidence is stored separately in `variantMeasurements.placeholder`, and cannot inherit missing measurements from apply.
- Every manifest execution path, including both B4 choices, calls measured local pre-send and remote `fresh_gas` before execution. Remote rehearsal checks request `latest` plus accumulated state/time overrides because earlier steps have only executed on the fork. A live caller of `fresh_gas` omits overrides and checks actual `latest` state. The helper also checks the latest remote block ceiling.
- Measurement metadata is stripped from the deterministic stage-prefix payload, preserving staged rebuilding while retaining it in the frozen artifact.
- Pinned Amsterdam engine selection and validation are unchanged (`4e8874b2bdc840929585ca73e170993c50a4a531`). No default Anvil measurement fallback was added.

Offline evidence checks detect absent override context and replay detects changed overrides; they do not independently reconstruct a remote chain from serialized JSON. Actual provider support remains untested under the offline-only constraint. No particular step has been established as unestimatable; any such remote failure stops with the step ID and named gate, including a B4 apply that becomes unestimatable before submission.

## Negative controls and gate-removal probes

`python script/upgrade/probe_gas_gates.py` suppresses one named gate at a time in memory, runs its corresponding test, and requires that test to turn red. Production files are not modified by the probes.

| Control | Expected gate | Baseline | Gate suppressed |
|---|---|---|---|
| Remote 135104, fork estimate 53160, fork used 68394; gas covers fork margin but not remote margin | `measured_gas_limit` | PASS | RED |
| Missing remote `estimateGas` | `remote_estimate_missing` | PASS | RED |
| Estimate block differs from pin | `remote_estimate_pin` | PASS | RED |
| Dependent step has empty state overrides | `remote_estimate_overrides` | PASS | RED |
| Latest estimate exceeds frozen limit | `fresh_estimate` | PASS | RED |
| Limit exceeds block ceiling | `block_gas_limit` | PASS | RED |

Additional controls cover a consistent plan, unsupported remote estimation, real shared-measurement serialization/replay against offline RPC doubles, changed overrides on replay, and every step in each manifest stage (including independent placeholder evidence). Execution tests assert one remote fresh check for every manifest step.

## Final verification

All commands ran from repository root. Final output lines:

```text
python script/upgrade/test_manifest_exec.py
Ran 202 tests in 255.785s
OK

python script/a3a/test_a3a_exec.py
Ran 102 tests in 3.298s
OK

python script/upgrade/test_sp_upgrade_exec.py
Ran 141 tests in 1.640s
OK

python script/upgrade/test_pop_adapter.py
Ran 53 tests in 0.286s
OK

python script/upgrade/test_release_evidence.py
Ran 69 tests in 3.759s
OK

python script/upgrade/probe_gas_gates.py
GAS_GATE_PROBES PASS 6/6
```

The final focused gas/stage/B4 run passed 13 tests in 14.651s. `git diff --check` passed. HEAD remains `9edde2b18eec455faf993d65aa81bc7a30b931c7`; changes are uncommitted.
