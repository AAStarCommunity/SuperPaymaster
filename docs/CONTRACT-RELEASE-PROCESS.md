# SuperPaymaster — Ideal Contract Release Process

> The end-to-end process for shipping a contract release, beta → mainnet.
> Two halves, merged: **(A) code verification** (tool pipeline) +
> **(B) release preparation** (review, deploy list, scripts, docs, changelog).
> Verification detail lives in [`security/security-validation-pipeline.md`](security/security-validation-pipeline.md);
> findings live in dated `security/<date>-*.md` reports.

---

## Phase 0 — Version & branch

- **Beta channel**: `vMAJOR.MINOR.PATCH-beta.N` (e.g. `v5.3.4-beta.1`), iterate `-beta.2 → -rc.1 → final`.
- **Branch**: `release/vX.Y.Z-beta.N` cut from the merged main tip.
- **Version source of truth**: the contract `version()` string must match the tag's MAJOR.MINOR.PATCH. A tag bump WITHOUT a `version()`/bytecode change is only allowed for off-chain-only releases — and then prefer re-tagging the same version, not inventing a new number.

> **Current SuperPaymaster**: `version() == "SuperPaymaster-5.3.3"`, tag `v5.3.3-beta` (points at main, includes the full test/tooling hardening). The next release that lands the P0 security fixes **changes the bytecode**, so it earns a real bump → **`v5.3.4-beta.1`**.

---

## Phase 1 — Code verification (the pipeline)

Run the staged pipeline (see the pipeline doc for exact commands & gates):

1. **Authoring** — `solhint` + `forge fmt --check` + `forge build --sizes` (EIP-170).
2. **Test + fuzz** — `forge test` (unit) + `forge test --fuzz-runs 10000` + `forge coverage` (critical contracts ≥ 90% branch).
3. **Static** — `slither` (gate High/Medium). *Note: via-IR support is partial; pair with mythril + manual.*
4. **Deep** — `mythril` symbolic exec on critical contracts + `forge invariant` (10k+, INV-03 solvency) + `echidna` campaigns.

Gate: no open High/Medium static finding; invariants hold; coverage thresholds met.

---

## Phase 2 — Security review (full sweep / "totto")

| # | Scope | Who |
|---|---|---|
| 2.1 | Full adversarial source sweep — **Codex × local-model PK**, every CRITICAL re-verified line-by-line against source (never accept a finding on trust; also flag false positives). | Codex + local |
| 2.2 | Cross-contract invariants — solvency (INV-03), debt monotonicity, voucher cumulative monotonicity, spending-limit, role/permission matrix across all entry points. | manual + Codex |
| 2.3 | External-attacker modeling — enumerate every `external`/`public` mutating function: who can call it? access control? what state does it change? Build the access-control matrix. | systematic |
| 2.4 | Known-Issues cross-ref — each prior KI: still valid? severity change? new KI? Re-verify prior reports aren't stale (e.g. 2026-04-25 had several since-fixed items). | doc cross-ref |
| 2.5 | **Findings closure** — every P0 closed, each with a regression test that fails-on-old / passes-on-fixed (these double as the missing coverage). | — |

Output: a dated `security/<date>-...-findings.md` report + a closure table. **No release while any P0 is open.**

---

## Phase 3 — Release preparation

### 3.1 Contract deployment list
- **New / changed contracts** this release (vs the previously-deployed version) — diff `version()` + `srcHash`.
- **Reused contracts** (unchanged) — EntryPoint v0.7, price feed, etc.
- Per contract: constructor args, dependency graph, **deploy order (DAG)**.
- **Wiring steps** post-deploy (`setStaking`/`setMySBT`/`setSuperPaymaster`/`setAuthorizedSlasher`/agent registries…) with order + atomicity risk.

### 3.2 Deploy script check
- Does `DeployLive.s.sol` / `UpgradeLive.s.sol` cover every new contract? Diff `src/` vs the script.
- **Dry-run / fork test** the deploy end-to-end (`forge script … --fork-url`).
- Post-deploy **Etherscan verify** step present.
- `srcHash` is recomputed and written to `deployments/config.<net>.json` (skip-if-unchanged logic).

### 3.3 Deployment doc
- New `docs/DEPLOYMENT-vX.Y.Z-beta.N.md` (template from the prior one): full contract list / deploy order / constructor args / wiring / env vars / verify / **address table (left blank for the real deploy)**.
- **Pre-flight checklist**: RPC healthy, deployer balance, EntryPoint/price-feed addresses, role/owner = expected Safe, etc.
- **Post-deploy smoke test**: a real sponsored UserOp lands, keeper updates price, key wiring reads back correct. (Our 33-group E2E suite is this smoke test.)

### 3.4 Operational readiness
- **Price keeper** running 24/7 (`run-keeper.sh`), refreshing SuperPaymaster **and every live PaymasterV4** (note: E2E uses the deployer's V4, distinct from the canonical/community V4).
- Monitoring/alerting: keeper health, Chainlink staleness, operator solvency, `ProtocolRevenueUnderflow`, `pendingDebts` growth.
- Incident runbook: operator insolvency, oracle outage, paymaster pause, BLS aggregator hot-swap (24h timelock), break-glass.

---

## Phase 4 — Changelog / release notes / version

- `CHANGELOG.md` section for `vX.Y.Z-beta.N`: features, fixes (with finding IDs), review rounds, ABI regen.
- Bump `version()` strings, `docs/` version headers, SDK ABI/address sync (separate SDK PR).
- `gh release create vX.Y.Z-beta.N` notes (tag **after** merge; beta prep only writes the docs/scripts, doesn't tag yet).

---

## Phase 5 — Release gate (mainnet)

- [ ] Full third-party audit signed off.
- [ ] All P0 findings closed + regression-tested.
- [ ] Critical-contract branch coverage ≥ 90%; `BLS.sol` verification path covered.
- [ ] Invariant + echidna long-run clean.
- [ ] Ownership → multisig (Safe); deploy/upgrade rehearsed on a fork.
- [ ] Deployment doc + address table + smoke test complete.

---

## How this release stands today (SuperPaymaster 5.3.3 → 5.3.4-beta.1)

| Phase | Status |
|---|---|
| 1 Verification | partial — unit/E2E ✅, fuzz/invariant/slither/mythril ❌ (tools now installing) |
| 2 Security review | **done a sweep** — Codex×local PK found **4 Critical + 2 High** (see `security/2026-05-31-pk-audit-findings.md`); **P0 NOT yet closed** |
| 3 Release prep | deploy scripts compile-clean (DeployLive/UpgradeLive/TestAccountPrepare fixed); deploy doc + address table TBD |
| 4 Changelog/version | next bump = `v5.3.4-beta.1` once P0 fixes land |
| 5 Release gate | **blocked** on P0 closure + external audit |

**Bottom line**: not releasable to mainnet until the Phase-2 P0s are fixed + a real audit. Sepolia beta is fine for testing with trusted operators and x402 disabled.
