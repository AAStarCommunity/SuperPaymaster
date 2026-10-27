# AOA-SP-02 第 3 项：A4 Passport 模板与权限矩阵

依据：DSR `AOA_Parallel_Work_Orders_2026-10-26.md` §AOA-SP-02 子任务 3。
本文给出正式 A4/A6 Passport **应读什么、在哪个固定块读、谁能改它**，并逐项对照当前
`script/a6-collector/collector.mjs` 的 `passport()` 实际读了什么。所有条目都以 main 上的 Solidity 源码为准，
不以 `abis/*.json` 为准（那些文件可能陈旧）。本文只是模板，**不是链上读数**；A3a 尚未执行，表里没有实测值。
机器可读的空模板：[`data/aoa-sp02/a4-passport-template.json`](data/aoa-sp02/a4-passport-template.json)。

源码简称：`SP` = `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`，`SPS` = 同目录 `SuperPaymasterStorage.sol`，
`SPA` = `SuperPaymasterAdmin.sol`，`BPU` = `BasePaymasterUpgradeable.sol`；`XB` = `contracts/src/tokens/v2/xPNTsV2Base.sol`，
`XT` = `xPNTsTokenV2.sol`，`XE` = `xPNTsTokenV2Ext.sol`，`XF` = `xPNTsFactoryV2.sol`，`PR` = `AOAProtocolRegistry.sol`；
`REG` = `contracts/src/core/Registry.sol`，`CAP` = `contracts/src/tokens/APNTsCapped.sol`；
`TL` = OpenZeppelin v5.0.2 `governance/TimelockController.sol`。

## 1. 模板与权限矩阵

「采集器现状」一列：✅ 已在 `passport()` 读、⚠️ 部分、❌ 未读。

### 1.1 代码身份

| 字段 | 固定块上的读法 | 谁能改 | 采集器现状 |
|---|---|---|---|
| SP proxy / implementation | proxy 地址；EIP-1967 slot `0x3608…2bbc`；两者 `eth_getCode` 的 keccak 与字节数 | owner 经 UUPS `upgradeToAndCall`，要求无 pendingOwner（BPU） | ✅ |
| Registry proxy / implementation | 同上 | Registry owner（UUPS） | ❌ |
| xPNTs 克隆 / 模板 / Ext | 克隆的 EIP-1167 目标；代币自己的 `EXTENSION()`；`XF.implementationCodehash()`、`extensionCodehash()` | 工厂部署时钉住，不可改 | ⚠️ 读了克隆、模板的 codehash；Ext 的 codehash 取自配置文件里的 `cfg.xPNTsTokenV2Ext`，**没核对代币实际的 `EXTENSION()` 是否指向它**（`collector.mjs:346`）；没读工厂钉值 |
| xPNTs 工厂 | `SP.xpntsFactory()`；工厂 codehash | SP owner `setXPNTsFactory` | ❌ |
| aPNTs（APNTsCapped） | `SP.APNTS_TOKEN()`、`pendingAPNTsToken()`、`pendingAPNTsTokenEta()`；`CAP` codehash | SP owner 排队，7 天延迟（SPA） | ⚠️ 读了 `APNTS_TOKEN`，没读 pending 与 codehash |
| EntryPoint | codehash | 不可改 | ✅ |
| 价格源 | `SP.ETH_USD_PRICE_FEED()` 及其 codehash | SP 实现里的 immutable，随升级可变 | ⚠️ 哈希的是配置里的 `cfg.priceFeed`，没读 SP 实际绑定的地址（`collector.mjs:351`） |
| 账户 / 账户实现 | sender 与 EIP-1967 实现的 codehash | 账户 owner 可经 UUPS 升级（SimpleAccount） | ✅ 读了两者并做漂移检查 |
| 运行时依赖钉值 | 采集器、校验器、依赖、合约源码、ABI、配置的 SHA-256 与 commit | — | ⚠️ `run_start` 有 collector 文件哈希与 HEAD；缺合约源码树哈希与配置哈希 |

### 1.2 治理：Safe / Timelock / owner / guardian

| 字段 | 读法 | 谁能改 | 采集器现状 |
|---|---|---|---|
| Safe owners / threshold | Safe `getOwners()`、`getThreshold()`（`script/a3a/a3a_exec.py` 已有读法） | Safe 自身（多签交易） | ❌ |
| Timelock 角色 | `hasRole(PROPOSER/EXECUTOR/CANCELLER/DEFAULT_ADMIN, x)`；**另查 `hasRole(EXECUTOR, address(0))`**（开放执行，TL） | 角色 admin `grantRole/revokeRole` | ❌ |
| Timelock 最小延迟 | `getMinDelay()`；预期 172800 s | 只能经 Timelock 自身执行 `updateDelay` | ❌ |
| 待执行操作 ETA | 对每个已知 operation id：`getTimestamp(id)`、`isOperationPending/Ready/Done(id)` | proposer 排队、canceller 取消、executor 执行 | ❌ |
| SP owner / pendingOwner | `owner()`、`pendingOwner()` | 两步转移，禁止 renounce | ❌ |
| SP guardian / paused | `guardian()`、`paused()`；operator 暂停在 `operators(op).isPaused` | owner 设 guardian；guardian **只能暂停** | ⚠️ 读了 `paused` 与 operator 暂停，没读 `guardian` |
| Registry owner / pendingOwner | 同 SP | 两步转移 | ❌ |
| xPNTs 社区 owner / 工厂 | `communityOwner()`、`FACTORY()` | 社区 owner 直接转移；可 `renounceFactory` | ❌ |
| aPNTs owner / minter / capGuardian / cap | `owner()`、`pendingOwner()`、`minter()`、`capGuardian()`、`cap()` | owner 设 minter/guardian、抬 cap；owner 或 capGuardian **立即**降 cap | ❌ |
| 工厂 owner | `owner()`（单步 Ownable） | owner | ❌ |

### 1.3 allowlist / seal

| 字段 | 读法 | 谁能改 | 采集器现状 |
|---|---|---|---|
| 协议注册表封印 | `PR.sealed_()` | owner 封印，不可逆 | ❌ |
| SP、实现、tier source 是否获批 | `PR.isApprovedSP(sp)`、`PR.isApprovedImpl(kind, impl)`、`PR.approved(kind,key)`、`PR.pendingAt(kind,key)` | 封印前 owner 即时批准；封印后新增排队 48 h、任何人执行；owner 可即时撤销 | ❌ |
| 代币的自动批准 spender | `autoApprovedSpenders(sp)`、`spenderActivatesAt(sp)` | 社区 owner 提议，48 h 后任何人激活；owner 即时移除 | ❌ |
| x402 facilitator | `approvedFacilitators(x)` | 社区 owner 直接增删 | ❌ |
| 代币指向的 SP | `SUPERPAYMASTER_ADDRESS()`、`pendingSP()`、`pendingSPEta()`、`emergencyDisabled()`、`standbySP()` | 社区 owner / 工厂提议，ETA 后激活；owner 紧急撤销 | ⚠️ 读了 `SUPERPAYMASTER_ADDRESS` 与 `emergencyDisabled` |

### 1.4 价格更新与恢复

| 字段 | 读法 | 谁能改 | 采集器现状 |
|---|---|---|---|
| 价格缓存 | `cachedPrice()`、`priceStalenessThreshold()`、`priceValidUntil()` | **任何人** `updatePrice()`（SPA:477，无 keeper 白名单）；`updatePriceDVT` 限 owner/BLS 聚合器 | ⚠️ 读了 price、decimals、threshold；`updatedAt` 记为 volatile |
| 紧急价格 | `priceMode()`、`emergencyQueuedAt()`、`emergencyPendingPrice()`、`emergencyActivatedAt()` | owner 排队/取消，1 h 后任何人执行 | ❌ |
| 费率 / aPNTs 价 | `protocolFeeBPS()`、`aPNTsPriceUSD()` | SP owner | ✅ |
| 汇率 | `exchangeRate()`、`exchangeRateUpdatedAt()` | 社区 owner 或工厂，有界并冷却 | ⚠️ 只读了 `exchangeRate` |
| gas 参数 | `gasParams()`（当前与 pending） | owner 排队/执行/取消 | ⚠️ 只读了 `minPostOpGas` |
| 卡住的赞助恢复 | `SP.inflightOf(opHash)`；代币 `lockOf`、`creditReservationOf` | 任何人 `releaseStaleSponsorship(opHash)` 与代币 stale release，两边记录**分别**清 | ⚠️ 逐 op 读了 `inflightOf` 与 `lockOf.xLocked` |

### 1.5 账本：balance / locked / used / budget、结算与退款、operator 与收入、EP ETH

| 字段 | 读法 | 采集器现状 |
|---|---|---|
| 用户 xPNTs 余额 / 锁定 | `balanceOf(u)`、`lockedOf(u)`、`lockOf(opHash,u)` → (xLocked, aReserved, locker) | ⚠️ 逐 op 读了前两项；`lockOf` 只保留 `xLocked`，丢了 `aReserved` 和 `locker`（`collector.mjs:312`） |
| 用户预算 | `autoAllowance(u, SP)` → (cap, used)；`userTotal(u)` → (cap, used)；`autoRenewUsed(u)`、`renewalMode(u)`、`spenderDisabled(SP,u)` | ❌ 只在 setup 里写，Passport 不读 |
| 债务 / 信用预留 | `debts(u)`、`creditReservedOf(u)`、`creditReservationOf(opHash,u)` | ⚠️ 读前两项，缺第三项 |
| 代币侧已用 opHash 标记 | `usedOpHashes(opHash)`（XB:126；只在结算时写，合约里没有任何读取，**不构成防重放**） | ❌ |
| operator | `operators(op)` → aPNTsBalance、isConfigured、isPaused、xPNTsToken、reputation、minTxInterval、treasury、totalSpent、totalTxSponsored | ⚠️ 读了大部分；缺 reputation、treasury |
| 协议收入 / 跟踪池 | `protocolRevenue()`、`totalTrackedBalance()` | ⚠️ 读 `protocolRevenue`，缺 `totalTrackedBalance` |
| EP ETH | `EntryPoint.balanceOf(pm)`、`getDepositInfo(pm)` | ✅ |

结算语义（源码）：验证时先锁用户余额，**只有 `INSUFFICIENT` 才回退到 credit**（SP:346-354）；postOp 按快照结算，
收费不超过 a0；operator 拿回 `a0 − charge`，**整笔 charge** 计入 `protocolRevenue`。`totalSpent` 在验证时按 a0 累加，
退款不减，所以它是**毛预留累计**，不是净支出；用它做守恒时要注意这一点。

## 2. 证明 credit OFF 且无遗留在途 credit

SP 没有全局 credit 开关；`MODE_CREDIT` 只是逐 op 的内部模式。credit 由**每个代币**的 `creditPolicy` 控制：
`POLICY_OFF = 0`（XB:43-45），OFF 时 `effectiveCreditCap` 恒为 0（XT:337-339）。`creditPolicy` 唯一写入点是执行排队的
policy（XE:174），初值为 0，且工厂部署时断言 `creditPolicy() == 0`（XF:330；整条条件在 XF:324-331，不满足时 XF:332 revert `InitializationFailed`）。

对窗口内要用到的每个代币 t、每个协议控制的用户 u，在固定块 B（开窗前与收窗后各一次）：

| # | 断言 | 读法 | 排除的坏状态 |
|---|---|---|---|
| C1 | t 的代码身份正确 | §1.1 的克隆目标与钉值 | 用别的合约冒充 t，C2 读到的 0 无意义 |
| C2 | 现在是 OFF | `t.creditPolicy() == 0` | credit 已开 |
| C3 | 没有排队中的变更 | `t.hasPendingPolicy() == false` | 窗口中途 ETA 到期把 credit 打开（只看 C2 排除不了） |
| C4 | 从未开过 | 从 t 部署块到 B 的 `CreditPolicyExecuted` 日志里，**没有** policy ≠ 0 的条目 | 曾经开过又关掉，留下历史预留和债务 |
| C5 | u 无在途预留 | `t.creditReservedOf(u) == 0` | u 名下还有未结清的预留 |
| C6 | 每个已知 opHash 无预留记录 | `t.creditReservationOf(opHash,u).locker == 0` | 零金额预留记录（C5 看不出来） |
| C7 | 全局无在途 credit | 从 t 部署块到 B 按（块号, 日志序号）顺序重放 `CreditReserved` / `CreditSettled` / `CreditReleased`：每条结清事件必须消耗一条同键（user, opHash）、尚未结清的预留，且只消耗一次；到 B 时没有未结清的预留 | 别的用户还有预留（链上**没有**聚合 getter 或可枚举集合，只能靠日志对账）。不能只查「同键有结清」：`tryReserveCredit` 不拒绝用过的 opHash，「预留→释放→再预留」会留下一笔在途却能通过这种查法 |
| C8 | 无遗留债务 | 对 C7 涉及的每个用户 `debts(user) == 0` | OFF 和零预留都不会清掉已结算的债务 |
| C9 | SP 侧无遗留 | 对窗口前已知的每个 opHash，`SP.inflightOf(opHash) == (0, 0)` | SP 与代币的 stale release 分开清，只清一边会留下另一边 |

**C4 与 C7 依赖日志扫描是否完整。** 扫描完整性无法从返回数据推断：漏掉的区间和真空区间长得一样。
所以这两项必须在两个独立的归档端点上各扫一次、逐条一致，并给出正对照：用一个已知含 `CreditPolicyExecuted` 或
`CreditReserved` 的区间（例如本地演练链），先证明扫描器能找到它。做不到就写「未能验证」，不写「无」。
在 C1 核实代码身份、且历史完整的前提下，C4 推得出没有任何预留和 credit 债务：成功的预留一定发 `CreditReserved`，
policy 变化一定发 `CreditPolicyExecuted`，OFF 时 `effectiveCreditCap` 直接返回 0、不查 tier source，只有当前 SP 能预留，
credit 债务只能经预留结算产生。C5–C9 **不是**独立于扫描的全局对照：C5、C6、C9 只覆盖已知的用户和 opHash，
C8 的用户集合来自 C7，C7 本身也是日志扫描。它们的用处是在已知集合上直接读值，抓「扫描说没有、getter 说有」的矛盾；
扫描漏掉的用户或 opHash，它们同样看不到。

`Registry.maxTotalCreditExposure()`、`totalCreditExposure()` 为 0，或 `getAvailableCredit` 为 0，都**不能**单独证明
credit OFF：前两者管的是声誉抬升的额度，不管代币准入；后者是扣掉已用后的余量。

## 3. 缺口列表

| # | 缺口 | 影响 | 处理 |
|---|---|---|---|
| A4-G1 | 采集器 Passport 不读 `creditPolicy`、`hasPendingPolicy`、`creditReservationOf` | 现有 `a6-gauge/1` 运行**无法**证明 credit OFF | **部分关闭**：`a6-gauge/2` 已记录 C2、C3，校验器拒收 policy≠OFF 或有排队变更的运行，`/1` 不能判为合规（`data/a6-gauge-credit/`）。C6 逐 op 读回与 C4/C7 扫描仍待做 |
| A4-G2 | 不读 Safe、Timelock、owner、pendingOwner、guardian、aPNTs 的 minter/capGuardian/cap | 治理漂移不可见 | 按 §1.2 补读，列入 `invariant` 做漂移检查。同 A4-G3 的限制：首尾快照相同不排除窗口内改了又改回。要排除，须给 §1.2 **每个**字段指定它的全部写入事件并对整个窗口扫描（双归档端点 + 正对照）；补读 PR 要附这张「字段 → 事件」表，并逐项从源码核对写入点。下列只是例子、**不是完整清单**：Timelock `RoleGranted`/`RoleRevoked`/`MinDelayChange`，owner 的 `OwnershipTransferStarted`/`OwnershipTransferred`，代币 `CommunityOwnerUpdated`，SP `GuardianSet`，aPNTs `MinterSet`/`CapGuardianSet`/`CapRaised`/`CapLowered`，Safe 的 owner、threshold、module、guard 变更事件 |
| A4-G3 | 不读协议注册表封印和批准状态 | 无法证明窗口内没有新增 SP 或实现获批 | 按 §1.3 补读快照；但快照只说明被查的键在被查的块上的状态：窗口内「批准→撤销」前后快照相同，没查的键也看不到。要说「窗口内没有新的批准」，须对整个窗口扫 `ApprovalProposed` / `ApprovalExecuted` / `ApprovalRevoked` / `Sealed`（双归档端点 + 正对照），否则只能写成「这些键在开窗与收窗时的状态」 |
| A4-G4 | 不读用户预算 `autoAllowance`、`userTotal` | budget/used 不进账本，守恒检查少一维 | 补进逐 op readbacks |
| A4-G5 | 不读 `totalTrackedBalance`、代币侧 `usedOpHashes`、operator reputation/treasury | SP 内部池不可审计；`usedOpHashes` 只写不读，补读只用于对账，不能当防线 | 补读 |
| A4-G6 | Timelock 没有「全部待执行操作」的 getter；SP 没有 operator 枚举；代币没有用户枚举 | 「没有其它待执行操作」「全局无预留」只能靠日志对账 | 同 C7 的双归档端点扫描与正对照 |
| A4-G7 | 运行时钉值缺合约源码树与配置的哈希 | Passport 绑定不到源码 | `run_start` 增加 `contracts/src` 树哈希与配置文件 SHA-256 |
| A4-G9 | Ext 和价格源的 codehash 取自配置文件，不是链上实际绑定；`lockOf` 只存 `xLocked` | 配置与链上不一致时 Passport 仍显示一致；锁的 locker 不可审计 | **部分关闭**：`a6-gauge/2` 改为哈希代币 `EXTENSION()` 与 `SP.ETH_USD_PRICE_FEED()`；`lockOf` 仍只存 `xLocked` |
| A4-G8 | 本地演练里 SP 未质押（见[对照表](aoa-sp02-adapter-matrix.md) U-6） | 与生产 bundler 准入不符 | 正式窗口按 W-1 质押 ≥ 1 ETH |

A4-G1 至 A4-G7、A4-G9 是对 `collector.mjs` 的改动，会在单独的 PR 里做，并配负对照。本文先把模板和判据定下来，供 DSR 审。
