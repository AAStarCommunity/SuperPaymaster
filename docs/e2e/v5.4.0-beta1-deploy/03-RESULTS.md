# 03 — RESULTS (v5.4.0-beta.1 fresh-redeploy E2E chronological log)

> TX-Value-Verification framework, document 3 of 5.
> Chronological record of the live run. One row per executed scenario group.
> Status legend: ✅ PASS (executed + L2 state asserted) · ⛔ PASS (reverted with the EXACT expected selector) · ❌ FAIL→✅ (failed first pass, root-caused, re-run green) · ⏭️ SKIP (precondition unmet, inconclusive — NOT a pass).
>
> Reminder: a green L1 receipt alone is NOT a pass — the Notes column records the L2 state delta (or, for ⛔ rows, the exact revert selector).

## Run metadata

| Field | Value |
|---|---|
| Release (code) | v5.4.0-beta.1 (same code; **fresh full redeploy** — mainnet rehearsal) |
| Network | Sepolia (chainId 11155111) |
| SuperPaymaster | `0x030025f40d509b1a99547bAEb3795bD27F7182b7` (impl `0x24a94572…`) |
| Registry | `0x3F920B25f8b65988359C372F66F036E48adFc556` |
| X402Facilitator | `0x326Fc3413c8A0185b0179B971C69813B6dFD971B` |
| MicroPaymentChannel | `0x405851A141Cde827E33247d4D4089Af2814c2FF5` (v1.3.0) |
| Deploy fingerprint | `srcHash` = `14ba1a4daa1670e28b31f3a905a49a7808cc89c14277b904b5e9b47df12016d9` |
| Price keeper run before suite? | YES — gasless pre-flight reported cache fresh |
| Run started | Full suite 2026-06-16 14:01:29; isolated re-runs 14:45–15:02 |
| **Final tally (full suite)** | **37 groups · 33 PASS · 4 FAIL** → **37/37 effective** after fixes (all 4 root-caused, none a SuperPaymaster contract bug — see §Full-suite failures). |
| Independent RPC verification (axis-1) | **90/90 unique TXs REAL, all `status = 1`** — independently re-derived via `cast receipt` on `ethereum-sepolia-rpc.publicnode.com` (a different RPC than the suite). The 86-set (admin/config/x402/channel) **plus** the 4 gasless-rerun fix-txs (`0x7b015620…`, `0x2756e812…`, `0xaa9268a5…`, `0x23b807e2…`) are now all independently RPC-confirmed status=1 (appended to `logs/rpc-independent-verify.txt`). Zero NOT_FOUND, zero status=0. Evidence: `logs/rpc-independent-verify.txt`. |
| GA blockers (eth_call-verified) | **Both beta.1 GA blockers independently eth_call-confirmed** (not just doc claims): `SuperPaymaster.version()` → `"SuperPaymaster-5.4.0"`; `SuperPaymaster.APNTS_TOKEN()` → `0x9e66B457E0ABb1F139FD8A596d00f784eBA2873b` == `config.aPNTs` (identical, no divergence). Recorded as `ETH_CALL` lines in `logs/rpc-independent-verify.txt`. |
| No src/ change this session (git-evidenced) | The last 6 `main` commits touched **0** `contracts/src/*.sol` files (scripts/tests/docs/config only) — recorded as `GIT_EVIDENCE` in `logs/rpc-independent-verify.txt`. Confirms this rehearsal validated deploy mechanics, not a code change. |
| On-chain `version()` | SuperPaymaster / Registry both return **`5.4.0`** (clean — confirmed live in I1 rerun **and** independently eth_call-verified). No version deferral this run. |

## Chronological log

Group `[N]` = suite execution order. Each tx links via `https://sepolia.etherscan.io/tx/<hash>`.

| Group | Scenario ID | Status | Tx hash (etherscan) | Gas | Notes (L2 delta / exact revert selector for ⛔) |
|---|---|---|---|---|---|
| [1] Check Contracts | infra | ✅ PASS | (read-only) | — | 19 contracts + EntryPoint present. **Version-string MISMATCH warnings** printed (stale expected-version constants in `check-contracts.js`: expected `Registry-4.1.0`/`SuperPaymaster-4.1.0`/… vs on-chain `5.4.0`/`5.4.0`). On-chain values are CORRECT; preflight still PASSED. Test-script hygiene item. |
| [2] Check Balances | infra | ✅ PASS | approve `0x1e7ab565…` | 29169 | GToken 1873; deployer SBT≥1; all token balances sufficient. |
| [3] A1 | 3.1 / 3.3 | ✅ PASS | (idempotent — SKIP) | — | Genesis communities present: AAStar (deployer, `aastar.eth`) + Mycelium (Anni, `mushroom.box`). `deployer hasRole COMMUNITY`; `sbtHolders(AA_A)==true`; COMMUNITY members=2; ENDUSER count=3. |
| [4] A2 | 3.2 (read) | ✅ PASS | (read-only) | — | 7 ROLE keccak constants match; wiring `GTOKEN_STAKING/MYSBT/SUPER_PAYMASTER` == config.json. |
| [5] B1 | 7.1 | ✅ PASS | setOpLimits `0xfa8bbb5d…`; pause `0x9d1c303a…`; unpause `0x3e565454…` | 45390 / 36705 / 36694 | `minTxInterval==60`, pause/unpause asserted. **`nonce/in-flight conflict — draining mempool & retrying 1/2…` then succeeded** — validates the #295 harness fix (retry instead of skip). B1 PASSED in-suite (no isolated rerun needed). |
| [6] B2 | 7.1 (deposit/withdraw) | ✅ PASS | deposit `0x3af6e111…`; depositFor `0x8c8cba95…`; withdraw(3) `0x2842fdac…`; withdraw(12) `0xbcc29449…` | 82776 / 82175 / 62544 / 62544 | `aPNTsBalance` 10→15 (depositFor +5)→12 (withdraw −3); **`APNTS_TOKEN (0x9e66B457…) balance` asserted == `config.aPNTs`** (no divergence). Restored to 0. B2 PASSED in-suite (#295 fix held). |
| [6] B2 | 8.2 (withdraw excess ⛔) | ⛔ PASS | (eth_call revert) | — | `withdraw` over balance reverted (`execution reverted (unknown custom error)`). |
| [7] B3 | 7.1 / 3.2 | ✅ PASS | configureOperator(2-arg) (in 86-set) | 58–59k | PR#200 2-arg: `xPNTsToken == 0x9e66B457…` + treasury stored; `operators()` returns 9 fields (no exchangeRate); live rate read from token; idempotent re-configure. |
| [8] B4 | 7.2 / 2.4 | ✅ PASS | setTreasury / setAgentRegistries(+restore) / withdrawProtocolRevenue / setFacilitatorFeeBPS(100)+restore / setOperatorFacilitatorFee(50)+restore / queueBLSAggregator (all in 86-set) | 24–62k | `agentIdentityRegistry restored == 0x8004A818…` (== config, no divergence). feeBPS 0→100→0; op fee 0→50→0; `queueBLSAggregator` set pending+ETA. **SKIPs (legit):** `updateSBTStatus`/`updateBlockedStatus` (`onlyRegistry`); `withdrawFacilitatorEarnings` (`facilitatorEarnings==0`); `withdrawProtocolRevenue` skipped (`protocolRevenue ≤ buffer`). B4 PASSED in-suite (#295 fix). |
| [9] B5 | 1.6 (dry-run) / 7.7 | ✅ PASS | (read / static-call) | — | `dryRunValidation` returned `ok=false` reason `INSUFFICIENT_BALANCE` (minimal UserOp — not asserted; NOT the rate-commitment leg). `pendingDebts==0`; retry/clearPendingDebt SKIP (no pending debt). |
| [10] C1 | negatives | ⛔ PASS | (eth_call reverts) | — | No-SBT sender → `missing revert data`; paused operator → `unknown custom error`; unconfigured operator → `unknown custom error`. |
| [11] C2 | 1.5 (V4 negative) | ⛔ PASS | (eth_call revert) | — | Found PaymasterV4 `0x957852…`; zero-balance V4 user → `missing revert data`; `getSupportedTokens` returned. |
| [12] D1 | 6.1 | ✅ PASS | setRule / setEntropyFactor(+restore) / setCommunityReputation / removeRule (in 86-set) | 28–153k | Rule `E2E_ACTIVITY` base=20/bonus=5/max=200 stored & read; entropy→score 70+; communityReputation set; rule cleaned up. |
| [13] D2 | 6.1 / 7.6 (read) | ✅ PASS | setCreditTier / reset (in 86-set) | 52k / 30k | `creditTierConfig[1] == 100.0` (default); getCreditLimit(rep=0)→tier-1 100 aPNTs. (Default base tier — see §Credit-ceiling.) |
| [14] E1 | 7.3 | ✅ PASS | SP updatePrice / setAPNTSPrice(+restore) / V4 updatePrice (in 86-set) | 36–70k | Cache refreshed; aPNTsPrice tuned/restored. **`DRYRUN_STALE_PRICE` leg NOT executed** (cache kept fresh). |
| [15] E2 | 7.2 | ⛔+✅ PASS | setProtocolFee(500)+restore (in 86-set) | 32717 ea | protocolFeeBPS 500 set/restored; **setProtocolFee(2001) reverted** (over MAX=2000). |
| [16] E3 | (read, PR#200) | ✅ PASS | (read-only) | — | `operators()` 9-tuple; live rate from xPNTsToken; getDebt=0; availableCredit denominated in aPNTs. |
| [17] E4 | 1.3 (debt repay) | ✅ PASS (no-op) | (read / SKIP) | — | `getDebt()` returns aPNTs denomination; deployer debt==0 → `repayDebt` TX **SKIPPED (no-op)**; ceil/floor math verified read-only. (Repay cycle owed — §Owed.) |
| [18] F1 | 4.1 (read) | ✅ PASS | (read-only) | — | totalStaked / stakes / wiring REGISTRY/GTOKEN/treasury verified. |
| [19] F2 | slash (supporting) | ✅ PASS | slashOperator(WARNING,0) / updateReputation (in 86-set) | 124k / 37k | Slash record level=WARNING amount=0 (no stake burned); reputation restored. (Tier-1/2 DVT slash NOT exercised — 04 footnote.) |
| [20] F3 | 3.5 / 4.1 (admin) | ✅ PASS | exit-fee / slasher / rep-source / level-thresholds / creditTier set+restore (in 86-set) | 25–63k | Full Registry/Staking admin surface written, asserted, restored. `creditTierConfig[3]` before=300; set 350→restored 300. `topUpStake`/`batchUpdateGlobalReputation` SKIP (onlyRegistry / needs BLS). |
| [21] G1 | 6.2 (read) | ✅ PASS | (read-only) | — | sbtHolders / isEligibleForSponsorship / isRegisteredAgent / globalReputation / getCreditLimit read & asserted. **Agent feedback emission NOT asserted** (no live agent op). |
| [22] G2 | 3.4 (read) | ✅ PASS (read-only) | (read-only) | — | Dual-channel logic `sbtHolders \|\| isRegisteredAgent` verified by query. **No agent NFT registered → no live agent-sender `handleOps`** this run (owed, §Owed + 04). |
| [23] G3 | 1.2 / 6.2 (read) | ✅ PASS | setCreditTier(7,5000) / reset (in 86-set) | 52k / 30k | Tier ceiling expand/reset; fresh user (rep=0)→tier-1 100 aPNTs. Live escalation needs BLS-signed reputation (not run). |
| [24] H1 | DVT/BLS (read) | ✅ PASS | (read-only) | — | DVT/BLS wiring + thresholds; addValidator SKIP (deployer lacks ROLE_DVT). |
| [25] H2 | reputation (read) | ✅ PASS | (read-only) | — | ReputationSystem wiring/getters; syncToRegistry SKIP (needs ≥3 DVT BLS cluster). |
| [26] Gasless | 1.5 (PaymasterV4 escrow) | ✅ PASS | handleOps `0x7b015620014e5c45bb4b23008ace0f132a5261d27563acc77d032baff5a327c1` | confirmed | AOA independent path: gas paid from PaymasterV4 token escrow, no ETH from user. UserOp hash `0x5b07e6ee…`. |
| [27] Gasless | 1.1 (SP aPNTs balance-pay) | ❌ FAIL→✅ rerun | rerun `0x2756e8122a8c26965df4bc5f8bb08bd7f335adc7355a8c0ddba8e42f9f9e31e4` | confirmed | First pass `AA34 signature error` at validate (credit ceiling — see §Credit-ceiling). After `setCreditTier(1,300)`: rerun green, sender `0x9e66B457` xPNTs ↓ (−1 transfer + gas burn), recipient +1. |
| [28] Gasless | 1.1 (SP PNTs / Mycelium op) | ❌ FAIL→✅ rerun | rerun `0xaa9268a527470d4d11177511b963073ba0e28683fa76a4ad792fae421e2704f4` | confirmed | Same `AA34` first pass; after credit-tier fix, rerun green on the **PNTs** token: sender PNTs 1000→… (−1 transfer + gas burn), recipient +1. Confirms multi-operator/multi-token sponsorship. |
| [29] Gasless | 1.2 (SP credit/debt) | ❌ FAIL→✅ rerun | rerun `0x23b807e2b5e7dccccaf7595fb570ecd09df6e461ab40e0b91d7ab9aa446c9e32` | confirmed | Same `AA34` first pass. Rerun **BURN branch** (AA-A held 943.80 aPNTs): xPNTs 943.80→895.32 (**burned 48.47 aPNTs**), `debts[user]` unchanged at 0. **Pure-credit/DEBT branch + repay NOT exercised this run** (AA-A had balance — owed, §Owed). |
| [30] Channel | 2.5 (MicroPaymentChannel) | ✅ PASS | open `0xd5d1b440b3566657dc1861d1a8bf7241142d87d33ff6b939cf29de0152b2181d`; settle `0xbf9db46d9e3c50e717949162b74d476677930e60f7c7b1f15fd0b01dc50c72b0`; close `0x6ab1c648a9ecda2cd706c59d1241d30a8efa978c45d641602fa48c5b7b70ceac` | 168825 / 72378 / 111376 | Open 10 → settle cumulative → close; payee credited; channel struct deleted; finalized channel rejects re-settle. |
| [31] x402 | 2.1 (EIP-3009 USDC) | ✅⛔ PASS | settle `0x3581742cec28c64f50c19118555949e4e045d54577907c4f1fe063e5b19f398b` | 153491 | `settleX402Payment` (receiveWithAuthorization): payee +1.0 USDC; fee 0 (feeBPS=0); nonce consumed; **replay rejected** (2.3 `NonceAlreadyUsed`). |
| [32] x402 | 2.2 (direct xPNTs, C-02) | ✅⛔ PASS | settle `0x3bff8eb5f63e4db05e0c68c35ba5561c4e46286965e4e4ae088eb65714790cac`; binding-isolated `0x8f246bb00fd98dc61775dba0da72bf19976d08b3f46cd689be1b2843c40159c4` | 168433 / 132710 | `settleX402PaymentDirect`: payee +1.0 xPNTs; nonce consumed. **Tampered-recipient redirect → `InvalidX402Signature`**; unmodified sig settles only to AUTHORIZED recipient. |
| [33] BLS | 4.4 (permissionless ⛔, H-02) | ⛔ PASS | (eth_call revert) | — | `permissionlessBLSRegistration==false`; non-owner `registerBLSPublicKey` → **`PermissionlessRegistrationDisabled`**. |
| [34] P2 | 7.9 (PaymasterV4 lifecycle) | ✅ PASS | deactivate / activate / depositFor / withdraw / updatePrice (in 86-set) | 29–61k | paused toggle; depositFor +1 / withdraw −1 asserted; price cache synced on clone `0x957852…`. |
| [35] X1 | 8.1 / 8.2 (xPNTs admin) | ✅ PASS | setMaxSingleTxLimit / setSpenderDailyCap / autoApproved / facilitator-whitelist / burn / updateExchangeRate (+restores, in 86-set) | 28–53k | Caps + spender/facilitator whitelists set/restored; self-burn; exchangeRate +1%. **8.2 firewall REVERT legs (`UnauthorizedRecipient`/`SingleTxLimitExceeded`) NOT run live** — only cap *config* (footnote, 04). |
| [36] I1 | 7.6 (credit ceiling H-1) | ❌ FAIL→✅ rerun | (read-only) | — | First pass **FAILED** — hard-coded version assertion expected `SuperPaymaster-5.3.3`; on-chain is `5.4.0`. After updating the asserted string to `5.4.0`: rerun **13/13 PASS** — `version()=="SuperPaymaster-5.4.0"`, credit limit 300, `availableCredit=300−0`, H-1 `isBlocked` readable. |
| [37] I2 | 7.5 (emergency halt H-2) | ⛔ PASS | emergencyRevoke / addAutoApproved(+restore) (in 86-set) | 31–62k | `emergencyDisabled` flipped true; self-pull `transferFrom` reverted **`0x4e97bcfc` == `EmergencyStop()`** (clean named selector); SP carve-out succeeded; state restored. |

## ⚠️ The 4 first-pass failures — honest root-cause → fix → re-run green

The full suite reported **33 PASS / 4 FAIL**. **None is a SuperPaymaster contract bug.** All 4 root-caused and resolved → **37/37 effective**. (A 5th issue, the `prepare-test` `Unauthorized()`, occurred during *setup* before the 37-group suite — included below for completeness.)

| # | Symptom | Root cause | Resolution | Kind |
|---|---|---|---|---|
| 1 | `prepare-test` reverts `Unauthorized()` at "Configure deployer as SP operator" (pre-suite) | `configureOperator` requires `hasRole(PAYMASTER_SUPER, msg.sender)`; a **fresh** deployer holds `COMMUNITY` + `PAYMASTER_AOA` but **not** `PAYMASTER_SUPER` (an upgrade-accumulated chain already had it). | Added an idempotent `PAYMASTER_SUPER` grant for the deployer in `TestAccountPrepare.s.sol` (log now shows `PAYMASTER_SUPER granted to deployer`). | Test-infra fix (committed) |
| 2 | Groups **[27] [28] [29]** (3 SP gasless cases) fail with **`AA34` (paymaster signature error)** at validate time | The `_creditExceeded` credit ceiling — see the dedicated analysis below. A fresh ENDUSER sits at base credit tier (100 aPNTs); the validate-time charge on Sepolia **L1** (~120 aPNTs buffered) exceeds 100 → rejected before it can pay by balance. | Raised `setCreditTier(1,300)` + `setCreditTier(2,300)` live on Sepolia (covers the L1 charge, keeps tier monotonicity ≤ tier3=300). **NOT changed in contract code** — economic/product parameter. Reruns [27]/[28]/[29] green. | Config decision (live; **contract default kept**) |
| 3 | Group **[36] I1** fails its version assertion | Test hard-coded `expected SuperPaymaster-5.3.3`; the fresh contract correctly returns `5.4.0`. (Same stale-table root cause as the `check-contracts.js` warnings in [1].) | Updated the asserted/expected version strings to `5.4.0`. I1 rerun 13/13 PASS, `version()=="SuperPaymaster-5.4.0"`. | Test-hygiene fix (committed) |

**Re-run evidence (status=1, confirmed in `logs/rerun-*.log` AND now independently RPC-verified in `logs/rpc-independent-verify.txt` → part of the 90/90 set):**
- [27] SP aPNTs balance-pay: `0x2756e8122a8c26965df4bc5f8bb08bd7f335adc7355a8c0ddba8e42f9f9e31e4`
- [28] SP PNTs: `0xaa9268a527470d4d11177511b963073ba0e28683fa76a4ad792fae421e2704f4`
- [29] SP credit/debt (burn branch): `0x23b807e2b5e7dccccaf7595fb570ecd09df6e461ab40e0b91d7ab9aa446c9e32`
- [36] I1: read-only group, `version()=="SuperPaymaster-5.4.0"`, credit limit 300, 13/13 PASS.

> **B1/B2/B4 did NOT fail this run** (unlike beta.1). The full-suite log shows `nonce/in-flight conflict — draining mempool & retrying 1/2…` for `setOperatorLimits` and `Unpause`, after which the txs confirmed and the groups PASSED in-suite. This **validates the #295 harness nonce-retry fix** end-to-end: a nonce/in-flight conflict is now retried (mempool drained, nonce re-synced) instead of skipping a critical tx.

## Credit-ceiling analysis (the `AA34` root cause — precise)

The 3 SP gasless failures ([27]/[28]/[29]) all rejected at validate with `AA34 signature error`. The mechanism:

1. **Credit limit is GLOBAL-reputation-derived, not per-community.** `Registry.getCreditLimit(user) = creditTierConfig[level]`, where `level` is derived from **`globalReputation[user]`** (GLOBAL across all communities) via `levelThresholds = [13, 34, 89, 233, 610]`. A **fresh** user has `globalReputation == 0` → **level 1** → default `creditTierConfig[1]` = **100 aPNTs**.
2. **Validate-time charge exceeds 100 on L1.** SuperPaymaster's validate-time charge is `maxCost × 1.1 buffer × fee`, which on Sepolia **L1** gas comes to **~120 aPNTs** (the actual postOp burn was only **~48 aPNTs** — TC4 burned 48.47). The buffered validate charge therefore exceeds the 100-aPNTs base ceiling.
3. **The ceiling has NO user-balance short-circuit (by design — H-1 anti-drain).** The credit-ceiling check bounds *worst-case debt* if a user drains their xPNTs between validate and postOp; it deliberately does NOT exempt balance-paying users (otherwise the anti-drain guarantee breaks). So a 100-aPNTs base user is blocked **even when they hold ample xPNTs**. Hence: a brand-new ENDUSER with a healthy xPNTs balance still cannot be SP-sponsored for a normal L1 tx out of the box.

**Fix applied for the rehearsal (Sepolia only):** `setCreditTier(1,300)` + `setCreditTier(2,300)` (live; keeps monotonicity ≤ tier3=300). This raises the base ceiling above the ~120-aPNTs L1 charge so a fresh user is sponsorable.

> ### ⚠️ KEY OPEN ITEM — the OP base-credit value is NOT measured; "keep 100" is an UNRESOLVED GA decision
> Codex confirmed the H-1 credit-ceiling mechanism above is accurate (it DOES block balance-payers — verified in `SuperPaymaster.sol` lines 1102–1106 + `_creditExceeded` 812–814; there is no balance short-circuit by design). **But our earlier claim that "on OP the charge drops to ~1–5 aPNTs so the default 100 is sufficient and needs no change" is an UNVERIFIED hypothesis — it was downgraded by Codex as RISKY/UNPROVEN.** No OP receipt, no OP gas model, and no L1-data-fee calculation was produced this rehearsal.
> - **KEEP (directional reasoning only):** OP L2 execution gas is ~100× cheaper than Sepolia L1, so the per-tx aPNTs validate-charge is *expected* to be far lower on OP. This is a plausible direction, not a measurement.
> - **NOT MEASURED:** no OP transaction or gas model was run this rehearsal. The OP L1-data-fee component in particular was never computed. So the actual OP validate-time charge is **unknown**.
> - **Therefore "keep base credit 100" is an OPEN GA DECISION, NOT a resolved item.** Before relying on `creditTierConfig[1]=100` for OP mainnet, the **actual sponsored-tx validate-charge MUST be measured on OP** and confirmed `< 100` aPNTs. If it is not (or for any higher-gas chain), the base tier MUST be raised via `setCreditTier`. Do **not** present 100 as proven-fine.
> - The Sepolia `setCreditTier(1/2,300)` was applied purely to make the L1 E2E representative; it is neither a proof for nor a recommendation against the OP mainnet value — that value remains owed pending an OP gas measurement.

## Independent RPC verification (axis-1)

The **86 unique TX hashes** in `logs/all-tx-inventory.txt` **plus the 4 gasless-rerun fix-txs** ([26] `0x7b015620…`, [27] `0x2756e812…`, [28] `0xaa9268a5…`, [29] `0x23b807e2…`) were independently re-derived via `cast receipt <hash>` against `https://ethereum-sepolia-rpc.publicnode.com` (a different RPC than the suite used).

**Result: 90/90 REAL, all `status = 1`.** Zero NOT_FOUND, zero status=0. (The 4 rerun fix-txs are now folded into the independent set — they were previously only suite/`logs/rerun-*.log`-confirmed; they are now RPC-confirmed status=1, appended to `logs/rpc-independent-verify.txt`.) Block range 11071076→11071279; total gas (86-set) 4,913,548. Evidence: `logs/rpc-independent-verify.txt`.

In addition, two GA blockers were independently **eth_call-verified** (recorded as `ETH_CALL` lines in the same file): `SuperPaymaster.version()` → `"SuperPaymaster-5.4.0"`, and `SuperPaymaster.APNTS_TOKEN()` → `0x9e66B457E0ABb1F139FD8A596d00f784eBA2873b` == `config.aPNTs`. The "no `src/` change this session" claim is `GIT_EVIDENCE`-recorded: the last 6 `main` commits touched 0 `contracts/src/*.sol` files.

> **Why every mined tx is status=1 (not a contradiction):** the ⛔ negatives are probed via read-only `eth_call`/staticcall, which revert *without* producing a mined transaction — they never become `status=0` receipts. The headline x402 ([31]/[32]), channel ([30]), gasless `handleOps` headline ([26]) and the 4 rerun fix-txs are all now inside the 90-set RPC re-derivation; I1 is a read-only group (`version()=="SuperPaymaster-5.4.0"`).

## Negative (⛔) coverage gaps this run (honest)

These plan ⛔ legs were NOT executed as live mined txns this run (covered by Foundry unit tests / `eth_call`-observed instead):
- **1.6 `DRYRUN_RATE_COMMITMENT_VIOLATED`** — B5 dry-run returned `INSUFFICIENT_BALANCE`, not the rate-commitment revert.
- **7.3 `DRYRUN_STALE_PRICE`** — price cache kept fresh; stale leg not triggered.
- **7.6 credit-ceiling revert** — I1 verified ceiling *state* read-only; the live over-ceiling rejection surfaced as the [27]–[29] `AA34` (then fixed), not as an explicit isolated ⛔ assertion.
- **8.2 `UnauthorizedRecipient` / `SingleTxLimitExceeded`** — X1 set/restored caps but did not run the firewall reverts.
- **8.3 `OperationAlreadyProcessed`** (burn replay) — not re-run as an explicit same-opHash replay this suite.
- **8.4 `Unauthorized`** (unapproved facilitator) — x402 direct ran with an already-approved facilitator.

> **7.5 `EmergencyStop` is NOT a gap** — [37] I2 reverted live with `0x4e97bcfc` == `EmergencyStop()`; clean ⛔ PASS.

## Owed items (not-yet-live-exercised this run)

Mirrors beta.1's honesty. Each is a test-fixture/coverage gap, NOT a deployment gap:
1. **Dual-channel agent `handleOps`** — `agentIdentityRegistry` is wired to the official `0x8004A818…`, but no no-SBT account is registered as an agent and no live agent-channel op was run. Only read-only eligibility (G2) proven.
2. **`repayDebt` cycle** — [29]/TC4 took the BURN branch (AA-A held balance); the debt-accrual + repay cycle was not driven live (would need draining AA-A to 0 first, as beta.1 did).
3. **Live ⛔ negatives** — most were observed via `eth_call` / unit tests, not as live mined failed txns (see §Negative coverage gaps).

## Deferred (Tier C) — not executed live (see 02-PLAN)

3.4, 1.3(repay), 4.2, 4.3, 5.1, 5.2, 5.3, 7.4, 7.5(gov), 7.8, 8.5 — intentionally deferred; covered by Foundry unit / fork tests. See 04-CAPABILITY-MAP footnotes.
