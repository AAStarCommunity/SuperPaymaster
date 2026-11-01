# Manifest executor slice 1 — implementation report

Delivered as an uncommitted schema-3 module. No signing, public broadcasting, wallet/key-material access, contract-source edits, or protected data/evidence edits were performed.

## Files

- `script/upgrade/manifest_exec.py`: Phase A/B builder, public external-input validation and SHA-256 binding, HEAD archive rebuild, pin collection, per-sender nonces, derived CREATE addresses, exact drains, Safe batches, read-back predicates, ETA/B2/B4 gates, measured fork execution, negative controls, solvency probe, and refusal CLI.
- `script/upgrade/test_manifest_exec.py`: 32 offline unittest cases with synthetic artifacts/PoPs and fake chain state; includes full runner orchestration, waits, B2 placement, conditional B4 nonce preservation, and a failing-solvency finalization test.
- `script/upgrade/README.md`: input format, commands, limitations, timing, and solvency finding.
- `.github/workflows/a3a-executor.yml`: adds the offline manifest suite.
- This report.

## Verification

Using Python 3.11.9 and `A3A_ENGINE_DIR=$HOME/.foundry/bin`:

| Suite | Result |
| --- | --- |
| Manifest | 32 passed |
| Existing IG-08 upgrade | 141 passed |
| Existing A3a executor | 92 passed |

These are offline tests, not chain evidence. ABI encoding and keccak use local cast. The orchestrator tests mock the fork helper boundaries; the B2/B4 tests exercise their actual RPC reads against a fake chain. The existing sender/signing suite was not run.

An actual archive-at-HEAD rebuild was attempted. It stopped at `rebuild_submodule_unavailable` for `contracts/lib/chainlink-brownie-contracts`; the required initialized submodule/local object store is absent. No network fallback was attempted. No real fork was run: frozen external verifier/PoP inputs and RPC files were not supplied, and the inherited clean-tree fork gate deliberately rejects this uncommitted delivery. No release packet, successful fork result, or live execution is claimed.

## Design finding that blocks packet finalization

After the specified swap, tracked total and protocol revenue are `0.1e18`, while SP's APNTsCapped balance is zero. This violates `contracts/test/invariant/SuperPaymasterFundConservation.invariant.t.sol:91` (`invariant_solvency`). A deposit adds the same amount to tracked total and backing; a revenue withdrawal subtracts the same amount. Neither removes the shortfall.

The implemented snapshot probe records all three states in `manifest-solvency.json`. An insolvent result produces `post_swap_solvency` FAILURE before a plan/PASS result is frozen. This is a source-derived finding tested with fake chain arithmetic, not a claimed real-fork observation. The accepted A/B transactions were preserved. Resolving this requires a revised design or explicit treatment of the legacy buffer.

## Interface sources and assumptions

The following are the concrete source locations used to resolve ABI and behavior. These local interfaces were read rather than inferred from design shorthand.

| Use | Contract function/source |
| --- | --- |
| SP implementation constructor / internal extension | `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:98`; admin constructor `SuperPaymasterAdmin.sol:45` in the same directory |
| GlobalTierSource constructor | `contracts/src/tokens/v2/GlobalTierSource.sol:25` |
| AOA registry constructor / bootstrap / seal / padded SP key | `contracts/src/tokens/v2/AOAProtocolRegistry.sol:53`, `:60`, `:69`, `:107` |
| V2 extension / token / factory constructors | `contracts/src/tokens/v2/xPNTsTokenV2Ext.sol:55`; `xPNTsTokenV2.sol:41`; `xPNTsFactoryV2.sol:199` in the same directory |
| Token EIP-712 immutable values | `contracts/src/tokens/v2/xPNTsV2Base.sol:214`; `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/utils/cryptography/EIP712.sol:66` |
| Lens has no constructor arguments | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol:42` (contract declaration), `:75` (version) |
| Registry implementation / BLS pointer / reputation authorization | `contracts/src/core/Registry.sol:86`, `:288`, `:853`, `:535` |
| UUPS upgrade ABI | `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol:86` |
| Aggregator constructor / PoP / thresholds / verifier rotation | `contracts/src/modules/monitoring/BLSAggregator.sol:662`, `:767`, `:1544`, `:1564`, `:1606`, `:1625` |
| PoP point ABI uses bytes32, not uint256 | `contracts/src/utils/BLS.sol:35` (G1), `:43` (G2) |
| DVT pointer setter and proposal read-back shape | `contracts/src/modules/monitoring/DVTValidator.sol:306`, `:30` (proposal struct) |
| Operator tuple shape | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol:20` (`ISPLensView.operators`) |
| Stake and EntryPoint deposit | `singleton-paymaster/lib/account-abstraction-v7/contracts/core/BasePaymaster.sol:117`; `StakeManager.sol:63` in the same directory |
| Operator/global pauses and factory rejection | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:90`, `:106`, `:118` |
| Drain and funding | `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:199`, `:160`; `SuperPaymasterAdmin.sol:274` in the same directory |
| Gas queue/application | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:305`, `:315` |
| BLS queue/application (24 h) | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:668`, `:675` |
| Token swap / pending slash | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:200`, `:565` |
| In-flight proof relies on 5.5 being the first reservation epoch and continuously paused | `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol:41`, `:149`; `SuperPaymaster.sol:324`; `SuperPaymasterAdmin.sol:106` in the same directory |
| Solvency fixture mint authority | `contracts/src/tokens/APNTsCapped.sol:92` |

There are **two external interface assumptions that cannot be confirmed from a local contract function**:

1. Committee `setBlsAggregator(address)`, `blsAggregator()`, and `owner()`. The setter is specified by `docs/release/sp-upgrade-a6e/MANIFEST-DESIGN.md:88`; the camel-case getter is an explicit assumption. There is no committee contract source in this worktree to cite. Pin collection calls the getter, requires the expected old pointer and deployer owner, and binds runtime bytes; a different ABI stops collection.
2. DVT's `OverIssueFraudProofVerifier(address aggregator,address registry)` constructor, `AGGREGATOR()`/`REGISTRY()` getters, and named runtime immutables. Constructor order comes from `docs/release/sp-upgrade-a6e/MANIFEST-DESIGN.md:92`. The external implementation is absent here, so no contract file:line can honestly be supplied. Unknown immutable bindings stop building; wrong constructor/getter behavior stops rehearsal. The input must come from DVT's frozen reproducible build, with its commit/build/CI hashes.

No alternate selector fallback is attempted for either assumption. These must be checked against the supplied frozen sources before an accepted packet exists.

## Remaining work

Phases C/D, real signing/sending, manifest nonce-gap amendments, combined pre-S7 A3a bootstrap, source-verification execution, and a design-approved solvency resolution are not implemented. Complete release attestations, initialized build dependencies, external verifier/PoP data, and an authorized clean-tree environment are still required for a real fork rehearsal. Keystore-import requirements belong to future sending and are deliberately not probed by this slice.
