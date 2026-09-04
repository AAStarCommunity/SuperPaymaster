# aPNTs 3.5.0 — Sepolia, SUPERSEDED 2026-09-04

> **This deployment is abandoned. Do not act on anything below it.**
>
> The token it describes, `0x948C9d1Bd99B39DEE482C23d6A3BD26210B56040`, was handed
> to the Mycelium governance Safe. That was correct for OP mainnet, where an EOA
> must not be able to mint (CC-46), and wrong here: the script hardcoded the Safe
> as a `constant`, so a TEST token ended up behind a 2-of-3 whose owners
> (`0x871608cB` / `0xBB05d2E9` / `0x8c349925`, measured on chain) are not ours.
> Every routine test action needed two signatures nobody here has. The repo's own
> convention is the opposite: testnets may use a test EOA, production converges
> on the Safe.
>
> **The live Sepolia aPNTs is now `0xBb46321545a91DB2F3B5c3e694F2f23aBe259883`**
> (factory `0x0E54b9e2c2032dCe6Ce14E12EA70b4e6eff2A244`), both owned by
> `0xb5600060e6de5E11D3636731964218E53caadf0E`, 2,000,000 minted, and already
> wired: `SUPERPAYMASTER_ADDRESS` is set and the paymaster is an auto-approved
> spender — the two steps this document asks a Safe to perform were done directly,
> because the owner is now a key we hold.
>
> SuperPaymaster's pending aPNTs swap points at the new token, ETA
> **2026-09-11 11:11**. What remains on that day: drain the two operator balances
> and the protocol revenue to the 0.1 buffer, `executeAPNTsTokenChange()`, deposit
> the new token, flip `config.sepolia.json`, then re-run `15_VerifyAPNTs` with
> `ALLOW_POST_DEPLOY_ACTIVITY=true`.
>
> Kept unedited below as the record of what was deployed and why, including the
> reasoning that still applies to OP mainnet. The cutover sequence in it names the
> Safe and the old addresses; both are obsolete.

## Original record, as written on 2026-09-02 (obsolete — see the banner above)

**Deployed 2026-09-01, chain 11155111. NOT yet the configured aPNTs.** The token
exists, is Safe-owned and funded; `config.sepolia.json` still points at the old
`0x696A7370…` and must, until the cutover below is done. See "Why the config was
not switched".

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
EXPECT_CHAIN_ID=11155111 \
APNTS=0x948C9d1Bd99B39DEE482C23d6A3BD26210B56040 \
FACTORY=0xc83EDcb81964a259Eb9392BC8b4B5B2929a89774 \
forge script contracts/script/deployment/15_VerifyAPNTs.s.sol:VerifyAPNTs \
  --rpc-url "$SEPOLIA_RPC_URL"
```

The expected supply is no longer passed in. It is read from
`deployments/apnts-deploy-record.<chainId>.json`, which `14_RedeployAPNTs` writes at
deploy time from the amount it was told to mint — a declaration made before the chain
is consulted, and the only source that can disagree with the chain. A missing record
fails the run; it is not treated as "nothing to check". The check is still that supply
equals **exactly** the declared amount, so a second mint in the ownership gap fails it.
(`EXPECT_CHAIN_ID` is still read, at `15_VerifyAPNTs.s.sol:47`; it defaults to OP
mainnet.)

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


## Why the config was not switched

Pointing `config.sepolia.json` at this token was wrong and was reverted. The token
is not wired, and SuperPaymaster cannot be pointed at it today:

```
new 0x948C9d1B…   SUPERPAYMASTER_ADDRESS  0x0        autoApprovedSpenders[SP]  false
old 0x696A7370…   SUPERPAYMASTER_ADDRESS  0x09DF0d2e  autoApprovedSpenders[SP]  true    <- control
SuperPaymaster 0x09DF0d2e…   APNTS_TOKEN = 0x696A7370…  (the OLD token)
```

`SuperPaymaster.setAPNTsToken` queues behind a **7-day** `APNTS_TOKEN_TIMELOCK`
and then needs an apply, so the pointer cannot move today. Flipping the config
alone would have left the record naming one token while the paymaster charged
another — the same shape as the 2026-08-30 aggregator split, created deliberately
by me this time, and it would have broken the gasless path. Found by Codex at
stop-time review.

### Cutover sequence, when someone wants it

1. **Safe** (it owns the token now): `setSuperPaymasterAddress(0x09DF0d2e…)` and
   `addAutoApprovedSpender(0x09DF0d2e…)` on `0x948C9d1B…`.
2. **SP owner**: `setAPNTsToken(0x948C9d1B…)`, wait 7 days, then apply.
3. Only then flip `config.sepolia.json`, and re-run `15_VerifyAPNTs` — with
   `ALLOW_POST_DEPLOY_ACTIVITY=true`, because steps 1 and 2 deliberately leave the
   fresh-clone state the default run asserts (a SuperPaymaster is now set, and a
   spender is auto-approved). That run prints `RESULT: OK (REDUCED)` and names what
   it did not check: the defaults and the supply-vs-record comparison. It is an
   owner check at that point, not a deploy check.

Steps 1 and 2 can run in parallel; step 3 must be last. Both halves of step 1 are
Safe transactions, which is the intended steady state — but it is why the wiring
could not simply ride along with the deploy: the factory was given
`superPaymaster = address(0)`, so the token was born unwired and then handed over.
Minting was moved before the handover for the same reason; the SP wiring was not,
and that is the gap this section records.
