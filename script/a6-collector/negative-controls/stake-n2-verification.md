# Archived validator exits (offline, 2026-10-30)

Every archived `*.jsonl` under `docs/design/aoa-balance-mode/data/` was checked before and after. Paths below are relative to that directory. Non-gauge ledgers also appear and retain exit 2.

| File | Before | After |
|---|---:|---:|
| `a6-gauge-credit/credit-off.jsonl` | 0 | 0 |
| `a6-gauge-credit/credit-on.jsonl` | 1 | 1 |
| `a6-gauge-credit/credit-queued.jsonl` | 1 | 1 |
| `a6-gauge-local/a-exec-revert.jsonl` | 3 | 3 |
| `a6-gauge-local/b-drop-op.jsonl` | 3 | 3 |
| `a6-gauge-local/c-wrong-hash.jsonl` | 3 | 3 |
| `a6-gauge-local/d-tamper-b.jsonl` | 2 | 2 |
| `a6-gauge-local/e-conservation-injected.jsonl` | 1 | 1 |
| `a6-gauge-local/e-missing-field.jsonl` | 2 | 2 |
| `a6-gauge-local/n50-mechanism.jsonl` | 3 | 3 |
| `a6-gauge-local/old-a-exec-revert.jsonl` | 2 | 2 |
| `a6-gauge-local/old-b-drop-op.jsonl` | 2 | 2 |
| `a6-gauge-local/positive.jsonl` | 0 | 0 |
| `d5b/a2-failclosed-reads-11884320-045a8962/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads-11884320-045a8962/neg-controls.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads-11884320-045a8962/receipts.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/neg-controls.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-count-new/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-count-old/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-from-new/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-from-old/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-list-new/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-list-old/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-status-new/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-status-old/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-tx-new/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/negctl-review/ledger-tx-old/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-failclosed-reads2-11885120-4f638f61/receipts.jsonl` | 2 | 2 |
| `d5b/a2-final-11885120-4f6d5084/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-final-11885120-4f6d5084/neg-controls.jsonl` | 2 | 2 |
| `d5b/a2-final-11885120-4f6d5084/receipts.jsonl` | 2 | 2 |
| `d5b/a2-item4-dummy-bump-11881530-fb507e36/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-item4-dummy-bump-11881530-fb507e36/neg-controls.jsonl` | 2 | 2 |
| `d5b/a2-item4-dummy-bump-11881530-fb507e36/receipts.jsonl` | 2 | 2 |
| `d5b/a2-item4-dummy-bump-11881940-6cf7af89/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/a2-item4-dummy-bump-11881940-6cf7af89/neg-controls.jsonl` | 2 | 2 |
| `d5b/a2-item4-dummy-bump-11881940-6cf7af89/posthoc-state-guard-85b62b38/neg-controls.jsonl` | 2 | 2 |
| `d5b/a2-item4-dummy-bump-11881940-6cf7af89/receipts.jsonl` | 2 | 2 |
| `d5b/fork-rehearsal-a2-full-11877936-0c21a8fe/fork-tx-ledger.jsonl` | 2 | 2 |
| `d5b/fork-rehearsal-a2-full-11877936-0c21a8fe/neg-controls.jsonl` | 2 | 2 |
| `d5b/fork-rehearsal-a2-full-11877936-0c21a8fe/receipts.jsonl` | 2 | 2 |
| `g2-31921fbc-partA.jsonl` | 2 | 2 |
| `g2-6c3a9a0e-partB.jsonl` | 2 | 2 |
| `g2-main-7fa7b705-oldformula.jsonl` | 2 | 2 |
| `rams-rr-matrix/phase2-smoke/cells.jsonl` | 2 | 2 |

## Offline verification

- `node --test script/a6-collector/`: attempted; Node v24.21.0 exits 1 with
  `MODULE_NOT_FOUND` for the directory. No tests ran successfully through that form.
- `node --test script/a6-collector/*.test.mjs`: **35 passed, 0 failed, 0 skipped**.
  Covers existing export rules, exact positive/zero penalty, missing trace nulls,
  one-gas bounds, an exhaustive 306-value inversion check, trace bindings,
  exporter propagation, and refusal of a validated formal-candidate with a changed
  exact claim. The same synthetic candidate is accepted before the claim mutation.
- `node --check`: passed for all six changed/new `.mjs` files.
- `python3 script/a6-collector/negative-controls/stake-gate.py`: passed one
  threshold-positive, nine isolated negative and nine restored-positive variants.
  Every negative returns exactly its new arm/condition error and exit 1;
  all positive variants return exit 0. These synthetic rows are not chain evidence.
- `python3 script/a6-collector/negative-controls/credit-schema-downgrade.py`:
  passed both variants. `/1` returns only the schema-required error (exit 1),
  `/2` is accepted (exit 0). Stake thresholds are satisfied in both variants.
- All **46** archived JSONL exits unchanged: two exit 0, three exit 1,
  thirty-seven exit 2, four exit 3. The full before/after list is above.
- `bash -n negative-controls/n2-penalty-anvil.sh`: passed syntax validation only.
- `git diff --check`: passed.

This offline verification used no network, chain calls, transactions or private-key
operations. The live Anvil control was run afterwards; see
`docs/design/aoa-balance-mode/data/a6-gauge-n2/README.md` (30/30 exact, and a mutation
probe showing the innerHandleOp tail check is load-bearing). The callTracer inversion
can yield two adjacent solutions; those are reported as bounded (width one gas) and
the live control accepts them as bounded, never as exact. postOp-reverted fallback
decomposition is not implemented.

## Files changed

All paths below are relative to `script/a6-collector/`:

- `collector.mjs`: complete pinned deposit info, optional raw call trace and decomposition, source hash.
- `validate.mjs`: U-6 gate and non-conformant note.
- `gas-decomposition.mjs` (new): trace binding, preOpGas extraction, exact/bounded inversion and claim check.
- `gas-decomposition.test.mjs` (new): synthetic gas/trace controls.
- `to-aoa-m3-receive.mjs`: per-attempt decomposition, hashed traces, mismatch flag/refusal.
- `to-aoa-m3-receive.test.mjs`: qualifying synthetic stakes and exporter N-2 controls.
- `negative-controls/stake-gate.py` (new): isolated U-6 controls.
- `negative-controls/credit-schema-downgrade.py`: keep the existing control isolated from U-6.
- `negative-controls/n2-penalty-anvil.sh` (new): read-only live reconstruction control.
- `README.md`: schema, derivation, bounds, commands and limitations.
- `negative-controls/stake-n2-verification.md` (new): this report and all archived exit codes.
