# exp/buffer-and-params — G2 per-op raw data

Schema, field definitions and statistics definitions: **identical** to the evidence index on
`feat/aoa-balance-mode-5.5.0 @ 501eb0d6` (`docs/design/aoa-balance-mode/data/README.md` §1 there).
`script/evidence/overpay-stats.mjs` is a verbatim copy of that commit's script. The export hook
(`_exportOp` + `_exp*` storage, env-gated by `G2_EXPORT_PATH`, default off) is ported verbatim; only
the `bufGas` line and the `formula` tag follow this branch's charge oracle.

All data is `unit-test` category (forge, in-process EVM). Nothing here is a transaction on any chain.

| file | tree | formula tag | notes |
|---|---|---|---|
| `g2-31921fbc-partA.jsonl` | `git archive 31921fbc` (Part A, Codex APPROVE) + the export hook; the exact diff applied is `g2-31921fbc-partA.hook.diff` | `A_Cpostop170k_Cwrap5k` (`bufGas = 170000 + ceil((callGas+postOpGas)*10/100) + 5000`) | 6,069 admitted ops = 4,398 settled + 1,671 injected; re-run byte-identical (`cmp`); sha256 `fef179f9…f3f694` |
| `g2-6c3a9a0e-partB.jsonl` | commit `6c3a9a0e` (Part B final format; hook committed there) | `B_Cpostop175k_Cwrap5k_default` (default GasParams: MIN 200k, SETTLE 160k, C_WRAP 5k, C_POSTOP 175k) | 6,069 admitted ops = 4,398 settled + 1,671 injected; re-run byte-identical (`cmp`); sha256 `3f018408…028c65` |
| `*.stats.txt` / `*.stats.json` | `node script/evidence/overpay-stats.mjs <file> [--json]` | | **0 consistency mismatches, 0 subsidised ops** in both files |
| `*.forge.log` | forge `-vv` output of the export run (the in-test `_report`) | | numbers equal the script output |

| overpay (charge_eth − G)/G, mean / P95 / max | ALL settled | postOpGasLimit ≤ 250,000 | postOpGasLimit ≥ 1,000,000 |
|---|---|---|---|
| main 5.5.0 (old formula; `g2-main-7fa7b705-oldformula.jsonl` on the feature branch) | 83.2 / 269.6 / 371.1 % | 41.8 / 61.3 / 81.5 % | 243.4 / 305.3 / 371.1 % |
| Part A `31921fbc` | 22.6 / 37.4 / 45.6 % | 23.7 / 38.3 / 45.6 % | 18.3 / 28.8 / 32.5 % |
| Part B `6c3a9a0e` (defaults) | 23.7 / 38.8 / 47.2 % | 24.9 / 39.7 / 47.2 % | 19.3 / 29.9 / 33.7 % |

Reproduce Part B (this branch at `6c3a9a0e`):
```
forge build
G2_EXPORT_PATH=cache/g2-export.jsonl forge test --match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol \
  --match-test test_G2_coverage_replay_fixed_seeds -vv
node script/evidence/overpay-stats.mjs cache/g2-export.jsonl
```
Reproduce Part A: `git archive 31921fbc | tar -x -C <dir>`, restore the submodule libraries, `patch -p1 <
g2-31921fbc-partA.hook.diff` (paths relative to the tree root), then the same commands in `<dir>`.

`e0cf0dc8` and `fb64e7eb` are intermediate Part B context formats that must never be deployed; no data
was exported for them.
