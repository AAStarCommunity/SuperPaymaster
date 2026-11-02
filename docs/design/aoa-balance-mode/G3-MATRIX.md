# G3 sampling matrix (draft)

Status: **draft, not frozen**. The sample protocol in §2 is DSR's decision (2026-11-01; DSR owns it per the README split
and the paper pre-registration), with the resolved Phase C rulings of 2026-11-02. Fields marked **TBD** are filled from chain read-backs and the pilot before the freeze.
Sampling starts only after the freeze, and nothing in this matrix changes after it. Changes before the freeze are
reported to DSR. Formal collection follows `script/a6-collector/A6-SOP.md`.

## 1. Window preconditions (all before the freeze)

| # | Precondition | Owner | Evidence |
| --- | --- | --- | --- |
| W1 | Pre-sampling manifest Phases A–D executed and fully read back, including the Registry acceptance (+48 h) | SP | manifest run records; DSR independent read-back |
| W2 | P-price: before each batch, `cachedPrice.updatedAt + priceStalenessThreshold − now ≥ batch duration + 60 s` for SP; TPM `cachedPriceTimestamp + priceMaxAge` likewise; refresh first if short (SP `updatePrice()`, TPM `updateCachedPrice(true)`; never from the deployer) | DVT keeper (SP); O (TPM) | per-batch read-back rows |
| W3 | On-chain admission boundary for the SP arm (DSR #4 on the tuple): 480000 admitted through real `handleOps`; 479999 rejected, checked with `eth_call` against real chain state (no gas spent) | SP | pilot record |
| W4 | A3a go and A4 completion registered (A6-SOP §1) | author / SP | registry entries |
| W5 | RPC A/B independence registered (A6-SOP §2) | SP; DSR registers its own RPC | registry entries |
| W6 | Every item of A6-SOP "SP TODO before formal A6" is done, each with a DSR acceptance record: remote A/B collection with real account preparation (no `ANVIL_KEYS`, no `anvil_*`), RPC independence evidence, dual raw request/response archive, per-operation evidence package, exclusion validation, freeze and sampling flow. The DSR re-fetch tooling is DSR's (`scripts/aoa_m3_refetch.py` for receipts/UOE; DSR writes the state deep-check) | SP (collector); DSR (re-fetch) | DSR acceptance per item |
| W7 | Whether the DVT repository is frozen again before the window: put on the author's decision card (DSR recommends freezing) | author | decision record |

## 2. Sample protocol (DSR, fixed)

| Item | Value | Reason / source |
| --- | --- | --- |
| Triples | 50 matched triples; each has one SP, one VPM and one TPM operation; 150 included samples | A6-SOP §1.5 |
| Task | the same ERC-20 transfer on all three arms, as pre-registered: `execute(T, 0, transfer(R, 1 unit))`. T is a plain ERC-20 test token deployed in Phase C (not aPNTs or xPNTs); `R = 0x000000000000000000000000000000000000dEaD`. The sender and R both hold nonzero T balances before the window (warmed settlement state), enough for 100 attempts × 3 arms. The `exec-revert` fixture is not a formal sample | paper pre-registration ("same ERC-20 transfer task"). The collector's current empty `execute(0x…dEaD, 0, "0x")` is replaced; the pre-registration is not changed |
| Bundle size | `B_max = 1`: one operation per `handleOps` | single-op gas is compared; multi-op has fork evidence; bundle amortization would contaminate paired differences |
| Arm order | rotates by triple index: order `(i mod 3)` cycles SP→VPM→TPM, VPM→TPM→SP, TPM→SP→VPM (replaces the fixed order at `collector.mjs:635`) | near-zero-cost defence against order effects |
| SP mode | all BALANCE, community credit policy OFF | paper pre-registration, Workflow C; collector and validator require OFF |
| Renewal | **None. SP_RENEW is never set.** Before every SP attempt (pilot/formal), read both allowance and total-cap used counters; if either `L-used < Amax`, STOP and go through a new packet. `L=50000e18` | Resolved by DSR 2026-11-02; manifest allowance rule |
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
| SP | **TBD** (pilot) | **TBD** | **TBD**; SP_RENEW never | max(480000, **TBD**) | **TBD** |
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
The funding rules and symbol definitions come from the **Phase C funding worksheet** in
[MANIFEST-DESIGN.md](../../release/sp-upgrade-a6e/MANIFEST-DESIGN.md#phase-c--funding-and-sampling-configuration-after-6d).
That worksheet governs the calculation, deficit funding and read-back predicates; G3 remains the registry of the
chosen inputs, computed targets, actual balances, pilot consumption and final frozen values. All amounts below
are integer base units; fee cap is 5 gwei. Pre-pilot gas/outer bounds are Amsterdam fork rehearsal measurements
×1.5 (rounded up), initial SP post=480000. Register these bounds, then the pilot recomputation.
Resolved by DSR 2026-11-02: `P*=3500e8` (8 decimals); exceeding it is STOP; `e=1e18`; `Amax≤5000e18`.
`beta_A=5×Amax`, `extra_EP_j=5×M_j` (thus `beta_EP_j=6×M_j`), `beta_X=5×Xmax`,
`beta_Q=5×Qmax`, `beta_B=0.2 ETH`. Computed targets and read-backs below remain pin/pilot outputs.

| Item | Rule (Phase C worksheet) | Value |
| --- | --- | --- |
| APNTsCapped deposit for the deployer operator | `AD = 100×Amax + beta_A`; use the worksheet's nested ceiling calculation for Amax, fixed price bound and no-renewal gas bound (initial SP post = 480000). Fund the deficit and check the uint128 bound | **TBD** |
| EntryPoint deposits | Each j ∈ {SP,VPM,TPM}: `ED_j = 100×M_j + beta_EP_j`, with `beta_EP_j = M_j + extra_EP_j` and `extra_EP_j=5×M_j`. This preserves the collector's post-send deposit floor `B_max×M_j = M_j`, including attempt 100. Fund deficits; stake is separate | **TBD** (per-arm targets, deficits and read-backs) |
| User xPNTs (V2) balance | Convert aPNTs reservation units: `Xmax = ceilDiv(Amax×e,10^18)`; `XD = 100×Xmax + beta_X`. Mint deficit only with zero debt/lock/credit reservation; require `X.maxSingleTxLimit() ≥ Amax` (default 5000e18) and the per-SP-attempt used precheck; no renewal | **TBD** |
| TPM fee token Q / allowance | `QD = 100×Qmax + beta_Q`, with Qmax computed by the worksheet, including refundPostopCost and cached-price/markup checks. Mint deficit to S and approve TPM for QD; Q is separate from task token T | **TBD** |
| Task token T | Before pilot, sender S ≥ 301 and recipient R ≥ 1 smallest unit; mint exact deficits. One unit per transfer, across all three arms; R does not return T during the window | **TBD** (balances/read-backs; minimum 301/1) |
| Bundler ETH | `BD = 100×f×(H_SP+H_VPM+H_TPM) + f×sum(H_aux) + beta_B`; use outer transaction bounds and listed maintenance, without netting beneficiary reimbursements. Fund the deficit | **TBD** |
| Recompute trigger | After the pilot, apply the worksheet's remaining-attempt checks and collector deposit floor. Recompute all affected reservations, limits and balances if SP post exceeds 480000 or any other bound is exceeded. If balances suffice, DSR signs off without a transaction; any needed transaction requires STOP, a new packet, author go on its new hash and read-backs, never a mid-sampling top-up | **TBD** (consumption, remaining targets and surplus) |

The margin is deliberately wide (testnet). The surplus remains and is read back; it does not affect the gas measurement.
D funds B and O. O sends C9/C18 approval and in-window TPM refreshes; SP refresh belongs to the DVT keeper.
The packet computes D's full ETH budget, including Phase A/B deployments, stakes, EP deposits, B/O funding and gas.
If short, STOP and report the shortfall; **never reduce n**. Aggregate ETH estimates are not funding checks.

No renewal resets the used counters: `settleLocked` refunds `aReserved-charge` (`xPNTsTokenV2.sol:250–268`),
so used accumulates actual charges. Renewal would contaminate the next SP sample with first-write cost.
SP uses lock/settle (`SuperPaymaster.sol:439`); stale `_releaseLock` refunds the full reservation.
`_spendV2` (`xPNTsTokenV2.sol:162`) charges the full amount only for auto-approved non-SP transferFrom/burnFrom
spenders, absent with paymasterAOA=0. These citations carry the verified DSR source evidence.

## 5. Operator configuration (Phase C)

- The deployer deploys its V2 token: `xPNTsFactoryV2.deployxPNTsToken(name, symbol, communityName, communityENS,
  exchangeRate, paymasterAOA = 0)`. Fixed by DSR 2026-11-02: name **AOA Research Points**, symbol **xARP**,
  communityName **AOA Research**, communityENS **""**, `exchangeRate=e=1e18`. This requires COMMUNITY (read back true) and is allowed once per community.
- `configureOperator(V2 token, treasury)` reconfigures in place: the deployer holds PAYMASTER_SUPER and COMMUNITY (read
  back true), and there is no "already configured" check. Treasury is test Safe
  `0x16dF788Ed4ed1fc384e52Dc832a6a6C3A23BdeBf`; `configureOperator` only stores it
  (`SuperPaymasterAdmin.sol:142`); settlement never reads or writes it (verified DSR evidence).
- Read-backs before and after: aPNTs balance, `maxSingleTxLimit`, `minTxInterval`. If `minTxInterval` constrains the
  sampling cadence, the cadence is recorded here.
- Credit policy: the V2 default is OFF; the factory asserts `creditPolicy() == 0`. Read back `creditPolicy == 0` and
  `pendingPolicyEta == 0`; no queue/execute.
- Registration remains frozen; ENDUSER inactive or S status mismatch is STOP. No registration reopening or renewal.
  `L=50000e18`, renewal mode=0, SP_RENEW never; before every SP attempt require both `L-used ≥ Amax`.

## 6. Registered identities (A6-SOP §1.4; filled at the freeze)

| Field | Value |
| --- | --- |
| Window id | **TBD** |
| Chain | Sepolia (11155111), engine Amsterdam (nightly `4e8874b` for rehearsal) |
| EntryPoint | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| SP proxy | `0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9` (5.5.0 after Phase B) |
| VPM / TPM | **TBD** addresses from manifest Phase C; each owned by D, 1 ETH stake each; TPM cache settings 864000 s (DSR 2026-11-02) |
| Senders | One shared SimpleAccount S, **TBD** address/salt; owner O is a fresh dedicated keystore, D-funded |
| O / V | **TBD** addresses of fresh dedicated keystores; only addresses enter the packet. O sends C9/C18 approval and in-window TPM refreshes; V signs VPM |
| Bundler | a fresh dedicated keystore EOA, funded by D, calling `handleOps` directly (`collector.mjs:527`), shared by all three arms; not D, N, A or E; **TBD** address |
| Task token T / recipient R / `callDataHash` | T/hash **TBD** (Phase C); R=`0x000000000000000000000000000000000000dEaD` |
| X metadata / rate / treasury | AOA Research Points / xARP; community AOA Research, ENS ""; e=1e18; test Safe `0x16dF788Ed4ed1fc384e52Dc832a6a6C3A23BdeBf` |
| F1 provenance | F1TestToken/F1Oracle permitted on Sepolia by DSR 2026-11-02; source commit/artifacts recorded in packet; §9 card explains the "local only" header scope difference, without source changes |
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
