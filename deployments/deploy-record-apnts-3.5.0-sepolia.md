# aPNTs 3.5.0 — Sepolia rehearsal

**Deployed 2026-09-01, chain 11155111.** This is the rehearsal for the OP-mainnet
redeploy, run first at Jason's direction. Mainnet is NOT deployed.

## Addresses

| | |
|---|---|
| aPNTs (new) | `0x5Cfc992fD095D047c41A03E80f6e760899450Ae3` |
| xPNTsFactory (new) | `0xfd16CaA468992701D17a1603c8bEFE0613550da3` |
| Registry used | `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71` (Registry-5.8.0) |
| Deployer | `0xb5600060e6de5E11D3636731964218E53caadf0E` |

All four transactions status `0x1`:
`0x639dc32f…` factory · `0x6cab21ac…` deployxPNTsToken ·
`0x4febb3d0…` transferCommunityOwnership · `0x8b3d4c3b…` factory transferOwnership

## Verified ON CHAIN, not from the deploy log

The deploy script's own `require`s run in the simulation, after `stopBroadcast`, so
they cannot see a half-applied chain state. `15_VerifyAPNTs` re-reads everything:

```
chain id        11155111
aPNTs           XPNTs-3.5.0
  communityOwner  0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114   Mycelium Safe
  FACTORY         0xfd16CaA468992701D17a1603c8bEFE0613550da3
  totalSupply     0
factory         xPNTsFactory-2.3.0-clone-optimized
  owner           0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114   same Safe
  decimals        18
  aPNTsPriceUSD   20000000000000000        = $0.02
  APNTS_PRICE_MIN  1000000000000000        = $0.001
  APNTS_PRICE_MAX  100000000000000000000   = $100
RESULT: OK   exit 0
```

Reproduce:

```
EXPECT_CHAIN_ID=11155111 \
APNTS=0x5Cfc992fD095D047c41A03E80f6e760899450Ae3 \
FACTORY=0xfd16CaA468992701D17a1603c8bEFE0613550da3 \
forge script contracts/script/deployment/15_VerifyAPNTs.s.sol:VerifyAPNTs \
  --rpc-url "$SEPOLIA_RPC_URL"
```

## What this deployment does and does not fix

It changes **who may mint, not whether minting is bounded**. `issuanceCap` is not a
mint gate — one `_mint` call site guarded only by `onlyFactoryOrOwner`, and the cap
is read solely by the view `isOverIssued()` that DVT calls, defaulting to unset. The
Safe can still mint without bound; it just cannot do so unilaterally, and
over-issuance stops being silent.

`totalSupply` is 0. Nothing is carried over from any earlier token.

## For repo:airaccount

`decimals` is 18, so their 27 baked limits need no rescaling. `APNTS_PRICE_MAX` is
$100 — 5,000× the $0.02 launch price — which is what closed their option (A): sizing
a permanently-unchangeable guard against the worst reachable price forces
conservative tier-1 down to a single aPNTs.

Still open, and Jason's: the **steady-state per-member aPNTs balance** (a lower
bound, not a mean). Their tier limits are per-account gates, so a total supply
figure is not the input they need. Nothing should be baked until that lands.

## OP mainnet

Not deployed here, and not pending on this repo's automation: **the mainnet run is
executed manually by ops**, using these same scripts. `EXPECT_CHAIN_ID` defaults to
10 and `REGISTRY` to the OP-mainnet Registry-3.0.2, so the mainnet invocation needs
no extra arguments. Dry-run against real OP-mainnet state is green; the addresses
will differ from the Sepolia ones above.

Two things for whoever runs it: sign with `0x51Ac6949…` (keystore
`optimism-deployer`), per the signer section above; and run `15_VerifyAPNTs`
afterwards, because the deploy script's own assertions execute in the simulation
and cannot see a half-applied chain.

## Event-log audit: the token was not touched in the ownership gap

State reads cannot prove this. Between tx2 and tx3 the deployer EOA held
`communityOwner` and could have granted `autoApprovedSpenders`,
`approvedFacilitators` or `spenderDailyCapOverride` to an **arbitrary** address —
mappings a view call can probe but never enumerate. `communityOwner == SAFE` is
true whether or not that happened. So the complete check is the log, not the state.

Every event the new token emitted, deploy window (blocks 11611106–11611115):

| topic0 | event | from tx |
|---|---|---|
| `0xc7f505b2f371ae21` | `Initialized(uint64)`, data `1` | `0x6cab21ac…` deployxPNTsToken |
| `0x1191f7dd7e510e69` | `CommunityOwnerUpdated(0xb5600060…deployer → 0x51eDf11f…Safe)` | `0x4febb3d0…` |

**Two events, both expected.** No `Transfer` (nothing minted), no
`FacilitatorApproved`, no `SpenderDailyCapForUpdated`, no `ExchangeRateUpdated`,
no `AutoApprovedSpenderAdded` beyond what `initialize` sets in storage without
emitting.

**The instrument was verified before the result was believed.** The first run of
this audit reported zero events for every query INCLUDING a control that could not
be zero — the cause was an HTTP 400: the RPC free tier caps `eth_getLogs` at a
10-block range, and `cast` reports that as no output rather than as an error, so a
broken query and a clean token produce the identical reading. Re-run inside a
10-block window it returns 2 events on the token and 3 on the factory. The zeros
above are from the working instrument.

### The rate check needed a second value

`exchangeRate == 1 ether` on its own false-passes a touched token. `initialize`
sets `exchangeRate` but **not** `exchangeRateUpdatedAt`, so a fresh clone carries
zero there — and the cooldown guard reads
`if (exchangeRateUpdatedAt != 0 && ...)`, so it does not apply to the first call.
The deployer EOA could therefore call `updateExchangeRate(1 ether)` inside the
ownership gap: same value, delta zero, in range, and it **succeeds**. The rate
still reads 1 ether, the check still passes, and the token has been written to
with the one-hour cooldown now armed against the Safe's first legitimate change.

`exchangeRateUpdatedAt` is the discriminating value. `xPNTsToken.sol:1146` is its
only write, inside `updateExchangeRate`, so zero means that function was never
called. On the deployed token it reads **0**, alongside `exchangeRate` = 1e18 from
the same contract — which is what makes the zero a reading rather than a silence.

## The rehearsal exposed a mainnet fact: it needs a different key

The Sepolia run was broadcast by `0xb5600060e6de5E11D3636731964218E53caadf0E`
(visible as the `from` in the `CommunityOwnerUpdated` event above). On OP mainnet
that address is not a community. Checked against the OP-mainnet Registry-3.0.2,
`COMMUNITY` = `0xe94d78b6d8fb99b2c21131eb4552924a60f564d8515a3cc90ef300fc9735c074`:

| address | `hasRole(COMMUNITY, …)` on OP mainnet |
|---|---|
| `0xb5600060…` Sepolia deployer | **false** |
| `0x51Ac6949…` OP deployer (keystore `optimism-deployer`) | **true** |
| `0x51eDf11f…` governance Safe | false — the control, and see below |

**The mainnet broadcast must be signed by `0x51Ac6949…`, not the key that ran the
rehearsal.** Not dangerous: `forge script --broadcast` simulates the whole script
first, so a wrong signer aborts with `CallerNotCommunity` before anything is sent.
But it would fail confusingly at the worst moment, which is exactly the class of
fact a rehearsal exists to surface. Raised by pr-daemon.

The third row is worth more than its control duty. **The Safe does not hold
COMMUNITY on OP mainnet either**, so once the factory is handed over the Safe can
configure and price the token but cannot call `deployxPNTsToken` on it. Deploying
another community token from that factory would need a `registerRole` for the Safe
first. Not a blocker for this deployment; a surprise waiting for whoever tries the
second one.
