# 02 — PLAN (v5.4.0-beta.1 fresh-redeploy E2E Scenario ↔ TX Matrix)

> TX-Value-Verification framework, document 2 of 5.
> Each row maps one scenario to one intended on-chain call, with a **3-layer Verification** spec.
> Same release code as `docs/e2e/v5.4.0-beta.1/` — this matrix is re-applied against the **fresh-deploy addresses** (01-TESTDATA §2).
>
> **Core principle — a green receipt ≠ a proven feature.** Every row's Verification column carries:
> - **L1 Receipt**: tx mined, `status = 1` (or, for ⛔, mined-revert / `eth_call`-revert with the named selector).
> - **L2 State**: the precise on-chain delta that proves the feature actually happened (the load-bearing assertion).
> - **L3 Feature**: the user-facing business outcome the L2 delta implies.
>
> **Negatives (⛔) are first-class.** A ⛔ row passes ONLY if it reverts with the EXACT named reason/selector. Any other revert (or success) = FAIL.
>
> Script names reference `script/gasless-tests/` (see `run-all-e2e-tests.sh`). Group numbers `[N]` are the suite's execution order (03-RESULTS).

## Tier A — Headline scenarios (MUST be 1:1 live, real tx)

| ID | TX (intended call) | Feature | Actor | Params | Business expectation | Verification (L1 Receipt / L2 State / L3 Feature) | Type |
|---|---|---|---|---|---|---|---|
| 1.1 | `EntryPoint.handleOps` → SP `validatePaymasterUserOp` + `postOp` + `burnFromWithOpHash` | AOA+ gasless via xPNTs (balance-pay) | Operator + AA-A | userOp, xPNTs token, opHash | User pays gas in xPNTs, no ETH | L1: handleOps status=1, `TransactionSponsored`. L2: user xPNTs balance ↓ (burn), `operators[op].aPNTsBalance` accounting, `totalTxSponsored`++. L3: gasless tx settled in community token. Group [27] (aPNTs) / [28] (PNTs). | ✅ |
| 1.2 | SP `validatePaymasterUserOp`+`postOp` → burn branch / `recordDebtWithOpHash` | Credit/debt path | Operator + AA-A | userOp, opHash, credit ceiling | Sponsor user; burn if balance, else accrue debt to ceiling | L1: handleOps status=1. L2: balance>0 → xPNTs burned, `debts[user]` unchanged; balance==0 → `DebtRecorded`, `debts[user]` ↑. L3: onboarding without prefunding. Group [29] (TC4). | ✅ |
| 1.5 | `EntryPoint.handleOps` → PaymasterV4 `validatePaymasterUserOp`+`postOp`; escrow via `depositFor` | AOA independent paymaster (pre-funded escrow) | Operator + AA-A | userOp, token, escrow | Independent per-community paymaster pays from escrow | L1: handleOps status=1. L2: `balances[user][token]` ↓ by cost, `balances[treasury][token]` ↑. L3: standalone AOA works without shared pool. Group [26]. | ✅ |
| 2.1 | `X402Facilitator.settleX402Payment` (EIP-3009 `receiveWithAuthorization`, USDC) | x402 native USDC settlement | Facilitator (deployer) | payer auth sig, recipient, amount, nonce | Off-chain-signed USDC payment settled on-chain, fee taken | L1: status=1, `X402PaymentSettled`. L2: payer USDC ↓, recipient ↑ (amount − fee), `facilitatorEarnings` ↑, `x402SettlementNonces[key]` set. L3: agent pays USDC gaslessly. Group [31]. | ✅ |
| 2.2 | `X402Facilitator.settleX402PaymentDirect` (`transferFrom` xPNTs, C-02 signed auth) | x402 direct xPNTs settlement | Facilitator + payer | C-02 auth sig, payer, recipient, amount, nonce | Settle xPNTs payment with payer's signed authorization | L1: status=1, `X402PaymentSettled`. L2: payer xPNTs ↓, recipient ↑, nonce consumed (triple-key). L3: community-token x402 micropayment. Group [32]. | ✅ |
| 3.3 | `Registry.registerRole(ENDUSER)` / `MySBT.safeMintForRole` + `updateSBTStatus` | End-user onboarding + SBT status gate | Community | enduser addr, role, SBT status | Onboard end-user so they qualify for sponsorship | L1: status=1, role + SBT mint events. L2: `sbtHolders[user]=true`; `isEligibleForSponsorship==true`. L3: only onboarded users get sponsored. Group [3] A1 + `RegisterEnduser.s.sol`. | ✅ |
| 3.4 | `EntryPoint.handleOps` with agent sender (no SBT) → SP `isEligibleForSponsorship` (`isRegisteredAgent`) | Dual-channel eligibility (SBT OR ERC-8004 Agent NFT) | Operator + agent sender | userOp from agent, no SBT | Registered agents sponsored without an SBT | L1: handleOps status=1, `TransactionSponsored`. L2: agent sender `sbtHolders==false` yet `isEligibleForSponsorship==true` via `isRegisteredAgent`; tx settled. L3: agent economy gets gasless access. Group [22] G2. **Deferred-live this run — read-only logic only (see Tier C / 04).** | ✅ (read-only this run) |
| 8.3 | SP-internal `burnFromWithOpHash` then replay same opHash | Burn replay protection | SP (caller) | opHash, token, amount | One opHash → one burn, ever | L1: first burn status=1; replay reverts. L2: `usedOpHashes[opHash]=true`; replay reverts **`OperationAlreadyProcessed`**. L3: no double-charge. Group [27]–[29] + C1. | ⛔ (replay leg) |
| 7.1 | SP `configureOperator` / `deposit` / `withdraw` / `setOperatorPaused` | Operator config & funding lifecycle | Operator | aPNTs amount, exchangeRate, pause, treasury, limits | Operator manages its own pool | L1: each call status=1. L2: `aPNTsBalance` ↑ deposit / ↓ withdraw; `isPaused` toggles; treasury/minTxInterval stored. L3: self-service operator treasury. Groups [5] B1 / [6] B2 / [7] B3. | ✅ |

## Tier B — Supporting scenarios (live E2E)

| ID | TX (intended call) | Feature | Actor | Params | Business expectation | Verification (L1 / L2 / L3) | Type |
|---|---|---|---|---|---|---|---|
| 1.3 | SP `repayDebt` | Debt repayment & exchange-rate settlement | User / payer | debt amount, xPNTs | User clears accrued debt | L1: status=1, repay event. L2: `debts[user]` ↓; xPNTs burned at rate. L3: credit revolves. Group [17] E4. **No-op this run (deployer/AA-A debt==0 — burn branch was taken).** | ✅ (no-op) |
| 1.4 | SP `postOp` over-charge refund branch | postOp over-charge refund | Operator (in postOp) | actual vs prepaid gas | Operator not over-debited when actual < prepaid | L1: handleOps status=1. L2: buffer recovered. L3: accurate accounting. Covered indirectly in [27]–[29]. | ✅ |
| 1.6 | SP `validatePaymasterUserOp` with `exchangeRate > maxRate` | Rate-commitment / rug-pull guard | Operator + AA | userOp with rate commitment, maxRate | Reject if operator's rate exceeds user-committed max | L1: validation returns SIG_FAILURE / mined-revert. L2: **`DRYRUN_RATE_COMMITMENT_VIOLATED`** / SIG_FAILURE; no burn, no debt. L3: user protected. Group [9] B5 dry-run + C1. | ⛔ |
| 2.3 | `X402Facilitator.settleX402Payment*` re-submit same nonce | x402 replay protection (triple-key nonce) | Facilitator | used nonce | Same authorization cannot settle twice | L1: replay reverts. L2: **`NonceAlreadyUsed`**; no balance change. L3: no double-settlement. Groups [31]/[32]. | ⛔ |
| 2.4 | SP `setFacilitatorFeeBPS` + `withdrawFacilitatorEarnings` | Facilitator fee config & earnings withdraw | Owner / facilitator | feeBPS, withdraw | Facilitator configures and collects fees | L1: status=1. L2: `facilitatorFeeBPS` set; on withdraw `facilitatorEarnings[op]`→0. L3: facilitator monetization. **Withdraw not exercised — earnings==0** (footnote). Group [8] B4. | ✅ (partial) |
| 2.5 | `MicroPaymentChannel.open` / `settle` / `close` | Streaming micropayment channel | Payer / payee | deposit, settle amount | Off-chain streaming with on-chain escrow | L1: each call status=1. L2: open→settled→closed; escrow moves payer→payee; remainder refunded. L3: pay-per-use streaming. Group [30]. | ✅ |
| 3.1 | `Registry.registerRole(ROLE_COMMUNITY)` + `lockStake` + `mintForRole` | Community registration | Community | role, stake, SBT | Community joins protocol | L1: status=1, `RoleRegistered`. L2: `hasRole(community, ROLE_COMMUNITY)==true`; stake locked; SBT minted. L3: community can sponsor. Group [3] A1. | ✅ |
| 3.2 | `Registry.registerRole(ROLE_PAYMASTER_*)` + `_requireCommunityForPaymaster` + `configureOperator` | Operator registration | Operator | role, community link | Operator registered under a community | L1: status=1. L2: `hasRole(op, ROLE_PAYMASTER_SUPER/AOA)==true`; operator config created. L3: community-backed operators sponsor. Groups [4] A2 / [5] B1 / [7] B3. | ✅ |
| 3.5 | `Registry.exitRole` + `unlockAndTransfer` + `burnSBT` | Role exit / SBT burn / stake unlock | Role holder | role | Clean exit returns stake net fee | L1: status=1, `RoleExited`. L2: GToken returned = locked − exitFee; SBT burned; role revoked. L3: reversible membership. Group [20] F3 (admin surface). | ✅ |
| 4.1 | `GTokenStaking.lockStakeWithTicket` / `topUpStake` | Role stake lock + min-stake floor | Role holder | ticket, amount | Stake meets/exceeds role floor | L1: status=1. L2: `roleLocks[holder][role].amount` ↑; rejects below floor. L3: skin-in-the-game. Groups [18] F1 / [20] F3. | ✅ |
| 4.4 | `BLSValidator.registerBLSPublicKey` / `setPermissionlessBLSRegistration` | BLS key registration + permissionless toggle | Validator / owner | BLS pubkey, toggle | Validators register; owner toggles open registration | L1: status=1. L2: pubkey stored; permissionless flag gates. L3: DVT onboarding. Group [33]. | ✅ (+⛔ gate leg) |
| 6.1 | ReputationSystem `setRule` / `setCommunityReputation` / `setNFTBoost` | Reputation scoring & community rules | Community / owner | rule, score, boost | Configure reputation inputs | L1: status=1. L2: rule/score/boost stored & readable. L3: reputation drives credit tiers. Groups [12] D1 / [21] G1 / [25] H2. | ✅ |
| 6.2 | SP credit-tier gating + ERC-8004 `giveFeedback` in postOp | Reputation-gated sponsorship + agent feedback | Operator + agent | reputation, agent feedback | Higher reputation → higher credit; agents get feedback | L1: handleOps status=1. L2: credit tier applied per reputation; **agent feedback emission NOT asserted** (no live agent op). L3: reputation economy. Groups [21] G1 / [23] G3 / [29]. | ✅ (partial) |
| 7.2 | SP `setProtocolFee` / `setAPNTSPrice` / `withdrawProtocolRevenue` | Protocol economics | Owner | feeBPS, price, withdraw | Owner tunes economics, collects revenue | L1: status=1. L2: `protocolFeeBPS`, `aPNTsPriceUSD` within bounds; `protocolRevenue`→0 on withdraw. L3: sustainable protocol. Groups [8] B4 / [15] E2. | ✅ |
| 7.3 | SP `updatePrice` / `setCachedPrice`; query with stale cache | Oracle price update & staleness | Keeper / owner | price, timestamp | Fresh price required for ops | L1: update status=1. L2: cached price+timestamp updated; stale → **`DRYRUN_STALE_PRICE`**. L3: no mispriced sponsorship. Group [14] E1. | ✅ (+⛔ stale leg) |
| 7.6 | SP `_creditExceeded` (C-01) + H-1 `isBlocked` | Credit ceiling enforcement (anti-drain) | Operator + user | accrued debt vs ceiling | Stop sponsoring past credit ceiling | L1: over-ceiling op mined-revert / `AA34` at validate. L2: H-1 `isBlocked`; `debts[user]` ≤ ceiling; `availableCredit = limit − totalDebt`. L3: anti-drain. Group [36] I1. **Read-only state this run; the L1-charge>ceiling artifact surfaced live in [27]–[29] (see 03 §Credit-ceiling).** | ⛔ |
| 7.7 | SP `retryPendingDebt` / `clearPendingDebt` | Pending-debt recovery | Owner | user, debt | Owner recovers/clears stuck debt | L1: status=1. L2: pending debt re-applied/cleared. L3: debt hygiene. Group [9] B5. **No-op (no pending debt).** | ✅ (no-op) |
| 7.9 | PaymasterFactory `deployPaymaster` + Registry `activate/deactivate` + `addStake` + `pause` | PaymasterV4 lifecycle | Operator | salt, config | Full AOA paymaster lifecycle | L1: each call status=1. L2: clone active in Registry; pause toggles; escrow ±. L3: independent paymaster ops. Group [34] P2. | ✅ |
| 8.1 | xPNTsFactory `deployxPNTsToken` + SP `propagateSuperPaymaster` | xPNTs deployment by community | Community | name/symbol, SP addr | Community mints its own gas token | L1: status=1. L2: clone deployed; `isXPNTs[token]==true`; SP propagated as burner. L3: per-community gas token. setup + Group [35] X1. | ✅ |
| 8.2 | xPNTsToken `transferFrom` firewall + caps | xPNTs transferFrom firewall + caps | User / spender | from, to, amount | Token movement constrained to firewall rules | L1: violating txs revert; allowed status=1. L2: non-self/non-SP → **`UnauthorizedRecipient`**; over-cap → **`SingleTxLimitExceeded`**. L3: anti-abuse firewall. Group [35] X1. **Caps set; firewall revert legs not run live** (footnote). | ⛔ (firewall legs) |
| 8.4 | `X402Facilitator.settleX402PaymentDirect` without `addApprovedFacilitator` | Approved-facilitator whitelist | Facilitator (not approved) | unapproved facilitator | Only community-approved facilitators settle direct | L1: unapproved reverts; approved status=1. L2: absent approval → **`Unauthorized`**. L3: community controls who pulls its token. Group [32]. **Ran with approved facilitator; unapproved leg not run live** (footnote). | ⛔ |
| 7.5 | xPNTsToken `emergencyRevokePaymaster` then burn/transferFrom | Emergency halt | Owner | token | Kill-switch freezes token operations | L1: revoke status=1; subsequent burn/transferFrom revert. L2: `emergencyDisabled==true`; revert **`EmergencyStop`** (`0x4e97bcfc`). L3: incident containment. Group [37] I2. | ⛔ |

## Negative (⛔) assertions — consolidated checklist

Each must revert with the EXACT selector below; any other outcome = FAIL.

| ⛔ | Trigger | Required revert |
|---|---|---|
| 1.6 | exchangeRate > user maxRate | `DRYRUN_RATE_COMMITMENT_VIOLATED` / SIG_FAILURE |
| 2.3 | x402 replay (used nonce) | `NonceAlreadyUsed` |
| 8.4 | x402 direct settle by unapproved facilitator | `Unauthorized` |
| 8.2a | xPNTs transferFrom to non-self/non-SP | `UnauthorizedRecipient` |
| 8.2b | xPNTs transfer over per-spender / single-tx cap | `SingleTxLimitExceeded` |
| 7.6 | credit ceiling exceeded (C-01/H-1) | credit-exceeded revert / `AA34` at validate / H-1 blocked |
| 8.3 | burn replay (reused opHash) | `OperationAlreadyProcessed` |
| 7.5 | op after emergency halt | `EmergencyStop` (`0x4e97bcfc`) |
| 2.2 | x402 redirect / tampered recipient binding (C-02) | `InvalidX402Signature` |
| 7.3 | op against stale price cache | `DRYRUN_STALE_PRICE` |
| 4.4 | non-owner `registerBLSPublicKey` with switch off | `PermissionlessRegistrationDisabled` |

## Deliberately deferred (Tier C) — NOT a silent gap

Intentionally not run live on-chain this rehearsal. Each has a stated reason and an existing alternative coverage. MUST be revisited before GA.

| ID | Scenario | Reason deferred | Existing coverage |
|---|---|---|---|
| 3.4 | Dual-channel agent `handleOps` (no-SBT agent) | No no-SBT account registered as an agent + no live agent-channel op this run | Read-only eligibility logic verified (G2); registry deployed & wired (`0x8004A818…`). Test-fixture gap, NOT a deployment gap. |
| 1.3 | `repayDebt` reduction cycle | TC4 took the BURN branch (AA-A had balance); debt-accrual + repay not driven live this run | Math verified read-only (E4); proven live in beta.1 via a drain fixture. |
| 4.2 | DVT slash of operator aPNTs (Tier-1, `executeSlashWithBLS`) | Needs BLS threshold from multiple validators; no live multi-validator fixture | Foundry unit tests under `contracts/test/modules/` |
| 4.3 | DVT slash of GToken stake (Tier-2, `slashByDVT`) | Same multi-validator BLS fixture requirement | Foundry unit tests |
| 5.1 | PolicyRegistry spend policy (`checkPolicy`/`recordSpend`) | Standalone — not wired into paymaster validate path on main | `PolicyRegistry-1.0.0` deployed but unconsumed; decision pending |
| 5.2 | Policy governance freeze/unfreeze/guardian/timelock | Unfreeze needs real 2-day timelock; needs fork time-warp | Timelock unit tests; fork simulation |
| 5.3 | DVT proposal lifecycle (`createProposal`/`markProposalExecuted`) | Needs multi-validator quorum | Foundry unit tests |
| 7.4 | Timelocked aPNTs migration / emergency price | Needs timelock minDelay (2 days) to elapse | Fork time-warp test |
| 7.5 (gov) | BLS aggregator queue/apply | Timelock delay | Fork time-warp test |
| 7.8 | UUPS upgrade of Registry / SuperPaymaster | Deploy-time op, not a runtime user flow | `UUPSUpgrade.t.sol` + `MigrateToUUPS.s.sol` |
| 8.5 | Community ownership transfer / factory renounce | Low centrality, one-way op | Foundry unit tests |

## Row counts

- Tier A: **9** rows (1.1, 1.2, 1.5, 2.1, 2.2, 3.3, 3.4, 8.3, 7.1)
- Tier B: **22** rows (1.3, 1.4, 1.6, 2.3, 2.4, 2.5, 3.1, 3.2, 3.5, 4.1, 4.4, 6.1, 6.2, 7.2, 7.3, 7.6, 7.7, 7.9, 8.1, 8.2, 8.4, 7.5)
- Negative (⛔) assertions: **11** (consolidated checklist above)
- Deferred (Tier C): **11** rows
