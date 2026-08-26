# CC-48 — Safe / Timelock onboarding runbook

> CC-48 round-7 LOW-5. Written because the governance gate creates a real bring-up
> tension: once `GOVERNANCE_OWNER` is enforced, every `onlyOwner` step has to be driven
> from the Safe, and the cheapest field workaround is to point `GOVERNANCE_OWNER` at a
> contract the operator controls alone. Round-6's gate accepted exactly that. The M-of-N
> check removes the easy version of the shortcut; this document removes the reason to look
> for one.
>
> **What the gate proves:** the owner holds code, is not an EIP-7702 delegation designator,
> and answers `getThreshold()` / `getOwners()` with a Safe-compatible M-of-N configuration
> (`threshold >= 2`, distinct non-zero owners, `owners.length >= threshold`).
> **What it does not prove:** that the owner is a *canonical* Gnosis Safe. That needs an
> audited runtime-codehash or factory allowlist per chain, which does not exist here.
> Deploying the Safe from the canonical factory is therefore a **procedural** requirement,
> not one the script can check for you. Record the factory and singleton addresses you used.

---

## 0. Which owner is which

| Contract | Required owner | Why |
|---|---|---|
| `BLSAggregator` | **Safe-compatible M-of-N only** | `emergencyDisarmFraudProofVerifier()` is immediate and unannounced. A `TimelockController` is refused: a timelocked emergency stop is not an emergency stop. |
| `Registry` | Safe-compatible M-of-N **or** a `TimelockController` with `getMinDelay() > 0` | `setCreditPolicy` is immediate `onlyOwner`; the 5.7.0 batch must be atomic. Declare which via the `TIMELOCK` env var. |
| GToken / staking / SuperPaymaster | out of scope for CC-48 | separate change, separate blast radius |

---

## 1. Before anything is deployed

1. Create the Safe **from the canonical factory** for the target chain, with at least
   `2-of-N` and owners on **distinct** keys and distinct devices. `2-of-2` passes the gate
   but has no recovery path; `2-of-3` or `3-of-5` is the intended shape.
2. Note the Safe address, `getThreshold()`, `getOwners()`, and the factory/singleton
   addresses. These go in the deployment record next to the gate's own log lines.
3. Confirm with a read-only call that the Safe answers both methods:

   ```bash
   cast call <SAFE> "getThreshold()(uint256)"        --rpc-url "$RPC"
   cast call <SAFE> "getOwners()(address[])"         --rpc-url "$RPC"
   cast code  <SAFE>                                 --rpc-url "$RPC" | head -c 12   # not 0xef0100
   ```

   A `0xef0100…` prefix means the address is a **delegated EOA**, not a Safe. The gate
   refuses it and names it; do not work around that.

---

## 2. Deploying an aggregator that is Safe-owned from the first block it matters

`DeployBLSAggregatorSepolia`, `DeployNewBLSModules`, `DeployStandardV3`, `DeployLive`,
`deployment/07b_DeployBLSModules` and `DeployRepCreditSepolia` all follow the same shape:

```
GOVERNANCE_OWNER=<safe> forge script <script> --rpc-url "$RPC" --broadcast
```

`transferOwnership(GOVERNANCE_OWNER)` is the **last** owner-gated action inside the
broadcast, so every earlier owner-only wiring step still runs under the deployer key; the
gate then reads `owner()` as it actually is — not as the script intended to set it — after
`vm.stopBroadcast()`. `forge` simulates the whole script first, so a gate failure aborts
before any transaction is sent.

**Anything the deployer cannot do before the handover must be driven from the Safe
afterwards** (§3). Plan which of these you need *before* deploying, because doing them
under the deployer key is one transaction and doing them from the Safe is one Safe
proposal each:

- `registerBLSPublicKey` on the owner path (validators re-filing PoPs after a migration)
- `setPermissionlessBLSRegistration`
- `proposeFraudProofVerifier` / `applyFraudProofVerifier` (4-day in-contract rotation delay)
- `emergencyDisarmFraudProofVerifier` (the reason the Safe exists)

---

## 3. Driving an `onlyOwner` call from the Safe

Every owner call becomes: build calldata → propose → collect `threshold` signatures →
execute. Nothing here is SuperPaymaster-specific, but the calldata is:

```bash
# example: re-arm a verifier (starts the in-contract rotation delay)
cast calldata "proposeFraudProofVerifier(address)" <VERIFIER>

# example: allow permissionless BLS registration
cast calldata "setPermissionlessBLSRegistration(bool)" true
```

Submit each as a Safe transaction to the aggregator address with `value = 0`. Record the
Safe transaction hash next to the resulting on-chain transaction hash — the pair is what
makes the deployment record auditable later.

**Emergency disarm.** `emergencyDisarmFraudProofVerifier()` is the one call whose whole
value is being fast. Rehearse it: make sure `threshold` signers can actually be reached and
sign within minutes, on the devices they will really be using. A 3-of-5 that in practice
takes a day is not an emergency stop, and the residual risk documented in round-5/6 §3
assumes it is one.

---

## 4. Registry: Safe or Timelock

**Safe-owned** — nothing extra; `UpgradeRegistryTo580` holds Registry to the same M-of-N bar
as the aggregator.

**Timelock-owned** — deploy `TimelockController(minDelay, proposers, executors, admin)`
with `minDelay > 0` and `admin = address(0)` (nobody can re-grant roles to bypass the
delay), proposers = the Safe. Then:

```
TIMELOCK=<timelock> forge script contracts/script/v3/UpgradeRegistryTo580.s.sol …
```

The script asserts `Registry.owner() == TIMELOCK` **and** `TIMELOCK.getMinDelay() > 0`
before it emits anything. A zero-delay Timelock makes `setCreditPolicy` immediate again,
which is the property the atomic batch exists to remove.

> **There is no script in this repository that transfers `Registry` ownership to a Safe or
> Timelock.** It is a manual ops step — `Registry.transferOwnership(<safe|timelock>)` from
> the current owner — and as of this writing the live Sepolia Registry
> (`0xf5Bf37ca…8E71`) and the 4.3.0 aggregator (`0x174b60bB…0158`) are **both owned by an
> EOA** (`0xb5600060…df0e`), so the migration script stops at the governance gate before it
> reaches anything else. See §3 of [`CC48-round7-changes.md`](./CC48-round7-changes.md).

---

## 5. Experiment stacks (and the one acknowledgement that exists)

The RepCredit evidence stack and the CC-89 E2E aggregator need a hot owner to drive an
experiment. That is allowed on a **known testnet only**, and only with:

```
TESTNET_EOA_OWNER_ACK=true
```

which prints, in full, that the deployment has **no** governance defence against an
immediate verifier disarm. There is no acknowledgement that works on a production chain —
the require has no escape hatch there at all. Local anvil work needs
`LOCAL_DEV_GOVERNANCE_ACK=true` (set automatically by `deploy-core anvil`); note that
`anvil --fork-url <mainnet>` also reports chainid 31337, so if you are rehearsing a
production chain on a fork, the gate you are acknowledging away is the one you came to
rehearse.

---

## 5b. Which `GuardianSlashQueued` topic to scan — per aggregator, not globally

`GuardianSlashQueued` gained a `guiltyGuardians` array in `BLSAggregator-4.11.0`, so its
`topic0` differs by aggregator version:

```
<= 4.10.0   GuardianSlashQueued(uint256,bytes32,uint256)
            0xbd29882a64fb25d3f96a8c3b657df25c01d1cf84f77df08564dbea8fc988fd82
>= 4.11.0   GuardianSlashQueued(uint256,bytes32,uint256,address[])
            0xcf5c0505e0bff287d5bb2aaf75cb5409c172bdfa5972505e4431b3e76672958c
```

**Do not "switch the watcher to the new topic".** The topic belongs to the contract that
emitted the log, and the migration preflight scans the **OLD** aggregator — the one you are
migrating away from — to prove it holds no unresolved case. Pointing that scan at the new
topic makes a still-open case invisible and reports the old aggregator clean. That is the
precise failure this section exists to prevent, so keep the two filters separate:

| what you are scanning | topic0 to use |
|---|---|
| OLD aggregator, history up to cutover | the topic **its own version** emits (table above) |
| NEW aggregator (4.11.0+), from deployment on | `0xcf5c0505…` |
| during the migration window | **both addresses, each with its own topic** |

### Why this scan is load-bearing

`requireNoPendingCases` enumerates guardians through `validatorAtSlot`, so an accused
address whose key was already revoked holds no slot and cannot be seen on-chain. Scanning
`GuardianSlashQueued` over the case window is the documented compensating control for
exactly that blind spot (`docs/security/CC48-round3-changes.md` 1.5). A filter on the wrong
topic returns zero events and raises no error, and zero events is indistinguishable from
"no fraud cases".

### Before reading a clean scan as evidence

The failure this section defends against is not theoretical and not exotic: **an endpoint can
answer `eth_getLogs` with a successful, well-formed, empty array when the range is not
empty** — no error, no warning, exit code 0. Measured 2026-08-26 against this aggregator over
`[11492045, 11570738]` (78,693 blocks), same query repeated. The expected value 3 was the
occupied-slot count at that time; re-derive it before reusing these figures, since both the
count and the range move:

| endpoint | `BLSPublicKeyRegistered` (expected 3 at the time) | verdict |
|---|---|---|
| a public no-key endpoint (`ethereum-sepolia-rpc.publicnode.com`) | `0 0 3 0 3 3 0 3 0 0 3 3` — **6 of 12 wrong, 0 errors** | unusable as a sole source |
| one particular Alchemy **key** | `3 3 3 3 3 3 3 3 3 3` — 10 of 10 | stable *for that key, in that sample* |

⚠️ **The second row is a property of a key, not of a provider.** This repo alone carries three
different Alchemy Sepolia keys under near-identical names — `.env.sepolia` has both `RPC_URL`
and `SEPOLIA_RPC_URL`, and operators commonly have another in a personal env — and they sit on
**different tiers**. Measured on the same full-span query: one answered in one call, another
was refused outright for the block range, and a third had been disabled for the network
entirely (HTTP 403). Reading a verdict off the provider name and picking whichever variable
looks right is how you end up running this procedure on an endpoint that cannot execute it.
**Re-measure on the exact key you are about to use.**

Note what this is **not**: it is not a chunking artefact. The whole-range call and chunked
calls both exhibit it, so "don't chunk" is not a fix. It is per-call non-determinism.

**And it is not binary.** Repeating one query against the flaky endpoint — Registry over the
frozen range where the correct answer is 10 — produced:

```
10  3  7  0  7  3  10  3  0  0
```

Not just "complete or empty": **partial results**, with no error on any of them. That matters
for how the checks here are read. `M >= N` still catches a shortfall, because a partial result
for `BLSPublicKeyRegistered` falls below the occupied-slot count. But any check of the form
"the number looks plausible" does not — and a baseline recorded from one of these partial
reads becomes a wrong constant that later partial reads will match.

**The hard part.** When the answer you are checking is *supposed* to be zero, a false empty
and a true empty are identical, and repeating the query cannot separate them — you get zero
every time either way. So a bare "I scanned and found no cases" is not evidence, no matter how
many times it was repeated.

What makes it evidence is pairing it with a query whose answer you already know:

**0. Put a wall-clock cap on every RPC call.** A refusal is not the only failure mode: the
same query that a raw `eth_getLogs` rejects loudly can make `cast logs` **hang with no output,
no error, and no exit** — measured here at 90 s with an empty stdout *and* an empty stderr,
still running when it was killed. Every `|| exit 1` in this section is unreachable in that
state, and to an operator "still working" and "wedged" look identical. This is the same
indistinguishability the section is about, moved into the time dimension, so it needs the same
treatment: make it fail, loudly, on a clock.

```bash
# Portable wall-clock cap. Use it for EVERY cast/curl call below.
rpc() {  # usage: rpc <seconds> <command...>
  local secs=$1; shift
  if   command -v timeout  >/dev/null 2>&1; then timeout  "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
# A timed-out call is a FAILED call: abort the round, never treat it as "no events".
```

Wrap each call as `rpc 60 cast ...` and keep the existing `|| { ...; exit 1; }`. With the cap
in place a wedged endpoint exits non-zero (124 from `timeout`, 142 from the `perl` fallback)
and the guard fires as intended.

**1. Deployment block.** Binary-search the first block with code, using the same wall-clock
wrapper — the search issues ~24 calls and any one of them can wedge:

```bash
rpc 30 cast code "$AGG" --block "$n" --rpc-url "$EP" \
  || { echo "code read at $n failed/timed out — abort, do NOT treat as 'no code'" >&2; exit 1; }
```

Treat an RPC *error* as unknown, never as "no code", or the search walks to the wrong block. For `0x174b60bB…` this is **11492045** (its Registry is a
different contract at a different block; do not reuse one for the other).

**2. Health probe, in the same batch as every scan.** Immediately alongside each
`GuardianSlashQueued` query, issue the same-shape query for `BLSPublicKeyRegistered` over the
identical range, and compare against state. Nothing below is hard-coded to one deployment —
`AGG` and `DEPLOY` come from step 1, and the slot ceiling is read from the contract:

```bash
EP=<rpc-url>
AGG=<aggregator-address>
DEPLOY=<deployBlock from step 1>          # NOT a constant: re-derive per aggregator
HEAD=$(rpc 30 cast block-number --rpc-url "$EP") \
  || { echo "block-number read failed/timed out — abort" >&2; exit 1; }
REG_TOPIC=0x544d98ba9bb0b5ddc2f49ab57954b76f6ff7ffba5e89a9bcb73bbf77ffa31ed3   # BLSPublicKeyRegistered(address,uint8)
Q_TOPIC=<the topic0 this aggregator's version emits — see the table above>

# N — from state. Count only well-formed non-zero addresses; an RPC error must
# abort, never be counted as an occupied slot (that would inflate N) nor skipped
# silently (that would deflate it).
MAXV=$(rpc 30 cast call "$AGG" 'MAX_VALIDATORS()(uint256)' --rpc-url "$EP") \
  || { echo "MAX_VALIDATORS read failed/timed out (rc=$?) — abort" >&2; exit 1; }
N=0
for s in $(seq 1 "$MAXV"); do
  a=$(rpc 30 cast call "$AGG" 'validatorAtSlot(uint8)(address)' "$s" --rpc-url "$EP") \
    || { echo "slot $s read failed/timed out (rc=$?) — abort" >&2; exit 1; }
  case "$a" in
    0x0000000000000000000000000000000000000000) ;;
    0x*[0-9a-fA-F]) N=$((N+1)) ;;
    *) echo "unparseable slot $s: $a" >&2; exit 1 ;;
  esac
done

# M and Q — same endpoint, same range, same chunking, adjacent in time.
# A failed call aborts the round; it never contributes an empty list.
M=$(rpc 120 cast logs --rpc-url "$EP" --from-block "$DEPLOY" --to-block "$HEAD" \
      --address "$AGG" "$REG_TOPIC" --json) \
  || { rc=$?; echo "health-probe query failed (rc=$rc$( [ $rc = 124 ] || [ $rc = 142 ] && printf ' = TIMEOUT' )) — abort, this is NOT 'no events'" >&2; exit 1; }
Q=$(rpc 120 cast logs --rpc-url "$EP" --from-block "$DEPLOY" --to-block "$HEAD" \
      --address "$AGG" "$Q_TOPIC"   --json) \
  || { rc=$?; echo "GuardianSlashQueued query failed (rc=$rc$( [ $rc = 124 ] || [ $rc = 142 ] && printf ' = TIMEOUT' )) — abort, this is NOT 'no cases'" >&2; exit 1; }
M=$(printf '%s' "$M" | jq 'length')
Q=$(printf '%s' "$Q" | jq 'length')
echo "N=$N M=$M Q=$Q"
# N==0 makes M>=N vacuous — see 2b. Refuse rather than report a meaningless pass.
[ "$N" -gt 0 ] || { echo "N=0: this probe cannot certify anything here; use 2b" >&2; exit 2; }
[ "$M" -ge "$N" ] || { echo "batch untrustworthy (M<N) — discard, including Q" >&2; exit 1; }
```

If the endpoint rejects the span it will say so — the ceiling is whatever it reports, and it
is not stable: the same host answered 78,693-block queries for one operator and refused them
with `exceed maximum block range` for another, in the same hour. Do not hard-code a chunk
size; react to what the endpoint returns, and if you chunk, chunks must tile `[DEPLOY, HEAD]`
with no gap and any failed chunk aborts the round.

**2b. When `N == 0` this probe is worthless — and that is the worst case, not a corner
case.** `M >= N` becomes `M >= 0`, which every false empty satisfies. Worse, `N == 0` does
**not** mean there are no cases to find: `_validateGuardianSet` is `pure` and checks only
non-empty / length / non-zero / no-duplicates, so **any address can be an accused guardian,
occupying a slot or not**. An aggregator whose keys were all revoked reads `N == 0` while
being exactly the situation `requireNoPendingCases` cannot see — the blind spot this whole
section compensates for is widest precisely where the probe goes blind.

So when `N == 0`, do not run the check above and read a pass from it. Substitute a different
known-answer anchor over the **same endpoint and the same range**, in this order of
preference:

1. **A state-derived expectation on another contract.** Anything where you can compute the
   expected log count without trusting the log index, as `N` did.
2. **A PREVIOUSLY established baseline over a FROZEN, FINALIZED range** (see the boxed note
   below for why it must pre-exist). Pick a second address known to be active in that range —
   the Registry is the natural one — and record its log count together with the exact
   `[from, to]` you counted over. Two separate requirements on `to`:

   - **Not `head`.** A range ending at `head` grows as the chain advances, so a fixed
     expected value is wrong by tomorrow: demanding equality raises false alarms, relaxing to
     `>=` gives up most of the detection.
   - **At or below the finalized block.** A fixed height is not a fixed history — blocks
     above finality can be reorged, so the same height can hold different logs later and the
     baseline would flag a healthy endpoint. Take it from `cast block finalized`, and leave
     margin: when this was written Sepolia's finalized block lagged `latest` by ~80 blocks.
     (The first baseline drafted here, `11570891`, was 43 blocks *above* finalized — the
     mistake is easy to make, which is why the script asserts it.)

   With both satisfied the range is genuinely immutable and can be required to match exactly:

   ```bash
   BASE_ADDR=<second contract>     # e.g. the Registry
   BASE_FROM=<fixed>  BASE_TO=<fixed>   # frozen; NOT $HEAD, and <= finalized
   BASE_EXPECT=<count verified when the baseline was taken>

   # A fixed height is only immutable once it is finalized. Resolve finality in its own
   # step: in a pipeline `||` sees only the last command, so a dead RPC would leave FIN
   # empty and the failure would surface as the misleading "BASE_TO is above finalized=".
   FIN_JSON=$(rpc 30 cast block finalized --rpc-url "$EP" --json) \
     || { echo "finality lookup failed — cannot validate the baseline" >&2; exit 1; }
   FIN=$(printf '%s' "$FIN_JSON" | jq -r '.number // empty')
   [ -n "$FIN" ] || { echo "finalized block missing from response" >&2; exit 1; }
   FIN=$(printf '%d' "$FIN" 2>/dev/null) \
     || { echo "unparseable finalized block: $FIN" >&2; exit 1; }
   [ "$BASE_TO" -le "$FIN" ] || {
     echo "BASE_TO=$BASE_TO is above finalized=$FIN — reorgable, not a baseline" >&2; exit 1; }

   got=$(rpc 120 cast logs --rpc-url "$EP" --from-block "$BASE_FROM" --to-block "$BASE_TO" \
           --address "$BASE_ADDR" --json) \
     || { echo "baseline query failed/timed out — cannot validate the baseline" >&2; exit 1; }
   [ "$(printf '%s' "$got" | jq 'length')" -eq "$BASE_EXPECT" ] || {
     echo "endpoint failed the frozen baseline — do not trust this batch" >&2; exit 1; }
   ```

   Measured here: Registry `0xf5Bf37ca…` over the frozen, finalized range
   `[11492045, 11570000]` returns **10**, identical across repeats. The real scan still runs
   to `head`; only the baseline is frozen.

   ⚠️ **A baseline is established once, ahead of time, and only then is it usable as a
   single-endpoint check.** That split is the whole point of it, so keep the two phases
   distinct:

   - **Establishing it** requires **two independently operated endpoints that agree** on the
     count over the frozen range. Never derive it from the endpoint it will later check —
     that is the endpoint certifying itself: if it was misbehaving when the baseline was
     recorded, the baseline captures the wrong number and every later bad read matches it.
     A correct value obtained that way is luck, and nothing afterwards distinguishes the two.
   - **Using it** needs only one endpoint. That is what a baseline buys: the cross-endpoint
     cost is paid once, and every later check compares against a value that did not come
     from the endpoint under test.

   So this option applies when you **already hold** such a record. If you do not, you are not
   choosing between "baseline" and "cross-endpoint" — establishing one *is* a cross-endpoint
   check, so run step 4 directly and, if you can, record the result as a baseline for next
   time. With only a single endpoint available, neither is possible: record the pending-case
   question as UNRESOLVED.

   **Record the endpoint and key the baseline was taken on, alongside the numbers.** A
   baseline is a claim about one endpoint's behaviour, so carrying it to a different key —
   even at the same provider, see the warning above — compares against something that was
   never measured. Store `(BASE_ADDR, BASE_FROM, BASE_TO, BASE_EXPECT, endpoints agreed,
   key ids)` as one record, and re-take it when a key changes. Be honest about the strength: a baseline is an empirical constant, not
   derived from state, so it is weaker than `M >= N` — it detects an endpoint that has
   stopped answering, not one that was always wrong.
3. **No state-derived anchor and no pre-existing baseline ⇒ go straight to step 4**
   (two independent endpoints must agree on the `GuardianSlashQueued` count itself). Only if
   that is unavailable too — a single endpoint and nothing recorded — is the answer
   **UNRESOLVED**. Never fall back to "the scan returned no cases".

   Note the baseline in (2) does **not** degenerate the way `M >= N` does at `N == 0`: its
   expected value is a recorded non-zero constant, so a false empty fails it. What it cannot
   do is prove the endpoint was healthy for the *other* call in the batch — that limit is the
   same one stated for `M >= N`, and it is why step 4 does the heavy lifting on this path.

In all three, cross-endpoint agreement (step 4) does more work than it does in the `N >= 1`
path, because it is the only remaining control that does not depend on this endpoint's own
output.

`M < N` ⇒ that batch is not trustworthy; discard it, including its `GuardianSlashQueued`
result. **`M >= N` licenses only the call that produced it.** The non-determinism is per-call,
so a healthy `M` does not certify the `Q` call sitting next to it — it only removes batches
you can already prove are broken.

**2c. The real scan runs to `head`, and its tail is not final.** You must scan to `head` — a
case queued a minute ago is exactly what you are looking for — but everything above the
finalized block can still be reorged, so a `Q = 0` covering that tail is provisional. Two
consequences for a migration:

- Re-run the scan immediately before scheduling the batch, not once hours earlier.
- Prefer to take the decision when the range you care about has finalized. If you cannot
  wait, record explicitly that the clean result covers `[DEPLOY, finalized]` firmly and
  `(finalized, head]` provisionally — that is an honest status; "clean" full stop is not.

```bash
# Report coverage of what was ACTUALLY scanned. Finality can advance past $HEAD while the
# scan runs, and blocks above $HEAD were never looked at — being finalized does not make
# them scanned, so the firm bound is capped at $HEAD.
#
# Resolve finality in its own step and validate it. In a pipeline, `|| exit` only sees the
# LAST command, so a dead RPC leaves FIN empty, `[ "" -lt N ]` errors to stderr, the `if`
# takes its else branch, and the report announces "firm throughout" — the strongest status
# this line can issue, produced by a lookup that wholly failed.
FIN_JSON=$(rpc 30 cast block finalized --rpc-url "$EP" --json) \
  || { echo "finality lookup failed — coverage unknown" >&2; exit 1; }
FIN=$(printf '%s' "$FIN_JSON" | jq -r '.number // empty')
[ -n "$FIN" ] || { echo "finalized block missing from response — coverage unknown" >&2; exit 1; }
FIN=$(printf '%d' "$FIN" 2>/dev/null) \
  || { echo "unparseable finalized block: $FIN" >&2; exit 1; }

if [ "$FIN" -lt "$HEAD" ]; then FIRM=$FIN; else FIRM=$HEAD; fi
if [ "$FIRM" -lt "$HEAD" ]; then
  echo "scanned [$DEPLOY, $HEAD]: firm through $FIRM, provisional $((FIRM+1))..$HEAD"
else
  echo "scanned [$DEPLOY, $HEAD]: firm throughout (finality has passed $HEAD)"
fi
```

**3. Repeat the paired scan K times and require every round to agree** (K >= 5; every round
must show `M >= N` *and* the same `GuardianSlashQueued` result). Any disagreement ⇒
**UNRESOLVED**. With a per-call false-empty rate `p`, K agreeing rounds leave roughly `p^K`
residual — which is why step 4 matters more than K does.

**4. Use an endpoint that does not exhibit this, and prove it does not** by running step 3
against it. Then corroborate with a second, independently operated endpoint and require both
to agree. This is the control that actually carries the weight; K repetitions of a bad
endpoint do not add up to a good one.

**5. Error handling is part of the check.** A failed call must abort the round, never
contribute an empty list to a sum — `... || echo 0` in a chunk loop silently converts every
error into "no events found", which is the same false-clean by another route.

**6. Replaying a known past case** is the strongest check where one exists; most aggregators
never had one, so it cannot be the primary control.

If these cannot be satisfied, record the pending-case question as **UNRESOLVED** rather than
clean. "We could not verify" is a usable migration status; "clean" from an unverifiable scan
is not.

### One special case worth naming

A predecessor that predates the feature emits this event **never**, at either topic —
Sepolia's `BLSAggregator-4.3.0` has no `queueGuardianSlash` at all (`GUARDIAN_SLASH_CASE_WINDOW`,
`pendingGuardianSlashCount` and friends all revert as non-existent functions). Its zero is
real, but it is evidence of *the feature being absent*, not of *cases having been resolved*.
Prove that from the deployed ABI surface — which is what the preflight does — rather than
from an empty log scan, because an empty log scan looks identical when the watcher is simply
misconfigured.

From 4.11.0 on the event carries the guardian array itself, so a correctly-pointed watcher
can reconstruct the exact `guiltyGuardians` set — which is what `expireGuardianSlashCase`
requires, and that array exists nowhere else once the queueing transaction's calldata is out
of reach.

## 6. What to keep

For every production or rehearsal deployment, keep:

- the `[gov-gate]` block from the transcript — owner, `getThreshold()`,
  `getOwners().length`, the enumerated owners, and the `criterion` / `NOT proven` lines;
- Safe address + factory/singleton addresses + the chain;
- for a Timelock: address, `getMinDelay()`, proposers, executors, and that `admin == 0`;
- the Safe transaction hash ↔ on-chain transaction hash pair for every owner call.
