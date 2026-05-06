# SuperPaymaster Bytecode Size Budget

EIP-170 hard limit: **24,576 bytes** (runtime bytecode)  
Soft warning threshold (CI): **24,500 bytes**  
Compiler: Solidity 0.8.33, via_ir = true, optimizer_runs = 10,000, EVM: cancun

---

## Current State

| Date | Commit | Runtime (bytes) | Headroom | Notes |
|------|--------|-----------------|---------|-------|
| 2026-03-xx | (main before audit) | 26,166 | −1,590 ❌ | Over EIP-170 — blocked CI |
| 2026-05-06 | 290104a | 24,537 | +39 ✅ | EIP-170 compression pass |
| 2026-05-06 | 8e6d0cc | 24,541 | **+35 ✅** | Restored try/catch in getAgentSponsorshipRate |

---

## What Was Removed to Fit (EIP-170 Pass, commit 290104a)

| Change | Bytecode saved (est.) | Risk |
|--------|-----------------------|------|
| 16 constants → `internal` (getters removed) | ~800 bytes | MEDIUM — SDK must hardcode values |
| Remove dead `useRealtime` branch | ~400 bytes | LOW — was dead code |
| Remove `oracleDecimals` storage var | ~150 bytes | LOW — Chainlink ETH/USD always 8 |
| Remove `xPNTsAmount` from context encoding | ~39 bytes | MEDIUM — breaking for calldata decoders |
| Drop try/catch in `configureOperator` | ~34 bytes | LOW — factory is owner-controlled |
| Remove unused `bytes memory` from `_slash` | ~80 bytes | NONE — internal only |

**Total saved: ~1,503 bytes**

---

## Known Costs of Pending Features

| Feature | Est. cost (bytes) | Status | Notes |
|---------|--------------------|--------|-------|
| PR #114 — P0-11 price bounds (after all optimizations) | +~81 | Open | Constants now `internal`; net +81B after rebase on #118. Final size ~24,622B (46B over) — needs 46 more bytes found at rebase time |
| PR #113 — P0-3 blacklist hardening | +~50 | Open | Small, will fit after #118 merges |
| PR #110 — P0-12b facilitator whitelist | +~80 | Open | Will fit after #118 merges |

---

## Rules for Future Features

1. **Any PR adding >20 bytes must check size first**: Run `forge build --sizes` and record the delta in the PR description.
2. **New public constants are prohibited** unless they replace something else. Use `internal` — values go in SDK constants file.
3. **New try/catch blocks cost ~30–100 bytes each** — use only for genuinely fault-isolated external calls (untrusted/upgradeable targets).
4. **New events cost ~50 bytes each** (event signature storage). Batch related events where possible.
5. **New storage variables cost ~150 bytes** (getter + initialization + SLOAD/SSTORE opcodes). Consider packing into existing slots.

---

## Available Budget for Next Features

**Today**: 35 bytes  
After PR #114 lands (if constants are `internal`): ~185 bytes  
After all 3 open PRs land: ~55 bytes

---

## Optimizer Experiments

| optimizer_runs | via_ir | Runtime size | Notes |
|---------------|--------|--------------|-------|
| 10,000 | true | 24,541 bytes | Current production setting |
| 200 | true | **24,541** (identical) | Tested 2026-05-06 — zero difference |

> **Finding (2026-05-06)**: Switching to `optimizer_runs = 200` with `via_ir = true` produced **zero bytecode size change** (24,541B in both cases). The Yul/IR compiler handles most size-reduction passes as part of the IR lowering pipeline regardless of `optimizer_runs`. The `optimizer_runs` parameter primarily affects inlining heuristics in the legacy (non-IR) pipeline; with IR, its marginal effect on size is negligible.
>
> **Recommendation**: Keep `optimizer_runs = 10,000` (better gas per call). Lowering it gains nothing when `via_ir = true`. If size becomes critical in the future, evaluate **disabling `via_ir`** combined with `optimizer_runs = 200` as a combined change — but measure gas regressions first (~3-8% expected increase per call).

---

## When Size Becomes Critical Again

If headroom drops below 0, options in order of disruption:

1. **Make more constants `internal`** — zero logic impact, SDK change only
2. **Extract a library** (`SuperPaymasterLib`) — move pure math helpers to a linked library (~2-3 KB savings, medium refactor)
3. **Reduce `optimizer_runs` + disable `via_ir`** — saves ~1-3 KB at the cost of higher gas per call (~3-8%)
4. **Split implementation** — `SuperPaymasterCore` (validation+postOp) + `SuperPaymasterAdmin` (config) with internal delegation (~4 KB savings, large refactor)
5. **Diamond proxy (EIP-2535)** — arbitrary size, removes limit entirely (major architecture change, adds complexity)
