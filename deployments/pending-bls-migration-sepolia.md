# Pending BLS-module migration — Sepolia (slash unification #329)

**Status**: DEPLOYED, wiring in 24h timelock — NOT yet active.
**Do not point tooling/SDK at the new addresses until `applyBLSAggregator` completes.**

`config.sepolia.json` intentionally still lists the OLD addresses, because until
`SP.applyBLSAggregator()` runs, `SuperPaymaster.BLS_AGGREGATOR` is still the OLD
aggregator — a slash driven through the new aggregator would revert at SP.

## Addresses

| Contract | OLD (active now) | NEW (deployed, pending) |
|---|---|---|
| BLSAggregator | `0x893b8fb7B3d203C288b481400fE05Ade5edD6d11` | `0xF51c029879685Ced8fbCfa4b647c2eAe50Cd8B13` |
| DVTValidator | `0x9946953af7aAA8F56e8dF4E46F68FFFA0c4F593D` | `0x568b1486BFE036e603eA11f0D03Dc47fa62c9E0e` |

New BLSAggregator verified on-chain: `slashThresholds` = 2/3/3, `slashPolicyAdmin` =
deployer, `DVT_VALIDATOR` = new DVTValidator; new DVTValidator `BLS_AGGREGATOR` = new BLSAggregator.

## Wiring done

- `SP.queueBLSAggregator(new)` — tx `0x93452c28cc80ec8db2c74cab8cfd99331404b266b40c3642176bc722985cae36`
  - 24h timelock, **ETA 1783356732** (apply not allowed before this).
- `staking.setAuthorizedSlasher(new, true)` — tx `0xd6b61d7c4519c7b336438f03ed4b5f7e932f59bf631e86c72cd9133305066c18`

## Follow-up (in order, after ETA)

1. `SP.applyBLSAggregator()` — activates the new aggregator on SP.
2. **Flip `config.sepolia.json` to the NEW addresses** (only after step 1).
3. `staking.setAuthorizedSlasher(old, false)` — revoke the old aggregator's slasher role.
4. owner: `addValidator(Jason/Anni/Bob)` ×3 → `registerBLSPublicKey(...)` ×3 (+slot) →
   `setSlashPolicyAdmin(multisig/TimelockController)`.
5. SDK: update BLSAggregator/DVTValidator address + ABI (verifyAndExecute 8-arg,
   queueSlashWithConsensus, slashThresholds, ...).
