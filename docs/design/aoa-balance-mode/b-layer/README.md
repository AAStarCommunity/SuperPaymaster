# B 层（门槛 G1）证据目录

计划与判据见 [../D5-plan.md](../D5-plan.md) §3 和 §6。脚本在 `script/b-layer/`，违规样例合约在 `contracts/test/bundler/B0Violators.sol`，B4 和 B6 用的合约在 `contracts/test/bundler/BLayerAccounts.sol`。所有运行都只在本机节点上（anvil、geth `--dev`），没有任何公网广播。

## 0. bundler 与链（D-9 调整后，2026-09-13）

| 角色 | bundler | 版本锁定 | 默认 `minStake` / `minUnstakeDelay` |
|---|---|---|---|
| **主用，验收以它为准** | Rundler（alchemyplatform/rundler） | **v0.11.0，commit `2a3db23724bc995e3d7fcf7ee270fa2b759612aa`**（写本文时的最新正式版） | 1 ETH / **86400 s**（`rundler node --help`：`--min_stake_value 1000000000000000000`、`--min_unstake_delay 86400`），与 ERC-7562 的 MIN_UNSTAKE_DELAY 一致 |
| 交叉验证 | Alto（pimlicolabs/alto） | **v1.2.5，commit `45bbf3410ac3d91b38392bbe81a720fcdfef3ac5`**。最新版 v1.2.8 的 safe mode 不可用，见 §2 发现 1 | 1 ETH / **1 s**（`--min-entity-stake 1`（单位 1e18）、`--min-entity-unstake-delay 1`），与规范不一致 |

D-9 由 DSR 按作者授权调整：原定"Alto 主用、Rundler 交叉验证"，因为 Alto 最新版的 safe mode 对 EntryPoint v0.7 不可用，触发了 D-9 的兜底条款，改为 Rundler 主用。

**链的硬分叉层级：B 层统一对齐到 Osaka**，与目标链一致。依据是 2026-09-13 的实测：

| 链 | 证据 | 层级 |
|---|---|---|
| Sepolia | `eth_config`（EIP-7910，publicnode）：current fork 于 `1761607008`（2025-10-27 23:16:48 UTC）激活，blobSchedule 为 target 14 / max 21（BPO2），`next` 为空（没有已排期的下一个 fork）；`CLZ` 探针见下 | **Osaka**（Fusaka + BPO2） |
| OP 主网 | `eth_config` 不对外开放；`CLZ` 探针见下 | **≥ Osaka 等价** |
| OP Sepolia | 同上 | **≥ Osaka 等价** |

`CLZ` 探针：用 `eth_call` 加 state override 执行 `PUSH1 1; CLZ; …`（`CLZ` 是 Osaka 引入的 EIP-7939）。三条目标链都返回 `0xff`，也就是 clz(1) = 255 的正确结果。**负对照**：同一调用在 `anvil --hardfork prague` 上报 `EVM error NotActivated`，在 `anvil --hardfork osaka` 上返回 `0xff`，说明这个探针能区分两种层级。

> 更正：本目录第一版写的是"目标链在 Prague 这一级"，这是凭记忆写的，**是错的**。经上面的实测更正为 Osaka。Prague 级别的运行结果保留在矩阵里，作为额外数据点。

## 1. B0：bundler 的规则检查在所用链上是否真的在执行

**方法**：4 个故意违规的 paymaster，外加 1 个合规的对照。违规样例在 bundler 关闭 safe mode 时全部被接受并上链（`b0/b0-alto-unsafe.json`），说明它们本身是能执行的有效 op，只有规则检查才能拦住。

| 用例 | 违反的规则 |
|---|---|
| `control` | 无（不访问存储，不用禁用 opcode，context 为空） |
| `op011_timestamp` | OP-011：验证期使用 TIMESTAMP |
| `sto031_unstakedOwnStorage` | STO-031：未质押的实体写自己的存储 |
| `op070_unstakedTstore` | OP-070：未质押的实体用 TSTORE |
| `sto021_stakedExternalWrite` | STO-021/032：已质押的实体写另一个合约里与 sender 无关的槽 |

### 结果矩阵（原始响应在 `b0/*.json`）

| bundler | 链 | 对照 | 4 个违规样例 | 结论 |
|---|---|---|---|---|
| **Rundler v0.11.0** | **anvil `--hardfork osaka`**（chain 1337） | 接受并上链 | 全部被拒，均为 `-32502`：`paymaster uses banned opcode: TIMESTAMP`；`entity stake/unstake delay too low`（×2）；`paymaster accesses inaccessible storage at address … slot …` | **通过** |
| Rundler v0.11.0 | anvil `--hardfork prague`；anvil 默认 hardfork；geth 1.17.5 `--dev`（Prague） | 接受并上链 | 同上 | 通过 |
| **Alto v1.2.5** | **anvil `--hardfork osaka`**（chain 31337） | 接受并上链 | 全部被拒，均为 `-32502`：`banned opcode: TIMESTAMP`；`unstaked paymaster accessed paymaster slot 0x0`（×2）；`paymaster has forbidden read from … slot …` | **通过** |
| **Alto v1.2.5** | **geth 1.17.5 `--dev`（genesis 只开到 Osaka）** | 接受并上链 | 同上 | **通过** |
| Alto v1.2.5 | anvil `--hardfork prague`；geth（Prague） | 接受并上链 | 同上 | 通过 |
| Alto v1.2.5 | geth `--dev` 的默认 genesis（Osaka **加** `bogota`） | 接受 | TIMESTAMP 和 TSTORE 按规则被拒；两个写存储的样例在 paymaster 帧里耗尽 100k gas，报 `AA33 reverted` | 不可判定：原因是 `bogota` 这个 fork，见 §2 发现 2 |
| Alto v1.2.8 | anvil；geth | **对照也被拒** | 全部报 `Encoded error signature "0x99410554" not found on ABI` | **不可用**（上游缺陷，见 §2 发现 1） |

**判定：G1 的前置条件 B0 通过**。在 Osaka 级别的 anvil 上，两个 bundler 都能按规则拒绝全部违规样例，同时接受对照，所以 B1–B10 可以在 anvil（`--hardfork osaka`，包括 fork Sepolia）上跑，geth 作为交叉验证。

## 2. 发现

1. **Alto v1.2.6 起，EntryPoint v0.7 的 safe mode 无法工作**（上游回归，与链无关）。证据链：
   - **二分定位**：从 GitHub 取各 tag 的 `src/rpc/validation/SafeValidator.ts`，v1.2.0 到 v1.2.5 都不含 `pimlicoSimulationsAbi`，v1.2.6、v1.2.7、v1.2.8 都含（出现 3 次）。
   - **代码**：v1.2.8 的 `getValidationResultWithTracerV07` 用 `debug_traceCall` 调用 `PimlicoSimulations.simulateValidation`，取 `tracerResult.calls.slice(-1)[0]`，要求它的类型是 `REVERT`，再用 `pimlicoSimulationsAbi` 解码出 `ValidationResult`。但 `contracts/src/PimlicoSimulations.sol` 里的 `simulateValidation` 是**正常返回** `ValidationResult` 的，而 geth 风格的 JS tracer 不会为顶层帧记录 exit。所以最后一帧其实是 EntryPoint 内层 `delegateAndRevert` 的 revert。
   - **解码那一帧**：revert data 以 `0x99410554` 开头，也就是 `DelegateAndRevert(bool,bytes)`。解码得到 `success = true`，`ret` 就是 ABI 编码的 `ValidationResult`。换句话说，**模拟本身成功了，结果也在这一帧里，只是 Alto 解码错了层**，于是任何 op 都会被拒，包括合规的对照。
   - **旁证**：Alto 仓库自带的 e2e 配置（`test/e2e/alto-config.json`）和本地配置（`scripts/config.local.json`）都是 `"safe-mode": false`。
   - 要不要给 Pimlico 提上游 issue，DSR 会去问作者（那是外部仓库）。
2. **链的 fork 配置必须与目标链一致**：geth 1.17.5 `--dev` 的默认 genesis 在 0 块就启用了 Osaka 和 `bogota`（Osaka 之后的下一个 fork）。在这个配置下，验证期写存储会在 100k gas 内耗尽。只开到 Osaka 的 genesis 下同样的 op 按规则被拒（见矩阵），说明问题出在 `bogota`，而目标链都还没有这个 fork。**原因（查 geth v1.17.5 源码 `core/vm/jump_table.go`）**：`bogota` = Amsterdam 指令集 = Osaka + EIP-7843 + EIP-8024 + **EIP-8037（多维 state-gas 计量）+ EIP-8038（state 访问重新定价）**，这两条改了 SSTORE、SLOAD 和 CALL 系列的 gas，所以验证期的 SSTORE 会耗尽 100k。Amsterdam 在 Sepolia 上还没有排期（`eth_config.next` 为空）。**B 层统一用 Osaka**：anvil 加 `--hardfork osaka`；geth 用 `script/b-layer/geth-genesis.mjs` 生成 genesis 之后，删掉 `bogotaTime` 以及 blobSchedule 里多出的项。
3. **SP 的质押低于主用 bundler 的门槛**：2026-09-13 读回 `EntryPoint.getDepositInfo`，Sepolia 的 SP `0x09DF…` 和 OP 主网的 SP `0xA2c9…` 都是 stake 0.1 ETH、delay 86400。已写进 runbook 第 5b 步（03 §6）：补足到 ≥ 1 ETH，delay ≥ 86400，并加读回。B9 会实测"门槛以下被拒"。

## 3. 复现（固定的启动命令）

```
# 链（Osaka 级别）
anvil --port <p> --chain-id 1337  --hardfork osaka     # Rundler 的 dev network 要求 chain id 1337
anvil --port <p> --chain-id 31337 --hardfork osaka     # Alto
node script/b-layer/b0-setup.mjs http://127.0.0.1:<p> <setup.json>

# Rundler v0.11.0（2a3db237）
rundler node --network dev --node_http http://127.0.0.1:<p> --signer.private_keys <anvil key 3> --rpc.port <rp> --metrics.port <mp>
# Alto v1.2.5（45bbf341）
node src/lib/cli/alto.js run --entrypoints 0x0000000071727De22E5E9d8BAf0edAc6f37da032 \
  --executor-private-keys <anvil key 1> --utility-private-key <anvil key 2> --rpc-url http://127.0.0.1:<p> --port <ap> --safe-mode true

node script/b-layer/b0-send.mjs <setup.json> http://127.0.0.1:<bundler port> <label> <out.json>
```
构建方式：Rundler 用 `cargo build --release --bin rundler`，需要 forge 在 PATH 上、子模块已初始化，以及 protoc 29.3（官方 release 二进制，放在 scratchpad 里，sha256 `2b8a3403…`，没有装到系统）。Alto 用 corepack 提供的 pnpm 8.15.4 执行 `pnpm run build:contracts && pnpm run build`。geth v1.17.5 用 `go install github.com/ethereum/go-ethereum/cmd/geth@v1.17.5`（go 1.26.4）从源码构建，启动时加 `--ipcdisable`。私钥只用 anvil 公开的开发者私钥。

## 4. G1 用例 B1–B10（D5.4）

结果、trace 获取方式、§3.4 逐行对照与发现见 [B1-B10.md](B1-B10.md)，原始证据在 `cases/`。
一键复现：`script/b-layer/g1-run.sh <workDir> <rundler 目录> <alto125 目录>`，然后 `script/b-layer/g1-collect.sh <workDir>`。

## 5. 自托管 Rundler 的配置（论文实验用）与选 Rundler 作主用的补充理由（F1 之后）

**论文实验所用的自托管 Rundler v0.11.0 固定加 `--pool.same_sender_mempool_count 1`**（其余与 §3 / B1-B10.md §1 相同）。
依据是 F1 调查（[F1-investigation.md](F1-investigation.md)）：Rundler 的「二次验证」逐笔独立进行，同一 sender 的多笔 op 只在出块前一次
不带 tracer 的 `handleOps` 联合调用里才一起执行；那里 paymaster 失败（AA30/31/33/34）会让已质押的 paymaster 被按 SREP-050 封禁，
标准的 eth-infinitism `TokenPaymaster` 同样如此。把同一 sender 在内存池里的 op 数限为 1，就不会出现同一 sender 的多笔 op 进同一 bundle。

实测（`cases/f1/rundlerSSMC1-sp3-*`，B2b 同样的三笔 op）：第 1 笔接受并上链；**第 2、3 笔在提交时就被拒**，响应原文
`{"code":-32505,"message":"Max operations (1) reached for account:\"0x740Be5d5c1d56ff61a7839A212947e36Fe2d5722\" due to being unstaked"}`；
SP 信誉 `opsSeen 0x1 / opsIncluded 0x1 / status 0`（未封禁），随后别的用户经 SP 的 op 正常上链。
（注意：这个上限只对**未质押**的账户生效，`crates/pool/src/mempool/uo_pool.rs:711`；而且只保护我们自己的节点，不能约束第三方 bundler。）

**Rundler 作主用的补充理由**：Alto v1.2.5 在 safe mode 下有两处与 SP 无关的上游缺陷（证据见 [B1-B10.md](B1-B10.md) §5）：
1. **质押检查不看 `--min-entity-*`**：存储规则判断「是否已质押」用的 `isStaked` 写死为 `1 wei ≤ stake && 1 s ≤ unstakeDelay`
   （`src/rpc/validation/TracerResultParserV07.ts:66-70`）；`--min-entity-stake / --min-entity-unstake-delay` 只进信誉管理
   （`src/mempool/reputationManager.ts:307、792`），且前者按 wei 比较。结果：SP 质押 0.1 ETH、工厂质押 0.5 ETH 或 delay 3600 s 都被接受。
2. **trace 归属跨 sender 错位**：提交时把同 paymaster 的待处理 op 排在前面一起模拟（`src/store/createMemoryOutstandingStore.ts:221-251`），
   解析器却用 `callsFromEntryPoint.find(...)` 取到**第一个** op 的 `validateUserOp` 层（`TracerResultParserV07.ts:531`），把前一个 sender
   读自己存储的访问记到当前 op 头上 → `unstaked account accessed <另一个 sender> slot 0x0`。两个不同 sender 共用一个 paymaster 时必然触发。
