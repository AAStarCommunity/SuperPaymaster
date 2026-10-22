# R-AMS-2 (B layer) — bundler acceptance on an Amsterdam-level chain

DSR CC-125 `d13dd9eb`, task R-AMS-2 (B layer), spec `03-final-spec.md` §10.8b. Date of run: 2026-10-22 (second
pass, after an adversarial review of commit `c3eb1011`; see "Changes vs c3eb1011" directly below).
Everything ran on local anvil only, with anvil's public dev keys only. No public-chain RPC was used and no
transaction was sent anywhere else. `contracts/src`, `contracts/script`, `foundry.toml` and `.github` are untouched.

Three G1 variants:

- **(a)** current defaults (SP GasParams 200k/160k/5k/175k, op pmV 300k / pmP 250k / v 250k / v+initCode 1.2M);
- **(b) PRELIMINARY** — the earlier, uncalibrated sweep (SETTLE 380000, MIN 400000, C_POSTOP 340000, op pmV 820000 / pmP 400000);
- **(c) CALIBRATED** — the G-layer tuple from branch `cc125/rams-2a-glayer` (`457a133`): SP GasParams MIN 440000 / SETTLE 420000 /
  C_WRAP 5000 / C_POSTOP 340000; op pmP 440000, pmV 1150000 (covers the 998,874 SP_RENEW need + 15 %), v 150000, v with initCode 4600000.
  A supplementary Rundler-only run **(c′)** repeats (c) with Rundler's `--max_verification_gas 6000000` (§5.5).

## Changes vs c3eb1011

| # | review item | what changed | effect on numbers |
|---|---|---|---|
| 1 | evidence not committed | B0, G1 (a) and (b) re-run with the committed scripts. Every cited log is now committed (`git add -f`, the repo's `.gitignore` ignores `*.log`): `{a,b,c,c-rundler-mvg6m}/{rundler,alto,altoMulti}-cases.log`, `*-bundler.log` (full process logs), `rundler-events.log`, `alto*-errors.log`, `deploy.log` (full, was `tail -40`), `setup.log`, `receipts.log`; `b0/b0-*-{bundler,send,setup}.log`. New `deploy-receipts.json` per run (tx hash, contract, gas limit, gasUsed, status for all 55 deploy txs, `script/b-layer/ams-receipts.mjs`). No file exceeds 5 MB, so none is gzipped except the traces | **none.** All 63 + 63 matrix rows of (a) and (b) were compared field by field with `c3eb1011` (verdict, error, both raw estimates, needs, validation frames, on-chain success / actualGasUsed / actualGasCost / bundle gasUsed / gasLimit): **0 differences.** B0: same verdict on all 30 (configuration, op) pairs; only addresses and hashes differ |
| 1 | `6/55 > 2^24`, SP impl 52,389,391, AD-3 "all status 1" | now backed by `{a,b,c}/deploy-receipts.json` | confirmed in all three deployments: 55 txs, all `status 1`, the same 6 over 2^24 with identical gasUsed (§6.3 AMS-6) |
| 2 | probe replayed estimates without the estimated PVG | `ams-probe.mjs` now replays the **complete** estimate: v, call, **preVerificationGas**, pmV, pmP as returned (`g1-lib.mjs` `gasOverride.preVerificationGas`). The substitution that remains is stated in §3 and in every `sufficiency.filledByUs` | every "executes with the estimate?" verdict in (a) and (b) is **unchanged** |
| 3 | §6.1 Alto rows overgeneralized | §6.1 rewritten per case from `*/matrix.json` | 240,000 is B10 only; ordinary supplied pmP = 300,000 (a) / 480,000 (b) / 528,000 (c); B5 supplied 1,306,619 **executes**; pmP 137,851 qualified |
| 4 | §6.1 explanation | the "invalid account signature makes sigFail unusable" claim is removed; the fail-closed path is shown with a token-level trace (`explain/`); the 497,292 convergence is labelled an **inference** | — |
| 5 | fee invariance | B7 at 3 gwei investigated: the probe's generous op exceeds B7's credit cap; with a smaller baseline the minima are identical (§6.1) | — |
| 6 | §5.1 merged variants | per-variant exact minima (b is 9 gas lower than a in the SP frame); B4 per factory | — |
| 7 | §6.5 coverage | 60/80 captured, 48/68 checked; the 12 factory-OOG traces per variant are skipped (now listed explicitly by `access-check.mjs`); (a) OOG samples have R3 = 0 | — |
| 8 | variant (c) | new: §5.4, §5.5 | — |
| — | (found while re-deriving) | §5.3 bundle tx gasLimit ranges: c3eb1011 attributed altoMulti's range to Alto | Alto 1,596,016 (every tx), altoMulti 1,596,016–3,179,021 |

## 0. Calibration gate (step 0): PASS

`/tmp/fd/nightly/anvil --hardfork amsterdam`, minimum gas at which `eth_call` from anvil account 0 succeeds
(binary search, lower bound 0). Script: `script/b-layer/ams-calibrate.mjs`. Run first in this session on a standalone
anvil (`--gas-limit 60000000`), then again at the start of every G1 run (`{a,b,c,c-rundler-mvg6m}/calibration.json`).
Identical in every case.

| probe | live Sepolia (Amsterdam) | anvil 1.8.7-nightly `926eb1d0` | match |
|---|---|---|---|
| create `0x00` | 207,606 | 207,606 | ✅ |
| create `0x6101006000f3` | 599,432 | 599,432 | ✅ |
| create `0x600160005500` | 317,700 | 317,700 | ✅ |
| create `0x6001600055600260005500` | 320,075 | 320,075 | ✅ |
| 1 wei to fresh `0xa3a3…a3` | 204,600 | 204,600 | ✅ |

`eth_estimateGas` returns the same five numbers.

## 1. Versions and commits

All tools were rebuilt in this session (the earlier binaries no longer existed).

| component | version / commit | how obtained |
|---|---|---|
| SuperPaymaster | branch `cc125/rams-2b-blayer` (from `c3eb1011`); submodules `--init --recursive` | — |
| chain engine | foundry **nightly `926eb1d087523f1de437e3c0c49ea6d26407e827`**, `anvil 1.8.7-nightly` (build timestamp 2026-10-22T06:24:10Z) | `foundry_nightly_linux_amd64.tar.gz`, sha256 `df74eb56171295ee11548e3ef9eb8209befb67e1ab595afe35f27dde4c22a6a1`, equal to the release's `foundry_nightly_linux_amd64.sha256` |
| contract build | **forge 1.7.1** (`foundry_v1.7.1_linux_amd64.tar.gz`, sha256 `cf7e688ed0c4c48adffca788b496076e31060b67ac5afe1e43dbb5499c20c88b`, equal to the release `.sha256`), `forge build` = `[profile.default]` as `deploy-core` does | — |
| solc | 0.8.33 (repo), 0.8.28 (Alto), 0.8.26 (Rundler) | official `solc-static-linux` assets from `github.com/ethereum/solidity/releases` in `~/.svm/<v>/` |
| Rundler (primary) | **v0.11.0, `2a3db23724bc995e3d7fcf7ee270fa2b759612aa`** | `cargo build --release --bin rundler`, toolchain 1.92.0 (`rust-toolchain.toml`), protoc 29.3 (`protoc-29.3-linux-x86_64.zip`, sha256 `3e866620c5be27664f3d2fa2d656b5f3e09b5152b42f1bedbf427b333e90021a`), forge 1.7.1 on PATH |
| Alto (cross-check) | **v1.2.5, `45bbf3410ac3d91b38392bbe81a720fcdfef3ac5`** (`git describe` = `v1.2.5`) | pnpm 8.15.4 (`packageManager`), `pnpm install --frozen-lockfile && pnpm run build:contracts && pnpm run build` |
| node / viem (harness) | node 22.22.0, viem 2.52.2 (`pnpm install --frozen-lockfile` at the repo root, pnpm 10.28.0 — pnpm 8 cannot read the root lockfile v9) | — |

## 2. Exact commands

```
# step 0 (standalone)
anvil --port 18845 --chain-id 31337 --hardfork amsterdam --gas-limit 60000000
node script/b-layer/ams-calibrate.mjs http://127.0.0.1:18845 <out>

# B0 (fresh anvil per configuration; pm verification gas 100000 = recorded value, 400000 = raised)
script/b-layer/ams-b0-run.sh /tmp/bl/b0 /tmp/bl/rundler /tmp/bl/alto docs/design/aoa-balance-mode/b-layer/amsterdam/b0 100000 400000

# G1 B1–B10: (a) current defaults, (b) PRELIMINARY, (c) CALIBRATED; then collect each
script/b-layer/ams-g1-run.sh /tmp/bl/g1a /tmp/bl/rundler /tmp/bl/alto a
script/b-layer/ams-g1-run.sh /tmp/bl/g1b /tmp/bl/rundler /tmp/bl/alto b
script/b-layer/ams-g1-run.sh /tmp/bl/g1c /tmp/bl/rundler /tmp/bl/alto c
G1_DEPLOY_JSON=docs/design/aoa-balance-mode/b-layer/amsterdam/<v>/deploy.json script/b-layer/ams-g1-collect.sh /tmp/bl/g1<v> <v>

# (c′) supplementary: Rundler only, its verification-gas cap raised
AMS_OUT=c-rundler-mvg6m G1_BUNDLERS=rundler RUNDLER_EXTRA="--max_verification_gas 6000000" \
  script/b-layer/ams-g1-run.sh /tmp/bl/g1c2 /tmp/bl/rundler /tmp/bl/alto c
G1_BUNDLERS=rundler G1_DEPLOY_JSON=docs/…/amsterdam/c-rundler-mvg6m/deploy.json script/b-layer/ams-g1-collect.sh /tmp/bl/g1c2 c-rundler-mvg6m

# §6.1 investigation (fresh anvil + variant-a stack, read-only debug_traceCall)
script/b-layer/ams-g1-deploy.sh http://127.0.0.1:18945 docs/…/amsterdam/explain/deploy.json <log>
G1_DEPLOY_JSON=docs/…/amsterdam/explain/deploy.json node script/b-layer/g1-setup.mjs http://127.0.0.1:18945 docs/…/amsterdam/explain/setup.json
G1_DEPLOY_JSON=docs/…/amsterdam/explain/deploy.json node script/b-layer/ams-explain.mjs docs/…/amsterdam/explain/setup.json docs/…/amsterdam/explain/explain.json 497292
# (reservoir/ is from c3eb1011 and was not re-run; its command is in ams-reservoir.mjs)
```

Inside `ams-g1-run.sh` the commands are those of `g1-run.sh` (B1-B10.md §1) with these changes:

```
/tmp/fd/nightly/anvil --port 18645 --chain-id 31337 --hardfork amsterdam --gas-limit 60000000
node script/b-layer/ams-calibrate.mjs http://127.0.0.1:18645 <work>/calibration.json
script/b-layer/ams-g1-deploy.sh …            # = g1-deploy.sh + forge script --skip-simulation --gas-estimate-multiplier 110
node script/b-layer/ams-receipts.mjs …       # receipts of every broadcast tx
node script/b-layer/ams-gasparams.mjs …      # b: queueGasParams(400000,380000,5000,340000); c: (440000,420000,5000,340000) → warp 48h+60s → executeGasParams
G1_ESTIMATE=1 [G1_GAS_JSON=… G1_MIN_POST_OP_GAS=…] node script/b-layer/g1-cases.mjs …
```

`G1_GAS_JSON`: (b) `{"pmVerificationGasLimit":"820000","pmPostOpGasLimit":"400000"}`, MIN 400000; (c)
`{"verificationGasLimit":"150000","verificationGasLimitInit":"4600000","pmVerificationGasLimit":"1150000","pmPostOpGasLimit":"440000"}`, MIN 440000.
Rundler and Alto start exactly as in `g1-run.sh`: Rundler with `--chain_spec docs/…/b-layer/rundler-chain-31337.toml` (defaults otherwise,
so `max_verification_gas` = 5,000,000). Alto runs as `alto` (defaults) and as `altoMulti` (`--min-entity-stake 1e18
--min-entity-unstake-delay 86400 --enforce-unique-senders-per-bundle false`), `--safe-mode true`, manual bundling.

## 3. Adaptations (every change vs the Osaka scripts)

| # | what | why |
|---|---|---|
| AD-1 | anvil = nightly `926eb1d0`, `--hardfork amsterdam` (was anvil 1.7.1 `--hardfork osaka`) | the task; the only engine that matches live Sepolia Amsterdam gas (§0) |
| AD-2 | anvil `--gas-limit 60000000` (was the 30M default) | Under EIP-8037 the SuperPaymaster impl CREATE uses 52,389,391 (receipts), so the 30M default cannot deploy the stack. 60M is Sepolia's block gas limit (taken from memory, not re-read, since public RPC is not allowed). The calibration values do not depend on it (§0). Rundler's chain spec still says `block_gas_limit = 30000000` (unchanged file); bundle txs here are ≤ 6.7M |
| AD-3 | `ams-g1-deploy.sh` = `g1-deploy.sh` + `forge script --skip-simulation --gas-estimate-multiplier 110` | forge 1.7.1 simulates with its own pre-Amsterdam EVM (c3eb1011's first attempt: the first CREATE was sent with gas 109,354 and failed). With `--skip-simulation` every tx gets its limit from the Amsterdam node's `eth_estimateGas`; ×1.3 would put the SP CREATE at 68M > 60M. Same 55 transactions, **all `status 1`** (`*/deploy-receipts.json`) |
| AD-4 | `lib.mjs` `artifact()`: if `out/<file>/<name>.json` is missing, take `<name>.default.json` | forge 1.7.1 writes `SimpleAccountFactory.default.json` + `.registry-size.json` (compilation_restrictions). It selects the profile.default artifact, which is the one that ships |
| AD-5 | B0 on chain 31337 for both bundlers (Rundler via `rundler-chain-31337.toml`), one fresh anvil per configuration; `b0-send.mjs` reads `B0_PM_VGL` (default 100000 = recorded) | README §3 used Rundler `--network dev` on chain 1337. Second B0 value 400000: see §4 |
| AD-6 | `g1-lib.mjs`: `G1_GAS_JSON` / `G1_MIN_POST_OP_GAS` override the fixed op gas; `buildG1Op` accepts `gasOverride` (now incl. `preVerificationGas`) and returns its `params` | variant (b)/(c) op gas, and the probe rebuilds ops with other gas. Defaults unchanged |
| AD-7 | `g1-cases.mjs`: with `G1_ESTIMATE=1`, `submit()` first runs `ams-probe.mjs`; `outcome()` also reads the bundle tx and the EntryPoint events back from the chain (`onchain`) | step 3 of the task. Probe traffic goes straight to anvil (not through the trace proxy) except the two `eth_estimateUserOperationGas` calls, which go to the bundler under test |
| AD-8 | variants (b)/(c): GasParams via the owner's governance path `queueGasParams` → `evm_increaseTime` 48 h + 60 s → `executeGasParams`, read back (`{b,c}/gasparams.json`) | the task. (b) cWrap kept at 5000, the op carries pmP = MIN; (c) as given by the task |
| AD-9 | evidence goes to `amsterdam/{b0,a,b,c,c-rundler-mvg6m,explain,reservoir}/`. `*-results.json` and logs are plain (< 5 MB); traces stay `.jsonl.gz`; the collectors gzip any file > 5 MB | — |
| AD-10 | `ams-receipts.mjs` (new), log retention in `ams-b0-run.sh` / `ams-g1-collect.sh` | review item 1 |
| AD-11 | `access-check.mjs`: a simulation with no account phase is listed as `SKIPPED` with the count of captured / checked / skipped per file (it was dropped silently) | review item 7. Classification of checked simulations unchanged |
| AD-12 | `ams-g1-run.sh`: variant `c`; optional `AMS_OUT`, `G1_BUNDLERS`, `RUNDLER_EXTRA` (supplementary run only) | review item 8, §5.5 |

**Probe method (`ams-probe.mjs`), per op, immediately before it is submitted:**
(1) `eth_estimateUserOperationGas` from the bundler under test in two shapes: *pm supplied* (the case's paymaster gas fields) and *pm omitted*
(both omitted). call/verification/PVG are always omitted from the request.
(2) **min need**: the smallest value of each executable field at which `EntryPoint.handleOps([op])` fully succeeds (no FailedOp,
`UserOperationEvent.success`, no `PostOpRevertReason`), the other fields held generous (v 1.5M / 4M with initCode, call 0.5M, pmV 2M,
pmP 1.5M, PVG 100k). Binary search with `debug_traceCall` (callTracer + logs), tx gas 16,000,000, fee 0.1 gwei.
(3) **does the estimate execute**: the op rebuilt with the **complete** estimate — every gas field the bundler returned (verificationGasLimit,
callGasLimit, **preVerificationGas**, paymasterVerificationGasLimit, paymasterPostOpGasLimit) — at the case's real fees, then the same handleOps check.
**One substitution remains, explicitly:** a field the bundler does *not* return is filled — pm supplied → the value the case sent; pm omitted → 0
(what the bundler itself would put in the op). In this run that happens only for `paymasterPostOpGasLimit` on Rundler (it never returns one);
every Alto estimate that succeeded returned all five fields. The filled fields are listed per op in `sufficiency.filledByUs` and marked `*` in `matrix.md`.
(4) the op as submitted through handleOps.

## 4. B0 — bundler rule checks on Amsterdam (`b0/*.json`, logs `b0/b0-<config>-{bundler,send,setup}.log`)

Re-run in this pass: every verdict equals c3eb1011.

| configuration | pm verif gas | control | op011 TIMESTAMP | sto031 unstaked own storage | op070 unstaked TSTORE | sto021 staked external write | verdict |
|---|---|---|---|---|---|---|---|
| Rundler v0.11.0 | 100,000 | included | `-32502 paymaster uses banned opcode: TIMESTAMP` | `-32500 validation reverted:` (**OOG**) | `-32502 entity stake/unstake delay too low` | `-32500 validation reverted:` (**OOG**) | rejections match, but 2 of 4 are from OOG, not from a rule |
| Alto v1.2.5 safe | 100,000 | included | `-32502 banned opcode: TIMESTAMP` | `-32500 AA33 reverted - 0x` (**OOG**) | `-32502 unstaked paymaster accessed paymaster slot 0x0` | `-32500 AA33 reverted - 0x` (**OOG**) | same |
| Alto v1.2.5 unsafe | 100,000 | included | included | `-32500 UserOperation reverted with reason: AA33 reverted - 0x` | included | same | the 2 storage writers cannot even execute at 100k |
| **Rundler v0.11.0** | **400,000** | included | `-32502 …banned opcode: TIMESTAMP` | `-32502 entity stake/unstake delay too low` | `-32502 entity stake/unstake delay too low` | `-32502 paymaster accesses inaccessible storage at address … slot …` | **PASS (by rule)** |
| **Alto v1.2.5 safe** | **400,000** | included | `-32502 banned opcode: TIMESTAMP` | `-32502 unstaked paymaster accessed paymaster slot 0x0` | `-32502 unstaked paymaster accessed paymaster slot 0x0` | `-32502 paymaster has forbidden read from … slot …` | **PASS (by rule)** |
| Alto v1.2.5 unsafe | 400,000 | included | included | included | included | included | negative control: all 4 violators are valid, executable ops |

**B0 holds on Amsterdam, but only at 400k.** At the recorded 100,000 gas, the two storage-writing violators run out
of gas in the paymaster frame, because one zero→nonzero SSTORE now costs ~110k (calibration probe 3 minus probe 1). So the rejection no longer
shows that the rule is enforced (README §2 finding 2 saw the same on geth's `bogota`). With 400k, both bundlers reject
all four by the rules and accept the control, and unsafe Alto includes all four.

## 5. G1 B1–B10 result matrices

Complete per-op tables, with the exact bundler error, both estimates (v / c / pvg / pmV / pmP) and whether each executes, the min need, the on-chain
result and flags: **[`a/matrix.md`](a/matrix.md)**, **[`b/matrix.md`](b/matrix.md)**, **[`c/matrix.md`](c/matrix.md)**,
**[`c-rundler-mvg6m/matrix.md`](c-rundler-mvg6m/matrix.md)**. Machine-readable copies are `*/matrix.json`; the raw bundler responses are
`*/<bundler>-results.json`; per-case console output `*/<bundler>-cases.log`; full process logs `*/<bundler>-bundler.log`. Notation: v =
verificationGasLimit, pmV = paymasterVerificationGasLimit, pmP = paymasterPostOpGasLimit; "frame" = gasUsed of the frame in the generous baseline.

### 5.1 Minimum gas each op needs on Amsterdam, per variant (exact, from `*/matrix.json` `needs`)

callGasLimit need is 3,696 everywhere. pmP need equals the MIN floor whenever MIN ≥ the settle need: (a) 288,276 (269,585 for B7) at SETTLE 160k,
which is *above* MIN 200k; (b) 400,000 = MIN; (c) 440,000 = MIN.

**(a)** (nothing is ever included, so every case runs against a fresh SP):

| case | v need | pmV need | pmP need | SP frame | account frame | createSender |
|---|---|---|---|---|---|---|
| B1, B3, B9, B8, B2*, aftermath (BALANCE) | 124,346 | 882,375 | 288,276 | 864,025 | 6,850 | — |
| B5 SP_RENEW | 124,346 | 998,874 | 288,276 | 980,524 | 6,850 | — |
| B6 account renew | 150,839 | 870,575 | 288,276 | 852,225 | 33,343 | — |
| B7 CREDIT | 124,346 | 717,084 | 269,585 | 698,734 | 6,850 | — |
| B4 unstaked / lowStake / shortDelay | 3,983,015 | 882,420 | 288,276 | 864,056 | 4,850 | 3,854,479 |
| B4 ok (the staked factory) | 3,885,095 | 882,420 | 288,276 | 864,056 | 4,850 | 3,756,559 |

**(b)** — the SP pmV need and frame are **9 gas lower** than (a) for the same state; after the first included op (B7) the BALANCE need drops to 784,446:

| case | v need | pmV need | pmP need | SP frame |
|---|---|---|---|---|
| B9, B1, B3 (fresh SP) | 124,346 | 882,366 | 400,000 | 864,016 |
| B5 SP_RENEW (fresh) | 124,346 | 998,865 | 400,000 | 980,515 |
| B6 account renew (fresh) | 150,839 | 870,566 | 400,000 | 852,216 |
| B7 CREDIT (fresh) | 124,346 | 717,075 | 400,000 | 698,725 |
| B8, B2a/b, aftermath (after B7 included) | 124,346 | 784,446 | 400,000 | 766,096 |
| B4 ×3 / B4 ok (after B7 included) | 3,983,015 / 3,885,095 | 784,491 | 400,000 | 766,127 (createSender 3,854,479 / 3,756,559) |

**(c)** — B9-below is rejected on Rundler but included on Alto, so the state before each case differs slightly per bundler:

| case | v need | pmV need | pmP need | SP frame |
|---|---|---|---|---|
| B9-below, Rundler B9-above (fresh SP) | 124,346 | 882,366 | 440,000 | 864,016 |
| B1, B3, B8, B2a/b (after the first included op) | 124,346 | 784,446 | 440,000 | 766,096 |
| B5 SP_RENEW (after the first included op) | 124,346 | **900,945** | 440,000 | 882,595 |
| B6 account renew | **150,839** | 772,646 | 440,000 | 754,296 (account 33,343) |
| B7 CREDIT | 124,346 | 619,155 | 440,000 | 600,805 |
| B4 ×3 / B4 ok | 3,983,015 / 3,885,095 | 784,491 | 440,000 | 766,127 (createSender 3,854,479 / 3,756,559) |
| a sender's second op (Alto B9-above, B2-aftermath) | 26,426 | 588,606 | 440,000 | 570,256 |

The calibrated pmV 1,150,000 covers every need measured in this run (max 998,874 = fresh SP, SP_RENEW). v 150,000 does **not** cover B6 (150,839).

### 5.2 Variant (a): current defaults (op: v 250k, v+initCode 1.2M, pmV **300k**, pmP **250k**; SP GasParams 200k/160k/5k/175k)

| case | Rundler v0.11.0 | Alto v1.2.5 | altoMulti | on chain |
|---|---|---|---|---|
| B9-below, B9-above, B1, B3 (×3), B5, B6, B7, B8, B2a (×2), B2b (×3), B2-aftermath | reject `-32603 Failed to decode validation output 0x…` (the op is `AA36 over paymasterVerificationGasLimit` in handleOps) | reject `-32500 AA36 over paymasterVerificationGasLimit` | same as Alto | nothing included |
| B4 ×4 (unstaked / 0.5 ETH / 3600 s / ok) | reject `-32603 Failed to decode validation output 0x00…00` (`AA13 initCode failed or OOG`) | reject `-32500 AA13 initCode failed or OOG` | same | nothing included |
| B10 | supplied: `-32500 validation reverted: [reason]: AA36 over paymasterVerificationGasLimit`; omitted: pmV 60,859, **no pmP** | supplied (pmV 300k, pmP 200k): pmV 497,292 / **pmP 240,000**; omitted: pmV 497,292 / pmP 137,851 | same | — |

**(a) fails on Amsterdam: 0 of 20 ops per bundler (60 submissions) are included.** Every rejection is gas, not a rule (`OUTSIDE 0 / FORBIDDEN 0`, §6.5).
pmV 300k is ~2.9× too low; pmP 250k is below the 288,276 needed; v+initCode 1.2M is ~3.3× too low. The stake checks could not be exercised.

### 5.3 Variant (b): PRELIMINARY candidates (op pmV **820k**, pmP **400k**; SP GasParams MIN 400k / SETTLE 380k / cWrap 5k / C_POSTOP 340k)

| case | pmV need vs 820k | Rundler v0.11.0 | Alto v1.2.5 | altoMulti | on chain (UserOperationEvent success, actualGasUsed, postOp) |
|---|---|---|---|---|---|
| B9-below / B9-above | 882,366 > 820k | reject `-32500 validation reverted:` (handleOps: `AA33 reverted`) | reject `-32500 AA33 reverted - 0x` | same | not included. The stake check is masked by OOG |
| B1, B3 (×3) | 882,366 > 820k | reject | reject | reject | not included |
| B5 SP_RENEW | 998,865 > 820k | reject | reject | reject | not included |
| B6 account renew | 870,566 > 820k | reject | reject | reject | not included |
| **B7 CREDIT** | 717,075 ✓ | **included** | **included** | **included** | ✅ 1,157,426 gas, postOp ok, `debts 0 → 294.06` |
| **B8 TSTORE** | 784,446 ✓ | **included** | **included** | **included** | ✅ 1,152,705 gas, postOp ok |
| B4 ×4 | v need 3.89–3.98M > 1.2M | reject `-32603 Failed to decode validation output 0x00…00` (AA13) | reject `-32500 AA13 initCode failed or OOG` | same | not included. The factory stake checks are masked by OOG |
| B10 | — | supplied: pmV echoed **820,000**, no pmP; omitted: pmV 60,857 | **all 3 shapes: `Hex size (33) exceeds padding size (16)`** (AMS-4) | same | — |
| **B2a** (same sender, 2 ops) | 784,446 ✓ | ✅ 1 tx (1,153,019 + 688,445) | ✅ both, in **2 txs** (D3) (1,152,705 + 956,865) | ✅ 1 tx | success, postOp ok |
| **B2b** (same sender, 3 ops, balance 2.5·x0) | 784,446 ✓ | ❌ **all 3 accepted, none included** (F1): `FailedOp(2,"AA34 signature error")` at bundle time → `Empty bundle with 3 rejected ops and 1 rejected entities` → `Removed entity from pool: paymaster` | ✅ ops 1–2 included, op 3 rejected on submit `-32500 AA34 signature error` | ✅ same as Alto | — |
| B2-aftermath | 784,446 ✓ | reject `-32504 paymaster 0x0b30… throttled or banned` | ✅ included (1,152,705) | ✅ included | — |

Bundle tx gasLimit (b): Rundler 1,673,330–3,324,648; Alto 1,596,016 (every tx); altoMulti 1,596,016–3,179,021. gasUsed is always below the limit.
**No bundle tx reverted and no op failed on chain (OOG / AA33 / AA50 / postOp revert = 0).**

### 5.4 Variant (c): CALIBRATED (SP GasParams MIN 440k / SETTLE 420k / C_WRAP 5k / C_POSTOP 340k; op pmV **1.15M**, pmP **440k**, v **150k**, v+initCode **4.6M**)

GasParams read back after `executeGasParams`: `{minPostOpGas 440000, settleGasBound 420000, cWrap 5000, cPostop 340000}` (`c/gasparams.json`).

| case | expected (Osaka) | Rundler v0.11.0 | Alto v1.2.5 | altoMulti | on chain (actualGasUsed; postOp) |
|---|---|---|---|---|---|
| **B9-below** (SP 0.1 ETH / 86400 s) | reject, stake | **reject `-32502 entity stake/unstake delay too low`**, `needsStake.paymaster` = SP, `accessingEntity paymaster`, `accessedAddress` = the operator token, `slot 0xf`, `minimumStake 1e18`, `minimumUnstakeDelay 86400` — **identical to Osaka** | **included** (D1) | **included** (D1) | Alto: ✅ 1,254,625 |
| B9-above (1 ETH) | include | ✅ included 1,254,625 | ✅ 862,945 (sender's 2nd op) | ✅ 862,945 | postOp ok |
| B1 | include | ✅ 1,156,705; burn > 0, lockedOf 0, operator Δ = −revenue Δ | ✅ 1,156,705 | ✅ | ok |
| B3 (3 senders) | include, 1 tx | ✅ **all 3 in one tx** (1,156,710 / 1,044,108 / 1,044,116), 3 `LockSettled` | op 1 ✅; ops 2–3 **`-32502 unstaked account accessed 0x84e4…5263 slot 0x0`** (= sender b3a, **D2**) | same (D2) | ok |
| B5 SP_RENEW | include | ✅ 1,273,204, `AllowanceRenewed(bySP=true)` | ✅ 1,273,204 | ✅ | ok |
| **B6** account renew | include | ❌ reject `-32603 Failed to decode validation output 0x00…00` (handleOps: **`AA26 over verificationGasLimit`**, v need 150,839 > 150,000) | ❌ **accepted, not included**: bundle-time `eth_estimateGas` → `FailedOp(0,"AA26 over verificationGasLimit")`; no tx sent (`c/alto-bundler.log`) | same | — |
| B7 CREDIT | include | ✅ 975,378, `debts 0 → 273.40`, creditReserved 0 | ✅ 975,378 | ✅ | ok |
| B8 TSTORE | include | ✅ 1,156,705 | ✅ 1,156,705 | ✅ | ok |
| **B4-unstaked** | reject, factory stake | reject **`-32000 precheck failed: verificationGasLimit is 5750000 but must be at most 5000000`** (v + pmV > Rundler's default `max_verification_gas`; see §5.5) | **reject `-32502 unstaked factory accessed factory slot 0x0`** — as Osaka | same | — |
| **B4-lowStake** (0.5 ETH) | reject | precheck (same) | **included** (D1) | **included** (D1) | ✅ 5,015,419 |
| **B4-shortDelay** (3600 s) | Rundler reject; Alto per config | precheck (same) | included (default delay 1 s) | **included** (86400 configured, D1) | ✅ 5,015,419 |
| B4-ok | include | precheck (same) | ✅ 4,917,499 | ✅ | ok |
| B10 | — | supplied: pmV echoed **1,150,000**, no pmP; omitted: pmV 60,857, no pmP | all 3 shapes throw `Hex size (33) exceeds padding size (16)` (AMS-4) | same | — |
| B2a | 1 bundle | ✅ 1 tx (1,157,019 + 692,445) | ✅ both, **2 txs** (D3) (1,156,705 + 960,865) | ✅ 1 tx (1,157,019 + 692,445) | ok |
| B2b | op 3 rejected | ❌ **F1**: all 3 accepted, none included; `Rejected op … paymaster … AA34` → `Empty bundle with 3 rejected ops and 1 rejected entities` → `Removed entity from pool: paymaster` | ✅ ops 1–2 included, op 3 `-32500 AA34 signature error` | ✅ same | ok |
| B2-aftermath | observation | reject `-32504 paymaster 0x0b30… throttled or banned` | ✅ 862,945 | ✅ | ok |

Per bundler in (c) (20 ops each): Rundler 10 included (B9-above, B1, B3 ×3, B5, B7, B8, B2a ×2), 3 accepted-not-included (B2b), 7 rejected
(B9-below, B6, B4 ×4, aftermath); Alto 15 included, 1 accepted-not-included (B6), 4 rejected (B3 #2/#3, B4-unstaked, B2b #3); altoMulti the same as
Alto. Bundle tx gasLimit (c): Rundler 1,957,497–5,828,429; Alto / altoMulti 1,864,910–6,319,009 —
all below the EIP-7825 cap. **No bundle tx reverted and no included op failed (success = true, no `PostOpRevertReason`) in (c).**

**What (c) answers.**
- **Stake rules are now reached.** B9-below on Rundler is rejected by the stake rule with exactly the Osaka reason and data. B4's three factory-stake cases
  reach the rule on Alto (unstaked: rejected; 0.5 ETH and 3600 s: accepted — D1) and, on Rundler, once its verification cap admits the op (§5.5).
- **Alto D1 and D2 are now observed on Amsterdam** and match Osaka: D1 — B9-below (SP 0.1 ETH), B4 0.5 ETH and B4 3600 s are accepted and included,
  also by altoMulti with `--min-entity-stake 1e18 --min-entity-unstake-delay 86400`; D2 — B3's 2nd/3rd sender are rejected with
  `unstaked account accessed <1st sender> slot 0x0`. D3 (B2a in 2 txs under default Alto) also reproduces.
- **New in (c):** B6 fails because v 150,000 < 150,839 (AMS-7), and Rundler's default `max_verification_gas` 5,000,000 rejects every initCode op
  that carries v 4.6M + pmV 1.15M (AMS-8).

### 5.5 (c′) Supplementary: Rundler with `--max_verification_gas 6000000` (`c-rundler-mvg6m/`)

Same chain setup, same (c) parameters, only this Rundler flag added. Every case except B4 has the same verdict and the same gas quantities as (c); wei amounts can differ slightly with the fresh chain's base fee (e.g. Rundler B2a #1 `actualGasCost` 2,314,038,307,767,054 in (c) vs 2,314,038,275,370,522 in (c′)).

| case | Rundler v0.11.0 (`--max_verification_gas 6000000`) | Osaka (B1-B10.md) |
|---|---|---|
| B4-unstaked (stake 0) | **reject `-32502 entity stake/unstake delay too low`**, `needsStake.factory` = 0xcbEA…47cc, `accessingEntity factory`, `accessedEntity factory`, `slot 0x0`, `minimumStake 1e18`, `minimumUnstakeDelay 86400` | same reason, `needsStake.factory` ✅ |
| B4-lowStake (0.5 ETH) | **reject**, same reason, `needsStake.factory` = 0x1429…0F20f | same ✅ |
| B4-shortDelay (3600 s) | **reject**, same reason, `needsStake.factory` = 0x162A…6890 | same ✅ |
| B4-ok (1 ETH / 86400 s) | ✅ included, 4,917,499 gas, bundle tx 4,568,036 / 6,631,798 | included ✅ |
| B9-below | reject `-32502 entity stake/unstake delay too low` (as in (c)) | same ✅ |

With the cap raised, **all four Rundler stake-rule rejections are Osaka-equivalent.**

## 6. Flags (task step 3)

### 6.1 Bundler estimate vs what the op needs on Amsterdam (per case, from `*/matrix.json`; "executes?" = complete-estimate replay, §3)

**Alto v1.2.5 (alto; altoMulti returned the same values wherever both estimated):**

| variant / shape | cases | estimate v / c / pvg / pmV / pmP | need pmV / pmP | executes? |
|---|---|---|---|---|
| (a) supplied (pmV 300k, pmP 250k) | B9-below, B9-above, B1, B3 ×3, B8, B2a ×2, B2b ×3, aftermath | 164,041 / 16,323 / 54,969–54,982 / **497,292** / **300,000** | 882,375 / 288,276 | ❌ `AA34 signature error` |
| (a) supplied | B6 | 164,041 / 16,323 / 55,008 / 497,292 / 300,000 | 870,575 / 288,276 | ❌ AA34 |
| (a) supplied | **B5** | 164,041 / 16,323 / 54,982 / **1,306,619** / 300,000 | 998,874 / 288,276 | ✅ **executes** |
| (a) supplied | B4 ×3 / B4-ok | 5,181,863 / 5,058,084 (v) / 16,323 / 56,856 / 497,292 / 300,000 | 882,420 / 288,276 | ❌ AA34 |
| (a) supplied / omitted | **B7** | **error** `-32521 UserOperation reverted during simulation with reason: AA33 reverted 0x` | 717,084 / 269,585 | — |
| (a) omitted | all except B4, B5, B7 | same v / c / pvg, pmV 497,292 / pmP **137,851** | as above | ❌ AA34 |
| (a) omitted | B5 | pmV 1,306,619 / pmP 137,851 | 998,874 / 288,276 | ❌ AA34 (pmP < MIN 200k → SP sigFail) |
| (a) omitted | B4 ×4 | pmV 497,292 / pmP **137,850** | 882,420 / 288,276 | ❌ AA34 |
| (a) B10 suppliedPostOpMin (pmV 300k, **pmP 200k**) | B10 | pmV 497,292 / pmP **240,000** | — / 288,276 | (not replayed) |
| (b) supplied (pmV 820k, pmP 400k) | B9 ×2, B1, B3 ×3 | 164,041 / 16,323 / 54,982 / 497,292 / **480,000** | 882,366 / 400,000 | ❌ AA34 |
| (b) supplied | B6 | … / 55,008 / 497,292 / 480,000 | 870,566 / 400,000 | ❌ AA34 |
| (b) supplied | **B5** | … / 1,306,619 / 480,000 | 998,865 / 400,000 | ✅ **executes** |
| (b) supplied | **B7** | **error** `-32521 … AA33 reverted 0x` | 717,075 / 400,000 | — |
| (b) omitted | B9 ×2, B1, B3 ×3, B6 | pmV 497,292 / pmP 137,851 | as above | ❌ AA34 |
| (b) omitted | B5 | 1,306,619 / 137,851 | 998,865 / 400,000 | ❌ AA34 |
| (b) omitted | **B7** | 164,041 / 16,323 / 54,982 / **516,336** / **243,585** | 717,075 / 400,000 | ❌ AA34 |
| (b) both shapes | B8 and every later case (after the first included op), B10 | **throws** `Hex size (33) exceeds padding size (16)` (AMS-4) | — | — |
| (c) supplied (pmV 1.15M, pmP 440k) | B9-below | 164,041 / 16,323 / 54,982 / 497,292 / **528,000** | 882,366 / 440,000 | ❌ AA34 |
| (c) omitted | B9-below | pmV 497,292 / pmP 137,851 | 882,366 / 440,000 | ❌ AA34 |
| (c) both shapes | every case after B9-below (B9-below was included), B10 | **throws** (AMS-4; 41 occurrences in `c/alto-errors.log`) | — | — |

So the ordinary supplied pmP is the input × 1.2 (300,000 / 480,000 / 528,000); 240,000 is only B10's 200,000 input. pmP 137,851 is the pm-omitted value
in (a) and in (b)/(c) before the first included op, except (a) B4 (137,850), B7 (errors in (a); 243,585 in (b)), and every estimate after the first
included op, which throws.

**Rundler v0.11.0:**

| variant / shape | cases | estimate v / c / pvg / pmV / pmP | executes? |
|---|---|---|---|
| (a) supplied | all | **error** `-32500 validation reverted: [reason]: AA36 over paymasterVerificationGasLimit` (correct: 300k < need) | — |
| (b) supplied | B9 ×2, B1, B3, B5, B6 | **error** `-32500 validation reverted: [reason]: AA33 reverted` (correct: 820k < need) | — |
| (b) supplied | B7, B8, B2*, aftermath, B4 ×4 | v 145,426–153,182 (B4 4,635,822–4,730,070) / 9,100 / 46,704–49,224 / pmV echoed 820,000 / **none** | ✅ (pmP filled with the supplied 400,000) |
| (c) supplied | all except B6 | v 141,264–158,890 (B4 4,635,822–4,730,070) / 9,100 / 46,704–49,224 / echoed 1,150,000 / none | ✅ (pmP filled 440,000) |
| (c) supplied | **B6** | **v 145,458** / 9,100 / 46,728 / 1,150,000 / none | ❌ **`AA26 over verificationGasLimit`** (v need 150,839) |
| (a)(b)(c) omitted | all | v 154,913–155,029 (B4 4,488,756–4,596,478) / 9,100 / 46,704–49,224 / **pmV 60,857–62,840** / **none** | ❌ AA34 (pmP filled 0 → below MIN → SP sigFail, F2) |

Account-side v and call estimates are otherwise not low (v need 124,346; call need 3,696). In (c) the supplied-shape B2-aftermath v estimate is
32,822 vs a need of 26,426 (the sender's second op).

**Why Alto's pmV can be low — what is shown and what is inferred.**

*Shown (SP source + trace).* SP's validation-time token call fails closed. `_reserveForOp` calls the token through `_tokenWord`
(`SuperPaymaster.sol` 349–350), which uses a raw `call(gas(), …)` and reports any failure, **including out-of-gas in the child**, as `ok = false`
(367–370); `ok = false` → `MODE_NONE` → `return ("", _packValidationData(true, 0, 0))` (318), i.e. paymaster **sigFail without a revert**, provided
SP keeps enough gas to return (the 1/64 it retains under EIP-150). `explain/explain.json` (`ams-explain.mjs`, fresh variant-a stack) traces B1 at Alto's pmV 497,292: the SP frame uses 476,951 of 497,292 and does
**not** revert; its `tryLockForGas` call gets 425,168 gas and the token's inner frame runs **out of gas**; SP returns `validationData = 1`
(sigFail); the EntryPoint reports `FailedOp(0, "AA34 signature error")` — exactly the "executes?" column above.

The script's search uses the **EntryPoint verdict** as its predicate (not the SP frame's own revert status), so it only locates verdict
changes. In every traced point the SP frame itself returned without error; what changes is EntryPoint's verdict. Measured points only (B1 and B5;
the verdict is **not monotonic** in pmV, so nothing is claimed between them):

| case | pmV | EntryPoint verdict | SP frame error | token call |
|---|---|---|---|---|
| B1 | 436,440 | `AA36 over paymasterVerificationGasLimit` | none | `tryLockForGas` OOG |
| B1 | 436,441 | `AA34 signature error` (sigFail) | none | `tryLockForGas` OOG |
| B1 | 497,292 | `AA34 signature error` (sigFail) | none | `tryLockForGas` OOG |
| B1 | 882,374 | `AA36 over paymasterVerificationGasLimit` | none | ok |
| B1 | 882,375 | ok | none | ok |
| B5 | 436,440 / 436,441 | AA36 / AA34 | none | OOG ("not enough gas for reentrancy sentry") |
| B5 | 998,873 / 998,874 | AA36 / ok | none | ok |
| B7 | 717,083 / 717,084 | AA36 / ok | none | ok |

So a sigFail (AA34) band exists where the token call runs out of gas, and the success threshold is a separate, higher AA36→ok boundary.
**Correction:** `explain.json`'s `b6` rows (pmV 882,375 / 436,441, and the 497,292 trace) were generated by a script version that omitted
`flags: FLAG_ACCOUNT_RENEW, accountRenew: true`, i.e. they are a B1-shaped op from the B6 account, **not B6**. They are not used as B6 evidence;
the real B6 needs are the matrix values (870,575 in (a)). `ams-explain.mjs` now builds B6 with the case's flags; it was **not re-run** in this pass.

*Inferred, not shown.* That Alto's estimator converged on 497,292 **because** of this fail-closed sigFail is an inference. Alto binary-searches the
paymaster verification gas in its simulation contract and treats a simulation that does not revert as success (`EntryPointSimulations.sol` 192–255 at
`45bbf341`); a sigFail does not revert, so such a search can stop in the band where the token call OOGs. But this run has **no trace of Alto's own
search**, and the emulation does not reproduce Alto's numbers: it gives 436,441, not 497,292 (Alto applies its own multipliers/rounding, not
re-derived here), it gives 717,084 for B7 where Alto returned 516,336 (pm omitted, (b)), and it does not explain B5, where Alto returned 1,306,619,
which executes. A paymaster sigFail and an invalid *account* signature are separate signals (`validationData` of the paymaster vs of the
account), so the account signature used during estimation is not part of this explanation (the claim to the contrary in c3eb1011 is withdrawn).

**Excluded alternatives** (`reservoir/`, from c3eb1011, not re-run): (i) the EIP-8037 state-gas reservoir — min needs are identical at tx gas 8M,
16M, 16,777,216, 17M, 20M, 30M and 60M, and replaying Alto's estimation `eth_call`s with no gas / 16M / cap / 30M / 60M gives byte-identical results
(`reservoir/alto-estimate-ethcall-replay.json`); (ii) the simulation fee — for B1 and B5 the minima are identical at 1 wei, 1 kwei, 1 mwei, 0.1 gwei,
1 gwei and 3 gwei. **Exception: `reservoir.json` records B7 at 3 gwei failing its generous baseline with `AA34` and no minima.** Investigated in
`explain/explain.json`: the probe's generous op (v 1.5M + call 0.5M + pmV 2M + pmP 1.5M + PVG 0.1M) at 3 gwei reserves a0 = **2,016 aPNTs**,
above B7's effective credit cap of **1,000 aPNTs**, so the token refuses the credit, SP returns MODE_NONE → sigFail → AA34. It is a property of
the probe's oversized baseline, not of the fee. With a smaller baseline at 3 gwei (v 300k, call 100k, pmV 1.0M, pmP 500k → a0 720 aPNTs < cap)
the B7 minima are v 124,346 / call 3,696 / pmV 717,084 / pmP 269,585 — identical to every other fee. So the needs are fee-invariant from 1 wei to
3 gwei for B1 and B5 directly, and for B7 once the probe op fits under its credit cap.

### 6.2 Simulation passes but on-chain execution fails

- **Rundler B2b, (b) and (c)**: all 3 ops accepted on submit, then the bundle is dropped (`AA34` on op 3 at bundle-time estimation) and the SP
  removed/banned (F1). No tx was sent; nothing reverted on chain.
- **Alto and altoMulti B6, (c)**: accepted on submit with v 150,000, then the bundle's `eth_estimateGas` fails with `FailedOp(0,"AA26 over
  verificationGasLimit")` and the op is not included; no tx was sent (`c/alto-bundler.log`, `c/alto-errors.log`). Rundler rejects the same op on
  submit. Why Alto's validation simulation admits a v that handleOps rejects was not determined.
- Otherwise **none**. Every op included in (b), (c), (c′) has `success = true` and no `PostOpRevertReason`; no bundle tx reverted.

### 6.3 Other findings

- **AMS-1 (high): SP's validation gas roughly quadruples on Amsterdam.** pmV need 588,606–998,874 across (a)–(c) (Osaka frame 198k–238k), v with initCode 3.89–3.98M
  (Osaka factory phase 532k), postOp 288k at SETTLE 160k. Defaults (a) let **no** op through; PRELIMINARY (b) lets only CREDIT and post-first-op
  BALANCE through. The **calibrated (c)** pmV 1.15M / pmP 440k / MIN 440k / SETTLE 420k cover the paymaster-side gas of every case measured: no included op
  failed on gas and every included op's postOp settled. Not every gas-sufficient op was included: Rundler B2b (F1, bundle dropped) and Alto
  B3 #2/#3 (D2, rejected on submit) are rule/bundler outcomes, not gas.
- **AMS-2 (high, carries Osaka F1): F1 reproduces on Amsterdam** in (b), (c) and (c′): Rundler B2b drops the bundle and removes the SP; the next
  normal op gets `-32504 throttled or banned`.
- **AMS-3 (medium): estimates cannot be used as-is (F2).** Rundler never returns `paymasterPostOpGasLimit`, and with pm gas omitted estimates pmV
  ≈ 61k. Alto's pmV is below the need except for B5, its pm-omitted pmP is below MIN, and its estimator throws after the first included op (AMS-4).
  The SDK must supply pmV and pmP itself (≥ the G-layer values) and must not take Alto's pmV.
- **AMS-4 (medium, Alto defect): Alto v1.2.5's `eth_estimateUserOperationGas` throws** `Hex size (33) exceeds padding size (16)` (viem 2.24.3,
  no RPC code) for **every** estimate after the first included op: 25 in `b/alto-errors.log`, 41 in `c/alto-errors.log`. Root cause not determined.
  Submission and bundling are unaffected.
- **AMS-5 (low, Rundler diagnostics):** Rundler v0.11.0 reports AA36 / AA13 / AA26 as `-32603 Failed to decode validation output 0x…` and an
  in-validation OOG (AA33) as `-32500 validation reverted:` with empty data. Not re-run on Osaka with this build, so not established as
  Amsterdam-specific.
- **AMS-6 (info, deployment): 6 of 55 B-layer deploy txs exceed the EIP-7825 per-tx cap** (16,777,216) and fit only through the EIP-8037 reservoir.
  From `{a,b,c}/deploy-receipts.json` (identical in all three): SuperPaymaster impl **52,389,391**; `xPNTsFactory` 36,864,464; `Registry`
  36,585,825; `xPNTsTokenV2Ext` 34,382,101; `xPNTsTokenV2` 31,294,520; `MySBT` 19,700,047 (forge's broadcast record names the two
  `compilation_restrictions` artifacts `xPNTsFactory.registry-size` / `MySBT.registry-size`). All 55 `status 1`. `deploy-core` on an Amsterdam
  chain needs `--skip-simulation` (or an Amsterdam-aware forge) and a block gas limit ≥ ~53M.
- **AMS-7 (medium, new in c): the calibrated v 150,000 is too low for B6 (option A, account calls `renewForSelf` in `validateUserOp`).** Need
  150,839 (account frame 33,343). Rundler rejects it (AA26); Alto accepts it and then cannot bundle it (§6.2). Ordinary ops need 124,346, so 150k
  is enough for them; an account that renews in its own frame needs ≥ ~174k (+15 %).
- **AMS-8 (medium, new in c): Rundler's default `max_verification_gas` (5,000,000) rejects every initCode op with v 4.6M + pmV 1.15M = 5.75M**
  at precheck (`-32000 precheck failed: verificationGasLimit is 5750000 but must be at most 5000000`) — Rundler compares the sum. The measured need is
  v 3.89–3.98M + pmV 0.78–0.88M ≈ 4.67–4.87M, so under Rundler's default cap only ~3–7 % of total margin would remain; with the calibrated
  values a bundler must be configured with `max_verification_gas` ≥ 5.75M (the value to choose is left to the G layer / runbook). With 6M (§5.5) every B4 case behaves as on Osaka.

### 6.4 State-dependence of SP's validation gas

The second op of the same sender in the same bundle uses 688,445 (b) / 692,445 (c) gas vs 1,153,019 / 1,157,019 for the first (B2a, Rundler, one
tx); in Alto's separate txs 956,865 (b) / 960,865 (c). The first op ever through a fresh SP needs +98k pmV (882,366 vs 784,446); SP_RENEW after the
first op needs 900,945 vs 998,874 fresh; a sender's second op needs pmV 588,606. All follow from EIP-8037 pricing zero→nonzero writes at ~100k. A
fixed pmV must cover the coldest path (fresh SP + SP_RENEW, 998,874).

### 6.5 §3.4 access check on the Amsterdam traces

`access-check.mjs` on our tracer's output for every captured simulation (`*/access-check.txt`, header line per file):

| run | captured | checked | skipped (no account phase) | OUTSIDE / FORBIDDEN |
|---|---|---|---|---|
| (a) | 60 (20 per bundler) | **48** | 12 — the 4 B4 traces per bundler, where the factory runs out of gas inside `createSender` so no account phase exists | 0 / 0 |
| (b) | 80 (26 / 27 / 27) | **68** | 12 — the same B4 traces | 0 / 0 |
| (c) | 100 (28 / 36 / 36) | **100** | 0 (B4 reaches the account phase) | 0 / 0 |
| (c′) | 33 | **33** | 0 | 0 / 0 |

The skipped factory phases are **not** covered by this check in (a) and (b). In (c) and (c′) every simulation, including the B4 factory phases, is
checked. Access sets of ops that ran to completion are identical to Osaka: B1-type R1 6 / R2 19 / R3 2, B5 R2 23, B6 R4 8, B7 R1 13 / R2 20 / reg
2 + 12, B4-ok factoryOwn 2. In ops cut short by OOG: **(a) R2 12–14 and R3 = 0** (pmV 300k stops before the token's TSTOREs); (b) R2 19 and R3 = 1
(only the first TSTORE before the OOG). B8 OP-070: both bundlers' tracers again record the two TSTOREs as `writes` (`{b,c}/b8-op070.json`).

## 7. Differences vs the recorded Osaka results (README.md, B1-B10.md)

| # | item | Osaka (anvil 1.7.1, `--hardfork osaka`) | Amsterdam (a) / (b) | Amsterdam (c) CALIBRATED (+ c′) |
|---|---|---|---|---|
| X1 | B0 at pm verif 100k | 4/4 violators rejected **by rule** | 2/4 (STO-031, STO-021) rejected by **OOG**; by rule only at 400k | (B0 is independent of the variant) |
| X2 | B9-below (SP 0.1 ETH) | Rundler `-32502 entity stake/unstake delay too low`, needsStake paymaster, slot 0xf; Alto accepts (D1) | never reached (gas) | **same as Osaka** on Rundler and Alto |
| X3 | B9-above, B1, B3, B5, B6 | included (B3: Alto D2) | rejected (gas) | B9-above, B1, B3, B5 **as Osaka** (D2 reproduces); **B6 fails** (AMS-7) |
| X4 | B7, B8 | included | (a) rejected; (b) included | included |
| X5 | B4 (factory stake) | Rundler rejects ×3 by stake; Alto rejects only unstaked (D1); ok included | all four `AA13` (v 1.2M) | Alto **as Osaka**; Rundler precheck at default cap (AMS-8), **as Osaka with cap 6M** |
| X6 | B2a | Rundler 1 tx; Alto 2 txs (D3); altoMulti 1 tx | (a) rejected; (b) as Osaka | as Osaka |
| X7 | B2b / F1 | Rundler bans SP; Alto rejects op 3 | (a) rejected; (b) as Osaka | as Osaka (F1) |
| X8 | B10 Rundler | no pmP; omitted pmV 38,403; supplied echoed | no pmP; omitted 60,857–60,859; (a) error AA36; (b) echoed 820k | no pmP; echoed 1.15M; omitted 60,857 |
| X9 | B10 Alto | supplied 200k → pmP 240,000, pmV 287,821; omitted pmP 114,560 | (a) pmP 240,000 (< 288,276), pmV 497,292 (< 882k), omitted pmP 137,851; (b) throws | throws (AMS-4) |
| X10 | SP validation gas | 198k–238k | 698k–981k frame, 717k–999k need | pmV need 588,606 (repeated sender) – 900,945 (B5); fresh-SP first op 882,366 |
| X11 | account validation / factory | 6,850 (B6 32,443) / factory 531,693 | 6,850 (B6 33,343) / createSender 3,756,559 (ok) – 3,854,479 (others) | same |
| X12 | Rundler OOG messages | `Simulation ran out of gas for entity: factory` | `-32603 Failed to decode validation output …` (AMS-5) | same, also for AA26 |
| X13 | §3.4 | 0 / 0 (34 + 36 + 36 sims) | 0 / 0 on 48 of 60 (a), 68 of 80 (b) | 0 / 0 on 100 of 100 (+ 33 of 33) |
| X14 | deployment | 30M default block limit | needs ≥ ~53M block limit, `--skip-simulation` (AMS-6) | same |

## 8. Not run / limits

- **geth `--dev` cross-check on Amsterdam was not run** (optional; anvil nightly is the engine calibrated against live Sepolia).
- The `reservoir/` sweep is from c3eb1011 and was not re-run; this pass added the B7 3-gwei explanation in `explain/`.
- The attribution of Alto's 497,292 to the fail-closed sigFail is an inference (§6.1); Alto's own search was not traced.
- AMS-4 (Alto throw), AMS-5 (Rundler message), and why Alto's simulation admits B6 at v 150k (§6.2): root causes not determined.
- B6 and B4 were not re-run with a larger v or a tighter v + pmV; (c) uses exactly the task's values, (c′) changes only the Rundler cap.
- Sepolia's block gas limit (60M) was taken from memory, not read live. The calibration does not depend on it.

## 9. Files

| path | content |
|---|---|
| `script/b-layer/ams-calibrate.mjs` | step-0 gate |
| `script/b-layer/ams-b0-run.sh` | B0 on Amsterdam (both bundlers, unsafe control), keeps bundler / send / setup logs |
| `script/b-layer/ams-g1-run.sh`, `ams-g1-deploy.sh`, `ams-gasparams.mjs`, `ams-g1-collect.sh`, `ams-receipts.mjs` | G1 runner (variants a/b/c, supplementary options), deploy, governance step, receipts, collection |
| `script/b-layer/ams-probe.mjs`, `ams-report.mjs`, `ams-reservoir.mjs`, `ams-explain.mjs` | per-op estimate / need / complete-estimate replay, matrix, tx-gas & fee sweep, §6.1 investigation |
| `script/b-layer/{lib,g1-lib,g1-cases,b0-send,access-check}.mjs` | adapted as AD-4 … AD-7, AD-11 (defaults reproduce the Osaka run) |
| `amsterdam/b0/` | B0 verdicts (6 configurations) + `b0-<config>-{bundler,send,setup}.log` |
| `amsterdam/{a,b,c}/`, `amsterdam/c-rundler-mvg6m/` | `deploy.json`, `deploy.log`, `deploy-receipts.json`, `receipts.log`, `setup.{json,log}`, `gasparams.{json,log}` (b, c), `calibration.json`, `versions.txt`, `<bundler>-results.json`, `<bundler>-cases.log`, `<bundler>-bundler.log`, `<bundler>-traces.jsonl.gz`, `<bundler>-bundler-tracer-*.js`, `rundler-events.log`, `alto*-errors.log`, `access-check.{json,txt}`, `b8-op070.json`, `matrix.{md,json}` |
| `amsterdam/explain/` | `explain.{json,log}` (pmV trace at 497,292, Alto-style search, B7 at 3 gwei), its `deploy.{json,log}`, `setup.{json,log}` |
| `amsterdam/reservoir/` | `reservoir.json` (needs vs tx gas and vs fee), `alto-estimate-ethcall-replay.json` (from c3eb1011) |
