# DSR H-2: real-chain gas gate

Commits on `cc125/chain-gas-gate` (PR #599): `6a615186` (gate), `b1f52040` (challenge round 1), `17a00c5d` (round 2), `b256ac8a` (merge of main `7c0d6caf`), then the DSR review fix recorded in the final section. No remote RPC calls, fork launches, signing or broadcasting were performed for this change; tests use offline fixtures and local ABI tools.

## Original survey at `9edde2b18eec455faf993d65aa81bc7a30b931c7`

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
- Both B4 payloads use the shared measurement mechanism. Frozen execution replays the REMOTE pinned measurements for BOTH apply and placeholder against reconstructed overrides, compares `estimateGas` and `gasEvidence`, and runs `validate_gas_evidence` before selecting either payload. Only the selected payload receives full replay, including the local fork estimate. A permissionless apply already reflected on the fork therefore permits placeholder selection without locally estimating the now-reverting apply. Placeholder evidence is stored separately in `variantMeasurements.placeholder`, and cannot inherit missing measurements from apply. Tampered apply estimates/limits stop at `replay_estimateGas`; irrelevant nonempty overrides stop at `replay_gasEvidence`.
- Every manifest execution path, including both B4 choices, calls measured local pre-send and remote `fresh_gas` before execution. Remote rehearsal checks record `mode='pinned-consistency'` and request the PIN block plus accumulated state overrides and the step's time override. This repeats measurement's parameters and is a consistency check, not a freshness gate. A live caller of `fresh_gas` records `mode='live'`, omits overrides, and checks actual `latest` state. Freshness against chain changes after the pin is enforced only at live send time (`pre_send` on `latest`) and by re-pinning, not in rehearsal. Rehearsal's local `pre_send` checks only the fork's latest state; signing/sending remain disabled. The helper checks the block ceiling at the same selected block and returns `{mode, block}`; manifest execution records this as `freshGas`.
- Measurement metadata is stripped from the deterministic stage-prefix payload, preserving staged rebuilding while retaining it in the frozen artifact.
- Pinned Amsterdam engine selection and validation are unchanged (`4e8874b2bdc840929585ca73e170993c50a4a531`). No default Anvil measurement fallback was added.

Offline evidence checks detect absent override context and replay detects changed overrides; they do not independently reconstruct a remote chain from serialized JSON. Actual provider support remains untested under the offline-only constraint. No particular step has been established as unestimatable; any such remote failure stops with the step ID and named gate, including a B4 apply that is unestimatable in its pinned remote context. An unselected apply is never estimated against current fork state.

## Negative controls and gate-removal probes

`python3 -B script/upgrade/probe_gas_gates.py` suppresses one named gate at a time in memory and observes the actual control action. It requires the suppressed gate to be exercised but never raised. Other exceptions or test failures fail the probe; they cannot be mislabeled as acceptance. A secondary gate is reported as defense in depth, not proof that the removed gate alone is load-bearing. Production files are not modified by these probes.

| Suppressed gate | Baseline | Suppressed outcome |
|---|---|---|
| measured_gas_limit | PASS | accepted (load-bearing) |
| remote_estimate_missing | PASS | caught by measurement_estimateGas (defense in depth) |
| remote_estimate_pin | PASS | accepted (load-bearing) |
| remote_estimate_overrides | PASS | accepted (load-bearing) |
| fresh_estimate | PASS | accepted (load-bearing) |
| block_gas_limit | PASS | accepted (load-bearing) |


Additional controls cover a consistent plan, unsupported remote estimation, shared-measurement serialization/replay, changed overrides, and every step in each manifest stage (including independent placeholder evidence). Each missing-measurement mutation now uses a fresh deep copy. All gas controls assert the failing step ID as well as the gate, including Phase D. Shared gas failures preserve this ID in `record.step`.

Execution tests assert one remote fresh check for every manifest step. Mode tests assert both the estimate block tag/overrides and the block-ceiling lookup for live calls and rehearsal calls (including empty overrides). Probe tests check the six observed outcomes and reject a supposedly suppressed gate that still raises.

## Fix-removal checks

Offline in-memory source mutations and base-version comparisons produced:

| Fix removed | Observed regression |
|---|---|
| Frozen B4 apply replay | Both apply tampering controls fail because execution reaches selection instead of the required replay STOP. Placeholder controls remain protected. |
| Rehearsal estimate at PIN | Mode test fails: estimate parameters contain `latest` instead of `0x123`. |
| Independent mutation copies | Retaining the new step assertion with the old loop fails: `B4 != D.registry.transfer`. |
| README margin correction | Base text contains the stale “freezes that exact limit” statement; corrected text removes it and specifies the measured 13/10 margin. |
| Honest probe outcomes | Base probe prints generic RED for missing remote measurement; the outcome check fails because it omits `measurement_estimateGas` defense in depth. |

No source files were reverted during these checks. B4 regression controls mutate each variant independently: estimate 100000 / limit 130000 versus observed estimate 120000, and irrelevant `{ZERO_ADDRESS: {}}` evidence versus reconstructed overrides.

## Prior verification at 6a615186

The prior delivery recorded these offline results from repository root:

```text
python3 -B script/upgrade/test_manifest_exec.py
Ran 206 tests in 242.025s
OK

python3 -B script/a3a/test_a3a_exec.py
Ran 102 tests in 3.161s
OK

python3 -B script/upgrade/test_sp_upgrade_exec.py
Ran 141 tests in 1.691s
OK

python3 -B script/upgrade/test_pop_adapter.py
Ran 53 tests in 0.305s
OK

python3 -B script/upgrade/test_release_evidence.py
Ran 69 tests in 3.473s
OK

python3 -B script/upgrade/probe_gas_gates.py
GAS_GATE_PROBES PASS 6/6
```

The focused gas/probe run passed 13 tests. All five fix-removal checks above produced the expected regression. `git diff --check` passed. This round was committed as `b1f52040`. No remote RPC, fork launch, signing, or broadcasting was performed.

## Review regressions at b1f52040

The RPC-only `test_b4_preapplied_real_measurement` uses real replay and selection helpers and stops at the first pre-send RPC. The fork rejects local apply estimation with `NoPendingVerifierRotation`; valid evidence reaches placeholder pre-send, while tampered apply estimates and overrides STOP before local estimation. Existing execution controls separately cover reserved nonce consumption and receipts.

Fix-removal probes loaded the original HEAD functions in memory, leaving production files untouched:

- Original `execute_b4`: regression RED with `NoPendingVerifierRotation`.
- Original `fresh_gas`: regression RED because `rehearsal` differs from `pinned-consistency`.

## Final offline verification at b1f52040

All commands ran from repository root. Final lines:

```text
python3 -B script/upgrade/test_manifest_exec.py
Ran 207 tests in 236.679s
OK

python3 -B script/a3a/test_a3a_exec.py
Ran 102 tests in 3.477s
OK

python3 -B script/upgrade/test_sp_upgrade_exec.py
Ran 141 tests in 1.711s
OK

python3 -B script/upgrade/test_pop_adapter.py
Ran 53 tests in 0.358s
OK

python3 -B script/upgrade/test_release_evidence.py
Ran 69 tests in 3.512s
OK

python3 -B script/upgrade/probe_gas_gates.py
GAS_GATE_PROBES PASS 6/6

FIX_REMOVAL execute_b4 RED_CONFIRMED
FIX_REMOVAL fresh_gas RED_CONFIRMED
```

`git diff --check` passed. This round was committed as `17a00c5d`. Only offline fixtures and local ABI tools were used.

## DSR review of #599 (b256ac8a)

- Two gates had no negative control (replacing them with `pass` left all 218 manifest tests green): `remote_estimate_time` and `remote_estimate_prior_steps`. Added `test_wrong_time_override`, `test_wrong_prior_steps` (one prior step missing) and `test_tampered_prior_steps` (wrong id, duplicated id); both gates are in `probe_gas_gates.py`, which now reports 8/8, every suppressed gate leaving the bad input accepted except `remote_estimate_missing` (caught by `measurement_estimateGas`).
- Precondition for any future live sender (not implemented here: manifest signing/sending remain disabled, and `fresh_gas` live mode has no production caller yet). Before **each** signature the sender must call `fresh_gas` in live mode against `latest` without overrides and:
  - STOP if the live estimate exceeds the limit;
  - STOP and re-pin if the live estimate exceeds `floor(limit / 1.1)`: the limit is the pinned estimate x1.3, so a rise of more than about 18% means the state changed after the pin;
  - write the live estimate, block number and limit of every comparison into the send record.
  DSR reviews this together with the sender.
