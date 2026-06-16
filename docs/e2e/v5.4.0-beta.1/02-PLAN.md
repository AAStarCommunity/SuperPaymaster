# 02 — PLAN (v5.4.0-beta.1 E2E Scenario ↔ TX Matrix)

> TX-Value-Verification framework, document 2 of 5.
> Each row maps one scenario to one intended on-chain call, with a **3-layer Verification** spec.
>
> **Core principle — a green receipt ≠ a proven feature.** Every row's Verification column carries:
> - **L1 Receipt**: tx mined, `status = 1` (or, for ⛔, mined-revert with the named selector).
> - **L2 State**: the precise on-chain delta that proves the feature actually happened (the load-bearing assertion).
> - **L3 Feature**: the user-facing business outcome the L2 delta implies.
>
> **Negatives (⛔) are first-class.** A ⛔ row passes ONLY if it reverts with the EXACT named reason/selector. Any other revert (or success) = FAIL.
>
> Script names reference `script/gasless-tests/` (see `run-all-e2e-tests.sh`).

## Tier A — Headline scenarios (MUST be 1:1 live, real tx)

| ID | TX (intended call) | Feature | Actor | Params | Business expectation | Verification (L1 Receipt / L2 State / L3 Feature) | Type |
|---|---|---|---|---|---|---|---|
| 1.1 | `EntryPoint.handleOps` → SP `validatePaymasterUserOp` + `postOp` + `burnFromWithOpHash` | AOA+ gasless via xPNTs (balance-pay) | Operator + AA-A | userOp, xPNTs token, opHash | User pays gas in xPNTs, no ETH | L1: handleOps status=1, `TransactionSponsored` emitted. L2: user xPNTs balance ↓ (burn), `operators[op].aPNTsBalance` ↓, `protocolRevenue` ↑, `totalTxSponsored`++. L3: gasless tx settled in community token. Script: test-case-2/3. | ✅ |
| 1.2 | SP `validatePaymasterUserOp` → `_recordDebt` / `recordDebtWithOpHash` | Credit/debt path (new user, insufficient xPNTs) | Operator + new AA | userOp, opHash, credit ceiling | Sponsor user with 0 xPNTs up to credit ceiling | L1: handleOps status=1, `DebtRecorded` emitted. L2: `debts[user]` ↑ by charge; tx sponsored despite user xPNTs balance = 0. L3: new-user onboarding without prefunding. Script: test-case-4-credit-path + D2/G3. | ✅ |
| 1.5 | `EntryPoint.handleOps` → PaymasterV4 `validatePaymasterUserOp` + `postOp`; escrow via `depositFor` | AOA independent paymaster (pre-funded escrow) | Operator + AA-A | userOp, token, escrow balance | Independent per-community paymaster pays from escrow | L1: handleOps status=1. L2: `balances[user][token]` ↓ by actual cost, `balances[treasury][token]` ↑. L3: standalone AOA paymaster works without Registry shared pool. Script: test-case-1-paymasterv4 + P2. | ✅ |
| 2.1 | `X402Facilitator.settleX402Payment` (EIP-3009 `receiveWithAuthorization`, USDC) | x402 native USDC settlement | Facilitator (deployer) | payer auth sig, recipient, amount, nonce | Off-chain-signed USDC payment settled on-chain, fee taken | L1: status=1, `X402PaymentSettled` + `ReceiveWithAuthorization` typehash consumed. L2: payer USDC ↓ amount, recipient USDC ↑ (amount − fee), `facilitatorEarnings` ↑ fee, `x402SettlementNonces[key]` set. L3: agent pays USDC gaslessly via x402. **KNOWN TX `0x878dbb0b`**. Script: test-x402-eip3009-settlement. | ✅ |
| 2.2 | `X402Facilitator.settleX402PaymentDirect` (`transferFrom` xPNTs, C-02 signed auth) | x402 direct xPNTs settlement | Facilitator + payer | C-02 auth sig, payer, recipient, amount, nonce | Settle xPNTs payment with payer's signed authorization | L1: status=1, `X402PaymentSettled`. L2: payer xPNTs ↓ amount, recipient xPNTs ↑, nonce consumed (triple-key). L3: community-token x402 micropayment. **KNOWN TX `0x3bb790b6`**. Script: test-x402-direct-settle. | ✅ |
| 3.3 | `Registry.registerRole(ENDUSER)` / `MySBT.safeMintForRole` + `updateSBTStatus` | End-user onboarding + SBT status gate | Community (Anni) | enduser addr, role, SBT status | Onboard end-user so they qualify for sponsorship | L1: status=1, role + SBT mint events. L2: `sbtHolders[user] = true`; `isEligibleForSponsorship(user) == true`. L3: only onboarded users get sponsored. Script: A1 + RegisterEnduser.s.sol. | ✅ |
| 3.4 | `EntryPoint.handleOps` with agent sender (no SBT) → SP `isEligibleForSponsorship` (`isRegisteredAgent`) | Dual-channel eligibility (SBT OR ERC-8004 Agent NFT) | Operator + agent sender | userOp from agent, no SBT | Registered agents sponsored without an SBT | L1: handleOps status=1, `TransactionSponsored`. L2: agent sender has `sbtHolders==false` yet `isEligibleForSponsorship==true` via `isRegisteredAgent`; tx settled. L3: agent economy gets gasless access through ERC-8004 identity. Script: G2-agent-identity-sponsorship. | ✅ |
| 8.3 | SP-internal `burnFromWithOpHash` then replay same opHash | Burn replay protection | SP (caller) | opHash, token, amount | One opHash → one burn, ever | L1: first burn status=1; replay tx mined-revert. L2: `usedOpHashes[opHash] = true` after first; replay reverts **`OperationAlreadyProcessed`**. L3: no double-charge / double-spend. Script: case-2/3 + C1 negative. | ⛔ (replay leg) |
| 7.1 | SP `configureOperator` / `deposit` / `withdraw` / `setOperatorPaused` | Operator config & funding lifecycle | Operator | aPNTs amount, exchangeRate, pause flag, treasury, limits | Operator manages its own pool | L1: each call status=1. L2: `operators[op].aPNTsBalance` ↑ on deposit / ↓ on withdraw; `isPaused` toggles; exchangeRate/treasury/minTxInterval stored. L3: self-service operator treasury management. Script: B1/B2/B3. | ✅ |

## Tier B — Supporting scenarios (live E2E)

| ID | TX (intended call) | Feature | Actor | Params | Business expectation | Verification (L1 Receipt / L2 State / L3 Feature) | Type |
|---|---|---|---|---|---|---|---|
| 1.3 | SP `repayDebt` | Debt repayment & exchange-rate settlement | User / payer | debt amount, xPNTs | User clears accrued debt | L1: status=1, repay event. L2: `debts[user]` ↓ to 0 (or by amount); xPNTs burned at exchange rate. L3: credit revolves. Script: E4. | ✅ |
| 1.4 | SP `postOp` over-charge refund branch | postOp over-charge refund | Operator (in postOp) | actual vs prepaid gas | Operator not over-debited when actual < prepaid | L1: handleOps status=1. L2: `operators[op].aPNTsBalance` recovers the buffer (post-refund balance > naive prepay debit). L3: accurate accounting, no operator leak. Covered indirectly in case-2/3/4. | ✅ |
| 1.6 | SP `validatePaymasterUserOp` with `exchangeRate > maxRate` | Rate-commitment / rug-pull guard | Operator + AA | userOp with rate commitment, maxRate | Reject if operator's rate exceeds user-committed max | L1: validation returns SIG_FAILURE / op mined-revert. L2: op rejected with **`DRYRUN_RATE_COMMITMENT_VIOLATED`** (dry-run) / SIG_FAILURE; no burn, no debt. L3: user protected from rate rug-pull. Script: C1 negative + B5 dry-run. | ⛔ |
| 2.3 | `X402Facilitator.settleX402Payment*` re-submit same nonce | x402 replay protection (triple-key nonce) | Facilitator | already-used nonce | Same authorization cannot settle twice | L1: replay tx mined-revert. L2: reverts **`NonceAlreadyUsed`**; no balance change on second attempt. L3: no double-settlement. Script: inside test-x402-*. | ⛔ |
| 2.4 | SP `setFacilitatorFeeBPS` + `withdrawFacilitatorEarnings` | Facilitator fee config & earnings withdraw | Owner / facilitator | feeBPS, withdraw | Facilitator configures and collects fees | L1: status=1. L2: `facilitatorFeeBPS` set; on withdraw `facilitatorEarnings[op]` → 0 and recipient balance ↑. L3: facilitator monetization. **PARTIAL — standalone withdraw not yet scripted (flag to add a dedicated script).** Script: setFacilitatorFeeBPS via config; earnings accrue in 2.1. | ✅ (partial) |
| 2.5 | `MicroPaymentChannel.open` / `topUp` / `settle` / `close` | Streaming micropayment channel | Payer / payee | deposit, top-up, settle amount | Off-chain streaming with on-chain escrow | L1: each call status=1. L2: channel state transitions (open→funded→settled→closed); escrow moves payer→payee; remainder refunded on close. L3: pay-per-use streaming. Script: test-micropayment-channel. | ✅ |
| 3.1 | `Registry.registerRole(ROLE_COMMUNITY)` + `lockStake` + `mintForRole` | Community registration | Community | role, stake, SBT | Community joins protocol | L1: status=1, `RoleRegistered`. L2: `hasRole(community, ROLE_COMMUNITY)==true`; GToken stake locked in `roleLocks`; SBT minted. L3: community can sponsor. Script: A1/A2/F3. | ✅ |
| 3.2 | `Registry.registerRole(ROLE_PAYMASTER_*)` + `_requireCommunityForPaymaster` + `configureOperator` | Operator registration | Operator | role, community link | Operator registered under a community | L1: status=1. L2: `hasRole(op, ROLE_PAYMASTER_SUPER/AOA)==true`; community prerequisite enforced; operator config created. L3: only community-backed operators sponsor. Script: A1/B1/B3. | ✅ |
| 3.5 | `Registry.exitRole` + `unlockAndTransfer` + `burnSBT` | Role exit / SBT burn / stake unlock | Role holder | role | Clean exit returns stake net fee | L1: status=1, `RoleExited(exitFee)`. L2: GToken returned = locked − exitFee; SBT burned; role revoked. L3: reversible membership. Script: F3. | ✅ |
| 4.1 | `GTokenStaking.lockStakeWithTicket` / `topUpStake` | Role stake lock + min-stake floor + top-up | Role holder | ticket, amount | Stake meets/exceeds role floor | L1: status=1. L2: `roleLocks[holder][role].amount` ↑; rejects below min-stake floor. L3: economic skin-in-the-game. Script: F1/F3. | ✅ |
| 4.4 | `BLSValidator.registerBLSPublicKey` / `setPermissionlessBLSRegistration` | BLS key registration + permissionless toggle | Validator / owner | BLS pubkey, toggle | Validators register BLS keys; owner toggles open registration | L1: status=1. L2: pubkey stored for validator; permissionless flag toggles gating. L3: DVT validator onboarding. Script: test-bls-permissionless-switch + H1. | ✅ |
| 6.1 | ReputationSystem `setRule` / `setCommunityReputation` / `setNFTBoost` | Reputation scoring & community rules | Community / owner | rule, score, boost | Configure reputation inputs | L1: status=1. L2: rule/score/boost stored and readable via getters. L3: reputation drives credit tiers. Script: D1/G1/H2. | ✅ |
| 6.2 | SP credit-tier gating + ERC-8004 `giveFeedback` in postOp | Reputation-gated sponsorship + agent feedback | Operator + agent | reputation, agent feedback | Higher reputation → higher credit; agents get on-chain feedback | L1: handleOps status=1. L2: credit tier applied per reputation; **agent feedback emission to AgentReputationRegistry NOT yet explicitly asserted (flag to add assertion).** L3: reputation economy. Script: G1/G3/D2. | ✅ (partial) |
| 7.2 | SP `setProtocolFee` / `setAPNTSPrice` / `withdrawProtocolRevenue` | Protocol economics | Owner | feeBPS, price, withdraw | Owner tunes economics, collects revenue | L1: status=1. L2: `protocolFeeBPS`, `aPNTsPriceUSD` updated within bounds; `protocolRevenue` → 0 on withdraw, recipient ↑. L3: sustainable protocol. Script: E1/E2/E3. | ✅ |
| 7.3 | SP `updatePrice` / `setCachedPrice`; query with stale cache | Oracle price update & staleness | Keeper / owner | price, timestamp | Fresh price required for ops | L1: update status=1. L2: cached price+timestamp updated; stale cache → op invalid / **`DRYRUN_STALE_PRICE`**. L3: no mispriced sponsorship. Script: E1. | ✅ (+⛔ stale leg) |
| 7.6 | SP `_creditExceeded` (C-01) + H-1 `isBlocked` | Credit ceiling enforcement (anti-drain) | Operator + user | accrued debt vs ceiling | Stop sponsoring past credit ceiling | L1: over-ceiling op mined-revert. L2: reverts on credit-exceeded; H-1 blocked user cannot drain; `debts[user]` does not exceed ceiling. L3: anti-drain protection. Script: I1-credit-ceiling-h1. | ⛔ |
| 7.7 | SP `retryPendingDebt` / `clearPendingDebt` | Pending-debt recovery | Owner | user, debt | Owner recovers/clears stuck debt | L1: status=1. L2: pending debt re-applied or cleared; `debts[user]` adjusted accordingly. L3: operational debt hygiene. Script: B5. | ✅ |
| 7.9 | PaymasterFactory `deployPaymaster` + Registry `activate/deactivate` + `addStake` + `pause` | PaymasterV4 lifecycle | Operator | salt, config | Full AOA paymaster lifecycle | L1: each call status=1. L2: EIP-1167 clone deployed; registered + active in Registry; stake added; pause toggles. L3: independent paymaster operations. Script: P2/C2. | ✅ |
| 8.1 | xPNTsFactory `deployxPNTsToken` + SP `propagateSuperPaymaster` | xPNTs deployment by community | Community | name/symbol, SP addr | Community mints its own gas token | L1: status=1. L2: clone deployed; `isXPNTs[token]==true`; SP propagated as authorized burner. L3: per-community gas token. Script: setup-gasless + X1. | ✅ |
| 8.2 | xPNTsToken `transferFrom` (non-self/non-SP), over per-spender cap, over daily limit | xPNTs transferFrom firewall + caps | User / spender | from, to, amount | Token movement constrained to firewall rules | L1: violating txs mined-revert; allowed path status=1. L2: non-self/non-SP transferFrom reverts **`UnauthorizedRecipient`**; over-cap reverts **`SingleTxLimitExceeded`**; daily limit enforced. L3: anti-abuse token firewall. Script: X1 + C1/I2 negatives. | ⛔ (firewall legs) |
| 8.4 | `X402Facilitator.settleX402PaymentDirect` without `addApprovedFacilitator` | Approved-facilitator whitelist (community opt-in) | Facilitator (not approved) | unapproved facilitator | Only community-approved facilitators settle direct | L1: unapproved tx mined-revert; approved path status=1. L2: absent approval reverts **`Unauthorized`**; after `addApprovedFacilitator` it succeeds. L3: community controls who can pull its token. Script: inside test-x402-direct-settle. | ⛔ |
| 7.5 | xPNTsToken `emergencyRevokePaymaster` then burn/transferFrom | Emergency halt | Owner | token | Kill-switch freezes token operations | L1: revoke status=1; subsequent burn/transferFrom mined-revert. L2: `emergencyDisabled==true`; burn & transferFrom revert **`EmergencyStop`**. L3: incident containment. Script: I2-emergency-halt. | ⛔ |

## Negative (⛔) assertions — consolidated checklist

Each must revert with the EXACT selector below; any other outcome = FAIL.

| ⛔ | Trigger | Required revert |
|---|---|---|
| 1.6 | exchangeRate > user maxRate | `DRYRUN_RATE_COMMITMENT_VIOLATED` / SIG_FAILURE |
| 2.3 | x402 replay (used nonce) | `NonceAlreadyUsed` |
| 8.4 | x402 direct settle by unapproved facilitator | `Unauthorized` |
| 8.2a | xPNTs transferFrom to non-self/non-SP | `UnauthorizedRecipient` |
| 8.2b | xPNTs transfer over per-spender / single-tx cap | `SingleTxLimitExceeded` |
| 7.6 | credit ceiling exceeded (C-01/H-1) | credit-exceeded revert / H-1 blocked |
| 8.3 | burn replay (reused opHash) | `OperationAlreadyProcessed` |
| 7.5 | op after emergency halt | `EmergencyStop` |
| 2.2 | x402 redirect / tampered recipient binding (C-02) | `InvalidX402Signature` |
| 7.3 | op against stale price cache | `DRYRUN_STALE_PRICE` |

## Deliberately deferred (Tier C) — NOT a silent gap

These scenarios are intentionally not run live on-chain in beta.1. Each has a stated reason and an existing alternative form of coverage. They MUST be revisited before GA.

| ID | Scenario | Reason deferred | Existing coverage |
|---|---|---|---|
| 4.2 | DVT slash of operator aPNTs (Tier-1, `executeSlashWithBLS`) | Needs BLS threshold from multiple validators; no live multi-validator fixture | Foundry unit tests under `contracts/test/modules/` |
| 4.3 | DVT slash of GToken stake (Tier-2, `slashByDVT`) | Same multi-validator BLS fixture requirement | Foundry unit tests |
| 5.1 | PolicyRegistry spend policy (`checkPolicy`/`recordSpend`) | Standalone — NOT wired into paymaster validate path on main; needs consumer auth | Decision pending: standalone-E2E vs unit; `PolicyRegistry-1.0.0` deployed but unconsumed |
| 5.2 | Policy governance freeze/unfreeze/guardian/timelock | Unfreeze requires real 2-day timelock delay; needs fork time-warp | Timelock unit tests; fork simulation |
| 5.3 | DVT proposal lifecycle (`createProposal`/`markProposalExecuted`) | Needs multi-validator quorum | Foundry unit tests |
| 7.4 | Timelocked aPNTs migration / emergency price | Needs timelock minDelay (2 days) to elapse | Fork time-warp test |
| 7.5 (gov) | BLS aggregator queue/apply | Timelock delay | Fork time-warp test |
| 7.8 | UUPS upgrade of Registry / SuperPaymaster | Deploy-time op, not a runtime user flow | `UUPSUpgrade.t.sol` + `MigrateToUUPS.s.sol` |
| 8.5 | Community ownership transfer / factory renounce | Low centrality, one-way op | Foundry unit tests |

## Row counts

- Tier A: **9** rows (1.1, 1.2, 1.5, 2.1, 2.2, 3.3, 3.4, 8.3, 7.1)
- Tier B: **22** rows (1.3, 1.4, 1.6, 2.3, 2.4, 2.5, 3.1, 3.2, 3.5, 4.1, 4.4, 6.1, 6.2, 7.2, 7.3, 7.6, 7.7, 7.9, 8.1, 8.2, 8.4, 7.5)
- Negative (⛔) assertions: **10** (consolidated checklist above)
- Deferred (Tier C): **9** rows
