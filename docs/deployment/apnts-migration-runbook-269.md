# APNTS_TOKEN Migration Runbook (#269)

> Execute **after 2026-06-20 01:50 UTC** (timelock). SuperPaymaster Sepolia proxy
> `0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a`. All steps are **owner/operator
> on-chain, irreversible** — do them in order, verify each gate.

## Goal
Switch `SP.APNTS_TOKEN` from legacy aPNTs `0x9f0E11e0D33Ec0a5c9608990E7B3498B5EE3210B`
to new aPNTs `0xc53a8c96581D8b7ACeDF16995323D7b3888ABCe8` (user side already on new aPNTs).

## On-chain snapshot (2026-06-14)
| field | value |
|---|---|
| `pendingAPNTsTokenEta` | 1781920248 = **2026-06-20 01:50 UTC** |
| `pendingAPNTsToken` | `0xc53a…` (new) |
| `APNTS_TOKEN` (current) | `0x9f0E…` (legacy) |
| `totalTrackedBalance` | 4279.5 ether |
| `protocolRevenue` | 172.7 ether |
| **operator balance to drain** | **≈ 4106.8 ether** (= total − protocolRevenue) |
| **protocolRevenue to withdraw** | **≈ 172.6 ether** (down to ≤ 0.1 buffer) |

## `executeAPNTsTokenChange()` preconditions (SuperPaymaster.sol:366-383)
1. `pendingAPNTsToken != 0` ✅ (already `0xc53a…`)
2. `block.timestamp >= pendingAPNTsTokenEta` — gate on 2026-06-20 01:50 UTC
3. `totalTrackedBalance == protocolRevenue` — i.e. ALL operator balances withdrawn
4. `protocolRevenue <= PROTOCOL_REVENUE_BUFFER` (0.1 ether)

## Steps (after timelock)

```bash
SP=0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a
source .env.sepolia   # RPC_URL + DEPLOYER_ACCOUNT (owner) keystore

# 0. Gate: confirm timelock elapsed
cast call $SP "pendingAPNTsTokenEta()(uint256)" --rpc-url $RPC_URL   # must be <= now
```

1. **Drain every operator balance** (`SP.withdraw(amount)` — each operator withdraws its own
   `operators[op].aPNTsBalance`; owner cannot withdraw on their behalf). Enumerate operators
   from `OperatorDeposited`/Registry `ROLE_PAYMASTER_SUPER` members; have each call
   `withdraw(fullBalance)`. Target: `totalTrackedBalance − protocolRevenue → 0`.
2. **Withdraw protocol revenue to buffer**: owner `withdrawProtocolRevenue(treasury, amount)`
   until `protocolRevenue <= 0.1 ether` (PROTOCOL_REVENUE_BUFFER is left unwithdrawable by design).
3. **Verify the invariant** before executing:
   ```bash
   cast call $SP "totalTrackedBalance()(uint256)" --rpc-url $RPC_URL
   cast call $SP "protocolRevenue()(uint256)"     --rpc-url $RPC_URL
   # require: totalTrackedBalance == protocolRevenue  AND  protocolRevenue <= 0.1e18
   ```
4. **Execute**: `cast send $SP "executeAPNTsTokenChange()" --account $DEPLOYER_ACCOUNT --rpc-url $RPC_URL`
   → `APNTS_TOKEN` becomes `0xc53a…`; `pendingAPNTsToken`/`Eta` cleared; emits
   `APNTsTokenChangeExecuted` + `APNTsTokenUpdated`.
5. **Re-fund operators with new aPNTs**: `setup-gasless fundOperator` reads `SP.APNTS_TOKEN`
   dynamically, so it now pulls `0xc53a…` automatically — re-deposit each operator.
6. **Re-run full E2E (37/37)** on the migrated contracts; re-capture on-chain tx evidence.
   Update `docs/e2e-evidence/real-transactions.md`. Capture a real **debt-path** tx for #29
   (drain an AA account below the per-op charge so postOp records debt instead of burning).

## Post-conditions to confirm
- [ ] `APNTS_TOKEN()` == `0xc53a…`
- [ ] `pendingAPNTsToken()` == `0x0`, `pendingAPNTsTokenEta()` == 0
- [ ] operators re-funded in new aPNTs; `SP.deposit()` pulls `0xc53a…`
- [ ] E2E 37/37 green on migrated state + tx evidence refreshed
- [ ] #29 debt-path tx captured

## Notes
- UUPS impl upgrades do NOT reset this timelock (it's in proxy storage). Don't redeploy to skip it.
- The drain is the heavy part: ~4107 ether across operators must move before step 4's invariant holds.
