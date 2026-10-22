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

Exact commands (drivers are in `scratch/`):

```bash
# Step 0
anvil --hardfork amsterdam --port 8611 & python3 -I scratch/calib.py http://127.0.0.1:8611
# Task 1 (scratch/run.sh): separate FOUNDRY_OUT/FOUNDRY_CACHE_PATH per configuration
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv --evm-version prague                       # n_prague
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv --evm-version prague --hardfork amsterdam  # n_amsterdam
forge test --offline --no-isolate --fuzz-seed 0x5eed -vv                                            # n_cancun
/tmp/fd/v1.7.1/forge test --offline --fuzz-seed 0x5eed -vv                                          # d_171_cancun
#   *_rerun.log: suites that read ./out re-run once ./out existed (see §2)
# Task 2/3 scratch: scratch/Rams2a.t.sol.txt copied to contracts/test/zz_rams2a/Rams2a.t.sol in a
#   COPY of the tree (/tmp/rams/wt, sha256 of all contracts/src/*.sol identical), never in this checkout
scratch/scr_run.sh test_B1 test_B2 ...   # = forge test --match-path …/Rams2a.t.sol --match-test <t> -vv [--hardfork amsterdam]
forge test … --match-test test_A -vv [--hardfork amsterdam [--enable-tx-gas-limit]]
# Task 3 real transactions: anvil --hardfork {amsterdam,prague} [--enable-tx-gas-limit]; python3 -I scratch/resv.py URL Probe.bin
# Task 5: anvil --hardfork {amsterdam,prague} --gas-limit 300000000; python3 -I scratch/deploy.py URL code EP.hex rows.json
python3 -I scratch/cmp.py <prague.log> <amsterdam.log>   # → g_layer_prague_vs_amsterdam.txt
python3 -I scratch/diff.py "<a.log[+rerun.log]>,<b.log[+rerun.log]>,<name a>,<name b>"   # → result_diffs.md
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
cancun profile.default build and those suites re-run (`logs/suite/*_rerun.log`); the merge replaces
whole suites. Raw main logs are kept unmodified.

Differences (`result_diffs.md`, all tables):

| comparison | tests differing | what differs |
|---|---|---|
| 1.7.1 cancun vs nightly cancun | **0** of 1,840 | tool change moves no result |
| 1.7.1 cancun vs nightly prague | 231 | all PASS↔SKIP or absent (BLS stub suites skip on Prague / real-precompile suites skip on Cancun; invariant grouping). No FAIL |
| nightly prague vs **nightly amsterdam** | **54 PASS → FAIL** | listed below |
| 1.8.6 prague (old sweep) vs nightly prague | 0 | — |
| 1.8.6 amsterdam (old sweep) vs nightly amsterdam | **0** | the same 54 tests fail, same reasons |

The 54 Amsterdam failures, by cause (full per-test table with reasons in `result_diffs.md`):

| class | n | tests | why |
|---|---|---|---|
| AA33 at the tests' fixed `paymasterVerificationGasLimit = 700,000` | 18 | `APNTsCappedSPIntegration` ×2, `D5bUpgradeRace` ×2, `FeeSnapshot` ×4, `Rc1Rc2MidBundle` ×4, `V55Gas.test_G_sp_charge_covers_final_cost_*` ×3, `ParamRace` ×1, `V55UpgradeRace` ×2 | balance-mode first-op validation needs 820,305 (§4.3) |
| no-OOG band (empty revert after the SETTLE guard) | 3 | `V55.test_B1_no_oog_band_above_entry_guard`, `GasParams.test_settle_floor_keeps_no_oog_band`, `Fuzz.testFuzz_G2_noOOGBand_direct_postOp` | SETTLE 160k / 155k leaves a ≈205k-gas OOG band (§4.2) |
| postOp at `MIN_POST_OP_GAS = 200k` cannot settle → op rejected / postOp reverted / sweeps never reach success / G2 "settled iff not made to fail" | 27 | `PoC_C04` ×4, `V55` ×3 (`balance_mode_end_to_end`, `I8_…_e2e`, `TR1409_…`), `V55Adversarial` ×15, `V55Fuzz` G2 ×4 (`testFuzz_G2_I8_I9_I10_conservation`, `testFuzz_G2_floor_params`, `test_G2_coverage_replay_*` ×2), `V542ToRc2MidBundle` ×1 | smallest settling postOp limit through EntryPoint is 365k–370k (§4.1) |
| probe-paymaster artefacts | 5 | `V55Gas.test_G_wrap_bound_*` ×2, `PostOpBound` ×3 | `PostOpProbePaymaster.postOp` writes two fresh slots (zero→non-zero ≈ 196k state gas) inside a 200k limit, so the probe itself OOGs; with the slots pre-set C_WRAP is 1,870 (§4.4). `test_each_path_within_C_POSTOP` additionally fails on the real rule (C_POSTOP 175k < W_postop) |
| `V55.test_G_min_post_op_gas_covers_measured_postOp` | 1 | | postOp 212,212 × 64/63 + 20k = 235,580 > 200,000 |

So the full-suite verdict of the old sweep stands; only its CREATE/deployment numbers were wrong.
In-test execution (SSTORE/SLOAD/CALL metering) gives byte-identical G-layer values under 1.8.6 and
the nightly (e.g. `PostOpBound` W_postop 291,579 / minLimit 379,783 in both).

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
3. **The reservoir exists only when the tx gas limit exceeds the regular cap.**
   `initial_gas_and_reservoir`: `regular = min(gasLimit, tx_gas_limit_cap) − intrinsic`,
   `reservoir = gasLimit − intrinsic − regular`. With the EIP-7825 cap 2^24 active, a transaction
   with `gasLimit ≤ 16,777,216` has reservoir 0 and **all state gas spills into `remaining`, i.e.
   is visible to `gasleft()` and bounded by every CALL's gas argument**. Above 2^24 the excess is
   reservoir (that is how Sepolia includes > 2^24 transactions).
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
   by default **reservoir = 0** — the regime of every bundle with `gasLimit ≤ 2^24`.

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

**Regime R0 — bundle gasLimit ≤ 2^24 (reservoir 0).** Every state charge spills into `remaining`,
so (i) `gasleft()` differences *include* state gas, (ii) every frame limit
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
  fresh slots). So with the current SP code the refill does not reach the `innerHandleOp` /
  `_postExecution` measurement, and **no underflow of `preGas − gasleft()` was observed**.
- The refill that is not absorbed in the SP frame reaches the `handleOps` frame after
  `innerHandleOp` returns (where no `gasleft()` difference is open on the success path); it lowers
  the bundle's real cost, not the op's `actualGasUsed`. EntryPoint therefore bills the op (and SP's
  deposit) the validation-time state gas of the lock record although the transaction gets it back:
  the **paymaster is over-charged relative to the bundler's cost, never under-charged by this
  mechanism**. Per-op numbers: `B7` (actualGasUsed vs the gas the `handleOps` frame consumed;
  dominated by the 10 % unused-gas penalty, so read only as a sign).
- Latent hazard (not reachable in the measured code paths): if a future SP/token change made a
  postOp **clear more zero-at-tx-start slots than it writes**, or made validation clear a slot set
  earlier in the same bundle, the excess refill would be credited to `innerHandleOp` /
  `handleOps` while EntryPoint's unchecked `preGas − gasleft()` is open. The result wraps to ~2^256:
  `:716`/`:357` → `actualGasCost > prefund` → `INNER_REVERT_LOW_PREFUND` → the op is charged its
  **whole prefund** from SP's deposit with postOp rolled back (an I9 loss); `:549` → AA36 and the
  whole bundle reverts. Any change to the postOp write/clear set must be re-checked against this.

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
therefore shown with minimal probes only. All SP numbers in this report are regime R0.

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
| in-repo `PostOpBound` minLimit (direct call, test frame), max over 8 paths | 167,387 | **379,783** (credit), 375,484 (balance) | `n_*` logs |
| in-repo `test_G_min_post_op_gas_covers_measured_postOp` requirement | 164,347 | 235,580 | `n_*` logs |

### 4.2 No-OOG band scan (B-1 / I8): direct `postOp{gas: g}` from the EntryPoint address, same tx as validation

| path | SETTLE | Prague: min settling g / min g passing guard / band | Amsterdam: same |
|---|---|---|---|
| balance first op | 155,000 (floor) | 159,463 / 159,463 / **0** | 365,325 / 159,463 / **205,862** (206 failures, 1k steps) |
| balance first op | 160,000 (default) | 164,543 / 164,543 / 0 | 365,325 / 164,543 / **200,782** |
| balance first op | 360,000 / 361,000 | — | 367,717 / 367,717 / **0** — no band |
| credit first op | 155,000 | 159,463 / 159,463 / 0 | 369,624 / 159,463 / **210,161** |
| credit first op | 160,000 | 164,543 / 164,543 / 0 | 369,624 / 164,543 / **205,081** |
| credit first op | 365,000 / 366,000 | — | 372,797 / 372,797 / **0** — no band |

The band closes at **SETTLE ≥ 360k (balance) / 365k (credit)** (verified points; the guard
threshold is ≈ SETTLE × 64/63 + 2k).

### 4.3 W_postop, C_POSTOP rule, and the I9 / G2 charge check

| quantity | Prague | Amsterdam | source |
|---|---|---|---|
| in-repo W_postop (`consumed`, max over 8 paths; credit first debt) | 147,939 | **291,579** | `PostOpBound` logs |
| in-repo balance paths / no-rate-limit control | 133,927 / 113,534 | 189,547 / 81,134 | same |
| W_postop at EntryPoint level, `(F_real − F_postOpMocked) × 10/9`: balance / credit | 128,814 / 142,825 | 177,234 / **279,265** | `B2` |
| rule C_POSTOP ≥ W × 1.15 (in-repo W) | 170,130 | **335,316** | |

End-to-end through EntryPoint (`B1`, ample limits, **current defaults**), charge vs the full
EntryPoint cost to SP at the validation price snapshot ("need"):

| case | Prague charge − need (aPNTs) | Amsterdam charge − need (aPNTs) | Amsterdam actualGasUsed |
|---|---|---|---|
| balance, first op | +6.88 | +2.07 | 1,340,281 |
| balance, second op | +12.99 | +14.94 | 771,782 |
| **credit, first op** | +5.49 | **−8.03** (charge 126.94 < need 134.97; not clamped, a0 = 726) | 1,227,013 |
| balance, user call reverts | +7.42 | +2.61 | 1,289,479 |
| balance, user writes 1 / 2 / 3 fresh slots | +7.14 / +7.39 / +7.63 | +3.31 / +4.52 / +5.73 | 1,441,503 / 1,540,675 / 1,639,847 |
| **credit, user writes 1 / 2 / 3** | +5.76 / +6.00 / +6.25 | **−6.79 / −5.58 / −4.37** | 1,328,236 / … |

**I9 is violated at the current defaults under Amsterdam:** every credit-mode op is charged
4.4–8.0 aPNTs (≈ 3–6 %) less than SP pays EntryPoint; the operator subsidises it. Cause:
C_POSTOP + C_WRAP = 180k < W_postop + wrap ≈ 281k.

With the op at `paymasterPostOpGasLimit = MIN = 200k` (`B5`/`B8` "defaults"), Amsterdam postOp
OOGs in all 6 scenarios: the user's execution is rolled back, the user pays 0, and **SP's
EntryPoint deposit pays the whole op** (need 97.8–141.4 aPNTs per op). This is the I10 path, but
any user can trigger it at the current defaults by choosing a postOp limit in [200k, ~365k), which
validation admits. That makes it a griefing vector against SP's deposit on every Amsterdam chain
until the tuple is changed.

### 4.4 C_WRAP (probe slots pre-set so the probe does no zero→non-zero write)

| measurement | Prague | Amsterdam |
|---|---|---|
| single op: succeeded/200k, succeeded/1M, reverted/200k | 1,770 / 1,756 / 1,770 | **1,870 / 1,856 / 1,870** |
| bundle positions 0..3 | 1,770 ×4 | 1,870 ×4 |

C_WRAP 5,000 keeps 2.67×. (The in-repo probe tests fail under Amsterdam only because the probe's
own fresh writes exceed its 200k limit.)

### 4.5 Proposed tuples end-to-end (postOpGasLimit = MIN; `B8`, plus `B5`)

| tuple (MIN / SETTLE / C_WRAP / C_POSTOP) | Amsterdam: settles in all 6 scenarios? | charge ≥ need in all 6? | min charge − need (aPNTs) |
|---|---|---|---|
| 200k / 160k / 5k / 175k (defaults) | **no (0/6)** | **no** | −141.1 |
| 385k / 365k / 5k / 336k (raw needs) | yes | yes | +19.8 |
| **440k / 420k / 5k / 340k** (needs + 15 %) | yes | yes | +20.2 |
| 440k / 420k / 5k / 300k (C_POSTOP below the rule, control) | yes | yes (penalty budget masks it) | +15.8 |
| B5: 300k/280k, 350k/330k (C_POSTOP = MIN) | no / no | — | — |
| B5: 400k/380k, 450k/430k, 500k/480k (C_POSTOP = MIN) | yes | yes | — |

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
| `C_POSTOP_GAS` | 175,000 | [175,000, MIN] | ≥ 170,130 (§4.3) | **≥ 335,316** (291,579 × 1.15) (§4.3) | **340,000** (rule already has the 15 %) | **NO** (I9: credit −4.4…−8.0 aPNTs/op) | (a), needs MIN ≥ 340k first or in the same queue |
| `C_WRAP_GAS` | 5,000 | [5,000, 50,000] | ≥ 1,770 (§4.4) | ≥ 1,870 (§4.4) | 5,000 (2.67× kept) | yes | none |

Validation: the full tuple **(MIN 440,000, SETTLE 420,000, C_WRAP 5,000, C_POSTOP 340,000)**
settles and covers the full cost in all 6 EntryPoint scenarios (§4.5). All four values are inside
the hard bounds, so the fix is **path (a) only: one `queueGasParams(440000, 420000, 5000, 340000)`
→ ≥ 48 h → `executeGasParams()`, behind the 48 h timelock**. Note that `queueGasParams` checks
`cPostop ≤ minPost` of the *same* call, so the single queued tuple is valid.

**Path (b) (source change + new candidate/tag): not required by any measurement here.** It would
only be needed for: (1) changing the in-bytecode defaults (all-zero slot → 200k/160k/5k/175k) so
that a fresh deployment or an un-queued instance is Amsterdam-safe from block 0; (2) the legacy
352-byte context path (`LEGACY_SETTLE_GAS_BOUND` 160k, `LEGACY_C_WRAP_GAS`), which applies only to
5.5.0 contexts admitted before an upgrade mid-bundle; (3) the §3.3 latent hazard, if the postOp
write/clear set ever changes. None blocks the parameter fix.

### 5.2 SDK / bundler parameters (per op; not contract-enforced except postOp ≥ MIN)

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

About EIP-7825: nine transactions need more than 2^24 = 16,777,216 gas (rows 2, 4, 7, 8, 13, 14, 20,
and 10 standalone). That is **not** a deployment blocker on Sepolia: the 2^24 cap applies to regular
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
   cases ran with callGas 50k. Those logs were deleted, and every scratch log in `logs/scratch/` comes
   from the final `scratch/Rams2a.t.sol.txt`.

## 8. Files

| path | content |
|---|---|
| `calibration/` | Step-0 raw outputs (nightly, v1.8.6) |
| `logs/suite/` | full `-vv` suite logs (1.7.1 cancun, nightly cancun/prague/amsterdam), `*_rerun.log` (./out suites), `timeline.txt` |
| `result_diffs.md` | the six per-test difference tables |
| `logs/scratch/` | scratch G-layer logs, Prague and Amsterdam (and Amsterdam + reservoir for part A) |
| `g_layer_prague_vs_amsterdam.txt` | every scratch `R2A` row side by side |
| `gasleft/` | real-transaction gasleft probes on anvil |
| `deploy/` | deployment gas log, JSON rows, init-code resolution log |
| `scratch/` | `Rams2a.t.sol.txt` (G layer, gasleft probes), `ResvProbe.sol.txt`, `MockFeed.sol.txt`, `calib.py`, `resv.py`, `deploy.py`, `resolve.py`, `run.sh`, `scr_run.sh`, `cmp.py`, `diff.py`, `parse.py` |

## 9. Summary

- **Calibration: PASS.** nightly 926eb1d matches live Sepolia exactly on 5/5 probes, and the
  Timelock deployment matches the live S2 minimum exactly. v1.8.6 is off on 5/5.
- **Insufficient under Amsterdam:** `SETTLE_GAS_BOUND` 160k (a 205k-gas OOG band),
  `MIN_POST_OP_GAS` 200k (no op settles at MIN, so SP's deposit pays whole ops: griefable),
  `C_POSTOP_GAS` 175k (I9 broken: credit ops under-charged 4.4–8.0 aPNTs each). Also the SDK
  `paymasterVerificationGasLimit` (needs 820k balance / 612k credit), `verificationGasLimit` for
  initCode (801k) and `callGasLimit` (+113.7k per fresh slot). `C_WRAP_GAS` 5k is fine (1,870 measured).
- **Needed values (with 15 % margin): MIN 440,000 / SETTLE 420,000 / C_WRAP 5,000 /
  C_POSTOP 340,000**, validated end-to-end. SDK: paymasterVerificationGasLimit ≈ 945k,
  paymasterPostOpGasLimit = MIN.
- **Source change: not required.** All values are inside the GOV-5 hard bounds, so the fix is
  `queueGasParams` → `executeGasParams` (≥ 96 h) plus an SDK release. Since Sepolia has run
  Amsterdam since 2026-10-06, the current defaults are already live there.
- `gasleft()` excludes the state-gas reservoir and can **rise** across a call (−96,929 measured),
  because EIP-8037 refills are credited to spilling frames. With the current SP code this was not
  observed to corrupt EntryPoint accounting. A postOp that clears more fresh slots than it writes
  would make EntryPoint's unchecked `preGas − gasleft()` wrap (§3.3).
