# CC-115 B3 — successor stack deployment manifest

`cc115-b3-successor-manifest.template.json` is the receipt sheet for deploying a
successor Registry 5.8.0 + BLSAggregator 4.11.0 stack. It is **not** a config file:
nothing reads it, and nothing should copy values out of it into a deployment.

## The one rule

**Every `null` is an unmet obligation, and a `null` that survives into an evidence
bundle is UNRESOLVED — never an implicit pass.** Fields that are knowable from the
build are pre-filled and marked `source: build`; everything else must be replaced
with an on-chain observation *and the block it was read at*.

## Why "expected" is not evidence

`postExecutionAssertions` carries both `expected` and `observed` for each check.
`UpgradeRegistryTo580` prints the expectations at the end of its run; a manifest
that records only those has recorded the script's intention, not the chain's state.

## Three traps this template exists to close

**1. The build hash is not the on-chain hash.** `buildRuntimeKeccak` is
`keccak256` of the artifact's `deployedBytecode`. Registry carries 2 immutable
placeholders and BLSAggregator carries 10 — the deployer fills them at construction,
so the deployed runtime *will* differ. Record both: the build hash identifies which
source was compiled, `onchain.extcodehash` identifies what is actually there.
Neither substitutes for the other.

**2. There is no direct verifier setter.** SP 4.11 arms a fraud-proof verifier only
via `proposeFraudProofVerifier` (owner) → wait `VERIFIER_ROTATION_DELAY` (4 days) →
`applyFraudProofVerifier` (permissionless). A new aggregator starts dormant at
`address(0)`. A manifest that jumps from deployment to an active verifier is
describing a contract that does not exist, so every step has its own receipt,
including the measured delay.

**3. A clean event scan is not evidence of a clean scan.** Per
`docs/security/CC48-safe-onboarding-runbook.md` §5b, an endpoint can return a
successful, well-formed, **empty** array for a non-empty range — no error, exit 0,
non-deterministically, per call. When the value under test is supposed to be zero, a
false empty and a true empty are byte-identical, so repetition alone cannot
distinguish them. `scanEvidence` therefore requires a paired positive control in the
same batch and range, K≥5 repetitions in full agreement, and a second independently
operated endpoint. If those cannot be satisfied, the honest value of `result` is
`UNRESOLVED`.

## Scope: fresh stack vs in-place migration

`manifest.stackKind` defaults to `fresh-isolated`, which is what CC-115 B3 declares.
On a fresh stack there is no predecessor to disarm, so `predecessorRevoke` stays null
with reason `n/a: fresh stack`.

If it is ever changed to `in-place-migration`, that block becomes **required**, and
the ordering matters: during the successor's 4-day arming window the successor is
fail-closed and can open no case, while the deposed predecessor already has its
verifier wired, holds an `immutable REGISTRY`, and never asks Registry whether it is
still the registered aggregator — its slash path does not go through Registry at all.
For that entire window the only contract able to open a guardian-slash case is the one
Registry no longer points at, and `GTokenStaking.authorizedSlashers` is the only
switch that cuts it off. So the revoke must land, and read `false`, **before** the
arming window opens.

That is history, not theory: on Sepolia `0xF51c0298…` is still an authorized slasher,
because the `0x893b→0xF51c` rotation revoked its predecessor by hand and the next
rotation forgot to. PR #379 made the revoke an atomic step of the batch for exactly
this reason.

## Provenance of the pre-filled values

Built from `main` at the commit recorded in `source.commit`, profile `default`
(`deploy-core` never sets `FOUNDRY_PROFILE`). At the time of writing:

| | Registry | BLSAggregator |
|---|---|---|
| `version()` | `Registry-5.8.0` | `BLSAggregator-4.11.0` |
| runtime size | 23,038 B | 23,667 B |
| EIP-170 headroom | 1,538 B | 909 B |
| immutable placeholders | 2 | 10 |

Re-derive rather than trust this table — it is a snapshot, and sizes are
branch-specific:

```bash
forge build
python3 -c "import json;d=json.load(open('out/Registry.sol/Registry.json'));\
rt=d['deployedBytecode']['object'];print(len(rt.removeprefix('0x'))//2)"
cast keccak "$(python3 -c "import json;print(json.load(open('out/Registry.sol/Registry.json'))['deployedBytecode']['object'])")"
```
