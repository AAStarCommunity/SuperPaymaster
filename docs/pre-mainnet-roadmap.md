# SuperPaymaster — Pre-Mainnet Roadmap & Security Posture

> Status as of 2026-05-31 · Target: SuperPaymaster-5.3.3 (`v5.3.3-beta`) on Sepolia → Mainnet
>
> This document is a planning artifact. It records **objectively** what testing /
> review has been completed, states honestly what has **not** been done, and lays
> out a concrete checklist to reach mainnet-grade assurance.

---

## 0. Current state (facts)

- **Contract**: `SuperPaymaster-5.3.3` (unified aPNTs debt accounting), deployed on Sepolia at `0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a` (proxy; impl `0x8E2d93Bb…`).
- **Source ↔ chain integrity**: the on-chain deployment was **hash-verified** to match the current source tree — `srcHash` of `contracts/src/*.sol` (excl. mocks) == the value stored at deploy time (`4127b28b…884b7f2`). i.e. **what was tested is byte-for-byte what is deployed.**
- **Architecture**: UUPS proxies (Registry, SuperPaymaster); pointer-replacement upgrade for the rest. EntryPoint v0.7.

---

## 1. What testing & review HAS been completed (objective record)

This section is a neutral statement of work done — neither a guarantee of correctness nor a marketing claim.

### 1.1 Unit tests
- **`forge test`: 961 / 961 passing**, 0 failed, 0 skipped (74 test suites).
- Compiler: Solidity 0.8.33, optimizer 10k runs, via-IR, Cancun.

### 1.2 On-chain end-to-end (Sepolia)
- **33 E2E groups: 31 PASS + 2 SKIP + 0 FAIL.**
- The 2 SKIPs are **verified environmental** (transient RPC timeout; price-cache staleness), not contract faults — each re-runs clean once the precondition is met.
- The **credit/debt sponsored-UserOp path was exercised end-to-end on-chain for the first time** (previously it was being skipped). Real sponsored UserOp landed on Sepolia (xPNTs burn + debt accounting verified).

### 1.3 Adversarial code review
- **6 rounds of independent adversarial review (Codex)** on the test harness, deployment scripts, and SDK sync, with each round's findings evaluated, fixed, and re-reviewed. One finding was identified as a false positive on verification (not blindly accepted).
- **Prior internal security reviews** of the contracts: `docs/security/2026-04-25-review.md` (+ `-zh`), `docs/security/2026-04-26-p0-prelaunch.md`. Several findings from those reviews have since been remediated (verified against current source — see §3).

### 1.4 Coverage (forge, `--ir-minimum`)
- Overall: **65.75% lines / 74.11% statements / 68.62% branches / 38.56% functions**.
- Core contract line/branch coverage (the figure that matters for risk):

  | Contract | Lines | Branches |
  |---|---|---|
  | Registry | 95.71% | 67.50% |
  | SuperPaymaster | 90.56% | 71.65% |
  | xPNTsToken | 91.32% | 68.42% |
  | MySBT | 96.67% | 80.95% |
  | GTokenStaking | 90.76% | 72.73% |
  | GTokenAuthorization | 100.00% | 75.00% |
  | ReputationSystem | 97.83% | 100.00% |
  | MicroPaymentChannel | 93.18% | 60.71% |
  | BLSAggregator | 89.19% | 64.81% |
  | DVTValidator | 95.65% | 76.47% |
  | PaymasterBase | 92.89% | 68.33% |
  | **utils/BLS.sol** | **2.86%** | **0.00%** |

---

## 2. The honest gap (what this does NOT prove)

**Testing demonstrates the presence of correct behaviour on tested paths; it does not prove the absence of bugs.** Specifically, before mainnet the following are open:

1. **No full external/third-party audit.** All review to date is internal + adversarial-LLM. The first-audited V5.3 surface (x402 / agent economy / EIP-1153 transient cache / ticket model) has only had internal review.
2. **Branch coverage is materially below 100%** on critical contracts — e.g. SuperPaymaster **71.65%** branches (~28% of conditionals unexercised), MicroPaymentChannel **60.71%**, BLSAggregator **64.81%**. Bugs concentrate in untested branches.
3. **`utils/BLS.sol` direct coverage is 2.86%.** The BLS12-381 pairing crypto is exercised only indirectly via aggregator integration tests. For a contract whose job is to *reject forged proofs*, this is the highest-leverage gap.
4. **GToken.sol at 50% lines** (low-risk surface but should be closed).

> Bottom line: appropriate confidence for a **Sepolia beta**; **not** sufficient to custody real value on mainnet without the P0 items below.

---

## 3. Prior findings — remediation status (verified against current source)

Spot-checks confirm the 2026-04-25 review is **stale** (several "未修复" items are now fixed). Before mainnet, run a fresh pass to confirm ALL prior P0/P1 are closed. Verified-fixed examples:

| Finding | 2026-04-25 status | Current source | 
|---|---|---|
| H-01: `GTokenStaking.slash` doesn't write back to Registry | 未修复 | ✅ Fixed — `_syncRegistry(user, roleId, …)` (P0-14) |
| B2-N1: `setAPNTsToken` instant owner rug/freeze | 未修复 | ✅ Mitigated — now timelocked (`pendingAPNTsToken` + `APNTS_TOKEN_TIMELOCK`) |
| B2-N12: `retryPendingDebt` no auth | High | ✅ Fixed — now `onlyOwner` |
| Chainlink `answeredInRound` discarded | Info | ✅ Fixed — `if (answeredInRound < roundId) revert OracleError()` (validation path) |

**Action**: a fresh confirmation review must close out the remaining items in `2026-04-25-review.md` (e.g. M-04 `MAX_SINGLE_TX_LIMIT` sizing for L1 gas, I-01 `protocolRevenue` dual-semantics 2-pool split) and re-validate the INV-03 solvency invariant.

---

## 4. Pre-mainnet roadmap

### P0 — Blocking (must complete before mainnet)
- [ ] **Full third-party security audit** (scope: whole `contracts/src`, with explicit emphasis on the first-audited V5.3 surface — x402 settlement / EIP-3009, agent sponsorship policy, EIP-1153 transient cache, ticket model, dual-channel eligibility).
- [ ] **BLS audit + tests**: dedicated audit of `utils/BLS.sol` + `BLSAggregator` (pairing correctness, malicious/forged-proof rejection, signerMask handling, EIP-2537 precompile edge cases). Raise BLS unit coverage from 2.86% → meaningful (target ≥80% on the verification path).
- [ ] **Critical-path branch coverage ≥ 90%** for SuperPaymaster, xPNTsToken, MicroPaymentChannel, BLSAggregator (currently 71.65% / 68.42% / 60.71% / 64.81%). Enumerate uncovered branches via `forge coverage --report lcov` and write targeted tests.
- [ ] **Fresh confirmation review**: close every open item from `2026-04-25-review.md`; re-prove the INV-03 solvency invariant (`protocolRevenue + Σ aPNTsBalance + pending == totalTrackedBalance`) with an invariant/fuzz test.
- [ ] **Echidna/invariant campaign** (configs already present: `echidna*.yaml`) — long run on solvency, debt monotonicity, voucher cumulative monotonicity, spending-limit.

### P1 — Test coverage build-out
- [ ] Cover the ~28% uncovered SuperPaymaster branches (validation rejection paths, postOp debt/insolvency fallbacks, agent-policy tiers, x402 settle paths).
- [ ] MicroPaymentChannel → ≥90% branch (close/settle/topUp/finalization edge cases).
- [ ] GToken.sol → ≥90% lines.
- [ ] Negative-path E2E expansion (the hardened harness now distinguishes precondition-SKIP vs real-FAIL — add explicit RATE_COMMITMENT_VIOLATED / USER_BLOCKED / INSUFFICIENT_BALANCE assertions).

### P2 — SDK / client (tracked in aastar-sdk)
- [ ] **aastar-sdk #34**: fix client code that still assumes the old ABI — `operator.ts` (operators() 10-tuple → 9-tuple, exchangeRate now from `xPNTsToken.exchangeRate()`), `configureOperator` 2-arg, `registry.ts` `setBLSValidator` → `setBLSAggregator`. **These fail at runtime today.**
- [ ] Merge ABI/address sync (**PR #33**) + keeper script (**PR #37**).
- [ ] `npm publish` new `@aastar/core` + `@aastar/sdk` once #33/#34 land.

### P3 — Operational readiness
- [ ] **Price keeper 24/7** (PR #37 `run-keeper.sh`) on a persistent host (Mac mini). Must refresh BOTH SuperPaymaster AND the *operator's* PaymasterV4 (note: E2E uses the deployer's V4, not the canonical/Anni V4 — confirm which V4(s) are live in production and keep them all fresh).
- [ ] **Monitoring/alerting**: keeper health (Telegram already wired), Chainlink feed staleness, operator solvency, ProtocolRevenueUnderflow events, pendingDebts growth.
- [ ] **Incident runbook**: operator insolvency, oracle outage, paymaster pause, BLS aggregator hot-swap (24h timelock), emergency break-glass.

### P4 — Deployment & upgrade safety
- [ ] **UUPS storage-layout verification** before any upgrade (`forge inspect … storage-layout`); upgrade rehearsal on a fork (`UpgradeLive.s.sol` is now compile-clean + tolerant-load).
- [ ] **Ownership → multisig (Safe)** for Registry/SuperPaymaster owners + DAO roles before mainnet; dry-run an `onlyOwner` call from the Safe before `transferOwnership`.
- [ ] **Ownable2Step** migration evaluated (UUPS doc Appendix D.1 #6): deferred to mainnet **clean redeploy** (storage-collision blocker on existing proxies). Decide redeploy vs accept single-step at mainnet.
- [ ] Confirm deploy-scripts on a fresh fork end-to-end (`DeployLive.s.sol` now compiles + serializes `registryImpl`; `TestAccountPrepare` guards keystore-only misuse).

---

## 5. One-line summary for external comms

> "SuperPaymaster 5.3.3 (Sepolia beta) passed 961 unit tests + 33 on-chain E2E groups (0 failures) and 6 rounds of adversarial review; the deployed bytecode is hash-verified against the tested source. A full third-party audit and expanded BLS/branch test coverage are planned before mainnet."

(Do **not** state "bug-free" or "audited" — neither is true yet.)
