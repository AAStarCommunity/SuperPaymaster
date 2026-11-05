# Deployed-source parity — DSR rulings, 2026-11-04

**Registry adopted under DSR option (a), behavioral-equivalence only:** on-chain runtime is behaviorally equivalent to the a839347e build (immutable-masked byte-for-byte equality, solc 0.8.33).

Candidate provenance is irrelevant only when the comparison uniquely determines the property being checked. For L-1 the property is behavior: runtime exact equality suffices, with every masked immutable independently decoded and checked. Source identity requires a deployment record. Metadata remains UNMASKED; masking is limited to compiler immutable references. Current claims: APNTsCapped retains `deployment-record + runtime parity` with a validated committed plan/receipt; all other targets use `behavioral-equivalence`. Local broadcasts are not committed and therefore do not satisfy the new record-binding gate.

Offline; no network request, commit, or transaction.

Pinned Sepolia block: **12061284**, hash `0x6efc112879041305b4e48a194069fa1ac1117286a23c0d43b13474428f292787`. Original supplied snapshot SHA-256: `a105ed6fb0347924d08528f674e0d65049c9e0e70253931e1d18b29491680567`. Supplemental clone/Registry snapshot SHA-256: `0e7a170ac9022e2f40709268ef086834156c022df4daeed6c6b212b0e005d820`.

This re-ruling run freshly built all ten accepted implementations offline from archived commits and retained local dependencies. Registry used the full committed default profile; the remaining builds selected the relevant contract paths with the same committed default settings. Every comparison passed again. Fresh artifact/build-info hashes, compiler settings, commands, AST types and decoded immutable values are recorded under `reRulingBuild` and `immutableChecks` in the JSON evidence. Targeted builds can assign different AST IDs; immutable references are always resolved against their own build.

| Contract | Accepted commit | Result | Comparison type | CBOR solc | CBOR ipfs |
|---|---|---|---|---|---|
| Registry | `a839347e04b40da287522c3641e12121ef2e8e9e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| SuperPaymaster | `6a6d2d1785e1f03bcf72091930c6bca03f7090a8` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| APNTsCapped | `5be39abf44ec01b60fda738fd732533b797fd6c7` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| TimelockController | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| GTokenStaking | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| GToken | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| xPNTsFactory | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| xPNTsToken | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| MySBT | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |
| PaymasterFactory | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS | Immutable ranges only; metadata UNMASKED, byte-for-byte equal | 0.8.33 | absent |

`ipfs: null` in JSON means the CBOR map contains no `ipfs` key, not an unknown hash or a masked field. Every on-chain trailer decodes to `{solc: 0x000821}` (0.8.33), consistent with `bytecodeHash: none`. No IPFS hash exists in these trailers to report. GToken is rebuilt from **GTokenAuthorization**; the collector uses that artifact and AST under the logical GToken name.

## Registry 5.8.0 acceptance and origin

DSR accepts `a839347e04b40da287522c3641e12121ef2e8e9e` for implementation `0x9bed0f58d6001b0006923eb8c4b1cc548d42ccee`. Metadata is UNMASKED and byte-for-byte equal; only compiler immutable ranges are masked. on-chain runtime is behaviorally equivalent to the a839347e build (immutable-masked byte-for-byte equality, solc 0.8.33). Candidate provenance is irrelevant only when the comparison uniquely determines the property being checked. For L-1 the property is behavior: runtime exact equality suffices, with every masked immutable independently decoded and checked. Source identity requires a deployment record.

Deployment-origin record only, not a blocker: Etherscan v2 `getcontractcreation` → creator `0xb5600060e6de5e11d3636731964218e53caadf0e`, transaction `0x2792ea496eefac7868ce5e11e071e1613584b87bcdafaae39103d42333ab12b5`, block **11599359**. The orchestrator verified receipt `contractAddress == 0x9bed0f58d6001b0006923eb8c4b1cc548d42ccee` on both endpoints; this offline run consumes the supplied `onchain/xpnts-and-registry.json` record and makes no fresh endpoint claim.

Fixture key is the executing Registry proxy `0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71`, whose local DeployLive CREATE receipt is block **11151002**. That proxy boundary is distinct from the implementation origin above; live before/at-code checks remain mandatory.

## xPNTs five-step evidence

1. Both supplied clones have exactly 45 bytes: `363d3d373d3d3d363d73 ‖ impl ‖ 5af43d82803e903d91602b57fd5bf3`. The checker requires the exact prefix, suffix and length, then parses bytes [10:30].
2. Origin method: **CREATE address formula** `keccak(rlp([factory, nonce=1]))[12:]`. Factory `0x67422d2e44a33c8da99b3b776841bf316bd209a2` computes `0xfdfb993ddce4d95407c893e09556e31732a5beb8`, equal to both parsed implementations. The accepted factory constructor creates `new xPNTsToken()` as its first CREATE.
3. The supplied implementation runtime is **13437 bytes** and passes the fresh `cf26915e032ccc9e8e02f9aaf3769afd4335027e` xPNTsToken rebuild comparison, with seven immutable ranges masked and metadata UNMASKED and byte-for-byte equal. CBOR solc = 0.8.33; ipfs = absent. Compiler settings, runtime hashes, ranges and values are retained in JSON.
4. Both named clones are mandatory in discovery even if omitted by factory/operator lists. Every discovered clone must resolve at the pin to the same parity-verified implementation. The post-upgrade hook includes the union of legacy and current factory/operator clones, including manifest-created clones once they exist, rechecks implementation parity, and STOPs on any difference.
5. Implementation parity does not prove clone storage authority. `communityOwner`, `FACTORY`, minter-like authority/getters and boolean permissions (`autoApprovedSpenders`, `approvedFacilitators`), plus allowances, are extracted from that same parity-verified deployed build and read in each clone context at the pin with the existing positive/negative controls. Offline supplied code is not a live storage-authority certification.

| Clone | Address | Parsed implementation | Local CREATE block |
|---|---|---|---|
| aPNTs | `0x696a73701b104c6ccbbaaddd2216788ea08eab89` | `0xfdfb993ddce4d95407c893e09556e31732a5beb8` | 11151014 |
| PNTs | `0xe6579a90dc498a710008de12119812d0fb7aa224` | `0xfdfb993ddce4d95407c893e09556e31732a5beb8` | 11151051 |

Clone boundaries come from local DeployLive `additionalContracts` CREATE entries and matching transaction receipts. Runtime snapshots and local records do not replace the collector’s live before/at boundary checks.

Under this ruling, a future V2 clone pointing to a different implementation STOPs even when the caller labels its inventory `xPNTsTokenV2`. A different implementation requires a new explicit acceptance; release-source selection cannot waive this binding.

## Fixture and validation

The fixture now contains the Registry proxy, the eight previously accepted targets, and both named clones (11 executing targets, 10 logical contract types). Additional discovered targets still require their own source and creation-boundary inputs. This is accepted source evidence, not a completed live isolation run.

Negative controls cover nonstandard clone bytes, wrong implementation, wrong factory nonce-1 origin, two valid clones with different implementations, metadata differences/masking under rule 4, immutable ranges overlapping metadata, and storage authority/allowance leaks on both named clones. Gate-removal probes report whether removing a gate admits the bad input or another gate catches it.

```text
old-owner: Ran 36 tests in 4.509s — OK (skipped=2)
manifest: Ran 228 tests in 309.926s — OK (skipped=2)
a3a exec: Ran 102 tests in 3.503s — OK
a3a send (PTY): Ran 73 tests in 52.042s — OK
git diff --check: passed
```

Old-owner ran **88 gate-removal trials**: 60 accepted, 26 caught elsewhere, 2 structural-check removal crashes. Full per-gate outcomes and log paths are in [OLD_OWNER_ISOLATION_RESULTS.md](OLD_OWNER_ISOLATION_RESULTS.md). The two skips require opt-in hydrated local forks. No live isolation or fork acceptance is claimed.

## Record provenance

- **SuperPaymaster**: `broadcast/UpgradeToV5_4_2.s.sol/11155111/run-1783499317168.json`, commit field `6a6d2d17` → `6a6d2d1785e1f03bcf72091930c6bca03f7090a8`.

transactions[] swaps hashes: listed CREATE hash 0xae0399f86c25b1b4cfe95c396488feadfc11c80319862e6292c89560ecc33ec6 is upgradeToAndCall; real CREATE is 0xc73a1f1ba653a0691427e547b935c4ba35d47ba30a7d6aa3cda13741015c3fcf. Receipt contractAddress is implementation at block 11228202, verified by orchestrator on both endpoints.

- **APNTsCapped**: `docs/release/a3a-exec-ams/plan-11981108/plan.json`, commit field `5be39abf44ec01b60fda738fd732533b797fd6c7` → `5be39abf44ec01b60fda738fd732533b797fd6c7`.
- **TimelockController**: `broadcast/DeployLive.s.sol/11155111/run-1782562837353.json`, commit field `cf26915e` → `cf26915e032ccc9e8e02f9aaf3769afd4335027e`.
- **GTokenStaking**: `broadcast/DeployLive.s.sol/11155111/run-1782562837353.json`, commit field `cf26915e` → `cf26915e032ccc9e8e02f9aaf3769afd4335027e`.
- **GToken**: `broadcast/DeployLive.s.sol/11155111/run-1782562837353.json`, commit field `cf26915e` → `cf26915e032ccc9e8e02f9aaf3769afd4335027e`.
- **xPNTsFactory**: `broadcast/DeployLive.s.sol/11155111/run-1782562837353.json`, commit field `cf26915e` → `cf26915e032ccc9e8e02f9aaf3769afd4335027e`.
- **MySBT**: `broadcast/DeployLive.s.sol/11155111/run-1782562837353.json`, commit field `cf26915e` → `cf26915e032ccc9e8e02f9aaf3769afd4335027e`.
- **PaymasterFactory**: `broadcast/DeployLive.s.sol/11155111/run-1782562837353.json`, commit field `cf26915e` → `cf26915e032ccc9e8e02f9aaf3769afd4335027e`.

GToken uses the broadcast artifact **GTokenAuthorization**, not GToken. The orchestrator verified the six DeployLive CREATE receipts on both endpoints (blocks 11151003–11151057), and the corrected SuperPaymaster CREATE at block 11228202. This run uses that supplied verification; it does not claim fresh RPC verification. APNTsCapped’s prior A3a identity is supplemented by this independent rebuild and the recorded live S3 creation receipt.


## Build and dependency evidence

### `cf26915e032ccc9e8e02f9aaf3769afd4335027e`

Default profile: solc `0.8.33`, optimizer `True`, runs `500`, via IR `True`, EVM `cancun`, bytecode hash `none`.
Per-file restrictions: `[]`; additional compiler profiles: `[]`.
Compiler executed: `True`. Build error: `null`.

| Dependency | Full gitlink | URL from parent commit .gitmodules | Available object equals gitlink |
|---|---|---|---|
| contracts/lib/chainlink-brownie-contracts | `6e324d8ad9fbb5519186ad9f1eaf99704de4c915` | https://github.com/smartcontractkit/chainlink-brownie-contracts | True |
| contracts/lib/solady | `90db92ce173856605d24a554969f2c67cadbc7e9` | https://github.com/Vectorized/solady.git | True |
| standards/ercs | `c6d2d5e3ac261769cec2fb49b3e382fe2bf21e88` | https://github.com/ethereum/ERCs.git | True |
| standards/mpp-specs | `0c438bdd24b831abafc22b2a99f7562e414dcf4f` | https://github.com/tempoxyz/mpp-specs.git | True |
| standards/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2.git | True |
| standards/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402 | `b054f423400f0b972dbd9032120f172350110a59` | https://github.com/coinbase/x402.git | True |
| standards/x402/contracts/evm/lib/forge-std | `1801b0541f4fda118a10798fd3486bb7051c5dd6` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts | `fcbae5394ae8ad52d8e580a3477db99814b9d565` | https://github.com/openzeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/erc4626-tests | `232ff9ba8194e406967f52ecc5cb52ed764209e9` | https://github.com/a16z/erc4626-tests.git | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/forge-std | `3b20d60d14b343ee4f908cb8079495c07f5e8981` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/halmos-cheatcodes | `7328abe100445fc53885c21d0e713b95293cf14c` | https://github.com/a16z/halmos-cheatcodes | True |
| standards/x402/contracts/evm/lib/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2 | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |

### `6a6d2d1785e1f03bcf72091930c6bca03f7090a8`

Default profile: solc `0.8.33`, optimizer `True`, runs `500`, via IR `True`, EVM `cancun`, bytecode hash `none`.
Per-file restrictions: `[]`; additional compiler profiles: `[]`.
Compiler executed: `True`. Build error: `null`.

| Dependency | Full gitlink | URL from parent commit .gitmodules | Available object equals gitlink |
|---|---|---|---|
| contracts/lib/chainlink-brownie-contracts | `6e324d8ad9fbb5519186ad9f1eaf99704de4c915` | https://github.com/smartcontractkit/chainlink-brownie-contracts | True |
| contracts/lib/solady | `90db92ce173856605d24a554969f2c67cadbc7e9` | https://github.com/Vectorized/solady.git | True |
| standards/ercs | `c6d2d5e3ac261769cec2fb49b3e382fe2bf21e88` | https://github.com/ethereum/ERCs.git | True |
| standards/mpp-specs | `0c438bdd24b831abafc22b2a99f7562e414dcf4f` | https://github.com/tempoxyz/mpp-specs.git | True |
| standards/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2.git | True |
| standards/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402 | `b054f423400f0b972dbd9032120f172350110a59` | https://github.com/coinbase/x402.git | True |
| standards/x402/contracts/evm/lib/forge-std | `1801b0541f4fda118a10798fd3486bb7051c5dd6` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts | `fcbae5394ae8ad52d8e580a3477db99814b9d565` | https://github.com/openzeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/erc4626-tests | `232ff9ba8194e406967f52ecc5cb52ed764209e9` | https://github.com/a16z/erc4626-tests.git | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/forge-std | `3b20d60d14b343ee4f908cb8079495c07f5e8981` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/halmos-cheatcodes | `7328abe100445fc53885c21d0e713b95293cf14c` | https://github.com/a16z/halmos-cheatcodes | True |
| standards/x402/contracts/evm/lib/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2 | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |

### `5be39abf44ec01b60fda738fd732533b797fd6c7`

Default profile: solc `0.8.33`, optimizer `True`, runs `500`, via IR `True`, EVM `cancun`, bytecode hash `none`.
Per-file restrictions: `[{"paths": "contracts/src/core/Registry.sol", "max_optimizer_runs": 200}]`; additional compiler profiles: `[{"name": "registry-size", "optimizer_runs": 200, "via_ir": true}]`.
Compiler executed: `True`. Build error: `null`.

| Dependency | Full gitlink | URL from parent commit .gitmodules | Available object equals gitlink |
|---|---|---|---|
| contracts/lib/chainlink-brownie-contracts | `6e324d8ad9fbb5519186ad9f1eaf99704de4c915` | https://github.com/smartcontractkit/chainlink-brownie-contracts | True |
| contracts/lib/solady | `90db92ce173856605d24a554969f2c67cadbc7e9` | https://github.com/Vectorized/solady.git | True |
| standards/ercs | `c6d2d5e3ac261769cec2fb49b3e382fe2bf21e88` | https://github.com/ethereum/ERCs.git | True |
| standards/mpp-specs | `0c438bdd24b831abafc22b2a99f7562e414dcf4f` | https://github.com/tempoxyz/mpp-specs.git | True |
| standards/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2.git | True |
| standards/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402 | `b054f423400f0b972dbd9032120f172350110a59` | https://github.com/coinbase/x402.git | True |
| standards/x402/contracts/evm/lib/forge-std | `1801b0541f4fda118a10798fd3486bb7051c5dd6` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts | `fcbae5394ae8ad52d8e580a3477db99814b9d565` | https://github.com/openzeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/erc4626-tests | `232ff9ba8194e406967f52ecc5cb52ed764209e9` | https://github.com/a16z/erc4626-tests.git | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/forge-std | `3b20d60d14b343ee4f908cb8079495c07f5e8981` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/halmos-cheatcodes | `7328abe100445fc53885c21d0e713b95293cf14c` | https://github.com/a16z/halmos-cheatcodes | True |
| standards/x402/contracts/evm/lib/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2 | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |

### `a839347e04b40da287522c3641e12121ef2e8e9e`

Default profile: solc `0.8.33`, optimizer `True`, runs `500`, via IR `True`, EVM `cancun`, bytecode hash `none`.
Per-file restrictions: `[{"paths": "contracts/src/core/Registry.sol", "max_optimizer_runs": 200}]`; additional compiler profiles: `[{"name": "registry-size", "optimizer_runs": 200, "via_ir": true}]`.
Compiler executed: `True`. Build error: `null`.

| Dependency | Full gitlink | URL from parent commit .gitmodules | Available object equals gitlink |
|---|---|---|---|
| contracts/lib/chainlink-brownie-contracts | `6e324d8ad9fbb5519186ad9f1eaf99704de4c915` | https://github.com/smartcontractkit/chainlink-brownie-contracts | True |
| contracts/lib/solady | `90db92ce173856605d24a554969f2c67cadbc7e9` | https://github.com/Vectorized/solady.git | True |
| standards/ercs | `c6d2d5e3ac261769cec2fb49b3e382fe2bf21e88` | https://github.com/ethereum/ERCs.git | True |
| standards/mpp-specs | `0c438bdd24b831abafc22b2a99f7562e414dcf4f` | https://github.com/tempoxyz/mpp-specs.git | True |
| standards/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2.git | True |
| standards/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402 | `b054f423400f0b972dbd9032120f172350110a59` | https://github.com/coinbase/x402.git | True |
| standards/x402/contracts/evm/lib/forge-std | `1801b0541f4fda118a10798fd3486bb7051c5dd6` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts | `fcbae5394ae8ad52d8e580a3477db99814b9d565` | https://github.com/openzeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/erc4626-tests | `232ff9ba8194e406967f52ecc5cb52ed764209e9` | https://github.com/a16z/erc4626-tests.git | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/forge-std | `3b20d60d14b343ee4f908cb8079495c07f5e8981` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/openzeppelin-contracts/lib/halmos-cheatcodes | `7328abe100445fc53885c21d0e713b95293cf14c` | https://github.com/a16z/halmos-cheatcodes | True |
| standards/x402/contracts/evm/lib/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` | https://github.com/Uniswap/permit2 | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot | `3c5d52a26169876a144f7690d2f9ef0200eb0791` | https://github.com/marktoda/forge-gas-snapshot | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std | `2c7cbfc6fbede6d7c9e6b17afe997e3fdfe22fef` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-gas-snapshot/lib/forge-std/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std | `66bf4e2c92cf507531599845e8d5a08cc2e3b5bb` | https://github.com/foundry-rs/forge-std | True |
| standards/x402/contracts/evm/lib/permit2/lib/forge-std/lib/ds-test | `e282159d5170298eb2455a6c05280ab5a73a4ef0` | https://github.com/dapphub/ds-test | True |
| standards/x402/contracts/evm/lib/permit2/lib/openzeppelin-contracts | `d3ff81b37f3c773b44dcaf5fda212c7176eef0e2` | https://github.com/OpenZeppelin/openzeppelin-contracts | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate | `8d910d876f51c3b2585c9109409d601f600e68e1` | https://github.com/rari-capital/solmate | True |
| standards/x402/contracts/evm/lib/permit2/lib/solmate/lib/ds-test | `9310e879db8ba3ea6d5c6489a579118fd264a3f5` | https://github.com/dapphub/ds-test | True |


## Superseded historical attempts

**superseded: not from a deployment record** — applies to every earlier attempt below and each JSON `historicalAttempts` record. This history is not the candidate-selection basis.

# Offline deployed-source runtime parity — 2026-11-04

Base HEAD: `926a028206c38fdca4b06df3cb01d82363bc29f9`. Uncommitted; no fetch, RPC, or transaction performed.

Supplied finalized Sepolia pin: `12061284` / `0x6efc112879041305b4e48a194069fa1ac1117286a23c0d43b13474428f292787`.
Runtime file SHA-256: `a105ed6fb0347924d08528f674e0d65049c9e0e70253931e1d18b29491680567`.

Rerun after the permit2 nested objects and account-abstraction object store were repaired. **22 attempts / 10 contracts; 0 exact matches.** Candidate order is retained; compilation uses fresh `archive_commit` trees and Forge 1.7.1 offline. Repeated commits reuse the result from this run. No dependencies are omitted.

Every row below records an attempt. Compiler settings are declared settings when archival fails; they do not imply compiler execution. All profiles are `default`. `N/D` means not determined, not false or zero. Offsets are zero-based byte offsets after immutable masking. `HEAD` remains the original resolved `03f8bdeb`.

| Contract | Candidate | solc / runs / EVM / hash | Optimizer / via IR | Exact masked equality | First diff | Only CBOR hash | Result |
|---|---|---|---|---|---|---|---|
| Registry | `bb2610e8` | 0.8.33 / 200 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| Registry | `c30854f9` | 0.8.33 / 200 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| SuperPaymaster | `6a6d2d17` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| SuperPaymaster | `e1ddf9dd` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| APNTsCapped | `d2ca897e` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| APNTsCapped | `3be99c94` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| APNTsCapped | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| TimelockController | `89e1cb64` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| TimelockController | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| GTokenStaking | `8074c2b4` | 0.8.33 / 500 / cancun / ipfs (default) | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| GTokenStaking | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| GToken | `73f43561` | 0.8.28 / 1 / prague (artifact) / ipfs | True / True | false | 33 | false | STOP: old_owner_runtime_parity |
| GToken | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| xPNTsFactory | `27c08c03` | 0.8.33 / 500 / cancun / ipfs (default) | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| xPNTsFactory | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| xPNTsToken | `d8893493` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| xPNTsToken | `e1ddf9dd` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| xPNTsToken | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| MySBT | `351a8991` | 0.8.33 / 500 / cancun / ipfs (default) | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| MySBT | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |
| PaymasterFactory | `73f43561` | 0.8.28 / 1 / prague (artifact) / ipfs | True / True | false | 31 | false | STOP: old_owner_runtime_parity |
| PaymasterFactory | `03f8bdeb` | 0.8.33 / 500 / cancun / none | True / True | N/D | N/D | N/D | STOP: missing `standards/x402/contracts/evm/lib/forge-std` @ `1801b0541f4fda118a10798fd3486bb7051c5dd6` |

Registry retains the committed 200-run restriction where present. The JSON evidence includes each full committed default config, command, compiler-execution status, runtime hashes and immutable ranges. The nine supplied runtime hashes were recomputed successfully. xPNTsToken has no supplied address or runtime.

The 20 archive failures all report `rebuild_submodule_unavailable` for `standards/x402/contracts/evm/lib/forge-std` at `1801b0541f4fda118a10798fd3486bb7051c5dd6`. The remaining two attempts compiled commit `73f43561`: GToken has 2,599 rebuilt bytes versus 6,113 on-chain; PaymasterFactory has 5,144 versus 6,093. Both have non-metadata runtime differences. GToken also fails consistency across the three occurrences of its compiler-declared immutable when read at those offsets in the on-chain code; PaymasterFactory has no immutable ranges. Masking therefore cannot authenticate either runtime. Their artifact metadata reports EVM `prague` (the historical config does not explicitly select an EVM version).

## Historical proxy binding (superseded by the adversarial-review fix below)

`old_owner_isolation.deployed_inventory` already reads the target proxy’s EIP-1967 implementation slot at `pin.stateBlock`, checks `old_owner_implementation`, then authenticates that implementation’s runtime. Existing Registry/SP tests cover correct and incorrect bindings. This offline snapshot contains implementation-address zero slots, not actual proxy-slot evidence; live binding verification is not claimed.

## Exact-match input

`fixtures/old-owner/deployed-sources.json` contains `{"deployedSources": {}}` because no exact match was established. No target creation blocks or proxy/clone bindings were fabricated.

## Tests

```text
python3 script/upgrade/test_old_owner_isolation.py
Ran 26 tests in 3.409s
OK (skipped=2)

python3 script/upgrade/test_manifest_exec.py
Ran 218 tests in 287.509s
OK (skipped=2)

git diff --check: passed
```

Both suites exited 0. The skipped cases require opt-in hydrated local forks. Logs: `/private/tmp/old-owner-parity-old-owner-tests.log` and `/private/tmp/old-owner-parity-manifest-tests.log`. The compilation log is `/private/tmp/old-owner-parity-builds/73f43561fa873072b3984aaa2942c6b9f2350a66.log`; ordered attempt output is `/private/tmp/old-owner-parity-progress.log`. No live proxy-slot, history, or fork-control verification is claimed.

## Re-ruling immutable checks (2026-11-04)

All values below are decoded from the supplied runtime using fresh build immutableReferences and AST variable types. Repeated references also agree. Expected addresses come from `deployments/config.sepolia.json`; implementation/self addresses use the authenticated runtime target, factory implementation uses CREATE nonce 1, and chain ID is Sepolia (11155111). No expectation is inferred from an observed value.

| Contract | Name | AST type | Value | Expected | Result |
|---|---|---|---|---|---|
| Registry | __self | address | 0x9bed0f58d6001b0006923eb8c4b1cc548d42ccee | 0x9bed0f58d6001b0006923eb8c4b1cc548d42ccee | PASS |
| SuperPaymaster | __self | address | 0xe25f88dbeafc64200270a948df8e9dd2f9b22c27 | 0xe25f88dbeafc64200270a948df8e9dd2f9b22c27 | PASS |
| SuperPaymaster | entryPoint | contract IEntryPoint | 0x0000000071727de22e5e9d8baf0edac6f37da032 | 0x0000000071727de22e5e9d8baf0edac6f37da032 | PASS |
| SuperPaymaster | REGISTRY | contract IRegistry | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | PASS |
| SuperPaymaster | ETH_USD_PRICE_FEED | contract AggregatorV3Interface | 0x694aa1769357215de4fac081bf1f309adc325306 | 0x694aa1769357215de4fac081bf1f309adc325306 | PASS |
| APNTsCapped | _cachedDomainSeparator | bytes32 | 0x1e6b004fb025d43d7acd57b0d7a4ce494813a52358eb0c20db630bbd8826af17 | no expected value | no expected value |
| APNTsCapped | _cachedChainId | uint256 | 11155111 | 11155111 | PASS |
| APNTsCapped | _cachedThis | address | 0x9eb17fac022557f64924aa2f9e018db3a330e1e7 | 0x9eb17fac022557f64924aa2f9e018db3a330e1e7 | PASS |
| APNTsCapped | _hashedName | bytes32 | 0xb61d5c2240b92a39a4b635d085e9d59534f71f542fb712e82ce2d23f93a3682f | no expected value | no expected value |
| APNTsCapped | _hashedVersion | bytes32 | 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6 | no expected value | no expected value |
| APNTsCapped | _name | ShortString | 0x41415374617220504e547300000000000000000000000000000000000000000b | no expected value | no expected value |
| APNTsCapped | _version | ShortString | 0x3100000000000000000000000000000000000000000000000000000000000001 | no expected value | no expected value |
| TimelockController | — | — | no masked immutables | — | PASS |
| GTokenStaking | GTOKEN | contract IERC20 | 0x4c09ae57503aa1e2a43b05621a38dbdd43b0aa08 | 0x4c09ae57503aa1e2a43b05621a38dbdd43b0aa08 | PASS |
| GTokenStaking | REGISTRY | address | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | PASS |
| GToken | _cap | uint256 | 21000000000000000000000000 | no expected value | no expected value |
| GToken | _cachedDomainSeparator | bytes32 | 0xcffef6e6b0a079f053c14db119ab2ed05b0b641cee0d2f43a8fbc314222c9b4e | no expected value | no expected value |
| GToken | _cachedChainId | uint256 | 11155111 | 11155111 | PASS |
| GToken | _cachedThis | address | 0x4c09ae57503aa1e2a43b05621a38dbdd43b0aa08 | 0x4c09ae57503aa1e2a43b05621a38dbdd43b0aa08 | PASS |
| GToken | _hashedName | bytes32 | 0xd18b43fd042671ca04a7660e7c0008ccd50ca1fe48518df01fb0aea651dcd462 | no expected value | no expected value |
| GToken | _hashedVersion | bytes32 | 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6 | no expected value | no expected value |
| GToken | _name | ShortString | 0x47546f6b656e0000000000000000000000000000000000000000000000000006 | no expected value | no expected value |
| GToken | _version | ShortString | 0x3100000000000000000000000000000000000000000000000000000000000001 | no expected value | no expected value |
| GToken | factory | contract IxPNTsFactory | 0x67422d2e44a33c8da99b3b776841bf316bd209a2 | 0x67422d2e44a33c8da99b3b776841bf316bd209a2 | PASS |
| xPNTsFactory | REGISTRY | address | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | PASS |
| xPNTsFactory | implementation | address | 0xfdfb993ddce4d95407c893e09556e31732a5beb8 | 0xfdfb993ddce4d95407c893e09556e31732a5beb8 | PASS |
| xPNTsToken | _cachedDomainSeparator | bytes32 | 0xb5ac272e3557a3cc63af8e2ebc4e4f595dd6ee226f466391072fb706271db4e4 | no expected value | no expected value |
| xPNTsToken | _cachedChainId | uint256 | 11155111 | 11155111 | PASS |
| xPNTsToken | _cachedThis | address | 0xfdfb993ddce4d95407c893e09556e31732a5beb8 | 0xfdfb993ddce4d95407c893e09556e31732a5beb8 | PASS |
| xPNTsToken | _hashedName | bytes32 | 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 | no expected value | no expected value |
| xPNTsToken | _hashedVersion | bytes32 | 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6 | no expected value | no expected value |
| xPNTsToken | _name | ShortString | 0x0000000000000000000000000000000000000000000000000000000000000000 | no expected value | no expected value |
| xPNTsToken | _version | ShortString | 0x3100000000000000000000000000000000000000000000000000000000000001 | no expected value | no expected value |
| MySBT | GTOKEN | address | 0x4c09ae57503aa1e2a43b05621a38dbdd43b0aa08 | 0x4c09ae57503aa1e2a43b05621a38dbdd43b0aa08 | PASS |
| MySBT | GTOKEN_STAKING | address | 0x472297b557c1d0f030f281a5bb8a535f6c5ab65e | 0x472297b557c1d0f030f281a5bb8a535f6c5ab65e | PASS |
| MySBT | REGISTRY | address | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | 0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71 | PASS |
| PaymasterFactory | — | — | no masked immutables | — | PASS |

35 immutables total: 16 address values match expected configuration/bindings and differ from OLD; 3 chain IDs match the executor's Sepolia constant; 16 remaining values explicitly have no expected value. TimelockController and PaymasterFactory have no compiler immutable references. The EIP-712 implementation cache is checked in the implementation runtime, not in clone/proxy storage.

## Registry creation-code corroboration

The supplied direct-CREATE transaction `0x2792ea496eefac7868ce5e11e071e1613584b87bcdafaae39103d42333ab12b5`, from `0xb5600060e6de5e11d3636731964218e53caadf0e` at block **11599359**, contains **23,366 bytes**. Both-endpoint input agreement is supplied evidence, not a fresh network claim.

The a839347e source declares `constructor() Ownable(msg.sender)` and its compiled constructor ABI has no inputs. Decoded arguments: `[]`; encoded argument length: **0 bytes**. There are no address arguments to check against OLD. The inherited owner argument is `msg.sender`, the supplied creator address, which differs from OLD.

**Creation code equality: true, all 23,366 bytes.** Diff offsets/lengths: none. There is no constructor-argument or metadata difference. Both creation-code SHA-256 values are `a87e8af8ea5ae8544ec4b591a9aa6bcb44e813495ca03e4f823cec4748fa3d47`. The supplied transaction file SHA-256 is `5e5ddb86af936e52d681cfab7fb889a0e2e5ff77d9628a0cb4751049ae1f5ba7`.

This is nonblocking corroboration. Registry's accepted claim remains: on-chain runtime is behaviorally equivalent to the a839347e build (immutable-masked byte-for-byte equality, solc 0.8.33).

## Adversarial-review corrections (2026-11-04)

RoleConfigured now shares the exact bounded/bisected reader, size limit and
partition equality checks used by grant/revoke history. Each endpoint transcript
is revalidated. Dropping the custom OLD-owned config event from a full-range
page while retaining it in a partition STOPs. A saturated single-block page
STOPs rather than being accepted as complete.

Every masked address-typed immutable now requires an independent expectation;
unknown names STOP at `old_owner_immutable_expectation_missing`. Non-address
immutables retain explicit recorded values and may have no expectation.

Deployment-record claims now validate committed file bytes and SHA-256, the
record's resolved commit, and a successful receipt's transaction hash and
contract address against the source entry's implementation. APNTsCapped uses
the committed A3a plan plus S3 receipt. The local DeployLive and SP upgrade
broadcasts have no committed file in this repository; those claims are therefore
explicitly downgraded to behavioral-equivalence. Registry remains unchanged.
`fixtures/old-owner/broadcast-provenance.json` records the local file hashes and
receipt summaries. SP's real CREATE remains
`0xc73a1f1ba653a0691427e547b935c4ba35d47ba30a7d6aa3cda13741015c3fcf`;
the broadcast transactions array swaps it with the upgradeToAndCall hash.

The historical sections above describe prior runs. See
[ADVERSARIAL_REVIEW_RESULTS.md](ADVERSARIAL_REVIEW_RESULTS.md) for this run's proxy
rebuild, final suite results and gate-removal probes. No live RPC verification,
transaction, or commit was performed.

## Timelock address correction (DSR 2026-11-05)

The TimelockController parity result previously recorded here was for
`0x86c86c789edc099801cc6a5f48334f1d67dc9564`, the earlier 48h timelock.
The canonical A3a S2 timelock is `0xccdf8e0d29fb2c3061910d79484a2b653757c34b`
(block 12032424, transaction
`0xe2c6b4276e8be5ea26057499b924c2550d29ff983fccac790784d715c117d48c`,
built at `cd9aa1c410ac926a6007b0dc0b7e95b0b3effad2`).
Both runtimes are identical and both delays are 172800, so the recorded parity
values stand. Runtime parity cannot distinguish their addresses. Address binding
comes only from `discover_targets` and its `old_owner_source_targets` equality gate.
Retained parity measurements and the earlier deployment record in
`deployed_source_candidates.json` remain explicitly bound to the legacy address;
this offline correction makes no new on-chain measurement.

`old_timelock_holds_nothing` runs at the pin and at closing. It checks all four
roles on the new timelock, the isolation authority getters, role holders and
mappings, and Safe ownership/module membership, recording every call at that
phase's single block. See [reader impact](../../docs/release/sp-upgrade-a6e/OLD_TIMELOCK_CORRECTION.md).
