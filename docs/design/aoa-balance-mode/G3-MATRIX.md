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
| W3 | On-chain admission check through real `handleOps`: 480000 admitted for the SP arm (DSR #4 on the tuple) | SP | pilot record |
| W4 | A3a go and A4 completion registered (A6-SOP §1) | author / SP | registry entries |
| W5 | RPC A/B independence registered (A6-SOP §2) | SP; DSR registers its own RPC | registry entries |

## 2. Sample protocol (DSR, fixed)

| Item | Value | Reason / source |
| --- | --- | --- |
| Triples | 50 matched triples; each has one SP, one VPM and one TPM operation; 150 included samples | A6-SOP §1.5 |
| Bundle size | `B_max = 1`: one operation per `handleOps` | single-op gas is compared; multi-op has fork evidence; bundle amortization would contaminate paired differences |
| SP mode | all BALANCE, community credit policy OFF | paper pre-registration, Workflow C; collector and validator require OFF |
| CREDIT | not sampled on chain; CREDIT gas comes only from fork/local evidence; the paper makes no on-chain CREDIT claim | DSR |
| Operators | the deployer `0xb560…df0E` only. Anni `0xEcAA…33c9` stays paused, gets no V2 token and no funding | no multi-operator comparison is pre-registered; **limitation**: no on-chain evidence for multiple communities sharing the proxy |
| Accounts | SimpleAccount on all arms (factory `0x91E6…8985`, implementation `0x6864…00C2`, EntryPoint v0.7) | G3 |
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

## 4. Funding (computed in Phase C; 100 attempts per arm)

100 attempts per arm = 50 formal + 20 pilot + 30 margin for failures and exclusions.

| Item | Rule | Value |
| --- | --- | --- |
| APNTsCapped deposit for the deployer operator | ≥ 100 × maximum single reservation, computed with ceiling arithmetic at SP post = 480000 and ver on the SP_RENEW path | **TBD** |
| EntryPoint deposits | SP, VPM and TPM: each 100 × that arm's maxCost | **TBD** |
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
| Bundler | **TBD** |
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
- **Governance asymmetry.**
  - Registry, AOAProtocolRegistry and xPNTsFactoryV2 sit behind the 48 h timelock.
  - BLSAggregator and DVTValidator are Safe-only, with no timelock.
- **SETTLE changes.** `_checkGasParams` does not enforce the admission margin. Any later change of SETTLE must be
  re-validated with ⌈64S/63 + C⌉.
