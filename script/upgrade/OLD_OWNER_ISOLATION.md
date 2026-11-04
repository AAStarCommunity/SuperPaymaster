# L-1 old-owner isolation

`manifest_exec.collect()` runs the isolation audit at `stateBlock`. `collect_pair()`
collects both endpoints, applies `independent_pin`, and retains each endpoint's
query/result transcript in `pin.oldOwnerIsolation.endpointResults`. `build_plan()`
re-extracts the inventory from the release rebuild through the single
`inventory_source(release_tree)` selection seam and replays both transcripts
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
inventory**. The earlier offline build attempt could not complete: Chainlink and Solady
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
not equal OLD. Their `xPNTsToken` fields are combined with the pinned factory's
`getAllTokens()` for authority and allowance targets; an empty xPNTs inventory
stops collection. Future CREATE targets
have no token state at this pin.

Allowance targets include APNTsCapped, old aPNTs
`0x696a73701b104c6ccbbaaddd2216788ea08eab89` (`deployments/config.sepolia.json:2`),
GToken discovered through `Registry.GTOKEN_STAKING()` → `GTokenStaking.GTOKEN()`,
and the union of operator xPNTs and `xPNTsFactory.getAllTokens()`. For each, the eight protected holders are Safe,
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
The expanded positive-control gates also have individual removal probes.
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

## H2/H3/M4 adversarial-review changes

The source choice is unchanged: `inventory_source(release_tree)` returns the
retained release tree. No deployed-source fallback is introduced. The complete
required contract set is Registry, SuperPaymaster, APNTsCapped,
TimelockController, GTokenStaking, GToken, xPNTsFactory, xPNTsToken, MySBT and
PaymasterFactory. All inherit the same AST/ABI getter and role extraction rules.

| Added target | Address discovery | Authority candidates / controls |
|---|---|---|
| GTokenStaking | pinned Registry `GTOKEN_STAKING()` | `owner`, `GTOKEN`, `REGISTRY`, `treasury`, `authorizedSlashers(OLD) == false`; owner must equal deployer |
| GToken | pinned staking `GTOKEN()` | `owner` controls minting; owner must equal deployer; forward allowances for all eight existing principals |
| xPNTsFactory | pinned SP `xpntsFactory()` | inherited owner, `SUPERPAYMASTER`, `REGISTRY`, `implementation`, `isXPNTs(OLD) == false`; owner must equal deployer |
| Every discovered xPNTsToken | union of pinned `SP.operators` for `pauseList` and factory `getAllTokens()` | inherited owner, `communityOwner`, `FACTORY`, `SUPERPAYMASTER_ADDRESS`, `emergencyRevokedAddress`, `autoApprovedSpenders`, `approvedFacilitators`; nonzero community owner must map back to this token through factory `communityToToken` |
| MySBT | pinned Registry `MYSBT()` | `GTOKEN`, `GTOKEN_STAKING`, `REGISTRY`, `daoMultisig`, `reputationCalculator`; DAO authority must equal deployer |
| PaymasterFactory | `deployments/config.sepolia.json:paymasterFactory`, frozen as `PAYMASTER_FACTORY` | inherited owner and `registry`; owner must equal deployer |

The manifest's existing operator pin supplies the touched existing xPNTs tokens.
Factory-only tokens also receive authority, authorization-mapping and allowance
checks. Future CREATE token/factory targets have no state at this pin. No block
scan is used for token discovery. Missing getters fail closed under the existing
release-source policy; the offline run does not attest to installed-runtime ABI
compatibility or actual control-holder values.

The following existing manifest checks are credited, not duplicated:
`fixed_old_aggregator`, `old_aggregator_owner` (old aggregator owner is deployer),
`pointer_owner` (DVT and committee owners are deployer), and `old_pointer` (both
point to the pinned old aggregator). They run in `manifest_exec.collect()` before
isolation collection; existing ownership-transfer/readback steps remain intact.

Registry role history uses the compiled ABI to verify the source event signature:

```text
RoleConfigured(bytes32,(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256),uint256)
```

The topic is computed with keccak, with only roleId indexed. Queries are filtered
by Registry address and that topic, bounded from `registryCreation` through
`stateBlock`, and use `a3a_exec.schedule_logs` (bounded bisection, never a
block-by-block scan). Returned logs must have the correct address/topic, two
topics, a valid role id, an in-range block, no removed flag, and a canonical
block hash. Canonical checks are cached by event block, and the state pin hash is
checked before and after history extraction. Both endpoints retain successful
queries and range-limit errors, allowing the same bisection to replay offline.

Every historical role id is retained in `configuredRoles`, even if its current
configuration is inactive. All configured role owners must differ from OLD and
`hasRole(role, OLD)` must be false. The standard source-extracted role ids must
all appear in configuration events; empty or incomplete history stops at
`old_owner_role_extraction_empty`. Registry `_initRole` does not emit this event:
a pin lacking subsequent standard-role configuration events intentionally stops,
as required, and must not be accepted as evidence of isolation.

## Verification results

Offline runs from the repository root; no commit, RPC, transaction or real fork.
The focused suite exercises 44 gate-removal probes: 24 negative authority,
role, allowance and Safe probes; 13 positive-holder probes; seven event-history
probes. Each removed gate makes its specific expected-STOP assertion red.
Additional tests cover factory-only tokens, operator/factory union, event ABI
signature verification, the source-selection seam, bounded bisection/replay,
endpoint disagreement and evidence tampering.

Final suite result lines:

```text
script/upgrade/test_manifest_exec.py: Ran 205 tests — OK (skipped=1)
script/upgrade/test_old_owner_isolation.py: Ran 13 tests — OK (skipped=1)
script/a3a/test_a3a_exec.py: Ran 102 tests — OK
script/upgrade/test_sp_upgrade_exec.py: Ran 141 tests — OK
script/upgrade/test_pop_adapter.py: Ran 53 tests — OK
script/upgrade/test_release_evidence.py: Ran 69 tests — OK
```

The skipped test is the opt-in real local fork, also imported by the manifest
suite. All offline controls passed. `git diff --check` passed. Live holder values,
installed getter compatibility and actual configured-role history remain
unverified; no live acceptance is claimed.
