# Deploy Record — CC-115 B3, Sepolia (2026-08-30)

> ## CURRENT STATE, 2026-08-30 — read this before the sections below
>
> **This file is a RECORD OF A DEPLOYMENT, so most of it is written in the tense of the
> moment it describes.** Two conditions it reports at length were true then and are NOT
> true now. They are listed here rather than only in addenda further down, because a
> reader who stops at a heading would otherwise carry away the opposite of the truth.
>
> | thing | as this file first described it | **now** |
> |---|---|---|
> | reputation path | SHUT (`creditPopulationSeededAt == 0`) | **OPEN** — `creditPopulationSeededAt` = `1788104232`, caps `10_000e18` / `50_000e18`, `isReputationSource(new)` = `true` |
> | the three guardians | not registered on the new aggregator | **registered** — `validatorAtSlot(1..3)` hold them, in order; MINOR quorum of 3 is met |
>
> Everything else in this file still holds: Registry proxy address unchanged, aggregator
> replaced, DVT's acceptance probes passing, and the rollback points still valid.

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

## Two config entries that were stale when this was written (item 2 has since been resolved)

`deployments/config.sepolia.json` is a flat address map with no place for a caveat,
so the caveats live here:

1. **`0x128847cFD6e0C8247ED297Fb27a1302f2ad66D51` can never serve the new aggregator** —
   stronger than "not wired", which is how this note first put it. Measured:
   `AGGREGATOR()` on that verifier returns `0x174b60bB…0158`, the PREVIOUS aggregator,
   hard-bound at construction. The new aggregator reads `fraudProofVerifier() == 0x0`,
   dormant by design; arming it is DVT's D1 flow (`proposeFraudProofVerifier` → 4 days →
   permissionless `applyFraudProofVerifier`), not a field to hand-edit here.

   The config key is therefore renamed `blsFraudProofVerifier` → **`blsFraudProofVerifierPrev`**,
   so the JSON states what this paragraph states. A caveat that only lives in a markdown
   file protects nobody reading the machine-readable map, and `config.sepolia.json` IS
   machine-read (a dozen `contracts/script/v3/*.s.sol` load it). Renaming is free today:
   grep over `contracts/script/` and `scripts/` finds no consumer of the old key.
   (Raised by pr-daemon on #390; the `AGGREGATOR()` binding verified here before acting.)

2. **AS OF THE DEPLOYMENT (block 11599371) — SINCE RESOLVED, see the addendum below.**
   `blsGuardians` (`0x5D870E13…`, `0x40F0b121…`, `0xD904A706…`) were NOT registered on
   the new aggregator; `validatorAtSlot(1..13)` read zero across the board. A new
   aggregator starts empty and registrations do not migrate: the PoP is bound to the
   aggregator's domain separator, which includes its address, so every prior PoP is
   void by construction (CC-48 round-3 made PoP mandatory on both registration paths
   precisely so this cannot be waved through). The MINOR threshold is 3, so the slash
   consensus path cannot reach quorum until all three re-register.

   `registerBLSPublicKey` is `external` and the owner may submit on a validator's
   behalf, but the signature must come from that validator's BLS secret key. SP does
   not hold them. This step belongs to DVT / the node operators.

   > **2026-08-30, addendum — DONE.** DVT completed the re-registration. Read at
   > `latest`: `validatorAtSlot(1..3)` = `0x5D870E13…7Eca3` / `0x40F0b121…bd1f` /
   > `0xD904A706…1601`, slot 4 onward zero — the same three, back in the same order, so
   > the MINOR threshold of 3 is met again. The paragraph above is accurate as HISTORY
   > (read at block 11599371 the slots were all zero) and would mislead as CURRENT STATE,
   > which is why this line exists rather than an edit to it.

## THE UPGRADE SHUT THE REPUTATION PATH — deliberate in 5.8.0, and the deployment above
## did not open it (it was opened later the same day; see the addendum ending this section)

**Tense warning:** this section is written as of the swap. For the state today read the
CURRENT STATE block at the top of this file.

At that moment `batchUpdateGlobalReputation` reverted `CreditPopulationNotSeeded()` on
this proxy. That is 5.8.0 doing what it says (`Registry.sol:519`, CC-48 round-9
MEDIUM-HIGH-B3).

The hazard the gate exists for, stated as the general case it is: a freshly UPGRADED
proxy reads zero in the credit-population slots, and if promoted users already exist
on-chain then exposure derived from that empty population under-counts the live stock by
exactly the pre-upgrade issuance. Fresh deployments seed inside `initialize`, where the
population provably IS empty; an upgrade cannot prove that, so the path stays shut until
governance re-counts.

**Note what that does and does not say about THIS proxy.** The gate tests one slot:
`creditPopulationSeededAt == 0` (`Registry.sol:519`). It is emphatically NOT "any
upgrade" — a fresh deployment is seeded in `initialize` (`:155`) and an upgrade between
two revisions that both already carry the slot leaves it non-zero, so neither trips it.
What tripped it here is narrower and exact: an upgrade **from a revision predating the
slot**, so the slot was new and therefore read zero. (The only other way to reach zero is
`_invalidateCreditPopulation` (`:706`) after a schedule change, and that path returns
early when `creditPopulationTotal == 0`.)

The consequence for reading this record: a zero in that slot carries no information about
whether anyone was ever promoted — it says the slot has not been written, nothing more.
Here the population genuinely was empty: `GlobalReputationUpdated` has never been emitted
on this Registry, so the re-count the gate demanded had nothing to count. That is why the
seed was `([], 0, true)` — a formality satisfying a gate that fires on the slot rather
than on the population, not a real re-count that happened to come back empty. The evidence for the emptiness, and the positive control behind it, are in
the addendum at the end of this section; do not read the paragraph above as a claim that
promoted users existed here.

Measured on the proxy immediately after the swap (**historical — see the addendum at the
end of this section for what these read today**):

```
creditPopulationSeededAt()              -> 0     <- the gate, as it read THEN
creditPopulationTotal()                 -> 0
totalCreditExposure()                   -> 0
maxTotalCreditExposure()                -> 0
maxAggregateCreditUpliftPerProposal()   -> 0
isReputationSource(new aggregator)      -> false
isReputationSource(old aggregator)      -> false  <- already false BEFORE this upgrade
```

Three owner-gated steps are required, in this order. **They have since been performed —
see the addendum at the end of this section** — but they were NOT part of the deployment
above, and the numbers came from the repo owner, not from me:

1. `setCreditPolicy(perProposalCap, totalCap)` — both caps **read 0 at this point**
   (they now read `10_000e18` / `50_000e18`; see the addendum).
2. `seedCreditPopulation(address[] users, uint256 expectedPopulationTotal, bool finalize)`
   — batched; the final call must pass `finalize = true` and the running count must equal
   `expectedPopulationTotal` or it reverts `CreditPopulationCountMismatch`. Only then is
   `creditPopulationSeededAt` set. Enumerating the already-promoted users **was** an
   off-chain job against this Registry's history — **it was done, and the answer was the
   empty set**; see the addendum for why that is exact rather than a shortcut.
3. `setReputationSource(0xEaeC2F512eA50708211fa95533e4dBb60e3d2E5D, true)`.

Note the asymmetry in what this migration caused: **step 3's gap pre-existed** — the old
aggregator was already not a reputation source — whereas **the seeding gate at step 1/2 is
new, introduced by this upgrade.** Downstream work that calls
`batchUpdateGlobalReputation` (the YAAA B5 registration → aggregation → reputation smoke,
and the SDK B4 evidence runner) would fail until all three were done — which they now are.

> **2026-08-30, addendum — the reputation path is now OPEN.** The owner supplied the caps
> and the three steps were executed. Read back afterwards:
>
> ```
> creditPopulationSeededAt()              -> 1788104232   (was 0 — this is the gate)
> creditPopulationTotal()                 -> 0
> totalCreditExposure()                   -> 0
> maxAggregateCreditUpliftPerProposal()   -> 10_000e18
> maxTotalCreditExposure()                -> 50_000e18
> isReputationSource(0xEaeC2F51…)         -> true
> ```
>
> | step | tx |
> |---|---|
> | `setCreditPolicy(10_000e18, 50_000e18)` | `0xb7e6fdfe287faf01a1ce04ed30879b2b8f5632ffa9bff554f8298c5be425f971` |
> | `seedCreditPopulation([], 0, true)` | `0x6b5b90fbce689d7deb7360aaebb8a44e93f926b1b4ccf3d179768c86172d6b09` |
> | `setReputationSource(0xEaeC2F51…, true)` | see the CC-115 thread |
>
> **Why the seed list is empty, and why that is exact rather than lazy.** The population
> this Registry had to re-count was zero: `GlobalReputationUpdated` has NEVER been emitted
> on this proxy. That query was positive-controlled before being trusted — the same
> `getLogs` call against the same address returns 6 `BLSAggregatorUpdated`, 6 `Upgraded`
> and 3 `ReputationSourceUpdated`, so the zero is a real zero and not a broken filter.
> No user has ever been promoted here, so `seedCreditPopulation([], 0, true)` is the
> complete and exact seed, and `totalCreditExposure` legitimately reads 0.
>
> The caps were chosen by the repo owner against this schedule: tiers 1–3 all equal the
> 300e18 floor, so promotions below reputation 89 cost NO exposure; level 4 (rep ≥ 89)
> costs +300e18, level 5 (≥ 233) +700e18, level 6 (≥ 610) +1700e18. All 25 current
> role-holders at the TOP tier would be 42,500e18, under the 50,000e18 ceiling.

## Deliberately not done

- Nothing here was decided unilaterally: the caps above are the owner's numbers. Until
  they arrived the gate was left visibly shut rather than opened on invented values.
- `setReputationSource(newAggregator, true)` on its own — it would not open the path
  while the seeding gate is closed, and it would widen the permission surface for no
  effect.
- No verifier wired (see above).
- No other contract touched.

## Rollback

- Registry: `upgradeToAndCall(0x9e5da7B4461Ff92F9Ea2Ae57bcf749afC812CC00, 0x)` from the
  same owner. Proxy address and state are unaffected either way.
- Aggregator: `setBLSAggregator(0x174b60bB462b00550F0EC7Bc35Fe39dDB6310158)`. The old
  aggregator still holds its three validator registrations, so rolling back is clean.
