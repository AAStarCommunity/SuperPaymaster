# v5.4.0 Mainnet-Deployment Rehearsal — Sepolia (2026-06-16)

> A **fresh, full deployment** run on Sepolia executed exactly as mainnet will be (the canonical
> `./deploy-core <env> --fresh-deploy` → `DeployLive.s.sol` path). The only thing that differs on
> mainnet is the signing-key channel; everything else — contracts, wiring, init data, genesis
> communities, test-token generation, verification — was exercised end-to-end here. The rehearsal
> deliberately surfaced (and fixed) the issues a first-ever clean deploy hits that an
> upgrade-accumulated chain hides.

## 1. Outcome

- **Fresh full deploy: SUCCESS** — `ONCHAIN EXECUTION COMPLETE`, ~19 contracts + full wiring + both
  genesis communities (AAStar `aastar.eth`, Mycelium/MushroomDAO `mushroom.box`), audit Check04–10
  green, Etherscan source-verified (see `deployments/verify.sepolia.contracts-6-16.md`).
- **Two GA blockers resolved automatically by the fresh path:**
  - `version()` now returns **`SuperPaymaster-5.4.0`** (deployed from current source, no stale literal).
  - **`SuperPaymaster.APNTS_TOKEN()` == `config.aPNTs`** (`0x9e66B457…`) — a fresh deploy wires the base
    accounting token directly at `initialize()`, so there is **no `queueSetAPNTsToken` migration and no
    config↔on-chain divergence** (the two beta.1 reconcile items both disappear on a clean deploy).
- **Full E2E: 37/37 effective** after the fixes below (33 PASS on the first pass; the 4 failures were
  all diagnosed to root cause and resolved — none was a SuperPaymaster contract bug).

## 2. New Sepolia addresses (fresh deploy)

Canonical source: [`deployments/config.sepolia.json`](../../../deployments/config.sepolia.json). Key entries:

| Contract | Address |
|---|---|
| SuperPaymaster (proxy) | `0x030025f40d509b1a99547bAEb3795bD27F7182b7` (impl `0x24a94572cfB6Ca6C8dE107431043556D461d8cFf`) |
| Registry (proxy) | `0x3F920B25f8b65988359C372F66F036E48adFc556` (impl `0x1770338C0669d3333473a72CF0c164Ccc640Dc34`) |
| aPNTs (`APNTS_TOKEN` == config.aPNTs) | `0x9e66B457E0ABb1F139FD8A596d00f784eBA2873b` |
| PNTs (Mycelium xPNTs) | `0xC687f8a115D308ECD39658a8EE33bC3c8F75EE31` |
| X402Facilitator | `0x326Fc3413c8A0185b0179B971C69813B6dFD971B` |
| PolicyRegistry | `0x8c2488d46d5447418558c38AA6441720df656094` |
| TimelockController | `0xB734df3c0A1809bc06708512363D368Ac51dF1A2` |

> Prior `v5.4.0-beta.1` addresses (in `docs/e2e/v5.4.0-beta.1/`) are now historical — the fresh deploy
> replaced the Sepolia deployment.

## 3. Issues surfaced by the rehearsal (and how each was resolved)

| # | Issue | Root cause | Resolution | Kind |
|---|---|---|---|---|
| 1 | `prepare-test` reverts `Unauthorized()` at "Configure deployer as SP operator" | `configureOperator` requires `hasRole(PAYMASTER_SUPER, msg.sender)`; on a fresh deploy the deployer holds `COMMUNITY` + `PAYMASTER_AOA` but **not** `PAYMASTER_SUPER` (an upgrade-accumulated chain already had it). `TestAccountPrepare` granted the role to Anni but never to the deployer. | Added a `PAYMASTER_SUPER` grant block for the deployer before `configureOperator`, mirroring the Anni block (idempotent). | **Test-infra fix (committed)** |
| 2 | B1/B2/B4 fail in the full suite (`nonce/in-flight conflict — skipped [CRITICAL]`) | `sendTxSafe` only retried *network* errors; a nonce/in-flight conflict skipped the critical tx instead of retrying. | (Already fixed in #295.) **Validated here:** the full suite shows `draining mempool & retrying` and B1/B2/B4 now **PASS**. | **Validated (fix from #295)** |
| 3 | 3 SuperPaymaster gasless cases fail with **`AA34` (paymaster sig)** | `_creditExceeded`: a fresh `ENDUSER` sits in credit **tier 1 = 100 aPNTs**, but the validate-time charge (maxCost × 1.1 buffer × fee) is ~150 aPNTs → the C-01 credit ceiling rejects the op *before* it can pay by balance. So **no base-tier user can be SP-sponsored** out of the box. | Raised `creditTierConfig[1]=[2]` from 100 → **300 aPNTs** on Sepolia (covers the charge, keeps tier monotonicity ≤ tier3). **Not changed in contract code** — see §4. | **Config decision (live on Sepolia; mainnet value is yours)** |
| 4 | I1 + `check-contracts` print stale-version failures/warnings | Tests hard-coded the old version strings (`5.3.3`, `Registry-4.1.0`, …); the contracts are correctly v5.4. | Updated the asserted/expected versions to the v5.4 strings. | **Test-hygiene fix (committed)** |

## 4. ⚠️ Decision required before GA — base credit tier

The default `creditTierConfig` (set in `Registry.initialize`) is `[1]=100, [2]=100, [3]=300, [4]=600,
[5]=1000, [6]=2000` aPNTs. A normal SuperPaymaster-sponsored tx costs **~50 aPNTs actual** / **~150
aPNTs at validate-time (buffered max)**, so the **100-aPNTs base tier is below the validate ceiling** —
a brand-new ENDUSER cannot be SP-sponsored until they reach a higher tier (via reputation) or their
credit limit is raised.

This is an **economic/product parameter**, not a contract bug, so it was **not changed in code**. Mainnet
must choose one before GA:
- **(a)** Raise the base tiers in `Registry.initialize` / a post-deploy `setCreditTier` so new users are
  immediately sponsorable (chosen-onboarding-UX vs operator-drain risk), or
- **(b)** Seed genesis users with reputation/credit, keeping the conservative 100-aPNTs base.

The Sepolia rehearsal applied (a) live (`setCreditTier(1,300)`, `setCreditTier(2,300)`) purely to make the
E2E representative; the permanent value is an ops/product call.

## 5. Still owed (TX-Value-Verification follow-up, non-blocking)

The full 5-document TX-Value-Verification pass for this fresh deployment (live agent-channel `handleOps`,
`repayDebt` cycle, live negative ⛔ assertions, full-set independent RPC re-derivation, Codex 2-axis
challenge) is the documentation layer on top of this record — to be produced next, mirroring
`docs/e2e/v5.4.0-beta.1/`.
