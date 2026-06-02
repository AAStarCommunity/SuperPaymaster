# Final Coverage Report — Security Upgrade Verification (2026-06-02)

Verifies the 6 security fixes (C-01..C-04, H-01, H-02) deployed to Sepolia, with full
unit-test and 100%-ABI E2E coverage run against the **live on-chain contracts**.

## Executive Summary

| Layer | Result |
|---|---|
| **Unit tests (`forge test`)** | **979 passed / 0 failed / 0 skipped** (79 suites) |
| **E2E (on-chain Sepolia, `run-all-e2e-tests.sh`)** | **33 passed / 0 failed** in the full run + **2 supplementary tests** (C-02 direct-settle, H-02 switch) run separately, both pass → **35 green** (1 documented SKIP — BLS DVT cluster) |
| **Security fixes deployed + verified** | 6/6 (C-01, C-02, C-03, C-04, H-01, H-02) |
| **E2E issues found** | 4 — all root-caused, **0 contract bugs** (all test-data / SDK-signing gaps) |

All 4 E2E failures from the first full run were traced to ground truth and resolved; every
one turned out to be a *test-provisioning or test-signing* gap, and each fix's correctness
was **confirmed by the failure itself** (the gate fired exactly as designed).

---

## 1. Unit Test Coverage

```
forge test → Ran 79 test suites: 979 tests passed, 0 failed, 0 skipped
```

Covers: Registry roles/slashing, MySBT, GTokenStaking (immutable REGISTRY, slash, exit
fees), SuperPaymaster admin/pricing/credit/debt/oracle, V5.3 features (x402 settle, agent
sponsorship, EIP-1153 cache), PaymasterV4 security/optimizations, DVT/BLS validators,
ReputationSystem, xPNTsFactory, UUPS upgrade + storage-layout, and the 6 security fixes.

---

## 2. E2E Coverage (100% ABI, live Sepolia)

Runner: `script/gasless-tests/run-all-e2e-tests.sh`
Raw result: `script/gasless-tests/results/2026-06-02_18-35-04_run-all-e2e-tests.md`

| Group | Coverage | Status |
|---|---|---|
| A1/A2 | Registry roles + queries | ✅ |
| B1–B5 | Operator config / deposit-withdraw / configureOperator v2 / SP governance / dry-run + pending-debt | ✅ |
| C1/C2 | SuperPaymaster + PaymasterV4 negative paths | ✅ |
| D1/D2 | Reputation rules + credit tiers | ✅ |
| E1–E4 | Pricing/oracle / protocol fees / aPNTs exchange-rate accounting / repayDebt settlement | ✅ |
| F1–F3 | Staking queries / slash history / staking+registry admin | ✅ |
| G1–G3 | Reputation-gated + agent-identity (ERC-8004) sponsorship + credit-tier escalation | ✅ |
| H1/H2 | DVT & BLS aggregator queries / ReputationSystem scoring + BLS sync | ✅ |
| Gasless TC1 | PaymasterV4 real UserOp | ✅ |
| Gasless TC2/TC3 | SuperPaymaster xPNTs sponsorship (real UserOp) | ✅ |
| Gasless TC4 | SP credit/debt path (real UserOp) | ✅ |
| MicroPaymentChannel | open / settle / close | ✅ |
| x402 | EIP-3009 settlement + replay protection (C-03) | ✅ |
| x402 direct | **C-02** signed-auth direct settle + replay + recipient-tamper rejection | ✅ (supplementary) |
| BLS switch | **H-02** permissionless-registration switch gate (non-owner → revert) | ✅ (supplementary) |
| P2 | PaymasterV4 lifecycle (deposit/withdraw/activate) | ✅ |
| X1 | xPNTs token admin (limits/spenders/exchange-rate) | ✅ |

**Total: 33 PASS / 0 FAIL** in the full run, **+2 supplementary** (C-02 direct-settle, H-02
switch) added afterward to close E2E gaps — both pass on-chain → **35 green**. One inner
`SKIP` (H2 `syncToRegistry`) is by design — it needs a ≥3-validator DVT node cluster, an
infra dependency not reproducible from a script. The two supplementary tests are now wired
into `run-all-e2e-tests.sh` so future full runs cover them.

---

## 3. Security Fixes — Deployment & On-Chain Verification

Deployment: **SuperPaymaster UUPS upgrade** (proxy storage + operator state preserved) +
**BLSAggregator redeploy & rewire** (H-02). Funded from Anni; owner (`0xb560`) signed the
`upgradeToAndCall`.

| Fix | Severity | What it does | On-chain proof |
|---|---|---|---|
| **C-01** credit ceiling | Critical | `_creditExceeded` balance-aware: reject over-limit users unless they hold enough xPNTs balance | TC4: charge+debt 871.88 > 1000 → `CREDIT_EXCEEDED`; after repay → sponsored from balance ✅ |
| **C-02** x402 unsigned drain | Critical | `settleX402PaymentDirect` requires EIP-712 `X402PaymentAuthorization` (SignatureCheckerLib, EOA+ERC-1271) | x402 direct-settle E2E: signed auth settles 1 xPNTs ✅, replay → `NonceAlreadyUsed` ✅, recipient-tamper → `InvalidX402Signature` ✅ (drain prevented) |
| **C-03** recipient redirect | Critical | EIP-3009 `nonce = keccak256(abi.encode(payee, salt))` binds recipient | x402 test: settle 1.0 USDC to payee ✅, replay rejected ✅; swapped recipient → signature no longer recovers `from` |
| **C-04** postOp OOG | Critical | `MIN_POST_OP_GAS=200000` floor + `VALIDATION_BUFFER_BPS=1000` | Covered by unit suite + live UserOps (TC2/3/4) |
| **H-01** chunked retryPendingDebt | High | `retryPendingDebt(token,user,amount)` bounded settlement | B5 dry-run + pending-debt E2E ✅ |
| **H-02** permissionless BLS registration | High | PoP-gated `registerBLSPublicKey`; `permissionlessBLSRegistration` switch (default OFF) | BLSAggregator redeployed `0x7ec72505`, `Registry.blsAggregator()` rewired, switch=`false` ✅; BLS-switch E2E: non-owner self-register → `PermissionlessRegistrationDisabled` ✅ |

### Deployed addresses (Sepolia)

```
SuperPaymaster (proxy):  0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a
  spImpl (new):          0x52C1E6f039eb9BA50ac9Ad0D041cB07Dcf4C9AA0   (SuperPaymaster-5.3.3)
  previousSpImpl:        0x8e2d93bb9176b5796ffa91587bd2a755510c9819
BLSAggregator (new):     0x7ec72505220a13040c80EF2B895Bf3405b6ed3e9
  previousBlsAggregator: 0xCDCdb8e2b62cdDCC3918f4d120322C6eB5910276
Registry:                0xB5Fb8920F7AcD8b395934bd1F21222b32A30eF1A
GTokenStaking:           0x574820E26Acb7D9a1202708C6183d6A8aC957dA6
GToken:                  0x46B82966f8a40f0Bbb8C13aCfBA746631CC2ec72
xPNTsFactory:            0xC4f5A121c426734CC1c0DbE57f6A2Dd764E278e4
ReputationSystem:        0xDD4D6162F426998E8B8FC97D0a8a5912cd70e6E0
DVTValidator:            0xB60C82158734def92D0d2163C93927cf19b86a95
PaymasterFactory:        0x60B8f728Abca14B82a4EC72f00Ff5437e0702e90
```

---

## 4. E2E Issue Root-Cause Log

Every issue traced to root cause. **None were contract bugs** — the security gates fired
exactly as designed; the gaps were in test provisioning / test signing.

| # | Symptom | Root cause | Resolution | Proves |
|---|---|---|---|---|
| 1 | **TC2** AA34 → `USER_NOT_ELIGIBLE` | Account `0x179Faf25` had no SBT and isn't a registered agent → `isEligibleForSponsorship=false` (V5.3 dual-channel gate) | `safeMintForRole(ENDUSER)` via Registry (`--slow` to dodge the 7702 in-flight-tx limit) → `sbtHolders=true` | V5.3 eligibility gate correctly rejects un-provisioned users |
| 2 | **TC3** same | Account `0xb78ef5C8` same | same | same |
| 3 | **TC4** dryRun → `CREDIT_EXCEEDED` | Account `0xECD9C07f` carried `debt 871.88` from prior runs; `871.88 + 201 charge > 1000 credit` | Minted 1000 xPNTs → `_update` auto-repaid on mint → `debt=0` | **C-01** correctly caps over-limit debt, then sponsors from balance once cleared |
| 4 | **x402** settle reverts (status 0) | Test signed EIP-3009 over a *raw* random nonce but passed it as `salt`; C-03 derives `nonce=keccak256(payee,salt)`, so USDC signature recovery failed | Fixed test signing to derive `nonce=keccak256(abi.encode(payee,salt))` and pass `salt` (no SDK dep — uses ethers directly). aastar-sdk#39 tracks the SDK-side change. | **C-03** recipient binding works on-chain: settle succeeds with the correct nonce, replay rejected, recipient-swap breaks the signature |

### 7702 in-flight-tx caveat (operational note)

The deployer `0xb560` is an EIP-7702 delegated account; the Sepolia RPC enforces an
in-flight-tx limit for delegated accounts. Batch `forge script` broadcasts hit
`in-flight transaction limit reached for delegated accounts` and silently fail *after*
simulation printed success. **Always run multi-tx scripts from this account with `--slow`**
(one confirmation per tx). Verify state on-chain, never trust simulation-phase logs.

---

## 5. How to Reproduce

```bash
# Unit tests
forge test                                   # 979 passed / 0 failed

# Full E2E (100% ABI) against live Sepolia — now includes the 2 supplementary tests
cd script/gasless-tests && ./run-all-e2e-tests.sh

# Individual fix proofs (run standalone)
node script/gasless-tests/test-x402-eip3009-settlement.js   # C-03 recipient binding
node script/gasless-tests/test-x402-direct-settle.js        # C-02 signed-auth direct settle
node script/gasless-tests/test-bls-permissionless-switch.js # H-02 permissionless switch gate
```
