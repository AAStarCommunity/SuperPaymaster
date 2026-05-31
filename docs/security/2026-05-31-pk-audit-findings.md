# SuperPaymaster v5.3.3 — Pre-Mainnet Security Findings (Codex × local-model PK)

> 2026-05-31 · branch `security/pre-mainnet-hardening` · contract `SuperPaymaster-5.3.3`
>
> Method: an adversarial source audit (Codex) was run in parallel with an
> independent coverage-gap analysis (local model). **Every CRITICAL below was
> then re-verified line-by-line against the source by the local model** — none
> are taken on trust. Items Codex raised that did not survive verification, or
> that are already fixed, are listed in §"Not confirmed / already fixed".

## ⚠️ Headline

The unit/E2E suites pass, but they **do not cover** the x402 settlement, credit/debt,
and postOp-revert paths — which is exactly where the confirmed fund-loss bugs live.
"Tests pass" did not mean "no bugs"; it meant "the bugs are in untested branches".

---

## CONFIRMED — must fix before mainnet (and before enabling x402 on any network)

### C-01 · No credit/debt ceiling in `validatePaymasterUserOp` → operator drain
- **Where**: `SuperPaymaster.sol` validate body (1017–1095); credit view exists at `:797 getAvailableCredit` but is **never called** in validation.
- **Verified**: validate checks configured / paused / eligibility / blocked / rate-limit / rate-commitment / **operator** solvency — but never `getCreditLimit(user)` vs `getDebt(user)+pendingDebts`. A user with SBT/agent eligibility, 0 xPNTs and 0 credit limit can submit UserOps repeatedly; each deducts the operator and records unbounded user debt in postOp. The operator is drained by a non-paying user; the credit-limit mechanism that was meant to cap this is not enforced.
- **Fix**: in validate, require `getDebt(user) + pendingDebts[token][user] + estimatedFinalCharge <= REGISTRY.getCreditLimit(user)`. Test: credit==0 ⇒ validate reverts.

### C-02 · `settleX402PaymentDirect` pulls any user's xPNTs with no user authorization
- **Where**: `SuperPaymaster.sol:1534–1558`; auto-allowance in `xPNTsToken.sol allowance():351-359` (`autoApprovedSpenders[SP]⇒type(uint256).max`, SP added at `:604`).
- **Verified**: caller needs `ROLE_PAYMASTER_SUPER` + `approvedFacilitators[caller]`. Because SP holds an unlimited auto-allowance over **every** holder, `safeTransferFrom(victim, SP, amount)` succeeds with **no signature from the victim**. A malicious/compromised approved-facilitator can drain any community member's xPNTs to an arbitrary `to`.
- **Severity note**: gated by the community-granted facilitator role (not permissionless), but the capability — pull any user without consent — is far broader than the feature needs.
- **Fix**: require a user EIP-712 authorization binding `(from,to,asset,amount,nonce,validBefore,operator,chainId)`; or remove the direct path.

### C-03 · `settleX402Payment` recipient (`to`) is not covered by the EIP-3009 signature → redirect
- **Where**: `SuperPaymaster.sol:1500–1509`.
- **Verified**: `transferWithAuthorization(from, address(this), amount, …, signature)` (`:1505`) authorizes only `from → SuperPaymaster`. The downstream `safeTransfer(to, amount-fee)` (`:1506`) uses a **caller-supplied `to`** that the user never signed. Any party holding the user's EIP-3009 auth (e.g. lifted from the x402 flow) can settle to an attacker address.
- **Fix**: bind `to`/facilitator/fee/asset/amount/nonce/validity/chainId into a second SuperPaymaster EIP-712 signature.

### C-04 · `postOpReverted` early-returns with no reconciliation → operator overpay + `protocolRevenue` overstated + user free-ride
- **Where**: `SuperPaymaster.sol postOp`, `if (mode == PostOpMode.postOpReverted) return;` (≈:1217); refund logic that it skips is at ≈:1242-1255.
- **Verified**: validation optimistically moves `initialAPNTs` from `operator.aPNTsBalance` into `protocolRevenue`. On `postOpReverted` the function returns **before** the refund/burn/debt logic — so the operator is never refunded the unused portion, no xPNTs is burned, no debt is recorded (user pays nothing), and `protocolRevenue` stays inflated (owner can later withdraw it). Breaks the INV-03 solvency invariant. An attacker can force this with a deliberately low `paymasterPostOpGasLimit`.
- **Fix**: reject too-low `paymasterPostOpGasLimit` in validate; in the `postOpReverted` branch do a **bounded** reconciliation (no external token calls) that at minimum returns `initialAPNTs` to the operator and decrements `protocolRevenue`.

---

## CONFIRMED — High

### H-01 · Over-limit `pendingDebts` can never be retried (M-04 still open)
- **Where**: `SuperPaymaster.sol:1290-1294` (pendingDebts accumulate), `:1306-1311 retryPendingDebt`; `xPNTsToken recordDebtWithOpHash` reverts on `> maxSingleTxLimit`.
- **Verified path**: a charge `> maxSingleTxLimit` makes both `burnFromWithOpHash` and `recordDebtWithOpHash` revert; SP parks it in `pendingDebts`. `retryPendingDebt` calls `recordDebt(user, sameAmount)` → reverts again, forever. Combined with C-01 the debt is also invisible to validate.
- **Fix**: chunk retries to `<= maxSingleTxLimit`; include pendingDebts in the C-01 credit check.

### H-02 · BLS registration without Proof-of-Possession → rogue-key attack
- **Where**: `BLSAggregator.sol` register (`:215-240`) + verify (`:536-560,582-592`).
- **Assessment**: requires a malicious validator to register `Pm = xG − Σ(honest pubkeys)`; with that slot in the signerMask the reconstructed `pkAgg == xG` and the attacker alone can satisfy the pairing while `signerCount` reaches quorum. Plausible; needs validator onboarding. **Recommend deeper verification + a dedicated test** (this overlaps the BLS.sol 102-line coverage gap).
- **Fix**: require on-chain (or recorded off-chain) Proof-of-Possession at `registerBLSPublicKey`.

---

## Coverage corroboration (local-model side of the PK)

The confirmed bugs sit in the **least-tested** code (forge lcov, uncovered lines):
- `utils/BLS.sol` — **102** uncovered (→ H-02)
- `SuperPaymaster.sol` — 42 uncovered, incl. `onTransferReceived`(8), `_slash`(6), `retryPendingDebt`/`clearPendingDebt`(9), x402 settle paths, validate branches (→ C-01/C-04/H-01)
- `xPNTsToken.sol` — 21 uncovered incl. `recordDebtWithOpHash`
- `BLSAggregator.sol` — 20 uncovered

---

## Not confirmed / already fixed (did not survive verification)
- M-02 (operator keeps `isConfigured` after role exit): plausible, needs confirming role-exit doesn't clear it — flagged for follow-up, not yet verified.
- EIP-1153 transient cache: Codex found no `tload/tstore` in the audited files — **no finding**.
- Prior 2026-04-25 highs H-01/B2-N1/B2-N12 + Chainlink answeredInRound: **verified fixed** (P0-14, timelock, onlyOwner, answeredInRound check).

---

## P0 — Pre-mainnet must-fix (PK-agreed)
1. Enforce credit/debt ceiling (incl. pendingDebts) in `validatePaymasterUserOp` — **C-01**.
2. Add user EIP-712 authorization to `settleX402PaymentDirect`, or remove it — **C-02**.
3. Bind recipient/fee/operator into a second EIP-712 signature in `settleX402Payment` — **C-03**.
4. Bounded reconciliation in the `postOpReverted` branch + reject too-low postOpGasLimit — **C-04**.
5. Chunk `pendingDebts` retries to `maxSingleTxLimit` — **H-01**.
6. Require Proof-of-Possession in BLS registration + dedicated BLS.sol tests — **H-02**.

Each fix ships with a regression test that **fails on current code and passes after the fix** (the tests are also the coverage the suite is missing).
