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

## 5b. Repoint your watcher before trusting the migration preflight

`GuardianSlashQueued` gained a `guiltyGuardians` array in `BLSAggregator-4.11.0`, which
moves its `topic0`:

```
old  GuardianSlashQueued(uint256,bytes32,uint256)
     0xbd29882a64fb25d3f96a8c3b657df25c01d1cf84f77df08564dbea8fc988fd82
new  GuardianSlashQueued(uint256,bytes32,uint256,address[])
     0xcf5c0505e0bff287d5bb2aaf75cb5409c172bdfa5972505e4431b3e76672958c
```

A watcher still filtering on the old topic **returns zero events and raises no error**.
Zero events is indistinguishable from "no fraud cases", and that ambiguity lands on a
control this runbook depends on: `requireNoPendingCases` enumerates guardians through
`validatorAtSlot`, so an accused address whose key was already revoked holds no slot and
cannot be seen on-chain. Scanning `GuardianSlashQueued` over the case window is the
documented compensating control for exactly that blind spot
(`docs/security/CC48-round3-changes.md` 1.5).

Before reading a watcher's "no pending cases" as evidence for scheduling an upgrade batch:

1. update the filter to the new topic (or to the regenerated ABI — `abis/BLSAggregator.json`);
2. replay a known historical case and confirm the watcher reports it;
3. only then treat a clean scan as clean.

The array is now carried in the event itself, so a repointed watcher can reconstruct the
exact `guiltyGuardians` set — which is also what `expireGuardianSlashCase` requires, and
that array exists nowhere else once the queueing transaction's calldata is out of reach.

## 6. What to keep

For every production or rehearsal deployment, keep:

- the `[gov-gate]` block from the transcript — owner, `getThreshold()`,
  `getOwners().length`, the enumerated owners, and the `criterion` / `NOT proven` lines;
- Safe address + factory/singleton addresses + the chain;
- for a Timelock: address, `getMinDelay()`, proposers, executors, and that `admin == 0`;
- the Safe transaction hash ↔ on-chain transaction hash pair for every owner call.
