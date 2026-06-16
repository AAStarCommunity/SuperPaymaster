# 04 — CAPABILITY MAP (v5.4.0-beta.1 fresh redeploy)

> TX-Value-Verification framework, document 4 of 5.
> Maps each proven on-chain tx to the capability it demonstrates and the user value it delivers.
> Only txs with a real hash and an asserted L2 state delta count as "proven". Everything else lives in the footnote section, never silently claimed.
>
> **Adversarial scoping rule (applied below):** each "user value" claim is held to EXACTLY what the tx mutates on-chain. Read-only queries are labelled `(read-only)` and claim nothing about a live sponsored UserOp. State mutations name the precise delta. Revert (⛔) rows claim only the exact selector observed.
>
> Reminder: same release code as `docs/e2e/v5.4.0-beta.1/`, **fresh-deploy addresses** (01-TESTDATA §2). Etherscan: `https://sepolia.etherscan.io/tx/<hash>`.

## Proven on-chain (real tx + asserted state)

| # | TX (hash + ✅/⛔) | What it proves (scoped to the on-chain delta) | User value (no overstatement) |
|---|---|---|---|
| 1 | `0x7b015620014e5c45bb4b23008ace0f132a5261d27563acc77d032baff5a327c1` ✅ | One `handleOps` via PaymasterV4 (AOA independent): a sponsored op mined end-to-end, gas drawn from the PaymasterV4 token escrow (`depositFor`). | A user with zero ETH moved a community token; gas paid from the community's prefunded escrow. |
| 2 | `0x2756e8122a8c26965df4bc5f8bb08bd7f335adc7355a8c0ddba8e42f9f9e31e4` ✅ (rerun) | One `handleOps` via SuperPaymaster (AOA+): sender `aPNTs` (`0x9e66B457…`) ↓ = −1 transfer **+ gas burned in postOp** (`burnFromWithOpHash`); recipient +1. Proves shared-pool xPNTs balance-pay + burn accounting. | A user pays Ethereum gas in xPNTs through the shared paymaster, holding no ETH. |
| 3 | `0xaa9268a527470d4d11177511b963073ba0e28683fa76a4ad792fae421e2704f4` ✅ (rerun) | Second SuperPaymaster op on a *different* token (PNTs `0xC687f8a1…`, Mycelium operator): sender PNTs ↓, recipient +1. Proves multi-operator / multi-token sponsorship on one SP. | Multiple communities each run their own gas token on one shared paymaster. |
| 4 | `0x23b807e2b5e7dccccaf7595fb570ecd09df6e461ab40e0b91d7ab9aa446c9e32` ✅ (rerun) | Credit/debt entry path, **burn branch**: xPNTs 943.80→895.32 (**burned 48.47 aPNTs**), `debts[user]` stayed 0. Proves postOp burns when the user holds a balance. **Scoped exactly to the burn branch** — the 0-balance→`DebtRecorded` branch was NOT taken this run (footnote 7). | A sponsored tx settles by burning the user's token when they hold a balance. |
| 5 | `0x3581742cec28c64f50c19118555949e4e045d54577907c4f1fe063e5b19f398b` ✅⛔ | `settleX402Payment` (EIP-3009 USDC): payee +1.0 USDC, fee 0 (feeBPS=0), nonce consumed; replay re-submit rejected. Proves native-USDC x402 settlement + nonce replay guard. | An off-chain-signed USDC payment settles on-chain once and cannot be replayed. |
| 6 | `0x3bff8eb5f63e4db05e0c68c35ba5561c4e46286965e4e4ae088eb65714790cac` ✅ | `settleX402PaymentDirect` (xPNTs `transferFrom`, C-02 signed auth): payee +1.0 xPNTs, nonce consumed. Proves community-token x402 direct settle. | A signed xPNTs micropayment settles via the facilitator without the payer sending a tx. |
| 7 | replay leg of #5/#6 ⛔ | Re-submitting a used nonce reverts **`NonceAlreadyUsed`**. | An authorization cannot be double-settled. |
| 8 | C-02 leg of #6 ⛔ + `0x8f246bb00fd98dc61775dba0da72bf19976d08b3f46cd689be1b2843c40159c4` ✅ | Redirecting the same signature to a different recipient reverts **`InvalidX402Signature`**; the unmodified signature settles only to the authorized recipient. Proves recipient is bound into the signed payload. | A signed payment cannot be hijacked to a different recipient. |
| 9 | `0xd5d1b440…` (open) / `0xbf9db46d…` (settle) / `0x6ab1c648…` (close) ✅ | MicroPaymentChannel lifecycle: open 10 → settle cumulative → close; payee credited, channel struct deleted; re-settle on finalized channel rejected. | Pay-per-use streaming with on-chain escrow and a clean refund-on-close. |
| 10 | permissionless-BLS leg ⛔ | Non-owner `registerBLSPublicKey` with the switch off reverts **`PermissionlessRegistrationDisabled`** (H-02 gate). | Validator registration stays owner-gated until explicitly opened. |
| 11 | [37] I2 `emergencyRevokePaymaster` ✅ + emergency revert ⛔ | `emergencyRevokePaymaster` set `emergencyDisabled=true`; a subsequent self-pull `transferFrom` reverted with **`0x4e97bcfc` == `EmergencyStop()`**; SP carve-out path still succeeded. Clean ⛔ PASS — named selector matched. | A community can flip an emergency kill-switch on its token; the exact `EmergencyStop()` revert is verified on-chain. |
| 12 | E2 over-fee leg ⛔ + setProtocolFee(500)/restore ✅ | `setProtocolFee(500)` set & restored; `setProtocolFee(2001)` reverts (over MAX=2000). Proves protocol-fee setter with an upper bound. | Protocol fee is owner-tunable but cannot exceed the hard cap. |
| 13 | E1 SP/V4 `updatePrice` + `setAPNTSPrice`/restore ✅ | `updatePrice` refreshed the Chainlink-backed cache; `setAPNTSPrice` tuned/restored. Proves the price cache is writable and bounded. **Does NOT prove stale-price rejection** (cache kept fresh). | Sponsorship is priced off a refreshable oracle cache. (Staleness guard not exercised — footnote 13.) |
| 14 | F2 slashOperator(WARNING,0)/restore ✅ | Slash record level=WARNING, amount=0 (no stake burned), reputation restored. Proves the slash-record path for a zero-penalty warning. **Does NOT prove value-bearing DVT slash** (footnote 2). | Operators accrue an on-chain disciplinary record. |
| 15 | F3 admin set (exit-fee / slasher / rep-source / level-thresholds / creditTier, +restores) ✅ | Each written, asserted, and restored. Proves the Registry/Staking admin surface. | Governance can tune membership economics and reputation wiring. |
| 16 | D1 setRule + communityRep ✅ | Reputation rule `E2E_ACTIVITY` (base 20 / bonus 5 / max 200) stored & read; entropy factor → score; communityReputation set. Proves reputation-rule configuration + score compute. | Communities define reputation inputs that drive credit tiers. |
| 17 | D2/G3 setCreditTier(+resets) ✅ | `setCreditTier(7, 5000)` written & reset; `getCreditLimit(rep=0)`→tier-1 **100** aPNTs (default). Proves the credit-ceiling config and the rep→tier read mapping. | Admin can expand the credit ceiling; users get a tier by reputation. (Live escalation needs BLS rep update — footnote 5.) |
| 18 | B4 setFacilitatorFeeBPS / setOperatorFacilitatorFee (+restores) ✅ | `setFacilitatorFeeBPS` 0→100→0; `setOperatorFacilitatorFee` 0→50→0. Proves the facilitator-fee config setters. **Withdraw NOT exercised** — `facilitatorEarnings==0` (footnote 8). | Facilitators/operators can set a fee rate. Earnings-withdraw path unproven this run. |
| 19 | B4 setTreasury + setAgentRegistries (+restore) ✅ | `setTreasury` and `setAgentRegistries` written, asserted, restored; `agentIdentityRegistry restored == 0x8004A818…` (== config — **no divergence**). Proves SP governance setters. | Operator can repoint treasury and agent-identity/reputation registries. |
| 20 | B4 queueBLSAggregator ✅ | `queueBLSAggregator` set `pendingBLSAgg` + ETA (timelock). Proves the *queue* step. **`applyBLSAggregator` NOT run** (timelock) (footnote 3). | Critical wiring changes go through a timelock queue. |
| 21 | B1/B2/B3 operator config/funding ✅ | setOpLimits / pause / unpause / deposit / depositFor / withdraw / configureOperator(2-arg). `aPNTsBalance` 10→15→12; `APNTS_TOKEN (0x9e66B457…) == config.aPNTs` asserted on withdraw. Proves operator self-service pool management + #295 nonce-retry (mempool drain in-suite). | An operator funds, configures, pauses, and drains its own shared-pool position; the base token has no config↔chain split. |
| 22 | P2 lifecycle (deactivate/activate/depositFor/withdraw/updatePrice) ✅ | PaymasterV4 lifecycle on clone `0x957852…`: pause toggle, escrow ±1, price cache synced. | Independent AOA paymaster can be paused/funded/drained at runtime. |
| 23 | X1 xPNTs admin (caps / spenders / facilitator-whitelist / burn / exchange-rate, +restores) ✅ | Token-admin config surface set & restored. **Firewall REVERT legs NOT run** (footnote 10). | Community owner tunes its token's caps, spenders, and rate. |
| 24 | I1 read-only (after version fix) ✅ | creditTierConfig / getCreditLimit (300 after the L1 fix) / pendingDebts / userOpState(isBlocked) readable; `availableCredit = 300−0`; **`version()`=="SuperPaymaster-5.4.0"** asserted. **(read-only — no over-ceiling tx).** | Confirms H-1 ceiling state is on-chain & queryable, and the clean v5.4.0 version literal. |
| 25 | A1/A2/E3/F1/G1/G2/H1/H2 read-only ✅ | Role grants, SBT-holder flag, dual-channel eligibility logic (`sbtHolders \|\| isRegisteredAgent`), 9-tuple operator struct, staking state, DVT/BLS wiring, reputation getters — queried & asserted. **(read-only).** | Confirms deployed wiring and gating logic match spec. No live UserOp claimed by these rows. |

## Fresh-deploy provenance (capabilities the clean redeploy proves that beta.1 could not)

- **Clean `version()` = 5.4.0** (#24) — beta.1's on-chain `version()` read `5.3.3` (a GA blocker). The fresh deploy compiles current source, so the literal is correct. **This GA blocker is resolved by the deploy path itself, and is now independently `eth_call`-verified** (`version()`→`"SuperPaymaster-5.4.0"`, recorded as an `ETH_CALL` line in `logs/rpc-independent-verify.txt`).
- **No base-token divergence** (#19, #21) — `SuperPaymaster.APNTS_TOKEN() == config.aPNTs == 0x9e66B457…`, now independently `eth_call`-verified (identical, `ETH_CALL` line in the verify file). beta.1 carried an in-flight `queueSetAPNTsToken` migration and a config↔chain split; a fresh deploy wires the base token at `initialize()` with no migration.
- **Agent registry matches config** (#19) — `agentIdentityRegistry() == 0x8004A818…` (the official ERC-8004), identical to `config`. beta.1's SP was wired to a different registry.

## Notable scope-downs (what we did NOT prove, despite a green/effective-green run)

> **OWED headline items** (test-fixture gaps, NOT deployment gaps): the dual-channel-agent `handleOps` AND the 0-balance debt-accrual + `repayDebt` cycle. Both were proven live in beta.1; this rehearsal did not re-drive them (AA-A held a balance → burn branch; no no-SBT agent registered).

- **[OWED] 1.2 credit/debt DEBT branch + 1.3 repay** — #4 proved only the BURN branch live (AA-A held 943.80 aPNTs). The 0-balance→`recordDebtWithOpHash` branch and the subsequent `repayDebt` reduction were not driven this run. (beta.1 proved the debt branch via a drain fixture: debt 0→+39.76 aPNTs.)
- **[OWED] 3.4 Dual-channel agent sponsorship** — G2 verified the eligibility *logic* by query only. The agent identity registry **IS deployed and wired** (`agentIdentityRegistry() == 0x8004A818…`). What is owed is a no-SBT account *registered as an agent* there **plus** a live agent-sender `handleOps` (sbt==false yet sponsored). Claim limited to the read-only eligibility check.
- **6.2 agent feedback emission** — G1/G3 ran the rep path but did NOT assert an `AgentReputationRegistry.giveFeedback` event.

## Code-has-it but NOT yet E2E-proven on-chain (footnote — no silent claims)

These capabilities exist in the deployed bytecode but are NOT proven by a live tx in this run.

1. **PolicyRegistry spend policy** (`checkPolicy`/`recordSpend`) — `PolicyRegistry-1.0.0` deployed but NOT wired into the paymaster validate path on main; no consumer exercises it on-chain. (02-PLAN 5.1/5.2)
2. **DVT slashing** (Tier-1 `executeSlashWithBLS` → aPNTs; Tier-2 `slashByDVT` → GToken stake) — requires multi-validator BLS threshold; Foundry unit tests only. F2 proved only a zero-penalty WARNING record. (4.2/4.3)
3. **Timelock-gated governance apply steps** (`applyBLSAggregator`, emergency price) — the *queue* step was proven (#20); apply needs the timelock minDelay (2 days) to elapse; fork time-warp only. (5.2/7.4/7.5gov)
4. **DVT proposal lifecycle** (`createProposal`/`markProposalExecuted`) — needs multi-validator quorum; unit-tested. (5.3)
5. **BLS aggregator apply + `batchUpdateGlobalReputation`** — needs an aggregate BLS-12-381 signature from ≥3 DVT validators; F3/H2 SKIP these. Reputation→credit-tier escalation therefore unproven live. (7.5gov)
6. **UUPS upgrade** of Registry/SuperPaymaster — deploy-time op; `UUPSUpgrade.t.sol` + `MigrateToUUPS.s.sol`. (7.8)
7. **Credit/debt DEBT branch + `repayDebt`** — #4 proved only the burn branch; the 0-balance debt-accrual + repay were not driven live this run (OWED — see scope-downs; proven in beta.1). (1.2/1.3)
8. **Standalone facilitator earnings withdraw** — `withdrawFacilitatorEarnings` SKIP'd in B4 (`facilitatorEarnings==0`, suite fee 0%); a dedicated accrue-then-withdraw script is still owed. (2.4)
9. **xPNTs firewall reverts** (`UnauthorizedRecipient`, `SingleTxLimitExceeded`) — X1 set caps but did not execute the violating transfers; unit-tested only. (8.2)
10. **Unapproved-facilitator revert** (`Unauthorized`) — x402 direct ran with an already-approved facilitator. (8.4)
11. **Burn replay `OperationAlreadyProcessed`** — not re-run as an explicit same-opHash replay (unit-tested). (8.3)
12. **Rate-commitment / stale-price dry-run reverts** (`DRYRUN_RATE_COMMITMENT_VIOLATED`, `DRYRUN_STALE_PRICE`) — B5 dry-run returned `INSUFFICIENT_BALANCE`; the rate/stale legs were not triggered live. (1.6/7.3)
13. **Community ownership transfer / factory renounce** — low centrality; unit-tested. (8.5)
14. **Credit-ceiling over-drain rejection (live)** — I1 verified the ceiling *state* read-only; the live over-ceiling rejection surfaced incidentally as the [27]–[29] `AA34` (an L1-gas artifact, then fixed via `setCreditTier`), not as an isolated ⛔ assertion. See 03 §Credit-ceiling. **OPEN GA ITEM (downgraded per Codex):** the OP base-credit value is NOT measured — the earlier "keep 100 on OP, no change needed" wording was an UNVERIFIED hypothesis (no OP receipt / no OP gas model / no L1-data-fee calc). Directional reasoning (OP execution gas ≈100× cheaper) is kept, but "keep base credit 100" remains an **open GA decision pending an actual OP validate-charge measurement < 100 aPNTs**; if not met, raise the base tier via `setCreditTier`. (7.6)

> **NOT owed (resolved by the fresh deploy):** the beta.1 GA blockers — on-chain `version()`==5.3.3 and the `APNTS_TOKEN`↔`config.aPNTs` divergence — are both GONE on this clean redeploy (see "Fresh-deploy provenance"). `EmergencyStop` exact selector is a clean ⛔ PASS (#11).
