# R-AMS-2a — G layer under Amsterdam, re-measured with a calibrated engine (CC-125 d13dd9eb)

Evidence for spec `03-final-spec.md` §10.8b **R-AMS** (line ~697: "re-run the G layer (T-R14-09,
no-OOG scan, C_WRAP) … if the current parameters are insufficient, within the hard bounds use
`queueGasParams` → `executeGasParams` (≥ 96 h); beyond them, a UUPS upgrade") and `D5-plan.md` §2
(G2 / I8 / I9 / I10). This report **supersedes the numbers** of
`../amsterdam-sweep/REPORT.md` (forge 1.8.6), whose CREATE costs were proven wrong against live Sepolia.

- Commit under test: `79c0c6ffe197da9ee288fab881272b3af168dcc1` (`origin/main`, same commit as the old sweep).
- Date: 2026-10-22. Sepolia runs Amsterdam since 2026-10-06.
- Read-only: nothing under `contracts/src`, `contracts/script`, `foundry.toml`, `.github` changed. No
  public-chain RPC, no keys, no transactions on any public chain. All execution is local (forge
  in-process revm, local anvil).

## 0. Calibration gate (Step 0) — PASSED

`anvil --hardfork amsterdam` (no fork). For each transaction, the minimum gas limit for which
`eth_call` from anvil account 0 succeeds, by binary search over [0, 30,000,000]
(`scratch/calib.py`; raw output `calibration/calib-nightly.txt`, `calibration/calib-v1.8.6.txt`).
Expected values: live Sepolia, block 11969861.

| # | transaction | live Sepolia | **nightly 926eb1d** (anvil 1.8.7-nightly) | Δ | v1.8.6 (negative control) | Δ |
|---|---|---|---|---|---|---|
| 1 | CREATE, data `0x00` | 207,606 | **207,606** | 0 | 53,006 | −154,600 |
| 2 | CREATE, data `0x6101006000f3` | 599,432 | **599,432** | 0 | 104,304 | −495,128 |
| 3 | CREATE, data `0x600160005500` | 317,700 | **317,700** | 0 | 75,180 | −242,520 |
| 4 | CREATE, data `0x6001600055600260005500` | 320,075 | **320,075** | 0 | 77,555 | −242,520 |
| 5 | 1 wei → fresh `0xa3…a3` | 204,600 | **204,600** | 0 | 21,000 | −183,600 |

**5/5 exact on the nightly** (and `eth_estimateGas` returns the same 5 values). v1.8.6 differs on
all 5 rows (not only CREATE: it does not charge the EIP-8037 new-account state gas of a value
transfer either). At `min − 1` the nightly fails with `OutOfGas` (row 4: `ReentrancySentryOOG`).

**Assumption (stated, not proven):** the calibration covers anvil. `forge test` of the same
nightly build runs the same revm crates (`revm 43.0.3`, `revm-handler 43.0.3`,
`revm-interpreter 43.0.2`, `revm-context 43.0.3`, from the release's `Cargo.lock`), so the forge
numbers below are taken to be equally calibrated. One forge-only difference is documented in §3.4
(cheatcode calls reset the state-gas reservoir); it does not affect any reservoir-0 number.

## 1. Tools, versions, commands

| item | value |
|---|---|
| engine under test | foundry **nightly-926eb1d087523f1de437e3c0c49ea6d26407e827** — `forge Version: 1.8.7-nightly`, `Commit SHA: 926eb1d087523f1de437e3c0c49ea6d26407e827`, `Build Timestamp: 2026-10-22T06:24:10.676280092Z`, `Build Profile: dist`; same for anvil |
| tarball | `github.com/foundry-rs/foundry/releases/download/nightly-926eb1d…/foundry_nightly_linux_amd64.tar.gz`, sha256 `df74eb56171295ee11548e3ef9eb8209befb67e1ab595afe35f27dde4c22a6a1` = the release's `foundry_nightly_linux_amd64.sha256` asset (the asset is named `.sha256`, not `.tar.gz.sha256`). Attestation asset points to `github.com/foundry-rs/foundry/attestations/58520969` (not verified offline) |
| binaries (`/tmp/fd/nightly`) | forge sha256 `9f19c41c…db85`, anvil `7f483b2a…5142` |
| baseline | forge **1.7.1** (`4072e487…`), tarball sha256 `cf7e688e…c88b` = release `.sha256`; forge binary `4f77da08…355c` |
| negative control | forge/anvil **1.8.6** (`6bad0a66…`), tarball sha256 `58850106…35fc` = release `.sha256`; anvil binary `3c28263c…2cd5` |
| solc | 0.8.33+commit.64118f21, `solc-static-linux` from the ethereum/solidity GitHub release, sha256 `1274e5c4…5468`, placed in `~/.svm/0.8.33/`; all runs `--offline` |
| revm source read for §3 | crates.io `revm-handler-43.0.3`, `revm-interpreter-43.0.2`, `revm-context-interface-43.0.2`, `revm-context-43.0.3`, `revm-primitives-43.0.0`; every `.crate` sha256 equals the checksum in the nightly's `Cargo.lock` (`ba5102e9…`, `aa32f509…`, `3068385c…`, `9b06efea…`, `f1f4ba1a…`) |
| isolation | `--no-isolate` + `FOUNDRY_ISOLATE=false` (CLI/env only; nightly defaults to `isolate = true`); no `--gas-report` |
| compile / run | compile target = repo default `cancun` (baseline) or `--evm-version prague`; runtime `--hardfork amsterdam` (solc has no amsterdam target). Fuzz seed `0x5eed` |
| checksum records | `checksums/tarballs.sha256.txt` (each tarball's `sha256sum` next to the release's own `.sha256` asset), `checksums/binaries.sha256.txt` (forge/anvil/cast, solc, `--version` output), `checksums/revm-crates.sha256.txt`, `checksums/tree.sha256.txt` (`contracts/src` hash of this checkout = throwaway copy; restored scratch test = `scratch/Rams2a.t.sol.txt`) |

Exact commands (drivers are in `scratch/`):

```bash
# Step 0
anvil --hardfork amsterdam --port 8611 & python3 -I scratch/calib.py http://127.0.0.1:8611
# Task 1 (scratch/run.sh): separate FOUNDRY_OUT/FOUNDRY_CACHE_PATH per configuration
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv --evm-version prague                       # n_prague
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv --evm-version prague --hardfork amsterdam  # n_amsterdam
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv                                            # n_cancun
/tmp/fd/v1.7.1/forge test --offline --fuzz-seed 0x5eed -vv                                          # d_171_cancun
#   *_rerun.log: suites that read ./out re-run once ./out existed (see §2): scratch/rerun.sh
# 1.8.6 prague/amsterdam (old-sweep engine, regenerated here): scratch/run186.sh
# Task 2/3 scratch: scratch/Rams2a.t.sol.txt copied to contracts/test/zz_rams2a/Rams2a.t.sol in a
#   COPY of the tree (/tmp/rams/wt, sha256 of all contracts/src/*.sol identical), never in this checkout
scratch/scr_all.sh   # test_A (prague / amsterdam / amsterdam --enable-tx-gas-limit), then scratch/scr_run.sh test_B1 … test_C_wrap
#   = forge test --match-path …/Rams2a.t.sol --match-test <t> -vv [--hardfork amsterdam]
forge test … --match-test test_A -vv [--hardfork amsterdam [--enable-tx-gas-limit]]
# Task 3 real transactions: anvil --hardfork {amsterdam,prague} [--enable-tx-gas-limit]; python3 -I scratch/resv.py URL Probe.bin
# Task 5: anvil --hardfork {amsterdam,prague} --gas-limit 300000000; python3 -I scratch/deploy.py URL code EP.hex rows.json
python3 -I scratch/cmp.py <prague.log> <amsterdam.log>   # → g_layer_prague_vs_amsterdam.txt
python3 -I scratch/diff.py "<a.log[+rerun.log]>,<b.log[+rerun.log]>,<name a>,<name b>"   # → result_diffs.md
python3 -I scratch/derive.py logs/scratch/test_B{1,6,8}_*.log    # bare / fee-inclusive columns of §4.3, §4.5, §5.3
```

## 2. Task 1 — full suite: 1.7.1-cancun vs nightly-cancun / prague / amsterdam

| run | result (merged with the `./out` re-run, see note) |
|---|---|
| 1.7.1 cancun (baseline) | 1,840 result lines: 1,791 PASS, 0 FAIL, 49 SKIP |
| nightly cancun | 1,840: 1,791 PASS, 0 FAIL, 49 SKIP |
| nightly prague | 1,694: 1,671 PASS, 0 FAIL, 23 SKIP |
| nightly amsterdam | 1,694: 1,617 PASS, **54 FAIL**, 23 SKIP |

Note on `./out`: this checkout had no `./out`, and the nightly runs wrote to separate
`FOUNDRY_OUT` dirs, so 5 suites that read profile.default artifacts from the hard-coded `./out`
path failed with `vm.readFile … out/xPNTsTokenV2.sol/xPNTsTokenV2.json` / "no profile.default
build of …" (`D5c1Replay`, `CheckDefaultArtifacts`, `DeployAPNTsCapped`, `APNTsCappedSPIntegration`,
one `SuperPaymasterV55Adversarial` ABI test). `./out` (gitignored) was then filled from the nightly
cancun profile.default build and those suites re-run (`logs/suite/*_rerun.log`, `scratch/rerun.sh`);
the merge replaces whole suites. Raw main logs are kept unmodified. All logs cited here were
regenerated in this revision and are committed under `logs/` (see §10).

Differences (`result_diffs.md`, all tables):

| comparison | tests differing | what differs |
|---|---|---|
| 1.7.1 cancun vs nightly cancun | **0** of 1,840 | tool change moves no result |
| 1.7.1 cancun vs nightly prague | 231 | all PASS↔SKIP or absent (BLS stub suites skip on Prague / real-precompile suites skip on Cancun; invariant grouping). No FAIL |
| nightly prague vs **nightly amsterdam** | **54 PASS → FAIL** | listed below |
| 1.8.6 prague (old-sweep engine, regenerated: `logs/suite/v186_prague*.log`) vs nightly prague | 0 | — |
| 1.8.6 amsterdam (old-sweep engine, regenerated: `logs/suite/v186_amsterdam*.log`) vs nightly amsterdam | **0** | the same 54 tests fail, same reasons |

The 54 Amsterdam failures, by cause (full per-test table with reasons in `result_diffs.md`):

| class | n | tests | why |
|---|---|---|---|
| AA33 at the tests' fixed `paymasterVerificationGasLimit = 700,000` | 18 | `APNTsCappedSPIntegration` ×2, `D5bUpgradeRace` ×2, `FeeSnapshot` ×4, `Rc1Rc2MidBundle` ×4, `V55Gas.test_G_sp_charge_covers_final_cost_*` ×3, `ParamRace` ×1, `V55UpgradeRace` ×2 | balance-mode first-op validation needs 820,305 (§4.7) |
| no-OOG band (empty revert after the SETTLE guard) | 3 | `V55.test_B1_no_oog_band_above_entry_guard`, `GasParams.test_settle_floor_keeps_no_oog_band`, `Fuzz.testFuzz_G2_noOOGBand_direct_postOp` | SETTLE 160k / 155k leaves a ≈205k-gas OOG band (§4.2) |
| postOp at `MIN_POST_OP_GAS = 200k` cannot settle → op rejected / postOp reverted / sweeps never reach success / G2 "settled iff not made to fail" | 27 | `PoC_C04` ×4, `V55` ×3 (`balance_mode_end_to_end`, `I8_…_e2e`, `TR1409_…`), `V55Adversarial` ×15, `V55Fuzz` G2 ×4 (`testFuzz_G2_I8_I9_I10_conservation`, `testFuzz_G2_floor_params`, `test_G2_coverage_replay_*` ×2), `V542ToRc2MidBundle` ×1 | smallest settling postOp limit through EntryPoint is 365k–370k (§4.1) |
| probe-paymaster artefacts | 5 | `V55Gas.test_G_wrap_bound_*` ×2, `PostOpBound` ×3 | `PostOpProbePaymaster.postOp` writes two fresh slots (zero→non-zero ≈ 196k state gas) inside a 200k limit, so the probe itself OOGs; with the slots pre-set C_WRAP is 1,870 (§4.4). `test_each_path_within_C_POSTOP` additionally fails on the real rule (C_POSTOP 175k < W_postop) |
| `V55.test_G_min_post_op_gas_covers_measured_postOp` | 1 | | postOp 212,212 × 64/63 + 20k = 235,580 > 200,000 |

So the full-suite verdict of the old sweep stands; only its CREATE/deployment numbers were wrong.
In-test execution (SSTORE/SLOAD/CALL metering) gives byte-identical G-layer values under 1.8.6 and
the nightly (e.g. `PostOpBound` W_postop 291,579 / minLimit 379,783 in both:
`logs/suite/v186_amsterdam.log:1825`, `logs/suite/n_amsterdam.log:1965`).

## 3. Task 3 — `gasleft()` semantics under EIP-8037 (revm 43 as shipped in the nightly)

### 3.1 What the source says

`revm-interpreter-43.0.2/src/gas.rs`, `revm-context-interface-43.0.2/src/cfg/gas.rs`,
`revm-handler-43.0.3/src/{frame.rs,handler.rs,validation.rs}`, `revm-interpreter-43.0.2/src/instructions/{system.rs,host.rs}`:

1. **Two pools.** Each frame has `remaining` (regular gas) and a `reservoir` (state gas). State
   charges (`record_state_cost`: SSTORE 0→x = 64 B × CPSB 1,530 = **97,920**; new account
   120 B = **183,600**; code deposit 1,530/B) are taken **from the reservoir first and spill into
   `remaining`** only when it is empty; the spill is counted in `state_gas_spilled`.
2. **`GAS` (= `gasleft()`) pushes `remaining` only** (`system.rs: push!(…, gas.remaining())`). The
   reservoir is invisible to Solidity.
3. **The *initial* reservoir is non-zero only when the tx gas limit exceeds the regular cap.**
   `initial_gas_and_reservoir` (`revm-context-interface-43.0.2/src/cfg/gas.rs:560-590`):
   `execution = gasLimit − intrinsic_regular`, `regular = min(gasLimit, tx_gas_limit_cap) −
   intrinsic_regular`, `reservoir = execution − regular`; then the **intrinsic state gas**
   (`initial_state_gas`, e.g. the new-account charge of a CREATE transaction) is deducted
   separately — from the reservoir first, and the deficit from `regular`. With the EIP-7825 cap
   2^24 active, a transaction with `gasLimit ≤ 16,777,216` **starts** with reservoir 0, so a state
   charge made while the current frame's reservoir is 0 spills into `remaining` (visible to
   `gasleft()`, bounded by that frame's CALL gas argument). Above 2^24 the excess is initial
   reservoir (that is how Sepolia includes > 2^24 transactions).
   **Reservoir 0 at tx start does not mean reservoir 0 throughout the tx.** A 0→x→0 restoration
   in a frame whose own `state_gas_spilled` is smaller than the refill (e.g. a child clearing a
   slot that a parent or sibling set: item 5) puts the excess into that frame's *reservoir*
   (`refill_reservoir`, `gas.rs:248-257`); on return the parent credits only up to its own spill
   (`absorb_returned_reservoir`, `gas.rs:109-118`) and the rest stays reservoir. Later state
   charges in that frame or its descendants draw from it first: invisible to `gasleft()` and
   **not** bounded by the CALL gas argument. So in a ≤ 2^24 transaction "every state charge is
   bounded by each CALL argument" holds only while no such refill has created reservoir gas
   earlier in the transaction.
4. **A CALL passes the whole reservoir** to the child (not 63/64, not bounded by `{gas: g}`);
   the child's leftover reservoir is returned (`absorb_returned_reservoir`).
5. **0→x→0 restoration refills state gas directly** (`host.rs` → `refill_reservoir`): the refill is
   credited to `remaining` **up to the current frame's own `state_gas_spilled`**, the rest goes to the
   reservoir; on return the parent again credits `remaining` up to *its* spill
   (`absorb_returned_reservoir`). Hence **`gasleft()` of an ancestor can increase across a call**
   when a descendant restores a slot whose zero→non-zero charge spilled in that ancestor's tree.
6. Revert/halt: `rollback_state_gas` returns the frame's spill to `remaining` and restores the
   reservoir; on halt `remaining` is then burnt (`spend_all`).
7. In tooling: forge and anvil `eth_call` set `tx_gas_limit_cap = u64::MAX` unless
   `--enable-tx-gas-limit` (foundry `crates/evm/core/src/opts.rs:1178`, anvil `mem/mod.rs:3239`), so
   by default the **initial reservoir = 0** — the starting regime of every bundle with
   `gasLimit ≤ 2^24` (a refill can still create reservoir gas later, item 3).

### 3.2 Demonstration (measured, not derived)

Real transactions on anvil (`gasleft/resv_amsterdam.txt`, `gasleft/resv_prague.txt`, probe
`scratch/ResvProbe.sol.txt`) and forge without any cheatcode before the measurement
(`R2aReservoirNoCheat`, `logs/scratch/A_*.log`):

| quantity (caller's `g_before − g_after`; negative = **gasleft rose**) | Prague | Amsterdam, reservoir 0 | Amsterdam, reservoir > 0 (forge `--enable-tx-gas-limit`, tx 2^30) |
|---|---|---|---|
| own fresh SSTORE | 22,169 | 110,089 | **12,169** (state gas from reservoir, invisible) |
| CALL → child sets a fresh slot | 22,885 | 110,905 | 12,985 |
| CALL → child restores that slot to 0 (same tx) | +891 | **−96,929** (real anvil tx: **−96,992**) | +991 |
| CALL `{gas: 30,000}` → child does one fresh SSTORE | ok | **fails** | **ok** |
| CALL `{gas: 100,000}` → same | ok | **fails** | ok |
| restore from a frame that did not spill (A2, 3 slots) | 1,223 | 1,223 | 1,223 |

Anvil real-tx receipts: the same `run()` costs 108,713 (Prague) / 276,383 (Amsterdam) gas at tx
gasLimit 15M, 16,777,216 and 30M (anvil default: cap disabled → reservoir 0 for all three).
`anvil --enable-tx-gas-limit` **rejects** a 30M tx under Amsterdam (`tx.gas_limit > resolved tx
gas limit cap`), unlike live Sepolia; the reservoir regime could therefore only be exercised in forge.

### 3.3 Consequences for EntryPoint v0.7 and SuperPaymaster

EntryPoint measures with `gasleft()` differences, all inside `unchecked`:
`:129`/`:142` (`_executeUserOp` failure paths, handleOps frame), `:357` (`innerHandleOp`),
`:549` (paymaster validation, AA36), `:655`/`:672` (account validation, preOpGas), `:716`
(`_postExecution`, the postOp segment). SP measures once: `SuperPaymaster.sol:405`
`gasleft() < SETTLE` at postOp entry.

**Regime R0 — bundle gasLimit ≤ 2^24 (initial reservoir 0).** A state charge spills into
`remaining` whenever the charging frame's reservoir is 0 — always the case until a refill has
created reservoir gas (§3.1 item 3). In the measured SP flows (§4) this was the case for the
charges that matter (`callGasLimit` grows by ≈ 113.7k per fresh slot vs ≈ 23k on Prague, §4.7), so (i) `gasleft()`
differences *include* state gas, (ii) every frame limit
(`paymasterVerificationGasLimit`, `paymasterPostOpGasLimit`, `callGasLimit`,
`verificationGasLimit`) must cover the state gas of its fresh writes — measured: SP postOp needs a
365k–370k limit, validation 612k–820k (§4); (iii) `MIN_POST_OP_GAS` and the `SETTLE_GAS_BOUND`
guard compare against regular gas that already carries the state charges, so they keep their
meaning with larger values. This is the binding regime for every parameter below.

**gasleft can rise inside a measured region.** The restore refill is credited to `remaining` of
any frame (or ancestor) that spilled. In the SP flow the validation-time lock record (zero→non-zero,
spilled in the `handleOps` frame tree) is cleared in postOp; the refill is first credited inside the
SP postOp frame against SP's own fresh writes in the same postOp (`_settledDebtOps[opHash]`,
`lastTimestamp`, …). Measured consequences:

- W_postop at EntryPoint level is **identical with and without a user execution that spills**
  (balance first op 177,234 in both, `B2`), and no `UserOperationPrefundTooLow`/AA36/AA95 occurred
  in any of the 60+ EntryPoint runs (`B1`, `B2`, `B5`, `B7`, `B8`; user execution writing 0–3
  fresh slots). **No accounting failure was observed in the measured cases.** This does not show
  that a refill can never reach an open `innerHandleOp` / `_postExecution` measurement in other
  flows; it shows only that in these cases the measured segment and EntryPoint's results were
  consistent.
- In the measured cases the refill that is not absorbed in the SP frame appears to reach the
  `handleOps` frame after `innerHandleOp` returns (where no `gasleft()` difference is open on the
  success path); it then lowers the bundle's real cost, not the op's `actualGasUsed`. If so,
  EntryPoint bills the op (and SP's deposit) the validation-time state gas of the lock record
  although the transaction gets it back, i.e. the paymaster is over-charged relative to the
  bundler's cost in these cases. Per-op numbers: `B7` (actualGasUsed vs the gas the `handleOps`
  frame consumed; dominated by the 10 % unused-gas penalty, so read only as a sign). Whether the
  refill can be credited elsewhere in other code paths was not established.
- **Latent hazard (unproven; needs targeted evidence).** If a future SP/token change made a postOp
  clear more zero-at-tx-start slots than it writes, or made validation clear a slot set earlier in
  the same bundle, a refill could be credited to `innerHandleOp` / `handleOps` while one of
  EntryPoint's unchecked `gasleft()` differences is open, making `gasleft()` larger at the end of
  the segment than at its start. What that does is **not determined** by this report: e.g. at
  `EntryPoint.sol:716` the wrapped `preGas − gasleft()` is *added* to the accumulator `actualGas`
  in unchecked arithmetic, so it can cancel against it (500,000 + (2^256 − 96,929) = 403,071 mod
  2^256: an under-count by the refill, not a ~2^256 value); `:357` likewise adds `opInfo.preOpGas`,
  while `:549` compares the raw difference with `paymasterVerificationGasLimit` (a wrapped value
  there would trip AA36 rather than under-count). Possible outcomes range from a silently smaller
  `actualGasUsed` to a wrapped value; none was produced or measured here. Any change to the
  postOp or validation write/clear set needs a targeted test (a postOp/validation that clears
  more pre-existing-zero slots than it writes, measured through EntryPoint) before relying on it.

**Regime RR — bundle gasLimit > 2^24 (reservoir > 0).** State gas is drawn from the reservoir
first: invisible to `gasleft()`, and **not bounded by any per-frame gas limit** (a
`{gas: 30,000}` child performed a 97,920-state-gas SSTORE). EntryPoint's `actualGasUsed` then
excludes that state gas, so the op and SP are charged *less* than the transaction costs: the
bundler absorbs it. For SP this regime needs *smaller* limits than R0 and does not under-charge SP
relative to EntryPoint (SP's charge and EntryPoint's deposit debit are both based on the same
`gasleft()` accounting). A partially filled reservoir makes the regime position-dependent within a
bundle (the first state writes consume it). Not measured end-to-end, see §3.4.

### 3.4 Tool artefact found

In forge (with `--enable-tx-gas-limit`), **any cheatcode call resets the frame's reservoir to 0**:
fresh SSTORE costs 12,128 before and 110,048 after a single `vm.getBlockTimestamp()` (`A5`). So
EntryPoint/SP flows (which need `vm.prank`, `vm.sign`, …) cannot be measured in regime RR with
forge, and anvil rejects > 2^24 transactions under `--enable-tx-gas-limit` (§3.2). RR is
therefore shown with minimal probes only. All SP numbers in this report are regime R0. (Also
observed: `test_A4_reservoir_size` fails with `OutOfGas` at 16,762,164 gas under
`--enable-tx-gas-limit` (`logs/scratch/A_amsterdam_reservoir.log:50`), i.e. at about the 2^24 regular
cap, before printing any row; hence the `—` in that column of `g_layer_prague_vs_amsterdam.txt`. Why
it exhausts regular gas was not investigated.)

## 4. Task 2 — G layer, Prague vs Amsterdam (nightly; R0)

Sources: `g_layer_prague_vs_amsterdam.txt` (all `R2A|key|value` rows side by side),
`logs/scratch/test_*_{prague,amsterdam}.log`, in-repo logs `logs/suite/n_{prague,amsterdam}.log`.
Fixture: canonical EntryPoint v0.7 runtime (codehash `0x8db5ff69…fc58`) etched at
`0x0000000071727De22E5E9d8BAf0edAc6f37da032`, real SP 5.5 proxy, factory-issued xPNTsTokenV2,
SimpleAccount v0.7, operator `minTxInterval = 60` (cold `lastTimestamp` write = worst path),
1 gwei, ETH/USD 2000. "Ample limits" = verification 1M, call 1M, pmVerification 3M, postOp 1M, PVG 50k.

### 4.1 T-R14-09 (MIN_POST_OP_GAS covers the worst postOp, through EntryPoint)

| measurement | Prague | Amsterdam | source |
|---|---|---|---|
| op with `paymasterPostOpGasLimit = 200,000` (= current MIN) settles? balance / credit | yes / yes | **no / no**: inner revert data empty (OOG after the guard) | `B3.TR1409_defaults` |
| smallest settling `paymasterPostOpGasLimit` through EntryPoint, params at floor (MIN 175k, SETTLE 155k): balance / credit / balance + user writes 1 slot | ≤ 175,000 (floor) all | **365,325 / 369,624 / 365,325** | `B3.min_postOpGasLimit_EP` |
| non-guard (OOG) failures for limits in [175k, min), step 2k | — | 96 / 98 / 96 | same |
| in-repo `PostOpBound` minLimit (direct call, test frame), max over 8 paths | 167,387 | **379,783** (credit), 375,484 (balance) | `logs/suite/n_prague.log:4124`, `n_amsterdam.log:1963-1965` |
| in-repo `test_G_min_post_op_gas_covers_measured_postOp` requirement (measured postOp × 64/63 + 20k) | 164,347 (142,092) | 235,580 (212,212) | `logs/suite/n_prague.log:1311`, `n_amsterdam.log:1389-1391` |

### 4.2 No-OOG band scan (B-1 / I8): direct `postOp{gas: g}` from the EntryPoint address, same tx as validation

| path | SETTLE | Prague: min settling g / min g passing guard / band | Amsterdam: same |
|---|---|---|---|
| balance first op | 155,000 (floor) | 159,463 / 159,463 / **0** | 365,325 / 159,463 / **205,862** (206 failures, 1k steps) |
| balance first op | 160,000 (default) | 164,543 / 164,543 / 0 | 365,325 / 164,543 / **200,782** (201 failures) |
| balance first op | 360,000 | — | 367,717 / 367,717 / **0** — no band |
| balance first op | 361,000 | — | 368,733 / 368,733 / **0** — no band |
| credit first op | 155,000 | 159,463 / 159,463 / 0 | 369,624 / 159,463 / **210,161** (211 failures) |
| credit first op | 160,000 | 164,543 / 164,543 / 0 | 369,624 / 164,543 / **205,081** (206 failures) |
| credit first op | 365,000 | — | 372,797 / 372,797 / **0** — no band |
| credit first op | 366,000 | — | 373,813 / 373,813 / **0** — no band |

The band closes at **SETTLE ≥ 360k (balance) / 365k (credit)** (verified points; the guard
threshold is ≈ SETTLE × 64/63 + 2k).

### 4.3 W_postop, C_POSTOP rule, and the I9 / G2 charge check

| quantity | Prague | Amsterdam | source |
|---|---|---|---|
| in-repo W_postop (`consumed`, max over 8 paths; credit first debt) | 147,939 | **291,579** | `PostOpBound` logs |
| in-repo balance paths / no-rate-limit control | 133,927 / 113,534 | 189,547 / 81,134 | same |
| W_postop at EntryPoint level, `(F_real − F_postOpMocked) × 10/9`: balance / credit | 128,814 / 142,825 | 177,234 / **279,265** | `B2` |
| rule C_POSTOP ≥ W × 1.15 (in-repo W) | 170,130 | **335,316** | |

End-to-end through EntryPoint (`B1`, ample limits, **current defaults**). Two reference values
per op, both at the validation price snapshot (fixture: ETH/USD 2000, aPNTs 0.02 USD, so 1 wei of
EntryPoint cost = 10^5 aPNTs-wei; `protocolFeeBPS` 1,000):

- **bare** = EntryPoint's `actualGasCost` converted to aPNTs = what SP's EntryPoint deposit
  actually pays for the op (`spEpDepositDelta_wei` = `actualGasCost_wei` in every B1 case);
- **fee-incl.** = bare × 1.10 (ceil) = the target `_fullCostCharge` in
  `contracts/test/v2/SuperPaymasterV55Gas.t.sol:256-260` and the scratch `need` (it **includes
  the 10 % protocol fee**).

`charge` = the `protocolRevenue` increase for the op. Columns derived by
`scratch/derive.py` from `actualGasCost_wei` / `charge_aPNTs` / `need_aPNTs` of
`logs/scratch/test_B1_{prague,amsterdam}.log` (the script asserts the logged `need` equals the
fee-inclusive formula for every case). All values in aPNTs.

| case | Prague: bare / charge / fee-incl. | Prague: charge − bare / charge − fee-incl. | Amsterdam: bare / charge / fee-incl. | Amsterdam: charge − bare / **charge − fee-incl.** | Amsterdam actualGasUsed |
|---|---|---|---|---|---|
| balance, first op | 59.25530 / 72.05792 / 65.18083 | +12.80 / +6.88 | 134.02810 / 149.50452 / 147.43091 | +15.48 / +2.07 | 1,340,281 |
| balance, second op | 43.75320 / 61.11391 / 48.12852 | +17.36 / +12.99 | 77.17820 / 99.83171 / 84.89602 | +22.65 / +14.94 | 771,782 |
| **credit, first op** | 57.61070 / 68.86176 / 63.37177 | +11.25 / +5.49 | **122.70130 / 126.94396 / 134.97143** | **+4.24 / −8.03** (not clamped, a0 = 726) | 1,227,013 |
| balance, user call reverts | 54.17510 / 67.00793 / 59.59261 | +12.83 / +7.42 | 128.94790 / 144.45453 / 141.84269 | +15.51 / +2.61 | 1,289,479 |
| balance, user writes 1 fresh slot | 61.46470 / 74.75545 / 67.61117 | +13.29 / +7.14 | 144.15030 / 161.87325 / 158.56533 | +17.72 / +3.31 | 1,441,503 |
| balance, user writes 2 | 63.46910 / 77.20526 / 69.81601 | +13.74 / +7.39 | 154.06750 / 173.99426 / 169.47425 | +19.93 / +4.52 | 1,540,675 |
| balance, user writes 3 | 65.47350 / 79.65507 / 72.02085 | +14.18 / +7.63 | 163.98470 / 186.11527 / 180.38317 | +22.13 / +5.73 | 1,639,847 |
| **credit, user writes 1** | 59.82020 / 71.55929 / 65.80222 | +11.74 / +5.76 | 132.82360 / 139.31269 / 146.10596 | +6.49 / **−6.79** | 1,328,236 |
| **credit, user writes 2** | 61.82460 / 74.00910 / 68.00706 | +12.18 / +6.00 | 142.74080 / 151.43370 / 157.01488 | +8.69 / **−5.58** | 1,427,408 |
| **credit, user writes 3** | 63.82900 / 76.45891 / 70.21190 | +12.63 / +6.25 | 152.65800 / 163.55471 / 167.92380 | +10.90 / **−4.37** | 1,526,580 |

**I9 / G2 at the current defaults under Amsterdam, in the 4 tested credit-mode cases above:** the
charge **covers the bare EntryPoint cost** (+4.24 … +10.90 aPNTs: SP collects more than its
EntryPoint deposit pays for these ops) but **misses the fee-inclusive target** by 4.37–8.03 aPNTs
(≈ 2.6–5.9 % of the target), i.e. the protocol keeps only 35–71 % of the intended 10 % fee on these
ops. The tested balance-mode cases meet both references. Cause: the charge budgets C_POSTOP +
C_WRAP = 180k for postOp and wrapper, while the measured W_postop + wrap is ≈ 281k (credit).
Other credit-mode paths were not tested, so no statement is made about them.

With the op at `paymasterPostOpGasLimit = MIN = 200k` (`B5`/`B8` "defaults"), Amsterdam postOp
OOGs in all 6 B8 scenarios: the user's execution is rolled back, the user pays 0, and **SP's
EntryPoint deposit pays the whole op**: bare 88.93–128.31 aPNTs per op (fee-incl. 97.82–141.14;
`derive.py` over `test_B8_amsterdam.log`). This is the I10 path, but any user can trigger it at
the current defaults by choosing a postOp limit in [200k, ~365k), which validation admits. That
makes it a griefing vector against SP's deposit on every Amsterdam chain running 5.5.0 with the
GasParams slot unset (see §5.3 for the upgrade window).

### 4.4 C_WRAP (probe slots pre-set so the probe does no zero→non-zero write)

| measurement | Prague | Amsterdam |
|---|---|---|
| single op: succeeded/200k, succeeded/1M, reverted/200k | 1,770 / 1,756 / 1,770 | **1,870 / 1,856 / 1,870** |
| bundle positions 0..3 | 1,770 ×4 | 1,870 ×4 |

C_WRAP 5,000 keeps 2.67×. (The in-repo probe tests fail under Amsterdam only because the probe's
own fresh writes exceed its 200k limit.)

### 4.5 Proposed tuples end-to-end (postOpGasLimit = MIN; `B8`, plus `B5`)

| tuple (MIN / SETTLE / C_WRAP / C_POSTOP) | Amsterdam: settles in all 6 scenarios? | charge ≥ fee-incl. in all 6? | min charge − bare (aPNTs) | min charge − fee-incl. (aPNTs) |
|---|---|---|---|---|
| 200k / 160k / 5k / 175k (defaults) | **no (0/6)** | **no** | **−128.31** (charge 0; SP's deposit pays the op) | −141.14 |
| 385k / 365k / 5k / 336k (raw needs) | yes | yes | +32.55 | +19.78 |
| **440k / 420k / 5k / 340k** (needs + 15 %) | yes | yes | +33.05 | +20.22 |
| 440k / 420k / 5k / 300k (C_POSTOP below the rule, control) | yes | yes (penalty budget masks it) | +28.65 | +15.82 |
| B5: 300k/280k, 350k/330k (C_POSTOP = MIN) | no / no | — | — | — |
| B5: 400k/380k, 450k/430k, 500k/480k (C_POSTOP = MIN) | yes | yes | — | — |

B8 logs `charge − fee-incl.` and `actualGasUsed`; bare = actualGasUsed × 1 gwei × 10^5 and
charge = (charge − fee-incl.) + ceil(bare × 1.1) (`scratch/derive.py`).

Scenarios: balance first op; balance + user writes 2 slots; credit first op; balance user call
reverts; balance at realistic limits (call 120k, pmVer 900k, verification 150k); credit at
realistic limits (pmVer 700k). Prague settles and covers for every tuple.

### 4.6 I8 / I10 and stale-release gas (`B6`, isolated transactions)

| | Prague | Amsterdam |
|---|---|---|
| settle forced to fail (balance): execution kept? / user balance unchanged / lock left | 0 / yes / 726 xPNTs | 0 / yes / 726 xPNTs (I8 holds) |
| op actualGasUsed on that path (SP deposit pays) | 634,355 | 1,333,615 |
| `releaseStaleLock` gasUsed (refund) | 56,094 (11,218) | 86,494 (17,298) |
| `releaseStaleSponsorship` gasUsed (refund) | 39,882 (4,800) | 48,682 (9,736) |
| `releaseStaleCredit` gasUsed | 44,858 | 60,858 |
| after both releases: lock 0, in-flight cleared | yes | yes |

### 4.7 SDK-side limits (smallest passing values through EntryPoint)

| limit | Prague | Amsterdam | source |
|---|---|---|---|
| `paymasterVerificationGasLimit`, balance first op | 194,487 | **820,305** | `B3` |
| `paymasterVerificationGasLimit`, credit first op | 164,970 | **611,954** | `B3` |
| `verificationGasLimit`, deployed SimpleAccount | 31,648 | 119,668 | `B3` |
| `verificationGasLimit`, SimpleAccount deployed via initCode | 165,879 | **801,247** | `B3` |
| `callGasLimit`, `execute` writing 0 / 1 / 2 fresh slots | 1,842 / 24,741 / 47,725 | 1,842 / **115,475 / 229,192** | `B3` |

## 5. Task 4 — parameter matrix

Hard bounds from `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol:193-204`,
checked at queue and execute in `SuperPaymasterAdmin.sol:298-301`; `GP_TIMELOCK = 48 hours`
(`:204`). Governance wait for path (a): timelock 48 h (GOV-1) + `GP_TIMELOCK` 48 h = **≥ 96 h**.
"With margin" = measured × 1.15 (the DSR `M_BPS = 1,500`), rounded up to 5k.

### 5.1 Contract parameters

| parameter | current default | GOV-5 hard bounds | needed, Prague (row) | needed, Amsterdam (row) | Amsterdam with margin | default OK? | path |
|---|---|---|---|---|---|---|---|
| `SETTLE_GAS_BOUND` | 160,000 | [155,000, 1,000,000] | ≤ 155,000: no band at floor (§4.2) | **≥ 365,000** (credit; balance 360k) (§4.2) | **420,000** | **NO** (205k band) | (a) |
| `MIN_POST_OP_GAS` | 200,000 | [SETTLE + 20,000, 2,000,000] | ≥ 167,387 (in-repo minLimit; EP ≤ 175k) (§4.1) | **≥ 385,000** = max(379,783 in-repo minLimit; 369,624 EP; SETTLE 365k + 20k) | **440,000** (= max(379,783 × 1.15 = 436,751; 420k + 20k)) | **NO** (0/6 settle at 200k) | (a) |
| `C_POSTOP_GAS` | 175,000 | [175,000, MIN] | ≥ 170,130 (§4.3) | **≥ 335,316** (291,579 × 1.15) (§4.3) | **340,000** (rule already has the 15 %) | **NO** (tested credit cases: charge covers the bare cost but misses the fee-inclusive target by 4.37–8.03 aPNTs/op, §4.3) | (a), needs MIN ≥ 340k first or in the same queue |
| `C_WRAP_GAS` | 5,000 | [5,000, 50,000] | ≥ 1,770 (§4.4) | ≥ 1,870 (§4.4) | 5,000 (2.67× kept) | yes | none |

Validation: the full tuple **(MIN 440,000, SETTLE 420,000, C_WRAP 5,000, C_POSTOP 340,000)**
settles in all 6 B8 EntryPoint scenarios and its charge covers both the bare EntryPoint cost and
the fee-inclusive target in each (§4.5). All four values are inside the GOV-5 hard bounds, so the
**values** can be set by path (a): one `queueGasParams(440000, 420000, 5000, 340000)` → ≥ 48 h →
`executeGasParams()`, behind the 48 h owner timelock. Note that `queueGasParams` checks
`cPostop ≤ minPost` of the *same* call, so the single queued tuple is valid.

**Path (b) (source change + new candidate/tag): not required for the parameter VALUES (all within
the GOV-5 hard bounds).** That statement is about the values only. It does **not** cover the
period between an upgrade to 5.5.0 and `executeGasParams` (§5.3), the legacy 352-byte context path
(`LEGACY_SETTLE_GAS_BOUND` 160k, `LEGACY_C_WRAP_GAS`, `SuperPaymaster.sol:85-86`), which applies to
contexts admitted before an upgrade mid-bundle, or the §3.3 latent hazard if the postOp write/clear
set ever changes.

### 5.2 Test-to-evidence index for §5.1

Every number in the §5.1 table (and the validation paragraph), with the log file and line it comes
from. Paths are relative to this directory; scratch logs are from `scratch/Rams2a.t.sol.txt`
(restored as `contracts/test/zz_rams2a/Rams2a.t.sol` in a throwaway copy of the tree), suite logs
from the in-repo tests. Line numbers refer to the committed files.

| §5.1 number | meaning | source (file:line) |
|---|---|---|
| 160,000 / 200,000 / 5,000 / 175,000 | current defaults | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol:193-196` (zero slot → these, `:317-322`) |
| [155k, 1M], [SETTLE+20k, 2M], [175k, MIN], [5k, 50k] | GOV-5 hard bounds | `SuperPaymasterStorage.sol:197-203`; checked in `SuperPaymasterAdmin.sol:297-302`, at queue `:306` and execute `:318` |
| SETTLE Prague "≤ 155,000: no band at floor" | balance / credit: min settling g = min g passing guard = 159,463, band 0 | `logs/scratch/test_B4_prague.log:22-24`, `:39-41` |
| SETTLE Amsterdam "≥ 365,000 (credit)" | band 0 at 365k: 372,797 / 372,797 | `logs/scratch/test_B4_amsterdam.log:35-38` (366k: `:31-34`) |
| SETTLE Amsterdam "balance 360k" | band 0 at 360k: 367,717 / 367,717 | `logs/scratch/test_B4_amsterdam.log:18-21` (361k: `:14-17`) |
| SETTLE "205k band" at the default | credit at 160k: 369,624 / 164,543 / band 205,081 (balance 200,782) | `logs/scratch/test_B4_amsterdam.log:26-28` (balance `:9-11`) |
| SETTLE with margin 420,000 | 365,000 × 1.15 = 419,750 → 420,000 | derived |
| MIN Prague ≥ 167,387 | in-repo PostOpBound max minLimit | `logs/suite/n_prague.log:4124` |
| MIN Prague "EP ≤ 175k" | smallest settling postOp limit through EntryPoint = floor 175,000 (balance / credit / balance + 1 slot) | `logs/scratch/test_B3_min_postOp_prague.log:9-11` |
| MIN Amsterdam 379,783 | in-repo PostOpBound minLimit, credit first debt | `logs/suite/n_amsterdam.log:1965` (balance 375,484: `:1963`) |
| MIN Amsterdam 369,624 | smallest settling postOp limit through EntryPoint, credit (balance 365,325) | `logs/scratch/test_B3_min_postOp_amsterdam.log:13` (balance `:9`, + 1 slot `:17`) |
| MIN "SETTLE 365k + 20k" = 385,000 | GOV-5 coupling MIN ≥ SETTLE + 20k | `SuperPaymasterStorage.sol:192`, derived |
| MIN with margin 440,000 | max(379,783 × 1.15 = 436,751; 420k + 20k) | derived |
| MIN "0/6 settle at 200k" | B8 defaults, settled = 0 in all 6 scenarios | `logs/scratch/test_B8_amsterdam.log:10,16,22,28,34,40` |
| C_POSTOP Prague ≥ 170,130 | W_postop 147,939 × 1.15 | `logs/suite/n_prague.log:4119` (W), `:4121` (× 1.15) |
| C_POSTOP Amsterdam ≥ 335,316 | 291,579 × 1.15 (the Amsterdam run fails before printing its max line; 291,579 is the max of the 8 path lines) | `logs/suite/n_amsterdam.log:1963-1977` (291,579 at `:1965`) |
| C_POSTOP "4.37–8.03 aPNTs/op" | credit first op / writes 1, 2, 3: `charge`, `need` (fee-incl.), `actualGasCost_wei` (bare) | `logs/scratch/test_B1_amsterdam.log:55-62`, `:156-159`, `:176-179`, `:196-199` |
| C_WRAP Prague ≥ 1,770 | wrapper upper bound, single op and bundle positions | `logs/scratch/test_C_wrap_prague.log:9-16` |
| C_WRAP Amsterdam ≥ 1,870 | same | `logs/scratch/test_C_wrap_amsterdam.log:9-16` |
| tuple 440k/420k/5k/340k settles and covers in 6/6 | B8 `settled` = 1, `chargeCoversNeed` = 1 | `logs/scratch/test_B8_amsterdam.log:82-113` |
| ≥ 48 h / ≥ 96 h | `GP_TIMELOCK = 48 hours` (+ GOV-1 owner timelock 48 h) | `SuperPaymasterStorage.sol:204`; `SuperPaymasterAdmin.sol:307,317` |

### 5.3 Upgrade window

`SuperPaymasterStorage.sol:317-322` (`_gpRaw`): an **all-zero GasParams slot selects the in-bytecode
defaults 200k / 160k / 5k / 175k**. A proxy upgraded to 5.5.0 (or a fresh 5.5.0 deployment) starts
with that slot zero. The measured values (§4.5) can only be written by `executeGasParams`, which
needs `queueGasParams` first and then `block.timestamp ≥ eta = queue time + GP_TIMELOCK (48 h)`
(`SuperPaymasterAdmin.sol:305-321`), plus the owner timelock's own delay for each of the two calls
if the owner is the GOV-1 timelock (`queueGasParams` cannot be queued before the 5.5.0 code is
live, since the function does not exist in the old implementation). So on an Amsterdam chain there
is a window of **≥ 48 h after the upgrade (≥ 96 h with GOV-1)** in which:

- validation admits any `paymasterPostOpGasLimit` ≥ 200k, and for limits in **[200k, ~365k)**
  (balance 365,325 / credit 369,624 are the smallest settling limits, §4.1) settlement fails and
  **SP's EntryPoint deposit pays the whole op** (bare 88.93–128.31 aPNTs per op in the B8 scenarios,
  §4.3/§4.5); any user can choose such a limit;
- ops with limits above that settle, but tested credit-mode ops miss the fee-inclusive target
  (§4.3).

Two remediation options; this report does not choose between them:

- **(A) Parameter-only, with a protected rollout.** Keep the 5.5.0 bytecode; stop sponsorship
  atomically with the upgrade and resume only after `executeGasParams`. Existing mechanisms:
  `setGlobalPaused(true)` (validation returns SIG_FAILURE for every op before parsing it,
  `SuperPaymaster.sol:233`; postOp and stale releases keep working) or `setOperatorPaused` per
  operator (`SuperPaymasterAdmin.sol:90-110`; owner both directions, guardian pause only).
  "Atomically" means the pause must be effective no later than the upgrade, e.g. set in the same
  timelock batch before `upgradeToAndCall`, or before it. The rollout must also cover **legacy
  contexts admitted before a mid-bundle upgrade**: such ops settle under
  `LEGACY_SETTLE_GAS_BOUND` 160k regardless of GasParams, so the pause has to be in force before the
  last pre-upgrade bundle that could carry SP ops, not only before the first post-upgrade one.
  Cost: no sponsorship for ≥ 48 h (≥ 96 h with GOV-1) per chain; no bytecode change.
- **(B) Amsterdam-safe in-bytecode defaults in a new candidate.** Change `MIN_POST_OP_GAS`,
  `SETTLE_GAS_BOUND`, `C_POSTOP_GAS` (and review `LEGACY_*`) so that the zero slot is already
  safe; requires a new candidate/tag, re-audit of the changed constants, and the CLAUDE.md
  version/ABI process (constants only, so no ABI/storage change is expected, but `version()` would
  bump). Cost on a **Prague/Osaka** chain, where the larger MIN is not needed but every op must
  still carry `paymasterPostOpGasLimit ≥ MIN`:
  - prefund / a0 (`SuperPaymaster.sol:305-310`: a0 = ceil(maxCost at the cached price) ×
    (1 + fee 10 % + validation buffer 10 %)): ΔpostOpLimit 240,000 gas × 1 gwei = **+0.00024 ETH
    prefund = +24.0 aPNTs bare = +28.8 aPNTs a0 per op** (computed from the formula at the fixture
    price, not logged by B8). For one balance op at Prague-scale limits (verification 150k,
    call 120k, pmVerification 225k ≈ 194,487 × 1.15, PVG 50k): prefund 745,000 → 985,000 gas,
    a0 89.4 → 118.2 aPNTs (+32 %); at the B8 "realistic" limits (pmVerification 900k):
    1,420,000 → 1,660,000 gas, a0 170.4 → 199.2 aPNTs (+17 %). a0 is a reservation (operator
    solvency check and user lock/credit reservation), not a charge.
  - actual cost (measured, `test_B8_prague.log`, balance first op, defaults vs 440k/420k/5k/340k):
    `actualGasUsed` 510,544 → 534,544 (**+24,000 gas** = EntryPoint's 10 % unused-gas penalty on
    the extra 240k of postOp limit), bare cost 51.05440 → 53.45440 aPNTs (+2.40, +4.7 %);
    charge 63.03693 → 83.82693 aPNTs (+20.79, +33 %), of which most comes from C_POSTOP
    175k → 340k in the charge formula, not from the gas used ((165,000 + 24,000) gas × 1 gwei ×
    10^5 × 1.1 = 20.79). The deltas are identical in all 6 B8 Prague scenarios (bare +2.40,
    charge +20.79 aPNTs each).

### 5.4 SDK / bundler parameters (per op; not contract-enforced except postOp ≥ MIN)

| parameter | Prague measured | Amsterdam measured (row) | Amsterdam with margin | note |
|---|---|---|---|---|
| `paymasterVerificationGasLimit` | 194,487 | **820,305** balance / 611,954 credit (§4.7) | **945,000** | test ops use 700k → AA33 (18 tests, §2) |
| `paymasterPostOpGasLimit` | ≥ MIN (200k) | must be ≥ on-chain MIN; settles from 365,325 / 369,624 | **= MIN = 440,000** | SDK reads `gasParams()` |
| `callGasLimit` | 24,741 + 23k per fresh slot | 115,475 for one fresh slot; +113.7k per fresh slot (§4.7) | estimate per call × 1.15 | each zero→non-zero write costs ≈ 97,920 more |
| `verificationGasLimit` | 31,648 / 165,879 (initCode) | 119,668 / **801,247** (initCode) (§4.7) | 140,000 / 925,000 | account deployment dominates |
| `preVerificationGas` | not measured | **not measured** (§7) | — | a fresh beneficiary adds 183,600 unattributed new-account state gas per bundle |

Path for all SDK values: SDK release only (no contract change, no governance wait).

## 6. Task 5 — deployment gas (tx level, nightly anvil, shipped profile.default cancun init code)

Method (`scratch/deploy.py`, log `deploy/deploy_tx_gas.log`, rows `deploy/rows_*.json`): local
anvil `--hardfork {amsterdam,prague} --gas-limit 300000000`, canonical EntryPoint runtime set at its
address, init code selected from the nightly cancun profile.default build by artifact metadata
(`scratch/resolve.py`; runs 500 / Registry 200, viaIR, cancun; sizes identical to the old sweep).
Each row is a **real transaction** in DeployLive order with constructor arguments of the same
shape: `estimate` = `eth_estimateGas`, `min` = smallest passing `eth_call` gas limit,
`used` = receipt `gasUsed` of the transaction sent with gas = estimate. Intrinsic, calldata and
EIP-8037 state gas are all included.

| # | transaction | kind | data B | runtime B | Prague used | Amsterdam estimate | Amsterdam min | Amsterdam used | ratio A/P | min > 2^24 | live Sepolia reference |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | MockFeed (test helper, not shipped) | CREATE | 202 | 176 | 91,495 | 480,211 | 480,211 | 480,211 | 5.25x | no |  |
| 2 | Registry | CREATE | 23670 | 23306 | 5,166,011 | 36,585,825 | 36,585,825 | 36,585,825 | 7.08x | yes | 36,877,356 (+0.80 %) |
| 3 | ERC1967Proxy(Registry) + initialize | CREATE | 863 | 100 | 1,373,703 | 6,499,227 | 6,499,227 | 6,499,227 | 4.73x | no |  |
| 4 | xPNTsFactory | CREATE | 25246 | 6802 | 5,413,786 | 37,068,268 | 37,068,268 | 37,068,268 | 6.85x | yes |  |
| 5 | GTokenAuthorization | CREATE | 8332 | 6113 | 1,475,540 | 10,025,642 | 10,025,642 | 10,025,642 | 6.79x | no |  |
| 6 | GTokenStaking | CREATE | 9616 | 9061 | 2,083,345 | 14,554,739 | 14,554,739 | 14,554,739 | 6.99x | no |  |
| 7 | MySBT | CREATE | 13460 | 12111 | 2,847,249 | 19,727,493 | 19,727,493 | 19,727,493 | 6.93x | yes |  |
| 8 | SuperPaymaster impl (ctor creates SuperPaymasterAdmin) | CREATE | 34647 | 13744 | 7,439,485 | 52,399,391 | 52,399,391 | 52,389,391 | 7.04x | yes | 52,811,426 (+0.79 %) |
| 9 | ERC1967Proxy(SuperPaymaster) + initialize | CREATE | 895 | 100 | 254,636 | 1,158,600 | 1,158,600 | 1,158,600 | 4.55x | no |  |
| 10 | SuperPaymasterAdmin standalone (breakdown only; inside row 8) | CREATE | 20109 | 19214 | 4,311,127 | 30,385,633 | 30,385,633 | 30,375,633 | 7.05x | yes |  |
| 11 | GlobalTierSource | CREATE | 769 | 542 | 172,969 | 1,048,531 | 1,048,531 | 1,048,531 | 6.06x | no |  |
| 12 | AOAProtocolRegistry | CREATE | 2987 | 2746 | 673,870 | 4,569,186 | 4,569,186 | 4,569,186 | 6.78x | no |  |
| 13 | xPNTsTokenV2Ext | CREATE | 24175 | 22005 | 4,868,703 | 34,382,101 | 34,382,101 | 34,382,101 | 7.06x | yes |  |
| 14 | xPNTsTokenV2 | CREATE | 22236 | 20008 | 4,437,504 | 31,294,520 | 31,294,520 | 31,294,520 | 7.05x | yes |  |
| 15 | AOAProtocolRegistry.bootstrapApprove(KIND_TIER_SOURCE, codehash) | CALL | 68 | — | 50,310 | 132,330 | 132,330 | 132,330 | 2.63x | no |  |
| 16 | xPNTsFactoryV2 | CREATE | 10884 | 8537 | 2,448,437 | 15,896,089 | 15,896,089 | 15,896,089 | 6.49x | no |  |
| 17 | SuperPaymasterLens | CREATE | 5439 | 5413 | 1,223,464 | 8,578,374 | 8,578,374 | 8,578,374 | 7.01x | no |  |
| 18 | ReputationSystem | CREATE | 7790 | 7044 | 1,699,078 | 11,663,324 | 11,663,324 | 11,663,324 | 6.86x | no |  |
| 19 | DVTValidator | CREATE | 6611 | 6326 | 1,469,640 | 10,214,948 | 10,214,948 | 10,214,948 | 6.95x | no |  |
| 20 | BLSAggregator | CREATE | 25072 | 24345 | 5,545,771 | 38,963,687 | 38,963,687 | 38,963,687 | 7.03x | yes |  |
| 21 | MicroPaymentChannel | CREATE | 6611 | 6117 | 1,427,048 | 9,894,350 | 9,894,350 | 9,894,350 | 6.93x | no |  |
| 22 | PaymasterFactory | CREATE | 6280 | 6158 | 1,432,075 | 9,953,913 | 9,953,913 | 9,953,913 | 6.95x | no |  |
| 23 | Paymaster | CREATE | 10974 | 10492 | 2,396,832 | 16,771,720 | 16,771,720 | 16,771,720 | 7.00x | no |  |
| 24 | X402Facilitator | CREATE | 4713 | 4332 | 1,040,088 | 7,133,004 | 7,133,004 | 7,133,004 | 6.86x | no |  |
| 25 | TimelockController (48 h, 1 proposer, 1 executor, admin 0) | CREATE | 7019 | 5458 | 1,378,624 | 9,233,390 | 9,233,390 | 9,233,390 | 6.70x | no | **9,233,390 min** / 9,307,838 estimate (S2) |
| 26 | PolicyRegistry | CREATE | 6883 | 6349 | 1,477,486 | 10,253,490 | 10,253,490 | 10,253,490 | 6.94x | no |  |
| 27 | APNTsCapped (DeployAPNTsCapped) | CREATE | 8003 | 5346 | 1,389,345 | 9,183,153 | 9,183,153 | 9,183,153 | 6.61x | no |  |
| 28 | EIP-1167 clone of xPNTsTokenV2 (raw) | CREATE | 55 | 45 | 62,915 | 277,377 | 277,377 | 277,377 | 4.41x | no |  |
| 29 | EIP-1167 clone of Paymaster (raw) | CREATE | 55 | 45 | 62,915 | 277,377 | 277,377 | 277,377 | 4.41x | no |  |
| | **sum of the shipped txs measured (excl. rows 1, 10, 28, 29)** | | | | **59,184,999** | | | **407,175,295** | **6.88x** | | |

Agreement with live Sepolia:
- **TimelockController: the anvil minimum equals the live S2 minimum exactly (9,233,390).**
- Registry and SP impl: the live figures are `eth_estimateGas` values. They sit **+0.80 % / +0.79 %**
  above the anvil minima, the same ratio as the live S2 estimate over its own minimum
  (9,307,838 / 9,233,390 = +0.81 %). This is consistent with the live node's estimate margin over an
  identical minimum. It is not a proof: the live Registry/SP minima were not given.
- Anvil's `eth_estimateGas` returns the exact minimum (no margin), so budget ≈ +1 % when using
  these rows to set a live gasLimit.

About EIP-7825: **eight rows** need more than 2^24 = 16,777,216 gas (rows 2, 4, 7, 8, 10, 13, 14,
20, from `deploy/rows_amsterdam.json`), i.e. **seven shipped transactions** plus the standalone
SuperPaymasterAdmin breakdown row 10 (which is not a separate transaction; it is inside row 8). That is **not** a deployment blocker on Sepolia: the 2^24 cap applies to regular
gas, and the excess is state-gas reservoir (§3.1). Live Sepolia included 3,047 transactions with
gasLimit > 2^24 in 3,000 blocks, one with gasUsed 84,832,515. The old report's "cannot be deployed"
remark (§5.2 there) is withdrawn. (Anvil itself rejects such transactions only when started with
`--enable-tx-gas-limit`, §3.2. It accepted all rows here with the cap disabled.)

## 7. What could NOT be measured, and why

1. **Regime RR (bundle gasLimit > 2^24, reservoir > 0) end-to-end with SP**: forge resets the
   reservoir on any cheatcode call (§3.4) and anvil rejects > 2^24 transactions when the cap is
   enabled. Only minimal probes were run. All parameter needs come from R0, which needs the larger values.
2. **`preVerificationGas`**: forge gives no transaction receipts for `handleOps`. A tx-level
   PVG would need the full SP stack deployed on anvil. Not done. Known component: a fresh
   beneficiary costs 183,600 state gas per bundle (calibration row 5 pattern).
3. **B layer** (Rundler/Alto ERC-7562 simulation and acceptance of ~0.95M paymaster verification
   limits): no bundler binaries / Amsterdam node here.
4. **Live chain**: forbidden by the task rules (no RPC, no transactions). The engine is calibrated
   on 5 probes (§0) and on the Timelock deployment (§6). The SP numbers rely on the assumption that
   forge uses the same revm as the calibrated anvil.
5. **Full in-repo suite re-run with the proposed tuple**: the tests hard-code 200k / 700k limits;
   changing them is out of scope. The tuple was validated end-to-end in the scratch suite (§4.5).
6. **Factory clone + initialize gas** (`xPNTsFactory.deployxPNTsToken` etc.) needs the orchestrated
   community/role setup. Only the raw 45-byte clone CREATE is measured (277,377).
7. Per-function trace table (old §4) was not regenerated. Validation and postOp are measured
   directly as limits through EntryPoint (§4.1, §4.7), which is what the parameters need.
8. Scratch bug, disclosed: the first `B1` run aliased a memory struct (`Lim memory lr = l`), so later
   cases ran with callGas 50k. Those logs were deleted. Every scratch log now in `logs/scratch/` was
   regenerated in this revision from the committed `scratch/Rams2a.t.sol.txt` (sha256 in
   `checksums/tree.sha256.txt`).

## 8. Files

| path | content |
|---|---|
| `calibration/` | Step-0 raw outputs (nightly, v1.8.6); re-run in this revision with byte-identical output |
| `checksums/` | sha256 records for §1: release tarballs vs release `.sha256` assets, extracted binaries + solc + `--version`, revm `.crate` files, `contracts/src` tree hash and restored scratch test |
| `logs/suite/` | full `-vv` suite logs: `d_171_cancun`, `n_cancun`, `n_prague`, `n_amsterdam`, `v186_prague`, `v186_amsterdam`, each with `*_rerun.log` (./out suites), and `timeline.txt` (commands, start/end, exit codes) |
| `result_diffs.md` | per-test difference tables, regenerated from `logs/suite/` |
| `logs/scratch/` | scratch G-layer logs, Prague and Amsterdam (and Amsterdam + reservoir for part A), `timeline.txt` |
| `g_layer_prague_vs_amsterdam.txt` | every scratch `R2A` row side by side, regenerated from `logs/scratch/` |
| `gasleft/` | real-transaction gasleft probes on anvil |
| `deploy/` | deployment gas log, JSON rows, init-code resolution log |
| `scratch/` | `Rams2a.t.sol.txt` (G layer, gasleft probes), `ResvProbe.sol.txt`, `MockFeed.sol.txt`, `calib.py`, `resv.py`, `deploy.py`, `resolve.py`, `run.sh`, `rerun.sh`, `run186.sh`, `scr_run.sh`, `scr_all.sh`, `cmp.py`, `diff.py`, `parse.py`, `derive.py` |

## 9. Summary

- **Calibration: PASS.** nightly 926eb1d matches live Sepolia exactly on 5/5 probes, and the
  Timelock deployment matches the live S2 minimum exactly. v1.8.6 is off on 5/5.
- **Insufficient under Amsterdam:** `SETTLE_GAS_BOUND` 160k (a 200,782–205,081-gas OOG band at
  160k), `MIN_POST_OP_GAS` 200k (no tested op settles at MIN, so SP's deposit pays whole ops:
  griefable), `C_POSTOP_GAS` 175k (in the 4 tested credit-mode cases the charge covers the bare
  EntryPoint cost, +4.24…+10.90 aPNTs, but misses the fee-inclusive I9 target by 4.37–8.03 aPNTs
  per op). Also the SDK `paymasterVerificationGasLimit` (needs 820k balance / 612k credit),
  `verificationGasLimit` for initCode (801k) and `callGasLimit` (+113.7k per fresh slot).
  `C_WRAP_GAS` 5k is fine (1,870 measured).
- **Needed values (with 15 % margin): MIN 440,000 / SETTLE 420,000 / C_WRAP 5,000 /
  C_POSTOP 340,000**, validated end-to-end in the 6 B8 scenarios. SDK:
  paymasterVerificationGasLimit ≈ 945k, paymasterPostOpGasLimit = MIN.
- **Source change: not required for the parameter VALUES (all within GOV-5 hard bounds)**; they
  can be set by `queueGasParams` → `executeGasParams` (≥ 48 h, ≥ 96 h with GOV-1) plus an SDK
  release. **This does not close the upgrade window (§5.3):** after a 5.5.0 upgrade the zero
  GasParams slot selects 200k/160k/5k/175k until `executeGasParams`, during which postOp limits in
  [200k, ~365k) are admitted but do not settle and SP's deposit pays the op. Options: (A)
  parameter-only with sponsorship paused atomically with the upgrade until `executeGasParams`
  (covering legacy contexts too), or (B) Amsterdam-safe in-bytecode defaults in a new candidate,
  which on Prague/Osaka costs +240k postOp limit per op (+28.8 aPNTs a0, +24,000 gas actually
  used, +20.79 aPNTs charge per measured op). Not chosen here. (SP on Sepolia is 5.4.2 per
  `deployments/deploy-record-v5.4.2-sepolia.md`, not 5.5.0; 5.4.2 was not measured here.)
- `gasleft()` excludes the state-gas reservoir and can **rise** across a call (−96,929 measured),
  because EIP-8037 refills are credited to spilling frames; a refill can also create reservoir
  gas inside a transaction that started with none (§3.1). No accounting failure was observed in
  the measured cases. Whether a postOp/validation that clears more pre-existing-zero slots than it
  writes could corrupt EntryPoint's unchecked accounting is unproven and needs targeted evidence
  (§3.3).

## 10. Changes vs 457a133a

**Measured numbers: none changed.** Every log the report cites was regenerated in this revision
with the same engine, flags and seed, and committed (`logs/suite/`, `logs/scratch/`; all files
< 5 MB, so none is gzipped):

- Step 0 calibration re-run first: output byte-identical to `calibration/calib-*.txt` (gate PASS).
- Full suites: 1.7.1 cancun, nightly cancun / prague / amsterdam, each with its `./out` re-run;
  merged counts 1,840/1,791/0/49, 1,840/1,791/0/49, 1,694/1,671/0/23, 1,694/1,617/54/23 as in §2.
  The 1.8.6 prague / amsterdam suites (previously only in the old sweep) were also regenerated.
  `result_diffs.md` regenerated from these logs: all six tables are byte-identical to 457a133a
  except the 1.8.6 table labels.
- Scratch G layer (`scratch/scr_all.sh`): `g_layer_prague_vs_amsterdam.txt` regenerated; every
  value is identical, only the order of the part-A rows (forge suite print order) differs.
- The `./out` re-run script (`scratch/rerun.sh`) first recorded a wrong exit code in
  `timeline.txt` (`$?` read after a `$(date)` substitution); those four lines were dropped and the
  four re-runs repeated with the fixed script. Results were the same.

Corrections of transcription, wording and derivation (no new measurement):

1. §1 / `checksums/`: sha256 records committed.
2. §4.3, §4.5, §5.1, §9: the old "need" was the **fee-inclusive** target (`_fullCostCharge`,
   +10 % protocol fee). Both references are now reported. Credit first op: bare 122.70130, charge
   126.94396, fee-incl. 134.97143 → charge covers the bare cost (+4.24) and misses the
   fee-inclusive target (−8.03). The previous claim that SP pays EntryPoint more than it collects
   (operator subsidy) is withdrawn: the bare column does not show it for any tested settled case.
   "every credit-mode op" is narrowed to the 4 tested credit cases. The §4.3 text range
   "97.8–141.4" is corrected to bare 88.93–128.31 / fee-incl. 97.82–141.14 (141.4 was a typo).
3. §3.3: the claim that a refill deterministically wraps EntryPoint's accounting into
   `INNER_REVERT_LOW_PREFUND` / whole-prefund loss is removed (`EntryPoint.sol:716` adds the
   wrapped difference to the accumulator, which can cancel); "refill does not reach" / "never
   under-charged" are reduced to what was observed in the measured cases; the hazard is marked
   unproven.
4. §3.1 / §3.3 R0: reservoir 0 is only the *initial* state of a ≤ 2^24 transaction; a refill in a
   non-spilling frame can create reservoir gas later; the intrinsic state gas deduction of
   `initial_gas_and_reservoir` is stated.
5. §4.2: SETTLE 360k → 367,717 and 361k → 368,733; 365k → 372,797 and 366k → 373,813 (all zero
   band) are now separate rows (were merged under the 360k / 365k values); failure counts added.
6. §6: eight rows exceed 2^24 including the standalone Admin row 10 (seven shipped
   transactions), not nine.
7. §5.1 / §9: "source change not required" restricted to the parameter values; new §5.3 Upgrade
   window with options (A) / (B) and the Prague/Osaka cost of (B); the sentence inferring that the
   defaults are live on Sepolia is removed (Sepolia SP is 5.4.2 per
   `deployments/deploy-record-v5.4.2-sepolia.md`).
8. New §5.2 test-to-evidence index; §4.1 rows now cite log lines.

