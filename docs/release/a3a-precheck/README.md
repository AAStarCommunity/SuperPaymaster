# OBSOLETE SNAPSHOT — DO NOT EXECUTE

> **本包已作废，仅作历史演练记录保留。** 执行请用 [`../a3a-precheck-v2/`](../a3a-precheck-v2/README.md)。
>
> 作废原因（DSR 评审 REQUEST CHANGES，CC-122 directive v4 + audit finding #7）：
> 1. 部署者 EOA 的 nonce 在快照之后已从 12130 变为 12131，本包里 S2/S3 的 CREATE 地址、S5/S6 calldata、timelock operation id、safeTxHash **全部失效**。
> 2. S5/S6 在 fork 上直接冒充了 Safe 地址，没有经过 `Safe.execTransaction`：2-of-3 签名顺序、Safe nonce 1→2→3、包装层 revert 与 gas 都没有验证。
> 3. timelock 角色只做了 `hasRole` 点查，没有证明成员集合恰好是 ADMIN = [timelock 自身]、PROPOSER/CANCELLER/EXECUTOR = [Safe]。
> 4. §3 时间线写的「≈ T0 + 9 天」是对的，但 §3 的「并行方案 ≈ T0 + 7 天」容易被误读为默认；默认顺序是 **T−9d**。
> 5. 原 `EVIDENCE.sha256` 列了 32 个文件，其中 5 个 `fork-sim/*.log` 被 `.gitignore` 的 `*.log` 排除，fresh checkout 只能校验 27/32。
>
> 本次处理：5 个日志已从生成它们的原始工作区原样补交（逐字节与原清单哈希一致），`.gitignore` 增加了这两个目录的 `*.log` 例外；
> 因为本 README 与 `a3a-precheck.json` 加了作废标记，清单中**只有这两行**的哈希被重算，其余 30 行未改。
> 日志里的 `ONCHAIN EXECUTION COMPLETE` / `Chain 11155111` 是 forge 对本地 anvil fork（chainId 沿用 Sepolia）的固定输出，不代表上链。

---

# A3a 逐笔预检包（Sepolia）— 历史版本

> ## ✅ delivered, NOT EXECUTED — nothing in this packet has been broadcast
> 本包里的所有交易只在**本地 anvil fork**（`127.0.0.1:28591`，fork 自 Sepolia 块 11,794,003）上执行过。
> 对真实 Sepolia 只做过**只读**调用（见文末「触达公网 RPC 的命令」）。执行任何一笔都需要作者对 A3a 单独 go。

- 请求方：DSR 执行指令 v3（CC-122 `9102bef8`），repo:sp 第 2 项。
- 源码：`feat/aoa-balance-mode-5.5.0` @ `a81e659d`（`contracts/src` 与 `v5.5.0-rc.2` @ `1ac0e1c5` 一致）。A3a 用到的 `APNTsCapped` 与 `TimelockController` 取自 profile.default 产物。
- 机器可读版：`a3a-precheck.json`（逐笔完整 calldata、keccak、gas、解码后的事件、Safe payload）。原始材料：`snapshot.json`、`safe-payloads.json`、`fork-sim/`（每笔的 tx/receipt JSON、脚本日志、负对照）。校验：`EVIDENCE.sha256`。
- 复现：`scripts/a3a-snapshot.mjs`、`scripts/a3a-fork-sim.sh`、`scripts/a3a-safe-payloads.mjs`、`scripts/a3a-build-packet.mjs`。

## 范围

**A3a = 03-final-spec §6 第 1 步 ①–③**，外加 APNTsCapped 所有权交接所需的 GOV-1 timelock：取消挂着的 `0xBb46…` 切换、部署新 timelock 与 `APNTsCapped`、多签经 timelock 接收所有权、重新排队 `setAPNTsToken(APNTsCapped)`。

**明确不含 A3b**：第 1 步 ④（`executeAPNTsTokenChange`、各 operator 取款与 1:1 重存）、第 2–7c 步、SP/Registry 升级、EntryPoint 质押补足（5b）、keeper 启用。这些都不在本包里，也不会因为 A3a 的 go 而被授权。

## 1. 固定快照（只读，块 11,794,003，时间戳 1790520192）

两个独立端点（Alchemy、publicnode）在同一块读取，**结果逐字段一致**（`snapshot.json` 的 `crossCheckIdentical: true`）。

| 项 | 值 |
|---|---|
| chainId | 11155111 |
| SP 代理 `0x09DF0d2e…4DE9` | impl `0xe25f88db…2c27`，`SuperPaymaster-5.4.2`，owner = 部署者 EOA |
| `APNTS_TOKEN` | `0x696A7370…EaB89`（当前 aPNTs） |
| `pendingAPNTsToken` | **`0xBb46321545a91DB2F3B5c3e694F2f23aBe259883`**（`XPNTs-3.5.0` / aPNTs，45 字节代码 = EIP-1167 克隆） |
| `pendingAPNTsTokenEta` | 1789099908（早已到期，惰性队列，未执行） |
| `APNTS_TOKEN_TIMELOCK` | 604800（7 天） |
| `totalTrackedBalance` / `protocolRevenue` | 2934.1359 / 399.5865 aPNTs |
| `protocolFeeBPS` / `priceStalenessThreshold` | 1000 / 4200 |
| `cachedPrice.updatedAt` | 1790488836（来自 2026-09-27 那两笔提前发出的 `updatePrice`，见 CC-122 `24330e6d`；约 07:10 UTC 已再次过期——属 A3b 范围） |
| EntryPoint 押金 / 质押 | 0.0935 ETH / 0.1 ETH，unstakeDelay 86400（质押补足到 1 ETH 属 A3b 第 5b 步） |
| creditPolicy | 不适用（5.4.2 没有；这是 5.5.0 xPNTs v2 的概念） |
| operator OWNER | aPNTsBalance 1690.0087，xPNTsToken = 旧 aPNTs，未暂停 |
| operator ANNI `0xEcAACb91…33c9` | aPNTsBalance 844.5407，xPNTsToken = `0xE6579A90…A224`（Mycelium PNTs），未暂停 |
| Registry 代理 `0xf5Bf37ca…8E71` | impl `0x9bed0f58…ccee`，`Registry-5.8.0`，owner = 部署者 EOA |
| 现有 timelock `0x86C8…9564` | minDelay 172800；**部署者 EOA 持有 PROPOSER/CANCELLER/EXECUTOR/ADMIN，多签一个角色都没有** |
| 多签 `0x51eD…E114` | Safe `1.4.1`，**2-of-3**，owners `0x8716…Fb48`、`0xBB05…b75E`、`0x8c34…73D6`；Safe nonce = 1；余额 0.05 ETH |
| 部署者 EOA `0xb560…df0E` | nonce 12130，余额 2.1622 ETH |

因为现有 timelock 里多签没有任何角色，`DeployAPNTsCapped._checkTimelock` 会拒绝它（"governance multisig is not PROPOSER"）。所以 A3a 需要**新部署一把 GOV-1 形状的 timelock**（与 D5b-design.md、apnts-capped-deliverable.md L124 的设计意图一致）。

## 2. 逐笔交易（按顺序；完整字段见 `a3a-precheck.json`）

| # | 签名方 | 目标 | 动作 | fork gas | 关键事件 |
|---|---|---|---|---|---|
| S1 | 部署者 EOA（SP owner） | SP `0x09DF…` | `cancelAPNTsTokenChange()` | 31,622 | `APNTsTokenChangeCancelled(0xBb46…)` |
| S2 | 部署者 EOA | CREATE → `0x11Cc8878…5D7c`* | `TimelockController(172800, [Safe], [Safe], address(0))` | 1,378,624 | `RoleGranted`×4、`MinDelayChange` |
| S3 | 部署者 EOA | CREATE → `0xCCdF8e0D…C34B`* | `APNTsCapped("AAStar PNTs","aPNTs", 10,000,000e18, owner=部署者, minter=Safe, capGuardian=Safe)` | 1,389,741 | `OwnershipTransferred`、`CapRaised`、`MinterSet`、`CapGuardianSet` |
| S4 | 部署者 EOA | APNTsCapped | `transferOwnership(S2 timelock)` | 48,238 | `OwnershipTransferStarted` |
| S5 | **Safe 2-of-3** | S2 timelock | `schedule(APNTsCapped, 0, acceptOwnership(), 0x0, salt, 172800)` | 55,529 | `CallScheduled`、`CallSalt` |
| — | — | — | **等待 ≥ 48h** | — | — |
| S6 | **Safe 2-of-3** | S2 timelock | `execute(APNTsCapped, 0, acceptOwnership(), 0x0, salt)` | 47,048 | `OwnershipTransferred`（→ timelock）、`CallExecuted` |
| S7 | 部署者 EOA（SP owner） | SP `0x09DF…` | `setAPNTsToken(APNTsCapped)` | 75,929 | `APNTsTokenChangeQueued(APNTsCapped, eta)` |

\* 预测地址基于快照时部署者 nonce 12130/12131，实际执行时要重算（见 §6）。salt = `keccak256("APNTsCapped-1.0.0/acceptOwnership")`。

S1、S3/S4、S7 直接复用仓库脚本：`UpgradeToV5_5_0.cancelPendingAPNTs()`（`V55_APNTS_DECISION=cancel`）、`DeployAPNTsCapped.run()`（`TIMELOCK=<S2 地址>`）、`UpgradeToV5_5_0.queueAPNTs(address)`（`V55_APNTS_DECISION=queue`）。这些脚本在广播后会自行做读回断言。S2 与 D5b fork 演练 A1b 的做法一致；S5/S6 是多签交易，payload 见 `safe-payloads.json`：

| 步 | Safe to | data keccak | Safe nonce（快照时） | safeTxHash（快照时） |
|---|---|---|---|---|
| S5 | S2 timelock | 见 json | 1 | `0xcb546b75…0485` |
| S6 | S2 timelock | 见 json | 2 | `0x02102f31…b996` |

`operation = 0`（CALL），`safeTxGas = baseGas = gasPrice = 0`，`gasToken = refundReceiver = 0x0`。

### 每步读回（fork 上全部实测通过）

- **S1 后**：`pendingAPNTsToken == 0`、`pendingAPNTsTokenEta == 0`、`APNTS_TOKEN` 不变。
- **S2 后**：地址 == 预测地址；`getMinDelay() == 172800`；Safe 持有 PROPOSER/CANCELLER/EXECUTOR；部署者 EOA 没有任何角色、也没有 DEFAULT_ADMIN。
- **S3/S4 后**：runtime == profile.default 产物（脚本内 T-4 检查）；`cap == 10,000,000e18`、`minter == capGuardian == Safe`、`totalSupply == 0`、`version == APNTsCapped-1.0.0`；`owner == 部署者`、`pendingOwner == S2 timelock`。
- **S5 后**：操作 pending，`readyAt == schedule 块时间 + 172800`。
- **S6 后**：`owner == S2 timelock`、`pendingOwner == 0`；`DeployAPNTsCapped.verify(token, deployer)` → `ALL PASS`。
- **S7 后**：`pendingAPNTsToken == APNTsCapped`、`pendingAPNTsTokenEta == queue 块时间 + 604800`、`APNTS_TOKEN` 不变。

### 负对照（fork 上全部按预期 revert）

- 48h 之前 execute → `TimelockUnexpectedOperationState`（`0x5ead8eb5`）。
- 部署者 EOA 在新 timelock 上 schedule → `AccessControlUnauthorizedAccount`（`0xe2517d3f`），证明新 timelock 里 EOA 没有权限。
- ETA 之前 `executeAPNTsTokenChange()` → revert（该函数本就属于 A3b）。

## 3. 时间线模板

| 时点 | 事项 |
|---|---|
| T0 | S1 → S2 → S3 → S4（同一时段，几分钟内），随后多签发起 S5 |
| T0 + 48h（S5 块时间 + 172800 之后） | 多签执行 S6，读回 owner == timelock |
| 紧接 S6 | S7 排队；ETA = S7 块时间 + 604800 |
| **ETA 之后** | 最早的 A3b 升级窗口（≈ T0 + 9 天） |

可选的并行方案（**需作者/DSR 确认，本包默认不采用**）：S4 之后立即做 S7，让 7 天的 ETA 与 48h 的 accept 重叠，A3b 最早可提前到 ≈ T0 + 7 天。代价是：如果 S6 因 timelock 配错而无法执行，APNTsCapped 的 owner 会停留在部署者 EOA，而 SP 已经排上了这个代币。fork 演练验证的是默认顺序。

## 4. gas 与资金

| 付款方 | fork 实测 gas | 保守估算（20 gwei） | 当前余额 |
|---|---|---|---|
| 部署者 EOA（S1–S4、S7） | 2,924,154 | 0.0585 ETH | 2.1622 ETH ✅ |
| Safe 执行者（S5、S6；另加每笔约 60k 的 Safe 包装开销） | 102,577 + 120,000 | 0.0045 ETH | owners：132.78 / 1.0 / 1.089 ETH ✅ |

快照时 base fee ≈ 0.94 gwei，20 gwei 已留出约 20 倍余量。

## 5. 中止与恢复矩阵

| 步 | 何时中止 | 状态是否安全 | 恢复动作 |
|---|---|---|---|
| S1 | revert 或读回不符 | 安全，尚未改变任何东西 | 重发（幂等） |
| S2 | 地址/角色/minDelay 不符 | 安全，未使用的 timelock 无副作用 | 重新部署正确参数的 timelock |
| S3/S4 | 脚本检查失败、参数不符、`pendingOwner` 错误 | 安全，代币总量为 0，**不要**进入 S7 | 重新部署；或由 owner 重新 `transferOwnership` |
| S5 | 目标/salt/delay 不对 | 安全，操作尚未执行 | 多签以 CANCELLER 身份 `cancel(opId)` 后重新 schedule（再等 48h） |
| S6 | 执行后 owner ≠ timelock | 需排查 | timelock 配错时 accept 本就执行不了，此时 owner 仍是部署者：这是天然中止点 |
| S7 | 排错了代币 | 安全，切换不会自动执行 | `cancelAPNTsTokenChange()` 后重新排队，代价是再等 7 天 |

## 6. 真正执行时会变、必须重算的值

- 部署者 nonce（快照时 12130）→ S2/S3 的 CREATE 地址：`cast compute-address <部署者> --nonce <n>`。
- APNTsCapped 地址 → S5/S6 的 calldata、timelock 操作 id、Safe tx hash。
- Safe nonce（快照时 1）→ safeTxHash：`Safe.getTransactionHash(...)`。
- S5 块时间 → readyAt；S7 块时间 → ETA。
- Safe `execTransaction` 包装层的 gas：fork 上直接冒充了 Safe 地址，没有包含这部分，已在 §4 单列余量。
- fork 上多签是被直接冒充的，**真实执行需要 3 个 owner 中的 2 个签名**。

## 7. 需要作者确认的事项

1. **Sepolia 的 cap = 10,000,000e18**：这是 `DeployAPNTsCapped.s.sol` 里的常量 `TEST_CAP_SEPOLIA`，脚本和 spec 都标明是**测试值**（主网已决定为 300,000e18）。确认 Sepolia 就用它。
2. **新 timelock**：A3a 会部署一把新的 GOV-1 形状 48h timelock（proposer = canceller = executor = 多签，无 admin），而不是用现有的 `0x86C8…`。请确认这把新 timelock 之后也作为 M1/A5s 的 SP/Registry owner 目标，还是只服务于 APNTsCapped。现有 `0x86C8…` 在 A3a 中不被触碰（部署者 EOA 仍持有它的 admin）。
3. **顺序**：默认先 accept（S5/S6，48h）再排队（S7），与 fork 演练一致；是否改为并行（§3）由作者/DSR 定。

## 8. 与 A3b 相关、但不在本包里的提醒

- A3b 第 1 步 ④：`totalTrackedBalance` 是**整个合约**的汇总，**每个 operator**（包括持有 Mycelium PNTs 的 ANNI）都必须全部取出，切换才能执行；ANNI 的余额之后会以 APNTsCapped 1:1 重存（D5b fork 演练 A1f 的发现）。
- 第 5b 步：SP 在 EntryPoint 的质押目前是 0.1 ETH，需补足到 ≥ 1 ETH。
- 第 7c 步：价格缓存会过期，升级窗口需先 `updatePrice()` 并启用 keeper（作者 2026-09-27 决定）。

## 触达公网 RPC 的命令（全部只读）

- `scripts/a3a-snapshot.mjs`：`eth_call`、`eth_getStorageAt`、`eth_getCode`、`eth_getBalance`、`eth_getTransactionCount`、`eth_getBlockByNumber`，固定在块 11,794,003；Alchemy 与 publicnode 各一次。
- `scripts/a3a-safe-payloads.mjs`：Safe 的 `nonce()`、`getOwners()`、`getTransactionHash(...)`，各 owner 的 `eth_getBalance`，`eth_gasPrice`。
- `anvil --fork-url … --fork-block-number 11794003`：只从上游**读取**状态。
- 所有 `cast send` / `forge script --broadcast` 都只发往 `http://127.0.0.1:28591`（脚本第 12 行对非本地 RPC 直接拒绝）。
