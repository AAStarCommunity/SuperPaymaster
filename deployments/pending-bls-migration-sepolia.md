# BLS-module migration — Sepolia (slash unification #329)

**Status**: ✅ MIGRATION COMPLETE — new aggregator active on SP, config flipped, old slasher revoked.
**Only remaining item is `setSlashPolicyAdmin` → multisig, which is an operations decision (see below).**

`config.sepolia.json` now lists the NEW addresses, consistent with on-chain reality:
`SP.applyBLSAggregator()` has run, so `SuperPaymaster.BLS_AGGREGATOR` is the NEW aggregator.

## Addresses (NEW now active)

| Contract | OLD (revoked) | NEW (active) |
|---|---|---|
| BLSAggregator | `0x893b8fb7B3d203C288b481400fE05Ade5edD6d11` | `0xF51c029879685Ced8fbCfa4b647c2eAe50Cd8B13` |
| DVTValidator | `0x9946953af7aAA8F56e8dF4E46F68FFFA0c4F593D` | `0x568b1486BFE036e603eA11f0D03Dc47fa62c9E0e` |

New BLSAggregator verified on-chain: `slashThresholds` = 2/3/3, `slashPolicyAdmin` =
deployer, `DVT_VALIDATOR` = new DVTValidator; new DVTValidator `BLS_AGGREGATOR` = new BLSAggregator.

## Wiring done (queue phase)

- `SP.queueBLSAggregator(new)` — tx `0x93452c28cc80ec8db2c74cab8cfd99331404b266b40c3642176bc722985cae36`
  - 24h timelock, ETA 1783356732.
- `staking.setAuthorizedSlasher(new, true)` — tx `0xd6b61d7c4519c7b336438f03ed4b5f7e932f59bf631e86c72cd9133305066c18`

## Follow-up (executed after ETA)

1. ✅ `SP.applyBLSAggregator()` — new aggregator active on SP.
   - tx `0x691db4175bcce842beb1e93481573b4e843ea3e4d86793a2f07230cc611bfd26` (block 11216728).
   - `SP.BLS_AGGREGATOR` = new; `pendingBLSAgg` / `pendingBLSAggEta` cleared.
2. ✅ Flipped `config.sepolia.json` to the NEW addresses.
3. ✅ `staking.setAuthorizedSlasher(old, false)` — revoked the old aggregator's slasher role.
   - tx `0x23562f9c2f929cc26deba7cfd9a6ff33d77d6ad88a803d5a0787708993c45bdd`.
   - Verified: `authorizedSlashers[old]` = false, `authorizedSlashers[new]` = true.
3b. ✅ `Registry.setBLSAggregator(new)` — repoint the Registry's own BLS aggregator pointer.
   - tx `0x924620a42ab12956af880be149621fb8f499202c49dc84a52f9b4cbc0217381e`.
   - Registry gates the reputation-slash execution path (`msg.sender == blsAggregator`) and calls
     `IBLSAggregator(blsAggregator).verify(...)`, so this pointer must track the active aggregator or
     the new aggregator's reputation callbacks into Registry would revert `UnauthorizedSource`.
   - Verified: `Registry.blsAggregator` = new.
4. Validator registration on the new modules:
   - ✅ `DVTValidator.addValidator(op)` ×3 — Jason `0xe212ae59…` / Anni `0x7c169e49…` / Bob `0xd2c8ea57…`; `isValidator` all true.
   - ✅ `BLSAggregator.registerBLSPublicKey(...)` ×3 (owner path) — slot 1=Jason `0x6ab1ae1c…` / slot 2=Anni `0xc76a56e3…` / slot 3=Bob `0x6077731a…`; `validatorAtSlot(1/2/3)` confirmed.
   - ⏳ `setSlashPolicyAdmin(multisig / TimelockController)` — **operations decision, NOT yet done.**
     `slashPolicyAdmin` is still the deployer (EOA). Does not block slash E2E (deployer can adjust
     the threshold table); ops should set a deadline to hand this to a multisig/timelock before
     that authority stays concentrated on an EOA long-term.
5. SDK: update BLSAggregator/DVTValidator address + ABI (verifyAndExecute 8-arg,
   queueSlashWithConsensus, slashThresholds, ...). Signalled to SDK via Cooperation-Center CC-18;
   SDK ABI already shipped (@aastar/sdk 0.37.3), address cutover pending on their side.

## Full wiring verification (on-chain, post-migration)

All active pointers resolve to the NEW modules; the OLD aggregator is fully de-authorized.

| Pointer | Expected | On-chain |
|---|---|---|
| `SP.BLS_AGGREGATOR` | new BLS | ✅ `0xF51c…8B13` |
| `Registry.blsAggregator` | new BLS | ✅ `0xF51c…8B13` |
| `staking.authorizedSlashers[old BLS]` | false | ✅ false |
| `staking.authorizedSlashers[new BLS]` | true | ✅ true |
| `DVTValidator(new).BLS_AGGREGATOR` | new BLS | ✅ `0xF51c…8B13` |
| `BLSAggregator(new).DVT_VALIDATOR` | new DVT | ✅ `0x568b…9E0e` |
| `DVTValidator(new).REGISTRY` | Registry | ✅ `0xf5Bf…8E71` |

Note: `staking.authorizedSlashers[new DVT]` is intentionally false — the slasher role is held by the
BLSAggregator (which calls `staking.slashByDVT`), not the DVTValidator directly. DVT → BLSAggregator →
staking is the path.
