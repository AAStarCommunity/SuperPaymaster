# L-1 old-owner isolation

`manifest_exec.collect()` runs the isolation audit at `stateBlock`. `collect_pair()`
collects both endpoints, applies `independent_pin`, and retains each endpoint's
query/result transcript in `pin.oldOwnerIsolation.endpointResults`. `build_plan()`
re-extracts the inventory from the release rebuild and replays both transcripts
through the same gates without RPC. Removing evidence, changing its query/block,
changing its extracted inventory, or leaving unused transcript entries stops replay.
This validates the recorded predicates, not the truth of an untrusted RPC response;
the existing dual-endpoint collection and artifact binding remain required.

The extractor consumes the retained release compile's build-info, follows
`linearizedBaseContracts` and import closures, and checks getters against compiled
ABIs. It includes file-level `ROLE_*` constants as well as names ending in `ROLE`:
Registry's constants use the former convention. All public address/contract-typed
variables and public/external zero-argument address-returning view/pure functions
are included, without a name-based authority allowlist. Source locations are
UTF-8 byte offsets converted to one-based line numbers.

## Offline source inventory

These are source-visible candidates, **not an attestation of a successful compiled
inventory**. The local offline build cannot complete: Chainlink and Solady
submodules are absent. Forge's dependency auto-install attempted local submodule
setup despite `--offline`, failed on filesystem permissions before cloning, and
was not retried. No RPC, deployment, transaction, or fork was run.

Addresses: Registry `sp_upgrade_exec.REG`, SP `sp_upgrade_exec.SP`, Timelock
`sp_upgrade_exec.TL`, APNTsCapped `pin.capped` (already validated against deployer
CREATE nonce 12133). OLD and NEW are fixed in `old_owner_isolation.py`.

| Contract | Role candidates | Source |
|---|---|---|
| Registry | ROLE_COMMUNITY, ROLE_ENDUSER, ROLE_PAYMASTER_AOA, ROLE_PAYMASTER_SUPER, ROLE_DVT, ROLE_ANODE, ROLE_KMS | `contracts/src/interfaces/v3/IRegistry.sol:7–13` (file-level imports) |
| TimelockController | PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE | `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/governance/TimelockController.sol:25–27` |
| TimelockController | DEFAULT_ADMIN_ROLE | `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/access/AccessControl.sol:57` |
| SuperPaymaster | Imported Registry constants are retained in the evidence; ABI has no hasRole | Same IRegistry source |
| APNTsCapped | No hasRole ABI; explicit evidence status | Ownable2Step, not AccessControl |

Authority candidates:

- Registry: `GTOKEN_STAKING`, `MYSBT`, `SUPER_PAYMASTER`, `blsAggregator`
  (`contracts/src/core/Registry.sol:33–36`), inherited `owner()` and `pendingOwner()`.
- SP: `EXTENSION` (`SuperPaymaster.sol:37`); `REGISTRY`, `APNTS_TOKEN`,
  `xpntsFactory`, `ETH_USD_PRICE_FEED`, `treasury` (`SuperPaymasterStorage.sol:73–77`);
  `BLS_AGGREGATOR` (:89), `agentIdentityRegistry` (:111),
  `agentReputationRegistry` (:112), `pendingAPNTsToken` (:124), `pendingBLSAgg`
  (:132), `guardian` (:158); `entryPoint` (`BasePaymasterUpgradeable.sol:21`);
  inherited `owner()` and `pendingOwner()`.
  These SP files are under `contracts/src/paymasters/superpaymaster/v3/`.
- APNTsCapped: `minter`, `capGuardian` (`contracts/src/tokens/APNTsCapped.sol:37,39`),
  inherited `owner()` and `pendingOwner()`.
- Inherited `owner()`: OpenZeppelin v5.0.2 `contracts/access/Ownable.sol:56`.
  Registry/SP `pendingOwner()`: `contracts/src/utils/Ownable2StepNamespaced.sol:57`.
  APNTsCapped `pendingOwner()`: OpenZeppelin v5.0.2 `contracts/access/Ownable2Step.sol:27`.
- Timelock has no source-visible address authority getter. Empty address lists
  are retained; the authority category as a whole must be nonempty, and every
  Ownable target must have candidates.

Public address-to-bool mappings: Registry `isReputationSource`
(`Registry.sol:60`), SP `sbtHolders` (`SuperPaymasterStorage.sol:82`). Registry
`getUserRoles(OLD)` must be empty; each extracted role's `getRoleConfig` owner must
not be OLD. This Registry represents communities/operators as role members,
not a separate address-keyed community-owner mapping.

`SP.operators(OLD)` must contain nine zero words. Its first word is the operator's
credited aPNTs deposit/balance (`ISuperPaymaster.sol:21–37`); no separate operator
deposit balance exists. Other inventoried operators' treasury fields must also
not equal OLD. Their `xPNTsToken` fields determine the release's existing xPNTs
allowance targets; an empty xPNTs inventory stops collection. Future CREATE targets
have no token state at this pin.

Allowance targets include APNTsCapped, old aPNTs
`0x696a73701b104c6ccbbaaddd2216788ea08eab89` (`deployments/config.sepolia.json:2`),
and those discovered xPNTs. For each, the eight protected holders are Safe,
Timelock, SP, Registry, deployer, approver, executor, NEW. `allowance(holder, OLD)`
must be zero. `allowance(OLD, SP/Registry)` is recorded even when nonzero.

## Gates and controls

Isolation gates use `old_owner_role_*`, `old_owner_role_admin_*`,
`old_owner_authority_*`, `old_owner_mapping_*`, `old_owner_registry_user_roles`,
`old_owner_operator`, `old_owner_operator_treasury_*`, `old_owner_allowance_*`,
and `old_owner_safe_{owners,modules,guard,fallback}`. Existing Safe inventory
checks still prohibit modules and require a zero guard. Storage slot hashes are
computed from the exact Safe guard-manager and fallback-manager strings.

Positive controls require Safe's Timelock PROPOSER_ROLE, SP's deployer owner,
nonempty deployer Registry roles, a configured inventoried operator, a true
extracted mapping lookup for an inventoried holder, a nonzero allowance among
protected holders to SP/Registry, and real Safe owners. All use pinned reads.
Missing role/authority/mapping/xPNTs categories stop; no optional RPC failure is
silently treated as absence.

The offline negative-control test removes one gate at a time and verifies that
the corresponding expected-STOP assertion becomes red: role, pendingOwner,
mapping, role-config owner, operator treasury, operator balance/configuration,
Registry registration, forward allowance,
Safe owner, Safe module, guard, fallback. Reverse allowances remain record-only.
The seven positive-control gates also have individual removal probes.
Additional tests cover inheritance, file-level constants, empty extraction,
positive-control failures, endpoint disagreement, and offline evidence tampering.

The optional real-fork control is
`OldOwnerIsolationTests.test_optional_anvil_fork_role_grant`. It skips unless the
engine and `OLD_OWNER_FORK_PIN`/`OLD_OWNER_FORK_RPC` are explicitly supplied. It
requires an already hydrated localhost fork, establishes the baseline audit,
impersonates the Timelock administrator, grants OLD PROPOSER_ROLE, checks the
specific STOP gate, and restores a snapshot. It is not run by the offline suite.

## DSR decisions before live acceptance

1. Positive allowance and mapping controls deliberately STOP if no queried real
   holder has a nonzero/true value. If this occurs at the intended pin, DSR must
   identify an independently justified real control holder, or approve another
   control design; zeros must not be relabeled as positive controls.
2. The mandatory inventory comes from release source, while the pin precedes the
   SP upgrade (and Registry is pinned at 5.8.0). Any release-only getter absent in
   the installed runtime will STOP. DSR must resolve any source/runtime mismatch
   with authenticated deployment-source evidence; the implementation does not
   skip reverting getters or substitute an unverified ABI.
3. Safe positive control is real-owner membership. A positive enabled module,
   guard, or fallback holder cannot be assumed when the expected Safe has none.
   The storage reads remain mandatory, with separate mocked OLD substitutions.

## Verification results

Commands ran from the repository root. Final suite result lines:

```text
script/upgrade/test_manifest_exec.py: Ran 200 tests — OK (skipped=1)
script/a3a/test_a3a_exec.py: Ran 102 tests — OK
script/upgrade/test_sp_upgrade_exec.py: Ran 141 tests — OK
script/upgrade/test_pop_adapter.py: Ran 53 tests — OK
script/upgrade/test_release_evidence.py: Ran 69 tests — OK
script/upgrade/test_old_owner_isolation.py: Ran 9 tests — OK (skipped=1)
```

The focused isolation run additionally verifies the final mock-fork harness and
role-source deduplication changes. The skipped test in both relevant suites is
the opt-in real local fork, not an offline negative control. All 19 removal probes
passed: each removed gate made its expected-STOP assertion fail, and restoring
the gate restored the expected STOP. `git diff --check` passed. Nothing committed.

Live probe results, actual allowance values, actual xPNTs addresses at the pin,
and the complete compiled source inventory remain unknown in this offline run.
