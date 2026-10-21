# A3a 逐笔预检包 v3（Sepolia，基于 `v5.5.0-rc.3`）— NOT EXECUTED

> ## 状态：NOT EXECUTED — 本包里没有任何一笔被广播到公网
> 所有交易只在**本地 anvil fork**（fork 自 Sepolia 块 **11,960,489**，2026-10-21 05:58 UTC）上执行过。
> 对真实 Sepolia 只做过**只读**调用。**执行任何一笔都需要作者对 A3a 单独 go。**
>
> ## ⚠ 有效性：只对下面两个 nonce 有效
> 本包里每一个预测地址、calldata、timelock operation id、safeTxHash 都只在
> **部署者 EOA nonce = 12131** 且 **Safe nonce = 1** 时有效。任何一个变动，**全部作废，必须重新生成**（见「复现」）。
> **逐笔中止规则**：每一笔发送 / 签名之前重新读取 nonce（部署者 `eth_getTransactionCount(pending)`、`Safe.nonce()`），不一致立即中止。
> 部署者 EOA 同时被其他自动化共用：执行窗口内必须先暂停这些自动化。

## 前置条件（执行 A3a 之前必须全部满足）

1. **作者对 A3a 单独 go**，并回答 §6 的三个问题。
2. **A2 发布总门签字**（DSR）。DSR CC-125 `aad24c8d` 判定 HOLD-CI-AND-MAIN/ATTESTATION：A2③、main 集成（PR #511）未完成（rc.3 attestation 已由 #510 合并）。DSR 明确：**不从未合入 main 的 feat/tag 直接进入 A3a**。
3. 执行前重读两个 nonce；与本包不一致则重新生成。

## 来源与生成方式

- 工具与产物：**`v5.5.0-rc.3` tag 的工作树**（peeled `57c665af`），未修改任何脚本；`APNTsCapped`、`TimelockController` 取自该树的 profile.default 产物（forge 1.7.1）。
- 生成器在 tag 树里把结果写到 `docs/release/a3a-precheck-v2/`（目录名写死在 `scripts/a3a-v2-build-packet.mjs`）；本目录是那次输出的原样拷贝，仓库里的 v2 目录保持原状。
- 快照：`RPC_A`（Alchemy 归档）与 `RPC_B`（publicnode）同块读取，**逐字段一致**（`crossCheckIdentical: true`）。
- fork 演练：`scripts/a3a-v2-fork-sim.sh <env RPC_URL> 11960489 <out> 12131 1` → **`A3a v2 FORK SIMULATION OK`**；S1–S7 读回、`DeployAPNTsCapped.verify` ALL PASS（含 #485 的 timelock 角色历史排他性检查）、全部负对照按预期 revert（`fork-sim/console.log`、`fork-sim/sim.log`）。
- `node scripts/a3a-v2-build-packet.mjs`：nonce 与 EIP-712 safeTxHash 交叉检查通过（`build-packet.log`）。
- 本目录所有文件（含 `*.log`，强制加入、不受 `.gitignore` 影响）都在 `EVIDENCE.sha256` 中，已在干净 clone 上校验 0 FAILED。

## 与 v2 包的差异

与 `../a3a-precheck-v2/a3a-precheck.json` 比较：**178 个身份字段（地址、calldata、safeTxHash、operation id、salt、nonce、to；不含时间与区块字段）中不同的为 0 个**——两个 nonce 未变（块 11,960,489 时仍为 12131 / 1），预测出的一切相同。全部叶子字段中共有 **43** 处不同，都是演练产物：时间与区块（forkBlock、t0、scheduleTs、readyAt、queueTs、eta、timelockDeployBlock、pinnedBlock、scannedTo）、fork 交易哈希、`baseFeeAtPinWei`（47 → 15）、`validity` 说明文字，以及 S3 的前置命令新增 `TIMELOCK_DEPLOYMENT_BLOCK`（#485）。v3 用 rc.3 tag 的脚本在新块上重新演练。

**cap 预算材料**（`CAP-BUDGET.md`、`cap-budget-evidence.json`）**未随 v3 重读**，仍以 `../a3a-precheck-v2/` 中的版本为准（v2 快照块 11,877,799；其中的 cachedPrice 当时已过期）。若作者需要在当前块上的 cap 预算，需要另行重算。

## 1. 固定快照（只读，块 11,960,489）

| 项 | 值 |
|---|---|
| 部署者 EOA `0xb560…df0E` | **nonce 12131**，余额 2.1619 ETH |
| Safe `0x51eD…E114` | `1.4.1`，**2-of-3**，**nonce 1**，guard = 0，余额 0.0500 ETH |
| Safe owners | `0x8716…Fb48`（nonce 28，132.7836 ETH）、`0xBB05…b75E`（nonce 0，1.0000 ETH）、`0x8c34…73D6`（nonce 7，1.0891 ETH） |
| SP 代理 `0x09DF…4DE9` | `SuperPaymaster-5.4.2`，owner = 部署者 EOA |
| `APNTS_TOKEN` | `0x696A73701b104c6cCBbAadDD2216788ea08EaB89` |
| `pendingAPNTsToken` / eta | **`0xBb46321545a91DB2F3B5c3e694F2f23aBe259883`** / 1789099908（仍挂着 → S1 仍需要） |
| 现有 timelock `0x86C8…9564` | minDelay 172800；A3a 中不触碰 |
| base fee | 15 wei |

关键身份（与 v2 相同）：新 timelock **`0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B`**；APNTsCapped **`0x9Eb17FAc022557F64924aA2F9E018dB3A330e1E7`**；accept operation id `0xa8c50665f85b1b63f98adc15dc5aab789f1ad91db7d2bc4425ecd46e0fcebc40`；salt `0xf11f070957a0e534b6d069d538b46e504303e413a6f6624a0569520761ac74f0`；S5 safeTxHash `0x65f033abab61bfd4b3dd915e34a5a5aee635c6c90c6add2d2b58d6b48c6cd2a0`；S6 safeTxHash `0x7c762ba6a524373107a5a277bfc6fb182e3ace9822daa784730abd17db7001ec`。

## 2. 逐笔交易（按顺序，与 v2 相同）

预测地址（由 nonce 决定，fork 上实测一致）：

- **新 timelock** = `keccak(rlp(部署者, 12132))` = **`0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B`**
  （注意：这恰好是 v1 包里 APNTsCapped 的预测地址——v1 当时 S1 用 12130、APNTsCapped 用 12132。别混用两包。）
- **APNTsCapped** = `keccak(rlp(部署者, 12133))` = **`0x9Eb17FAc022557F64924aA2F9E018dB3A330e1E7`**
- salt = `keccak256("APNTsCapped-1.0.0/acceptOwnership")` = `0xf11f0709…74f0`；operation id = `0xa8c50665f85b1b63f98adc15dc5aab789f1ad91db7d2bc4425ecd46e0fcebc40`

| # | 签名方 | to | 函数 | 发送方 nonce | Safe nonce | fork gas（建议 gasLimit） | 关键事件 |
|---|---|---|---|---|---|---|---|
| S1 | 部署者 EOA | SP `0x09DF…4DE9` | `cancelAPNTsTokenChange()` | **12131**→12132 | 1→1 | 31,622（41,108） | `APNTsTokenChangeCancelled(0xBb46…)` |
| S2 | 部署者 EOA | CREATE → `0xCCdF…C34B` | `TimelockController(172800, [Safe], [Safe], 0x0)` | **12132**→12133 | 1→1 | 1,378,624（1,792,211） | `RoleGranted`×4、`MinDelayChange` |
| S3 | 部署者 EOA | CREATE → `0x9Eb1…e1E7` | `APNTsCapped("AAStar PNTs","aPNTs", 10,000,000e18, 部署者, Safe, Safe)` | **12133**→12134 | 1→1 | 1,389,741（1,806,663） | `OwnershipTransferred`、`CapRaised`、`MinterSet`、`CapGuardianSet` |
| S4 | 部署者 EOA | APNTsCapped | `transferOwnership(0xCCdF…C34B)` | **12134**→12135 | 1→1 | 48,238（62,709） | `OwnershipTransferStarted` |
| S5a | Safe owner `0x8c34…73D6` | Safe | `approveHash(0x65f033ab…d2a0)` | 7→8 | **1**→1 | 52,784（68,619） | `ApproveHash` |
| S5b | Safe owner `0x8716…Fb48` | Safe | `execTransaction(timelock, 0, schedule(APNTsCapped, 0, acceptOwnership(), 0x0, salt, 172800), 0, 0,0,0, 0x0, 0x0, sigs)` | 28→29 | **1→2** | 99,143（128,885） | `SafeMultiSigTransaction`、`CallScheduled`、`CallSalt`、`ExecutionSuccess` |
| — | — | — | **等待 ≥ 48h**（readyAt = S5b 块时间 + 172800） | — | — | — | — |
| S6a | Safe owner `0x8c34…73D6` | Safe | `approveHash(0x7c762ba6…10ec)` | 8→9 | **2**→2 | 52,784（68,619） | `ApproveHash` |
| S6b | Safe owner `0x8716…Fb48` | Safe | `execTransaction(timelock, 0, execute(APNTsCapped, 0, acceptOwnership(), 0x0, salt), …, sigs)` | 29→30 | **2→3** | 90,370（117,481） | `SafeMultiSigTransaction`、`OwnershipTransferred(→timelock)`、`CallExecuted`、`ExecutionSuccess` |
| S7 | 部署者 EOA | SP | `setAPNTsToken(0x9Eb1…e1E7)` | **12135**→12136 | 3→3 | 75,929（98,707） | `APNTsTokenChangeQueued(APNTsCapped, eta)` |

建议 gasLimit = fork 实测 × 1.3。每笔的完整 calldata 与 keccak 见 `a3a-precheck.json` 的 `steps[].calldata / calldataKeccak256`；原始 tx/receipt 见 `fork-sim/<label>.tx.json / .receipt.json`。

### Safe 交易（S5 / S6）

| | S5 | S6 |
|---|---|---|
| Safe nonce | 1 | 2 |
| to / value / operation | 新 timelock / 0 / 0 (CALL) | 同左 |
| data | `fork-sim/S5-schedule.calldata` | `fork-sim/S6-execute.calldata` |
| safeTxGas / baseGas / gasPrice / gasToken / refundReceiver | 0 / 0 / 0 / 0x0 / 0x0 | 同左 |
| safeTxHash（合约 `getTransactionHash` 与离线 EIP-712 **两边独立算出且一致**） | `0x65f033abab61bfd4b3dd915e34a5a5aee635c6c90c6add2d2b58d6b48c6cd2a0` | `0x7c762ba6a524373107a5a277bfc6fb182e3ace9822daa784730abd17db7001ec` |

**签名**：fork 上走的是 Safe 合约原生的两条签名路径——owner `0x8c34…` 先链上 `approveHash(safeTxHash)`，owner `0x8716…` 作为 `msg.sender` 执行，两段 `v=1` 预验证签名**按 owner 地址升序**拼接（`0x8716… < 0x8c34…`）。真实执行也可以改用 Safe{Wallet} 的离线 EIP-712 签名（签的是同一个 safeTxHash）；那条路径在 fork 上无法演练（没有 owner 私钥），gas 会因 `ecrecover` 和签名 calldata 略有不同（每签名约 +数千 gas）。**任何路径都必须保证升序**——乱序已在负对照中确认会 `GS026`。

**Safe 包装层 gas**：S5b 99,143 vs 裸 `schedule()` 估算 55,529 → 包装开销 ≥ 43,614；S6b 90,370 vs 裸 `execute()` 51,848 → ≥ 38,522。

### timelock 角色：精确成员集合（不是点查）

OZ v5 `TimelockController` 是 `AccessControl`（不可枚举），`hasRole` 点查证明不了「没有别人」。`scripts/a3a-v2-roles.mjs` 用该合约**完整**的 `RoleGranted`/`RoleRevoked` 历史重建每个角色的成员集合：完整性是**检查过的**——部署块前一块该地址无代码，部署块之后全是本地 anvil 块；扫描结果为 4 条 `RoleGranted`、0 条 `RoleRevoked`（空扫描会直接失败）。随后对每个成员做 `hasRole == true` 正对照，对 0x0、部署者、三个 Safe owner、SP、旧 timelock 做 `hasRole == false` 负对照，并检查四个角色的 `getRoleAdmin == DEFAULT_ADMIN_ROLE`、本地计算的角色 id 等于合约 getter。

| 角色 | 精确成员集合（S2 后 = 全流程结束后） |
|---|---|
| DEFAULT_ADMIN | **[timelock 自身 `0xCCdF…C34B`]** |
| PROPOSER | **[Safe]** |
| CANCELLER | **[Safe]** |
| EXECUTOR | **[Safe]**（不开放：`hasRole(EXECUTOR, 0x0) == false`） |

当前 `DeployAPNTsCapped.run()` / `verify()` 必须同时设置 `TIMELOCK=$NEW_TL TIMELOCK_DEPLOYMENT_BLOCK=$TLBLK`。`scripts/a3a-v2-fork-sim.sh` 从 S2 部署回执的 `blockNumber` 取得 `TLBLK`，两处调用均显式传入；RPC 需提供从创建块到当前块的代码与日志历史。排他性证明以事件为基础，runtime 比对无法排除非标准构造函数的无事件角色写入；必须由本 runbook 使用默认 artifact 部署 timelock（前提说明见 [`../a3a-precheck/README.md`](../a3a-precheck/README.md)），不接受来源不明的部署。本段是当前调用要求，已有历史证据未重新生成。

证据：`fork-sim/S2-roles.json`（S2 之后）、`fork-sim/final-roles.json`（S7 之后，集合不变）。

### 每步读回（fork 上全部实测通过，失败即中止）

- **每笔之前**：发送方 nonce（S1–S4、S7 为部署者；S5/S6 为 `Safe.nonce()`）等于上表，否则中止。每笔之后：tx 自身的 nonce 等于计划值。
- **S1 后**：`pendingAPNTsToken == 0`、`pendingAPNTsTokenEta == 0`、`APNTS_TOKEN` 不变。
- **S2 后**：地址 == 预测；`getMinDelay() == 172800`；角色集合精确如上。
- **S3/S4 后**：地址 == 预测；runtime == profile.default 产物（脚本 T-4）；cap 10,000,000e18、minter == capGuardian == Safe、totalSupply 0、`APNTsCapped-1.0.0`；`owner == 部署者`、`pendingOwner == timelock`。
- **S5b 后**：`Safe.nonce() == 2`；`ExecutionSuccess`（不是 `ExecutionFailure`）；op pending，`readyAt == 块时间 + 172800`（fork：1792735115）。
- **S6b 后**：`Safe.nonce() == 3`；`owner == timelock`、`pendingOwner == 0`、`isOperationDone`；`DeployAPNTsCapped.verify` → `ALL PASS`。
- **S7 后**：`pendingAPNTsToken == APNTsCapped`、`eta == 块时间 + 604800`（fork：1793339930）、`APNTS_TOKEN` 不变；`eta − T0 = 777,626 s = 9 天 0 小时`（脚本断言 ≥ 9 天）。
- **全程结束**：部署者 nonce 12131→12136，Safe nonce 1→3。

### 负对照（全部按预期 revert，且发送方 nonce 与 Safe nonce 都不变；`fork-sim/negatives.ndjson`、`fork-sim/neg-*.err`）

| 负对照 | 何时 | 预期 revert |
|---|---|---|
| 只给 1 个签名（threshold 2） | S5 前 | `GS020` |
| 第二个 owner 未批准（`0x8716`‖`0xBB05`） | S5 前 | `GS025` |
| 非 owner 调 `approveHash` | S5 前 | `GS030` |
| 签名乱序（`0x8c34`‖`0x8716`） | S5a 后 | `GS026` |
| 签名正确但由第三个 owner 提交（`0x8716` 的 v=1 签名不再成立） | S5a 后 | `GS025` |
| 非 owner 签名（`0x8c34`‖部署者 EOA，EOA 自己提交） | S5a 后 | `GS026` |
| 部署者 EOA 直接 `schedule` | S5 后 | `AccessControlUnauthorizedAccount` (`0xe2517d3f`) |
| Safe owner 绕过 Safe 直接 `schedule` | S5 后 | `0xe2517d3f` |
| 部署者 EOA 提前 `execute` | S5 后 | `0xe2517d3f` |
| **经真实 `Safe.execTransaction`、2-of-3 有效批准，48h 前 execute** | S5 后 | 包装层 `GS013`（内层 `TimelockUnexpectedOperationState` `0x5ead8eb5`，eth_call 取得） |
| 部署者 EOA 在 48h 后 `execute` | 48h 后 | `0xe2517d3f`（executor 不开放） |
| ETA 前 `executeAPNTsTokenChange()` | S7 后 | `InvalidConfiguration` (`0xc52a9bd3`)（该函数本就属于 A3b） |

负对照为了构造「有效 2-of-3 但过早」的场景，在 fork 上让 owner `0xBB05…` 对 S6 的 safeTxHash 做过一次 `approveHash`（`fork-sim/NEG-approveHash-early-S6-by-OC.*`）。**真实执行时不要做这一步**；它不在执行步骤里。

## 3. 时间线（默认顺序，T−9d；括号内为本次 fork 演练值，见 `a3a-precheck.json` 的 `timing`）

| 时点 | 事项 |
|---|---|
| T0（2026-10-21 05:58 UTC） | 暂停共用部署者 EOA 的自动化 → S1 → S2 → S3/S4 → S5a → S5b（每笔前读 nonce） |
| S5b + 48h（readyAt 1792735115 = 2026-10-23 05:58 UTC） | S6a → S6b，读回 `owner == timelock` |
| 紧接 S6b | S7；ETA = S7 块时间 + 604800（1793339930 = 2026-10-30 05:58 UTC；ETA − T0 = 777,626 s） |
| ETA 之后（≈ T0 + 9 天） | 最早的 A3b 窗口 |

真实执行时 readyAt / ETA 以实际块时间计算，不等于上面的演练值；读回时核对的是「= 块时间 + 172800 / + 604800」的关系。

## 4. gas 与资金（20 gwei 保守估算；v3 快照 base fee 15 wei）

| 付款方 | fork 实测 gas | 20 gwei 费用 | 余额 |
|---|---|---|---|
| 部署者 EOA（S1–S4、S7） | 2,924,154 | 0.0585 ETH | 2.1619 ETH ✅ |
| owner `0x8c34…`（S5a、S6a） | 105,568 | 0.0021 ETH | 1.089 ETH ✅ |
| owner `0x8716…`（S5b、S6b） | 189,513 | 0.0038 ETH | 132.78 ETH ✅ |

## 5. 中止与恢复

| 步 | 中止条件 | 状态 | 恢复 |
|---|---|---|---|
| 任一笔之前 | nonce ≠ 本表 | 安全 | **中止，整包重新生成**（地址 / calldata / hash 全变） |
| S1 | revert 或读回不符 | 安全 | 重发（但会消耗 nonce → 之后全部重算） |
| S2 | 地址 / minDelay / 角色集合不符 | 安全，未用的 timelock 无副作用 | 重新部署并重算 S3 起的一切 |
| S3/S4 | 脚本检查失败、地址不符、`pendingOwner` 错 | 安全，总量 0；**不要**进入 S5/S7 | 重新部署；或 owner 重新 `transferOwnership` |
| S5a/S6a | Safe nonce 不符 | 安全；对过期 hash 的批准只能执行那一个 payload@那一个 nonce | 按新 nonce 重新生成后再批准 |
| S5b | 解码后 target/salt/delay 不对；`GS0xx` | 安全，未 schedule 或可撤 | Safe 以 CANCELLER `cancel(opId)` 后重排（再等 48h） |
| S6b | `GS013` / `ExecutionFailure` / owner ≠ timelock | accept 前 owner 仍是部署者，无损 | 排查后重试 |
| S7 | 排错代币 | 安全，切换不会自动执行 | `cancelAPNTsTokenChange()` 后重排（再等 7 天） |

## 6. 需要作者确认的三个问题（本包**不**替作者决定）

1. **Sepolia 的 APNTsCapped cap**：`TEST_CAP_SEPOLIA = 10,000,000e18`（脚本常量，标注为测试值；主网已定 300,000e18）。Sepolia 是否用 10,000,000e18？**未决。**
2. **单一 canonical timelock**：DSR 默认 = 是（S2 这把 Safe-only timelock 之后也是 SP / Registry / AOAProtocolRegistry / Factory 的 owner 目标）。**作者尚未确认。**
3. **顺序**：顺序执行 T−9d（默认，本包演练的）还是重叠 T−7d（S4 后立即 S7）？**未决。**

## 7. 不在本包里（A3b）

`executeAPNTsTokenChange`、operator 取出与重存、SP/Registry 升级、EntryPoint 存款与质押补足（快照：deposit 0.0935 ETH、stake 0.1 ETH）、keeper 与 `updatePrice()`。

## 复现

```bash
# 在 v5.5.0-rc.3 tag 的工作树中
forge build
RPC_A=<alchemy archive> RPC_B=https://ethereum-sepolia-rpc.publicnode.com BLOCK=11960489 node scripts/a3a-v2-snapshot.mjs > docs/release/a3a-precheck-v2/snapshot.json
scripts/a3a-v2-fork-sim.sh <env with RPC_URL> 11960489 docs/release/a3a-precheck-v2/fork-sim 12131 1 > docs/release/a3a-precheck-v2/fork-sim-console.log 2>&1   # OUT 须为仓库内相对路径
node scripts/a3a-v2-build-packet.mjs > docs/release/a3a-precheck-v2/build-packet.log 2>&1
# 拷到 a3a-precheck-v3/（fork-sim-console.log -> fork-sim/console.log）；*.log 需 git add -f。校验（干净 clone 上）：
cd docs/release/a3a-precheck-v3 && shasum -a 256 -c EVIDENCE.sha256 | grep -c FAILED   # 必须为 0
```

fork 交易哈希与时间字段依赖演练时刻，每次重跑都会变；身份字段（地址、calldata、safeTxHash、operation id）只依赖两个 nonce 与源码。RPC key 与私钥不写入本目录（已扫描：0 命中）。
