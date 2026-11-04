# Deployment-record source parity — 2026-11-04

DSR: deployment record first; exactly one candidate per record-based contract. Registry is evidence only. Prior attempts superseded; no alternate-commit retries. Offline rebuilds use complete recursive gitlink archives; unavailable dependencies are UNBUILDABLE.

Pinned Sepolia block: **12061284**. Runtime snapshot SHA-256: `a105ed6fb0347924d08528f674e0d65049c9e0e70253931e1d18b29491680567`.

Eight deployment-record contracts; Registry is evidence only; xPNTs clones need a DSR ruling. Four fresh commit archives, one build each, with shared results for the six DeployLive contracts. No alternate commits, RPC calls, fetches, or commits.

| Contract | Commit | Result | First masked diff (byte offset) | Metadata hash only |
|---|---|---|---|---|
| Registry | `a839347e04b40da287522c3641e12121ef2e8e9e` | needs DSR ruling: no deployment record; parity attempt: PASS | None | False |
| SuperPaymaster | `6a6d2d1785e1f03bcf72091930c6bca03f7090a8` | PASS; parity attempt: PASS | None | False |
| APNTsCapped | `5be39abf44ec01b60fda738fd732533b797fd6c7` | PASS; parity attempt: PASS | None | False |
| TimelockController | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS; parity attempt: PASS | None | False |
| GTokenStaking | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS; parity attempt: PASS | None | False |
| GToken | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS; parity attempt: PASS | None | False |
| xPNTsFactory | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS; parity attempt: PASS | None | False |
| xPNTsToken | `none` | needs DSR ruling; parity attempt: not run | None | None |
| MySBT | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS; parity attempt: PASS | None | False |
| PaymasterFactory | `cf26915e032ccc9e8e02f9aaf3769afd4335027e` | PASS; parity attempt: PASS | None | False |

PASS means full deployed-runtime equality after masking compiler-declared immutable references, with consistent repeated immutable values, including metadata. Null diff means no differing byte if PASS; comparison fields are unknown if UNBUILDABLE. JSON retains raw/masked hashes, byte lengths, immutable values/ranges, compiler metadata and settings for every completed comparison.

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

## DSR rulings and fixture

**Registry: needs DSR ruling: no deployment record.** `a839347e04b40da287522c3641e12121ef2e8e9e` comes only from M-11 §0.1’s prior runtime claim. Its result is evidence only and cannot enter the fixture.

At pin 12061284 read each clone runtime; require EIP-1167 363d3d373d3d3d363d73<20-byte implementation>5af43d82803e903d91602b57fd5bf3 (45 bytes), extract bytes [10:30], read implementation runtime at the same pin, then locate its deployment record before selecting a commit. No clone runtime or implementation deployment record supplied; do not infer source from factory/version parity.

All eight fixture entries are PASS only, with target creation boundaries from receipts. SuperPaymaster uses the proxy target from upgradeToAndCall and its original DeployLive CREATE receipt; its implementation is the verified runtime address. The collector must still authenticate the proxy slot at the pin. It is a partial source map, not evidence that the full isolation inventory is resolved.

- SuperPaymaster: Included: implementation runtime PASS; proxy target and implementation from upgrade record, proxy creation boundary from DeployLive receipt. Collector must verify pin binding.
- APNTsCapped: Included: exact runtime PASS with recorded direct CREATE boundary.
- TimelockController: Included: exact runtime PASS with recorded direct CREATE boundary.
- GTokenStaking: Included: exact runtime PASS with recorded direct CREATE boundary.
- GToken: Included: exact runtime PASS with recorded direct CREATE boundary.
- xPNTsFactory: Included: exact runtime PASS with recorded direct CREATE boundary.
- MySBT: Included: exact runtime PASS with recorded direct CREATE boundary.
- PaymasterFactory: Included: exact runtime PASS with recorded direct CREATE boundary.

GToken is the logical inventory name in the fixture; its rebuilt artifact is GTokenAuthorization, as recorded in the candidate evidence. These offline source results do not certify a successful full on-chain isolation collection.

## Validation

Old-owner suite: **26 tests, PASS (2 skipped)**. Manifest suite: **218 tests, PASS (2 skipped)**. No commit made.

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

## Proxy binding

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

