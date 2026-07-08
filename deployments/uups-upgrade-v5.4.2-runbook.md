# UUPS Upgrade Runbook — SuperPaymaster v5.4.1 → v5.4.2 (CC-13, #333)

**Nature of change:** in-place UUPS impl swap. The proxy **address is unchanged**
(`superPaymaster` in `deployments/config.<net>.json`). Therefore
BLSAggregator / DVTValidator / validator registrations / slots / SDK addresses
**all stay wired** — no aggregator re-deploy, no re-registration, no CC-18-style
address switch. `_authorizeUpgrade` is `onlyOwner` with **no timelock** → a single
immediate owner tx (unlike the BLS_AGGREGATOR swap which had a 24h timelock).

The only genuinely new surface: **one appended storage slot** (`_blsSlashCd`,
`__gap` 30→28, two slots) + **one new ABI method** (`isSlashPending`) + **changed `queueSlash`
behavior** (BLS path reverts `SlashCooldown` within the 1h window).

---

## 0. Pre-flight (before broadcasting)

- [ ] PR #334 merged to `main`.
- [ ] `forge test` green on `main` (1103/1103).
- [ ] Storage-layout snapshot diff — confirm `_blsSlashCd` is **appended** and no
      existing slot moved:
      `forge inspect SuperPaymaster storage-layout --extra-output storageLayout`
      → the only delta vs the deployed impl must be `_blsSlashCd` at the slot right
      after `_pendingSlash` (`_blsSlashCd` then `_blsSlashCdFloor`, two slots), and `__gap`
      length 30→28. **If any prior var moved, STOP.**
- [ ] `.env.sepolia` loaded; `DEPLOYER_ACCOUNT` = the SP proxy **owner** key.

## 1. Execute the upgrade (single owner tx, no timelock)

```
source .env.sepolia && forge script contracts/script/v3/UpgradeToV5_4_2.s.sol:UpgradeToV5_4_2 \
  --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast -vvvv
```

The upgrade is done via `upgradeToAndCall(newImpl, encodeCall(primeBlsSlashCooldown))`
— the impl swap **and** the global BLS-cooldown floor prime land in **one atomic tx**.
The floor (`_blsSlashCdFloor = now + 1h`) closes the **cold-start window**: right after the
upgrade `_blsSlashCd` is empty, so an operator BLS-slashed shortly before the upgrade would
have no recorded cooldown — the floor blankets ALL operators for one window (owner path exempt).
Expect: **no BLS slash executes for ~1h after the upgrade** (by design); owner `slashOperator`
still works.

The script **codifies** the critical checks (reverts if any fail):
- [ ] `version() == "SuperPaymaster-5.4.2"`
- [ ] storage integrity: `owner`, `APNTS_TOKEN`, `treasury`, `BLS_AGGREGATOR`,
      `protocolFeeBPS`, `aPNTsPriceUSD` **unchanged** across the swap
- [ ] `isSlashPending(0x0) == false` (new fn live)
- [ ] `BLS_AGGREGATOR == config.blsAggregator` (slash wiring intact)
- [ ] `BlsSlashCooldownPrimed(floorUntil)` event emitted (floor primed atomically)
- [ ] auto-patches `config.<net>.json`: `spImpl`, `srcHash`, `updateTime`

## 2. On-chain wiring re-verification (defense against "missed wiring")

These are **preserved** by UUPS (storage untouched) but re-verify explicitly —
they are the links the slash path depends on:

- [ ] `SP.BLS_AGGREGATOR()` == `0xF51c029879685Ced8fbCfa4b647c2eAe50Cd8B13`
- [ ] `Registry.blsAggregator()` == `0xF51c…8B13`
- [ ] `GTokenStaking.setAuthorizedSlasher(0xF51c…8B13)` still `true`
      (Tier-2 slash; on staking, not touched by the SP upgrade — but confirm)
- [ ] `DVTValidator(0x568b1486…).isValidator(Jason/Anni/Bob)` all `true`
- [ ] `BLSAggregator.validatorAtSlot(1/2/3)` == Jason / Anni / Bob
- [ ] `BLSAggregator.slashThresholds` == 2 / 3 / 3 (WARNING/MINOR/MAJOR)

## 3. Behavioral smoke test (the new cooldown path)

- [ ] Dry-run (staticCall) a full slash on a synthetic over-limit operator:
      `queueSlashWithProof → queueSlashWithConsensus → SP.queueSlash` (first slash:
      `_blsSlashCd == 0` → passes) then `executeWithProof → SP.executeSlashWithBLS`.
- [ ] Confirm a **second** `SP.queueSlash` for the same operator within 1h reverts
      `SlashCooldown` (the fix), and succeeds after `> 1h`.
- [ ] Confirm an **owner** `slashOperator` is NOT blocked by a recent BLS slash and
      vice-versa (F2 decoupling: separate `_slashCd` vs `_blsSlashCd`).

## 4. Downstream sync (off-chain — the easy-to-miss tail)

- [ ] `abis/` — re-extract `SuperPaymaster.json` (adds `isSlashPending`; no breaking
      change) via the ABI extraction script, then `./sync_to_sdk.sh`.
- [ ] **@repo:sdk** (their repo — issue/notify, don't PR): new SP ABI
      (`isSlashPending`); behavioral note that `queueSlash` reverts `SlashCooldown`
      within the window. Address unchanged → no address bump needed.
- [ ] **@repo:dvt** (Cooperation-Center CC-13): adopt `isSlashPending` getter (retire
      event-reconstruction); their raced re-queue now reverts at `SP.queueSlash`
      (staticCall pre-flight catches it). Already announced in CC-13.
- [ ] `deployments/config.<net>.json` — confirm `spImpl` / `srcHash` / `updateTime`
      patched (done by script); commit the config diff.
- [ ] `./version-check-onchain.sh` — confirm reports `SuperPaymaster-5.4.2`.
- [ ] Add a deploy-record note under `deployments/` (mirror prior records) with the
      new `spImpl` address + upgrade tx hash.

## 5. Not part of this upgrade (tracked separately)

- [ ] `setSlashPolicyAdmin(multisig/Timelock)` — governance/operations action (still
      `deployer` EOA). Independent of this impl swap; see CC-13 governance thread.
- [ ] RED mainnet-blocker batch + Registry batch — deferred to the next round
      (each Opus-5 evaluated first).

---

### Rollback

UUPS is reversible: if a post-upgrade check fails, `upgradeToAndCall(previousImpl, "")`
back to the recorded prior `spImpl`. No storage was migrated (only appended), so a
rollback is clean. Record the prior `spImpl` before step 1.
