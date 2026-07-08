# Deployment / upgrade runbook — security hardening (C-01..C-04, H-01, H-02)

Date: 2026-06-01 · main @ `65700d06` · `forge test` 979 passed / 0 · SuperPaymaster 24,159 B (EIP-170 OK).
Revised after Codex review (addresses 14 blockers — coverage map at the end).

## SCOPE — differs by network (read first)

The scope below is the **MAINNET** plan. **Sepolia was deployed FULL** (see status box).

> ### ✅ Sepolia — DEPLOYED 2026-06-02 (ALL 6 fixes, incl. H-02)
> - SuperPaymaster UUPS upgrade (C-01..C-04 + H-01): impl `8e2d93bb`→`52c1e6f0`; state preserved.
> - BLSAggregator (H-02): redeployed `0x7ec72505…d3e9` + rewired; switch OFF. Old `0xCDCdb8e2…0276`.
> - On sepolia the BLS key set was empty (no validator-key migration needed), so H-02 was
>   deployed alongside SP. **Open item: E2E TC2/TC4 `CREDIT_EXCEEDED` — root-cause before mainnet.**

### MAINNET plan (not yet executed)

**Upgrade SuperPaymaster ONLY** (C-01..C-04, H-01 — UUPS, low-risk). **Defer H-02** to
Appendix B as a separate runbook: its switch defaults **OFF** (zero behaviour change), while
redeploying the non-UUPS BLSAggregator on a network with live validators is high-risk
(key migration + in-flight DVT proposals) — unlike sepolia where the key set was empty.
- [ ] **MAINNET SIGN-OFF**: `__________` confirms H-02 is deferred on mainnet and the
      production release of the 4 Criticals + H-01 without H-02 is accepted.

GTokenStaking (slither comments only) and Registry (unchanged) are **not** redeployed.

---

## Environment matrix (verify before touching any network)

| env | `.env` | config | chainId | Registry proxy | SP proxy | notes |
|---|---|---|---|---|---|---|
| op-sepolia | `.env.op-sepolia` | `config.op-sepolia.json` | 11155420 | `0x9976…24e7` | `0xA2c9…140E` | staging |
| sepolia | `.env.sepolia` | `config.sepolia.json` | 11155111 | `0xB5Fb…eF1A` | `0xFb09…266a` | staging |
| optimism | `.env.optimism` | `config.optimism.json` | 10 | `0x9976…24e7` | `0xA2c9…140E` | ⚠️ same addrs as op-sepolia — **verify before use** |
| op-mainnet | `.env.op-mainnet` | `config.op-mainnet.json` | 10 | *(empty)* | *(empty)* | ⚠️ config not populated — confirm target |

- [ ] Confirm the production target + that its config has the REAL proxy addresses.
- [ ] **Chain-id guard (every command)**: `test "$(cast chain-id --rpc-url $RPC_URL)" = "$CHAIN_ID"` — abort on mismatch. `UpgradeLive` reads the config from `ENV` (`vm.envOr("ENV", "sepolia")`); `ENV`, `$RPC_URL`, and the on-chain chainId MUST all agree or the upgrade hits the wrong network/config.

---

## Known side effects of `UpgradeLive.s.sol` (must understand before running)

1. **Writes `deployments/config.<env>.json` via `vm.writeJson` (lines 122–126) — in SIMULATION too.** A dry-run overwrites the live config with phantom addresses. → back up + `git checkout` around every dry-run (see Phase 1).
2. **Upgrades Registry as well as SP** (deploys a new Registry impl + `upgradeToAndCall`). Registry was NOT changed here. → use the SP-only path (Phase 1 step A) or prove Registry bytecode is unchanged.
3. **Auto-deploys `MicroPaymentChannel` if missing** and patches it into config (line ~101). Confirm MPC already exists on the target (so this no-ops) or explicitly accept it.

---

## Phase 0 — pre-flight, per environment (ABORT on any failure)

- [ ] `git checkout main && git pull` → HEAD ≥ `65700d06`; `forge test` 979/0; `forge build --sizes --skip test --skip script` exit 0.
- [ ] `source .env.<env>` ; chain-id guard passes.
- [ ] **[CRITICAL] Storage-layout compatibility.** UUPS keeps proxy storage; new vars must sit in `__gap`/at the end with no existing slot moved.
  ```bash
  forge inspect SuperPaymaster storage-layout > /tmp/sp.new.layout
  # compare to the layout of the CURRENTLY DEPLOYED impl (check out its commit/tag, or
  # use a saved baseline) → diff slot/offset/type; ANY change to an existing slot, or a
  # new var not absorbed by __gap, ABORTS the upgrade.
  ```
  - [ ] Confirm C-02/C-03 storage (`x402SettlementNonces`, `agentPolicies`, fee maps, etc.) consumed `__gap` and left existing slots intact. Record remaining `__gap`.
- [ ] **[CRITICAL] Capture rollback state**: read the SP proxy's EIP-1967 impl slot and save it as `previousSpImpl` for this env:
  ```bash
  cast storage <SP_PROXY> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $RPC_URL
  ```
  Record `previousSpImpl=…` (and, if the Registry leg runs, `previousRegistryImpl`).
- [ ] **Operator snapshot** (for diff after upgrade): for each known operator, record `operators(op)` → `aPNTsBalance, isConfigured, isPaused, xPNTsToken, reputation, minTxInterval, treasury, totalSpent, totalTxSponsored`.
- [ ] **EntryPoint deposit/stake**: `cast call <ENTRYPOINT> "balanceOf(address)(uint256)" <SP_PROXY>` ≥ operational threshold (and staked if required). Record.

---

## Phase 1 — SuperPaymaster UUPS upgrade (op-sepolia → sepolia → production)

**A. SP-only upgrade (avoid touching Registry).** Choose ONE:
- [ ] **Preferred**: add an `ONLY_SP=true` guard to `UpgradeLive.s.sol` so it skips the
      Registry impl deploy + `upgradeToAndCall(registry,…)` leg, and use it; OR
- [ ] **Interim**: run as-is but first prove the new Registry impl bytecode `==` the current
      one (`cast code` of current Registry impl vs `forge inspect Registry bytecode`); if not
      equal, ABORT (Registry would change unexpectedly).

**B. Run (per env), config-safe:**
- [ ] `cp deployments/config.$ENV.json /tmp/config.$ENV.bak`
- [ ] Dry-run (no broadcast): `forge script contracts/script/v3/UpgradeLive.s.sol:UpgradeLive --rpc-url $RPC_URL -vvvv` → review the planned new impl + version bump.
- [ ] **Restore config** (discard simulation's `vm.writeJson`): `git checkout -- deployments/config.$ENV.json`
- [ ] Re-check chain-id guard.
- [ ] Broadcast: `… --broadcast --account $DEPLOYER_ACCOUNT` (the keystore signer). This run's config write is the real one — commit it.

**C. Post-upgrade verification (ALL must pass; ABORT/rollback otherwise):**
- [ ] `SuperPaymaster(proxy).version()` bumped; `Registry(proxy).version()` unchanged (SP-only).
- [ ] **Operator diff**: re-read `operators(op)` for each snapshot operator → identical `aPNTsBalance/isPaused/xPNTsToken/treasury/fee`. Any drift ⇒ storage-packing problem ⇒ rollback.
- [ ] **EntryPoint deposit/stake** unchanged and ≥ threshold.
- [ ] **Run the full check suite**: `Check01`–`Check09` + `VerifyV3_1_1` (in `contracts/script/checks/`) all green.
- [ ] **Price freshness**: restart the price keeper and/or call `updatePrice()`; confirm `cachedPrice.updatedAt` is fresh (within `priceStalenessThreshold`) — stale cache silently fails every UserOp.
- [ ] **x402 behaviour**: a settle with a valid `X402PaymentAuthorization` succeeds; an old/unsigned settle **reverts** (C-02/C-03 live).
- [ ] Save the new `spImpl` + the `previousSpImpl` (Phase 0) into `deployments/config.$ENV.json` for rollback; commit + re-extract ABIs (`scripts/extract_v3_abis.sh`) + `sync_to_sdk.sh`.

**D. Go/No-Go for production (after BOTH testnets):**
- [ ] Soak on op-sepolia + sepolia ≥ **48 h** with: ≥ N real sponsored UserOps succeeding, ≥ 1 valid x402 settle + 1 rejected unsigned settle, keeper freshness maintained, **zero** operator-config drift, zero unexpected reverts.
- [ ] Named sign-off recorded: `__________`.

---

## Phase 1.5 — x402 production prerequisite (HARD GATE before mainnet)

C-02/C-03 make `settleX402Payment*` revert without the new EIP-712 signature, so the moment
the new impl is live on mainnet, **any pre-existing unsigned x402 flow breaks**.
- [x] **aastar-sdk #39 CLOSED** — `@aastar/sdk@0.29.0` ships `@aastar/sdk/x402` with full
      `X402PaymentAuthorization` signing. DVT facilitator module live (YetAnotherAA-Validator
      #130–134 merged). x402 gate unblocked for mainnet GA.
- [ ] (Defense in depth) AirAccount KMS #16 / PR #20 (passkey-bound signing) merged.

---

## Rollback — SuperPaymaster

- [ ] `upgradeToAndCall(previousSpImpl, "")` on the SP proxy (address captured in Phase 0).
      State is preserved (UUPS). Verify `version()` reverts to the prior value + operator diff clean.

---

## Appendix B — H-02 BLSAggregator redeploy runbook (DEFERRED, separate execution)

BLSAggregator is **not** a proxy; a redeploy starts with an EMPTY key set and orphans
in-flight DVT state. Do NOT run this with Phase 1.

1. **Freeze**: stop DVT slash-proposal creation/execution for the maintenance window.
2. **Snapshot in-flight state** from the OLD aggregator + DVTValidator: open `aggregatedSignatures`, `executedProposals`/`proposalNonces`, and `DVTValidator` proposal status. Resolve or explicitly cancel every OPEN proposal (execution history must not split across two aggregators).
3. **Export the key manifest** from the old aggregator: for `slot` in `1..MAX_VALIDATORS(13)`, `validatorAtSlot(slot)` → `validator`, then `getBLSPublicKey(validator)` → `(pk, slot, isActive)`. Record `validator, slot, pk, isActive` + each validator's ROLE_DVT + locked stake.
4. **Deploy** `new BLSAggregator(registry, superPaymaster, dvt)`; record `oldAggregator` first.
5. **Re-register** every active validator's key at the SAME slot via the owner path
   `registerBLSPublicKey(validator, pk, slot, <empty G2 PoP>)`; verify slot mapping matches the manifest.
6. **Re-wire**: `Registry.setBLSAggregator(new)`, `DVTValidator.setBLSAggregator(new)`,
   `GTokenStaking.setAuthorizedSlasher(new, true)`; then `setAuthorizedSlasher(old, false)`.
7. **Verify** a fresh slash proposal aggregates + executes on the new aggregator.
8. Keep `permissionlessBLSRegistration` **OFF**.

**Rollback (BLS):** `Registry.setBLSAggregator(old)` + `DVTValidator.setBLSAggregator(old)` +
`GTokenStaking.setAuthorizedSlasher(old, true)` + `setAuthorizedSlasher(new, false)`; no BLS
proposal execution during the window.

---

## Codex finding → coverage map

| # | Codex blocker | Addressed in |
|---|---|---|
| C-1 | storage layout not verified | Phase 0 storage-layout diff |
| C-2 | Registry upgrade ambiguous | Phase 1.A (SP-only / bytecode-equal) |
| C-3 | H-02 in scope but deferred | Scope decision (removed + sign-off) |
| C-4 | BLS in-flight proposals | Appendix B steps 1–2 |
| C-5 | x402 cutover breaks prod | Phase 1.5 hard gate |
| C-6 | SP rollback addr not captured | Phase 0 capture `previousSpImpl` |
| H-7 | BLS key export wrong fn | Appendix B step 3 (`getBLSPublicKey`, enumerate slots) |
| H-8 | BLS rollback incomplete | Appendix B rollback (3 wiring points + slasher revoke) |
| H-9 | EntryPoint deposit/stake | Phase 0 + 1.C |
| H-10 | keeper/updatePrice | Phase 1.C price freshness |
| H-11 | check scripts omitted | Phase 1.C Check01–09 + VerifyV3_1_1 |
| H-12 | operator config diff | Phase 0 snapshot + 1.C diff |
| H-13 | go/no-go criteria | Phase 1.D soak + sign-off |
| H-14 | env coverage | Environment matrix |
| M-15 | UpgradeLive side effects | "Known side effects" section |
