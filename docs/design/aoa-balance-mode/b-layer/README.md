# B 层（门槛 G1）证据目录

计划与判据：[../D5-plan.md](../D5-plan.md) §3、§6。脚本：`script/b-layer/`。违规样例合约：`contracts/test/bundler/B0Violators.sol`。
所有运行都只在本机节点上（anvil、geth `--dev`），没有任何公网广播。

## B0：bundler 的规则检查在所用链上是否真的在执行（2026-09-13）

**方法**：4 个故意违规的 paymaster，外加 1 个合规的对照。违规样例在 bundler 关闭 safe mode 时全部被接受并上链（见 `b0-alto-unsafe.json`），说明它们本身是能执行的有效 op，只有规则检查才能拦住。所以 safe mode 下的拒绝确实来自规则检查，而不是 op 本身出错。

| 用例 | 违反的规则 |
|---|---|
| `control` | 无（对照：不访问存储，不用禁用 opcode，context 为空） |
| `op011_timestamp` | OP-011：验证期使用 TIMESTAMP |
| `sto031_unstakedOwnStorage` | STO-031：未质押的实体写自己的存储 |
| `op070_unstakedTstore` | OP-070：未质押的实体用 TSTORE |
| `sto021_stakedExternalWrite` | STO-021/032：已质押的实体写另一个合约里与 sender 无关的槽 |

### 结果矩阵

| bundler（版本 / commit） | 链 | 对照 | 4 个违规样例 | 结论 |
|---|---|---|---|---|
| Rundler v0.11.0（`2a3db237`） | anvil 1.7.1 默认 hardfork，chain 1337 | 接受并上链 | 全部拒绝：`-32502 paymaster uses banned opcode: TIMESTAMP`；`entity stake/unstake delay too low`（×2）；`paymaster accesses inaccessible storage at address … slot …` | **通过** |
| Rundler v0.11.0 | anvil `--hardfork prague` | 接受并上链 | 同上 | **通过** |
| Rundler v0.11.0 | geth 1.17.5 `--dev`，fork 只开到 Prague | 接受并上链 | 同上 | **通过** |
| Alto v1.2.5（`45bbf341`） | anvil `--hardfork prague`，chain 31337 | 接受并上链 | 全部拒绝：`-32502 … banned opcode: TIMESTAMP`；`unstaked paymaster accessed paymaster slot 0x0`（×2）；`paymaster has forbidden read from … slot …` | **通过** |
| Alto v1.2.5 | geth `--dev`，fork 只开到 Prague | 接受并上链 | 同上 | **通过** |
| Alto v1.2.5 | geth `--dev` 的默认 genesis（开了 Osaka 和 `bogota`） | 接受 | TIMESTAMP 和 TSTORE 按规则拒绝；**两个写存储的样例在 paymaster 帧里耗尽 100k gas，报 `AA33 reverted`** | 不可判定（原因不是规则检查，见下文第 2 点） |
| Alto v1.2.8（`37cade5d`，最新 release） | anvil；geth | **对照也被拒** | 全部报 `Encoded error signature "0x99410554" not found on ABI` | **不可用**（上游缺陷，见下文第 1 点） |

原始响应在本目录的 `b0-*.json`（每个用例都有：预期、实际结论、错误码和消息、userOpHash、是否上链）。

### 发现

1. **Alto v1.2.6 起，EntryPoint v0.7 的 safe mode 无法工作（上游缺陷，与链无关）**：`src/rpc/validation/SafeValidator.ts` 的 `getValidationResultWithTracerV07` 要求 trace 的最后一帧是 REVERT，并用 `pimlicoSimulationsAbi` 解码出 `ValidationResult`。但 `PimlicoSimulations.simulateValidation` 是**正常返回**的，而 geth 风格的 JS tracer 不会为顶层帧记录 exit，所以最后一帧其实是 EntryPoint 内层 `delegateAndRevert` 的 revert（`DelegateAndRevert(bool,bytes)`，selector `0x99410554`），解码失败，**任何 op 都会被拒，包括合规的对照**。二分定位：v1.2.5 的 SafeValidator 还没有 `pimlicoSimulationsAbi`，v1.2.6 开始有。Alto 自己的 e2e 配置是 `"safe-mode": false`，这和我们的观察一致。**因此 Alto 固定在 v1.2.5**，这是最后一个 safe mode 能用的版本。是否向上游报这个问题，由作者决定（那是外部仓库）。
2. **链的 fork 配置必须与目标链一致**：geth 1.17.5 `--dev` 的默认 genesis 在 0 块就启用了 Osaka 和 `bogota`，在这个配置下，验证期写存储会在 100k gas 内耗尽，于是 B0 的两个写存储样例报 AA33，而不是按规则被拒，这对 B0 没有判定力。目标链 Sepolia 和 OP 主网目前都在 Prague 这一级，**B 层统一用 Prague**：anvil 加 `--hardfork prague`，geth 使用去掉 osaka 和 bogota 的 genesis（`script/b-layer/geth-genesis.mjs` 生成之后再删掉这两项）。
3. **判定**：在 Prague 级别的 anvil 上，Rundler v0.11.0 和 Alto v1.2.5 都通过了 B0，所以 **B1–B10 可以直接在 anvil 上跑**（包括 fork Sepolia），不需要换到 geth；geth 上的同样结果作为交叉验证。

### 两个 bundler 的默认质押门槛（DSR 补充 2）

| bundler | `minStake` 默认值 | `minUnstakeDelay` 默认值 | 来源 |
|---|---|---|---|
| Alto v1.2.5 / v1.2.8 | 1 ETH（`--min-entity-stake 1`，单位是 1e18） | **1 秒**（`--min-entity-unstake-delay 1`） | `alto --help` |
| Rundler v0.11.0 | 1 ETH（`--min_stake_value 1000000000000000000`） | **86400 秒**（`--min_unstake_delay`） | `rundler node --help` |

两者的 unstake delay 默认值相差 86400 倍。B4 和 B9 的"门槛以下"那一格按**两者中较严格的**（1 ETH、86400 秒）来构造，并分别断言各自报出的原因码。

### 复现

```
node script/b-layer/b0-setup.mjs http://127.0.0.1:<anvil port> <setup.json>        # anvil --hardfork prague
# Alto v1.2.5：node src/lib/cli/alto.js run --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032 \
#   --executor-private-keys <anvil key 1> --utility-private-key <anvil key 2> --rpc-url <rpc> --port <p> --safe-mode true
# Rundler v0.11.0：rundler node --network dev --node_http <rpc>  (chain id 1337) --signer.private_keys <anvil key 3> --rpc.port <p>
node script/b-layer/b0-send.mjs <setup.json> http://127.0.0.1:<bundler port> <label> <out.json>
```
构建方式：Rundler 用 `cargo build --release`（需要 forge 在 PATH 上，以及 protoc 29.3，放在 scratchpad 里，没有安装到系统）；Alto 用 corepack 提供的 pnpm 8.15.4 执行 `pnpm run build:contracts && pnpm run build`；geth v1.17.5 用 `go install` 从源码构建。
