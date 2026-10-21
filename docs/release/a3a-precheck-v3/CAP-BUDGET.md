# Sepolia APNTsCapped cap 测试预算（CC-124）— 只读，NOT EXECUTED

> **cap ≠ 已铸造量。** `cap = 10,000,000e18` 只是 `mint` 允许 totalSupply 达到的**上限**；A3a 本身铸造 **0**（S3 读回 `totalSupply == 0`，S1–S7 没有任何 mint）。
> **本文只是 Sepolia 测试预算，不是主网风险上界。** 主网是另一套推导（初始 cap 300,000e18，铸造后立即 `lowerCap(已铸量)`，见 `03-final-spec.md:631`、`:681` RDR-6 ②），本文的任何数字都不适用于主网。Sepolia aPNTs 没有价值。

## 1. cap 约束的是什么（`contracts/src/tokens/APNTsCapped.sol`，rc.2）

| 项 | 结论 | 来源 |
|---|---|---|
| 约束对象 | 只约束 `mint`：`totalSupply() + amount ≤ cap`，否则 `CapExceeded`。transfer / `transferAndCall` / 已有余额不受约束 | `APNTsCapped.sol:92–99`（检查在 `:96`） |
| burn | 持有人只能烧自己的币，烧后腾出铸造空间；SP 收的费进 `protocolRevenue`，**不烧**，所以测试消耗不会降低 totalSupply | `:102–104` |
| 谁能 mint | 只有 `minter` = 治理 Safe `0x51eD…E114`（2-of-3）；每次铸造都是一笔 Safe 交易 | `:93`；部署脚本读回 `DeployAPNTsCapped.s.sol:330` |
| decimals | 18（OZ ERC20 默认，未覆盖） | 部署脚本读回 `DeployAPNTsCapped.s.sol:328` |
| 能否改 cap | 调高：`raiseCap` 仅 owner（= GOV-1 48h timelock）；调低：`lowerCap` capGuardian（Safe）或 owner，**即时**，可低于 supply（此后 mint 全部 revert，`isOverIssued()==true`）；不可升级，`renounceOwnership` 被禁用 | `:111–116`、`:121–127`、`:142–144`、`:156–158` |
| Sepolia 取值 | `TEST_CAP_SEPOLIA = 10_000_000e18`，脚本在 11155111 上强制使用，拒绝 `APNTS_CAP` | `DeployAPNTsCapped.s.sol:78`、`:177–180` |
| 初始 supply | 0（构造不铸造；脚本里 mint 到 cap 的正对照在快照内执行后回滚） | `DeployAPNTsCapped.s.sol:332`、`:414–429` |

## 2. Sepolia 现状（固定块 11,877,799，hash `0x32bd3294…c4fb`，ts 1791554328）

两个端点（A = Alchemy，B = Tenderly 公共网关，都是归档节点；URL 不落盘）读取结果**逐字段一致**，日志 (block, tx, logIndex) 集合一致。原始数据：[`cap-budget-evidence.json`](cap-budget-evidence.json)（sha256 `ea752f79…dbe3`），脚本 `scripts/a3a-v2-cap-budget-read.py`（只读，`eth_call` / `eth_getCode` / `eth_getLogs`）。

| 项 | 值（aPNTs） | 调用 |
|---|---|---|
| 旧 aPNTs `0x696A…EaB89` totalSupply | **12,734,489.008712737068326799** | `totalSupply()` |
| SP 持有的旧 aPNTs | 2,934.1359412137 | `balanceOf(SP)` = `SP.totalTrackedBalance()` |
| OWNER `0xb560…df0E` operator 余额 | 1,690.0087127370683268 | `SP.operators(OWNER)[0]` |
| ANNI `0xEcAA…33c9` operator 余额 | 844.5407028434157946 | `SP.operators(ANNI)[0]` |
| `protocolRevenue` | 399.5865256332158786 | `SP.protocolRevenue()` |
| 对账 | OWNER + ANNI + revenue = totalTrackedBalance **精确相等** → 没有其他非零 operator | 计算 |
| 历史铸造（Transfer from=0） | **32 笔，合计 12,735,600**；最后一笔块 11,228,500（此后无铸造） | `eth_getLogs`，区间 [11,151,014, 11,877,799] |
| 历史销毁（Transfer to=0） | 9 笔，合计 1,110.991287262931673201 | 同上 |
| 扫描完整性 | 代币在 11,151,013 无代码、11,151,014 有代码（两端点二分一致）；**铸造 − 销毁 = totalSupply 精确成立**；两端点计数与 ID 一致 | 计算 |
| 历史每笔实扣 | OWNER `totalSpent` 1,174.61 / 6 笔，ANNI 587.31 / 3 笔 → **195.77 / 笔**（5.4.2 记账，仅作参照） | `operators(...)[7]`、`[8]` |
| `cachedPrice` | ETH/USD 2,704.2805（8 位），updatedAt 1790488836（**已过期 12.3 天**；7c 会先 `updatePrice`） | `SP.cachedPrice()` |
| `aPNTsPriceUSD` / `protocolFeeBPS` | 0.02 USD / 1000 | getter |

注意：旧代币总量 12.73M **大于** 新 cap 10M（其中 10,000,000 在 EOA `0x42ba…3e22`）。这不矛盾：runbook 只按 1:1 重新铸造 **SP 内的 operator 余额**（`03-final-spec.md:371` 第 1 步 ④），不迁移旧代币持有人。

## 3. 预算表

记号：E = 1e18。参数 n = 50、B_max = 3、m = 0.2 取自 DSR CC-124 指令（仓库里 collector 的 `--count` / `--b-max` 是占位，由 DSR 定，`script/a6-collector/collector.mjs:6–8`）。

| # | 项 | 值（aPNTs） | 来源 | 算式 |
|---|---|---|---|---|
| 1 | cap | 10,000,000 | `DeployAPNTsCapped.s.sol:78` | — |
| 2 | 每笔 gas limit 之和 | 1,060,000 gas | `collector.mjs:73–77` | 100k call + 300k verif + 60k PVG + 400k pmVerif + 200k pmPostOp |
| 3 | maxFeePerGas 上限 | 20 gwei | `collector.mjs:74–75` | — |
| 4 | a_gas（每笔预留，未加费） | 2,866.53733 | `03-final-spec.md:562`；`SuperPaymaster.sol:214–224` | 1,060,000 × 20e9 × 2704.2805 / 0.02 / 1e18 |
| 5 | a0（每笔预留） | 3,439.844796 | `03-final-spec.md:563`；`SuperPaymaster.sol:309–310`；`SuperPaymasterStorage.sol:209` | #4 × (1 + 0.10 费 + 0.10 缓冲) |
| 6 | d′ = 每笔最坏净扣（含价格余量） | 4,127.8137552 | 结算 `c ≤ a0`（`03-final-spec.md:565`） | #5 × (1 + m)，m = 0.2；**假设每笔都被扣满 a0** |
| 7 | L = 在途预留底线（必须持有、不消耗） | 12,383.4412656 | 验证期要求余额 ≥ a0（`SuperPaymaster.sol:313`）；同 `deposit-guard.mjs:24–25` 的 B_max 形式 | B_max × d′ = 3 × #6 |
| 8 | M0 = 1:1 重新铸造（迁移） | 2,934.1359412137 | 第 2 节读回；`03-final-spec.md:371` | operator 余额 2,534.5494 + revenue 399.5865（revenue 按规范是取出而非重存，这里**保守计入**） |
| 9 | 计划 SP op 数 N | 500 | 见下 | A4：7c 每社区 1 笔 ×2 + B 层复跑 11 例（B1–B10 + B2b，`b-layer/B1-B10.md`）+ collector n = 50 → 63；×2 失败/重试余量 → 126。RepCredit R3–R5（CC-122，仓库未给笔数）预留 3 窗 × 50 × 2 = 300。合计 426，取整 500 |
| 10 | U = 预计测试消耗（最坏） | 2,063,906.8776 | — | N × d′ = 500 × #6 |
| 11 | **累计铸造（最坏）** | 2,079,224.4548 | — | M0 + L + U |
| 12 | **余量 headroom** | **7,920,775.5452（cap 的 79.2%）** | — | cap − #11 |
| 13 | 最坏情况下 cap 可承载的 op 数 | 2,418 | — | ⌊(cap − M0 − L) / d′⌋ |
| 14 | 按历史实扣的预计消耗（参照） | ≈ 97,885 | 第 2 节 195.77 / 笔 | 500 × 195.77；此口径下 cap 可承载 ≈ 42,500 笔（含 m） |

**建议的初始铸造（仓库文档没有规定测试铸造量，只规定了 1:1 重存）**：A3b 第 1 步 ④ 一次铸造 I = M0（P1 快照实测值）+ T_A4，T_A4 = L + 126 × d′ = 532,487.97 → **取 535,000**；按今天的 M0，I ≈ **537,934.14**，铸后剩余可铸空间 ≈ 9,462,065.86。之后的 RepCredit 窗口按需由 Safe 追加铸造（都计入第 11 行，已在余量内）。一次铸够 A4 的好处是 A4 期间不需要额外的 Safe 2-of-3 铸币交易。

## 4. 假设与失效条件

- **最坏口径**：第 6 行假设每笔 op 都按 a0 扣满；实际 `c = min(a0, 实际成本 × 1.1)`，Sepolia 的实际 gas 价远低于 20 gwei，所以真实消耗远低于第 10 行（参照第 14 行）。
- **价格 / gas / 费率放大的容忍度**：总量与 a0 成正比。只要 (ETH/USD ÷ aPNTsPriceUSD) × maxFeePerGas × gas limit 之和 × (1 + 费 + 缓冲) 的乘积不超过本文基准的 **5.78 倍**（= (cap − M0) / (503 × a0)，不含 m），500 笔仍在 cap 内。超过即失效：例如 ETH > ≈$15,600、maxFee > ≈115 gwei、`setAPNTSPrice` 把 aPNTs 价格调到 < ≈$0.0035。
- **N 超过 2,418 笔（最坏口径）即失效**。RepCredit R3–R5 的笔数仓库里没有给，第 9 行的 300 笔是本文的预留，不是计划值；DSR 定出实际笔数后按 #13 复核。
- **M0 不是常数**：P1 之前任何人都能用 `depositFor` 往已注册 operator 存旧 aPNTs（`SuperPaymaster.sol:189`），而旧 aPNTs 有 12.73M 在外（10M 在单个 EOA）。**A3b 铸造前必须重读 Σ operators**：M0 > cap − L − U ≈ 7,923,710 时本预算失效；M0 > cap 时 1:1 重铸本身会 `CapExceeded`。
- **不覆盖**：任何面向旧代币持有人的 1:1 兑换（12.73M > 10M）；给 operator 以外的地址（水龙头、测试用户、其他社区）铸 aPNTs；revenue 取出后重存的循环使用（会降低铸造需求，本文忽略，偏保守）。这些都另算，计入同一个 cap。
- cap 可以被 Safe 即时调低，调高要走 48h timelock；本预算假设测试期间 cap 保持 10,000,000e18。
- 本文不涉及 EntryPoint ETH 押金（RDR-6 ① 的 D_cap / F 是主网 ETH 口径，与本文的 aPNTs 口径无关）。

## 复现

```bash
RPC_A=<archive rpc> RPC_B=<second independent archive rpc> BLOCK=11877799 \
  python3 scripts/a3a-v2-cap-budget-read.py > /tmp/x.json   # 任一 check 为 false 时退出码 1
shasum -a 256 docs/release/a3a-precheck-v2/cap-budget-evidence.json
```
