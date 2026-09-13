# AOA / SP 5.5.0 — raw evidence data

Index of every item (id, category, commit, reproduction, sha256): [`../EVIDENCE-INDEX.md`](../EVIDENCE-INDEX.md).
Integrity: `cd docs/design/aoa-balance-mode && shasum -a 256 -c EVIDENCE.sha256` (and, separately,
`cd b-layer && shasum -a 256 -c F1-EVIDENCE.sha256` for the frozen F1 set, which this directory does not touch).

**Nothing in this directory is a 5.5.0 transaction on a public chain.** Categories:

| category | meaning |
|---|---|
| `onchain-real` | mined on a public chain, fetched read-only; verifiable on an explorer (`onchain-real/`) — only pre-5.5.0 history so far |
| `onchain-readonly` | read-only JSON-RPC answers from public chains (no transaction) |
| `local-anvil` | a fresh local anvil node (chain 31337). **The hashes exist only on that node, which no longer runs; no explorer has them** |
| `fork-simulation` | a local `anvil --fork-url <Sepolia archive>` node. **Hashes exist only on that local fork; nothing was broadcast to Sepolia** |
| `unit-test` | forge test output (in-process EVM) |

## 1. G2 per-op export — JSONL schema (`g2-*.jsonl`)

Produced by `contracts/test/v2/SuperPaymasterV55Fuzz.t.sol::test_G2_coverage_replay_fixed_seeds` when the
env var `G2_EXPORT_PATH` is set (default off; the file must lie under the repo root — foundry `fs_permissions`).
One JSON object per line, one line per **admitted** op (settled ops and injected-failure ops; rejected
ops are not admitted and have no line). Integers that can exceed 2^53 are JSON strings (decimal).

| field | type | meaning |
|---|---|---|
| `formula` | string | buffer formula tag. Main line (5.5.0 as on `feat/aoa-balance-mode-5.5.0`): `OLD_postOpGasLimit_Cwrap30k` = `bufGas = postOpGasLimit + ceil((callGas+postOpGas)*10/100) + 30000`. The experiment branch must use its own tag (e.g. `A_Cpostop170k_Cwrap5k`, `B_Cpostop175k_Cwrap5k_default`) and put the constants in the tag |
| `seedIndex` | int | i in `keccak256(abi.encode("G2-coverage", i))`, 0..999 |
| `seed` | hex | that campaign seed |
| `bundle` | int | bundle index inside the campaign (0-based; counts bundles whose ops were all rejected too) |
| `op` | int | index of the op in the bundle's planned list (0-based; rejected ops keep their index) |
| `userOpHash` | hex | EntryPoint `getUserOpHash` |
| `mode` | `BALANCE`/`CREDIT` | mode SP chose at validation (LockCreated / CreditReserved) |
| `settled` | bool | settlement happened (usedOpHashes + Lock/CreditSettled). Overpay statistics use `settled == true` only |
| `injected` | bool | a settle failure was injected (`vm.mockCallRevert`); `settled == !injected` is asserted by the test |
| `exec` | `OK`/`MOVE`/`REVERT`/`OOG` | the user execution kind |
| `ethMovedBeforePostOp` / `aMovedBeforePostOp` | bool | an ETH/USD (resp. aPNTs/USD) price move by a kept MOVE op of the same bundle happened at or before this op, i.e. before its postOp ran (same definition as the test's `postAfterEthMove` / `postAfterAMove` counters, which count settled ops only) |
| `postOpGasLimit`, `callGasLimit` | int | op gas limits |
| `feePerGas` | string wei | gas price EntryPoint passed to postOp (== maxFee; basefee 0 in forge) |
| `P` | string wei | `actualGasCost` argument of SP.postOp, taken from the postOp calldata (state-diff recording) |
| `bufGas` | int | buffer gas of the formula above |
| `bufWei` | string wei | `bufGas * feePerGas` |
| `a0` | string aPNTs-wei | reservation at validation |
| `charge` | string aPNTs-wei | SP charge incl. protocol fee (TransactionSponsored; == token-side charge; asserted exact == `min(a0, ceil(ceil((P+bufWei)*price*1e18/(10^dec*aPrice)) * (BPS+fee)/BPS))`) |
| `charge_eth` | string wei | documented conversion (`_chargeEthNet`): `floor(floor(charge*BPS/(BPS+fee)) * 10^dec * aPriceUSD / (price*1e18))` at the validation price snapshot, fee removed — a LOWER bound of what the user paid for gas. `"0"` for non-settled ops |
| `G` | string wei | `UserOperationEvent.actualGasCost` (what EntryPoint took from SP's deposit) |
| `actualGasUsed` | int | `UserOperationEvent.actualGasUsed` |
| `overpay_ppm` | int or null | `floor((charge_eth - G) * 1e6 / G)`; null for non-settled ops |
| `ethUsd`, `ethUsdDecimals`, `aPriceUSD`, `feeBps` | | the validation-time price snapshot (test-read, asserted equal to the OpCtx) and the protocol fee |

Statistics: `node script/evidence/overpay-stats.mjs <file.jsonl>` (add `--json` for machine output). It
re-derives `bufWei`, `charge`, `charge_eth` and `overpay_ppm` of every settled op from the raw fields and
exits non-zero on any mismatch or any subsidised op. Definitions (identical to the fuzz's `_dist`):
mean = `floor(Σppm / n)`; **P95 = nearest rank, sorted ascending `a[ceil(0.95·n) − 1]`** (Solidity
`a[(n*95+99)/100 - 1]`); median = `a[floor((n−1)/2)]`. Groups: all settled; `postOpGasLimit ≤ 250,000`
(MIN + 50k); `postOpGasLimit ≥ 1,000,000` (the plan only draws 1.0M–1.5M in that band; same predicate as the
experiment-branch fuzz).

### Files
| file | produced | notes |
|---|---|---|
| `g2-main-7fa7b705-oldformula.jsonl` | this commit's tree = `df941d57` + the export hook; the fuzz body is unchanged since `7fa7b705` apart from the hook (and no `contracts/src` change since `a3eb0945`) | 6,055 lines = 4,389 settled + 1,666 injected. Re-run is byte-identical (checked with `cmp`) |
| `g2-main-7fa7b705-oldformula.stats.txt` / `.stats.json` | `overpay-stats.mjs` output | all / tight / 1.0–1.5M = 83.2/269.6/371.1 %, 41.8/61.3/81.5 %, 243.4/305.3/371.1 % |
| `g2-main-7fa7b705-oldformula.forge.log` | forge -vv output of the export run | the in-test `_report` numbers; identical to an export-off run |
| `g2-main-export-off.forge.log` | the whole fuzz file with the export OFF | shows the hook changes nothing (same counts, same distribution) |

**PENDING (experiment branch `exp/buffer-and-params`)**: Part A (`31921fbc`) and Part B (`e0cf0dc8`) exports
with the SAME schema (own `formula` tag) and the SAME script — to be produced by the experiment-branch agent.
Port the hook (`_exportOp` and the `_exp*` storage) verbatim; only the `bufGas` line must follow that
branch's charge oracle.

Reproduce:
```
forge build
G2_EXPORT_PATH=cache/g2-export.jsonl forge test --match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol \
  --match-test test_G2_coverage_replay_fixed_seeds -vv
node script/evidence/overpay-stats.mjs cache/g2-export.jsonl
```

## 2. G-layer logs (`g-layer/`)
forge `-vv` console output, each file starts with the command, git HEAD, forge version and UTC time
(`script/evidence/run-logged.sh`). Files whose name carries a commit (`*-c5fc803c-*`, `*-31921fbc-*`) were
run in an unmodified `git archive` of that commit (header says so).

## 3. Local chains (`local/`)
- `l4-*`: fresh `anvil` 1.7.1 (chain 31337, default hardfork), `ANVIL_RPC_URL=http://127.0.0.1:28561 ./deploy-core anvil --force`
  then `ENV=anvil forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest --rpc-url … --broadcast --slow
  --gas-estimate-multiplier 400 -vv` and `--sig "verify()"`. `l4-balance-mode-op.receipts.json` = full tx + receipt
  + block header of the 6 L4 transactions (`script/evidence/collect-receipts.mjs`). `l4-gasless.anvil.snapshot.json`
  holds the script's SIMULATED post-state (burn 70.85…); the on-chain figures are in `l4-L4GaslessTest-verify.log`
  (burn 78.2769…) — the charge is priced at the gas price of the mined block, not the simulation's.
  `l4-deploy-core.log.gz` is the full deploy-core output (gzip -n; mostly forge-lint noise).
- `fork-sepolia-11692260/`: `script/evidence/fork-rehearsal.sh <.env.sepolia> 11692260 <dir>` — two local forks of
  Sepolia at block 11,692,260 (chain id 11155111 kept by anvil). Fork A: step 1 ①–③ (cancel 0xBb46, GOV-1-shaped
  timelock, DeployAPNTsCapped + simulated accept, real accept on the fork via the impersonated Safe after
  `evm_increaseTime 172800`, `verify()`, re-queue `setAPNTsToken(APNTsCapped)` by **manual cast — not scripted**).
  Fork B: step 1 ① cancel, 3 pause, `run()` strict (4 → 5 → 5b → 6), 7a issue, 7c-1 configure, 7c-2 unpause.
  Step 1 ④ (switch to APNTsCapped + 1:1 re-deposit) is **not scripted** for APNTsCapped and was not rehearsed.
  `*.receipts.json` = full receipts (labels re-derived from the fetched tx, not from forge's broadcast order);
  `*.log` = forge output; `A5-readback.txt` / `B7-readback.txt` = cast read-backs with block numbers;
  `_driver-output.txt` = the driver's stdout.

## 4. Other
- `onchain-readonly-fork-level-probes.json`: `script/evidence/fork-level-probes.mjs` — raw requests/responses of
  `eth_config` (Sepolia), the CLZ probe (Sepolia, OP mainnet, OP Sepolia; anvil prague = negative control,
  anvil osaka = positive control), EntryPoint v0.7 codehash on the three chains, `getDepositInfo(SP)` on
  Sepolia and OP mainnet.
- `onchain-real/sepolia-5.4.x-upgrade-txs.json`: the historical 5.4.1/5.4.2 impl-deploy and upgrade txs of
  `deployments/deploy-record-v5.4.2-sepolia.md` / `deploy-record-registry-v5.4.2-sepolia.md`, fetched read-only.
- `sizes/`: `script/evidence/sizes.mjs <tree>` — runtime sizes with the artifact chosen by its metadata.
- `templates/`: CSV headers for P2 (Sepolia runbook) and P4 (OP mainnet deployments and per-op data); spec §6.1.

## Part A / Part B exports (merged from `exp/buffer-and-params`)

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

## Mutation patches (`mutations/`, Part B context-format mutations)

Each `mutations/<name>.patch` is a plain `git diff` of `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`
against its state at **`6c3a9a0e`** (standard `a/…` / `b/…` headers; provenance is in the `#` comment block
above the diff, which `git apply` ignores). `mutations/<name>.columns.log` is the recorded four-column result
(forward / rollback from `SuperPaymasterV55UpgradeRace`, param-race from `SuperPaymasterV55ParamRace`, exact
charge from `SuperPaymasterV55GasParams::test_c_postop*`) plus the G2 exact oracle.

| patch | mutation | recorded result |
|---|---|---|
| `a-snapshot-in-word9.patch` | snapshot back in word 9 (fb64e7eb packing: `decimals \| GasParams-slot << 8`, 352-byte context) | rollback **red** `rollback: no victim postOp fails after a mid-bundle upgrade: 2 != 0`; forward / param-race / exact charge green; G2 red on its context-format assertion `R10-M3: postOp context carries the validation-time decimals` (word 9 is no longer a clean uint8) |
| `b-nolen-asm.patch` | only the length condition deleted, assembly load kept | all green — **equivalent mutant** (the 352-byte context is the calldata tail; CALLDATALOAD past calldatasize returns 0 → legacy path) |
| `b-slice.patch` | unconditional bounds-checked slice `context[352:384]` | forward **red** `forward: no victim postOp fails after a mid-bundle upgrade: 2 != 0`; others green |
| `c-384-as-legacy.patch` | 384-byte context treated as legacy | exact charge **red** `defaults: 40.7e18 != 35.2e18`; G2 red `R10-M3: aGas == … (exact)`; forward / rollback / param-race green |

Apply and run (repo root, tree at `6c3a9a0e`, i.e. `SuperPaymaster.sol` identical to that commit):
```
git apply --check docs/design/aoa-balance-mode/data/mutations/<name>.patch
git apply docs/design/aoa-balance-mode/data/mutations/<name>.patch
forge test --match-path "contracts/test/v2/SuperPaymasterV55{UpgradeRace,ParamRace}.t.sol"
forge test --match-path contracts/test/v2/SuperPaymasterV55GasParams.t.sol --match-test test_c_postop
forge test --match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol --match-test test_G2_coverage_replay_fixed_seeds
git apply -R docs/design/aoa-balance-mode/data/mutations/<name>.patch   # revert
```
Mutation (a) widens the `OpCtx.decimals` field to `uint256`; the rest of the test tree still compiles against it.
All four patches were verified with `git apply --check`, `git apply` and `git apply -R` on a clean
`git archive 6c3a9a0e` tree (temporary repo, removed afterwards). Some `.columns.log` headers name `8241349b`:
that commit only added data files; `SuperPaymaster.sol` there is identical to `6c3a9a0e`.
