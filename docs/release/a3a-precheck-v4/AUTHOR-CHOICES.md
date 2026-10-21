# A3a 作者选择单（一页）— 本包不替作者决定

> 对应 DSR CC-125 `dc77b160` 任务 3。本包（[`README.md`](README.md)）按下面三项的**默认值**演练；
> 第 1 项或第 3 项选非默认值时，S3 的 calldata 或 S7 的发送时点会变，**本包作废，需要重新生成**（第 1 项还需要新的 tag）；第 2 项只影响后续交权，不改变本包的任何一笔。
> 回复格式：`1=A/B，2=A/B，3=A/B`。

## 1. Sepolia 上 APNTsCapped 的 cap

| | 选项 | 后果 |
|---|---|---|
| **A（默认）** | **10,000,000e18**（`TEST_CAP_SEPOLIA`，`DeployAPNTsCapped.s.sol:84`，脚本在 11155111 上强制使用并拒绝 `APNTS_CAP`，`:180–189`） | 测试最坏累计铸造 2,079,224（含 1:1 重铸 2,934 + 在途底线 12,383 + 500 笔最坏消耗），余量 79.2%；最坏口径可承载约 2,418 笔。建议 A3b 首次铸造约 537,934。见 [`CAP-BUDGET.md`](CAP-BUDGET.md) |
| B | 其他值 | 需改脚本常量 → 新 rc tag → 本包重新生成（S3 initcode 变，S3 之后的地址不变但证据全部重做） |

与 OP 主网的区别：主网 cap **300,000e18** 是另一套推导（10 社区 × 100 人 × 20 笔/月 × ≈0.624 aPNTs × 12 月 × 2 ≈ 299,482，约 $6,000；`03-final-spec.md:633` GOV-4），铸造后立即 `lowerCap(已铸量)`（`:683` RDR-6 ②），部署时必须显式传 `APNTS_CAP`。Sepolia aPNTs 无价值，10M 只是测试上限，不是主网风险上界；旧 Sepolia aPNTs 总量 12.73M > 10M，但只有 SP 内的 operator 余额按 1:1 重铸，不迁移旧持有人。

## 2. 新 48h Safe-only timelock 是否作为唯一的 canonical timelock

| | 选项 | 后果 |
|---|---|---|
| **A（默认，DSR CC-122 v4）** | 是：S2 部署的 `0xCCdF…C34B`（minDelay 172800；PROPOSER / CANCELLER / EXECUTOR 只有 Safe `0x51eD…E114`，ADMIN 只有它自己，部署者无任何角色）此后也是 SP / Registry / AOAProtocolRegistry / Factory 的 owner 目标 | 所有后续交权都走同一把 timelock：每次 owner 操作 = Safe 2-of-3 schedule + 48h + Safe execute |
| B | 否：它只做 APNTsCapped 的 owner，其他合约另定 | A3a 本身不变；后续交权需要另一份方案。注意现有 timelock `0x86C8…9564` 的四个角色都在部署者 EOA 上，**不是** Safe-only，不能直接充当替代 |

## 3. 执行顺序

| | 选项 | 后果 |
|---|---|---|
| **A（默认，本包演练的）** | 串行：S1–S4 → S5（schedule accept）→ 等 ≥ 48h → S6（execute accept，APNTsCapped owner = timelock）→ S7（排队 `setAPNTsToken`）→ 等 7 天 → 最早 A3b | 约 **9 天**（fork 实测 ETA − T0 = 777,630 s）。S7 排队时 APNTsCapped 已归 timelock |
| B | 重叠：S4 之后立即 S7 | 约 7 天。S7 排队时 APNTsCapped 的 owner 仍在交接中；**本包未演练**，需要新的 fork 演练与 DSR 复核。DSR 明确：不先自行切到重叠方案 |

---
无论怎么选，执行 A3a 还需要：A2 总门收口（PR #514 合入 main）+ 作者对**本包**的单独 go；执行窗口内暂停共用部署者 EOA 的自动化，每笔前重读 nonce。
