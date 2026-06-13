# SuperPaymaster — Capability Map

Maps each product capability to the functions that implement it and the E2E test script that exercises it on-chain. The test scripts under [`script/gasless-tests/`](../../script/gasless-tests/) are the best call examples — they build, sign, and submit real transactions on Sepolia.

For exact signatures, selectors, params, and access control see [`reference.md`](./reference.md); for a flat selector index see [`selectors.md`](./selectors.md).

SuperPaymaster runs two sponsorship modes:
- **AOA+ (shared)** — one `SuperPaymaster` routes gas for many operators, priced in a canonical aPNTs (`APNTS_TOKEN`), users pay community tokens (xPNTs).
- **AOA (independent)** — per-community `PaymasterV4` instances deployed via `PaymasterFactory` (EIP-1167 minimal proxies).

---

## 1. Gasless gas sponsorship — SuperPaymaster (AOA+)

The paymaster pays the EntryPoint ETH gas; the user's community token (aPNTs/xPNTs) is burned to cover it. Dual-channel eligibility: SBT holder OR registered ERC-8004 agent.

| Function | Role |
|---|---|
| `validatePaymasterUserOp` / `postOp` | EntryPoint-driven validation + settlement (burn or debit) |
| `configureOperator(xPNTsToken, treasury)` | register an operator's community token + treasury |
| `deposit(uint256)` / `depositFor` / `withdraw` | operator funds its aPNTs balance (in `APNTS_TOKEN`) |
| `isEligibleForSponsorship(address)` | SBT-or-Agent gate |
| `operators(address)` | read operator config + balance |

**Tests:** [`test-case-2-superpaymaster-xpnts1-fixed.js`](../../script/gasless-tests/test-case-2-superpaymaster-xpnts1-fixed.js), [`test-case-3-superpaymaster-xpnts2.js`](../../script/gasless-tests/test-case-3-superpaymaster-xpnts2.js); operator admin in `test-group-B*`.

## 2. Credit-based sponsorship (overdraft / debt)

When a user can't cover the charge from xPNTs balance, the operator extends credit up to a per-user ceiling; debt is recorded in postOp instead of burning.

| Function | Role |
|---|---|
| `getCreditLimit` / `getAvailableCredit` | read credit ceiling / remaining |
| `repayDebt` | settle recorded debt |
| `_creditExceeded` (internal, C-01) | gate: total debt + this charge must stay within ceiling |

**Tests:** [`test-case-4-superpaymaster-credit-path.js`](../../script/gasless-tests/test-case-4-superpaymaster-credit-path.js), `test-group-D2-credit-tiers.js`, `test-group-I1-credit-ceiling-h1.js`.

## 3. x402 Agent payment settlement

Facilitator-submitted settlements with a fee split, used for agent-to-service micropayments.

| Function | Role |
|---|---|
| `settleX402Payment(...salt, signature)` | EIP-3009 path (USDC native) |
| `settleX402PaymentDirect(...nonce, signature)` | direct xPNTs path (C-02 recipient-bound signature, drain-proof) |
| `facilitatorFeeBPS` / `operatorFacilitatorFees` / `facilitatorEarnings` | fee config + accrual |
| `x402SettlementNonces` / `x402NonceKey` | replay protection |

**Tests:** [`test-x402-eip3009-settlement.js`](../../script/gasless-tests/test-x402-eip3009-settlement.js), [`test-x402-direct-settle.js`](../../script/gasless-tests/test-x402-direct-settle.js).

## 4. MicroPayment streaming channel

Off-chain cumulative vouchers, on-chain open/settle/close (separate `MicroPaymentChannel` contract).

| Function | Role |
|---|---|
| `openChannel(payee, token, deposit, salt, authorizedSigner)` | lock a deposit |
| `settleChannel(channelId, cumulativeAmount, signature)` | pay out a signed cumulative voucher |
| `closeChannel(channelId, cumulativeAmount, signature)` | final settle + refund the payer |
| `getChannel(channelId)` | read channel state |

**Tests:** [`test-micropayment-channel.js`](../../script/gasless-tests/test-micropayment-channel.js).

## 5. Independent paymaster — PaymasterV4 (AOA)

Per-community paymaster; gas debited from a per-user token deposit ledger (no burn).

| Function | Role |
|---|---|
| `depositFor(user, token, amount)` / `withdraw` | fund a user's gas-token balance |
| `setTokenPrice(token, price)` | register/enable a gas token (USD, 8 decimals) |
| `getSupportedTokens` / `isTokenSupported` | token allow-list |
| `updatePrice` / `setCachedPrice` / `cachedPrice` | Chainlink price cache |
| `deactivateFromRegistry` / `activateInRegistry` | lifecycle pause toggle |

**Tests:** [`test-case-1-paymasterv4.js`](../../script/gasless-tests/test-case-1-paymasterv4.js), [`test-group-P2-paymasterv4-lifecycle.js`](../../script/gasless-tests/test-group-P2-paymasterv4-lifecycle.js).

## 6. Community / node management — Registry

| Function | Role |
|---|---|
| role registration + `hasRole` queries | community/node onboarding (COMMUNITY/ENDUSER/PAYMASTER roles) |
| slashing + blocklist | governance enforcement |
| `getCreditLimit` | per-user credit ceiling (consumed by SuperPaymaster) |

**Tests:** `test-group-A1-registry-roles.js`, `test-group-A2-registry-queries.js`, `test-group-F3-staking-registry-admin.js`.

## 7. Staking & slashing — GTokenStaking

Two-tier slash: `SuperPaymaster.executeSlashWithBLS` (aPNTs, operational) + `GTokenStaking.slashByDVT` (GToken, governance).

**Tests:** `test-group-F1-staking-queries.js`, `test-group-F2-slash-queries.js`.

## 8. Reputation & agent economy (V5.3 / ERC-8004)

| Function | Role |
|---|---|
| `isRegisteredAgent` + agent identity/reputation registries | ERC-8004 agent sponsorship channel |
| agent sponsorship policies (tiered BPS + daily USD cap) | per-operator agent pricing |

**Tests:** `test-group-G1-reputation-gated-sponsorship.js`, `test-group-G2-agent-identity-sponsorship.js`, `test-group-G3-credit-tier-escalation.js`, `test-group-D1-reputation-rules.js`.

## 9. DVT / BLS infrastructure

BLS12-381 aggregation + permissionless-registration switch (H-02).

**Tests:** `test-group-H1-dvt-bls-queries.js`, `test-bls-permissionless-switch.js`.

## 10. Governance & security controls

| Function | Role |
|---|---|
| `setAPNTsToken` / `executeAPNTsTokenChange` | timelocked migration of the canonical aPNTs token |
| emergency halt (H-2) | one-shot kill switch on burn/transfer paths |
| protocol fee / treasury setters | `onlyOwner` governance |

**Tests:** `test-group-B4-sp-governance.js`, `test-group-I2-emergency-halt-h2.js`.
