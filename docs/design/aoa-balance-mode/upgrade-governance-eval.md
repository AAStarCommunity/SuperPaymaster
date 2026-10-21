# SP 升级权与 owner 权限的治理评估（主网前决策项，2026-09-13）

DSR 指出：`BasePaymasterUpgradeable._authorizeUpgrade` 是 `onlyOwner`，没有 timelock（`contracts/src/paymasters/superpaymaster/v3/BasePaymasterUpgradeable.sol:42`）。SP 的 owner 是 **EOA `0xb560…df0E`**（Sepolia 实测；Registry 的 owner 也是这个 EOA）。这把 EOA 能**即时**替换 SP 的实现，是整个系统权限最大、也最集中的一点。审稿人 R1-2 问的就是这一类问题。

## 1. 现状：SP owner 能做什么

`Ownable`，单步转移，用的是 OZ v5.0.2，不是 Ownable2Step。`onlyOwner` 的函数按性质分组：

| 类 | 函数（SuperPaymaster.sol / BasePaymasterUpgradeable.sol） | 现在的延迟 |
|---|---|---|
| 升级 | `_authorizeUpgrade`（Base:42）→ `upgradeToAndCall` | **即时** |
| 资金 | `withdrawTo`（Base:52，EP 押金）、`withdrawStake` / `unlockStake`（Base:60–64）、`withdrawProtocolRevenue`（:847，要留 buffer） | 即时（stake 有 EP 规定的 unlock delay） |
| 经济参数 | `setProtocolFee`（:510，上限 20%）、`setAPNTSPrice`（:488，单次 ±30% 且有上下界）、`emergencySetPrice`（:573，1 h timelock）、`setAPNTsToken` / execute / cancel（:399–429，有 timelock） | 大多即时，部分有限制 |
| 接线 | `setXPNTsFactory`（:526，**即时**）、`setTreasury`（:520）、`setAgentRegistries`（:1469）、BLS 聚合器的 queue/apply（:1063–1070） | 大多即时 |
| 惩罚与声誉 | `slashOperator`（:946）、`cancelSlash`（:924）、`updateReputation`（:960）、`primeBlsSlashCooldown`（:914） | 即时 |
| 暂停 | `setOperatorPaused`（:640，每个 operator 单独设置；**没有全局暂停**） | 即时 |

**这把钥匙被盗、或者 owner 作恶时，暴露的资产**：
- operator 存在 SP 里的 aPNTs、protocolRevenue、SP 在 EntryPoint 的 ETH 押金和质押：通过升级或 `withdrawTo` / `withdrawStake`，都可以全部拿走。
- **用户的 xPNTs 受 I6 保护**：token 侧的上界不依赖 SP 的实现。恶意 SP 通过锁定路径最多拿到"剩余额度 + K·cap"，信用路径受用户自己的申请上限约束，也不能直接转账（A-3）。**这正是 I6 存在的意义**：它假设 SP 可能被任意替换，而这个假设在现状下是真实存在的。
- Registry 的 owner（同一个 EOA）同样可以即时升级（`Registry.sol:967`），并即时替换 BLS 聚合器（`:283`）。

## 2. 方案

| 方案 | 做法 | 改动量 | 对紧急修复的影响 | 评价 |
|---|---|---|---|---|
| **T1** owner 换成 OZ `TimelockController` | `SP.transferOwnership(timelock)`；timelock 的 minDelay 设 48 h，proposer 和 canceller 都是 Mycelium Safe，executor 是 Safe（或开放给任何人）。Sepolia 上已经有一个 48 h 的 TimelockController（`0x86C8…`，v5.4 god-split 部署的） | **不改代码**：一笔转移，再读回 | **所有** onlyOwner 操作都要等 48 h，暂停 operator 也不例外 | 标准、审计充分，覆盖所有 owner 函数。缺点是没有快速止损的手段 |
| **T2** 在 `_authorizeUpgrade` 里加 queue/execute | 在 SP 内部实现"升级要先公示实现地址和 codehash，等 48 h" | 改代码（新存储、新函数、体积） | 只有升级变慢，其他 owner 函数仍然即时 | 覆盖面不如 T1（资金和接线类仍然即时），并且是自己写的 timelock。不推荐 |
| **T1 + G（推荐）** | T1，外加一个 **guardian 角色**（Mycelium Safe 直接持有，不走 timelock），**只能做止损方向的操作**：① `setOperatorPaused(op, true)`（只能暂停）；② 新增的全局 `paused` 开关，打开后 validate 一律返回 sigFail（所有新赞助立即停止，已在途的 op 照常结算和释放）。**恢复只能由 owner（timelock）执行**，guardian 不能恢复、不能升级、不能动资金。guardian 的地址只能由 owner 设置 | 小的代码改动：一个存储槽（guardian 地址 + `paused` 布尔，打包在一起）、两个修饰器或检查、validate 里多一次 SLOAD（SP 是已质押实体，STO-031 允许；冷读约 2.1k gas，可以和其他参数打包进同一个槽）。体积预计 +300–500 B，**需要原型实测**（当前余量 1,661 B）。存储是追加的，`__gap` 减 1，storage-layout 快照要更新 | 发现漏洞后，guardian 几分钟内就能全局暂停，止住损失；修复通过 timelock 至少 48 h 后上线。在此期间，已在途的 op 照常结算，用户可以通过 token 侧的急停（communityOwner 的 S-4）、`disableSpenderForSelf` 等手段自保 | **推荐**。把"快"和"大权限"分开：快的只能止损，大的必须等 48 h |

**不改代码时已经存在的应急手段**（T1 之下仍然可用）：
- 各社区的 communityOwner 可以对自家 token 即时执行 `emergencyRevokePaymaster`（S-4），把 SP 切断；
- 用户可以 `disableSpenderForSelf` 或 `releaseAndDisable`（E-4）；
- EntryPoint 层面没有 owner 之外的开关。

所以只用 T1 时，快速止损要靠每个社区各自动手，这就是推荐加上 G 的原因。

**其他注意点**：
- `Ownable` 是单步转移。转给 timelock 那一笔交易的地址**必须核对两遍**，交易之后读回 `owner() == timelock`，并确认 timelock 的角色配置正确（proposer、canceller、executor，以及 admin 已放弃）。要不要改成两步转移，需要改代码，可以和 G 一起做。**注意（更正）：不能直接改用 OZ `Ownable2Step` 作为基类**：它会在 `_owner`（slot 0）之后插入 `_pendingOwner`，让 SP 和 Registry 之后的所有槽后移，破坏原地升级。升级安全的做法见 03 §10.7b 的"GOV-2 存储设计"：自己实现两步转移，`pendingOwner` 放在 ERC-7201 命名空间槽。
- 日常运营的影响：`setAPNTSPrice` 本来是日常调价，放到 48 h 之后运营会变慢。可以选择：接受；把调价交给一个受限的 keeper（仍然受 ±30% 和上下界约束）；或者由 guardian 负责。需要作者决定。
- **Registry 同样处理**：Registry 的 owner 和升级权也应该放到 timelock 后面，否则 SP 放进 timelock 之后，Registry 就成了新的即时大权限（它能即时替换 BLS 聚合器、调整信用分档）。
- 与"gas 常数改为治理参数"的关系：参数调整的 48 h timelock 与本方案一致。T1 之后，升级本身也要等 48 h，参数化带来的新增信任面就更小了。

## 3. 需要作者决定（与 aPNTs 的 (b)、(d) 一起）

1. 主网 SP 和 Registry 的 owner：T1（TimelockController 48 h，Mycelium Safe 担任 proposer/canceller）是否作为主网部署的前置条件。
2. 是否加 guardian（G）：只能暂停和全局停止赞助，恢复必须走 timelock。若加，同时决定是否一并把 owner 改为 Ownable2Step。
3. 日常调价 `setAPNTSPrice` 在 timelock 之后怎么安排（接受 48 h / 受限的 keeper / 交给 guardian）。

写进 03 §10.7 信任矩阵"SP owner"一行，并列为主网前的决策项（03 §10.8 研究部署复核闸门（产品上线审计见 §10.8c））。
