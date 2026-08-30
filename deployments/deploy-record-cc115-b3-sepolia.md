# Deploy Record — CC-115 B3, Sepolia (2026-08-30)

**Nature:** Registry in-place UUPS impl swap + BLSAggregator generational replacement.
Executed after DVT reported (CC-115) that B3 verifier arming was hard-blocked by the
live aggregator still being 4.3.0.

## What moved

| contract | before | after | mechanism |
|---|---|---|---|
| Registry (proxy `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71`) | `Registry-5.4.2` | `Registry-5.8.0` | in-place UUPS — **proxy address unchanged** |
| Registry impl | `0x9e5da7B4461Ff92F9Ea2Ae57bcf749afC812CC00` | `0x9beD0F58d6001B0006923eb8c4b1Cc548D42ccEe` | new deploy |
| BLSAggregator | `0x174b60bB462b00550F0EC7Bc35Fe39dDB6310158` (4.3.0) | `0xEaeC2F512eA50708211fa95533e4dBb60e3d2E5D` (4.11.0) | **not upgradeable** — new address + `setBLSAggregator` |

Nothing else was redeployed. SuperPaymaster, DVTValidator, MySBT, GTokenStaking,
xPNTsFactory, ReputationSystem, PolicyRegistry, LivenessRegistry and
GTokenAuthorization were each probed on-chain and already match `main`; redeploying
them would only churn addresses and break downstream pins for no gain.

## Transactions (all status 1)

| step | tx |
|---|---|
| deploy Registry impl | `0x2792ea496eefac7868ce5e11e071e1613584b87bcdafaae39103d42333ab12b5` |
| `upgradeToAndCall(impl, 0x)` | `0x728d165c6971abacb6f8c5d87e31c8c9c7f0306f9773d670a52ce7210c4fb953` (block 11599363) |
| deploy BLSAggregator | `0x6a5a6ddff647a1501870d0464d41ebbf5165c044e18e8587dbddfebcb04e3881` |
| `Registry.setBLSAggregator` | `0xb06bbc506fc6464fa9ef8d896605217a458c0bc9b579055197bd8021e5ae92a9` (block 11599371) |

Signer: `0xb5600060e6de5E11D3636731964218E53caadf0E`, which is `Registry.owner()`.

## Pre-flight that gated this (per `uups-upgrade-v5.4.2-runbook.md`)

Storage layout, `bb2610e8^` (the 5.4.2 revision) vs `main`, per-slot:

- slots 0..23 byte-identical in position, name and type;
- 5.8.0's seven new variables are carved out of the reserved `__gap` at slots 24–30
  (`maxAggregateCreditUpliftPerProposal`, `totalCreditExposure`,
  `maxTotalCreditExposure`, `creditPopulationTotal`, `creditPopulationEpochOf`,
  `creditPopulationEpoch`, `creditPopulationSeededAt`);
- `__gap` shrinks `slot24 len50` → `slot31 len43`, so its end stays at slot 74.

No pre-existing slot moved, which is what the runbook makes the STOP condition.
Confirmed on-chain after the swap: `owner()`, `GTOKEN_STAKING()` and the then-current
`blsAggregator()` all read back unchanged.

Also measured before broadcasting: `forge test` 1361/0/49, `--evm-version prague`
1275/0/21 on `d23ab088`; Registry impl runtime 23,038 B (headroom 1,538);
BLSAggregator runtime 23,667 B (headroom 909).

## Acceptance — DVT's own three probes, before and after

Run twice: directly against the new contract before wiring, then through
`Registry.blsAggregator()` after. Identical both times.

| probe | 4.3.0 | 4.11.0 |
|---|---|---|
| `version()` | `"BLSAggregator-4.3.0"` | `"BLSAggregator-4.11.0"` |
| `VERIFIER_ROTATION_DELAY()` | revert | `345600` (4 days) |
| `pendingFraudProofVerifierReadyAt()` | revert | `0` |
| `guardianExitRequests(address)` | revert | `(0, 0)` |
| `setFraudProofVerifier(address)` | present | absent |

## Two config entries that are now stale — read this before trusting them

`deployments/config.sepolia.json` is a flat address map with no place for a caveat,
so the caveats live here:

1. **`blsFraudProofVerifier: 0x128847cFD6e0C8247ED297Fb27a1302f2ad66D51` is NO LONGER
   WIRED.** It was the old three-parameter verifier on the 4.3.0 aggregator. The new
   aggregator reads `fraudProofVerifier() == 0x0` — dormant by design. Arming it is
   DVT's D1 flow (`proposeFraudProofVerifier` → 4 days → permissionless
   `applyFraudProofVerifier`), not a field to hand-edit here.

2. **`blsGuardians` (`0x5D870E13…`, `0x40F0b121…`, `0xD904A706…`) are NOT registered on
   the new aggregator.** `validatorAtSlot(1..13)` reads zero across the board. A new
   aggregator starts empty and registrations do not migrate: the PoP is bound to the
   aggregator's domain separator, which includes its address, so every prior PoP is
   void by construction (CC-48 round-3 made PoP mandatory on both registration paths
   precisely so this cannot be waved through). The MINOR threshold is 3, so the slash
   consensus path cannot reach quorum until all three re-register.

   `registerBLSPublicKey` is `external` and the owner may submit on a validator's
   behalf, but the signature must come from that validator's BLS secret key. SP does
   not hold them. This step belongs to DVT / the node operators.

## Deliberately not done

- `setReputationSource(newAggregator, true)` — the old aggregator reads `false`, so
  this preserves the current permission surface rather than silently widening it.
- No verifier wired (see above).
- No other contract touched.

## Rollback

- Registry: `upgradeToAndCall(0x9e5da7B4461Ff92F9Ea2Ae57bcf749afC812CC00, 0x)` from the
  same owner. Proxy address and state are unaffected either way.
- Aggregator: `setBLSAggregator(0x174b60bB462b00550F0EC7Bc35Fe39dDB6310158)`. The old
  aggregator still holds its three validator registrations, so rolling back is clean.
