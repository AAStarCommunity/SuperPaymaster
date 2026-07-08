# Deploy Record — Registry 5.4.1 + SuperPaymaster 5.4.2 (Sepolia, 2026-07-08)

UUPS in-place upgrades (proxy addresses unchanged). Owner = `0xb5600060…adf0E`.

## ① Registry 5.4.0 → 5.4.1 (#210 / #335)

Pure EIP-170 compression (`_safeSetRoleExitFee` dedup, 25,019→23,621) — also lands the
P0-2/P0-3 CEI unchecked-call guards on-chain (the deployed 5.4.0 predated them).

| Item | Value |
|---|---|
| Proxy | `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71` |
| New impl | `0x6Af5A2A7252c82E60373A65F6dcbe6E41ca0a1dB` (was `0x60a5c660…`) |
| impl deploy tx | `0xff7b6887f5205d9d7440732364f948574b9b6d0ffd78fca58283948d8d4da766` |
| upgrade tx | `0x355b8547acb17a54d81f9c72605935e0a3f531eed93786381255ac35523d824d` |
| Verified | `version() == "Registry-5.4.1"`; owner/staking/sbt/sp/blsAggregator unchanged |

## ② SuperPaymaster 5.4.1 → 5.4.2 (CC-13 / #334)

Anti-double-slash: BLS-path `_slashCd` cooldown (1h) gated in `queueSlash`, dedicated
`_blsSlashCd` (decoupled from owner), `isSlashPending` getter, and a global cold-start
floor primed atomically in the upgrade tx.

| Item | Value |
|---|---|
| Proxy | `0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9` |
| New impl | `0xe25f88dbeaFc64200270A948Df8e9dd2F9b22C27` (was `0x0274811E…`) |
| impl deploy tx | `0xae0399f86c25b1b4cfe95c396488feadfc11c80319862e6292c89560ecc33ec6` |
| upgrade + primeBlsSlashCooldown tx | `0xc73a1f1ba653a0691427e547b935c4ba35d47ba30a7d6aa3cda13741015c3fcf` |
| Verified | `version() == "SuperPaymaster-5.4.2"`; `isSlashPending(0x0)==false`; `BLS_AGGREGATOR==0xF51c…8B13`; storage integrity (owner/APNTS/treasury/fee/price) |

## ⚠️ Cold-start floor active

`primeBlsSlashCooldown` set `_blsSlashCdFloor = now + 1h` at upgrade — **no BLS slash
executes for ~1h post-upgrade** (blanket, owner path exempt). DVT's first real slash E2E
must be scheduled >1h after the upgrade tx (block time of `0xc73a1f1b…`).

## Downstream sync (follow-up)

- [ ] `abis/SuperPaymaster.json` re-extract (adds `isSlashPending`) + `sync_to_sdk.sh`.
- [ ] Notify @repo:sdk (new SP ABI; address unchanged) + @repo:dvt (CC-13 — done, tx posted).
- [x] `deployments/config.sepolia.json` patched (`registryImpl`, `spImpl`).
