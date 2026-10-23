# R2-F4 — tested-bytecode identity for R-AMS (G and B layer) vs v5.5.0-rc.4

DSR open item R2-F4: *"G main experiments were nightly/Prague compiled, the deployment table nightly/Cancun; B says
forge 1.7.1/default. Source hash, size, version and params being equal do not replace creation/runtime artifact hashes
corresponding to rc.4. Deliver for both lines the actual artifacts, metadata, library links / immutable map of every key
contract and the final release list; if they differ, limit the claim to diagnostic or re-test with final artifacts."*

Date 2026-10-23. Local only: in-process forge and local anvil, anvil public dev keys, no public RPC, nothing under
`contracts/src`, `contracts/script`, `foundry.toml`, `.github` changed. Machine-readable result: **[`identity.json`](identity.json)**.
The actual rc.4 artifact JSONs (both variants of each release contract + the fixture contracts) are committed under
[`artifacts/`](artifacts/) (paths as in forge's `out/`; sha256 in `checksums/artifacts.sha256.txt`). Artifact names in this
report (`SuperPaymaster.sol/SuperPaymaster.json`, `….registry-size.json`, `….default.json`) refer to that layout.

## 0. Verdict

| line | which bytes it executed | equal to rc.4 release bytes? | consequence |
|---|---|---|---|
| **B layer** (`b-layer/amsterdam/{a,b,c,c-rundler-mvg6m}`) | SP impl, SuperPaymasterAdmin (created by the SP constructor), Lens, Registry impl, xPNTsTokenV2 impl, xPNTsTokenV2Ext, xPNTsFactoryV2, AOAProtocolRegistry, GlobalTierSource = the **profile.default (release) variants** (§3) | **yes**, for every release-list contract the stack contains (APNTsCapped is not part of the B stack) | B numbers stand as release-byte measurements |
| **G layer, R-AMS-2a scratch** (`data/rams-2a/logs/scratch/`) | the **`registry-size` variants** (optimizer runs **200**) of SuperPaymaster, SuperPaymasterAdmin, xPNTsTokenV2, xPNTsTokenV2Ext, xPNTsFactoryV2, AOAProtocolRegistry, GlobalTierSource, ERC1967Proxy, SimpleAccount(+Factory) (§4.1) | **no** (release = runs 500) | R-AMS-2a G numbers are **diagnostic**. Re-tested with the release bytes (§4.2): every verdict is unchanged. Gas-unit deltas (release − R-AMS-2a, 429 compared gas values): measured rows 80 down (−612 … −13), 16 up (15 frame-gas rows +290 … +600, initCode v +16,675), 314 zero; derived difference rows 6 down (−1,123 … −1), 13 zero (§4.3, [`g_delta.md`](g_delta.md)) |
| G layer, deployment table (R-AMS-2a §6) | init code taken from the profile.default artifacts (`rams-2a/deploy/resolve.log`: `SuperPaymaster.json`, `Registry.json`, … `.default.json`) | **yes** by artifact identity (40/40 variants byte-identical across forge 1.7.1-cancun, nightly-prague and nightly-cancun, §2.2); not re-run | stands |

The compiler line (forge 1.7.1 vs nightly, `--evm-version cancun` vs `prague`) does **not** change any byte (§2.2). The
difference comes from **which compile unit's code a test creates**: a test that imports `Registry` (via
`UUPSDeployHelper`) is compiled in the `compilation_restrictions` job for `Registry.sol` (runs 200), and `new X()` inside it
embeds that job's `X` — not the shipped runs-500 artifact.

A second, larger fixture effect was found while re-testing and is reported in R2-F2 (`../rams-f2/REPORT.md` §2): the
R-AMS-2a scratch ran with `--no-isolate` (the whole test is one transaction). With `--isolate` (each `handleOps` its own
transaction, as on chain and in the B layer) the G numbers rise (pmV 819,940 → 882,357) and match the B layer to within
18 gas. The rise is consistent with storage written earlier in the same transaction being warm and no longer zero (no
EIP-8037 zero→non-zero charge) under `--no-isolate`; this was not traced at opcode level. §4.4 lists the `--isolate` re-run of the same measurements.

## 1. Tools and build

| item | value |
|---|---|
| tag | `v5.5.0-rc.4`, tag object `67f78f60…`, peeled **`fbd74fb1e2e9d948996e6d6c02c48dc1c1778107`**; `contracts/src` tree `f1d39b5b…` = `origin/main` = `79c0c6f` (R-AMS-2a) = `c3eb1011` (B layer); `foundry.toml` `065d0bd7…` in all four. `git diff fbd74fb1 5ae59926` (origin/main when this item started; the current origin/main `f7eefb19` has the same two hashes) touches **353 files, none under `contracts/` and no `.sol` file**: `docs/design` 252, `docs/release` 63, `script/b-layer` 16, `script/evidence` 6, `script/gasless-tests/{package.json,pnpm-lock.yaml}`, `packages/x402-facilitator-node/{package.json,pnpm-lock.yaml}`, `scripts/{merge-preflight.sh,test_merge_preflight_strict.py}`, `.github/workflows/preflight-selftest.yml` (added), `CHANGELOG.md`, `README.md`, and 7 files under `singleton-paymaster/lib` (6 lockfiles + `openzeppelin-contracts-v5.1.0/package.json`). Full list: [`git-diff-rc4-vs-main.txt`](git-diff-rc4-vs-main.txt). The `contracts/src` tree `f1d39b5b…` and `foundry.toml` blob `065d0bd7…` are identical on both sides |
| build | `git worktree add /tmp/rc4 fbd74fb1`, submodules `contracts/lib/{chainlink-brownie-contracts,solady}` at the recorded gitlinks; **`/tmp/fd/v1.7.1/forge build --offline`** (no `FOUNDRY_PROFILE` = profile.default, as `deploy-core`); log `builds/rc4-build.log.gz` |
| forge 1.7.1 | `foundry_v1.7.1_linux_amd64.tar.gz` sha256 `cf7e688e…c88b` = release `.sha256`; forge `4f77da08…355c` |
| nightly | `nightly-926eb1d087523f1de437e3c0c49ea6d26407e827`, tarball sha256 `df74eb56…a6a1` = release `.sha256`; forge `9f19c41c…db85`, anvil `7f483b2a…5142` |
| solc | 0.8.33+commit.64118f21 (`solc-static-linux` from the GitHub release, sha256 `1274e5c4…5468`) |
| records | `checksums/tools.sha256.txt` (all of the above + Rundler/Alto commits), `checksums/f4art.sha256.txt` (the eight G re-run inputs; each equals a committed `artifacts/` file, mapping in §4.2), `checksums/fixture.sha256.txt` |
| other builds of the same tree (§2.2) | nightly `--evm-version prague` → `/tmp/g-out-prague`, nightly default (cancun) → `/tmp/g-out-cancun`, forge 1.7.1 of this checkout (`out/`, used by the B scripts); logs `builds/*.log.gz` |

## 2. rc.4 artifacts (forge 1.7.1, profile.default)

### 2.1 Release list (`../rc4-tag-fbd74fb1/rc4.json`) — all 10 equal to the tag record

`identity.json` → `releaseList[]` carries per contract: creation / runtime keccak and size, runtime keccak with immutables
zeroed, the full `immutableReferences` map (AST id → byte ranges), `linkReferences`, the decoded runtime CBOR tail, keccak of
`rawMetadata`, compiler settings, and the non-shipped `registry-size` variant.

| contract | artifact (shipped) | runs | runtime B | runtime keccak | creation keccak | immutable ranges | = tag record |
|---|---|---|---|---|---|---|---|
| SuperPaymaster | `SuperPaymaster.sol/SuperPaymaster.json` | 500 | 13,744 | `0xc9fe37f5…d222` | `0x4edff578…0a4e` | 16 | ✅ |
| SuperPaymasterAdmin | `SuperPaymasterAdmin.sol/SuperPaymasterAdmin.json` | 500 | 19,214 | `0xefc71c67…78d2` | `0x7c5fd9a3…3e66` | 18 | ✅ |
| SuperPaymasterLens | `SuperPaymasterLens.sol/SuperPaymasterLens.json` | 500 | 5,413 | `0x4435e4a5…d3c1` | `0xb2b98f67…61d5` | 0 | ✅ |
| Registry | `Registry.sol/Registry.json` | **200** | 23,306 | `0xde3d06d8…6e8b` | `0x4a8d5d6c…62c3` | 2 | ✅ |
| xPNTsTokenV2 | `xPNTsTokenV2.sol/xPNTsTokenV2.json` | 500 | 20,008 | `0xb15c14c4…0474` | `0xedaaecbb…5730` | 13 | ✅ |
| xPNTsTokenV2Ext | `xPNTsTokenV2Ext.sol/xPNTsTokenV2Ext.json` | 500 | 22,005 | `0x449f651a…2604` | `0x956b0781…1e04` | 17 | ✅ |
| xPNTsFactoryV2 | `xPNTsFactoryV2.sol/xPNTsFactoryV2.json` | 500 | 8,537 | `0xc5c82226…1776` | `0xb236ad22…3b61` | 9 | ✅ |
| AOAProtocolRegistry | `AOAProtocolRegistry.sol/AOAProtocolRegistry.json` | 500 | 2,746 | `0x14b95e6c…5551` | `0x8342ddc6…` | 0 | ✅ |
| GlobalTierSource | `GlobalTierSource.sol/GlobalTierSource.json` | 500 | 542 | `0x73c8f2f2…84f7` | `0xf2237df8…` | 2 | ✅ |
| APNTsCapped | `APNTsCapped.sol/APNTsCapped.json` | 500 | 5,346 | `0x16a1a114…1304` | `0xf6b8ecab…` | 7 | ✅ |

(`rc4.json` counts immutable *variables*, this table counts byte *ranges*; e.g. SP 5 variables / 16 ranges.) Every
contract also has a `registry-size` variant (runs 200, e.g. SP runtime 13,334 B `0x81adb28b…`), except Registry itself.

Common to all artifacts: **no library links** (`linkReferences` empty in creation and runtime of all 40 variants);
`bytecode_hash = "none"`, so the runtime ends with the CBOR map `a164736f6c6343000821` = `{solc: 0.8.33}` (10 bytes) followed by its 2-byte big-endian length `000a`, i.e. the last 12 bytes of every runtime are **`0xa164736f6c6343000821000a`** (checked: all 28 runtimes in the committed `artifacts/` end with these 12 bytes); no metadata hash;
the metadata JSON is identified by `rawMetadataKeccak` (it differs between forge 1.7.1 and nightly only in its JSON text,
e.g. `evmVersion`; it is not embedded in the code).

Other key contracts used by the fixtures (`identity.json` → `otherKeyContracts`; both variants each):
TimelockController (`.default` 5,458 B `0x41aec1b7…`), ERC1967Proxy (`.default` 100 B `0xbfa8a49f…`, `registry-size` 89 B
`0xf83adf10…`), SimpleAccount v0.7 (`.default` 4,768 B `0x922697f5…`), SimpleAccountFactory (`.default` 1,447 B
`0xed181ffd…`), MockAirAccount (2,097 B `0x228d7a59…`), MockAirAccountFactory (3,264 B `0x88d524f1…`), xPNTsFactory v1,
xPNTsToken v1, MySBT, GTokenStaking, GTokenAuthorization, EntryPoint (repo-compiled; **not used**: both layers etch the
canonical EntryPoint v0.7 runtime, keccak `0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58`, 16,035 B,
`contracts/test/fixtures/entrypoint-v0.7.runtime.hex`; SenderCreator `0x283c9d14…7689`).

### 2.2 Compiler line does not change the bytes

The same rc.4 tree built three ways — forge 1.7.1 (cancun), nightly `--evm-version prague` (the R-AMS-2a G compile),
nightly default (cancun; the R-AMS-2a deployment table) — gives **40/40 artifact variants byte-identical in creation and
runtime** (`identity-rc4-forge171-default.json`, `identity-rc4-nightly-prague.json`, `identity-rc4-nightly-cancun.json`;
`identity.json` → `crossBuildEquality`). Only `rawMetadata` differs.

## 3. B layer: what was executed

Method (`script/b-layer/f4-onchain-run.sh` → `b-onchain/`): fresh anvil nightly `--hardfork amsterdam --gas-limit 60000000`,
calibration gate **PASS** (`b-onchain/calibration.log`, 5/5), the B-layer deploy exactly as `ams-g1-run.sh`
(`ams-g1-deploy.sh` with forge 1.7.1, this checkout's `out/`, whose SP / Registry / xPNTsFactory-registry-size / MockAirAccount
artifacts are byte-identical to `/tmp/rc4/out`), then `g1-setup.mjs`. Then:

1. **Transaction identity.** All **55/55 deploy tx hashes** of this re-deployment equal those recorded in
   `{a,b,c,c-rundler-mvg6m}/deploy-receipts.json` (same signed transactions ⇒ same init code and constructor args); same
   gasUsed, status 1, addresses equal to every `deploy.json`. (The only field that differs in (b)/(c)/(c′) is forge's
   `contractName` label of the GTokenAuthorization rows, which was `null` there.)
2. **Creation code** (`script/b-layer/f4-creation-match.mjs` → `b-onchain/creation-match.{json,txt}`): every CREATE input
   = artifact creation code ‖ constructor args:

   | # | contract | creation artifact matched |
   |---|---|---|
   | 1 | Registry impl | `Registry.sol/Registry.json` (release) |
   | 14 | SuperPaymaster impl | `SuperPaymaster.sol/SuperPaymaster.json` (release; embeds the release SuperPaymasterAdmin) |
   | 16, 17 | GlobalTierSource, AOAProtocolRegistry | release |
   | 21–24 | xPNTsTokenV2Ext, xPNTsTokenV2, xPNTsFactoryV2, SuperPaymasterLens | release |
   | 2, 15 | ERC1967Proxy (Registry, SP) | `ERC1967Proxy.registry-size.json` (89 B; not on the release list) |
   | 3, 5, 6 | xPNTsFactory v1, GTokenStaking, MySBT | `registry-size` variants (B-layer infrastructure, not on the release list) |
   | 0, 4 | BLayerPriceFeed (script helper), GTokenAuthorization | no artifact in the list (script compile unit); not on the release list |

3. **Runtime code** (`script/b-layer/f4-identity-onchain.mjs` → `b-onchain/onchain-identity.{json,txt}`): `eth_getCode` of
   every address in `deploy.json` / `setup.json`, matched with the artifact's immutable ranges zeroed on both sides:
   SP impl, Lens, AOA registry, tier source, Ext, V2 impl, FactoryV2 = release runtime; the SP proxy and Registry proxy
   resolve (EIP-1967 slot) to the release SP / Registry runtime; the operator token is an EIP-1167 clone of the V2 impl;
   MockAirAccount ×12 and MockAirAccountFactory ×4 match their artifacts; EntryPoint = canonical codehash. The immutable
   values found are recorded per row (`immutables[]`).

## 4. G layer: what was executed, and the re-test with release bytes

### 4.1 What R-AMS-2a executed

Control run (`fixture/control-original-fixture.diff`: the original fixture, `new` kept, only dump statements added; log
`logs/g/control_original_fixture_test_B3_min_paymasterVerificationGasLimit_amsterdam.log` reproduces R-AMS-2a's
820,305 / 611,954 exactly). The dumped runtime of every contract (`g-dump-original-fixture/*.hex`) matched against the
identity (`scripts/match_dump.mjs` → `g-executed-bytecode-original-fixture.json`):

| deployed by the fixture | R-AMS-2a (original fixture) | F4 re-run (artifact bytes) |
|---|---|---|
| SuperPaymaster impl | `SuperPaymaster.registry-size.json` 13,334 B | `SuperPaymaster.json` 13,744 B (release) |
| SuperPaymasterAdmin | `registry-size` 18,891 B | release 19,214 B |
| xPNTsTokenV2 / Ext / FactoryV2 | `registry-size` 19,587 / 21,742 / 8,522 B | release 20,008 / 22,005 / 8,537 B |
| AOAProtocolRegistry / GlobalTierSource | `registry-size` 2,705 / 538 B | release 2,746 / 542 B |
| ERC1967Proxy (SP proxy, SimpleAccount) | `registry-size` 89 B | `.default` 100 B |
| SimpleAccountFactory / SimpleAccount impl | `registry-size` 1,443 / 4,675 B | `.default` 1,447 / 4,768 B |
| xPNTsTokenV2 clone | EIP-1167 → V2 impl | EIP-1167 → V2 impl |
| mocks (V55Registry, V55PriceFeed, V55APNTs, R2aWriter, GasBurner) | test-compiled | test-compiled (unchanged; not release contracts) |

Hence the R-AMS-2a G numbers were **not** measured on rc.4 release bytes. They are diagnostic.

### 4.2 Re-test method

Throwaway copy of the rc.4 tree (`/tmp/f4g`), R-AMS-2a scratch restored (sha256 `7098abba…` = committed
`rams-2a/scratch/Rams2a.t.sol.txt`), plus two added tests: `test_B4b` (band at the proposed SETTLE 420k) and `test_F2_matrix` (the unified table of `../rams-f2/REPORT.md` §1). In the copy of
`SuperPaymasterV55Gas.t.sol` every product contract the fixture creates is deployed with **`deployCode()` from the rc.4
forge-1.7.1 profile.default artifact JSON**, read from `f4art/<Name>.json` in the throwaway tree. `f4art/` is not committed separately: each of its eight files is byte-identical to a committed `artifacts/` file (`checksums/f4art.sha256.txt`; `scripts/setup_f4g.sh` recreates `f4art/` from `artifacts/` and checks the sha256): `SuperPaymaster.json`, `AOAProtocolRegistry.json`, `GlobalTierSource.json`, `xPNTsTokenV2.json`, `xPNTsTokenV2Ext.json`, `xPNTsFactoryV2.json` = `artifacts/<Name>.sol/<Name>.json`; `ERC1967Proxy.json` = `artifacts/ERC1967Proxy.sol/ERC1967Proxy.default.json`; `SimpleAccountFactory.json` = `artifacts/SimpleAccountFactory.sol/SimpleAccountFactory.default.json`. Deployed this way: SuperPaymaster impl (its
constructor creates the Admin), ERC1967Proxy, AOAProtocolRegistry, GlobalTierSource, xPNTsTokenV2Ext, xPNTsTokenV2,
xPNTsFactoryV2, SimpleAccountFactory (creates SimpleAccount). Diff: `fixture/artifact-run.diff`; full files
`fixture/*.txt`. The deployed runtime was dumped and matched (`g-executed-bytecode-artifact-run.json`): **all equal to the
release artifacts** (table §4.1, right column). Runtime: nightly forge, `--hardfork amsterdam`, `--no-isolate`,
`--evm-version prague` for the test-only contracts, same flags as R-AMS-2a. Logs `logs/g/`, timeline `logs/g/timeline.txt`.
In that first run the B4 pattern was `test_B4_no_oog_band$`, which matches no test (forge matches the regex against the name
with its `()` suffix); B4 was re-run by hand with `test_B4_no_oog` (timeline lines 15–16 and 30–31). The committed
`scripts/run_g.sh` was edited to `test_B4_no_oog` after that run; its header now records this.

**Reproduction with the committed scripts (2026-10-23T06:26Z).** `scripts/setup_f4g.sh` (creates `/tmp/f4g` from the rc.4
worktree if absent — it reuses an existing `/tmp/f4g` without reset, so start from a clean `/tmp`; the tree line in each log header records what ran, `fixture/*.txt` and `artifacts/`, sha256-checked), then `scripts/run_g.sh logs/g-r2` (`--no-isolate`) and
`scripts/run_g_isolate.sh logs/g-isolate-r2` (`--isolate --gas-limit 100000000000`). Every log starts with `# cmd:` (the full
forge command line), `# env:`, `# forge:` (version + binary sha256) and `# tree:` (commit, `contracts/src` tree,
`foundry.toml` blob, fixture sha256) lines; each timeline starts with the script's sha256. Result
([`logs/rerun-check.txt`](logs/rerun-check.txt), `scripts/rerun_check.sh`): the `R2A|` rows of all 14 `--no-isolate` and all 13
`--isolate` logs are **identical** to the original `logs/g/` and `logs/g-isolate/` logs.

### 4.3 Result: R-AMS-2a (runs-200 variants) vs release bytes, same flags (`--no-isolate`)

Full per-row diff of all 552 compared keys: **[`g_cmp.md`](g_cmp.md)** (340 identical, 212 differ, 0 missing).
Per-value gas deltas (release − R-AMS-2a, `scripts/delta_g.py` → **[`g_delta.md`](g_delta.md)**; values ≥ 1e11 are wei /
1e18-scaled aPNTs, not gas, and are excluded):

| class | values | down (range) | up (range) | zero |
|---|---|---|---|---|
| measured gas rows | 410 | 80 (**−612** `B1.balance_user_writes_1_fresh_slots.actualGasUsed` … −13 `B6.releaseStaleSponsorship.gasRefunded`) | 16: 15 test-frame rows (`testFrameGas_handleOps`, `handleOps_frame_gas`) **+290 … +600** (`B6.I8_settle_failure.testFrameGas_handleOps`), and initCode v **+16,675** | 314 |
| derived gas rows (difference of two measurements) | 19 | 6 (**−1,123** `B7.balance_user_writes_1.actualGasUsed_minus_frameGas` … −1) | 0 | 13 |

The frame-gas rows (gas the test's call frame spent on `handleOps`) rise while the ops' `actualGasUsed` falls, so the
derived `actualGasUsed − frameGas` rows fall by more than either (−843 / −1,123 / −1,122 for B7 writes 0 / 1 / 2).
**No verdict changed** (every `settled`, `chargeCoversNeed`, `success`, `postOpReverted`, `prefundTooLow`, band-failure count
and `settles_at_MIN` row is identical). Key numbers (`file:line` in `logs/g/` = same line in `rams-2a/logs/scratch/`):

| measurement (R-AMS-2a §) | R-AMS-2a | rc.4 release bytes | Δ | source line |
|---|---|---|---|---|
| T-R14-09: settles at MIN 200k, balance / credit (§4.1) | 0 / 0 | 0 / 0 | — | `test_B3_TR1409_amsterdam.log:9,12` |
| min settling postOp limit through EP, balance / credit / balance+1 slot (§4.1) | 365,325 / 369,624 / 365,325 | **365,207 / 369,581 / 365,207** | −118 / −43 / −118 | `test_B3_min_postOp_amsterdam.log:9,13,17` |
| non-guard failures in [175k, min) (§4.1) | 96 / 98 / 96 | 96 / 98 / 96 | 0 | `:12,16,20` |
| no-OOG band, SETTLE 160k: balance min-settle / min-guard / band (§4.2) | 365,325 / 164,543 / 200,782 | 365,207 / 164,500 / 200,707 | −118 / −43 / −75 | `test_B4_amsterdam.log:9-11` |
| band, SETTLE 160k credit | 369,624 / 164,543 / 205,081 | 369,581 / 164,500 / 205,081 | −43 / −43 / 0 | `:26-28` |
| band, SETTLE 155k balance / credit | 205,862 / 210,161 | 205,786 / 210,160 | −76 / −1 | `:24`, `:41` |
| band closes: balance 360k → 367,717; credit 365k → 372,797 (§4.2) | 0 / 0 | 0 / 0 (367,675; 372,754) | −42 / −43 | `:18-21`, `:35-38` |
| **band at SETTLE 420k** (new) balance / credit | — | **0 / 0** (min-settle = min-guard = 428,627) | — | `test_B4b_amsterdam.log` |
| W_postop at EP, balance / credit (§4.3) | 177,234 / 279,265 | 177,106 / 279,208 | −128 / −57 | `test_B2_amsterdam.log:11,17` |
| 6-scenario tuple 440k/420k/5k/340k: settles / covers (§4.5) | 6/6 / 6/6 | 6/6 / 6/6 | — | `test_B8_amsterdam.log` |
| same: min charge − bare / min charge − fee-incl. (aPNTs) | +33.05 / +20.22 | +33.05 / +20.24 | 0 / +0.02 | `derive.py` → `g_B8_derived.txt` |
| raw 385k/365k/5k/336k; C_POSTOP-low 300k; defaults (§4.5) | 6/6; 6/6; 0/6 | 6/6; 6/6; 0/6 | — | same |
| I9 credit first op: bare / charge / fee-incl. / charge−fee (§4.3) | 122.70130 / 126.94396 / 134.97143 / −8.03 | 122.65080 / 126.89402 / 134.91588 / −8.02 | | `g_B1_derived.txt` |
| I9 credit writes 1/2/3: charge − fee-incl. | −6.79 / −5.58 / −4.37 | −6.79 / −5.58 / −4.36 | | same |
| I9 balance first op: charge − fee-incl. | +2.07 | +2.09 | | same |
| SDK pmV, balance / credit first op (§4.7) | 820,305 / 611,954 | **819,940 / 611,572** | −365 / −382 | `test_B3_min_paymasterVerificationGasLimit_amsterdam.log:9-10` |
| SDK v, deployed SimpleAccount / via initCode (§4.7) | 119,668 / 801,247 | 119,590 / **817,922** | −78 / **+16,675** | `test_B3_min_verificationGasLimit_account_amsterdam.log:9-10` |
| SDK callGasLimit, 0 / 1 / 2 fresh slots (§4.7) | 1,842 / 115,475 / 229,192 | 1,776 / 115,408 / 229,125 | −66 / −67 / −67 | `test_B3_min_callGasLimit_amsterdam.log:9-11` |
| C_WRAP (§4.4) | 1,870 / 1,856 / 1,870 | identical | 0 | `test_C_wrap_amsterdam.log` |
| I8/I10 (§4.6): op actualGasUsed, releaseStaleLock, releaseStaleSponsorship, releaseStaleCredit | 1,333,615; 86,494; 48,682; 60,858 | 1,333,085; 86,348; 48,615; 60,792 | −530 … −66 | `test_B6_amsterdam.log:17,32,34,60` |

Why initCode verification **rises** by 16,675: the account the factory deploys is an ERC1967Proxy; the release build's proxy
runtime is 100 B vs 89 B in the `registry-size` unit, i.e. 11 more bytes of EIP-8037 code-deposit state gas
(11 × 1,530 = 16,830) minus small execution savings. With the R-AMS-2a +15 % convention this moves the §5.4 SDK value for
`verificationGasLimit` with initCode from **925,000 to 945,000** (817,922 × 1.15 = 940,610). No other §5 value changes
(pmV 819,940 × 1.15 = 942,931 → 945,000 as before; MIN/SETTLE/C_POSTOP derivations move by < 130 gas).

### 4.4 Same release bytes under `--isolate` (diagnostic for R2-F2)

`logs/g-isolate/` (same fixture and flags, `--isolate`, `--gas-limit 100000000000`). The original isolate timeline
(`logs/g-isolate/timeline.txt`) does not record the three `test_B3_min_{paymasterVerificationGasLimit,
verificationGasLimit_account,callGasLimit}` runs; they were re-run with the committed `scripts/run_g_isolate.sh` together with
every other isolate test: `logs/g-isolate-r2/` (timeline `logs/g-isolate-r2/timeline.txt`, full command line in each log;
e.g. `test_B3_min_paymasterVerificationGasLimit_amsterdam_isolate.log:1` =
`(cd /tmp/f4g && /tmp/fd/nightly/forge test --offline --isolate --gas-limit 100000000000 --evm-version prague --match-path
contracts/test/zz_rams2a/Rams2a.t.sol -vv --match-test test_B3_min_paymasterVerificationGasLimit --hardfork amsterdam)`), rows
identical to `logs/g-isolate/` (882,357 / 695,045 at `logs/g-isolate-r2/…:14-15`, original `logs/g-isolate/…:9-10`; 129,390 / 823,722 at r2 `…verificationGasLimit_account…:14-15`, original `:9-10`;
4,715 / 118,354 / 232,071 at r2 `…callGasLimit…:14-16`, original `:9-11`). Full diff vs §4.3:
[`g_cmp_isolate_vs_noisolate.md`](g_cmp_isolate_vs_noisolate.md)). Each external call of the test becomes its own
transaction, so the state the setup wrote is committed before `handleOps` runs — the on-chain/B-layer situation (the
warm/fresh-slot explanation of the difference is not traced, see §0). Not applicable to B4 (direct `postOp` after a separate validation call; in reality both are in one tx).

| measurement | `--no-isolate` (§4.3) | **`--isolate`** |
|---|---|---|
| pmV balance / credit first op | 819,940 / 611,572 | **882,357 / 695,045** |
| v deployed SimpleAccount / initCode | 119,590 / 817,922 | 129,390 / 823,722 |
| callGasLimit 0 / 1 / 2 slots | 1,776 / 115,408 / 229,125 | 4,715 / 118,354 / 232,071 |
| min settling postOp limit balance / credit (params at floor) | 365,207 / 369,581 | **398,430 / 379,739** (non-guard failures 112 / 103) |
| W_postop at EP balance / credit | 177,106 / 279,208 | 211,106 / 291,208 |
| tuple 440k/420k/5k/340k: settles / covers | 6/6 / 6/6 | **6/6 / 6/6**; min charge − bare +30.85, min charge − fee-incl. +16.87 |
| raw-needs tuple 385k/365k/5k/336k | 6/6 settle | **4/6 settle** (balance first op and balance + 2 slots fail) |
| B5 MIN = C_POSTOP at 400k/380k, 450k/430k, 500k/480k | settle | settle; 300k/280k, 350k/330k do not |
| I9 at current defaults, balance first op / user call reverts / writes 1: charge − fee-incl. | +2.09 / +2.62 / +3.32 | **−1.28 / −0.74 / −0.01** (bare still covered: +13.26 / +13.29 / +15.56) |
| C_WRAP | 1,870 | 1,868–1,870 |
| I8/I10 (B6) | — | identical to §4.3 |

So under realistic transaction boundaries the proposed tuple still settles and covers in all six scenarios, but its margin
over the measured need is smaller than the R-AMS-2a "+15 %" claim: MIN 440,000 is **+10.4 %** over the balance first-op
settle need 398,430 (+15 % would be 458,195 → 460,000), and C_POSTOP 340,000 is +16.8 % over W 291,208. The R-AMS-2a
statement that the tested balance-mode cases at the current defaults meet the fee-inclusive target does not hold under
`--isolate` (three of the six balance rows miss it by ≤ 1.28 aPNTs).

## 5. What the claims are limited to

- B-layer numbers (`b-layer/amsterdam/*`): measured on release bytes for SP, Admin, Lens, Registry, V2 token/ext/factory,
  AOA registry, tier source. The proxies (89 B `registry-size`), xPNTsFactory v1, aPNTs (xPNTsToken v1 clone),
  GTokenStaking, MySBT, GTokenAuthorization, BLayerPriceFeed, MockAirAccount(+Factory) are test infrastructure, not the
  release list. APNTsCapped and TimelockController are not deployed in the B stack.
- R-AMS-2a G numbers: **diagnostic** (runs-200 variants). The release-byte values are §4.3 (same semantics) and §4.4
  (`--isolate`). R-AMS-2a §6 deployment gas used release init code (by resolve.log + §2.2) and is not affected.
- G mocks (V55Registry, V55PriceFeed, V55APNTs) are not release contracts in either run; the real Registry, aPNTs and
  APNTsCapped are not exercised by the G fixture.
- In-repo suite numbers cited by R-AMS-2a (e.g. `PostOpBound` 291,579 / 379,783) come from in-repo tests that also create
  contracts with `new`; they were **not re-run** with artifact bytes.

## 6. Files

| path | content |
|---|---|
| `artifacts/` | the rc.4 forge-1.7.1 artifact JSONs: release list (shipped + `registry-size` variant each), Registry, ERC1967Proxy, SimpleAccount(+Factory) (both variants), TimelockController, MockAirAccount(+Factory); the G re-run's `f4art/` (not committed) = eight of these files, mapping in §4.2, sha256 in `checksums/f4art.sha256.txt` |
| `git-diff-rc4-vs-main.txt` | `git diff --name-status fbd74fb1 5ae59926` + the tree / blob hashes (§1) |
| `g_delta.md` | per-value gas deltas, release bytes vs R-AMS-2a (§4.3) |
| `identity.json` | consolidated: release list (10) with full identity + tag-record equality, other key contracts, canonical EntryPoint, cross-build equality (40 variants), executed-bytes mapping for G (both runs) and B (runtime + creation) |
| `identity-rc4-forge171-default.json`, `identity-rc4-nightly-{prague,cancun}.json` | raw per-variant identity of each build (`scripts/identity.mjs`) |
| `b-onchain/` | B re-deployment: `calibration.{json,log}`, `deploy.{json,log}`, `deploy-receipts.json`, `receipts.log`, `setup.{json,log}`, `onchain-identity.{json,txt}`, `creation-match.{json,txt}`, `versions.txt` |
| `g-dump-original-fixture/`, `g-dump-artifact-run/` | runtime hex dumped by the two G fixtures + `addresses.txt`; matches in `g-executed-bytecode-*.json` |
| `logs/g/` | G re-run logs (release bytes, `--no-isolate`), control log, `timeline.txt` |
| `logs/g-isolate/` | the same under `--isolate`, plus `test_F2_matrix` (used by R2-F2), `timeline.txt` |
| `logs/g-r2/`, `logs/g-isolate-r2/`, `logs/rerun-check.txt` | reproduction with the committed `run_g.sh` / `run_g_isolate.sh` (command line in every log); R2A rows identical to `logs/g/`, `logs/g-isolate/` |
| `g_cmp.md`, `g_cmp_isolate_vs_noisolate.md`, `g_B1_derived.txt`, `g_B8_derived.txt` | row-by-row comparisons; bare / fee-inclusive columns (`rams-2a/scratch/derive.py`) |
| `fixture/` | `artifact-run.diff`, `control-original-fixture.diff`, the fixture files used (`*.txt`) |
| `builds/` | build logs (gzip) |
| `checksums/` | tool, artifact-input and fixture sha256 records |
| `scripts/` | `identity.mjs`, `match_dump.mjs`, `cmp_g.py`, `delta_g.py`, `setup_f4g.sh`, `run_g.sh`, `run_g_isolate.sh`, `rerun_check.sh`, `build_identity.mjs`; B side: `script/b-layer/f4-onchain-run.sh`, `f4-identity-onchain.mjs`, `f4-creation-match.mjs` |

## 7. Changes vs 55cf7db7 (adversarial review)

| # | where | before | now | verified against |
|---|---|---|---|---|
| 1 | §0 G row, §4.3 | "gas numbers move by −630…+16,675" | exact per-class ranges: measured 80 down −612 … −13, 16 up (+290 … +600 ×15, +16,675 ×1), 314 zero; derived 6 down −1,123 … −1, 13 zero | `scripts/delta_g.py` → `g_delta.md` over `rams-2a/logs/scratch` vs `logs/g` |
| 3 | §4.2, §4.4, `scripts/` | isolate command not committed; `run_g.sh` hard-coded `--no-isolate`; isolate timeline lacked the three B3 `min_*` runs; B4 pattern differed from the timeline | `setup_f4g.sh`, `run_g.sh` (ISOLATE flag, command-line header per log, B4 history), `run_g_isolate.sh`; full re-run `logs/g-r2/`, `logs/g-isolate-r2/` with timelines; rows identical | `logs/rerun-check.txt` (27/27 IDENTICAL) |
| 4 | §0, §4.4 | warm / not-fresh storage stated as the cause of the isolate difference | "consistent with, not traced" | — |
| 5 | §1 tag row | "`git diff fbd74fb1 origin/main` touches … only lockfiles" | the exact 353-file breakdown; `contracts/src` `f1d39b5b` and `foundry.toml` `065d0bd7` identical | `git-diff-rc4-vs-main.txt` |
| 7 | §2.1 | CBOR tail `0xa164736f6c6343000821` | `0xa164736f6c6343000821000a` (map + length `000a`) | last 12 bytes of all 28 runtimes in `artifacts/*/*.json` |
| 8 | §1, §4.2, §6 | `f4art/` cited as if committed | mapped to the committed `artifacts/` paths; `setup_f4g.sh` recreates and sha256-checks it | `checksums/f4art.sha256.txt` vs `sha256sum artifacts/*/*.json` (8/8 match) |

No measured value in §2–§4 changed. (Items 2 and 6 of the review concern `../rams-f2/REPORT.md`.)
