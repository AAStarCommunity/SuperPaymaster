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

---

## 2026-09-04 rotation to BLSAggregator-4.11.0 — the agreed path (option A)

The 2026-08-30 rotation moved `Registry.blsAggregator` to 4.11.0 (`0xEaeC2F51…`) and nothing else,
leaving `SuperPaymaster.BLS_AGGREGATOR` and `DVTValidator.BLS_AGGREGATOR` on 4.3.0
(`0x174b60bB…`). The split ran for two days and was found by repo:sdk, not here.
`Check11_AggregatorPointers` exists because of it.

The SP leg is already queued (`pendingBLSAgg` = `0xEaeC2F51…`), so the remaining work is the two
pointer switches. **All three legs go to 4.11.0 on 09-04. 4.12.0 is scheduled separately** — it
needs a fresh BLSAggregator deployment, which would void DVT's four-day arming and push B3 out by
the same four days, and the guardian slash path it changes is unreachable while slash is closed.

Order, after DVT confirms its `fraudProofVerifier` readback is non-zero:

1. `DVTValidator.setBLSAggregator(0xEaeC2F512eA50708211fa95533e4dBb60e3d2E5D)` — immediate.
2. `SuperPaymaster.applyBLSAggregator()` — the eta (`1788322908`, 2026-09-03) has already passed,
   so this needs no further wait.
3. Flip `deployments/config.sepolia.json` `.blsAggregator` to `0xEaeC2F51…`. Check11 fails with
   `RECORD STALE` if this is skipped: that file is copied into aastar-sdk by `sync_to_sdk.sh`, so
   the chain moving without the record moves every consumer onto a dead address.
4. `CONFIG_FILE=config.sepolia.json forge script …Check11_AggregatorPointers` must print
   `RESULT: OK`. Report four readbacks: the three pointers and `pendingBLSAgg` (now zero).

### Deploying during the rotation window

Between step 1 and step 2 the three pointers legitimately disagree, and Check11 is red for the
whole window — which also blocks `./deploy-sepolia.sh` and `./audit-core sepolia`, including an
unrelated hotfix. There is no skip flag, deliberately. Instead, declare the target:

```
EXPECT_AGGREGATOR_ROTATION_TO=0xEaeC2F512eA50708211fa95533e4dBb60e3d2E5D ./deploy-sepolia.sh
```

This is an assertion, not a mute. It passes only when every pointer holds either the declared
target or the single address being rotated away from, nothing is queued anywhere else, and
something on-chain actually points at or is queued to the target. A wrong address, a third
address, or a queue pointing elsewhere all still fail. **Remove it once step 2 has landed** —
left set, it would keep accepting a rotation that is no longer in flight.
