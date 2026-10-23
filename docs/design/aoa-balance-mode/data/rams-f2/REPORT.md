# R2-F2 — one G/B parameter table for R-AMS, B6/B4 re-run, preVerificationGas on Amsterdam

DSR open item R2-F2: *"G 5.4 lists pmV 945k and initCode 925k; B uses pmV 1.15M, initCode 4.6M; the two fixtures are not
the same implementation. Unify by account/factory, cold/warm/first/subsequent, SP_RENEW/account renew, balance/credit. B6
v150k < 150,839; ~175k not re-run; c-prime only changed Rundler cap to 6M, cannot be called B6 passing. PVG, Alto estimator
anomalies/under-estimates, F1/D1/D2/D3 and fixed gas config must be stated separately. SDK/YAAA may consume candidates
offline but they are not accepted defaults."*

Date 2026-10-23. Local only (anvil nightly `926eb1d0` `--hardfork amsterdam`, in-process forge nightly), anvil public dev
keys, no public RPC; `contracts/src`, `contracts/script`, `foundry.toml`, `.github` untouched. Every chain run started with
the calibration gate (`script/b-layer/ams-calibrate.mjs`): **CALIBRATION PASS** 5/5 in `b-layer/amsterdam/d/calibration.json`,
`d-rundler-mvg6m/calibration.json`, `d-pvg/calibration.log`, `data/rams-f4/b-onchain/calibration.log`.
Bytecode identity of both lines vs rc.4: `../rams-f4/REPORT.md` (B = release bytes; R-AMS-2a G = `registry-size` variants,
re-tested with release bytes).

**Status of every value in this report: measured candidates for SDK/YAAA and bundler configuration, consumable offline.
None of them is an accepted default.**

## 0. Summary

1. **The G/B gap is a fixture gap, and it closes.** With the G fixture deployed from rc.4 release bytes and run with
   transaction isolation (`--isolate`: each `handleOps` its own transaction, as on chain and in the B layer), G and B agree on
   the SuperPaymaster side to **18 gas** for balance and SP_RENEW, fresh and warm SP (882,348 vs 882,366; 998,847 vs 998,865;
   784,428 vs 784,446; 900,927 vs 900,945). The remaining G/B differences are each a constant traced to one fixture element
   (§2): account implementation (+5,044 v), factory/account deployment model (v 823,722 vs 3.89–3.98M), credit-tier source
   (+22,039 pmV), the G operator's rate limit, and R-AMS-2a's `--no-isolate` (−62,417 pmV on the balance first op).
2. **"pmV 945k / initCode 925k" (G §5.4) vs "pmV 1.15M / initCode 4.6M" (B (c))** differ because G §5.4 took the balance
   first op only, under `--no-isolate`, on `registry-size` bytes, with a SimpleAccount proxy factory; B took the maximum over
   all cases (fresh-SP SP_RENEW 998,874) with a factory that deploys a full 2,097-byte account. Unified per-row values: §1.
3. **(d) = (c) with v 175,000 and initCode v 4,585,000**: **B6 is now included on Rundler, Alto and altoMulti**
   (1,171,398 gas, postOp ok). v + pmV = 5,735,000 does not fit Rundler's default `max_verification_gas` 5,000,000 — all four
   B4 cases are rejected at precheck; with `--max_verification_gas 6000000` B4 behaves as on Osaka (3 stake rejections,
   B4-ok included). Fitting 5M is not possible with +15 % margin (§3).
4. **PVG on Amsterdam (§4).** For the **first op through a fresh SP** the bundle tx costs more than the op's actualGasUsed
   unless PVG ≥ **52,593–52,629**. Rundler's acceptance floor is **46,152–46,200** (it under-recovers 6,409 gas on that op at
   its floor); **Alto v1.2.5 accepts PVG = 1** and then loses 52,592 gas on that op. For every other measured op (warm SP,
   second op, credit, SP_RENEW, initCode, 3-op bundle) the op's actualGasUsed exceeds the tx gasUsed by 155k–351k even at
   PVG 0 (break-even PVG negative).

## 1. Unified table (minimum per field, all other fields generous; same success predicate on both sides)

Predicate: `handleOps` does not revert, `UserOperationEvent.success`, no `PostOpRevertReason`, no prefund-too-low. pmP: the
on-chain floor `MIN_POST_OP_GAS` = 440,000 under the tuple 440k/420k/5k/340k in G and in B (c)/(d); validation rejects
lower, so "440,000" is the floor, not a need (the true settle need at floor GasParams is in the pmP note). PVG: not a
limit on chain (any PVG passes `handleOps`); the PVG column is the bundler acceptance floor and the tx-level break-even of §4.

**Sources.** G = `data/rams-f4/logs/g-isolate/test_F2_matrix_amsterdam_isolate.log` (release bytes, `--isolate`, GasParams
440k/420k/5k/340k; line numbers below) and `test_B3_*_isolate.log`; B = `b-layer/amsterdam/<run>/matrix.json` `needs`
(probe `ams-probe.mjs`, generous baseline v 1.5M / 4M initCode, call 0.5M, pmV 2M, pmP 1.5M, PVG 100k).

| # | account / factory | SP state | op of sender | flags | mode | **v** | **pmV** | **pmP** | **call** | **PVG** (accept floor; break-even) | source |
|---|---|---|---|---|---|---|---|---|---|---|---|
| G1 | SimpleAccount v0.7 (ERC1967 proxy → impl) deployed | fresh | first | — | balance | 129,390 | **882,348** | 440,000 floor (settle need 398,430) | ≤ 1,000 (empty callData) | not measurable in forge | G `:12-15`; pmP need `test_B3_min_postOp_amsterdam_isolate.log:9` |
| B1 | MockAirAccount (full contract) deployed | fresh | first | — | balance | 124,346 | **882,366** | 440,000 floor | 3,696 (`execute(0xdEaD,0,"")`) | Rundler 46,152–46,188; Alto ≥ 1; break-even **52,593–52,629** | B (b)/(c)/(d) `B9-below`; §4 |
| G2 | SimpleAccount | fresh | first | — | credit | 129,390 | 695,036 | 440,000 floor (settle need 379,739) | ≤ 1,000 | — | G `:16-19`; `test_B3_min_postOp…:13` |
| B2 | MockAirAccount | fresh | first | — | credit | 124,346 | 717,075 | 400,000 floor ((b) MIN 400k) | 3,696 | — | B (b) `B7` (the only run where B7 met a fresh SP) |
| G3 | SimpleAccount | fresh | first | SP_RENEW | balance | 129,390 | **998,847** | 440,000 floor | ≤ 1,000 | — | G `:20-23` |
| B3 | MockAirAccount | fresh | first | SP_RENEW | balance | 124,346 | **998,865** | 400,000 floor | 3,696 | — | B (b) `B5` (998,874 in (a), GasParams slot zero) |
| G4 | SimpleAccount | warm (1 op done) | first | — | balance | 129,390 | **784,428** | 440,000 floor | ≤ 1,000 | — | G `:25-28` |
| B4 | MockAirAccount | warm | first | — | balance | 124,346 | **784,446** | 440,000 floor | 3,696 | floor not probed (Rundler G1 est. 46,704–46,728); break-even < 0 (−251,143) | B (c)/(d) `B1`, `B3#1`, `B8`, `B2a#1`; §4 |
| G5 | SimpleAccount | warm | first | — | credit | 129,390 | 597,116 | 440,000 floor | ≤ 1,000 | — | G `:29-32` |
| B5 | MockAirAccount | warm | first | — | credit | 124,346 | 619,155 | 440,000 floor | 3,696 | Rundler 46,152–46,188; break-even < 0 (−155,017) | B (c)/(d) `B7`; §4 |
| G6 | SimpleAccount | warm | first | SP_RENEW | balance | 129,390 | **900,927** | 440,000 floor | ≤ 1,000 | — | G `:33-36` |
| B6′ | MockAirAccount | warm | first | SP_RENEW | balance | 124,346 | **900,945** | 440,000 floor | 3,696 | break-even < 0 (−251,119) | B (c)/(d) `B5`; §4 |
| G7 | SimpleAccount | warm | second (61 s later) | — | balance | 31,470 | 588,697 | 440,000 floor | ≤ 1,000 | — | G `:41-44` (inside 60 s: rejected, `:37-40`) |
| B7 | MockAirAccount | warm | second (prior op executed) | — | balance | 26,426 | 588,606 | 440,000 floor | 3,696 | Rundler 46,164–46,200; break-even < 0 (−251,143) | B (c)/(d) `B2-aftermath`, Alto `B9-above`; §4 |
| B7b | MockAirAccount | warm | second, same bundle | — | balance | 124,346 (simulated before op 1 executes) | 784,446 | 440,000 floor | 3,696 | — | B (c)/(d) `B2a#2` (on chain 692,445 actual) |
| G8 | SimpleAccount | — | — | account renew | — | **not available**: SimpleAccount has no renew hook in `validateUserOp` | | | | | fixture limitation |
| B8 | MockAirAccount (option A: `renewForSelf` in `validateUserOp`) | warm | first | ACCOUNT_RENEW | balance | **150,839** | 772,646 (fresh 870,566) | 440,000 floor | 3,696 | — | B (c)/(d) `B6` ((b) for fresh) |
| G9 | SimpleAccountFactory (deploys a 100 B ERC1967Proxy + `initialize`) | warm | first (initCode) | — | balance | **823,722** | 784,445 | 440,000 floor | ≤ 1,000 | — | G `:45-48`; `test_B3_min_verificationGasLimit_account_amsterdam_isolate.log:10` |
| B9 | MockAirAccountFactory (CREATE2 of the full 2,097 B MockAirAccount + `initialize` 3 slots), factory `deployments` counter already non-zero | warm | first (initCode) | — | balance | **3,885,095** | 784,491 | 440,000 floor | 3,696 | Rundler G1 est. 49,212–49,224; break-even < 0 (−249,475) | B (c)/(d) `B4-ok` |
| B9b | same factory type, counter still zero (first deployment of that factory) | warm | first (initCode) | — | balance | **3,983,015** | 784,491 | 440,000 floor | 3,696 | — | B (c)/(d) `B4-unstaked/-lowStake/-shortDelay` |

Not-isolated G values (R-AMS-2a mode, release bytes, `../rams-f4/REPORT.md` §4.3) for reference: pmV 819,940 / 611,572,
v 119,590 / 817,922, call (0 slots) 1,776.

### 1.1 Candidates derived from the table (measured × 1.15, rounded up to 5k; not accepted defaults)

| field | binding row | measured | candidate | note |
|---|---|---|---|---|
| `paymasterVerificationGasLimit` (fixed, all ops) | G3 / B3 fresh SP + SP_RENEW | 998,847 / 998,865 | **1,150,000** | same in G and B once isolated; per-scenario values in §1 if an SDK chooses by state |
| `verificationGasLimit`, deployed account, no renew | G1 / B1 | 129,390 / 124,346 | 150,000 | account-implementation dependent |
| `verificationGasLimit`, account renews in validation | B8 | 150,839 | **175,000** | (d) run: B6 included on all bundlers (§3) |
| `verificationGasLimit` with initCode, proxy-deploying factory | G9 | 823,722 | **950,000** | SimpleAccount v0.7 pattern |
| `verificationGasLimit` with initCode, full-code-deploying factory | B9b | 3,983,015 | **4,585,000** | MockAirAccount pattern; v + pmV = 5,735,000 > Rundler default 5M (§3) |
| `paymasterPostOpGasLimit` | on-chain MIN | — | = `gasParams().minPostOpGas` | true settle need (isolated) 398,430 balance / 379,739 credit; MIN 440k is +10.4 % (`../rams-f4/REPORT.md` §4.4) |
| `preVerificationGas` | §4 | 52,629 (fresh SP first op) | 65,000, or the bundler's own value if larger | binding only for the first op through a fresh SP; depends on bundler and calldata; §4 |

## 2. Every G vs B difference, by fixture element

| # | fixture element | G | B | measured effect | evidence |
|---|---|---|---|---|---|
| F-1 | transaction boundaries | R-AMS-2a: `--no-isolate` — setup, validation and `handleOps` are one transaction, so slots the setup wrote are warm (100 vs 2,100/2,600) and not fresh (no EIP-8037 state gas for them) | every op its own transaction | pmV 819,940 → 882,357 (+62,417); v 119,590 → 129,390; call 1,776 → 4,715; postOp settle need 365,207 → 398,430; W_postop 177,106 → 211,106 | `../rams-f4/g_cmp_isolate_vs_noisolate.md` |
| F-2 | contract bytes | R-AMS-2a: `registry-size` (runs 200) variants via `new` in the test | release (runs 500) | −630…−66 gas on most rows; initCode v **+16,675** (proxy 100 B vs 89 B) | `../rams-f4/REPORT.md` §4.3 |
| F-3 | account implementation | SimpleAccount v0.7: ERC1967 proxy `delegatecall` → impl, OZ ECDSA, owner SLOAD | MockAirAccount: direct contract, `ECDSA.recover`, owner SLOAD | v **+5,044** constant in both first-op (129,390 vs 124,346) and second-op (31,470 vs 26,426) rows; call for an `execute` that changes no state: 4,715 (G: `execute(writer, 0, w(_, 0))`) vs 3,696 (B: `execute(0xdEaD, 0, "")`) | rows G1/B1, G7/B7 |
| F-4 | factory / deployment model | SimpleAccountFactory: CREATE2 of a 100 B proxy + `initialize` | MockAirAccountFactory: CREATE2 of the full 2,097 B account + `initialize` (3 slots) + factory counter | v 823,722 vs 3,885,095: EIP-8037 code deposit 1,530/B → 2,097 B = 3,208,410 vs 100 B = 153,000 (Δ 3,055,410 of the 3,061,373 Δv); B4-ok vs other factories: exactly **97,920** = one fresh SSTORE (the `deployments` counter 0 → 1) | rows G9/B9/B9b |
| F-5 | credit tier source | `V55Registry` mock (`setCreditLimit`) | real Registry behind ERC1967 proxy (`setCreditTier`), read in validation: access check `reg=2/12` (2 accounts / 12 slots) | credit pmV **+22,039** constant (fresh 695,036 vs 717,075; warm 597,116 vs 619,155). Attribution to the Registry reads is from the access sets, not from a gas trace | rows G2/B2, G5/B5; `b-layer/amsterdam/d/access-check.txt` (B7) |
| F-6 | operator rate limit | `setOperatorLimits(60)`: a sender's next op inside 60 s is rejected (all four fields "fails at 5,000,000") | not set (0) | second op measurable in G only after 61 s | G `:37-44` |
| F-7 | renew hooks | SimpleAccount cannot renew in `validateUserOp` | MockAirAccount option A | account-renew row B-only | rows G8/B8 |
| F-8 | residual | — | — | 18 gas (balance, SP_RENEW, fresh and warm), 46 gas (initCode pmV), 91 gas (second op): not attributed (calldata/memory differences of `paymasterAndData`, e.g. G `maxRate = type(uint256).max` vs B 1e18, are candidates) | §1 |
| F-9 | price feed, aPNTs | `V55PriceFeed`, `V55APNTs` mocks | `BLayerPriceFeed`, xPNTsToken v1 clone | no visible effect on validation (balance rows agree to 18 gas) | — |

So G §5.4's pmV 945k came from row "balance first op" under F-1 and F-2 (820,305 × 1.15); B's 1.15M came from the maximum
over all rows (SP_RENEW on a fresh SP). G §5.4's initCode 925k (801,247 × 1.15) belongs to a proxy-deploying factory
(F-4, and F-2 lowered it by 16,675); B's 4.6M belongs to a factory that deploys the full account code. Neither is "the"
value: the initCode limit is a property of the account factory.

## 3. G1 variant (d) and (d′): B6 and every B4 case

Op gas (d): **v 175,000** (B6 need 150,839 × 1.15 = 173,465), **v with initCode 4,585,000** (max B4 need 3,983,015 × 1.15 =
4,580,468, rounded up to 5k), pmV 1,150,000, pmP 440,000; PVG 100,000, call 60,000, fees 3 / 2 gwei (fixed `g1-lib.mjs`
`GAS`). SP GasParams via `queueGasParams(440000, 420000, 5000, 340000)` → 48 h + 60 s → `executeGasParams`, read back
(`d/gasparams.json`). Commands:

```
script/b-layer/ams-g1-run.sh /tmp/bl/g1d /tmp/bl/rundler /tmp/bl/alto d
G1_DEPLOY_JSON=docs/design/aoa-balance-mode/b-layer/amsterdam/d/deploy.json script/b-layer/ams-g1-collect.sh /tmp/bl/g1d d
AMS_OUT=d-rundler-mvg6m G1_BUNDLERS=rundler RUNDLER_EXTRA="--max_verification_gas 6000000" \
  script/b-layer/ams-g1-run.sh /tmp/bl/g1d2 /tmp/bl/rundler /tmp/bl/alto d
G1_BUNDLERS=rundler G1_DEPLOY_JSON=docs/…/amsterdam/d-rundler-mvg6m/deploy.json script/b-layer/ams-g1-collect.sh /tmp/bl/g1d2 d-rundler-mvg6m
node script/b-layer/f2-summary.mjs b-layer/amsterdam/d/f2-summary.json …/c …/c-rundler-mvg6m …/d …/d-rundler-mvg6m
```

Rundler v0.11.0 `2a3db237…` and Alto v1.2.5 `45bbf341…` rebuilt from source in this session (`cargo build --release --bin
rundler`, toolchain 1.92.0, protoc 29.3; Alto `pnpm@8.15.4 install --frozen-lockfile && build:contracts && build`;
`../rams-f4/checksums/tools.sha256.txt`). Full matrices: [`d/matrix.md`](../../b-layer/amsterdam/d/matrix.md),
[`d-rundler-mvg6m/matrix.md`](../../b-layer/amsterdam/d-rundler-mvg6m/matrix.md); per-case verdicts and bundle gas:
`d/f2-summary.{json,txt}`.

| case | need v / pmV | Rundler default (5M cap) | Rundler `--max_verification_gas 6000000` | Alto v1.2.5 | altoMulti | (c) for comparison |
|---|---|---|---|---|---|---|
| **B6** account renew | 150,839 / 772,646 | ✅ **included**, 1,171,398, postOp ok | ✅ **included**, 1,171,398 | ✅ **included**, 1,171,398 | ✅ included | Rundler reject (AA26), Alto accepted-not-included |
| **B4-unstaked** | 3,983,015 / 784,491 | ❌ `-32000 precheck failed: verificationGasLimit is 5735000 but must be at most 5000000` | ❌ `-32502 entity stake/unstake delay too low` (rule) | ❌ `-32502 unstaked factory accessed factory slot 0x0` (rule) | ❌ same (rule) | same pattern (5,750,000) |
| **B4-lowStake** (0.5 ETH) | 3,983,015 / 784,491 | ❌ precheck (same) | ❌ `-32502 entity stake/unstake delay too low` | ✅ included 5,015,419 (D1) | ✅ included (D1) | same |
| **B4-shortDelay** (3600 s) | 3,983,015 / 784,491 | ❌ precheck (same) | ❌ `-32502 entity stake/unstake delay too low` | ✅ included 5,015,419 (Alto default delay) | ✅ included (D1, 86400 configured) | same |
| **B4-ok** (1 ETH / 86400 s) | 3,885,095 / 784,491 | ❌ precheck (same) | ✅ **included** 4,917,499 (bundle tx 4,568,024 / limit 6,616,036) | ✅ included 4,917,499 | ✅ included | Rundler precheck; Alto included |

Per bundler (20 ops each + B10 estimate-only): (d) Rundler 11 included / 3 accepted-not-included (B2b, F1) / 6 rejected
(B9-below by rule, B4 ×4 precheck, B2-aftermath banned); Alto and altoMulti 16 included / 4 rejected (B3 #2, #3 D2;
B4-unstaked by rule; B2b #3 AA34). (d′) Rundler 12 included / 3 accepted-not-included / 5 rejected (B9-below and B4 ×3 by
the stake rule, B2-aftermath banned). Every included op: `success = true`, no `PostOpRevertReason`; no bundle tx reverted;
bundle tx gas limits Rundler 1,983,747–5,907,179 (d) / –6,616,036 (d′), Alto 1,890,932–6,301,661, all below 2^24. §3.4
access check: 101 simulations in (d), 34 in (d′), all checked, OUTSIDE 0 / FORBIDDEN 0 (`d/access-check.txt`,
`d-rundler-mvg6m/access-check.txt`).

**B6 now passes** with v 175,000 on all three bundlers (it was the v limit, not the cap). **Fitting Rundler's default 5M:**
Rundler checks v + pmV (the precheck message reports the sum 5,735,000). With pmV fixed at 1.15M, v with initCode would have
to be ≤ 3,850,000 < the 3,983,015 need. Even with pmV equal to the initCode op's own need (784,491 warm / 882,420 fresh SP)
and v at +15 % (4,580,468), the sum is 5.36M–5.46M. The raw needs sum to 4,767,506 (warm) / 4,865,435 (fresh SP), so 5M
leaves at most +4.9 % / +2.8 % combined margin. **For a full-code-deploying factory the bundler cap needed is ≥ 5,735,000
(6,000,000 used here).** For a proxy-deploying factory (row G9) 950,000 + 1,150,000 = 2.1M fits the default.

## 4. preVerificationGas actually required on Amsterdam (B stack)

Method (`script/b-layer/ams-pvg-run.sh` → `b-layer/amsterdam/d-pvg/`): fresh anvil, calibration PASS, the (d) deploy +
governance + setup, then from one snapshot (`script/b-layer/ams-pvg.mjs`):

- **direct**: `handleOps` sent by anvil dev EOA #8 (beneficiary = itself, already funded, so no new-account charge), PVG
  100,000; per bundle: tx gasUsed vs Σ actualGasUsed. EntryPoint pays the beneficiary Σ actualGasUsed × price; the tx costs
  gasUsed × price (both in gas units here). **Break-even PVG per op** = PVG − (Σ actualGasUsed − gasUsed) / n. (The second
  field in the JSON, `gapNoPVGperOp`, is algebraically the same number.) actualGasUsed includes EntryPoint's 10 % penalty on
  unused call + postOp gas, which the beneficiary receives.
- **bundler**: per bundler the smallest PVG `eth_sendUserOperation` accepts (binary search over [0, 400,000]; each accepted
  op removed with `debug_bundler_clearState`), the rejection text at min − 1, then the op submitted **at that minimum**,
  bundled, and the bundle tx measured as above.

| op (B stack, (d) gas) | direct: tx gasUsed | Σ actualGasUsed (PVG 100k) | surplus | **break-even PVG / op** | Rundler accept floor (messages) | Rundler: bundled at floor → tx gasUsed / actualGasUsed / **bundler gain** | Alto accept floor | Alto: bundled at floor → gain |
|---|---|---|---|---|---|---|---|---|
| b1 first op, **fresh SP** | 1,207,254 | 1,254,625 | 47,371 | **52,629** | 46,184 accepted (floor 46,152–46,188) | 1,207,218 / 1,200,809 / **−6,409** | **1** (`0` → "user operation gas limits must be larger than 0") | 1,207,218 / 1,154,626 / **−52,592** |
| b1 second op | 511,826 | 862,945 | 351,119 | −251,119 | 46,200 (46,164–46,200) | 511,802 / 809,145 / +297,343 | 1 | +251,144 |
| b8 first op, warm SP | 805,562 | 1,156,705 | 351,143 | −251,143 | — | — | — | — |
| b7 credit first op (warm SP) | 720,385 | 975,378 | 254,993 | −154,993 | 46,187 (46,152–46,188) | 720,361 / 921,565 / +201,204 | 1 | +155,018 |
| b5 SP_RENEW (warm SP) | 922,085 | 1,273,204 | 351,119 | −251,119 | — | — | — | — |
| 3-op bundle b3a/b3b/b3c | 2,125,513 | 3,244,934 | 1,119,421 | −273,139 | — | — | — | — |
| initCode b4-ok | 4,568,024 | 4,917,499 | 349,475 | −249,475 | not reachable: precheck v+pmV 5,735,000 > 5M at every PVG | — | 1 | +249,488 |

Sources: `d-pvg/pvg-direct.{json,log}`, `d-pvg/pvg-rundler.{json,log}` (+ `pvg-rundler-bundler.log`),
`d-pvg/pvg-alto.{json,log}` (+ `pvg-alto-bundler.log.gz`, > 5 MB so gzipped). The same surplus appears in every G1 bundle of (c) and (d)
(`d/f2-summary.txt`; e.g. fresh-SP B9 47,371–47,383 with break-even 52,617–52,629; all later single-op bundles
254,993–351,155 surplus).

Per bundler:

- **Rundler v0.11.0** (default config, chain spec `rundler-chain-31337.toml`): acceptance floor 46,152–46,200 (it moves by a
  few dozen gas with the signature bytes, since the PVG field is part of the calldata it prices); its own estimate in the G1
  runs 46,704–49,224. Both are **below the 52.6k a fresh SP's first op needs**; at its floor Rundler loses 6,409 gas on that
  op. For every other op it is over-paid.
- **Alto v1.2.5** (safe mode, defaults): **no PVG floor beyond > 0**; its estimate is 54,969–56,856 (covers 52.6k) but it
  admits and bundles ops with PVG 1, losing 52,592 gas on a fresh SP's first op.
- Why every op after the first is over-paid by ≥ 155k is **not decomposed** here: PVG 100k + the 10 % penalty on ~400k
  unused postOp/call gas (~40k) explain part; the rest is consistent with the EIP-8037 refill of the validation-time lock
  record cleared in postOp being credited outside EntryPoint's measured segments (R-AMS-2a §3.3) and receipt-level refunds,
  but this was not traced.

## 5. Separately: F1 / D1 / D2 / D3, estimator anomalies, fixed gas config

These are bundler behaviours, not gas parameters; all reproduce in (d) exactly as in (c) (`d/matrix.md`, `d/*-errors.log`,
`d/rundler-events.log`).

| id | what | (d) / (d′) |
|---|---|---|
| **F1** | Rundler B2b: 3 ops of one sender accepted, bundle-time `FailedOp(2,"AA34 signature error")` → empty bundle → paymaster removed; next op `-32504 paymaster … throttled or banned` | reproduces in (d) and (d′) |
| **D1** | Alto accepts SP stake 0.1 ETH (B9-below) and factory 0.5 ETH / 3600 s (B4) even as altoMulti (`--min-entity-stake 1e18 --min-entity-unstake-delay 86400`) | reproduces |
| **D2** | Alto rejects B3 #2/#3 with `unstaked account accessed <b3a> slot 0x0` | reproduces |
| **D3** | default Alto bundles B2a in 2 txs (altoMulti 1 tx) | reproduces |
| E-1 (AMS-4) | Alto `eth_estimateUserOperationGas` throws `Hex size (33) exceeds padding size (16)` after the first included op | 41 occurrences in `d/alto-errors.log` |
| E-2 | Alto pmV estimate 497,292 < need 882,366 (B9-below), replay → AA34; supplied pmP returned as input × 1.2 (528,000); pm-omitted pmP 137,851 < MIN | as (c) |
| E-3 | Rundler never returns `paymasterPostOpGasLimit`; pm-omitted pmV 60,857–62,840 → AA34 | as (c) |
| E-4 | **Rundler B6 estimate under-estimates v**: supplied-shape v 145,458 < need 150,839, replay → `AA26 over verificationGasLimit` (the op itself carried 175,000 and was included) | (d) |
| E-5 | Rundler PVG floor (46.2k) and estimate (≤ 49.2k) below the fresh-SP break-even 52.6k; Alto accepts PVG 1 | §4 |
| E-6 | Alto (c): accepted B6 at v 150,000 and could not bundle it (`AA26` at bundle-time `eth_estimateGas`) | not re-observed in (d) (v 175k) |

**Fixed gas config of the G1 harness** (`script/b-layer/g1-lib.mjs` `GAS`, overridden per variant by `G1_GAS_JSON`):
callGasLimit 60,000, preVerificationGas 100,000, maxFeePerGas 3 gwei, maxPriorityFeePerGas 2 gwei in every variant;
(c) v 150,000 / initCode 4,600,000 / pmV 1,150,000 / pmP 440,000; (d) v 175,000 / initCode 4,585,000 / pmV 1,150,000 /
pmP 440,000; MIN 440,000 in both. The probe's generous baseline: v 1.5M (4M with initCode), call 0.5M, pmV 2M, pmP 1.5M,
PVG 100k, tx gas 16M, fee 0.1 gwei.

## 6. Not done / limits

- G has no account-renew row (SimpleAccount has no hook) and no PVG (forge has no tx receipt); B has no SimpleAccount row
  (the harness uses MockAirAccount). A SimpleAccount-based B run was not done.
- B's pmP column is the MIN floor; the B probe does not search below MIN. The true settle need is from G (`--isolate`).
- The +22,039 credit difference is attributed to the real Registry's credit-tier reads by access sets, not by a gas trace;
  the 18 / 46 / 91-gas residuals are not attributed.
- The PVG surplus of non-first ops is not decomposed (§4). PVG under a bundle mix with a fresh beneficiary, an L2 chain spec
  or Rundler's `pre_verification_gas_accept_percent` other than default was not measured.
- Rundler's PVG acceptance for the initCode op could not be measured at the default cap (precheck first).
- Alto's B6 admission at v 150k (E-6) and the Alto estimator throw (E-1): root cause not determined.
- No geth cross-check; anvil nightly is the calibrated engine.

## 7. Files

| path | content |
|---|---|
| `b-layer/amsterdam/d/` | variant (d), all three bundlers: matrices, results, cases/bundler logs, traces, access check, deploy + receipts, gasparams, setup, calibration, `f2-summary.{json,txt}` (verdicts + bundle gas for c, c′, d, d′) |
| `b-layer/amsterdam/d-rundler-mvg6m/` | (d′) Rundler with `--max_verification_gas 6000000` |
| `b-layer/amsterdam/d-pvg/` | §4: `pvg-{direct,rundler,alto}.{json,log}`, bundler logs, deploy/setup/gasparams/calibration |
| `data/rams-f4/logs/g-isolate/` | G rows (`test_F2_matrix`, `test_B3_*`) |
| `script/b-layer/ams-g1-run.sh` (variant d), `ams-pvg.mjs`, `ams-pvg-run.sh`, `f2-summary.mjs` | scripts added/changed for this item |
