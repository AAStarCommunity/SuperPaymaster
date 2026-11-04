# L-1 old-owner isolation — DSR ruling, 2026-11-04

This implements option (a). Pin-time source selection is **deployed source**;
there is no release-layout fallback and no treatment of a reverting getter as
absence. Work is uncommitted. No network request, live transaction or real fork
was run during this change.

## Source authentication and manifest integration

`manifest_exec.collect()` calls `collect_deployed()`. `inventory_source()` defaults
to deployed mode. Each target is discovered from pinned getters; factory tokens
and operator tokens are combined. Every token instance gets its own authenticated
inventory, even when two clones have different implementations or commits.

Supply `externalInputs.data.deployedSources`, keyed by lowercase target address:

```json
{
  "0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71": {
    "contract": "Registry",
    "implementation": "0x9bed0f58d6001b0006923eb8c4b1cc548d42ccee",
    "commit": "c30854f91833ae0d3fd6b7ec027ae53b138a3337",
    "creationBlock": 123
  }
}
```

This is a schema example, **not usable evidence**: `123` is a placeholder and the
commit is only a candidate. Supply exactly all discovered targets, including every
xPNTs clone. Resolve any tag to its full commit SHA. `creationBlock` is the target
or proxy's deployment block, not its implementation's deployment block.

The source gate:

1. Checks the canonical pin before and after source authentication.
2. Requires no target code immediately before the supplied creation block and
   nonempty code at that block. The Registry boundary must also agree with the
   existing `registryCreation` evidence.
3. Resolves ERC-1967 implementation storage and standard EIP-1167 clone runtime;
   direct contracts use their own address. Checks the supplied implementation.
4. Archives the exact commit and locally retained submodule objects into a fresh
   temporary tree. Runs `forge build --offline --ast --build-info` with the
   committed default profile. Missing dependencies/source/compiler stop execution.
5. Compares full pinned implementation runtime against the fresh artifact, masking
   only bounded, nonoverlapping 32-byte compiler immutable-reference ranges.
   Metadata bytes are not stripped.
6. Extracts AST/ABI authority, role and mapping inventory from that same build.
   Records target, implementation, commit, compiler, settings, Forge version,
   immutable ranges, runtime hash and parity result.

`build_plan()` reconstructs this evidence from source RPC transcripts and fresh
cached commit builds with `validate_deployed()`. Both endpoint audits are replayed;
unused queries, changed queries/results/inventories and extra transcript fields
stop replay. Endpoint identities hash the public origin plus endpoint label;
credentials, paths and query parameters are never retained in those identities.
As before, transcript replay proves predicates, not the honesty of RPC providers.
Dual-endpoint collection remains mandatory.

## Candidate deployed-source mapping

All addresses below are **offline candidates**, not assertions about a new pin.
Registry/SP implementations come from retained snapshots and deployment config.
Direct addresses come from config; APNTsCapped is calculated from deployer CREATE
nonce 12133. Clone implementations must be read at the pin.

| Contract / candidate version | Implementation candidate | Candidate commits / tags | Status |
|---|---|---|---|
| Registry-5.8.0 | `0x9bed0f58d6001b0006923eb8c4b1cc548d42ccee` | `bb2610e8`, `c30854f9` | STOP; parity unverified |
| SuperPaymaster-5.4.2 | `0xe25f88dbeafc64200270a948df8e9dd2f9b22c27` | `6a6d2d17`, `v5.4.2` → `e1ddf9dd` | STOP; parity unverified |
| APNTsCapped-1.0.0 | `0x9eb17fac022557f64924aa2f9e018db3a330e1e7` | `d2ca897e`, `3be99c94`, `03f8bdeb` | STOP; parity unverified |
| TimelockController (OZ 5.0.2; no version getter) | `0x86c86c789edc099801cc6a5f48334f1d67dc9564` | `89e1cb64`, `03f8bdeb` | STOP; parity unverified |
| Staking-4.2.0 | `0x472297b557c1d0f030f281a5bb8a535f6c5ab65e` | `8074c2b4`, `03f8bdeb` | STOP; parity unverified |
| GToken-2.1.2 | `0x4c09ae57503aa1e2a43b05621a38dbdd43b0aa08` | `73f43561`, `03f8bdeb` | STOP; parity unverified |
| xPNTsFactory-2.3.0-clone-optimized | `0x67422d2e44a33c8da99b3b776841bf316bd209a2` | `27c08c03`, `03f8bdeb` | STOP; parity unverified |
| XPNTs-3.5.0, per discovered token | **Unknown; resolve each clone at pin** | `d8893493`, `v5.4.2`, `03f8bdeb` | STOP; parity unverified |
| MySBT-3.2.0 | `0x4867b4302bf4c7818b71f55e53a3520ee1855aa7` | `351a8991`, `03f8bdeb` | STOP; parity unverified |
| PaymasterFactory-1.0.2 | `0xa936f8e3d682b0ecf280e6f5c05ff4204ee87180` | `73f43561`, `03f8bdeb` | STOP; parity unverified |

[deployed_source_candidates.json](deployed_source_candidates.json) contains full
SHAs, source paths, version-string checks and each attempted rebuild's actual STOP.
Every attempted build stopped at `rebuild_submodule_unavailable` for
`contracts/lib/chainlink-brownie-contracts`, before compiler execution. Solady and
other historical dependency objects/compiler installations may also be needed;
they have not been claimed available. No candidate is promoted to authenticated
source merely because its version string matches. The retained pending token
`0xbb46321545a91db2f3b5c3e694f2f23abe259883` is XPNTs-3.5.0, **not APNTsCapped**.

## Role history and controls

Role IDs are the union of source constants, Registry configuration-event IDs and
RoleGranted/RoleRevoked IDs. Every inventoried target, including non-AccessControl
contracts and each clone, gets both an unfiltered role-event query and a query
filtered to account=OLD. Every OLD grant must be cancelled by a later revoke,
ordered by block, transaction index and log index. Current `hasRole` and Registry
role-owner checks also apply to event-discovered IDs.

History covers deployment block through pin, inclusively, on both endpoints.
Queries use the existing bounded/bisected `schedule_logs`; responses of 1000 or
more trigger bisection. A full-range result must agree with a disjoint two-range
cover, and the OLD-filtered result must agree with the unfiltered history.
Event address, topics, block bounds/hash/number, removed flags, transaction/log
identity and duplicates are checked. Canonical blocks are cached per event block;
there is no block-by-block scan. Standard source roles must have event coverage
for `hasRole` contracts. Missing coverage stops; it is never silently excused.
Range-cover comparisons detect inconsistent truncation, not a provider that
consistently fabricates or omits the same history on every query.

Every extracted mapping gets its own live positive-holder search, including
principals, discovered targets and factory tokens. Every role gets live membership
controls; every allowance token gets a positive allowance search. Getter words
must be normal 32-byte returns; empty returns, reverts and malformed words stop.

When there is no live positive holder, `fork_probe()` executes a setter path for
CONTROL, reads nonzero/true, restores, executes the same path for OLD and requires
the actual exclusion assertion to STOP. Each trial restores its snapshot, also
on failures. Missing fork or setter paths report `unverified` and stop.
Timelock `grantRole` and token `approve` paths are provided. Contract-specific
mapping/Registry registration paths are supplied in the manifest's bound
`isolationControlCases`; the getter and STOP gate must match the audited surface.

Example mapping case (addresses and signer must be resolved for the actual pin):

```json
{
  "<target>:isReputationSource(address)": {
    "sender": "<current authorized owner>",
    "gate": "old_owner_mapping_Registry_isReputationSource",
    "transactions": [{
      "target": "<target>",
      "signature": "setReputationSource(address,bool)",
      "args": ["$ACCOUNT", "true"]
    }],
    "getter": {
      "target": "<target>",
      "signature": "isReputationSource(address)",
      "args": ["$ACCOUNT"]
    }
  }
}
```

Role cases use `<target>:<bytes32-role>` keys. Transactions may include multiple
prerequisite calls; `$ACCOUNT` is replaced identically for CONTROL and OLD. This
executes contract code, not direct writes to authorization storage.

Safe controls are separate from owner membership:

- Fallback storage must equal `0xfd0732dc9e303f09fcef3a7388ad10a83459ec99` and differ
  from OLD. This full address is retained in the repository's precheck snapshots.
  An authoritative Safe 1.4.1 deployments-list attribution was not found offline;
  the evidence explicitly flags canonical-list confirmation for DSR.
- Guard uses a Safe self-call to `setGuard(CONTROL)`, checks the exact slot, then
  repeats for OLD and requires STOP. The fork-only guard address receives minimal
  IERC165-compatible code so the real Safe setter executes its interface check.
- Modules use Safe self-call `enableModule`, read `isModuleEnabled` and
  `getModulesPaginated`, then inject OLD and require STOP. The live module page
  must retain the existing empty-module invariant.

Set `OLD_OWNER_CONTROL_RPC` only to an already hydrated localhost Anvil instance
at exactly `stateBlock`/`stateBlockHash`. The code never starts an upstream fork or
uses a public fork endpoint. A missing engine/fork does not count as verification.

## Manifest calldata and M2.5 hook

`build_plan().finish()` ABI-decodes all transactions and variants before returning
a plan. Constructor arguments are separated from the exact creation-bytecode
prefix and decoded too. ABIs come from the retained release compile, with explicit
Safe and external committee signatures. Unknown call selectors stop. Values are
visited recursively through tuples/arrays; known calls inside bytes recurse.
Safe, Timelock, upgrade and multicall payloads must themselves decode. A byte scan
also rejects OLD anywhere in argument bytes, including opaque/packed payloads.

There is no existing M2.5 post-upgrade fixed-block check in this repository.
`stage_readback()` is a local staged-manifest domain check, not that acceptance
check. The explicit integration hook is:

```python
post_upgrade_check(rpc, post_pin, release_tree, release_targets,
                   token_kinds, pre_upgrade_isolation, fork=local_fork)
```

The caller must:

- Use the retained, authenticated release rebuild tree and a canonical fixed
  post-upgrade pin, with `isolationDeployments` covering all checked targets.
- Supply `release_targets` as contract-name → nonempty address list for every
  `manifest_exec.NAMES` entry. Use the executing proxy/clone context for delegated
  getter surfaces. Include each relevant deployed authority context.
- Supply `token_kinds` for the union of pre-upgrade and current tokens, explicitly
  choosing `xPNTsToken` or `xPNTsTokenV2`; there is no inference from a revert.
- Pass the previously validated pre-upgrade isolation section. Legacy targets and
  tokens remain checked. Token ownership controls use each token's own `FACTORY`,
  so old tokens need not belong to the newly installed factory.
- Supply post-pin `isolationExpectedOwners` where handover changed a positive
  owner control, and any required `isolationControlCases` plus the hydrated fork.
- Run independently against both endpoints and retain/compare results before M2.5
  acceptance. The new external verifier's immutable AGGREGATOR/REGISTRY bindings
  also retain the existing manifest deployment/readback gates.

The hook explicitly selects release source, merges delegated SP/token getter
surfaces, re-runs the complete OLD audit and positive controls, and injects each
recorded forbidden return into an offline replay of that same audit. Every
negative replay must hit its specific STOP gate. These transcript substitutions
are negative checker controls, not claims of live state mutation. Actual fork
setter controls remain mandatory wherever the audit has no live positive holder.

## Remaining DSR / live-run items

1. Supply local historical dependency objects and compilers, the actual target
   deployment blocks, and exact candidate commits per target. Rebuild and obtain
   runtime parity at the chosen pin on both endpoints. Every unavailable or
   mismatched contract remains STOP pending DSR's per-contract decision.
2. Discover every clone's implementation and every relevant token/factory at the
   pin; config addresses and matching version strings are not substitutes.
3. Run canonical bounded history on both endpoints, including OLD-filtered grants
   and later revocations, and establish standard-role event controls.
4. Supply executable, authorized setter/prerequisite cases for categories with no
   live holder; run CONTROL/OLD trials on the hydrated fork. A path that cannot
   execute remains unverified, never PASS.
5. Confirm the fallback handler's Safe 1.4.1 canonical deployment attribution and
   its actual pinned slot value. Execute the real Safe guard/module controls.
6. Integrate/run the documented hook at the future M2.5 post-upgrade fixed block,
   with complete release/legacy target lists and post-handover controls.
7. DSR independently re-runs the removal probes. No commit or remote PR was made:
   this task explicitly prohibited commits and network access.

Offline suite results and the complete per-gate removal classification are in
[OLD_OWNER_ISOLATION_RESULTS.md](OLD_OWNER_ISOLATION_RESULTS.md).
