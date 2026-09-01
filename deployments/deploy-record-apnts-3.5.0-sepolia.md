# aPNTs 3.5.0 — Sepolia, current

**Deployed 2026-09-01, chain 11155111.** Replaces the aPNTs in
`config.sepolia.json`; the rest of the Sepolia stack is untouched (option A).

| | |
|---|---|
| aPNTs | `0x948C9d1Bd99B39DEE482C23d6A3BD26210B56040` |
| xPNTsFactory | `0xc83EDcb81964a259Eb9392BC8b4B5B2929a89774` |
| both owners | `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114` — Mycelium Safe |
| supply | 2,000,000 aPNTs, all to `0xb5600060…` for experiments |
| Registry | `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71` (Registry-5.8.0) |

Five transactions, all status `0x1`: factory · `deployxPNTsToken` · `mint` ·
`transferCommunityOwnership` · factory `transferOwnership`.

## Mint order is load-bearing

`mint` is `onlyFactoryOrOwner`, so once `communityOwner` is the Safe every mint is
a multisig transaction. That is the right steady state and the wrong way to put a
starting float on a fresh token, so the script mints **before** the handover — the
same order the official `DeployLive` uses. An earlier deployment of this token
(`0x5Cfc992f…`, supply 0) transferred first and left no way to fund it without the
Safe; it is superseded and unwired.

## Verified on chain, not from the deploy log

The deploy script's own `require`s run in the simulation, after `stopBroadcast`, so
they cannot see a half-applied chain. `15_VerifyAPNTs` re-reads everything:

```
aPNTs           XPNTs-3.5.0
  communityOwner  0x51eDf11f…  Safe
  FACTORY         0xc83EDcb8…  matches
  totalSupply     2,000,000
factory         xPNTsFactory-2.3.0-clone-optimized
  owner           0x51eDf11f…  same Safe
  decimals        18
  aPNTsPriceUSD   $0.02   MIN $0.001   MAX $100
RESULT: OK   exit 0
```

Reproduce:

```
EXPECT_CHAIN_ID=11155111 MINT_AMOUNT=2000000000000000000000000 \
APNTS=0x948C9d1Bd99B39DEE482C23d6A3BD26210B56040 \
FACTORY=0xc83EDcb81964a259Eb9392BC8b4B5B2929a89774 \
forge script contracts/script/deployment/15_VerifyAPNTs.s.sol:VerifyAPNTs \
  --rpc-url "$SEPOLIA_RPC_URL"
```

`MINT_AMOUNT` must match what the deploy minted: the check is that supply equals
**exactly** the declared amount, so a second mint in the ownership gap fails it.

## What this fixes, and what it does not

It changes **who may mint, not whether minting is bounded**. `issuanceCap` is not a
mint gate — one `_mint` call site guarded only by `onlyFactoryOrOwner`, and the cap
is read solely by the view `isOverIssued()` that DVT calls, unset by default. The
Safe can still mint without limit; it cannot do so unilaterally, and over-issuance
stops being silent. Bounding issuance is a governance question, not a contract one.

## The four Sepolia aPNTs

| address | version | supply | owner | consumer |
|---|---|---|---|---|
| `0x948C9d1B…` | 3.5.0 | 2,000,000 | **Safe** | this config, from now |
| `0x696A7370…` | 3.4.0 | 12,734,618 | `0x51C00187…` EOA | superseded here; DVT x402 leg |
| `0x9e66B457…` | 3.4.0 | 22,630 | `0xb5600060…` EOA | DVT relay whitelist |
| `0xDf669834…` | 3.0.0-unlimited | 378,709 | `0xb5600060…` EOA | repo:airaccount presets (stale) |

Downstream repos still point at the older ones. Notified; each has to decide its
own cutover. The reason there are four: both deploy entry points had a
`GOVERNANCE_OWNER` handover that moved only `BLSAggregator`, so every fresh
deployment produced another EOA-owned token — fixed in #404.
