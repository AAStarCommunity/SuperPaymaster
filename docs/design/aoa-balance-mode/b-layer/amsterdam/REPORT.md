# R-AMS-2 (B layer) — bundler acceptance on an Amsterdam-level chain

DSR CC-125 `d13dd9eb`, task R-AMS-2 (B layer), spec `03-final-spec.md` §10.8b. Date of run: 2026-10-22.
Everything ran on local anvil only, with anvil's public dev keys only. No public-chain RPC was used and no
transaction was sent anywhere else. `contracts/src`, `contracts/script`, `foundry.toml` and `.github` are untouched.

**Variant (b) is PRELIMINARY.** Its gas parameters (SETTLE_GAS_BOUND 380000, MIN_POST_OP_GAS 400000,
C_POSTOP_GAS 340000, paymasterVerificationGasLimit 820000) come from the earlier, uncalibrated sweep. The
definitive values come from the parallel calibrated G-layer run (branch `cc125/rams-2a-glayer`).

## 0. Calibration gate (step 0): PASS

`/tmp/fd/nightly/anvil --hardfork amsterdam`, minimum gas at which `eth_call` from anvil account 0 succeeds
(binary search, lower bound 0). Script: `script/b-layer/ams-calibrate.mjs`. The gate was re-run at the start of
every G1 run (`a/calibration.json`, `b/calibration.json`), and also at `--gas-limit 60000000` and `100000000`.
The values are identical in every case.

| probe | live Sepolia (Amsterdam) | anvil 1.8.7-nightly `926eb1d0` | match |
|---|---|---|---|
| create `0x00` | 207,606 | 207,606 | ✅ |
| create `0x6101006000f3` | 599,432 | 599,432 | ✅ |
| create `0x600160005500` | 317,700 | 317,700 | ✅ |
| create `0x6001600055600260005500` | 320,075 | 320,075 | ✅ |
| 1 wei to fresh `0xa3a3…a3` | 204,600 | 204,600 | ✅ |

`eth_estimateGas` returns the same five numbers.

## 1. Versions and commits

| component | version / commit | how obtained |
|---|---|---|
| SuperPaymaster | branch `cc125/rams-2b-blayer` from `origin/main`; submodules `--init --recursive` | — |
| chain engine | foundry **nightly `926eb1d087523f1de437e3c0c49ea6d26407e827`**, `anvil 1.8.7-nightly` (build timestamp 2026-10-22T06:24:10Z) | `foundry_nightly_linux_amd64.tar.gz`, sha256 `df74eb56…c22a6a1`, which equals the release's `foundry_nightly_linux_amd64.sha256`. The asset name the task gives (`…tar.gz.sha256`) is 404; this is the release's actual checksum asset |
| contract build | **forge 1.7.1** (`foundry_v1.7.1_linux_amd64.tar.gz`, sha256 `cf7e688e…31060b67ac5afe1e43dbb5499c20c88b`, equals the release `.sha256`), `forge build` = `[profile.default]` as `deploy-core` does | — |
| solc | 0.8.33 (repo), 0.8.28 (Alto), 0.8.26 (Rundler) | `binaries.soliditylang.org` is blocked by the egress proxy, so these are the official `solc-static-linux` assets from `github.com/ethereum/solidity/releases` placed in `~/.svm/<v>/` |
| Rundler (primary) | **v0.11.0, `2a3db23724bc995e3d7fcf7ee270fa2b759612aa`** | `cargo build --release --bin rundler`, toolchain 1.92.0 (pinned by `rust-toolchain.toml`), protoc 29.3 (official release zip, sha256 `3e866620…333e90021a`, linux-x86_64; README §3's `2b8a3403…` is a different platform's zip), forge 1.7.1 on PATH |
| Alto (cross-check) | **v1.2.5, `45bbf3410ac3d91b38392bbe81a720fcdfef3ac5`** (`git describe` = `v1.2.5`) | pnpm 8.15.4 (the repo's `packageManager`), `pnpm install --frozen-lockfile && pnpm run build:contracts && pnpm run build` |
| node / viem (harness) | node 22.22.0, viem 2.52.2 (`pnpm install --frozen-lockfile` at the repo root) | — |

## 2. Exact commands

```
# B0 (fresh anvil per configuration; pm verification gas 100000 = recorded value, 400000 = raised)
script/b-layer/ams-b0-run.sh /tmp/bl/b0 /tmp/bl/rundler /tmp/bl/alto docs/design/aoa-balance-mode/b-layer/amsterdam/b0 100000 400000

# G1 B1–B10, variant (a) current defaults, variant (b) PRELIMINARY candidates
script/b-layer/ams-g1-run.sh /tmp/bl/g1a /tmp/bl/rundler /tmp/bl/alto a
script/b-layer/ams-g1-run.sh /tmp/bl/g1b /tmp/bl/rundler /tmp/bl/alto b
G1_DEPLOY_JSON=docs/design/aoa-balance-mode/b-layer/amsterdam/a/deploy.json script/b-layer/ams-g1-collect.sh /tmp/bl/g1a a
G1_DEPLOY_JSON=docs/design/aoa-balance-mode/b-layer/amsterdam/b/deploy.json script/b-layer/ams-g1-collect.sh /tmp/bl/g1b b

# estimator investigation (fresh anvil + variant-a stack, read-only debug_traceCall)
script/b-layer/ams-g1-deploy.sh http://127.0.0.1:18645 docs/…/amsterdam/reservoir/deploy.json <log>
G1_DEPLOY_JSON=docs/…/amsterdam/reservoir/deploy.json node script/b-layer/g1-setup.mjs http://127.0.0.1:18645 docs/…/amsterdam/reservoir/setup.json
G1_DEPLOY_JSON=docs/…/amsterdam/reservoir/deploy.json node script/b-layer/ams-reservoir.mjs docs/…/amsterdam/reservoir/setup.json docs/…/amsterdam/reservoir/reservoir.json b1 b5 b7
```

Inside `ams-g1-run.sh` the commands are those of `g1-run.sh` (B1-B10.md §1) with these changes:

```
/tmp/fd/nightly/anvil --port 18645 --chain-id 31337 --hardfork amsterdam --gas-limit 60000000
node script/b-layer/ams-calibrate.mjs http://127.0.0.1:18645 <work>/calibration.json
script/b-layer/ams-g1-deploy.sh …            # = g1-deploy.sh + forge script --skip-simulation --gas-estimate-multiplier 110
node script/b-layer/ams-gasparams.mjs …      # variant b only: queueGasParams(400000,380000,5000,340000) → warp 48h+60s → executeGasParams
G1_ESTIMATE=1 [G1_GAS_JSON=… G1_MIN_POST_OP_GAS=400000] node script/b-layer/g1-cases.mjs …
```

Rundler and Alto start exactly as in `g1-run.sh`: Rundler with `--chain_spec docs/…/b-layer/rundler-chain-31337.toml`. Alto runs
as `alto` (defaults) and as `altoMulti` (`--min-entity-stake 1e18 --min-entity-unstake-delay 86400
--enforce-unique-senders-per-bundle false`), `--safe-mode true`, manual bundling.

## 3. Adaptations (every change vs the Osaka scripts)

| # | what | why |
|---|---|---|
| AD-1 | anvil = nightly `926eb1d0`, `--hardfork amsterdam` (was anvil 1.7.1 `--hardfork osaka`) | the task; the only engine that matches live Sepolia Amsterdam gas (§0) |
| AD-2 | anvil `--gas-limit 60000000` (was the 30M default) | Under EIP-8037 a 24 KB contract CREATE costs ~37.8M and the SuperPaymaster impl CREATE uses 52.4M, so the 30M default cannot deploy the stack. 60M is Sepolia's block gas limit (taken from memory, not re-read, since public RPC is not allowed). The calibration values do not depend on it (§0). Rundler's chain spec still says `block_gas_limit = 30000000` (unchanged file); bundles here are ≤ 3.4M |
| AD-3 | `ams-g1-deploy.sh` = `g1-deploy.sh` + `forge script --skip-simulation --gas-estimate-multiplier 110` | forge 1.7.1 simulates with its own pre-Amsterdam EVM: the first CREATE was sent with gas 109,354 and failed (tx `0xd1569571…`). With `--skip-simulation` every tx gets its limit from the Amsterdam node's `eth_estimateGas`; ×1.3 would put the SP CREATE at 68M > 60M. Same 55 transactions, all `status 1` |
| AD-4 | `lib.mjs` `artifact()`: if `out/<file>/<name>.json` is missing, take `<name>.default.json` | forge 1.7.1 writes `SimpleAccountFactory.default.json` + `.registry-size.json` (compilation_restrictions), so b0-setup could not find the artifact. It selects the profile.default artifact, which is the one that ships |
| AD-5 | B0 on chain 31337 for both bundlers (Rundler via `rundler-chain-31337.toml`, as G1 already does), one fresh anvil per configuration; `b0-send.mjs` reads `B0_PM_VGL` (default 100000 = recorded) | README §3 used Rundler `--network dev` on chain 1337. The toml is the dev spec with id 31337. Second B0 value 400000: see §4 |
| AD-6 | `g1-lib.mjs`: `G1_GAS_JSON` / `G1_MIN_POST_OP_GAS` override the fixed op gas; `buildG1Op` accepts `gasOverride` and returns its `params` | variant (b) op gas, and the probe rebuilds ops with other gas. Defaults unchanged |
| AD-7 | `g1-cases.mjs`: with `G1_ESTIMATE=1`, `submit()` first runs `ams-probe.mjs`; `outcome()` also reads the bundle tx and the EntryPoint events back from the chain (`onchain`) | step 3 of the task (estimates, needs, actual gas, postOp outcome). Probe traffic goes straight to anvil (not through the trace proxy) except the two `eth_estimateUserOperationGas` calls, which go to the bundler under test |
| AD-8 | variant (b): GasParams via the owner's governance path `queueGasParams` → `evm_increaseTime` 48 h + 60 s → `executeGasParams`, read back (`b/gasparams.json`); op gas `pmVerificationGasLimit 820000`, `pmPostOpGasLimit 400000` (= new MIN_POST_OP_GAS; the op must carry ≥ MIN, the task gives no separate postOp limit) | the task. cWrap kept at its default 5000. Every other op field unchanged (verif 250k, verif with initCode 1.2M, call 60k, PVG 100k, 3 gwei / 2 gwei) |
| AD-9 | evidence goes to `amsterdam/{b0,a,b,reservoir}/`. `*-results.json` are no longer gzipped because they are < 5 MB; traces stay `.jsonl.gz` | — |

**Probe method (`ams-probe.mjs`), per op, immediately before it is submitted:**
(1) `eth_estimateUserOperationGas` from the bundler under test in two shapes: *pm supplied* (the case's paymaster gas fields) and *pm omitted*
(both omitted). call/verification/PVG are always omitted.
(2) **min need**: the smallest value of each executable field at which `EntryPoint.handleOps([op])` fully succeeds (no FailedOp,
`UserOperationEvent.success`, no `PostOpRevertReason`), the other fields held generous. This is a binary search with `debug_traceCall`
(callTracer + logs), tx gas 16,000,000, fee 0.1 gwei. §6.3 shows that neither tx gas nor fee changes the result.
(3) **does the estimate execute**: the op rebuilt with each estimate at its real fees, then the same handleOps check. Where Rundler returns no postOp field,
the supplied value is used (pm supplied) or 0, which is Rundler's own default (pm omitted).
(4) the op as submitted through handleOps.

## 4. B0 — bundler rule checks on Amsterdam (`b0/*.json`)

| configuration | pm verif gas | control | op011 TIMESTAMP | sto031 unstaked own storage | op070 unstaked TSTORE | sto021 staked external write | verdict |
|---|---|---|---|---|---|---|---|
| Rundler v0.11.0 | 100,000 | included | `-32502 paymaster uses banned opcode: TIMESTAMP` | `-32500 validation reverted:` (**OOG**) | `-32502 entity stake/unstake delay too low` | `-32500 validation reverted:` (**OOG**) | rejections match, but 2 of 4 are from OOG, not from a rule |
| Alto v1.2.5 safe | 100,000 | included | `-32502 banned opcode: TIMESTAMP` | `-32500 AA33 reverted - 0x` (**OOG**) | `-32502 unstaked paymaster accessed paymaster slot 0x0` | `-32500 AA33 reverted - 0x` (**OOG**) | same |
| Alto v1.2.5 unsafe | 100,000 | included | included | `AA33 reverted` | included | `AA33 reverted` | the 2 storage writers cannot even execute at 100k |
| **Rundler v0.11.0** | **400,000** | included | `-32502 …banned opcode: TIMESTAMP` | `-32502 entity stake/unstake delay too low` | `-32502 entity stake/unstake delay too low` | `-32502 paymaster accesses inaccessible storage at address … slot …` | **PASS (by rule)** |
| **Alto v1.2.5 safe** | **400,000** | included | `-32502 banned opcode: TIMESTAMP` | `-32502 unstaked paymaster accessed paymaster slot 0x0` | `-32502 unstaked paymaster accessed paymaster slot 0x0` | `-32502 paymaster has forbidden read from … slot …` | **PASS (by rule)** |
| Alto v1.2.5 unsafe | 400,000 | included | included | included | included | included | negative control: all 4 violators are valid, executable ops |

**B0 holds on Amsterdam, but only at 400k.** At the recorded 100,000 gas, the two storage-writing violators run out
of gas in the paymaster frame, because one zero→nonzero SSTORE now costs ~110k (calibration probe 3 minus probe 1). So the rejection no longer
shows that the rule is enforced. This is exactly the effect that README §2 finding 2 saw on geth's `bogota`. With 400k, both bundlers reject
all four by the rules and accept the control, and unsafe Alto includes all four.

## 5. G1 B1–B10 result matrices

Complete per-op tables, with the exact bundler error, both estimates and whether each executes, the min need, the on-chain result and flags:
**[`a/matrix.md`](a/matrix.md)**, **[`b/matrix.md`](b/matrix.md)**. Machine-readable copies are `*/matrix.json`, and the raw bundler
responses are `*/<bundler>-results.json`. The tables below condense them. Notation: v = verificationGasLimit, pmV =
paymasterVerificationGasLimit, pmP = paymasterPostOpGasLimit.

### 5.1 Minimum gas each op needs on Amsterdam (both variants, same stack)

| case | v need | pmV need | pmP need (a: SETTLE 160k) | pmP need (b: SETTLE 380k) | Osaka SP validation frame (B1-B10.md §2) | Amsterdam SP validation frame gasUsed |
|---|---|---|---|---|---|---|
| B1 / B3 / B9 (first ops through a fresh SP) | 124,346 | **882,375** | **288,276** | 400,000 (= MIN floor) | 209,036 | 864,025 |
| B8, B2a/b, aftermath (after the SP's first included op) | 124,346 | **784,446** | — | 400,000 | — | — |
| B5 SP_RENEW | 124,346 | **998,874** | 288,276 | 400,000 | 237,515 | 980,524 |
| B6 account renew | **150,839** | **870,575** | 288,276 | 400,000 | 198,036 | 852,225 |
| B7 CREDIT | 124,346 | **717,084** | 269,585 | 400,000 | 218,543 | 698,734 |
| B4 initCode (factory CREATE2) | **3,885,095 – 3,983,015** | 882,420 (a) / 784,491 (b) | 288,276 | 400,000 | factory phase 531,693 | createSender 3,756,559 |

callGasLimit need is 3,696 everywhere. The +98k for "first op through a fresh SP" is one-time: B8 in (b), which comes right after the first
included op (B7), needs 784k. In (a) nothing is ever included, so every case needs 882k.

### 5.2 Variant (a): current defaults (op: v 250k, v+initCode 1.2M, pmV **300k**, pmP **250k**; SP GasParams 200k/160k/5k/175k)

| case | Rundler v0.11.0 | Alto v1.2.5 | altoMulti | on chain |
|---|---|---|---|---|
| B9-below, B9-above, B1, B3 (×3), B5, B6, B7, B8, B2a (×2), B2b (×3), B2-aftermath | reject `-32603 Failed to decode validation output 0x…` (the op is `AA36 over paymasterVerificationGasLimit` in handleOps) | reject `-32500 AA36 over paymasterVerificationGasLimit` | same as Alto | nothing included |
| B4 ×4 (unstaked / 0.5 ETH / 3600 s / ok) | reject `-32603 Failed to decode validation output 0x00…00` (`AA13 initCode failed or OOG`) | reject `-32500 AA13 initCode failed or OOG` | same | nothing included |
| B10 | pm supplied: `-32500 validation reverted: [reason]: AA36 over paymasterVerificationGasLimit`; pm omitted: pmV 60,859, **no pmP field** | supplied 200k: pmV 497,292 / **pmP 240,000**; omitted: pmV 497,292 / **pmP 137,851** | same | — |

**(a) fails on Amsterdam: 0 of 20 ops per bundler (60 submissions) are included.** Every rejection is gas, not a rule (`OUTSIDE 0 / FORBIDDEN 0`, §6.5).
pmV 300k is ~2.9× too low. Even with enough pmV, pmP 250k is below the 288,276 needed: postOp would revert at the `SETTLE_GAS_BOUND`
guard. v+initCode 1.2M is ~3.3× too low. The stake checks (B9-below, B4-unstaked/lowStake/shortDelay) could not be exercised at all,
because gas fails first.

### 5.3 Variant (b): PRELIMINARY candidates (op pmV **820k**, pmP **400k**; SP GasParams MIN 400k / SETTLE 380k / cWrap 5k / C_POSTOP 340k)

| case | pmV need vs 820k | Rundler v0.11.0 | Alto v1.2.5 | altoMulti | on chain (UserOperationEvent success, actualGasUsed, postOp) |
|---|---|---|---|---|---|
| B9-below / B9-above | 882k > 820k | reject `-32500 validation reverted:` (handleOps: `AA33 reverted`) | reject `-32500 AA33 reverted - 0x` | same | not included. The stake check is masked by OOG |
| B1 | 882k > 820k | reject (same) | reject (same) | same | not included |
| B3 (3 senders) | 882k > 820k | 3× reject | 3× reject | 3× reject | not included |
| B5 SP_RENEW | 999k > 820k | reject | reject | reject | not included |
| B6 account renew | 871k > 820k | reject | reject | reject | not included |
| **B7 CREDIT** | 717k ✓ | **included** | **included** | **included** | ✅ success, 1,157,426 gas, 2.3149e15 wei, postOp ok, `debts 0 → 294.06` |
| **B8 TSTORE** | 784k ✓ | **included** | **included** | **included** | ✅ success, 1,152,705 gas, 2.3054e15 wei, postOp ok |
| B4 ×4 | v need 3.9–4.0M > 1.2M | reject `-32603 Failed to decode validation output 0x00…00` (AA13) | reject `-32500 AA13 initCode failed or OOG` | same | not included. The factory stake checks are masked by OOG |
| B10 | — | pm supplied: pmV echoed **820,000**, no pmP; pm omitted: pmV 60,857 | **all 3 shapes: `Hex size (33) exceeds padding size (16)` (viem 2.24.3 inside Alto)** | same | — |
| **B2a** (same sender, 2 ops) | 784k ✓ | ✅ 1 tx, both included (1,153,019 + 688,445 gas) | ✅ both included in **2 txs** (D3, default unique-sender) | ✅ 1 tx | success, postOp ok |
| **B2b** (same sender, 3 ops, balance 2.5·x0) | 784k ✓ | ❌ **all 3 accepted, none included**: `FailedOp(2,"AA34 signature error")` at bundle time → `Empty bundle with 3 rejected ops and 1 rejected entities` → `Removed entity from pool: paymaster`; SP reputation `opsSeen 0x2710, status 2 (BANNED)` | ✅ ops 1–2 included, op 3 rejected on submit `-32500 AA34 signature error` | ✅ same as Alto | — |
| B2-aftermath | 784k ✓ | reject `-32504 paymaster 0x0b30… throttled or banned` | ✅ included (1,152,705 gas) | ✅ included | — |

Accepted/included per bundler in (b): Rundler 4 included + 3 accepted-not-included (B2b); Alto and altoMulti 7 included each. Bundle txs (b): Rundler gasLimit 1,673,330–3,324,648, Alto 1,596,016–3,179,021. gasUsed is always below the limit. **No bundle tx
reverted and no op failed on chain (OOG / AA33 / AA50 / postOp revert = 0).** No `PostOpRevertReason` anywhere.

## 6. Flags (task step 3)

### 6.1 Bundler estimate lower than what the op needs on Amsterdam

| bundler | shape | estimate | need | executes with the estimate? | cases |
|---|---|---|---|---|---|
| **Alto v1.2.5** | pm supplied | **pmV 497,292** | 882,375 (B1), 870,575 (B6) | ❌ `AA34 signature error` | (a) and (b): B9, B1, B3, B6, B8, B2*, B4* (where the estimate succeeded) |
| Alto v1.2.5 | pm supplied, (a) | pmP 240,000 (supplied 200k × 1.2) | 288,276 | — (would revert in postOp) | (a) B10 / all |
| **Alto v1.2.5** | pm omitted | **pmP 137,851** | ≥ MIN (200k in a, 400k in b), and 288,276 | ❌ `AA34` (below MIN → SP sigFail) | all cases, (a) and (b) |
| Alto v1.2.5 | pm omitted, B7 | pmV 516,336, pmP 243,585 | 717,084 / 400,000 | ❌ AA34 | (b) B7 |
| **Rundler v0.11.0** | pm omitted | **pmV 60,857–62,840, no pmP** | 717k–999k | ❌ `AA34` (postOp 0 → SP sigFail early, F2) | all cases |
| Rundler v0.11.0 | pm supplied | echoes the supplied pmV (820,000) | — | ✅ when 820k ≥ need (B7, B8, B2, B4); when it is not, estimation **errors** with `AA33`/`AA36`, which is correct | (b) |
| Rundler / Alto | v, call | Rundler v 145,426–155,029 (B4: 4.49–4.73M); Alto v 164,041 (B4: 5.06–5.18M); call 9,100 / 16,323 | v 124,346–150,839 (B4 3.89–3.98M); call 3,696 | ✅ not low | — |

**Why Alto's pmV is low (established in this run).** Alto's estimator binary-searches
`binarySearchPaymasterVerificationGasLimit` and treats "the simulated call did not revert" as success (`EntryPointSimulations.sol` 192–255 at
`45bbf341`). SP's validation-time token call fails closed: `_reserveForOp` → `_tokenWord` (`SuperPaymaster.sol` 346–372) turns
*any* token-call failure, **including out-of-gas**, into `MODE_NONE` → paymaster sigFail, with no revert. The search therefore converges on the gas
where `tryLockForGas` runs out and SP returns sigFail (497,292 after Alto's own multipliers). The account's signature is also
invalid during estimation, so a sigFail is not a usable failure signal. The resulting op fails with `AA34`, which matches the
"does it execute" column exactly. On Osaka, Alto's estimate (287,821) exceeded the measured ~209k, so the effect, if present, did not matter. On
Amsterdam, the token call's zero→nonzero SSTOREs (~95–110k each) are most of the paymaster's gas. **Two alternative explanations were tested and
excluded** (`reservoir/`): (i) the EIP-8037 state-gas reservoir. Min needs are identical at tx gas 8M, 16M, 16,777,216, 17M, 20M, 30M and 60M,
and replaying Alto's own estimation `eth_call`s with no gas / 16M / cap / 30M / 60M gives byte-identical results
(`reservoir/alto-estimate-ethcall-replay.json`). (ii) Alto's 1-wei simulation fee: the min needs are identical from 1 wei to 3 gwei.

### 6.2 Simulation passes but on-chain execution fails

- **Rundler B2b (b)**: all 3 ops are accepted on submit, then the bundle is dropped (`FailedOp(2, AA34)`) and the SP is banned (F1 below). No tx was
  sent, so nothing reverted on chain, but the ops were accepted and never included.
- Otherwise **none**. Every accepted op in (b) was included with `success = true`, and there was no OOG / AA33 / AA50 / postOp revert on chain.
  In (a) nothing was accepted.

### 6.3 Other findings

- **AMS-1 (high): SP's validation gas roughly quadruples on Amsterdam.** pmV need is 717k–999k (Osaka frame 198k–238k). The account's v with
  initCode is 3.9–4.0M (Osaka factory phase 532k). postOp needs 288k at SETTLE 160k. The current defaults (a) let **no** op through.
  The PRELIMINARY 820k (b) is enough for CREDIT (717k) and for BALANCE after the SP's first op (784k), but **not** for the first op through a
  fresh SP (882k), SP_RENEW (999k) or account renew (871k). Those cases fail with `AA33`. They are rejected at simulation time, so they cost no gas
  and cause no ban. The definitive value must cover ≥ 999k plus margin (to be set by the calibrated G-layer). MIN_POST_OP_GAS 400k / SETTLE 380k
  were sufficient in every included op. SDK/test v with initCode must be ≥ ~4.0M.
- **AMS-2 (high, carries Osaka F1): F1 reproduces on Amsterdam.** Rundler B2b gives the same log lines as on Osaka, the SP is BANNED
  (`opsSeen 0x2710, status 2`), and the next normal op gets `-32504 throttled or banned`.
- **AMS-3 (medium): estimates cannot be used as-is (F2, worse on Amsterdam).** Rundler still returns no `paymasterPostOpGasLimit`, and with pm gas
  omitted it estimates pmV ≈ 61k. Alto's pmV is below the need (§6.1). Alto's pmP is 137,851 when omitted and 240,000 for a 200k input (< 288k).
  The SDK must supply pmV and pmP itself (≥ the G-layer values) and must not take Alto's pmV.
- **AMS-4 (medium, Alto defect): Alto v1.2.5's `eth_estimateUserOperationGas` throws** `Hex size (33) exceeds padding size (16)`
  (viem 2.24.3, `SizeExceedsPaddingSizeError`, no RPC code) for **every** estimate in (b) after the first included op (B7): 25 occurrences in `b/alto-errors.log`. Before
  that, and throughout (a), its estimates either complete or end in a normal `AA..` error; it never throws. A computed field does not fit 16 bytes (probably negative). Root cause **not
  determined**. Submission and bundling are unaffected (B8, B2*, aftermath were included).
- **AMS-5 (low, Rundler diagnostics):** Under Amsterdam, Rundler v0.11.0 reports a paymaster-validation OOG (AA36) and an initCode OOG (AA13) as
  `-32603 Failed to decode validation output 0x…`, and an in-validation OOG revert (AA33) as `-32500 validation reverted:` with empty data.
  On Osaka the initCode OOG read `Simulation ran out of gas for entity: factory`. This run did not establish whether the message change is Amsterdam-specific;
  the same Rundler build was not re-run on Osaka.
- **AMS-6 (info, deployment): 6 of 55 B-layer deploy txs exceed the EIP-7825 per-tx cap** (16,777,216) and only fit through the EIP-8037
  reservoir. SuperPaymaster impl CREATE uses 52,389,391; xPNTsFactory 36.9M; Registry 36.6M; xPNTsTokenV2Ext 34.4M; xPNTsTokenV2 31.3M; MySBT 19.7M.
  forge 1.7.1's script simulation under-counts this (AD-3). `deploy-core` on an Amsterdam chain therefore needs `--skip-simulation` (or
  an Amsterdam-aware forge) and a block gas limit ≥ ~53M. This is outside the B layer and is passed on for the deployment runbook.

### 6.4 State-dependence of SP's validation gas

The second op of the same sender in the same bundle uses 688,445 gas vs 1,153,019 for the first (B2a, Rundler, one tx). In Alto's separate txs it uses 956,865.
The first op ever through a fresh SP/operator needs +98k pmV. Both follow from EIP-8037 pricing zero→nonzero writes at ~100k: whether a
slot is already nonzero now swings the cost by ~100k, where on Osaka the swing was ~20k. A fixed pmV must cover the coldest path.

### 6.5 §3.4 access check on the Amsterdam traces

`access-check.mjs` on our tracer's output for every captured simulation: **(a) 48 simulations, (b) 68 simulations: OUTSIDE 0, FORBIDDEN 0**
(`a/access-check.txt`, `b/access-check.txt`). The access sets (R1/R2/R3/R4/Registry counts) are identical to Osaka for the ops that ran
to completion, e.g. B1-type R1 6 / R2 19 / R3 2, B5 R2 23, B6 R4 8, B7 R1 13 / reg 2+12. In ops cut short by OOG, R3 is 1 (only the token's TSTORE
before the OOG). B8 OP-070: both bundlers' tracers again record the two TSTOREs as `writes` (`b/b8-op070.json`).

## 7. Differences vs the recorded Osaka results (README.md, B1-B10.md)

| # | item | Osaka (anvil 1.7.1, `--hardfork osaka`) | Amsterdam (this run) |
|---|---|---|---|
| X1 | B0 at pm verif 100k | 4/4 violators rejected **by rule** on both bundlers | 2/4 (STO-031, STO-021) rejected by **OOG** (`validation reverted` / `AA33`). By rule only at 400k |
| X2 | B9-below (SP 0.1 ETH) | Rundler: `-32502 entity stake/unstake delay too low` (needsStake paymaster) | stake check never reached. (a) `-32603 Failed to decode…` / `AA36`; (b) `AA33` (pmV 882k > 820k) |
| X3 | B9-above, B1, B3, B5, B6 | included on all bundlers (B3: Alto D2 rejects 2nd/3rd sender) | (a) and (b): rejected on all bundlers, gas (AA36 / AA33). D2 could not be observed |
| X4 | B7, B8 | included | (a) rejected AA36; (b) included (1,157,426 / 1,152,705 gas) |
| X5 | B4 (factory stake) | unstaked / 0.5 ETH / 3600 s rejected with stake reasons (Rundler); ok-factory included at v 1.2M | all four rejected `AA13` (v need 3.9–4.0M). The stake checks were not reached. D1 could not be observed |
| X6 | B2a | Rundler 1 tx; Alto 2 txs (D3); altoMulti 1 tx | (a) rejected; (b) **same as Osaka** |
| X7 | B2b / F1 | Rundler bans SP; Alto rejects op 3 on submit | (a) rejected (gas); (b) **same as Osaka** (F1 reproduces) |
| X8 | B10 Rundler | no pmP; pm omitted pmV 38,403; supplied 300k echoed | no pmP; omitted 60,857–62,840; (a) supplied 300k → **estimation error AA36**; (b) supplied 820k echoed |
| X9 | B10 Alto | supplied 200k → pmP 240,000 (≥ 200k ✓), pmV 287,821; omitted pmP 114,560 | (a) supplied → pmP 240,000 (**< 288,276 need**), pmV 497,292 (**< 882k need**); omitted pmP 137,851. (b): **estimation throws** (AMS-4) |
| X10 | SP validation gas | 198k–238k | 698k–981k frame, 717k–999k limit (§5.1) |
| X11 | account validation / factory | 6,850 (B6 32,443) / factory 531,693 | 6,850 (B6 33,343) / createSender 3,756,559 |
| X12 | Rundler OOG messages | `Simulation ran out of gas for entity: factory` | `-32603 Failed to decode validation output …` (AMS-5) |
| X13 | §3.4 | 0 outside / 0 forbidden (34 + 36 + 36 sims) | 0 / 0 (48 in a, 68 in b) |
| X14 | deployment | 30M default block limit, forge simulation fine | needs ≥ ~53M block limit, `--skip-simulation` (AD-2, AD-3, AMS-6) |

## 8. Not run / limits

- **geth `--dev` cross-check on Amsterdam was not run.** The task marks it optional, and anvil nightly is the engine calibrated against live Sepolia.
  geth's fork naming for Amsterdam (`bogota` in 1.17.5) would need its own calibration.
- **The stake-rule cases (B9-below, B4 × 3) and Alto's D1/D2 could not be evaluated on Amsterdam**, because gas fails before any stake/storage rule
  is reached, in both (a) and (b). Re-running B1–B10 with values that pass (≥ ~1.0M pmV, v+initCode ≥ ~4.0M) is the obvious next step
  once the G-layer values are final. That was not done here, to avoid inventing parameters.
- AMS-4 (Alto throw) and AMS-5 (Rundler message): root causes not determined.
- Sepolia's block gas limit (60M) was taken from memory, not read live (no public RPC allowed). The calibration does not depend on it.
- Min needs come from `handleOps` simulations at fee 0.1 gwei. §6.3 shows the needs do not change with fee or tx gas. Each case's own
  on-chain result at real fees agrees: B7 and B8 pass at 820k with needs of 717k and 784k, and B1 fails at 820k with a need of 882k.

## 9. Files

| path | content |
|---|---|
| `script/b-layer/ams-calibrate.mjs` | step-0 gate |
| `script/b-layer/ams-b0-run.sh` | B0 on Amsterdam (both bundlers, unsafe control) |
| `script/b-layer/ams-g1-run.sh`, `ams-g1-deploy.sh`, `ams-gasparams.mjs`, `ams-g1-collect.sh` | G1 runner, deploy, variant-b governance step, collection |
| `script/b-layer/ams-probe.mjs`, `ams-report.mjs`, `ams-reservoir.mjs` | per-op estimate / need / sufficiency probe, matrix, tx-gas & fee sweep |
| `script/b-layer/{lib,g1-lib,g1-cases,b0-send}.mjs` | adapted as AD-4 … AD-7 (defaults reproduce the Osaka run) |
| `amsterdam/b0/` | B0 raw verdicts (6 configurations) |
| `amsterdam/{a,b}/` | `deploy.json`, `setup.json`, `gasparams.json` (b), `calibration.json`, `versions.txt`, `<bundler>-results.json` (raw bundler responses + probe), `<bundler>-traces.jsonl.gz`, `<bundler>-cases.log`, `rundler-events.log`, `alto*-errors.log`, `access-check.{json,txt}`, `b8-op070.json`, `matrix.{md,json}` |
| `amsterdam/reservoir/` | `reservoir.json` (needs vs tx gas and vs fee), `alto-estimate-ethcall-replay.json` (Alto's estimation calls replayed at 5 gas values) |
