# 05 — CODEX CHALLENGE (v5.4.0-beta.1 adversarial verification)

> TX-Value-Verification framework, document 5 of 5.
> Independent 2-axis adversarial sign-off. The framework's whole point: **a green receipt is not a proven feature** — each tx must be judged separately on (1) is it REAL on-chain, and (2) was the intended feature actually MET by the resulting state, not merely that the tx mined.
>
> This document records the Codex (codex:rescue) adversarial pass, the network-limitation found mid-process, the compensating human-side RPC re-derivation, and the per-item resolution of every challenge Codex raised.

## A. Method & limitation

**Method.** Codex (via `codex:rescue`) was handed `02-PLAN.md`, `03-RESULTS.md`, `04-CAPABILITY-MAP.md`, and the CODEX-PROTOCOL rubric, and asked to re-derive every transaction directly from Sepolia RPC on two independent axes:

- **Axis 1 — REAL vs FABRICATED**: does the tx hash exist on-chain, mined, with a receipt whose `to`/selector/logs match the claim?
- **Axis 2 — FEATURE-MET vs NOT-MET**: did the load-bearing L2 state delta asserted in 02-PLAN actually occur (balance/debt/nonce/role/flag), and for ⛔ rows did it revert with the EXACT named selector?

**Limitation found (process finding).** The Codex CLI sandbox has **no outbound network** — `cast`/`fetch` against any RPC returned `Operation not permitted`. Codex therefore **could not independently confirm tx existence** and returned every tx as **AXIS-1 UNVERIFIED**. This is a methodology gap, not a result: **independent on-chain re-derivation must run in a network-enabled environment (e.g. CI with RPC egress).** To compensate for this run, the AXIS-1 verification was performed human-side in a network-enabled shell (section B), and Codex's contribution was scoped to the AXIS-2 / document-consistency adversarial challenge (section C).

## B. AXIS-1 (REAL vs FABRICATED) — independent RPC re-derivation (human-side, network-enabled)

All **82 unique TX hashes** appearing in `03-RESULTS.md` were independently checked via `cast receipt <hash>` against `https://ethereum-sepolia-rpc.publicnode.com` (a different RPC than the suite used, to avoid trusting the harness's own provider).

**Result: 82/82 REAL.** Every hash was found on-chain, mined, with a block number and gas used; **all 82 have `status = 1`**. Zero `NOT_FOUND`, zero `status = 0`. Evidence: `docs/e2e/v5.4.0-beta.1/logs/rpc-independent-verify.txt`.

**Why every mined tx is status=1 (not a contradiction):** the ⛔ negative scenarios are probed via read-only `eth_call` / staticcall, which revert *without* producing a mined transaction. They are real reverts observed off-chain, but they never become `status=0` receipts on-chain. So the absence of any `status=0` row is expected and correct — it is a consequence of how negatives are exercised, not evidence that negatives were skipped. The ⛔ legs are accounted for separately in section C and in 03/04.

## C. AXIS-2 (FEATURE-MET vs NOT-MET) — Codex findings + independent resolution

Codex challenged six areas where a green group might not equal a proven feature. Each was independently resolved:

| Item | Codex finding | Independent resolution | Verdict |
|---|---|---|---|
| **B1 / B2 / B4 full-suite failures** | "Harness-flake claim needs independent confirmation — DOWNGRADE; don't accept self-serving 'it's just a flake'." | Root cause is a harness nonce/mempool defect that SKIPs a *critical* tx instead of serializing the nonce or retrying. Isolated re-runs PASS 100%, and the confirming txs are among the 82 REAL/status=1 set: B1 unpause `0x8cf930c3…`, B2 depositFor `0x1a036bda…`, B4 setTreasury `0x8f8f2e4a…`. B3 (same operator-config contract path as B1) PASSED in the full suite — corroborating the defect is in the runner, not the contract. | **CONFIRMED harness flake, not a contract bug — and now FIXED.** Root cause was `sendTxSafe` in `script/gasless-tests/test-helpers.js` treating a nonce/in-flight conflict as an immediate CRITICAL skip (its retry loop only retried NETWORK errors). Fixed: nonce/in-flight conflicts are now RETRYABLE — the helper waits for the signer's mempool to drain (`_waitMempoolDrain`), re-syncs the nonce, and retries within budget, skipping only after exhausting attempts. Test-infra change only, no contract change. B1/B2/B4 should now pass in-suite. |
| **7.5 EmergencyStop selector** | Reading the doc: "revert `0x4e97bcfc` ≠ named `EmergencyStop` → harden 7.5 to NOT-MET." | Independent decode `cast 4byte 0x4e97bcfc` → **`EmergencyStop()`**. The selector IS the correct named selector; the original doc *under-claimed* by treating it as an unknown error. | **REFUTED — 7.5 is a CLEAN ⛔ PASS.** Independent verification corrected an over-downgrade: the named selector was matched all along. |
| **Credit / debt accrual (scenario 1.2)** | "Live tx went through the BURN branch; `debts[user]` stayed 0; repay skipped → the credit/debt path is UNPROVEN." | **NOW RESOLVED.** The finding was correct for the full-suite run, but the debt branch has since been driven live: sender AA Account A (`0xECD9C07f…dd70`) was drained to 0 xPNTs, then sponsored on the pure-credit path (tx `0x94eed4edd77db3e0a94dad1b0c2d834f60410a3b2edf7ecef0ce6502e1ebf18b`, status 1, block 11070221). Independent RPC read: `debts[AccountA]` 0→**39.759333601280400000 aPNTs**; **xPNTs balance stayed 0 → burn branch NOT taken, `recordDebtWithOpHash` ran**. Burn branch was already proven (#4). | **RESOLVED — PROVEN LIVE.** Debt accrual (+39.76 aPNTs on a zero-balance eligible sender) is on-chain and independently RPC-verified. Only the subsequent `repayDebt` reduction remains unexercised (debt is currently outstanding). |
| **Dual-channel agent (scenario 3.4)** | "Only a read-only eligibility query ran; no no-SBT agent `handleOps` was executed → UNPROVEN." | CONFIRMED unproven-live — but NOT for the reason first recorded. The agent identity registry **IS deployed and wired**: `SuperPaymaster.agentIdentityRegistry()` = `0xc60E7D1d13027Ed63a899926ba1a9A2692f1D9EB` (6988 bytes; `isRegisteredAgent` live & queryable, returns valid bools). The eligibility LOGIC (`sbtHolders \|\| isRegisteredAgent`) shipped and was verified read-only. What is missing is a no-SBT account *registered as an agent* + a real sponsored `handleOps` through the agent channel — neither was set up this run. (Wiring note: `config.agentIdentityRegistry` = `0x8004A818…` differs from the SP-wired `0xc60E7D1d…`; the wired one is operative.) | **UNPROVEN-live (OWED — a test-fixture/coverage gap: register a no-SBT agent + run a live agent-channel op; NOT a deployment gap).** |
| **Negatives unit-tested-only** | "Unit-test coverage ≠ live E2E proof — DOWNGRADE the ⛔ legs that didn't run live." | ACCEPTED. Several ⛔ legs were not executed as live txs this run: rate-commitment (`DRYRUN_RATE_COMMITMENT_VIOLATED`), stale-price (`DRYRUN_STALE_PRICE`), credit-ceiling drain, xPNTs firewall (`UnauthorizedRecipient` / `SingleTxLimitExceeded`), burn replay (`OperationAlreadyProcessed`), unapproved-facilitator (`Unauthorized`). | **DOWNGRADE** to "unit-tested + (where applicable) `eth_call`-observed, **NOT live-exercised this run**". Accurately reflected in 03 §"Negative coverage gaps" and 04 footnotes. |
| **version() integrity** | "On-chain `version()` returns 5.3.3 while the impl is v5.4 → on-chain integrity / provenance risk." | CONFIRMED. Known intentional beta deferral, but it makes betas indistinguishable on-chain — you cannot tell beta.1 from 5.3.3 by querying the contract. | **GA-BLOCKER.** `version()` must equal the exact tag (including `-beta.N`) before GA. Also encoded as a Known-Oversight rule in the methodology. |

## D. Release-level verdict — did v5.4.0-beta.1 achieve its original design?

Honest scorecard, scoped to what is proven on-chain (and independently RPC-verified REAL):

| Capability | On-chain proof status |
|---|---|
| SP xPNTs gasless sponsorship (burn path) | **PROVEN** (REAL tx + asserted xPNTs burn delta) |
| PaymasterV4 independent gasless | **PROVEN** |
| x402 EIP-3009 settlement (native USDC) | **PROVEN** |
| x402 direct settle (xPNTs, C-02) | **PROVEN** |
| `burnFromWithOpHash` replay protection | **PROVEN** (`eth_call` replay revert) |
| Operator funding / config / governance (B1/B2/B3/B4/B5) | **PROVEN** (isolated re-runs, after harness-flake correction) |
| MicroPaymentChannel lifecycle | **PROVEN** |
| Reputation-rule gating | **PROVEN** |
| Oracle price cache update | **PROVEN** |
| Emergency halt (7.5) | **PROVEN** (⛔ `EmergencyStop()` selector confirmed via `cast 4byte`) |
| **Credit / debt accrual branch** | **PROVEN** (REAL tx `0x94eed4ed…` + RPC-verified `debts[user]` 0→39.76 aPNTs, xPNTs stayed 0 → burn branch not taken) |
| **Dual-channel agent `handleOps`** | **UNPROVEN-live (OWED — test-fixture gap)** — registry IS deployed & wired (`SuperPaymaster.agentIdentityRegistry()` = `0xc60E7D1d…`); owed = register a no-SBT agent + run a live agent-channel op |
| Several ⛔ negatives (rate-commitment, stale-price, credit-ceiling drain, firewall, burn replay, unapproved-facilitator) | Unit-tested / `eth_call`-observed, **not live-exercised this run** |

**Bottom line.** The headline gasless + x402 value of v5.4.0-beta.1 is proven on-chain and independently RPC-verified REAL (82/82 hashes, all status=1, plus 3 new credit/debt live-proof txs). The credit/debt accrual branch is now PROVEN LIVE (debt 0→39.76 aPNTs, burn branch not taken, independently RPC-verified), leaving **only ONE owed headline item: the dual-channel agent `handleOps`** — a test-fixture gap (register a no-SBT agent in the already-deployed-and-wired registry `0xc60E7D1d…` + run a live agent-channel op), NOT a deployment gap. The harness nonce/mempool flake behind B1/B2/B4 has been root-caused AND fixed (test-infra change in `test-helpers.js`). The on-chain `version()` still reading 5.3.3 remains a GA blocker that must be fixed before general availability. The adversarial process worked exactly as intended: it caught a real overclaim risk (don't accept "flake" on faith; don't prematurely claim the debt/agent paths), drove the debt branch to a genuine live proof, **and** corrected one over-downgrade (7.5's `EmergencyStop` selector was correct all along).
