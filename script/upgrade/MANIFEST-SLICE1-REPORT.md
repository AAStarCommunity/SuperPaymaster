# Manifest executor slice 1 — round 2 report

Uncommitted delivery. No signing, public broadcasting, key-material access, sender changes, contract-source edits, or protected data/evidence edits were performed.

## Changes

- The verifier must come from `artifactPath`, with reviewed SHA-256 `4d7e0125094c381a0dca5e2d8dd56efa79b284e43119fd64130dfaa78d33e7d6`, creation keccak `0x736520628b9e5ed4163f440e4e7b5d064b4e4cb4571c29d926941964e038e3ab`, and DVT commit `72aca4fa0ba4aaa8c8a96210b1124534431294d6`. Caller-supplied bytecode/ranges are no longer an input. The pinned artifact authenticates all five immutable ranges (5519: three; 5522: two). AST names or runtime matching with both getters establish AGGREGATOR/REGISTRY order. Runtime comparison permits only those address substitutions. Both verifier getters and A7.REGISTRY are mandatory read-backs.
- CI evidence is a digest-checked public file carrying the pinned commit and PASS status. Build identity is the pinned artifact digest. Release evidence also requires actual nonempty files with matching digests; bare format-only or all-zero hashes are refused. These checks bind supplied attestations; they do not rerun CI or establish who authored an attestation.
- Registry baseline commits resolving to HEAD are refused. The baseline is independently rebuilt with immutable identities, compared against the live proxy implementation code collected at the pin, then compared against the candidate's recursive storage layout. The baseline's `__self` is substituted with the live implementation address.
- DVTValidator, committee and retired aggregator are fixed constants. Binding keys must be exactly DVT and committee, with nonempty code. `build_plan` runs external, release, nonce, sampling and binding validation itself.
- Amended A3a plan bytes are authenticated by reviewed digest. S7/S6a/S6b must be successful mined transactions at their planned nonces and no later than the pin. D must be exactly S7+1. A/E gaps require the existing A3a plain-transfer and prestate-trace proof. Receipt/transaction/gap-read evidence is retained in the pin and rechecked by the offline builder. An extra pre-pin D transaction is refused.
- B2a is a Safe approval/execution pair targeting APNTsCapped.mint(SP, 0.1e18), after 5b read-back and before 6c. All five Safe hashes are precomputed in 5a, 5b, B2a, 6c, 6d order. Its target-aware hash, payload, trace and balance read-back are explicit. B2 requires new-token backing exactly equal to 0.1e18, independently of old-token accounting.
- Rehearsal records accounting immediately after 6d, checks B4 leaves it unchanged, then probes a deposit, queued slash revenue accrual, and withdrawal of only revenue above the retained buffer. The snapshot is restored. A separate snapshot executes the activation timelock operation without B2a, records the deficit and B2 refusal, and restores state. Deterministic plan validation also refuses a removed mint.
- Round 3 supersedes the temporary B4 gate: its reserved nonce is always consumed by the hashed apply or placeholder variant. Post-state requires A12a active and both pending fields cleared; status 0 is permitted only for apply with that post-state. `a3a_send.py` is unchanged.

## Verification

| Suite | Result |
| --- | --- |
| Manifest Python | 48 passed |
| Existing IG-08 Python | 141 passed |
| Real Solidity proxy/token tests | 2 passed |
| Requested mutation checks | 4 mutations killed |

The two tests in `contracts/test/upgrade/ManifestSolvency.t.sol` use the real SuperPaymaster proxy and extension, APNTsCapped, deposit, slash and revenue-withdrawal implementations. They verify the original buffer-only withdrawal reverts with `InsufficientRevenue`, the B2a-backed route stays exactly solvent through all three stages, and the route without B2a has a 0.1-token deficit. No receipt or withdrawal success is mocked in these tests. Python tests additionally exercise the actual pre-send B2 call, both verifier getter predicates and the bound-runtime loop; runner orchestration fixtures remain synthetic and are not fork evidence.

Solidity command (in an isolated temporary tree with existing local dependency trees):

```sh
FOUNDRY_TEST=script/upgrade forge test --offline \
  --match-contract ManifestSolvencyTest --match-test test_manifest -vv
```

The initial worktree Forge attempt encountered missing submodules and attempted automatic installation; filesystem restrictions rejected its `.git` writes. It was not retried in the worktree. The successful run used a temporary archive of HEAD plus the new test and existing local dependency directories; no repository Git metadata was changed. This local contract behavior run is not a release reproducibility check.

Mutation edits were temporary, applied one at a time and restored in `finally`:

| Removed production behavior | Failing test |
| --- | --- |
| Real `b2_gate` call in `pre_send` | `test_pre_send_real_b2_is_required` |
| A12a `AGGREGATOR()` predicate | `test_a12a_getters_are_enforced` (AGGREGATOR subtest) |
| A12a `REGISTRY()` predicate | `test_a12a_getters_are_enforced` (REGISTRY subtest) |
| Entire `bindings` runtime loop | `test_pre_send_bound_runtime_is_required` |

Each mutation failed with an assertion that the expected gate was not raised, rather than an import/syntax error. No mutation is retained.

## Limits and recovery

No authenticated Sepolia fork, reviewed verifier artifact deployment, final packet, or broadcast is claimed. The reviewed external artifact and actual amended plan/PoPs/RPC files were not supplied. The uncommitted tree also retains the inherited clean-tree fork gate. The independent rebuild and full fork gates must still pass on real inputs before release.

The updated design resolves the old buffer deficit through B2a. The old-token 0.1 stays stranded in SP. After B2a but before 6d, the new-token 0.1 is held but untracked; it remains there if the route is abandoned. Phases C/D, signing/sending, source-verification execution and a nonce-gap amendment command remain absent. B4's keeper-applied case remains deliberately blocked in frozen execution pending design.

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
