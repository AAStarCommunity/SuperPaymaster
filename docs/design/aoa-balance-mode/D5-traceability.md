# D5 交付追溯

分支 `feat/aoa-balance-mode-5.5.0`。计划：[D5-plan.md](D5-plan.md)。D5 **不改** `contracts/src/`。

## 1. 门槛 G2：I8/I9/I10 的 EntryPoint 级 fuzz — `4fa67967`

文件：`contracts/test/v2/SuperPaymasterV55Fuzz.t.sol`；辅助合约 `contracts/test/helpers/V55FuzzFixtures.sol`（价格可调的 feed、按笔记录执行效果的计数器；不 import 任何 `*.t.sol`）。

**环境**：规范 EntryPoint v0.7 字节码（codehash `0x8db5ff69…`）、真实的 SP 5.5.0 代理、工厂发行的 v2 代币；2 个 operator，也就是 2 个社区，各有自己的代币，所以"每个 operator"这个粒度是真实存在的。

**随机化**：每一轮跑 2–3 个 bundle，每个 bundle 1–6 笔 op。
- sender 在 3 个账户里随机选，允许重复，每笔用一个新的 nonce key。
- 每笔的预期结果（BALANCE、CREDIT 或拒绝）由测试在当前状态上按规范模拟一遍 SP 和 token 的决策得出，再逐笔与实际的 `LockCreated` / `CreditReserved` 比对。预测会被拒的那几笔，逐笔验证 `FailedOp(k,"AA34")` 之后剔除，再重新提交。
- postOpGasLimit 取 {MIN−1, MIN, MIN+δ, 1.0–1.5M} 之一；callGas 随机；用户执行随机为成功、成功且在 bundle 中途改价、revert、OOG。
- 结算失败注入：按 `(selector ‖ user ‖ opHash)` 做 `mockCallRevert`，只让被选中的那一笔失败。
- bundle 之间随机插入：黑名单、策略切换（48h）、分档变化、operator 暂停、E-1 停用、S-4 急停、汇率变化、ETH 和 aPNTs 价格变化。

**交易边界**：`isolate = true`。在 forge 1.7.1 上实测：fuzz 模式下每个顶层调用都是一笔独立交易，TLOAD 读回 0；snapshot 和 mock 跨调用仍然有效。反证：去掉 isolate，release 立刻报 `StillLive()`。

**运行**：
| 测试 | 规模 | seed | 耗时 |
|---|---|---|---|
| `testFuzz_G2_I8_I9_I10_conservation` | 1000 runs | `0xd5c2`（关掉 dictionary，保证确定性） | 约 1.8 s |
| `test_G2_coverage_replay_fixed_seeds` | 1000 个固定种子 `keccak256("G2-coverage", i)`，逐项断言覆盖下限 | — | 约 8.2 s |
| `testFuzz_G2_noOOGBand_direct_postOp` | 1000 runs | `0xd5c3` | — |

Cancun 和 Prague 都通过（本机合并后两边各复跑一次，结果一致）。

**实际覆盖（1000 个种子）**：

| 项 | 实测 | 要求 |
|---|---|---|
| 执行的 bundle | 2221 | — |
| 计划的 op / 被拒（逐笔验证 AA34） | 8653 / 3023（其中 MIN−1 被拒 658 笔） | — |
| 已结算 BALANCE / CREDIT | 3124 / 1673 | 各 ≥ 200 |
| 注入结算失败（BALANCE / CREDIT） | 833（560 / 273） | ≥ 50 |
| 同一 sender 在一个 bundle 里多笔 | 1128 | ≥ 50 |
| postOpGasLimit == MIN 且已结算 | 1558 | ≥ 50 |
| opReverted（其中 OOG） | 1779（843） | ≥ 50 |
| **I9：没有后盾的赞助（笔数 / 金额）** | **0 / 0** | 0 |

**不补贴（DSR 补充 1）**：
- 换算：`eth = floor(floor(charge·BPS/(BPS+fee)) · 10^dec · aPriceUSD / (price·1e18))`，用验证期的价格快照，并扣掉协议费。两次向下取整，所以是用户实付的**下界**。
- 断言：已结算的 op 每笔都要满足 `eth ≥ actualGasCost`，每个 bundle 也要满足；注入失败的 op 单独断言 `G ≤ prefund` 且用户未被扣费；每个 bundle 的 SP 押金减少额 = Σ actualGasCost。
- 全程合计：EP 押金共减少 5.0577 ETH，其中已结算 op 占 4.3652 ETH，注入失败 op 占 0.6925 ETH；已结算 op 的净收费合计 7.9084 ETH。

**R1-8 保守报价多付率** `(eth − G) / G`，n = 4797：

| 范围 | 均值 | P95 | 最大值 |
|---|---|---|---|
| 全部已结算的 op | 75.9% | 251.0% | 342.4% |
| postOpGasLimit ≤ MIN + 50k（n = 3790） | 36.6% | 58.6% | 76.6% |

最小值 17.5%。多付主要来自 bufWei 按整个 postOpGasLimit 计价：limit 为 1–1.5M 的 op 会被多收 3 倍以上。这是设计上的保守报价，D3 §3 已写明 buffer 主要由 postOpGasLimit 项决定。**建议论文把两组数字分开报告**，后一组对应 SDK 按 MIN 附近估算 limit 的常见用法。

**变异**（在 src 里逐个修改，跑完用 `git checkout` 还原）：

| 变异 | 变红的断言 |
|---|---|
| (1) settle 包 try/catch 吞掉失败 | `I9: unbacked sponsorship per op == 0`；去掉这条之后，`I8: user execution effect kept => op settled` 变红 |
| (2) SETTLE_GAS_BOUND 改回 80k | `no-OOG band: a postOp that passed the SETTLE_GAS_BOUND entry check must complete`（直接调用的那个 fuzz） |
| (3) postOp 不退 a0 − c | `conservation: operator aPNTs delta == -sum(charge…)` |
| (4) releaseStaleSponsorship 不退 a0 | `I10: releaseStaleSponsorship restores the operator's in-flight a0…` |
| (5) CREDIT 分支跳过 settleCredit | `I9: unbacked sponsorship per op == 0` |

变异 (2) 在经过 EntryPoint 的测试里到不了：验证期要求 postOpGasLimit ≥ 200k，EntryPoint 给 postOp 的 gas 就是这个 limit，入口处 gasleft 远高于 160k。所以另加了直接调用 postOp 的 fuzz 来覆盖。

**全量**（合并 G2 与 D5.2 之后，Cancun）：124 个套件，1567 通过 / 0 失败 / 49 跳过。
**审查（Codex 对抗审查，第 1 轮，对 `4fa67967`）：不通过**。2 条 High、2 条 Medium、1 条 Low，都属于"测试可能放过真 bug"。修复提交为 `7fa7b705`。

### 1.1 修复后的 G2 — `7fa7b705`（**提交验收的版本**）

**Codex 第 2 轮：APPROVE**。第 1 轮的五个场景都已关闭；也没有找到"某条性质被破坏、而所有相关断言仍然通过"的单点故障路径。修法：
- **(H1) 精确的收费预言**：P 和 feePerGas 从规范 EntryPoint 发出的 postOp calldata 里取（handleOps 在 `startStateDiffRecording` 中执行），价格快照由测试在 bundle 前从 SP 的公开状态读取，并要求 context 里的字段与它相等（排除"自洽但错误的 context"）；再独立重算 aGas、charge、aCharged/debtAdded、xc，逐笔精确比对。另加一条不依赖 calldata 的界：把 aGas 按快照价折回 wei，必须落在 [G, G+bufWei] 之内。bundle 中途的价格变动放大为 ETH/USD ×0.4–×2.5（无许可的 updatePrice）、aPNTs/USD 1–5 次 ±10%（测试用的 owner 转发合约：它确实是 SP 的 owner，用户执行时正常调用它，没有 prank，也没有绕过权限）。
- **(H2) I10 逐条检查**：失败 op 留下的锁和预留跨 bundle 保留，之后在随机时点逐条释放。每释放一条都断言：本用户在该代币上的 lockedOf 或 creditReservedOf 正好减少这一条的量；其他用户、其他代币和其他未释放记录都不变；operator 余额加回 a0；重复释放没有副作用。
- **(M3)** `autoAllowance.used` 和 `userTotal.used` 逐条、逐 bundle 精确检查。
- **(M4)** 所有结算事件的数值都必须等于独立算出的 charge；某个用户在某个代币上只有一笔 op 时，按真实状态逐笔比对余额和债务；某个代币只有一笔 op 时，还比对供应量。
- **(L5)** 约 35% 的轮次里 operator 只有 0–3,000 aPNTs，偿付不足导致的拒绝逐笔断言为 AA34。

**覆盖（1000 个固定种子，2530 个 bundle）**：已结算 BALANCE 3268、CREDIT 1121（各 ≥ 200）；精确 charge 比对 4389 笔；在 bundle 中途 ETH 或 aPNTs 变价之后才执行 postOp 的已结算 op 分别为 817 和 835（各 ≥ 100）；注入结算失败 787（BALANCE）+ 879（CREDIT）；逐条释放时同一用户同一代币上还有其他未释放记录的情况 55 / 68（各 ≥ 40）；偿付不足被拒 687（≥ 50）；该用户在该代币上只有一笔的已结算 op 2842（≥ 200）；同一 sender 多笔的 bundle 1202；postOpGasLimit == MIN 且已结算 1412；opReverted 1695（其中 OOG 806）；**I9 没有后盾的赞助：0 笔 / 0 金额**。

**不补贴与多付率（更正：取代 §1 中修复前的 75.9% / 251% / 342% 与 36.6% / 58.6% / 76.6%；op 的构成变了——加入了中途变价的执行、提高了注入失败率、增加了轮次）**：每笔和每个 bundle 都满足"净收费（ETH）≥ actualGasCost"。全程 EP 押金减少 4.836 ETH，其中已结算 op 占 3.599 ETH，注入失败 op 占 1.238 ETH；已结算 op 的净收费合计 6.855 ETH。

| R1-8 多付率 `(eth−G)/G` | 均值 | P95 | 最大值 |
|---|---|---|---|
| 全部已结算的 op（n = 4389） | **83.2%** | **269.6%** | **371.1%** |
| postOpGasLimit ≤ MIN + 50k（n = 3489） | **41.8%** | **61.3%** | **81.5%** |

最小值 21.8%。

**变异（10 个，各自在指名断言上变红）**：M1–M5 同 §1；新增 M6（postOp 用实时的 cachedPrice.price）和 M7（用实时的 aPNTsPriceUSD）→ 在 `R10-M3: aGas == ceil((P + bufWei) x price_snap …) (exact)` 上变红（关掉这条精确断言之后，不依赖 calldata 的 [G, G+bufWei] 界也会变红）；M8 和 M9（release 把汇总值直接清零）→ 在 `I10: releaseStale{Lock,Credit} lowers … by exactly the record's …` 上变红；M10（释放过期锁时不退额度）→ 在 `I10/A-4: releaseStaleLock refunds a0 to the SP auto-allowance` 上变红。

**运行**：inline fuzz 1000 runs（seed `0xd5c2`）、固定种子覆盖测试（`keccak256("G2-coverage", i)`，i = 0..999）、直接调用 postOp 的 fuzz 1000 runs（seed `0xd5c3`）。本机合并后在 Cancun 和 Prague 上各跑一遍，都通过（约 23 s）。**forge 1.7.1 的一个现象**：在"用户执行先 revert、postOp 随后成功"的 op 上，state diff 的 AccountAccess `reverted` 标记也会置位，所以测试不用这个标记判断 postOp 是否成功，而是看有没有 PostOpRevertReason，并要求每笔 op 恰好调用一次 postOp。

## 2. D5.3 fork 演练：第 0 步盘点 — 本节

脚本 `script/rehearsal/inventory.mjs`（只读）。结果 `rehearsal/step0-inventory.json`。
- 数据源：`.env.sepolia` 里的归档端点（URL 不打印、不落盘）加上 publicnode 两路独立扫描，范围是 SP 代理部署块 11,151,016（归档端点上对 `eth_getCode` 二分得到）到 11,692,228。**10 类事件在两路上的集合逐条相同**（按 block:logIndex 比对）。
- 正对照：`OperatorConfigured` 找到 4 条事件，其中涉及的 2 个 operator 读回都是 `isConfigured == true`，说明事件 selector 正确，"0 条"的结果可信。publicnode 不是状态归档节点（部署块二分失败），但日志在全范围内与归档端点一致。
- 结论：
  - operator 2 个：`0xEcAA…33c9`（余额 844.54 aPNTs，xPNTs = PNTs `0xE657…`）、`0xb560…df0E`（余额 1690.01 aPNTs，它的 xPNTs 就是 aPNTs `0x696A…` 本身）；两者都未暂停。
  - `DebtRecordFailed` 0 条，所以 **pendingDebts 为空**，第 2 步没有要对账的条目。
  - `APNTsTokenChangeQueued` 2 条，没有 execute 也没有 cancel；当前 pending 是 `0xBb46…`（xPNTs 3.5.0 的 EIP-1167 克隆，"AAStar PNTs"/aPNTs，总量 2,000,000），ETA 1789099908 已过。
  - `protocolRevenue` 399.59，`totalTrackedBalance` 2934.14。
- 对第 1 步的影响：execute 分支要求所有 operator 先把余额全部取出（`totalTrackedBalance == protocolRevenue ≤ buffer`），所以它其实是一次完整的"取出 → 切换 → 用新币重新存入"迁移。已交给 D5.2 在 `UpgradeToV5_5_0` 里补全，两条分支分别在 fork 上演练、并列写出，交作者决定。**作者决定之前，第 1 步保持阻塞。**

## 3. D5.2 部署脚本迁移 — `cc23d9c0`、`407d2ead`

详见 [D5-deploy-migration.md](D5-deploy-migration.md)。

- 迁移的脚本：DeployAnvil、DeployLive、TestAccountPrepare、InitializeAAStar、InitializeTestCommunities、DeployRepCreditSepolia、L4GaslessTest、08b/11/11_1、Check08、Check09；新增 `V55Bootstrap.sol`、`UpgradeToV5_5_0.s.sol`（第 0–3 步是单独的入口；第 4 → 5 → 5b → 6 步由 `run()` 执行；7a/7c 也有入口；每一步都读回并 `require`，重复执行时复用已部署的合约）。
- **AUD-4 / R10-M5**：之前 `deploy-core` 部署的实际是 runs=200 的 `registry-size` 字节码，因为 import 了 Registry 的脚本会把整个依赖闭包带进这个 profile（SP 22,756 B，而 default 是 22,915 B）。修复后，7 个 5.5.0 合约一律按显式 artifact 路径用 `vm.deployCode` 部署 default 产物，部署后逐个断言运行时代码与 artifact 一致（屏蔽 immutable）；`deploy-core` 在 `forge script` 之前先 `forge build`。验证：全新 anvil 上部署出的 SP impl 为 22,915 B，日志显示 7 个合约全部是 `default (runs=500)`。**范围之外、仍按 registry-size 部署的旧合约**（GTokenStaking、MySBT、BLSAggregator 等）列在迁移文档 §8。
- 验收：`./deploy-core anvil --force`、`./prepare-test anvil` 以及全部 Check 都通过；一笔真实的 gasless 余额模式 op 上链，读回用户烧毁量 = operator 减少量 = revenue 增加量（78.3278）、`lockedOf` = 0；Sepolia fork 上 `run()` 严格模式通过，读回 `version()` = 5.5.0，stake 为 1 ETH / 86400。
- **第 1 步两条分支**（各用一个全新的 Sepolia fork，块 11692260，都完整走到 7c，读回全部通过；对照表见迁移文档 §9）：
  - A（execute）：operator 先取出全部余额 → revenue 转到 treasury，只留 0.1 的 buffer → 切换 → 两个 operator 按 1:1 用新 aPNTs 重新存入（1690.0087 / 844.5407）。
  - B（cancel）：什么都不动。
  - 两条分支都不改写已有的 RepCredit 证据。
- **需要作者知悉（SP 已独立核实）**：新 aPNTs `0xBb46…` 的 `communityOwner` 是 SP owner 那个 EOA `0xb560…`，现在的 aPNTs `0x696A…` 的 `communityOwner` 是另一个 EOA `0x51C0…`（链上代码长度为 0）。xPNTs 3.5.0 的 mint 没有上限，所以**无论选哪条分支，协议存款资产的增发权都在一个 EOA 上**。主网部署前应转给 Mycelium Safe。另外，选 A 之后留下的 0.1 revenue buffer 对应的是旧代币。
- 合并后全量测试：124 个套件，1567 通过 / 0 失败 / 49 跳过。
