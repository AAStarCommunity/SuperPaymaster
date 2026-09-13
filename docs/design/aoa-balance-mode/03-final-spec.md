# 03 · SP 5.5.0 + xPNTs v2 规范（定稿候选）

> **Codex 审阅记录（2026-09-12）：第 9 轮 APPROVE，v3.6-rc 是实现的设计基线。**
> | 轮次 | 结论 | 阻断项 |
> |---|---|---|
> | 1 | 续期设计：K 修改后通过；T-post 否决 | 2 Critical / 6 High |
> | 2 | 修改后通过，还不能开始实现 | 1 Critical / 4 High |
> | 3 | 修改后通过 | 1 Critical / 4 High |
> | 4 | 修改后通过 | 0 Critical / 6 High |
> | 5 | 修改后通过 | 0 / 2 High |
> | 6 | 修改后通过 | 0 / 1 High |
> | 7 | **APPROVE** | 0 / 0 |
> | 8（A-9/A-10 定向） | 修改后通过 | 0 / 2 High（最小代理白名单；主 SP 状态机） |
> | 9 | **APPROVE**（v3.6） | 0 / 0 |
>
> 每一轮的发现都由 SP 对照源码复核后才并入。**作者已定（2026-09-12）**：D-21 不处理（测试数据）；主网 = OP 主网；D-9 = 自托管 Alto 主用、Rundler 交叉验证（DSR 经作者授权确定）；DVT 询问走 Seeder（CC-121）。
>
> **状态：v3.9-rc（2026-09-13）：D6——按 R10-M1b / R10-M2 重写 §10.2 状态转移表，按模式拆开 opReverted 行，每一格补上 file:line；I10 的措辞同步到在途预留（operator 在 release 后净额为 0，G 由 SP 的 ETH 押金承担）；D3 发现：`SETTLE_GAS_BOUND` 从 80k 改为 160k（§10.1 ③）；验证期对 token 的三处调用（`exchangeRate` / `tryLockForGas` / `tryReserveCredit`）改为只拷 32 字节的低层调用，revert、短返回、畸形返回一律 fail closed 为 sigFail（§3.3；Codex D3 指出 typed try 挡不住解码失败）、I2 的"用户亲自操作"加以澄清、I6 的烧毁上界改用 §10.2 的公式。**
> v3.8-rc（2026-09-12）：并入 Codex 第 10 轮（1 High + 5 Medium）和 D1 的实现期发现（token 拆成核心和扩展、工厂接收预先部署的模板），见 §11。**
> v3.7-rc（2026-09-12）：并入 DSR 以 Reviewer 1 视角做的验收复核（B-1…B-7 High、独立审计闸门、Medium B-9/B-11/B-12），规范性内容在 §10，它优先于前文。**
> v3.6-rc（2026-09-12）：并入 Codex 第 8 轮（EIP-1167 最小代理的白名单规则；急停期间 SP 更换的规则）和 DSR 补充的 V4 产品影响。**
> v3.5-rc（2026-09-12）：新增 §2.5 SP 地址状态机的完整定义（S-0…S-7），起因是 stop-time Codex 审查指出 A-10 的更换流程不完整、没法实现。**
> v3.4-rc（2026-09-12）：补上 A-9（X6：工厂不再是 spender，DSR 核对时发现 03 漏了）和 A-10（v2 工厂的部署流程与 `propagateSuperPaymaster`，SP 在排查 A-9 时发现的同源遗漏）。**
> v3.3-rc（2026-09-12）：并入 Codex 第 6 轮（runbook 7a/7b/7c：先在暂停状态下发币，再处理 D-21，最后开信用并取消暂停）。**
> v3.2-rc（2026-09-12）：并入 Codex 第 5 轮的 2 个 High（runbook 中 D-21 的位置、I6 的信用部分）和 2 条 Low。**
> v3.1-rc（2026-09-12）：并入 Codex 第 4 轮（没有 Critical；6 High + 10 Medium，SP 已复核全部成立，修订集中在 §9）。§9 优先于本文其他段落。**
> v3.0-rc（2026-09-12）：这是规范性文档；[02](02-proposal-draft.md) 是协商过程的记录。两者冲突时，以本文为准。
> 本文已并入：作者的全部决定（§0）、Codex 第 1–3 轮中经 SP 复核成立的全部修订。第 4 轮 Codex 挑战以本文为范围。
> 作者 review 通过之前，不改合约、不部署。

## 0. 决定与范围

| 项 | 决定 | 来源 |
|---|---|---|
| 升级方式 | SP 代理 `0x09DF…` **原地升级**到 5.5.0；**不兼容旧代币**，没有 legacy 分支，也没有 `tokenGen` | 作者 / 02 §8.1 |
| RepCredit | 也迁到 5.5.0，经过 SP 结算/信用的证据重新采集；B3（BLS/committee/slash）保留 | 作者 |
| 余额模式 | A2：验证期锁定，postOp 结算 | Q1 |
| 免授权额度 | SP 默认 5,000 aPNTs；下限 **250 aPNTs**，各链统一；每用户总额默认 5,000 aPNTs；其他 spender 默认 0 | Q5/Q6/D-4 |
| 续期 | **A + B**：AirAccount 在自己的 `validateUserOp` 里调用 `renewForSelf`（`ACCOUNT_ONLY` 模式）；其他账户由 SP 转述续期标志（`SP_K` 模式），**K = 1（常量）**；AirAccount 入会时设为 `ACCOUNT_ONLY` | D-18 |
| 紧急停用 | 用户可以立即停用 SP（相当于额度撤到 0），恢复走 R2 | D-19 |
| 急停后换 SP | ②′：只能立即切到 48 h 前就预登记的备用 SP | D-15 |
| 信用 | 首版就带信用，并在**验证期预留**；社区策略 OFF / MANUAL / AUTO；AUTO 下用户入会时签一次 `requestCredit(maxCap)` | D-20 / §8.3 |
| 额度来源 | 可插拔的 `creditTierSource`；5.5.0 只上线 GLOBAL；COMMUNITY 放到后续版本，前提是 ReputationSystem 改为按社区授权或写入时带 BLS 证明 | §8.7 |
| 评估配置 | RepCredit 社区：AUTO + GLOBAL；AOA 评估社区：OFF | 作者 |
| D-21 | **作者定：不处理**。旧代币里的债务都是作者自己的测试数据，直接放弃（等同于选项 c，不需要改接口，也不需要单独披露） | 作者 2026-09-12 |
| 主网 | **OP 主网**（先在 Sepolia 充分测试，再上 OP 主网采集论文数据） | 作者 2026-09-12 |
| D-9 | **主用：自托管 Pimlico Alto**，Sepolia 和 OP 主网用同一版本、同一份配置，开启 safe mode（ERC-7562 全规则）；SP 5.5.0、VerifyingPaymaster、TokenPaymaster 走同一个实例（便于复现，也去掉厂商 bundler 给不同 paymaster 不同 PVG 这个混杂因素）。**交叉验证：Alchemy Rundler**，只在 B 层测 ERC-7562 兼容性，不参与 gas 数据。质押按 Alto 的**默认** minStake 和 minUnstakeDelay，不为 SP 调低；SP 在两条链上的质押补足到门槛以上（Sepolia 目前只有 0.1 ETH，门槛要实测）。Alto 的版本号、配置文件、启动命令写进论文附录。**兜底**：Alto 某项过不了而 Rundler 能过时，改用 Rundler（同样自托管或配置可公开），并记录原因 | DSR 定（经作者授权）2026-09-12 ✅ |
| 未定 | DVT 打分函数里有没有还债项（已在 Seeder 发 CC-121 向 repo:dvt 询问，不阻塞） | — |

## 1. 结构

```
 UserOp ──► EntryPoint v0.7
   ├─ 账户验证（AirAccount：若带 ACCOUNT_RENEW 位 → 从已签名的 paymasterAndData 里取出 token 地址 → token.renewForSelf(sp)，§9 R4-H1）
   ├─ SP.validatePaymasterUserOp
   │     现有检查（configured/paused/身份/MIN_POST_OP_GAS/isBlocked/validAfter/maxRate）
   │     operator 偿付检查
   │     r = token.tryLockForGas(sender, opHash, reserve, SP_RENEW 位)   ← try/catch；catch → sigFail
   │       OK           → BALANCE
   │       INSUFFICIENT → token.tryReserveCredit(sender, opHash, reserve) ─ OK → CREDIT，否则 sigFail
   │       其他          → sigFail
   │     operator 乐观预扣（不变）
   └─ SP.postOp
         gasleft() ≥ SETTLE_GAS_BOUND，否则 revert（§10 B-1）
         BALANCE → token.settleLocked(user, opHash, charge)   ← 不包 try/catch：失败 = postOp 回滚 = 用户执行被撤销
         CREDIT  → token.settleCredit(user, opHash, charge)   ← 同上
         operator 退差额（不变）
```

**SP 在 v2 token 上能调用的特权入口一共只有四个**：`tryLockForGas`、`settleLocked`、`tryReserveCredit`、`settleCredit`。
3.x 的 `burnFromWithOpHash`、`recordDebt`、`recordDebtWithOpHash` 在 v2 模板里**全部删除**（Codex C-1、C3-1）：
新的信用路径只通过"预留 → 结算"产生债务，已经不需要这三个函数。

## 2. xPNTsToken v2（`XPNTs-4.0.0`，新模板）

### 2.1 存储（在 3.5.0 前缀之后追加）

所有在**验证期写入**的槽，用户都是**最内层**键（ERC-7562 关联判据：`slot == keccak(A ‖ x) + n` 关联的是 A）。

```solidity
// —— 免授权额度（aPNTs 计价）——
struct Allow  { uint128 used; uint120 cap; bool set; }            // !set → 默认值（SP: SP_DEFAULT_CAP；其他: 0）
mapping(address spender => mapping(address user => Allow)) _auto;
mapping(address user => Allow)                             _budget;      // 跨 spender 总额
mapping(address user => uint8)                             autoRenewUsed; // SP_K 模式下已由 SP 转述的续期次数
mapping(address user => uint8)                             renewalMode;   // 0 = SP_K（默认），1 = ACCOUNT_ONLY
mapping(address spender => mapping(address user => bool))  spenderDisabled; // D-19 用户紧急停用

// —— 锁定 ——
struct LockRec { uint128 xLocked; uint128 aReserved; address locker; }
mapping(address user => uint256)                            lockedOf;
mapping(bytes32 opHash => mapping(address user => LockRec)) _locks;

// —— 信用 ——
struct CreditReq { uint128 requestedCap; uint128 approvedCap; uint32 epoch; } // approvedCap 只在 MANUAL 下使用
struct CreditRes { uint128 amount; address locker; }
mapping(address user => CreditReq)                            creditReq;
mapping(address user => uint256)                              creditReservedOf;
mapping(bytes32 opHash => mapping(address user => CreditRes)) _creditRes;
uint8   creditPolicy;          // 0 OFF / 1 MANUAL / 2 AUTO（当前生效值，验证期只读这一项）
uint32  policyEpoch;           // 每次策略切换 +1；epoch 不一致的申请或批准视为无效
uint8   pendingPolicy; uint64 pendingPolicyEta;
address creditTierSource;      // ICreditTierSource；切换走 queue/execute
address pendingTierSource;     uint64 pendingTierSourceEta;
address community;             // 初始化时由工厂显式传入（工厂 deployxPNTsToken 的调用方，即 COMMUNITY 角色地址；token 自己的 msg.sender 是工厂）；不随 communityOwner 转让而变化（§9）

// —— spender 与 SP 生命周期 ——
mapping(address spender => uint64) spenderActivatesAt;
mapping(address => bool)           historicalSP;   // 真正拿到过加锁权限的地址；此后永远不能使用 transferFrom
address standbySP; uint64 standbyActivatesAt;
mapping(address user => uint256)   allowanceNonce; // R2 签名
```

模板 immutable（按链写入；克隆通过 delegatecall 共享）：`SP_DEFAULT_CAP = 5,000e18`、`SP_CAP_FLOOR = 250e18`、
`USER_TOTAL_DEFAULT = 5,000e18`、`PROTOCOL_MAX_CAP`、`PROTOCOL_CREDIT_CEILING`、**`K = 1`（常量，不可调；原先的 K_MAX 取消）**、`SPENDER_TIMELOCK = 48 h`、
`SPENDER_REGISTRY`（codehash 白名单）、`TIER_SOURCE_REGISTRY`（分档源 codehash 白名单）。

### 2.2 接口

```solidity
enum LockResult   { OK, INSUFFICIENT, EMERGENCY, SINGLE_TX_LIMIT, INVALID_RENEWAL, CONFLICTING_LOCK, DISABLED }
enum CreditResult { OK, NO_CREDIT, EXCEEDS_CAP, EMERGENCY, SINGLE_TX_LIMIT, CONFLICTING, DISABLED }

// —— 只有 SP（当前 SP，或持有该记录的 locker）——
function tryLockForGas(address user, bytes32 opHash, uint256 reserveAPNTs, bool spRenew) external returns (LockResult, uint256 xLocked);
function settleLocked(address user, bytes32 opHash, uint256 chargeAPNTs) external returns (uint256 xBurned);
function tryReserveCredit(address user, bytes32 opHash, uint256 aPNTs) external returns (CreditResult);
function settleCredit(address user, bytes32 opHash, uint256 chargeAPNTs) external;

// —— 任何人（只在原交易结束之后生效，§2.4）——
function releaseStaleLock(address user, bytes32 opHash) external;
function releaseStaleCredit(address user, bytes32 opHash) external;

// —— 用户本人（msg.sender），或者 R2 签名（ECDSA / ERC-1271，验证期之外）——
function renewForSelf(address spender) external;                  // 方案 A：只访问与 msg.sender 关联的槽
function setRenewalMode(uint8 mode) external;
function setAutoAllowance(address spender, uint256 capAPNTs) external;
function setUserTotalCap(uint256 capAPNTs) external;
function disableSpenderForSelf(address spender) external;          // D-19
function enableSpenderForSelf(address spender) external;
function releaseAndDisable(address spender, bytes32 opHash) external; // 原子地：先停用，再释放该 opHash 过期的锁或信用预留；记录仍在原交易内时整个调用 revert（§9）
function requestCredit(uint256 maxCapAPNTs) external;              // 写入 requestedCap，记录当前 epoch
function revokeCredit() external;                                  // 用户撤回：阻止新预留
function executeBySig(bytes calldata action, address user, uint256 deadline, bytes calldata sig) external; // R2 签名版，覆盖上面各项

// —— communityOwner ——
function approveCredit(address user, uint256 capAPNTs) external;  // MANUAL：只能 ≤ requestedCap，记录 epoch
function queueCreditPolicy(uint8 p) external; function executeCreditPolicy() external; function cancelCreditPolicy() external;
function queueTierSource(address s) external; function executeTierSource() external;   // 执行时检查 codehash
function proposeSpender(address s) external; function activateSpender(address s) external; function removeAutoApprovedSpender(address s) external;
// SP 地址状态机（完整定义见 §2.5）
function proposeSP(address s) external; function cancelSP() external; function activateSP() external;
function emergencyRevokePaymaster() external; function unsetEmergencyDisabled() external;
function proposeStandby(address s) external; function activateStandbyDesignation() external; // 48 h 后生效，不授予任何权限
function emergencySwitchToStandby() external;   // 必须处于急停状态；提升为当前 SP，这时才写 historicalSP

// —— 视图 ——
function effectiveCreditCap(address user) external view returns (uint256); // 唯一的规范计算（§2.3 C-0）
function autoAllowance(address user, address spender) external view returns (uint256 cap, uint256 used);
function BALANCE_MODE_VERSION() external pure returns (uint16);          // = 1
```

### 2.3 规则（规范性）

**额度与续期**

| # | 规则 |
|---|---|
| A-1 | `_update`：对 `from != 0`，要求 `balanceOf(from) − value ≥ lockedOf[from]`，覆盖 transfer、transferFrom、burn、`transferAndCall`、permit 之后的转账，以及 mint 自动抵债时的烧币 |
| A-2 | 自动额度约束 `transferFrom`、`burn(address,uint256)` 和 SP 的锁定路径；显式 `approve` 优先使用，自动额度兜底。`allowance()` 返回 `显式 + 自动剩余（按实时汇率折算）`，并注明与锁定时汇率可能有差 |
| A-3 | `transferFrom` 与 `burn(address,uint256)`：当 `msg.sender == 当前 SP` 或 `historicalSP[msg.sender]` 时，**不论是否有显式 approve，一律拒绝** |
| A-4 | `tryLockForGas`：`used += reserve`（per-spender 和总额分别计）；`settleLocked`：`used −= (aReserved − charge)`，而且退回记在 `_auto[lock.locker][user]` 上 |
| A-5 | SP 转述的续期（`spRenew`）：只有 `renewalMode == SP_K`、`autoRenewUsed < K`、`lockedOf == 0`、`creditReservedOf == 0` 时才生效（`used` 清零，`autoRenewUsed += 1`），否则返回 `INVALID_RENEWAL`，并且**整个验证失败**，不会转去信用 |
| A-6 | `renewForSelf`（方案 A）/ R2：只要 `lockedOf == 0` 且 `creditReservedOf == 0`，就清零 `used` 和 `autoRenewUsed`。`renewForSelf` **只访问**与 `msg.sender` 关联的槽，不读任何全局槽，因为账户帧没有 STO-033 的只读特权 |
| A-7 | 同一 sender 在一个 bundle 里最多一笔续期，而且必须排在第一笔；不兼容的组合由 SDK 拆开 |
| A-8 | SP 额度不能设到 250 aPNTs 以下；**紧急停用**（`spenderDisabled`）是另外一个开关，不受下限约束 |
| A-9 | **X6**：v2 的 `initialize` 不把工厂写入 `autoApprovedSpenders`。工厂只保留 `onlyFactoryOrOwner` 的管理权（`mint`、`updateExchangeRate`、初始化时的配置），不能作为任何 spender。已核实 3.x 工厂代码里没有 `transferFrom` 或 `burn` 调用，删掉它的 spender 身份不会损失功能 |
| A-10 | **v2 工厂的部署流程**（3.x 的 `deployxPNTsToken` 在 `xPNTsFactory.sol:254–261` 直接调用 `addAutoApprovedSpender(SUPERPAYMASTER)` 和 `addAutoApprovedSpender(paymasterAOA)`，与 A-3、X4、Q5 冲突）：① 创世 SP 地址由工厂在 `initialize` 时传入，直接生效（此时代币还没有持有人，不需要 timelock），同时写 `historicalSP`，**但不加入 `autoApprovedSpenders`**；② 可选的 `paymasterAOA` 作为**创世 spender** 登记，同样不需要 timelock，但每用户默认额度为 0（Q5），用户要通过 R2 或显式 approve 开通；它必须通过 codehash 白名单（V4 是 EIP-1167 最小代理，按 §9 的最小代理规则校验它的实现合约）；**产品影响**：V4 的每用户默认额度为 0，所以 V4 的 `depositFor` 需要用户先显式 approve 或通过 R2 开通。这符合 V4 的定位（给想完全自持的社区，本来就要 approve 并预存），而且 V4 不进 AOA 论文，不影响任何证据。SDK 和 V4 社区需要知悉；③ **工厂的 `propagateSuperPaymaster`（`:389`）在 v2 里只能发起提议**：对每个 token 走 §2.5 的 S-1，同样要等 48 h，communityOwner 在等待期内可以取消，工厂不能提前激活；完整状态机见 §2.5 |

**紧急停用（D-19，Codex H3-3）**

| # | 规则 |
|---|---|
| E-1 | `spenderDisabled[SP][user] == true` 时，SP 发起的新锁定、新续期、新信用预留全部返回 `DISABLED` |
| E-2 | 已经存在的锁和预留，在原交易内照常结算；原交易结束之后照常 stale release。停用**不删除** `used`、`lockedOf`、`creditReservedOf`，也不删除任何结算需要的记录 |
| E-3 | 恢复（`enableSpenderForSelf` 或 R2）不自动重置 `used`；重置按 A-6 的条件另外进行 |
| E-4 | `releaseAndDisable` 在同一笔交易里先停用、再释放，中间不存在可以被重新加锁的窗口 |

**锁定与信用预留的生命周期（Codex N-H2、C3-1）**

| # | 规则 |
|---|---|
| L-1 | `tryLockForGas` / `tryReserveCredit` 在失败路径上**不写任何状态**（只返回结果） |
| L-2 | 成功时写单笔记录（带 `locker = msg.sender`），同时 TSTORE 一个活标记，槽为 `keccak(user ‖ keccak(opHash ‖ SEED))` |
| L-3 | `settleLocked` / `settleCredit` 要求：`msg.sender == record.locker`；**活标记 == 1**（即仍在原交易内）；`charge ≤ aReserved`（或 `≤ amount`），xBurn ≤ `xLocked`；先删除记录、减汇总值，再烧币或记债；**不重新读取**当时的策略、分档或汇率 |
| L-4 | `releaseStaleLock` / `releaseStaleCredit`：任何人都能调；要求活标记 == 0 且记录存在；锁全额退回，预留全额撤销；幂等（记录不存在时返回，不 revert） |
| L-5 | `historicalSP`：地址**真正拿到**加锁权限时（初始 SP、每次激活的 SP 或 standby）置位；只是被提议时不置位；用事件枚举。已退役的 locker 只保留对自己那些记录的**结算**权限，而且只在原交易内有效 |

**信用（Codex N-C1、H3-4、Medium）**

| # | 规则 |
|---|---|
| C-0 | **唯一的额度计算** `effectiveCreditCap(user)`：`creditPolicy == OFF` → 0；用户停用了 SP → 0；`creditReq.epoch != policyEpoch` → 0；否则取 `min(requestedCap, PROTOCOL_CREDIT_CEILING, tierOf(community, user))`；MANUAL 时再与 `approvedCap` 取最小值。`tierOf` 调用失败或返回格式不对 → 0。预留、视图、lens、测试、不变量**全部**使用这个函数 |
| C-1 | `tryReserveCredit`：要求 `debts + creditReservedOf + amount ≤ effectiveCreditCap(user)`，并且 `amount ≤ maxSingleTxLimit` |
| C-2 | `settleCredit`：`debts += min(charge, amount)`；预留被消费掉之后才记债（CEI） |
| C-3 | 策略切换：queue → 48 h → 任何人都可以 execute（写入时读 `block.timestamp` 没有问题，验证期不读 ETA）；execute 时 `policyEpoch += 1`，**之前所有的申请和批准都失效**，用户要重新申请。已准入的预留照常结算 |
| C-4 | 撤销（用户 `revokeCredit`、owner 调低 `approvedCap`、声誉下降）只影响**新**预留，已有债务和已准入的预留不受影响 |
| C-5 | 分档源切换：queue → 48 h → execute，执行时检查 codehash ∈ `TIER_SOURCE_REGISTRY`。5.5.0 的 `GlobalTierSource.tierOf(_, user) = Registry.getCreditLimit(user)` |

**验证期访问清单**（B 层逐项测；清单之外，token 在验证期不得访问任何槽）

| 帧 | 访问 | 槽 | 规则 |
|---|---|---|---|
| SP（已质押） | 读 | `SUPERPAYMASTER_ADDRESS`、`historicalSP[SP]`、`emergencyDisabled`、`exchangeRate`、`maxSingleTxLimit`、`creditPolicy`、`policyEpoch`、`creditTierSource`、`community`；Registry 的 `creditTierConfig` | STO-033 |
| SP | 读写 | `lockedOf[u]`、`_auto[SP][u]`、`_budget[u]`、`autoRenewUsed[u]`、`_locks[h][u]`、`creditReservedOf[u]`、`_creditRes[h][u]`；只读 `renewalMode[u]`、`spenderDisabled[SP][u]`、`creditReq[u]`、`_balances[u]`、`debts[u]`、Registry 的 `globalReputation[u]` | STO-021 |
| SP | TSTORE | 活标记 | OP-070 按 STO-021 处理 |
| 账户（未质押） | 读写 | `renewForSelf` 只访问 `lockedOf[me]`、`creditReservedOf[me]`、`_auto[sp][me]`、`_budget[me]`、`autoRenewUsed[me]`、`renewalMode[me]` | STO-021；**不读任何全局槽** |
| 所有帧 | 禁止 | `_reentrancyStatus`、`usedOpHashes`、`spenderRateLimit`、任何 `total*` 计数器；TIMESTAMP、NUMBER、ORIGIN | OP-011 |

### 2.4 悬挂释放

postOp 首次回滚会让整个 `innerHandleOp` 帧回滚，**用户这笔的执行结果也被撤销**；锁和预留是在验证期写的，所以会留下来。
L-4 规定释放时全额退回。`MIN_POST_OP_GAS` 必须 ≥ v2 postOp 最坏路径的实测 gas，并留出余量，要有专门的测试守住。
恶意 SP 通过"释放后立刻再锁"持续骚扰时，用户用 `releaseAndDisable` 一步退出（E-4）。

### 2.5 SP 地址状态机（规范性，完整定义；取代 X4、D-15、A-10 中关于 SP 更换的零散写法）

**存储**：`SUPERPAYMASTER_ADDRESS`（current）；`pendingSP`、`pendingSPEta`、`pendingSPByFactory`（bool）；`pendingStandby`、`pendingStandbyEta`、
`standbySP`；`emergencyDisabled`、`emergencyRevokedAddress`；`historicalSP`。

**权限**：只有 `current` 能调用 `tryLockForGas` / `tryReserveCredit`；`settleLocked` / `settleCredit` 只认记录里的 `locker`，而且只在原交易内有效（L-3）；
`historicalSP` 里的地址永远不能使用 `transferFrom` 和 `burn(from)`（A-3）。

| # | 转移 | 谁可以调 | 前置条件 | 效果 |
|---|---|---|---|---|
| S-0 | 创世 `initialize(..., sp, …)` | 工厂（一次） | `sp != 0`，codehash 在白名单里 | `current = sp`；`historicalSP[sp] = true`；**不加入 spender 名单** |
| S-1 | `proposeSP(new)` | communityOwner；或者工厂（经由 `propagateSuperPaymaster`；**急停期间工厂不能提议**） | `new ∉ {0, current, emergencyRevokedAddress}`；codehash 在白名单里；工厂的提议**不能覆盖** communityOwner 的提议，communityOwner 的提议可以覆盖工厂的提议 | `pendingSP = new`，`pendingSPEta = now + 48 h`，记录提议来源；发事件 |
| S-2 | `cancelSP()` | communityOwner（任何时候）；工厂（只能取消自己的提议） | 有 pending | 清空 pending |
| S-3 | `activateSP()` | 任何人 | `now ≥ pendingSPEta`；**重新检查** codehash 仍在白名单里；`pendingSP != emergencyRevokedAddress`；**急停期间只有 communityOwner 发起的提议能激活**（工厂的提议在 S-4 已被取消，急停期间也不能再发起） | `current = pendingSP`；`historicalSP[pendingSP] = true`；清空 pending。旧 SP 只剩对自己记录的结算权（L-3）。**不自动解除急停** |
| S-4 | `emergencyRevokePaymaster()` | communityOwner | 未处于急停状态 | `emergencyDisabled = true`；`emergencyRevokedAddress = current`；**如果 pending 是工厂发起的，一并取消**（防止急停期间工厂抢着换 SP）；current 的加锁和预留权立即失效（返回 `EMERGENCY`） |
| S-5 | `proposeStandby(s)` → 48 h → `activateStandbyDesignation()` | 提议：communityOwner；激活：任何人 | `s ∉ {0, current, emergencyRevokedAddress}`；codehash 在白名单里（激活时重新检查） | `standbySP = s`；清空 `pendingStandby` 和 `pendingStandbyEta`。**不授予任何权限，也不写 `historicalSP`** |
| S-6 | `emergencySwitchToStandby()` | communityOwner | 处于急停状态；`standbySP != 0` 且不等于 `emergencyRevokedAddress`；重新检查 codehash | `current = standbySP`；`historicalSP` 置位；`standbySP = 0`；清空 pending |
| S-7 | `unsetEmergencyDisabled()` | communityOwner | `current != emergencyRevokedAddress`（沿用现有规则） | `emergencyDisabled = false` |

**实现位置（D6）**：S-0 在 `xPNTsTokenV2.sol:85–91`（`initialize`）。以下各转移都在 `xPNTsTokenV2Ext.sol` 中：S-1 `:223`、S-2 `:245`、S-3 `:257`、S-4 `:268`、S-5 `:280`（propose）和 `:289`（designate）、S-6 `:301`、S-7 `:311`；`_setCurrentSP` 在 `:318`，负责 `historicalSP` 写入和清空 pending。
覆盖测试：`xPNTsTokenV2Test.test_S1_S3_rotation_after_timelock`、`test_factory_proposal_cannot_override_community_and_is_cancelled_by_emergency`、`test_S6_S7_standby_recovery`，以及 `xPNTsTokenV2D3Test` 的 `test_S2_*`、`test_S3_*`、`test_A10_*`。

**为什么急停期间还允许 S-3**（与 Codex 第 8 轮的建议不同）：如果急停期间只能走备用 SP，那么没有预设备用 SP 的社区会永久卡在急停状态（S-7 要求 current 不等于被撤销的地址）。只允许 communityOwner 发起、已公示满 48 h 的提议，它的安全性和备用 SP 相同（都是 48 h 前就公开的地址），而且不会卡死。

**由此得到的性质**：急停之后，恢复只有两条路：S-6 立即切到 48 h 前就公开的备用 SP，或者 S-3 等一个 48 h 的提议到期；然后才能 S-7 解除急停。
工厂在任何时候都**不能**让一个 SP 地址不经 48 h 公示就生效（创世 S-0 除外，那时代币还没有持有人）。
切换 token 的 SP 之后，社区还要在新 SP 上 `configureOperator`，否则新 SP 的 validate 会因为 operator 未配置而拒绝，这是默认失败。

## 3. SuperPaymaster 5.5.0（原地升级）

### 3.1 存储

**零新增**，`__gap` 不变。

| 状态 | 处理 |
|---|---|
| `operators[*]` | 保留。旧代币的 operator 必须在升级前暂停（§6） |
| `userOpState` | **保留并继续使用**：`isBlocked` 由 validate 读取，Registry 的黑名单同步（`updateBlockedStatus`，SP `:613` ← Registry `:639`）写入。旧的封禁记录**沿用** |
| `_settledDebtOps` | **保留并继续使用**，作为 postOp 的幂等锁（SP `:1373`）；旧的 hash 无害 |
| `pendingDebts`（slot 17） | 变成占位槽，不能删除。升级前按 §6 对账清零或明确核销 |
| `sbtHolders`、BLS 指针、EntryPoint 质押、operator 的 aPNTs 余额 | 不变 |
| `pendingAPNTsToken` | 升级**之前**必须执行或取消（§6）；它的 ETA 会跨升级保留，而且一直可以执行 |

### 3.2 `paymasterAndData`

```
[paymaster 20][verifGas 16][postOpGas 16][operator 20][maxRate 32][token 20][flags 1]
token: SP 校验它等于 operators[operator].xPNTsToken，不相等就 sigFail（§9 R4-H1）
flags: bit0 = SP_RENEW（SP 传给 tryLockForGas），bit1 = ACCOUNT_RENEW（只由 AirAccount 读取）；两位同时置 1 → sigFail
context: (token, user, aPNTsAmount, opHash, operator, mode, callGasLimit, postOpGasLimit)
```

### 3.3 代码改动

| 改动 | 内容 |
|---|---|
| validate | 按 §1 的流程；调用 token 一律用 try/catch，**catch → sigFail**，不让不支持的代币冒泡成 AA33（Codex H3-1） |
| postOp | 按 §1 的流程，**结算不包 try/catch**（§10 B-1）；charge = `min(initialAPNTs, calc(actualGasCost + buffer) × (1 + fee))`，buffer 用 DSR §3.1.3 的保守上界（`C_WRAP` 由 trace 推导），论文里称为"保守报价上限"，不能称为精确报销 |
| `configureOperator` | 探测 `BALANCE_MODE_VERSION() == 1`，不满足就拒绝；工厂校验不变 |
| 删除 | `_creditExceeded`、`_recordDebt`、`retryPendingDebt`、`clearPendingDebt`，以及 legacy 的分支 |
| `getAvailableCredit` | 重写为 `max(0, token.effectiveCreditCap(user) − debts − creditReservedOf)`（饱和减法，Codex H3-4 / R4-H4） |
| dryRun | 保留在 SP 里，改为镜像新流程；**如果实测放不下**，执行 F1 拆到 lens（实测可以腾出 2,150 B） |
| 事件 | ~~`SponsorshipUnbacked`~~：v3.7 取消（§10 B-1，这条路径已经不存在） |
| `version()` | `SuperPaymaster-5.5.0` |

## 4. 不变量

| # | 不变量 |
|---|---|
| I1 | 用户 xPNTs 余额的减少只可能来自：用户本人的交易；`settleLocked`；名单内 spender 在额度内经 `transferFrom` 或 `burn(from)`；mint 时的自动抵债 |
| I2 | 对任意 (user, spender)：自上次合法重置以来经 `transferFrom`、`burn(from)`、`settleLocked` 的累计 ≤ cap；各 spender 的累计之和 ≤ 总额上限；两次用户亲自操作之间，SP 转述的续期 ≤ K。**v3.9 澄清**："用户亲自操作"指用户本人发起的任意一次续期（`renewForSelf` 或 R2 `ACT_RENEW`），**不论指定哪个 spender**；A-6 的 `_renew` 总会把 `autoRenewUsed` 清零，所以用户续期任何 spender 都会重新开放 SP 的 K 次续期。每次重新开放都来自用户的签名或调用，所以 SP 在一个窗口内最多获得 K 次续期 |
| I3 | 新债务只能由 `settleCredit` 产生，而且只能消费一笔在准入时满足 C-1 的有效预留。`creditPolicy == OFF`、没有有效的当期申请、已撤回或已停用，这些状态**阻止新的预留**；债务在这些状态下仍可能增加，但**只能**来自消费此前已准入的预留（与 E-2、C-3、C-4 一致，§9 R4-H4） |
| I4 | 每笔交易结束时：`lockedOf[u] == Σ _locks[·][u].xLocked`，`creditReservedOf[u] == Σ _creditRes[·][u].amount`，并且 `balanceOf(u) ≥ lockedOf[u]` |
| I5 | 活标记为 0 之后，任何记录都只能被 stale release 处理，不能再被结算 |
| I6 | **恶意 SP**（impl 被任意替换、不经过任何 UserOp），每个用户：按锁定路径结算的 aPNTs 等值 ≤ `min(剩余 SP 额度 + K·SP cap, 剩余总额 + K·总额上限)`；xPNTs 烧毁量 ≤ `min(余额, Σ xc_i)`，`xc_i = min(x0_i, ceil(c_i · x0_i / a0_i))`（§10.2 的公式；**v3.9 修正**：原来写的 `Σ ceil(aCharge_i · rate_i / 1e18)` 每笔会少算最多 1 wei，按 lock 时的比例结算时可能被合法地超出，I 层用 `test_I6_literalBurnBound_offByOneWei` 复现）；新债分两部分：(i) 新预留只能在当期 epoch 内准入，额度 ≤ `max(0, min(有效的当期 requestedCap, PROTOCOL_CREDIT_CEILING) − debts − reserved)`；(ii) epoch、策略或分档源变化之后，**不能再准入新预留**，但此前已准入的预留仍然可以结算，每笔只能把自己那笔 reservation 转成不超过其 amount 的债务，所以这一部分的新增债务 ≤ 失效那一刻的 `creditReservedOf`（与额度来源无关，与策略无关，见 02 §8.7 的四格表）；转走的量 = 0。**范围**：只是 token 侧的上界 |
| I7 | `effectiveCreditCap` 是所有信用判断的唯一来源（结构性要求，由测试在每个信用入口上断言） |

## 5. 体积

| 项 | 数值 |
|---|---|
| SP 当前 | 23,569 B，余量 1,007 B（**实测**） |
| F1 能腾出的空间 | 2,150 B（**实测**，带对照组） |
| 5.5.0 的净变化 | 删除 legacy 信用逻辑，加上新的流程、context、buffer 和 dryRun 镜像：**不能拿估算做决定**（Codex 第 3 轮） |
| 发布门槛 | 实测 runtime ≤ 24,576 − **1,024 B**（给以后的修复留出空间）；不满足就执行 F1 |
| token v2 | 15,301 B + 估算 5–7 KB，要实测；工厂 initcode 远低于 49,152 B |

## 6. 升级与迁移 runbook（Codex H3-1、H3-2）

前提：DSR 发布 "B6 evidence frozen"（对 RepCredit 旧证据而言）+ 作者 review 通过 + §8 的测试全绿。

| 步 | 动作 | 验收（每一步都要带正对照读回） |
|---|---|---|
| 0 | **fork 层级检查（§10.8b R-AMS）**：`eth_config` 读 `current` / `next`，`next` 是 Amsterdam 就阻塞；盘点：枚举所有 `operators[*]`；按 `DebtRecordFailed` 事件枚举 `pendingDebts` 非零的条目；确认 `pendingAPNTsToken` 的状态 | 盘点表入库；日志扫描按"归档 RPC + 扫描完整性"纪律做交叉验证 |
| 1 | aPNTs 切换（T0）。**作者已决定（2026-09-13，经 DSR）：执行分支 A**，在升级窗口内执行，也就是 RepCredit B6 冻结之后，不提前。执行顺序：快照各 operator 余额 → 各 operator 取出全部余额 → `withdrawProtocolRevenue` 把 revenue 取到只剩 **0.1**（PROTOCOL_REVENUE_BUFFER）→ 读回 `totalTrackedBalance == protocolRevenue ≤ buffer` → `executeAPNTsTokenChange` → 各 operator 用新 aPNTs（`0xBb46…`）按 **1:1** 重新存入。实现：`UpgradeToV5_5_0.executePendingAPNTs(ops)`，设 `V55_APNTS_DECISION=execute`；演练记录见 D5-deploy-migration §9 | `pendingAPNTsToken == 0`；`APNTS_TOKEN == 0xBb46…`；每个 operator 的 `aPNTsBalance == 快照 × 1`；`totalTrackedBalance == Σ + protocolRevenue`。真实的 operator 要先拿到新 aPNTs，否则重新存入这一步会明确报错 |
| 2 | `pendingDebts`：逐条对账，要么先用 5.4.2 的 `retryPendingDebt`/`clearPendingDebt` 处理，要么在文档里明确核销 | 所有条目为 0，或者有核销记录 |
| 3 | 用 `setOperatorPaused`（SP `:589`）暂停所有旧代币的 operator；等 mempool 里的旧 op 清空 | 各 operator `isPaused == true` |
| 4 | 按顺序部署：`GlobalTierSource` → codehash 白名单登记 → AOA 工厂（构造时生成 v2 模板，把默认分档源传给 token 的 initialize，**立即** `setSuperPaymasterAddress(SP)`）；如果需要 F1，再部署 lens | 模板 codehash 与 artifact 一致；工厂的 SUPERPAYMASTER 等于 SP |
| 5 | 升级之前核对 5.5.0 impl 的构造参数（`REGISTRY`、`ETH_USD_PRICE_FEED`、`entryPoint`）；SP `upgradeToAndCall` → 5.5.0 | `version()`；三个 immutable 读回，并与 5.4.2 一致；BLS 三腿不变；`sbtHolders` 抽样；`userOpState` 抽样 |
| 5b | **SP 在 EntryPoint 的质押补足到 ≥ 1 ETH，`unstakeDelaySec` ≥ 86400**（v3.9，D-9 调整：主用 bundler Rundler v0.11.0 的默认门槛是 1 ETH / 86400 s，与 ERC-7562 的 MIN_UNSTAKE_DELAY 一致；SP 在验证期读全局槽，依赖 STO-033，不质押就会被 bundler 拒绝）。owner 调用 `SP.addStake{value: 差额}(max(86400, 当前 delay))`。2026-09-13 的实测：Sepolia 的 SP `0x09DF…` 和 OP 主网的 SP `0xA2c9…` 质押都只有 **0.1 ETH**（delay 86400） | `EntryPoint.getDepositInfo(SP)`：`staked == true`、`stake ≥ 1e18`、`unstakeDelaySec ≥ 86400`、`withdrawTime == 0` |
| 6 | `SP.setXPNTsFactory(AOA 工厂)`（CC-119 T5） | 读回 |
| 7a | 各社区在 AOA 工厂发 v2 代币（community 固定；`creditPolicy` 初始为 OFF），operator **仍处于暂停状态** | 代币 codehash 与模板一致；默认分档源读回正确 |
| 7b | **D-21（作者定：不处理）**：旧代币里的债务都是测试数据，直接放弃，只在迁移记录里写一句。下面保留原来的三个选项，仅作记录：(a) 把核对过的旧债导入 v2 代币；(b) 在 v2 代币上把欠债用户标记为不可开通信用；(c) 核销并在迁移记录里披露总额。**(a) 或 (b) 需要 v2 模板多一个一次性函数**（`importLegacyDebt(users, amounts)` 或 `setCreditIneligible(users)`，只有 communityOwner 能调，只能在 `creditPolicy` 首次离开 OFF 之前调用，而且之后永久关闭）；(c) 不需要改接口 | 对账记录入库；**这是 7c 的前置验收条件** |
| 7c | **先 `SP.updatePrice()`，读回 `cachedPrice.updatedAt > 0` 且未过期**（D3 §8(a)：价格缓存为 0 时 validate 会 revert，得到 AA33 而不是 sigFail）→ `configureOperator` → 取消暂停（此时只有余额模式）；RepCredit 社区 `queueCreditPolicy(AUTO)`，48 h 后 execute，AUTO 才生效；AOA 社区保持 OFF | 探测通过；每个社区一笔余额模式 op 成功，AUTO 社区另加一笔信用 op 成功 |
| 7d | **主网前**（任何时候都可以执行，作者要求保证随时可转）：aPNTs 铸币权交给 Mycelium Safe：先由当前 communityOwner 调 `renounceFactory()`，再 `transferCommunityOwnership(Safe)`（单步转移、没有 accept，**地址必须核对两遍**）。主网的新 aPNTs 部署时直接由 Safe 持有；是否在 mint 里强制上限，见 `apnts-mint-authority.md` §4，由作者决定 | `communityOwner == Safe`；`FACTORY == 0`；EOA 和工厂调 `mint` 都 revert，Safe 调 `mint` 成功（fork 演练，块 11692415，已通过） |
| 8 | 旧代币：不迁移余额（旧债已在 7b 处理）；如果需要，另外提供 1:1 兑换合约，由用户自愿兑换，欠债用户能否兑换按 D-21 的结论决定 | — |
| 9 | 下游：SDK / DVT / YAAA 按 02 §8.4 执行；在 airaccount-contract 开 issue（方案 A） | — |
| 10 | RepCredit 重新采集，范围按 02 §8.4；新增同一 bundle 多笔的 Measured 测试（修正后的 L249） | — |

## 7. 信任矩阵新增行

| 主体 | 能力 | 损失上界 / 缓解 |
|---|---|---|
| SP owner（UUPS 升级权） | 替换 impl | 只能销毁、不能转走，上界见 I6；codehash 白名单**约束不到**代理的 impl；建议（产品层面）把升级权放到 timelock 后面 |
| standby SP | 急停后可以立即接管 | 地址 48 h 前公开；但它的 impl 同样不受约束，恢复能不能成立取决于 standby 的升级权 |
| Registry owner | 改 `creditTierConfig`、改 source 白名单、立即升级 Registry | 在 AUTO 模式下影响额度；上界受 `requestedCap` 约束；目前是 EOA、没有 timelock（产品改进项） |
| BLS 法定人数 | 写全局声誉 | GLOBAL 分档的输入 |
| communityOwner | 策略切换（48 h）、MANUAL 批准（≤ 用户申请额）、调整汇率（有上下限） | 不能越过用户的 `requestedCap` |
| communityOwner（可用性） | 每 48 h 切换一次策略或分档源，就能让所有 AUTO 用户的申请反复失效 | 没有资金损失；属于可用性攻击，要监控报警，并在论文里写成信任假设 |
| 能签 UserOp 的主体（含 session key） | 方案 A 下的续期 | 不能调高上限；session key 能不能续期由账户策略决定 |
| 中继 | 代为提交 R2 签名 | 不能篡改签名内容 |

## 8. 测试矩阵

本节是**完整的**测试要求，不引用 02（Codex R4 Medium）。

- 恶意 SP：依次调用四个特权入口，以及**所有继承下来的公开 selector**；专门覆盖"预留 → 直接记债 → 结算"这条变异路径（在 v2 里必须因为 selector 不存在而失败）。
- 信用：同一 bundle 里 N 笔信用 op 合计超过额度，必须在第 k 笔验证时被拒；验证与 postOp 之间发生策略切换、撤销、声誉变化；`tierOf` revert 或返回格式不对；epoch 失效。
- 紧急停用：有锁和预留时停用，然后结算、release、恢复；用 `releaseAndDisable` 对抗重复加锁。
- 迁移：在 fork 上把 runbook 0–7 完整走一遍；遇到旧代币的 operator 返回 sigFail，而不是 AA33。
- U/I/A/M/D/B/G 各层的完整要求见 §9；B 层至少覆盖 Alto 和 Rundler，包括 AirAccount 带 initCode 的首笔、`renewForSelf` 的实际 trace，以及 factory 质押在门槛上下两种情况。

## 9. Codex 第 4 轮后的修订（v3.1，规范性）

第 4 轮结论：**修改后通过，没有 Critical**。Codex 确认已经解决的项：C3-1、H3-1、H3-2、分档源失败按 0 处理、AUTO 治理
写进信任矩阵、体积门槛。以下 6 个 High 和各项 Medium 已由 SP 复核成立，现并入。

| # | 问题 | 修订 |
|---|---|---|
| R4-H1 | AirAccount 不知道要调用哪个 token：`paymasterAndData` 里没有 token 地址，而 `SP.operators[operator]` 是非关联槽，未质押的账户不能读 | `paymasterAndData` 增加 **token 地址**（20 B，被签名覆盖）；SP 校验它等于 `operators[operator].xPNTsToken`，不相等就 sigFail。AirAccount 从自己的 calldata 里取出这个地址，**先验证签名，再调用** `renewForSelf`。AirAccount 在入会时把 `renewalMode` 设为 `ACCOUNT_ONLY`（token 默认是 `SP_K`，不设就会悄悄保留 K=1 的 SP 路径）。`ACCOUNT_RENEW` 和 `SP_RENEW` 不能同时置 1 |
| R4-H2 | 备用 SP 的"登记"和"启用"被混为一谈 | 拆成三步：① `proposeStandbySP`；② 48 h 后 `activateStandbyDesignation`，**不授予任何 SP 权限，也不写 `historicalSP`**；③ `emergencySwitchToStandby`：要求处于急停状态，把备用提升为当前 SP，记录新旧地址，**这时才**把它记为 `historicalSP` |
| R4-H3 | 迁移漏掉了旧代币里的用户债务 `xPNTsToken.debts[user]`：旧债留在旧代币里，而新代币债务从 0 开始，欠债的用户会拿到一份全新的 AUTO 额度 | **D-21 等作者选**：(a) 把核对过的旧债导入 v2；(b) 旧债还清之前不开通 v2 信用，也不能兑换；(c) 明确核销并披露。SP 的建议是 **(c)**：这是测试环境，作者已经决定不考虑旧代币，而且 RepCredit 会在 5.5.0 上重新采集证据；核销的总额按事件对账后写进迁移记录 |
| R4-H4 | I3 与"已准入的预留在停用、换 epoch、撤销之后仍然结算"矛盾；另外有几处减法可能下溢 | I3 已改写（§4）；I6 和 `getAvailableCredit` 改为饱和减法 `max(0, …)` |
| R4-H5 | GLOBAL 分档源没有启动路径：`creditTierSource` 默认是 0，而切换要等 48 h | token 的 `initialize` 接收一个**默认分档源**（必须在白名单里），工厂部署时传入 `GlobalTierSource`。部署顺序：`GlobalTierSource` → 白名单登记 → 工厂和模板 |
| R4-H6 | runbook 没有核对 implementation 的 immutable（`REGISTRY`、`ETH_USD_PRICE_FEED`，SP `:38–41`；`entryPoint`，BasePaymasterUpgradeable `:19`）。构造参数错一个，就会让验证失效，或者指向错误的合约，而且代理的存储看不出任何变化 | runbook 第 5 步之前：核对 5.5.0 impl 的构造参数；升级之后：读回这三个地址，并与 5.4.2 的值逐一比对 |

**Medium（全部并入）**

| 项 | 修订 |
|---|---|
| A-5 与 L-1 冲突 | SP 转述的续期**先在内存里算出结果**，只有余额锁定成功时才写入；如果最终走信用分支，续期不产生任何副作用 |
| epoch | 拒绝把策略切换成当前已生效的值（否则 owner 可以在不改策略的情况下作废所有申请）；换 epoch 之后，`requestCredit` 清空 `approvedCap`；`approveCredit` 要求用户有当期的申请，不能复活过期的申请。**分档源切换同样让 `policyEpoch += 1`**，用户需要为新的分档源重新授权 |
| 反复切换 | 恶意 owner 每 48 h 切换一次策略，就能让所有 AUTO 用户的申请反复失效。这是可用性问题，写进信任矩阵，并由监控报警 |
| 分档源接口 | `ICreditTierSource.tierOf` 必须是 `external view`（STATICCALL），调用时限制转发的 gas；白名单只收**不可升级**的合约。**可升级代理禁止**，因为它的 codehash 约束不到实现；**EIP-1167 最小代理允许**，因为它不可升级：校验时确认运行时字节码是标准的 45 字节克隆格式，取出内嵌的实现地址，再对**实现合约**的 codehash 做白名单检查（Codex 第 8 轮）。这条规则同样适用于 spender 白名单（X5） |
| `releaseAndDisable` | 同时处理锁和信用预留；要求记录已经过期（活标记为 0）。如果记录还在原交易里，整个调用 revert（停用也随之回滚），客户端退回单独调用 `disableSpenderForSelf` |
| 250 aPNTs 下限 | 它只是配置下限，不保证一笔 op 一定放得下。**SDK 规范性要求**：报价时如果 `reserve > 可用额度`，拒绝或提示，L1 上尤其要注意 |
| `communityId` | 改为 `address community`，由工厂显式传入（§2.1 已改） |

**完整测试要求（替代对 02 §6 的引用）**：

- **U 单元**：每个入口的成功与失败路径，失败路径断言具体的 error 或返回的枚举值。
- **I 不变量**：I1–I7。handler 覆盖 mint、transfer、transferFrom、burn(from)、transferAndCall、lock、settle、release、续期（A 和 B）、requestCredit、approveCredit、策略切换、停用和恢复、急停、切换到备用 SP。
- **A 对抗**：
  - R1-3 的六类场景：被盗的 owner、恶意工厂、重复转账、替换 SP、撤权、批处理。
  - SP 状态机：S-0…S-7 每个转移的正常和失败路径；急停期间，communityOwner 发起的提议可以激活，工厂发起的提议被取消，而且急停期间工厂不能再提议。
  - 恶意工厂：在没有显式 approve 的情况下，工厂调用 `transferFrom` 和 `burn(from)` 都必须失败（A-9）；工厂发起的 SP 提议在 48 h 内不生效，而且 communityOwner 可以取消（A-10）。
  - 路线 A 的五类场景：自抽干、同一 bundle、多个 nonce key、`maxCost` 超上限、postOp 回滚（含 penalty）。
  - 恶意 SP：调用全部 selector，包括"预留 → 直接记债 → 结算"这条路径。
  - 同一 bundle 里 N 笔信用 op 合计超额。
  - 验证与 postOp 之间发生策略、分档或声誉变化。
  - 分档源 revert 或返回格式不对。
  - 重复加锁骚扰，以及 `releaseAndDisable`。
  - 急停之后切到备用 SP。
  - 旧代币的 operator 必须得到 sigFail，而不是 AA33。
  - `paymasterAndData` 里的 token 地址与 operator 配置的代币不一致。
  - 两个续期位同时置 1。
- **M 变异**：每个机制都要有**指名的**断言变红，而且要确认变异真的改变了目标场景的行为。
- **D 一致性**：dryRun 或 lens 与真实 validate 对同一批输入的结果逐项相等。
- **B bundler**：Alto 和 Rundler，safe-mode 打开。要逐项核对：
  - SP 质押是否达到门槛；
  - §2.3 验证期访问清单里的每一行；
  - AirAccount 带 initCode 的首笔，factory 质押在门槛上下两种情况；
  - `renewForSelf` 的实际 trace；
  - 验证期 TSTORE；
  - 各种错误码：AA23、AA24、AA33、AA34。
- **G gas**：`C_WRAP` 上界的 trace；`MIN_POST_OP_GAS` ≥ postOp 最坏路径的实测 gas。
- **迁移**：在 fork 上把 runbook 0–10 完整走一遍，包括读回 impl 的三个 immutable。

## 10. R1 验收复核后的修订（v3.7，规范性）

来源：DSR `AOA_Decision_1_2_R1_Acceptance_Review_2026-09-12.md` §二 B 表。以下各项 SP 已对照源码复核。

### 10.1 B-1：结算失败不能让用户白嫖 gas（最终方案）

**问题**（成立）：v3.6 的 postOp 用 try/catch 包住 `settleLocked`。攻击者把 `paymasterPostOpGasLimit` 设得刚好让内层调用耗尽 gas（63/64 规则），
外层仍有足够的 gas 走完 catch，于是 postOp 成功返回，**用户的执行结果被保留**，锁却留在原地，之后被 stale release 全额退回。
同一 bundle 里后面几笔已经通过验证，拉黑也拦不住。

**最终方案**：

1. **结算不包 try/catch**：`settleLocked` / `settleCredit` 失败时，postOp 整体 revert，EntryPoint 连同用户这一笔的执行一起撤销（`innerHandleOp` 帧回滚），
   之后 stale release 全额退回才是正确的，因为用户确实什么也没得到。这样就得到一条**结构性质**：**用户执行结果被保留 ⇔ 结算成功**。
   不存在"执行生效但没付钱"的路径，也就**不需要区分"没收"和"退回"两种锁**，DSR 建议的 ③ 自然成立。`SponsorshipUnbacked` 事件随之取消。
2. **结算在逻辑上不会失败**：先减 `lockedOf`，再 `_burn(xCharge)`；因为 `balanceOf ≥ lockedOf ≥ xLocked ≥ xCharge`，烧币不会失败。
   急停期间照常结算（E-2），SP 更换后原 locker 照常结算（L-3），`settleLocked` 内部**不做任何外部调用**，gas 有固定上界。
3. **gas 只能不够、不能被利用**：postOp 入口检查 `gasleft() ≥ SETTLE_GAS_BOUND`（postOp 不受 ERC-7562 限制，可以读 GAS），不够就直接 revert；
   `MIN_POST_OP_GAS ≥ SETTLE_GAS_BOUND + SP 自身开销的实测上界 + 余量`，由专门测试守住。**v3.9（D3 实测）**：`SETTLE_GAS_BOUND` 必须覆盖入口检查之后 postOp 的**全部**剩余工作（最坏路径：首次写 lastTimestamp、首次写幂等位和 usedOpHash、BALANCE 或 CREDIT 结算），实测约 137k；原先的 80k 低于这个值，存在"检查通过、随后 OOG"的区间（不构成漏洞，因为结算不包 try/catch，回滚会一并撤销用户执行，但与本条"不开始可能半途耗尽的结算"不符）。现取 **160k**，由 `test_B1_no_oog_band_above_entry_guard` 守住：两种模式下扫描 postOp 可用 gas，结果只能是 PostOpGasTooLow 或完整结算。在这个条件下，用户无法通过调低 gas 让 postOp 回滚；
   即使回滚了，用户的执行也被撤销，拿不到任何好处。

**不变量**：

| # | 不变量 |
|---|---|
| I8 | 对每一笔 BALANCE 或 CREDIT op：用户执行结果被保留 ⇒ 这一笔已经结算（烧币或记债） |
| I9 | **没有后盾的赞助**（执行结果被保留、用户却没付钱）：**每笔 = 0，每 bundle = 0，每 operator = 0** |
| I10 | postOp 回滚（只可能是实现缺陷或 gas 上界测错）时：用户净额 = 0（执行被撤销，锁全额退回）；**v3.9 起以 R10-M1b 为准**：operator 的 `a0` 在交易之后经 `releaseStaleSponsorship` 全额退回，净额 = 0，`protocolRevenue` 不变；这一笔的 EntryPoint 费用 `G` 由 SP 的 ETH 押金承担（每笔上界 = 这一笔的 prefund），攻击者没有收益。（原文"operator 损失 a0、protocolRevenue 虚增 a0"描述的是 R10-M1b 之前的行为，已作废） |

### 10.2 B-2：状态转移表（m6；v3.9 按 R10-M1b / R10-M2 重写，D6）

记号：`a0` = 验证期预留的 aPNTs（§10.3），`x0 = ceil(a0 · rate_v / 1e18)`（`rate_v` 是验证时的汇率），`c` = 结算额（aPNTs，`c ≤ a0`），
`xc = min(x0, ceil(c · x0 / a0))`，`G` = EntryPoint 从 SP 的 ETH 押金里扣的最终费用。空格表示不变。
行号对应 D3 头部 `1f8769c7`；`SP` = `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`，`T` = `contracts/src/tokens/v2/xPNTsTokenV2.sol`，`B` = `…/v2/xPNTsV2Base.sol`，`X` = `…/v2/xPNTsTokenV2Ext.sol`，`EP` = 规范 EntryPoint v0.7（codehash `0x8db5ff69…`）。

| 事件 \ 状态 | 用户 xPNTs 余额 | lockedOf | creditReservedOf | debts | operator aPNTsBalance | SP 持有的 aPNTs | protocolRevenue | in-flight `_inflight[h]` | EP ETH 押金（SP） | xPNTs totalSupply |
|---|---|---|---|---|---|---|---|---|---|---|
| operator `deposit(amt)` | | | | | +amt（SP:775） | +amt（SP:764） | | | | |
| operator `withdraw(amt)` | | | | | −amt（SP:829） | −amt（SP:833） | | | | |
| validate 失败（sigFail，SP:1183–1255 各 return） | | | | | | | | | | |
| BALANCE 锁定（validate） | | +x0（T:237） | | | −a0（SP:1258） | | **不变** | 写入 (op, a0)（SP:1260–1261） | −prefund（EP `_validatePaymasterPrepayment`） | |
| CREDIT 预留（validate） | | | +a0（T:302） | | −a0（SP:1258） | | **不变** | 写入 (op, a0)（SP:1260–1261） | −prefund（同上） | |
| postOp 成功（BALANCE） | −xc（T:264） | −x0（T:260） | | | +(a0−c)（SP:1342） | | +c（SP:1343） | 删除（SP:1340） | +(prefund−G)（EP `_postExecution`） | −xc（T:264） |
| postOp 成功（CREDIT） | | | −a0（T:319） | +c（T:322） | +(a0−c)（SP:1342） | | +c（SP:1343） | 删除（SP:1340） | +(prefund−G) | |
| opReverted（BALANCE，用户执行 revert） | −xc（T:264） | −x0（T:260） | | | +(a0−c)（SP:1342） | | +c（SP:1343） | 删除（SP:1340） | +(prefund−G) | −xc |
| opReverted（CREDIT，用户执行 revert） | | | −a0（T:319） | +c（T:322） | +(a0−c)（SP:1342） | | +c（SP:1343） | 删除（SP:1340） | +(prefund−G) | |
| postOp 回滚（I10；用户执行一并撤销） | | 锁留下（活标记随交易结束清零） | 预留留下 | | 暂不退（仍是 −a0） | | **不变** | 保留，活标记清零 | +(prefund−G)（EP 以 postOpReverted 模式二次 `_postExecution`） | |
| stale release（锁，交易之后，任何人） | | −x0（B:313；T:270 入口） | | | | | | | | |
| stale release（预留，交易之后） | | | −a0（B:323；T:326 入口） | | | | | | | |
| `releaseStaleSponsorship(h)`（交易之后，任何人） | | | | | +a0（SP:1356） | | | 删除（SP:1355） | | |
| `withdrawProtocolRevenue(amt)` | | | | | | −amt（SP:855） | −amt（SP:853） | | | |
| `mint(m)` 且有债（自动抵债） | +m − rx（B:246–247） | | | −ra（B:245） | | | | | | +m − rx |
| 用户停用 / 恢复（X:66–67） | | | | | | | | | | |
| 急停 / 更换 SP | 已有的锁、预留照常由原 locker 结算（T:252）或交易后释放 | | | | | | | 原 SP 的 in-flight 照常结算或释放 | | |
| 迁移（§6） | 旧代币不动；v2 从 0 开始 | 0 | 0 | 0 | 原 operator 的余额保留 | | | 空 | | |

前置条件：BALANCE 锁定要求 `balance − lockedOf ≥ x0`，且额度、总额、单笔上限、停用标志都满足（T:187–211）；CREDIT 预留要求 C-1（T:275–286）；postOp 结算要求 L-3（T:250–253，T:313–316）；postOp 入口要求 `gasleft() ≥ SETTLE_GAS_BOUND`（SP:1308）；同一 opHash 的 postOp 只记账一次（SP:1318–1319，P1-17）。
opReverted 与 postOp 成功走同一段代码：SP 的 postOp 不区分 `PostOpMode`（SP:1300）。在两种模式下，速率限制时间戳都会写入（SP:1313–1314）。
`ra`、`rx` 是自动抵债的 aPNTs 额和 xPNTs 额（B:238–249）。
**守恒**：对每一笔 op，operator 净变化 = −c（结算）或 0（回滚后 release）；protocolRevenue 只在 postOp 结算时增加 c。验证期不再预记收入，因此不存在"退款被 protocolRevenue 截断"的问题（R10-M1b）。
**测试**：`SuperPaymasterV55Test.test_balance_mode_end_to_end`（operator 净减 == 收入增 == 烧币量）、`test_I10_stale_sponsorship_restores_operator`、`test_I10_release_refused_while_in_flight`、`test_I8_settle_failure_rolls_back_user_execution_e2e`、`xPNTsTokenV2Test.test_L3_…`/`test_L4_…`，以及 D3 的 A 层和 I 层。

### 10.3 B-6：预留额（规范）

```
a_gas = ceil( maxCost × cachedPrice.price × 1e18 / (10^decimals × aPNTsPriceUSD) )      // 用缓存价，验证期采样（SuperPaymaster.sol:1126）
a0    = ceil( a_gas × (BPS + protocolFeeBPS + VALIDATION_BUFFER_BPS) / BPS )             // 含协议费和 10% 验证缓冲
x0    = ceil( a0 × exchangeRate_v / 1e18 )，并要求 exchangeRate_v ≤ maxRate（用户在 paymasterAndData 里的承诺）
c     = min( a0, ceil( calc(actualGasCost + buffer) × (BPS + protocolFeeBPS) / BPS ) )   // postOp 时用同一个缓存价
```

- **按完整的 `maxCost` 预留**，不做任何截顶。`a0 > maxSingleTxLimit` → `SINGLE_TX_LIMIT`，验证失败；`a0 > 可用额度或可用总额` → `INSUFFICIENT`，
  符合条件时转去信用，否则验证失败。**不允许截顶后放行**。
- 舍入：面向用户的额度一律向上取整（协议不少收）；结算额不超过预留额（用户不多付超出承诺的部分）。
- 汇率只在验证时采样一次（`x0 / a0` 的比例），结算不重新读取（D-12）。

### 10.4 B-7：额度状态的转移规则

| 变化 | `_auto[spender][user]` | `_budget[user]` | 其他 |
|---|---|---|---|
| spender 被移除后重新加入 | **保留** `used/cap/set`，重新加入**不会**隐式清零 | 不变 | — |
| 更换 SP（S-3 / S-6） | 新 SP 用自己的格子（默认 cap）；旧 SP 的格子保留（旧 SP 只剩结算权） | **共享**，总额约束继续有效 | `autoRenewUsed` 按用户计，不按 SP 计 |
| 调低 cap 或总额，低于 `used` | 剩余额度 = `max(0, cap − used)`，不 revert，`used` 不变 | 同左 | — |
| 停用 / 恢复 | 计数不变 | 不变 | 只切换 `spenderDisabled` |
| 重置 `used` | 只能走 A-5 / A-6 | 同左 | — |

`allowance()` 返回 `min(type(uint256).max, 显式 approve + 自动剩余)`（饱和加法），显式 approve 为 `max` 时不会溢出 revert。

### 10.5 B-5：SP 不适用 codehash 规则

SP 是 UUPS 代理，codehash 规则（§9）约束不到它的实现。**SP 单独处理**：S-0 / S-1 / S-3 / S-5 / S-6 对 SP 地址检查的是
**`SP_REGISTRY`（协议治理维护的代理地址白名单，模板 immutable）**，只确认"这是一个协议认可的 SP 代理"；实现的风险归入 SP 的升级治理（信任矩阵 §10.7）。
codehash 规则只适用于非 SP 的 spender 和分档源。

### 10.6 B-3：R1-4 原文点名的测试（带 ID）

| ID | 场景 | 对应不变量 | 期望上界 / 断言 |
|---|---|---|---|
| T-R14-01 | 一人控制 N 个账户（Sybil），每个账户都有 SBT，各自发最大成本 op | I2、I9 | 每个账户按自己的锁付费；没有后盾的赞助 = 0；损失不随 N 增长 |
| T-R14-02 | 同一账户在同一 bundle 里重复发最大成本 op，覆盖多个 nonce key | I4、I9 | 第 k 笔在 `balance − lockedOf < x0` 时被拒；已准入的每笔都结算 |
| T-R14-03 | 过期的黑名单：`isBlocked` 在验证之后、postOp 之前才被 Registry 写入 | I8、I9 | 已准入的 op 照常结算；新 op 被拒 |
| T-R14-04 | 用户执行 revert（opReverted，区别于 postOp 回滚） | I8 | 用户照样为 gas 付费（`xc` 被烧掉），锁被清除 |
| T-R14-05 | postOp 回滚（gas 不够或人为让 settle revert） | I10 | 用户执行被撤销；锁在交易后可以 release；operator 损失 ≤ a0；攻击者收益 = 0 |
| T-R14-06 | 债务不可回收：AOA 社区 `creditPolicy == OFF` | I3 | 任何路径下 `debts` 都不增加（在测量区间内读回 OFF） |
| T-R14-07 | 同一 bundle 放大没有后盾的赞助：攻击者自建 bundler，把 postOpGasLimit 精确调到让 settle 内层 OOG | I9 | 无法成功：要么 postOp 入口因 gas 预检查 revert，要么结算成功；**不存在"执行保留、结算失败"的结果** |
| T-R14-08 | 信用 N 笔同一 bundle 合计超额 | I3、C-1 | 第 k 笔在验证期被拒 |
| T-R14-09 | `MIN_POST_OP_GAS` 覆盖：对 postOp 最坏路径做 gas 测量 | I10 | 实测值 + 余量 ≤ `MIN_POST_OP_GAS` |

### 10.7 B-4：信任矩阵（补全）

| 主体 | 能力（源码位置） | 最坏后果 | 缓解 |
|---|---|---|---|
| SP owner | UUPS 升级；`setOperatorPaused`（`:589`）；`setProtocolFee`（`:459`，上限 20%）；`setTreasury`（`:469`）；`setAPNTSPrice`（`:437`）；`emergencySetPrice`（`:522`，1 h timelock）；`setXPNTsFactory`（`:475`，**即时生效**）；BLS 聚合器（`:1019`–`:1034`，queue/apply）；`slashOperator`（`:910`）；`updateReputation`（`:924`）；`setAgentRegistries`（`:1600`，影响资格判定）；`withdrawProtocolRevenue`（`:796`）；EntryPoint 存款与质押（Base `:48`–`:64`） | 升级为恶意实现：token 侧上界见 I6；operator 的 aPNTs 与 EntryPoint 押金可以被拿走；可以暂停或罚没 operator | 建议把升级权和即时生效的配置放到 timelock 后面（产品改进项）；论文如实写成信任假设 |
| **（DSR，2026-09-13）SP 的升级权** | `_authorizeUpgrade` 是 `onlyOwner`，**没有 timelock**（`BasePaymasterUpgradeable.sol:42`）；owner 是 **EOA `0xb560…`**（Sepolia 实测），单步 `Ownable` | 即时替换实现：可以拿走 operator 存款、revenue、EP 押金和质押；**用户的 xPNTs 受 I6 保护**（token 侧的上界不依赖 SP 的实现） | **主网前决策项**：T1（owner 换成 TimelockController 48 h，Mycelium Safe 担任 proposer/canceller）+ G（guardian 只能暂停和全局停止赞助，恢复必须走 timelock）；Registry 同样处理。评估见 `upgrade-governance-eval.md` |
| Registry owner | 即时替换 BLS 聚合器（`Registry.sol:283`）；立即升级（`:967`）；`setCreditTier`（`:676`）；`setReputationSource`（`:848`）；`setLevelThresholds`（`:870`）；`setSuperPaymaster`（`:276`） | 绕过 BLS、改变 AUTO 额度 | 用户申请上限约束信用暴露（I6）；建议 timelock。黑名单更新现在要求非空 BLS proof（`:619`–`:640`） |
| `SP_REGISTRY` / `SPENDER_REGISTRY` / `TIER_SOURCE_REGISTRY` 的 owner | 增删白名单 | 把恶意合约加入白名单 | 白名单只是**必要条件**：激活仍需 communityOwner 提议并等 48 h；只在激活时检查，事后移除不影响已激活的；建议由 Mycelium Safe 持有，并对"加入"设 48 h timelock |
| （DSR O2）白名单撤销的范围 | `AOAProtocolRegistry.revokeApproval` **只影响以后的激活**，不会撤下已经激活的 SP、spender 或分档源 | 已激活的对象出问题时，白名单撤销无济于事 | 已激活对象的应急路径在 **token 层**：SP → `emergencyRevokePaymaster`（S-4），之后走 S-6 切到备用 SP 或 S-3 换 SP；spender → `removeAutoApprovedSpender`（即时生效）；分档源 → `queueTierSource` 换源（48 h），紧急时可以先 `queueCreditPolicy(OFF)`，或者由用户自己 `disableSpenderForSelf` / `revokeCredit` |
| 工厂（owner） | 创世配置（S-0、A-10）；对已部署 token 发起 SP 提议（S-1，communityOwner 可以取消） | 创世时写入错误的 SP 或 spender | 创世配置读回（runbook 第 7a 步）；之后没有即时权限 |
| communityOwner | 策略切换、MANUAL 批准、调汇率（有上下限）、spender 提议、急停、备用 SP；类型：EOA 或 Safe；可以用 `transferCommunityOwnership` 转让 | 可用性攻击（反复切换）；不能越过用户的申请上限 | 建议使用 Safe；恢复程序：由现任 owner 转让，丢失 key 时无法恢复（论文写明） |
| operator | `configureOperator`、`minTxInterval`、存取 aPNTs | 只影响自己的社区 | — |
| keeper（任何人） | `updatePrice`（Chainlink，permissionless） | 价格来自 Chainlink，keeper 不能伪造 | 陈旧度通过 `validUntil` 约束 |
| BLS 法定人数、中继、能签 UserOp 的主体 | 见 §7 | — | — |

### 10.7b 主网前的治理决策项（汇总，待作者决定）

| # | 事项 | 评估文档 | 推荐 |
|---|---|---|---|
| GOV-1 | SP 和 Registry 的 owner / 升级权放到 timelock 后面 | `upgrade-governance-eval.md` | T1 + G |
| GOV-2 | aPNTs 铸币权 | `apnts-mint-authority.md` | (a) Safe + renounceFactory；(b) 主网 aPNTs 在 mint 里强制上限（初始上限值待定）；(d) 放到 5.5.x |
| GOV-3 | gas 常数改成治理参数 + buffer 收紧 | `buffer-tightening-eval.md`，实验分支 `exp/buffer-and-params` | 等实验和 Codex 结论 |

### 10.8 独立审计闸门（runbook 新增）

在 **Sepolia 测试（S2）完成之后、OP 主网部署（S3）之前**：

| 步 | 内容 | 验收 |
|---|---|---|
| AUD-1 | 冻结审计 commit，写明范围：SP 5.5.0、xPNTs v2 模板、AOA 工厂、`GlobalTierSource`、lens（如有），以及三个白名单合约 | commit hash 与范围写进 `docs/audit/` |
| AUD-2 | 由**独立的外部审计方**审计（不能由 Slither、Echidna 或 AI 审阅代替，它们只是前置条件） | 报告原文入库 |
| AUD-3 | 修复 commit；有 High 或以上的修复时，必须复审 | **High 及以上全部关闭**，复审结论入库 |
| AUD-4 | OP 主网部署的 commit 必须等于"审计 commit + 已复审的修复" | 部署记录里写明 commit 对应关系 |

### 10.8b R-AMS：Amsterdam（EIP-8037/8038）的前向兼容风险（v3.9，D5 B0 发现）

当前目标链（Sepolia、OP 主网、OP Sepolia）都在 Osaka（证据见 `b-layer/README.md` §0）。一旦 Amsterdam 在某条目标链上激活，EIP-8037（state-gas 计量）和 EIP-8038（state 访问重新定价）会让 SSTORE、SLOAD、CALL 变贵。在 geth 的 Amsterdam 级 dev 链上已经实测到：验证期写一个新槽，会耗尽 100k 的 paymaster 验证 gas。影响如下：
- 验证期写入（锁记录、预留、在途记录，都是从零写成非零）→ `paymasterVerificationGasLimit` 要调高（SDK 侧）。
- **`SETTLE_GAS_BOUND = 160k` 和 `MIN_POST_OP_GAS = 200k` 是写死在字节码里的常量**，可能不够用。不够时 postOp 会 revert，也就是 I10 情形：用户的执行被撤销、没有损失，但赞助不可用。
- **触发条件（可检查）**：任何一条目标链公布了 Amsterdam 的激活时间 → 在 Amsterdam 级的链上重跑 G 层（T-R14-09、no-OOG 扫描、C_WRAP）和 B 层 → 如果常量不够，就通过 SP 的 UUPS 升级下发，并同步更新 SDK 的 gas 取值。
- **上线前检查（runbook 第 0 步的附加项）**：用 `eth_config` 读目标链的 `current` 和 `next` fork（如果链不开放 `eth_config`，就用该链官方公布的升级时间表，外加 opcode 探针）。**`next` 是 Amsterdam，或者已经启用了 EIP-8037/8038，就阻塞上线**，先完成上一条的重测。
- 论文口径：所有测量都注明硬分叉层级（Osaka + BPO2），R-AMS 写进 limitations 和前向风险（DSR 负责）。

### 10.9 Medium

- **B-9**：buffer 带来的用户多付，要在 Sepolia 和 OP 主网上实测（最大值、典型值），写进论文的综合成本表。
- **B-11**：论文里写"AOA 社区在测量区间内 `creditPolicy` 始终为 OFF"，并附测量起点和终点两次链上读回。
- **B-12**：README 的状态文字已更新（见 README）。

## 11. Codex 第 10 轮与实现期发现（v3.8，规范性）

### 11.1 Codex 第 10 轮（结论：修改后通过，没有 Critical）

| # | 发现 | 修订 |
|---|---|---|
| R10-H1 | SP 调 token 结算时还有第二道 EIP-150 的 63/64 转发，`MIN_POST_OP_GAS ≥ 上界 + 开销 + 余量` 在数学上不够严格 | `MIN_POST_OP_GAS ≥ G_pre + G_call + max(⌈64·G_settle/63⌉, G_settle + G_post) + margin`（`G_pre` 是 postOp 在结算调用之前的开销，`G_call` 是这次调用本身的开销，`G_post` 是结算之后的开销）。**T-R14-09 必须经过 EntryPoint，并设 `paymasterPostOpGasLimit == MIN_POST_OP_GAS`，结算要成功** |
| R10-M1 | "执行结果被保留 ⇔ 结算成功"写过头了：`opReverted` 的 op 没有执行结果被保留，但照常结算；I10 的"用户净额 = 0"也写得太宽（nonce 递增、账户验证期写的状态会留下） | §10.1 的双向改为单向，即 **I8：执行结果被保留 ⇒ 已经结算**；I10 改为"stale release 之后，执行的副作用和 token 扣费都为 0"；另补上 `totalSpent += a0` 也会留下 |
| R10-M1b | postOp 回滚时 operator 的 `a0` 被直接记成收入 | **D2 实现在途预留**：validate 时 `operator.aPNTsBalance −= a0`，`inflight[opHash] = (operator, a0)` 写在 SP 自己的存储里（SP 已质押，STO-031），并 TSTORE 一个活标记；postOp 时 `protocolRevenue += c`，`operator += a0 − c`，删掉 inflight；新增 `releaseStaleSponsorship(opHash)`（任何人都能调、幂等、要求活标记为 0），把 `a0` 全额退回 operator。这样也去掉了"退款被 protocolRevenue 截断"的问题（SP `:1397`）。体积按 D4 实测 |
| R10-M2 | §10.2 的表和现有代码不一致（退款被截断；opReverted 行留了空格） | 以在途预留为准重写表格；opReverted 按 BALANCE 和 CREDIT 拆成两行，各自完整写出增减量（D6 补 file:line 时一并完成） |
| R10-M3 | §10.3 buffer 的量纲没写清楚 | `bufWei = (postOpGasLimit + ⌈(callGasLimit + postOpGasLimit)·10/100⌉ + C_WRAP) × actualUserOpFeePerGas`；`c = min(a0, ⌈calc_snap(actualGasCost + bufWei) × (BPS + fee) / BPS⌉)`。**`calc_snap` 用验证时的价格快照**，通过 context 传给 postOp，不在 postOp 里重新读缓存价 |
| R10-M4 | §10.5 的 `SP_REGISTRY` 没有同步到前文 | 实现中 SP 登记在 `AOAProtocolRegistry` 的 `KIND_SP` 下，按地址登记；§2.5 的 S-0 / S-1 / S-3 / S-5 / S-6 一律指这个地址白名单，不再说 codehash；§10.7 补上"S-0 创世不需要 48 h"这个例外 |
| R10-M5 | §10.8 审计闸门没有证明"部署的字节码就是审计过的字节码" | AUD 追加两条：审计 commit 之后**任何**在范围内的代码改动都要审计方复审，未解决的 Medium 要逐条说明处理；部署后核对 SP 实现槽和 runtime codehash、token 模板与克隆的实现地址、两个白名单合约，以及 EntryPoint v0.7 的 runtime codehash，并锁定编译器和依赖版本 |

### 11.2 实现期发现（D1）

1. **单体 token 实测 30,388 B，超过 EIP-170。** 拆成核心（`xPNTsTokenV2`，19,509 B）和扩展（`xPNTsTokenV2Ext`，21,922 B），扩展经 fallback 以 DELEGATECALL 调用；
   存储布局由同一条继承链保证一致，并由 `scripts/check-xpnts-v2-layout.py` 复核。**验证期入口全部在核心合约里。** 以此取代 §5 里 token 的体积估算。
2. **工厂改为接收预先部署好的模板**（EIP-3860：核心和扩展的创建码加起来放不进工厂的构造函数）。部署顺序见 D1-traceability §1。
3. **白名单合约有部署期 bootstrap**：`seal()` 之前 owner 可以即时批准，之后新增批准要走 48 h，撤销即时生效，`seal()` 不可逆。**runbook 第 4 步**改为"部署 → bootstrap → `seal()` → 读回 `sealed_() == true`"，这一步完成之前不得部署工厂，也不得有任何社区发币。**信任矩阵**：`seal()` 之前 owner 对三类白名单是完全信任，之后新增要经过 48 h 公示。
4. **SDK 要合并核心和扩展的 ABI**，因为调用都发往同一个地址。
