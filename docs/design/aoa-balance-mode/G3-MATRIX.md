# G3 sampling matrix (draft)

Status: **draft, not frozen**. The sample protocol in §2 is DSR's decision (2026-11-01; DSR owns it per the README split
and the paper pre-registration). Fields marked **TBD** are filled from chain read-backs and the pilot before the freeze.
Sampling starts only after the freeze, and nothing in this matrix changes after it. Changes before the freeze are
reported to DSR. Formal collection follows `script/a6-collector/A6-SOP.md`.

## 1. Window preconditions (all before the freeze)

| # | Precondition | Owner | Evidence |
| --- | --- | --- | --- |
| W1 | Pre-sampling manifest Phases A–D executed and fully read back, including the Registry acceptance (+48 h) | SP | manifest run records; DSR independent read-back |
| W2 | P-price: before each batch, `cachedPrice.updatedAt + priceStalenessThreshold − now ≥ batch duration + 60 s` for SP; TPM `cachedPriceTimestamp + priceMaxAge` likewise; refresh first if short (SP `updatePrice()`, TPM `updateCachedPrice(true)`; never from the deployer) | DVT keeper (SP); sampler (in-batch) | per-batch read-back rows |
| W3 | On-chain admission boundary for the SP arm (DSR #4 on the tuple): 480000 admitted through real `handleOps`; 479999 rejected, checked with `eth_call` against real chain state (no gas spent) | SP | pilot record |
| W4 | A3a go and A4 completion registered (A6-SOP §1) | author / SP | registry entries |
| W5 | RPC A/B independence registered (A6-SOP §2) | SP; DSR registers its own RPC | registry entries |
| W6 | Every item of A6-SOP "SP TODO before formal A6" is done, each with a DSR acceptance record: remote A/B collection with real account preparation (no `ANVIL_KEYS`, no `anvil_*`), RPC independence evidence, dual raw request/response archive, per-operation evidence package, exclusion validation, freeze and sampling flow. The DSR re-fetch tooling is DSR's (`scripts/aoa_m3_refetch.py` for receipts/UOE; DSR writes the state deep-check) | SP (collector); DSR (re-fetch) | DSR acceptance per item |
| W7 | Whether the DVT repository is frozen again before the window: put on the author's decision card (DSR recommends freezing) | author | decision record |

## 2. Sample protocol (DSR, fixed)

| Item | Value | Reason / source |
| --- | --- | --- |
| Triples | 50 matched triples; each has one SP, one VPM and one TPM operation; 150 included samples | A6-SOP §1.5 |
| Task | the same ERC-20 transfer on all three arms, as pre-registered: `execute(T, 0, transfer(R, 1 unit))`. T is a plain ERC-20 test token deployed in Phase C (not aPNTs or xPNTs); R is fixed. The sender and R both hold nonzero T balances before the window (warmed settlement state), enough for 100 attempts × 3 arms. The `exec-revert` fixture is not a formal sample | paper pre-registration ("same ERC-20 transfer task"). The collector's current empty `execute(0x…dEaD, 0, "0x")` is replaced; the pre-registration is not changed |
| Bundle size | `B_max = 1`: one operation per `handleOps` | single-op gas is compared; multi-op has fork evidence; bundle amortization would contaminate paired differences |
| Arm order | rotates by triple index: order `(i mod 3)` cycles SP→VPM→TPM, VPM→TPM→SP, TPM→SP→VPM (replaces the fixed order at `collector.mjs:635`) | near-zero-cost defence against order effects |
| SP mode | all BALANCE, community credit policy OFF | paper pre-registration, Workflow C; collector and validator require OFF |
| CREDIT | not sampled on chain; CREDIT gas comes only from fork/local evidence; the paper makes no on-chain CREDIT claim | DSR |
| Operators | the deployer `0xb560…df0E` only. Anni `0xEcAA…33c9` stays paused, gets no V2 token and no funding | no multi-operator comparison is pre-registered; **limitation**: no on-chain evidence for multiple communities sharing the proxy |
| Accounts | SimpleAccount on all arms (factory `0x91E6…8985`, implementation `0x6864…00C2`, EntryPoint v0.7), with SimpleAccount rebuild evidence (source build matches the deployed factory/implementation runtime) | G3 |
| Failures | every attempt is kept, including AA32, unsent and excluded ones, each with an `exclusionReason` and replacement links (`replaces` / `replacedBy`) | DSR (M3) |

## 3. Gas-limit freeze rule (pre-registered)

- A separate pilot runs first; it is not counted in the 50 triples. Each arm runs ≥ 5 operations, cold and warm.
- For each arm, `callGasLimit` and `paymasterPostOpGasLimit` = ⌈pilot upper bound × 1.15⌉. This is a uniform 15%, the
  same basis as the existing fixtures.
- SP `paymasterPostOpGasLimit` = max(480000, that value), because the chain enforces `minPostOpGas = 480000`. If the
  floor binds, that is a deviation from the uniform rule; it is disclosed here and in the paper, and the EntryPoint
  penalty is reported as measured.
- The pilot results and frozen values are entered here before formal sampling. They are not adjusted afterwards.

| Arm | callGasLimit | verificationGasLimit | paymasterVerificationGasLimit | paymasterPostOpGasLimit | preVerificationGas |
| --- | --- | --- | --- | --- | --- |
| SP | **TBD** (pilot) | **TBD** | **TBD**, including the SP_RENEW path | max(480000, **TBD**) | **TBD** |
| VPM | **TBD** | **TBD** | **TBD** | **TBD** | **TBD** |
| TPM | **TBD** | **TBD** | **TBD** | **TBD** | **TBD** |

The sampler's current `PM_GAS.SP = {ver: 400_000n, post: 200_000n}` (`collector.mjs:220`) is rejected by
`validate.mjs:547` once the tuple is active (post must be ≥ the on-chain `minPostOpGas`). It is replaced by the frozen
values above, read back from chain and recorded in the pin. The `aoa-m3-receive` positive control is updated with it.

## 3a. Fee caps (DSR 2026-11-01; all three arms, pilot included)

| Item | Value | Note |
| --- | --- | --- |
| `maxFeePerGas` | **5 gwei** for all three arms; `collector.mjs` `MAX_FEE_CEILING` is changed to match | at the old 20 gwei the SP reservation is about 5,712–6,216 aPNTs, above `maxSingleTxLimit` 5000, so the SP arm would be rejected. At 5 gwei it is about 1,430–1,550 |
| `maxPriorityFeePerGas` | **1 gwei**, the same for all three arms | Sepolia base fee read at tens of wei. DSR sampled four points; one was about 0.96 gwei about 200,000 blocks earlier (not a peak). 5 gwei leaves about 5× headroom. Before the window the base fee is re-read over a contiguous range |
| Rule | if the base fee exceeds the cap and operations cannot be included, pause the window and wait for it to fall. The attempts are kept. The cap is not changed | — |

Fees do not change gas usage, only the reservation and the cost. The paper compares gas only.

## 4. Funding (computed in Phase C; 100 attempts per arm)

100 attempts per arm = 50 formal + 20 pilot + 30 margin for failures and exclusions.

| Item | Rule | Value |
| --- | --- | --- |
| APNTsCapped deposit for the deployer operator | ≥ 100 × maximum single reservation, computed with ceiling arithmetic at maxFeePerGas 5 gwei, SP post = 480000 and ver on the SP_RENEW path | **TBD** (≈ 100 × 1,430–1,550) |
| EntryPoint deposits | SP, VPM and TPM: each 100 × that arm's maxCost at 5 gwei | **TBD** (SP ≈ 1.3 ETH at about 2.59 M gas; all three ≈ 2–3 ETH; the deployer holds 12.16 ETH) |
| User xPNTs (V2) balance | 100 × maximum single reservation; check `maxSingleTxLimit` (default 5000e18) ≥ the maximum single reservation | **TBD** |
| Recompute trigger | if the pilot freezes SP post above 480000, recompute. If funds are short, STOP; do not top up mid-sampling | — |

The margin is deliberately wide (testnet). The surplus remains and is read back; it does not affect the gas measurement.

## 5. Operator configuration (Phase C)

- The deployer deploys its V2 token: `xPNTsFactoryV2.deployxPNTsToken(name, symbol, communityName, communityENS,
  exchangeRate, paymasterAOA = 0)`. This requires COMMUNITY (read back true) and is allowed once per community.
- `configureOperator(V2 token, treasury)` reconfigures in place: the deployer holds PAYMASTER_SUPER and COMMUNITY (read
  back true), and there is no "already configured" check.
- Read-backs before and after: aPNTs balance, `maxSingleTxLimit`, `minTxInterval`. If `minTxInterval` constrains the
  sampling cadence, the cadence is recorded here.
- Credit policy: the V2 default is OFF; the factory asserts `creditPolicy() == 0`. Read back `creditPolicy == 0` and
  `pendingPolicyEta == 0`; no queue/execute.

## 6. Registered identities (A6-SOP §1.4; filled at the freeze)

| Field | Value |
| --- | --- |
| Window id | **TBD** |
| Chain | Sepolia (11155111), engine Amsterdam (nightly `4e8874b` for rehearsal) |
| EntryPoint | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| SP proxy | `0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9` (5.5.0 after Phase B) |
| VPM / TPM | **TBD** (from `deploy-baselines.mjs` in Phase C) |
| Senders | **TBD** (SimpleAccount instances) |
| Bundler | a dedicated EOA calling `handleOps` directly (`collector.mjs:527`), shared by all three arms; not D, N, A or E; **TBD** address |
| Task token T / recipient R / `callDataHash` | **TBD** (Phase C) |
| Sampling seed, list and command | **TBD** (committed and frozen before the deep check, A6-SOP §6; DSR) |
| RPC A/B | **TBD** (DSR picks its own set as well) |
| DVT final configuration | **TBD** |
| Gas tuple | `(480000, 450000, 5000, 450000)` |
| Passport and evidence mapping | **TBD** |
| Source/config pins and SHA-256 | **TBD** (frozen tag) |

## 7. Disclosures that this matrix carries into the paper

- **Test multisig.** Both testnet Safe signers were controlled by one operator.
- **Floor deviation.** The 480000 floor deviates from the uniform 15% rule wherever it binds.
- **Token-swap buffer.**
  - The swap needs an operational pre-mint of the 0.1e18 buffer (manifest B2a). This is a contract-design constraint of 5.5.0.
  - The old token's 0.1e18 stays stranded in SP.
- **Guardian slash.** The evidence is fork state construction plus source-level tests. The fraud-proof path is not
  claimed to have been exercised on chain.
- **Scope of the on-chain sample.** CREDIT is not sampled on chain, and no multi-operator data is collected.
- **Bundler.** No public bundler and no ERC-7562 simulation. Operations are submitted by an EOA calling `handleOps`;
  public-bundler compatibility is not claimed.
- **TPM baseline.**
  - F1Oracle is a constant 1:1 controlled oracle; the paper compares gas only, not user fees.
  - The gas difference against a real Chainlink path is quantified on a fork, and the result goes into this matrix.
  - Whether TPM's postOp refreshed its price (`postOpRefreshed`) is decided from the trace. Triples where it is true
    are excluded and counted.
- **Governance asymmetry.**
  - Registry, AOAProtocolRegistry and xPNTsFactoryV2 sit behind the 48 h timelock.
  - BLSAggregator and DVTValidator are Safe-only, with no timelock.
- **SETTLE changes.** `_checkGasParams` does not enforce the admission margin. Any later change of SETTLE must be
  re-validated with ⌈64S/63 + C⌉.
