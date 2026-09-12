> **⚠️ 规范性内容已迁到 [03-final-spec.md](03-final-spec.md)（v3.0-rc）。本文保留为协商过程的记录（v1 → v2.5）；两者冲突时以 03 为准。**

# 02 · 双方待确认的技术方案（草稿）

> **v2.5（2026-09-12）：作者细化信用模型：在"批准方式"之外增加"额度来源"（全局声誉 / 社区声誉）。SP 的评估见 §8.7（Codex 第 3 轮以 v2.4 为范围，已在进行中；§8.7 另做一轮定向挑战）。**
>
> **v2.4（2026-09-12）：作者新决定（经 DSR 转达）：取消 legacy 分流，RepCredit 也迁到 5.5.0，额度下限 250 aPNTs，D-15 采用 ②′；D-18 = A + B（K = 1）；D-19 = 允许紧急撤到 0。SP 的评估见 §8，它优先于前文中与 legacy/tokenGen 相关的写法。**
>
> **v2.3（2026-09-12）：并入 Codex 第 2 轮（结论：修改后通过，但还不能开始实现；新增 1 Critical / 4 High / 4 Medium），新增规范性修订集中在 §2.9；已按第 2 轮 N-L1 同步修正前文中过时的写法。待作者决定的新增 3 项见 §7 D-18…D-20。**
>
> **v2.2（2026-09-12）：并入 Codex 第 1 轮对抗挑战（1 Critical 已并入修订 / 1 Critical 否决 T-post / 6 High / 5 Medium），规范性修订集中在 §2.8，它优先于本文其他段落中与之冲突的写法。续期方案新增"账户在验证阶段自己续期"（D-16），等作者选择。**
>
> **状态：v2.1（2026-09-12），双方没有剩余的技术分歧，由 DSR 整理定稿交作者 review。** 待作者确认 4 项：D-4 各链下限取值、D-9 bundler 选型、D-13 的 K、D-15 选 ①/②′。
> v2.1：D-13 补充 UX 代价与 SDK 中继恢复路径、§2.6 增加"耗尽 renew 次数"一行、§2.3 写明 `allowance()` 不再对 SP 特殊处理。
>
> v2：已并入 DSR 对 D-1…D-12 的回复和 5 条补充。
> v2 的变化：新增 D-13（R1 续期限次）、D-14（收窄 SP 在 token 上的权限面）、D-15（急停后换 SP 的选项②′）、§2.3 验证期访问清单、§2.6 恶意 SP 损失上界、I6；修订 I1/I2、§5 S3、§6 A 层和 B 层。
>
> v1 状态：SP 侧草稿，等 DSR 回应。 与 DSR §9 有分歧的地方，在文中标为 **【D-n】**，
> 并汇总在文末 §7。双方一致后由 DSR 定稿交作者 review。作者确认之前不实现。

## 1. 总体结构

```
                 ┌──────────────── SuperPaymaster 5.5.0 (UUPS, 原地升级) ───────────────┐
 validate ──►    │ operator.tokenGen == 0 (legacy) ──► 现有代码, 一字不改 (RepCredit 走这条) │
                 │ operator.tokenGen == 1 (v2)     ──► tryLockForGas ─OK─► BALANCE            │
                 │                                    └─INSUFFICIENT─► 信用预留成功 ? CREDIT : 拒绝;其余结果一律拒绝 │
 postOp  ──►     │ BALANCE: settleLocked (try/catch; catch → SponsorshipUnbacked + isBlocked)     │
                 │ CREDIT : 现有 _recordDebt                                                 │
                 └──────────────────────────────────────────────────────────────────────────────┘
                        │ 只读/只写"与 sender 关联"的槽
                 ┌──────▼──────── xPNTsToken v2 (新模板, 由 AOA 工厂克隆) ─────────────────────┐
                 │ 有界免授权额度 (X1/X2)  锁定与结算 (X3)  spender timelock + codehash (X4/X5)    │
                 │ 用户级信用授权 (X7)     _update 锁定检查                                        │
                 └──────────────────────────────────────────────────────────────────────────────┘
 dryRun ──► SuperPaymasterLens (新, 无状态, 不可升级)  ← F1, 从 SP 移出
```

与 DSR §9 的主要差别：

- **legacy 路径保留【D-1】**：代替 Q8① 的"批量写授权"，因为那一步在旧克隆上不可行。
- **续期走 `paymasterAndData`【D-2】**：代替"在 validate 里校验 1271"。
- **单笔锁定记录 + 悬挂释放【D-3】**：DSR 清单里没有这一项。

## 2. xPNTsToken v2（新模板）

版本号建议为 `XPNTs-4.0.0`（接口与语义都有破坏性变化）。它是新合约（从 3.5.0 分叉），克隆
没有升级问题；为了复用代码，存储沿用 3.5.0 的前缀，新增变量追加在后面。

### 2.1 新增存储

所有在**验证期写入**的槽，用户都在**最内层**键，从而与 sender 关联（见 01 §5 ②）。

```solidity
struct AutoAllowance { uint128 used; uint120 cap; bool set; } // aPNTs 计价; !set → 取默认值
struct UserBudget    { uint128 used; uint120 cap; bool set; } // 每用户跨 spender 总额 (Q6)
struct LockRecord    { uint128 xLocked; uint128 aReserved; address locker; } // 单笔：锁定量、预留额度、加锁的 SP（§2.8 R-5）

mapping(address spender => mapping(address user => AutoAllowance)) internal _auto;   // X1
mapping(address user => UserBudget)                                 internal _budget; // X1/Q6
mapping(address user => uint256)                                    public   lockedOf; // X3 汇总
mapping(bytes32 opHash => mapping(address user => LockRecord))      internal _locks;   // X3 单笔 【D-3】
mapping(address user => uint256)                                    public   creditLimitOf; // X7, aPNTs, 0=未获批
mapping(address user => uint256)                                    public   allowanceNonce; // R2 签名
mapping(address spender => uint64)                                  public   spenderActivatesAt; // X4
mapping(address user => uint8)                                      public   autoRenewUsed;      // D-13：已由 SP 触发的续期次数（默认 0 = 未用，§2.8 R-4）
mapping(address user => bool)                                       public   creditOptIn;        // 用户本人的信用申请（§2.8 R-7）
address public standbySP; uint64 public standbyActivatesAt;                                        // D-15 ②′（若作者选②′）
```

模板 immutable（克隆通过 delegatecall 共享；由工厂在部署模板时写入，**按链设定**）：

| immutable | 含义 | 说明 |
|---|---|---|
| `SP_DEFAULT_CAP` | SP 默认额度，5,000 aPNTs | Q5 |
| `SP_CAP_FLOOR` | SP 额度下限 | Q4 定的是 50 aPNTs。**【D-4】必须 ≥ 目标链单笔最大预留额**，否则用户会卡在下限（见 01 §8 g-3） |
| `PROTOCOL_MAX_CAP` | 用户可调上限的封顶值 | DSR 建议 $1,000 |
| `SPENDER_REGISTRY` | codehash 白名单来源 | X5；不从 `FACTORY` 读，因为 `renounceFactory` 之后它会变成 0 |
| `SPENDER_TIMELOCK` | 48 h | X4 |

### 2.2 接口

```solidity
interface IxPNTsTokenV2 {
    // —— 探测：SP 在 configureOperator 时调用一次（不在验证期） ——
    function BALANCE_MODE_VERSION() external pure returns (uint16); // = 1

    // —— X3：只允许 SP 调用 ——
    /// 验证期调用。不 revert，返回 LockResult；只有 INSUFFICIENT 允许 SP 转向信用分支（§2.8 R-2）。
    /// 禁止：nonReentrant、TIMESTAMP/NUMBER、写任何全局槽。
    function tryLockForGas(address user, bytes32 opHash, uint256 reserveAPNTs, bool renew)
        external returns (LockResult r, uint256 xLocked);
    /// 信用预留（§2.9 R-10）：验证期调用，与锁定对称；postOp 用 settleCredit 把预留转成债务
    function tryReserveCredit(address user, bytes32 opHash, uint256 aPNTs) external returns (bool ok);
    function settleCredit(address user, bytes32 opHash, uint256 chargeAPNTs) external;
    /// 方案 A：账户在自己的验证阶段调用，只访问与 msg.sender 关联的槽（§2.9 R-11）
    function renewForSelf(address spender) external;
    function setRenewalMode(uint8 mode) external;              // 用户本人：SP_K / ACCOUNT_ONLY
    function disableSpenderForSelf(address spender) external;  // 用户紧急开关（§2.9 R-13，与 Q4 冲突，待作者定）
    /// postOp 调用。按锁定时的比例换算：xCharge = min(xLocked, ceil(charge * xLocked / aReserved))；
    /// 先减 lockedOf，再 _burn；已用额度按 (aReserved - charge) 退回；写 usedOpHashes[opHash]。
    function settleLocked(address user, bytes32 opHash, uint256 chargeAPNTs) external returns (uint256 xBurned);
    /// 悬挂释放，见 §2.4
    function releaseStaleLock(address user, bytes32 opHash) external;

    // —— X1/X2：有界免授权额度 ——
    function autoAllowance(address user, address spender) external view returns (uint256 cap, uint256 used);
    function setAutoAllowance(address spender, uint256 capAPNTs) external;           // R2，用户直接调用
    function setUserTotalCap(uint256 capAPNTs) external;                              // Q6
    function setAutoAllowanceBySig(address user, address spender, uint256 capAPNTs, uint256 totalCapAPNTs,
        uint256 deadline, bytes calldata sig) external;                               // R2：ECDSA + ERC-1271，验证期之外

    // —— X4/X5：spender 管理 ——
    function proposeSpender(address spender) external;   // communityOwner；开始计时
    function activateSpender(address spender) external;  // 到期后；此时检查 codehash ∈ SPENDER_REGISTRY
    function removeAutoApprovedSpender(address spender) external; // 即时生效（与现有一致）
    // setSuperPaymasterAddress 同样改为 propose / activate 两步；急停即时生效

    // —— X7：用户级信用 ——
    function requestCredit(uint256 maxCapAPNTs) external;               // 用户本人申请并给出上限（R2 签名版同理），写入存储（§2.9 R-12）
    function approveCredit(address user, uint256 limitAPNTs) external;   // communityOwner（多签作为部署约束）
    function revokeCredit(address user) external;
}
```

### 2.3 规则

| 规则 | 内容 |
|---|---|
| `_update` 锁定检查 | 对 `from != 0`，要求 `balanceOf(from) - value ≥ lockedOf[from]`。mint 自动抵债、CC-28 都不冲突（01 §6） |
| 额度的扣减面 | 自动额度同时约束 `transferFrom`、`burn(address,uint256)` 和 SP 锁定路径。只要显式 `approve` 足够就优先用显式 approve【D-5】 |
| `allowance()` | 名单内 spender 返回 `显式 approve + 自动额度剩余`（折算成 xPNTs），不再返回 `uint256.max`。**接口注释要写明**：显示值按**实时**汇率折算，而 SP 结算按**锁定时**的比例（D-12），两者可能有汇率差，钱包不能把显示值当作结算承诺 |
| 锁定时预留额度 | `tryLockForGas`：`used += reserve`（按 spender 和总额分别计）；`settleLocked`：`used -= (reserve - charge)`。所以额度最终按实际费用消耗，但验证期就已经保证结算不会超额 |
| 续期 R1【D-13，v2 修订】 | `renew = true` 时，在预留之前把 `_auto[SP][user].used` 和 `_budget[user].used` 清零，同时 `autoRenewUsed[user] += 1`。`autoRenewUsed ≥ K` 时拒绝 renew，只有用户本人通过 R2（直接交易或签名）才能把它重置为 0（§2.8 R-4）；K 由用户设定（v2.3：K = 1、K_MAX = 1，§2.9）。只能清零，不能调高上限。**为什么要限次**：token 无法验证 renew 标志是否真的来自用户签过的 UserOp，它只能相信 SP。如果 SP 的 impl 被换成恶意实现，不限次的 renew 能无限次清零额度，I2 就不成立了（见 §2.6）。**UX 代价**：`autoRenewUsed ≥ K` 且额度用满时，用户**无法再通过 SP 发 UserOp 去做 R2**（验证期锁不到钱），恢复路径只有两条：① 用户自付 ETH 发一笔 R2；② **SDK 标准恢复路径**：钱包收集用户的 `setAutoAllowanceBySig` 签名，由社区或中继代为提交（中继付 ETH）。R2 同时把 `used` 和 `autoRenewUsed` 都清零。K 推荐取 1（恶意 SP 下的上界 = 2 × cap ≈ $200；正常用户要花满约 $200 的 gas 才会走到中继恢复），由作者定 |
| SP 的权限面【D-14，v2 新增】 | ① **SP 不再是 `transferFrom` 的名单内 spender**：v2 的 gas 路径只用锁定和结算，不需要转账；aPNTs 存款是另一枚代币。② v2 的 `burnFromWithOpHash`（保留给获批信用用户的 postOp）**同样消耗 `_auto[SP][user]` 和 `_budget[user]`**。③ v2 的 `recordDebtWithOpHash` 在 token 内部检查 `creditLimitOf[user] > 0` 且 `debts[user] + amount ≤ creditLimitOf[user]`，不能只依赖 SP 的检查。④ `burn(address,uint256)` 对 SP 仍然禁止（现状，`xPNTsToken.sol:1080`） |
| 急停 | `tryLockForGas` 返回 `EMERGENCY`（不进信用分支）；`settleLocked` 对已存在的锁照常结算（只能烧不超过预留额的钱）；`releaseStaleLock` 照常可用 |
| 单笔上限（S2） | `reserve > maxSingleTxLimit` 时 `tryLockForGas` 返回 false |
| 工厂 | 初始化时不再把工厂加入名单（X6） |
| `allowance()` 与 SP | D-14 ① 之后，SP 不在 v2 token 的任何名单里，`allowance(user, SP)` 就是标准 ERC-20 语义（只反映显式 approve），**不再对 SP 做任何特殊处理**。SP 在锁定路径上的额度通过 `autoAllowance(user, SP)` 查询 |
| 其他 spender | 默认额度 0，用户通过 R2 开通（Q5）。`X402Facilitator` 因此需要用户先开通才能用（DSR §7 已记录这个产品影响） |
| 急停后换 SP【D-15】 | 见 §2.7 |

**验证期访问清单**（B 层测试逐项确认；除这里列出的槽之外，`tryLockForGas` 不得访问 token 的其他任何槽）：

| 访问 | 槽 | 关联关系 | 依赖的规则 |
|---|---|---|---|
| 读 | `SUPERPAYMASTER_ADDRESS`、`emergencyDisabled`、`exchangeRate`、`maxSingleTxLimit` | 非关联 | STO-033（只读，要求 SP 已质押） |
| 读 | 模板 immutable（`SP_DEFAULT_CAP` 等） | 代码，不是存储 | — |
| 读 | `_balances[user]`、`creditLimitOf[user]` | 关联 user | STO-021 |
| 读写 | `lockedOf[user]`、`_auto[SP][user]`、`_budget[user]`、`_locks[opHash][user]`、`autoRenewUsed[user]` | 关联 user（用户在最内层） | STO-021 |
| TSTORE | 活锁标记 `keccak(user ‖ keccak(opHash ‖ SEED))` | 关联 user | 同 STO-021（以 bundler 实测为准） |
| 禁止 | `_reentrancyStatus`、`usedOpHashes`、`usedDebtHashes`、`spenderRateLimit`、任何 `total*` 计数器；TIMESTAMP、NUMBER | — | — |

### 2.4 锁定悬挂与释放【D-3】

**场景**：postOp 首次回滚（比如耗尽 gas）时，EntryPoint 不会再调用 paymaster。`_locks` 和
`lockedOf` 就会留下来，用户的这部分余额被永久冻结。

**约束**：释放**不能在同一笔交易里被调用**。否则用户可以在自己的执行阶段先释放锁，再把钱
转走，也就是换一种方式的自抽干。

**方案（推荐）**：`tryLockForGas` 在锁定的同时用 TSTORE 写一个活锁标记，槽为
`keccak(user ‖ keccak(opHash ‖ SEED))`，用户在最内层，是关联槽。`releaseStaleLock` 要求该
标记为 0：同一交易内标记一直存在，所以用户在执行阶段调不了；交易结束后 transient storage
自动清空，此时如果锁还在，就一定是 postOp 没有完成结算。释放方式是**解锁、全额退回用户**，
损失由 operator 承担，与 `SponsorshipUnbacked` 的语义一致。

为什么退回用户是对的：EntryPoint v0.7 的 postOp 是在 `innerHandleOp` 帧**内部**调用的；postOp
回滚会以 `PostOpRevertReason` 让整个 inner 帧回滚，**用户这笔的执行结果也一起被撤销**，之后
EntryPoint 按 `postOpReverted` 向 paymaster 收 gas。锁是在验证期（inner 帧之外）写入的，所以
留了下来。也就是说，用户这笔什么也没得到，退回锁定额正好。即使用户故意把
`paymasterPostOpGasLimit` 压在下限，想让 postOp 耗尽 gas，也只能让自己的执行被撤销，拿不到
任何好处；对 operator 而言，这只是一种耗 gas 的骚扰，今天的代码里就已经存在。

**附带要求**：`MIN_POST_OP_GAS`（现在是 200,000）必须 ≥ v2 postOp 最坏路径的实测 gas，并留出
余量，要有专门的测试守住这一点。否则"postOp 回滚"会从罕见的 bug 变成用户随手就能触发的常规
路径，悬挂释放也会被大量使用。

**备选**（如果目标 bundler 不接受验证期的 TSTORE）：`releaseStaleLock` 只允许
`communityOwner` 调用，并写进信任矩阵。

### 2.5 不变量（替代并细化 DSR §3.6）

| # | 不变量 |
|---|---|
| I1 | 用户 xPNTs 余额的减少只可能来自：① 用户本人发起的交易；② `settleLocked` 按 `min(锁定额, 按锁定比例折算的 charge)` 烧币；③ 名单内 spender 在额度内经 `transferFrom`、`burn(address,uint256)` 扣减；④ 获批信用用户的 `burnFromWithOpHash`（同样计入额度）；⑤ mint 时的自动抵债（只对有债务的用户） |
| I2 | 对任意 (user, spender)：自上次续期以来经 `transferFrom`、`burn(address,uint256)`、`settleLocked`、`burnFromWithOpHash` 的累计扣减 ≤ cap（`transferAndCall` 由用户本人发起，不计入 spender 额度，但同样受 `_update` 锁定检查约束）；各 spender 的累计之和 ≤ 用户总额上限；用户两次亲自操作之间，renew 的次数 ≤ K |
| I3 | `creditLimitOf[user] == 0` 的 v2 用户：`getDebt(user)` 和 `SP.pendingDebts[token][user]` 永远不增加 |
| I4（新） | 每笔交易结束时：`lockedOf[user] == Σ _locks[·][user].xLocked`，而且 `balanceOf(user) ≥ lockedOf[user]` |
| I5（新） | legacy operator：对相同输入，5.5.0 与 5.4.2 的状态转移逐项相同（差分测试） |
| I6（新，量化 D-7；v2.2 按 §2.8 R-6 修订） | SP impl 被替换成任意恶意实现、且不经过任何用户 UserOp 时，每个 v2 用户（**以 aPNTs 计的额度量**）：被结算的 aPNTs 等值 ≤ `min(剩余 SP 额度 + K × SP cap, 剩余总额 + K × 总额上限)`；被烧掉的 xPNTs ≤ `min(余额, Σ ceil(aCharge_i × lockedRate_i / 1e18))`；被记的新债 ≤ 用户本人授权的信用额度；被转走（而非烧掉）的 xPNTs = 0。**范围**：这是 token 侧的上界；恶意 SP 对自己的存储（`pendingDebts`、`isBlocked`）、EntryPoint 存款和 operator 资金的影响不在此列 |

### 2.6 恶意 SP 的损失上界（D-7 的量化，对应 I6）

恶意 SP 能调用的 token 入口（v2.3 修正：列全所有继承下来的公开 selector）：`tryLockForGas`、`settleLocked`、`tryReserveCredit`、`settleCredit`、`burnFromWithOpHash`、**无 hash 的 `recordDebt`**、
`recordDebtWithOpHash`，另外还能调 `releaseStaleLock`。

| 攻击 | 按 v1 草稿 | 按 v2（D-13/D-14） |
|---|---|---|
| 用伪造的 opHash 反复 lock + settle | 每次都消耗额度，上界 = 剩余额度 | 同左 |
| 每次都带 `renew = true` | **无上界**：额度被无限次清零 | 最多再清零 K 次 |
| 直接调 `burnFromWithOpHash` | **无上界**：不计入额度，只受单笔上限约束 | 计入额度，与上面合并计算 |
| 直接调**无 hash 的** `recordDebt` 记假债（Codex C-1） | **无上界**（3.5.0 的公开函数，只查单笔上限，`xPNTsToken.sol:528`） | 与下一行同样受限（§2.8 R-1） |
| 直接调 `recordDebtWithOpHash` 记假债 | **无上界**（token 内不检查额度），日后 mint 时自动抵债 | ≤ `creditLimitOf[user]`；未获批用户为 0 |
| `transferFrom` 转给自己 | 若 SP 仍在名单里，额度被清零后可以反复转走 | 不可能：v2 的 `transferFrom` 对 `msg.sender == SP` 直接拒绝，**包括用户显式 approve 过的额度**（Codex H-2，§2.8 R-3） |
| 故意把 renew 次数用光，让用户提前进入"必须走中继恢复"的状态 | 不适用（v1 不限次） | 可恢复的骚扰，没有资金损失：用户按 §2.3 的恢复路径②恢复 |
| lock 之后不结算，冻结用户余额 | 冻结到有人调 `releaseStaleLock` | 同左：交易结束后任何人都能释放，全额退回 |

结论：v2 下，恶意 SP 对每个用户的影响**限于销毁**（得不到任何代币），上界是
`(剩余额度 + K × cap)`，并同时受总额上限约束。这正是论文信任矩阵里 SP 升级权那一行要引用的数字。

### 2.7 急停后换 SP【D-15】

DSR 的选项②："急停后允许立即换回一个曾经激活过、codehash 在白名单里的 SP"。**这个写法会
重新打开攻击面**，有两点：

1. SP 是 UUPS 代理，"曾经激活过的地址"并不代表"那份代码"。它的 impl 可能已经被换过，
   codehash 也还是一样（01 X5）。
2. 急停由 community owner 发起。如果 owner 本身被盗，他可以先急停，再"立即换回"一个已经
   退役、有已知缺陷的旧 SP，从而绕过 48 h timelock。

**可行的改法 ②′：预登记备用 SP。** token 增加 `standbySP` 槽：**指定**备用 SP 本身要走
48 h 的 propose/activate 流程（与新增 spender 相同）。急停之后，只能**立即**切到当前的
`standbySP`，而且它不能等于 `emergencyRevokedAddress`（现有规则）。切换到任何其他地址仍然
要等 48 h。这样，立即切换的目标一定是 48 h 前就公开过、可以被监控的地址，没有引入 timelock
之外的新路径。新 SP 的每用户额度会从默认 cap 开始计，但 `_budget[user]` 是跨 spender 共享的，
所以总额上限仍然有效。实现成本：token 多两个槽、约 200 B，token 的余量足够。

选①还是②′，由作者决定。

### 2.8 Codex 第 1 轮挑战后的规范性修订（v2.2）

Codex 对 D-13 续期设计和 §2–§3 做了一轮对抗挑战。以下各项已由 SP 侧逐条对照源码复核，**全部成立**，
作为规范性修订，优先于本文其他段落中与之冲突的写法。

| # | Codex 发现 | 修订 |
|---|---|---|
| R-1 | **C-1（Critical）**：3.5.0 的公开函数 `recordDebt(user, amount)`（无 hash，`xPNTsToken.sol:528`）在 v2 里仍然存在，只检查单笔上限；`retryPendingDebt` 就在调用它（SP `:1515`）。恶意 SP 可以用它给任意用户无限记债，日后 mint 时被自动烧掉，I6 不成立 | v2 里 `recordDebt` 和 `recordDebtWithOpHash` **都**在 token 内检查信用授权（R-7）和累计上限。对抗测试覆盖**所有**继承下来、SP 能调用的公开 selector，而不只是新接口 |
| R-2 | **H-1**：`tryLockForGas` 返回 false 就转去信用分支，会把急停、超单笔上限、续期无效、锁冲突都当成"余额不够"；急停时获批信用用户仍然会被放行，operator 继续垫付 | `tryLockForGas` 返回枚举 `LockResult { OK, INSUFFICIENT, EMERGENCY, SINGLE_TX_LIMIT, INVALID_RENEWAL, CONFLICTING_LOCK }`。**只有 `INSUFFICIENT` 可以转去信用分支**，其余一律让验证失败。信用分支同样在验证期检查单笔上限（§3.3 已改） |
| R-3 | **H-2**：SP 移出名单之后，`transferFrom` 会走标准 ERC-20 allowance。用户如果显式 approve 过 SP，恶意 SP 可以把这部分额度转给任意地址，"转走 = 0"不成立 | v2 的 `transferFrom` 对 `msg.sender == 当前 SP 或任何历史 SP` 直接拒绝，**不论是否有显式 approve** |
| R-4 | **H-3**：续期把 `used` 清零后，续期之前的锁如果之后结算或释放，会把旧的预留额退到新一期的额度里（可能下溢、错误释放额度，I2 难以证明）。另外 `autoRenewLeft` 的默认值 0 同时表示"默认 K"和"已用完"，语义冲突 | **`lockedOf[user] != 0` 时禁止续期**（返回 `INVALID_RENEWAL`）。这是最简单的做法；如果以后要支持并发，改为给每个锁记录额度期号（epoch）。计数改为 `autoRenewUsed`：默认 0 表示未用，`autoRenewUsed < K` 时才允许续期，R2 把它重置为 0 |
| R-5 | **H-4**：锁定之后、结算之前，如果 SP 地址被轮换（community owner 自己的 UserOp 在执行阶段就可以轮换），原来的 SP 就无法结算，同一 bundle 里后面那些已经通过验证的用户都会结算失败 | `LockRecord.locker` 记录加锁的 SP，**它对这一把锁保留仅限结算的权限**，不论之后 SP 是否被移除或因急停被换掉；它不再有加锁、续期、转账、记债的权限 |
| R-6 | **H-5**：I6 把 xPNTs 的烧毁量和 aPNTs 计价的额度直接比较，量纲错了；"(1+K)×cap"只在额度初始是满的、余额足够、总额上限 ≥ SP 上限、每把锁都按全额结算时才是紧的。攻击开始时额度已用完的话，额外损失是 K×cap | I6 改写为以 aPNTs 计的额度上界，另附 xPNTs 换算式（§2.5 已改）；论文里的美元数字要注明它依赖 aPNTs 定价和汇率治理（community owner 可以在上下限内调整 `exchangeRate`） |
| R-7 | **H-6**：`approveCredit` 只由 community owner 调用，不需要用户同意。恶意 owner 加恶意 SP，就能给任意用户开信用并记假债；owner 事后调低额度时，`debts ≤ creditLimitOf` 也不再成立 | 信用必须**用户本人申请**：`requestCredit()` 写入 `creditOptIn[user] = true`（R2 同样支持签名方式），`approveCredit` 只对已申请的用户生效。撤销只阻止新增债务，不假装旧债消失；不变量写成"新增债务 ≤ 授权时的额度"。恶意 SP 的暴露面 = 额度暴露 + 用户本人授权的信用暴露，两者分开披露 |
| R-8 | **M-5**：§3.4 的 buffer 把整个 `postOpGasLimit` 都算进去，而 EntryPoint 对未用的 postOp gas 只罚 10%，所以这是一个安全的上界，但会系统性地多收 | 保留为安全上界，论文如实报告多收的规模；实现时考虑在 postOp 入口记录 `gasleft()` 快照，测出 postOp 自身的实耗，再加上可证明的 wrapper 上界，从而收紧 |
| R-9 | **C-2（Critical，针对 T-post）**：EntryPoint 先验证完所有 op 再执行，所以"结算时才验签"会让同一账户在一个 bundle 里的多笔 op 都按"待验证的续期"通过验证；恶意 bundler 不必遵守 mempool 的数量限制，损失不止一笔 | **否决 T-post** |

**续期方案（D-16，等作者选择）**

| 方案 | 做法 | 常见交易的额外 gas | 续期那一笔的额外 gas | 安全性 | 评价 |
|---|---|---|---|---|---|
| **A 账户自己续期（Codex 推荐）** | 带续期标志时，AirAccount 在自己的 `validateUserOp` 里先按正常的签名策略验证，然后直接调用 token 的 `renewForSelf(spender)`。token 看到 `msg.sender == user`，是用户本人的授权。账户验证先于 paymaster 验证（EntryPoint `:642` → `:662`），所以同一笔 op 就能用上新额度；如果之后签名或 nonce 失败，整个交易回滚 | ≈ 0（SP 热路径不变） | 约 10–35k | **不需要 K**；恶意 SP 伪造不了；session key 能不能续期由账户的策略决定 | 最好。需要改 AirAccount，要在 airaccount-contract 仓库开 issue（本仓库不向别人的仓库提 PR）。`renewForSelf` 只能写与该用户关联的槽，不能读 `SUPERPAYMASTER_ADDRESS` 这种全局槽（账户是未质押实体），spender 由调用方显式传入 |
| **B 只用 K（兜底）** | R1 由 SP 转述续期标志，K = 1，`K_MAX` 上线时也取 1 | 约 100–500 | 约 5–20k | 恶意 SP 下每用户多出 K×cap（aPNTs 等值） | 最便宜，适合不配合改造的账户 |
| C token 用 ECDSA 验证续期签名 | 用户另外配置一把 secp256k1 续期密钥，token 在验证期用 `ecrecover`（不对 EOA 做 EXTCODE* 探测） | 约 100–500 | 约 10–30k | 不需要 K | 可行，但要多管理一把密钥 |
| D token 用 ERC-1271 验证 | 在验证期调用账户的 `isValidSignature` | 约 100–500 | 约 15–150k 以上 | 不需要 K | 只能针对**测试过的**账户实现支持；签名放在 `paymasterAndData` 里还有 hash 循环依赖的问题（Codex M-3） |
| E 结算时验签（T-post） | — | — | — | 见 R-9 | **否决** |

**SP 侧的建议组合**：**A + B**。AirAccount 用方案 A（不需要 K、最省 gas、安全性最好）；其他账户兜底用 B（K = 1）。
token 两个接口都提供。**v2.3 更正**：SP 需要少量改动，要把两种续期标志分开（§2.9 R-11）。

### 2.9 Codex 第 2 轮后的规范性修订（v2.3）

第 2 轮结论：修改后通过，但**在下面这些项写清楚之前不能开始实现**。SP 已逐条复核：N-C1、N-H1、N-H2、N-H3
均成立；N-H4 成立，但它的修法与作者的 Q4 决议冲突，交作者定。

| # | Codex 发现 | 修订 |
|---|---|---|
| R-10 | **N-C1（Critical）**：信用路径在验证期只读 `debt + pending + 本次 ≤ 额度`，**不做预留**。EntryPoint 先验证完整个 bundle 再执行，所以同一用户的 N 笔信用 op 看到的都是同一个值，全部通过，超出额度。**注意：现有 legacy 代码也有同样的问题**（`_creditExceeded`，SP `:832`，只在 postOp 写 `pendingDebts`，`:1490`），超出的部分进入 `pendingDebts` 并置 `isBlocked` | token 侧新增**验证期信用预留**，与锁定对称：`tryReserveCredit(user, opHash, a)` 检查 `debts + creditReservedOf + a ≤ 有效额度`，写入 `creditReservedOf[user]` 和 `_creditRes[opHash][user]{amount, locker}`（都是关联槽）；postOp 的 `settleCredit` 最多把这笔预留转成债务。调低或撤销额度只阻止新的预留，已经准入的预留照常结算。悬挂预留的释放方式与锁相同。**legacy 的这个缺陷如实写进 RepCredit/AOA 的信任矩阵**，legacy 代码不改（D-1） |
| R-11 | **N-H1**：A+B 按原写法，AirAccount 用户仍然可以被恶意 SP 走 B 路径续期；而且 A 每次重置 `autoRenewUsed`，等于不断给恶意 SP 补充续期次数 | 每用户增加 `renewalMode ∈ {SP_K, ACCOUNT_ONLY}`（关联槽）。`ACCOUNT_ONLY` 下，SP 发起的 renew 一律返回 `INVALID_RENEWAL`。模式只能由用户本人切换，SP 的转述不能切回 `SP_K`。`paymasterAndData` 拆成两个标志位：`ACCOUNT_RENEW`（只由 AirAccount 读取并处理）和 `SP_RENEW`（SP 只把这一位传给 `tryLockForGas`）。**SP 因此需要少量改动** |
| R-12 | **N-H3**：布尔型的 `creditOptIn` 没有授权金额，恶意 owner 可以在用户申请之后批到全局分档的最大值 | 用户申请时给出上限：`requestCredit(maxCap)`。有效额度 = `min(用户申请上限, owner 批准额度, 协议上限, 全局分档)`。撤销只针对新增预留 |
| R-13 | **N-H4**：transient 标记只能阻止同一交易内的释放，挡不住"释放后又被恶意 SP 立刻锁上"的循环，恶意 SP 可以让 `lockedOf` 几乎一直不为 0，从而一直挡住续期 | Codex 建议：给用户一个**立即生效的每 spender 开关** `disableSpenderForSelf`，并提供原子的 `releaseAndDisable`。**这与作者的 Q4 决议（SP 额度最低 $1、不能撤到 0）冲突**，交作者定（D-19）。不加开关的话，要把"恶意 owner + 恶意 SP 可以造成可用性骚扰"写成信任假设 |
| R-14 | **N-H2**：按 R-5，原 locker 保留结算权；在原交易结束之后（例如 postOp 回滚、用户执行被撤销的情况），被攻破的前任 SP 可以抢在 `releaseStaleLock` 之前按全额结算 | `settleLocked` 同时要求：`msg.sender == lock.locker`；**该 (user, opHash) 的 transient 活锁标记仍为 1（即仍在原交易内）**；charge ≤ `aReserved`，xBurn ≤ `xLocked`；先删除锁记录并减 `lockedOf`，再烧币；额度退回记在 `_auto[lock.locker][user]` 上。标记清零之后，只允许 stale release |
| R-15 | **N-M1**：R-3 的"历史 SP"需要明确的生命周期 | `mapping(address => bool) historicalSP`：只在某个地址**真正获得**加锁权限时置位（包括初始 SP、每次提升的 standby/当前 SP）；只是被提议的候选不置位；不维护链上数组，用事件枚举。历史 SP 的地址以后永远不能再用 `transferFrom`（向它转账不受影响；aPNTs 是另一枚代币，不受影响）；记录的是代理地址。协议承诺不会复用这些地址 |
| R-16 | **N-M2**：R-4（有锁时禁止续期）会让某些诚实的同一 bundle 多 op 排列失败 | 写明支持的策略：同一 sender 在一个 bundle 里最多一笔续期，而且必须排在第一笔；不兼容的组合由 SDK/bundler 拆到不同 bundle |
| R-17 | **N-M4**：R-8 的保守计费 | 论文称之为"保守报价上限"，不能称为精确的 gas 报销；报告多收的最大值和实测典型值；`charge ≤ aReserved` 作为不变量；`C_WRAP` 由 trace 推导并注明余量 |

**第 2 轮对方案 A 在 ERC-7562 上的结论**：对已部署的账户可行。账户帧写外部 token 里与该账户关联的槽，受
STO-021 允许。`renewForSelf` 只能访问 `lockedOf[me]`、`_auto[spender][me]`、`_budget[me]`、`renewalMode[me]`、
`autoRenewUsed[me]`；**不能读** `SUPERPAYMASTER_ADDRESS`、`historicalSP[spender]`、`emergencyDisabled`、
`exchangeRate`、`maxSingleTxLimit` 等全局槽，因为账户是未质押实体，没有 STO-033 的只读特权。`spender`
在 token 层可以是任意非零地址（用户只能改自己的额度）；AirAccount 侧要求它等于签名覆盖的
`paymasterAndData` 里的 paymaster，而且 session key 能不能续期要由账户策略显式决定。带 initCode 的首笔交易
要求 factory 已质押（STO-022）。续期那一笔多出的 gas 约 15–35k（首次写入零值槽约 30–55k），计入账户的
`verificationGasLimit`。

## 3. SuperPaymaster 5.5.0

### 3.1 存储

**只新增一个字段**：`OperatorConfig` slot 0 的 byte 18 放 `uint8 tokenGen`。

- 不新增 slot，不移动任何现有字段，`__gap` 不变。
- 0 = legacy 是升级安全的方向（01 §2 S1）。已实测 Sepolia 两个存量 operator 的 byte 18–31
  都是 0。
- 在 `configureOperator` 里用 try/catch 调 `BALANCE_MODE_VERSION()` 探测并写入。旧代币没有这个
  函数，调用会 revert，结果就是 `tokenGen = 0`。

### 3.2 `paymasterAndData` 与 context

```
paymasterAndData: [paymaster 20][verifGas 16][postOpGas 16][operator 20][maxRate 32][flags 1]
                                                                                  └ offset 104, 可选；bit0 = renew (R1)
legacy context (160 B, 不变): (token, user, aPNTsAmount, userOpHash, operator)
v2 context (256 B):           (token, user, aPNTsAmount, userOpHash, operator, mode, callGasLimit, postOpGasLimit)
```

postOp 按 **context 长度**分流：长度等于 160 就走 legacy 分支，一行都不改。

### 3.3 validate（v2 分支，伪代码）

```solidity
// 前面的检查全部不变：isConfigured / isPaused / 身份 / MIN_POST_OP_GAS / isBlocked / validAfter / maxRate；
// aPNTsAmount 的算法也不变 = calc(maxCost) × (1 + fee + VALIDATION_BUFFER)
if (config.tokenGen == 0) { /* 现有 _creditExceeded + 偿付检查 + 返回 legacy context */ }
else {
    if (uint256(config.aPNTsBalance) < aPNTsAmount) return sigFail;   // operator 偿付能力：先检查，再锁定
    bool renew = pmd.length > 104 && (uint8(pmd[104]) & 1) == 1;
    LockResult r = IxPNTsTokenV2(token).tryLockForGas(sender, userOpHash, aPNTsAmount, renew);
    uint8 mode = MODE_BALANCE;
    if (r != LockResult.OK) {
        if (r != LockResult.INSUFFICIENT) return sigFail;              // 急停、超单笔上限、续期无效、锁冲突：一律拒绝，不进信用（§2.8 R-2）
        uint256 lim = IxPNTsTokenV2(token).creditLimitOf(sender);     // 关联槽
        if (lim == 0) return sigFail;                                   // I3：未获批用户永远进不了信用分支
        if (_creditExceeded(token, sender, aPNTsAmount) ||             // 全局分档
            debt + pending + aPNTsAmount > lim) return sigFail;         // 与社区批准额度取较小者
        if (aPNTsAmount > IxPNTsTokenV2(token).maxSingleTxLimit()) return sigFail; // 信用路径同样受单笔上限约束
        mode = MODE_CREDIT;
    }
    // operator 乐观预扣与 legacy 相同
    return (abi.encode(token, sender, aPNTsAmount, userOpHash, operator, mode,
                       userOp.unpackCallGasLimit(), userOp.unpackPostOpGasLimit()), valid);
}
```

返回 sigFail 时，EntryPoint 以 AA34 让整个 bundle 回滚，已写入的锁随之撤销；在模拟阶段，
bundler 会直接丢弃这笔 op。

### 3.4 postOp（v2 分支）

```solidity
// lastTimestamp、_settledDebtOps 幂等锁：与 legacy 相同
uint256 buf = (postOpGasLimit + ceilDiv((callGasLimit + postOpGasLimit) * 10, 100) + C_WRAP) * actualUserOpFeePerGas;
uint256 charge = min(initialAPNTs, calc(actualGasCost + buf) * (1 + fee));  // DSR §3.1.3 口径
if (mode == MODE_BALANCE) {
    try IxPNTsTokenV2(token).settleLocked(user, opHash, charge) {} catch {
        userOpState[operator][user].isBlocked = true;
        emit SponsorshipUnbacked(operator, user, charge);                  // 不写 pendingDebts（S4）
    }
} else {
    _recordDebt(token, user, charge, opHash, operator);                    // 获批信用用户：现有路径
}
// operator 退款 initialAPNTs - charge、protocolRevenue 同步扣回：与 legacy 相同
```

`C_WRAP` 是常数，要按"最终的 v2 context 长度 + 固定编译器"做 gas trace，推导出一个可审计的
上界（DSR §3.1.3）。

### 3.5 其他

- 删除 `dryRunValidation`（F1），新增 `SuperPaymasterLens.dryRunValidation(sp, userOp, maxCost)`。
  lens 是无状态、不可升级的合约，内部常量与 `sp.version()` 绑定，版本不匹配就拒绝返回结果。
- 新事件 `SponsorshipUnbacked(address operator, address user, uint256 amountAPNTs)`。
- `version()` 改为 `SuperPaymaster-5.5.0`；重新生成 `abis/`；通知 sdk 和 dvt（按 CLAUDE.md
  约定开 issue，不到别人的仓库提 PR）。

## 4. 体积预算

| 项 | 数值 | 来源 |
|---|---|---|
| SP 当前 | 23,569 B（余量 1,007） | **实测** |
| F1 删除 dryRun | −2,150 B → 21,419 B（余量 3,157） | **实测**（带对照组） |
| v2 validate 分支 | +350–500 B | 估算 |
| v2 postOp 分支（buffer、try/catch、事件） | +400–500 B | 估算 |
| `configureOperator` 探测 | +100–150 B | 估算 |
| context 扩展与解码 | +80–120 B | 估算 |
| **SP 5.5.0 预计** | **≈ 22,350–22,700 B，余量约 1.9–2.2 KB** | 估算，实现后必须实测 |
| xPNTsToken v2 | 15,301 B + 约 4–5 KB ≈ 19.5–20.5 KB | 估算 |
| 工厂 initcode | 25,182 B + 约 5 KB ≈ 30 KB（< EIP-3860 的 49,152 B） | 估算 |

如果实测超出预算，按 F3 → F4 的顺序处理。**F4 会改变论文的 gas 数据，不到万不得已不用。**

## 5. 升级与迁移顺序

前提：DSR 发布 "B6 evidence frozen" + 作者 review 通过本方案。

| 阶段 | 步骤 | 验收（每一步都要有读回，且读回要带正对照） |
|---|---|---|
| S0 现在 | 只写文档；CC-119 T0/T5 暂不执行 | — |
| S1 开发 | 分支实现 token v2、SP 5.5.0、lens；§6 的 U/I/A/M/D 五层测试在本地全绿；Anvil 全量部署 | `forge test`、`forge test --evm-version prague` 全绿；实测体积 |
| S2 Sepolia ① | 部署 AOA 工厂（构造时生成 v2 模板，并**立即** `setSuperPaymasterAddress(SP)`）；部署 lens | 模板 codehash 与 artifact 一致；`factory.SUPERPAYMASTER() == SP` |
| S2 Sepolia ② | SP `upgradeToAndCall` → 5.5.0（不需要初始化） | 两个存量 operator 读回 `tokenGen == 0`；各发一笔 legacy op，结果与升级前一致；fork 差分测试（I5）通过 |
| S2 Sepolia ③ | `SP.setXPNTsFactory(AOA 工厂)`（即 CC-119 T5） | `xpntsFactory()` 读回正确；legacy operator 不受影响（它们不会再调用 `configureOperator`） |
| S2 Sepolia ④ | AOA 评估社区：在 AOA 工厂发币 → `configureOperator` → 存 aPNTs | `tokenGen == 1`；余额模式 op 成功；§6 B 层（真实 bundler 的 ERC-7562 模拟）通过 |
| S2 Sepolia ⑤ | aPNTs 切换（CC-119 T0）：**与 AOA 解耦**，只受 B6 冻结约束，可以在 ①–④ 之前或之后单独做【D-6】 | 按 runbook 重新读取排空基线 |
| S3 主网（按 L2 定位默认 OP 主网，待作者确认） | 顺序：先在 Sepolia 充分测试（S2），确认后再部署到主网采集论文数据，两步都做。OP 主网上 SP 目前仍是 V3（CC-30 G1），**本来就要全新部署**，所以不存在原地升级和 legacy 分支的问题。按 S2 的顺序部署，然后部署受控基线（`VerifyingPaymaster` / `TokenPaymaster`，同一条链、同一个 EntryPoint、同一个 bundler） | 链上 codehash、配置读回写进论文附录（T-B） |
| S4 可选 | 存量社区自愿迁移：1:1 兑换合约（旧币烧、新币铸）；债务留在旧代币；RepCredit 社区不迁移 | — |

## 6. 测试矩阵

| 层 | 覆盖 | 判据 |
|---|---|---|
| **U 单元** | token v2 每个函数的正常与失败路径；SP 两种代际 × 两种模式 × 四种 postOp 结果（成功 / 执行回滚 / settle 失败 / 回滚后释放） | 每个失败路径断言具体的 error selector，而不是泛泛地 expectRevert |
| **I 不变量** | I1–I6 用 Foundry invariant 实现，handler 覆盖 mint、transfer、transferFrom、burn(from)、transferAndCall、lock、settle、release、renew、approveCredit、急停 | I4 在每个 handler 之后都检查 |
| **A 对抗（R1-3 六类）** | 被盗的 community owner；恶意工厂；重复转账；替换 SP 地址（timelock 期内和到期后）；撤权（移除 spender、调低额度、急停）；批处理 | 损失 ≤ I2 给出的上界；替换 SP 在 48 h 内不生效 |
| **A 对抗（路线 A 五类）** | 自抽干（执行阶段转走 / burn / transferAndCall / 调 releaseStaleLock）；同一 bundle 同一 sender 发 N 笔；多个 nonce key；`maxCost` 超过上限；postOp 回滚与 unused-gas penalty（高 callGasLimit、高 postOpGasLimit、高 maxFeePerGas） | 自抽干：执行阶段全部失败，结算照常完成；同一 bundle：第 k 笔在可用余额不足时被拒 |
| **A 对抗（本方案新增）** | 同一 bundle 内汇率或价格缓存变化；急停发生在 validate 与 postOp 之间；锁定悬挂后的释放；篡改 `paymasterAndData` 的续期标志（→ AA24）；卡在额度下限的用户；显式 approve 与自动额度的交互；账户未部署（带 initCode）的第一笔；获批信用用户"先余额、后信用" | 按条列出期望状态 |
| **M 变异** | 每个机制删掉之后，至少有一条**指名的**断言变红：删 `_update` 锁定检查、删 `renew` 前的清零、把 `lim == 0` 的拒绝去掉、把 settle 的 min 去掉、把 release 的 transient 检查去掉 | 必须看清是哪条断言变红；变异必须真的改变了目标场景的行为 |
| **D 一致性** | lens 与真实 validate：同一组 fuzz 输入，比较 (ok, 原因) 是否一致；v2 路径和 legacy 路径各一套 | 逐项相等 |
| **A 对抗（恶意 SP，量化 I6/D-7）** | 用 `vm.etch` 或升级把 SP impl 换成恶意实现，不经过任何 UserOp，直接调 `tryLockForGas`（含 renew=true 连续调用）、`settleLocked`（原交易之后）、`tryReserveCredit`、`settleCredit`、`burnFromWithOpHash`、**无 hash 的 `recordDebt`**、`recordDebtWithOpHash`、`transferFrom`（含用户显式 approve 过的额度）、`burn(from)`，以及**所有继承下来的公开 selector** | 每个用户：被烧掉的量 ≤ I6 的上界；被记的债 ≤ `creditLimitOf`；被转走的量 = 0。**正对照**：把 D-13 的限次去掉之后，同一个测试必须变红 |
| **B bundler（ERC-7562）** | 在 Sepolia 上**至少实测 Pimlico Alto 和 Alchemy Rundler 两家**（safe-mode 开启），逐项测：`MIN_STAKE_VALUE` 门槛（SP 按实测门槛补足质押）；§2.3 验证期访问清单里每一行是否被接受；单笔；同一 sender 多笔；多 sender 同 bundle；带 initCode；R1 续期；验证期 TSTORE。论文使用的 bundler 必须在 Sepolia 和主网都能用，而且所有被测系统（SP / VerifyingPaymaster / TokenPaymaster）用同一个 | 保存 trace 作为证据；不能只用 Foundry 代替（Foundry 不检查 ERC-7562） |
| **G gas** | `C_WRAP` 上界的 gas trace；论文数据在 OP 主网采集 | 上界可复现 |

## 7. 协商记录

状态说明：✅ 双方一致；🟡 双方一致，但取值或选项要作者拍板；🆕 v2 新增，等 DSR 回复。

| # | 议题 | 结论 | 状态 |
|---|---|---|---|
| D-1 | ~~保留 legacy 路径（`tokenGen`）~~ **v2.4 作废：作者决定不兼容旧代币，RepCredit 也迁到 5.5.0（§8）** | 同意。DSR 的立场：冻结证据依赖交易哈希和区块区间，不要求活链重新执行，所以**不需要**给 AOA 单独部署 SP 代理。前提是冻结清单记录 5.4.2 impl 的 codehash 和区块区间，并且做 I5 差分测试 | ✅（清单内容由作者最终确认） |
| D-2 | 续期拆成 R1（`paymasterAndData` 标志位）+ R2（独立交易 + 1271） | 同意。信任前提："凡是能为该账户签 UserOp 的主体，**包括 session key 和委托 validator**，都能续期，但不能调高上限。"钱包只在额度用满时才置 renew（SDK 约定，不进合约）。**R1 另受 D-13 的次数限制** | ✅ |
| D-3 | 单笔锁定记录 + transient 活锁标记 + 释放时全额退回用户 | 同意，采用 DSR 给的论文口径。`releaseStaleLock` 发独立事件 `LockReleased`（X8 已含），供 DVT 和监控统计频次 | ✅ |
| D-4 | `SP_CAP_FLOOR` | **作者定：250 aPNTs（≈ $5），各链统一**（§8.5 注意 gas 飙升） | ✅ |
| D-5 | 显式 approve 优先、自动额度兜底；aPNTs 只做存款币；论文改称"有界免授权额度" | 同意 | ✅ |
| D-6 | T0 与 AOA 解耦；T5 只切一次，直接切到 AOA 工厂，并且排在 B6 冻结之后（切换后 RepCredit 社区无法再重新配置） | 同意 | ✅ |
| D-7 | codehash 白名单约束不到 UUPS 代理；SP 的升级权是信任假设，损失上界见 **§2.6 / I6**。建议（产品层面，不阻塞 AOA）：SP 的升级权也放到 timelock 后面 | 同意 | ✅ |
| D-8 | F1：删掉 SP 的 `dryRunValidation`；RepCredit 证据工具固定到升级前的区块，需要活链调用时改调 lens | 同意 | ✅ |
| D-9 | bundler：至少实测 Alto 和 Rundler 的 `MIN_STAKE_VALUE` 和验证期写入的接受情况（§6 B 层）；SP 按实测门槛补足质押；最终选哪一家等测试结果 | 同意 | ✅（选型待定） |
| D-10 | S7、S8 不改；S8 的信任矩阵行覆盖 legacy 和获批信用用户 | 同意 | ✅ |
| D-11 | 获批信用用户也先走余额锁定，不够才记债；额度 = min(全局分档, 社区批准额度) | 确认 | ✅ |
| D-12 | 结算按锁定时的比例换算，与 maxRate 汇率承诺一致；`allowance()` 的显示值注明可能有汇率差（§2.3） | 同意 | ✅ |
| D-13 | **R1 续期限次**（含 UX 代价与 SDK 中继恢复路径，见 §2.3）：`autoRenewUsed[user]`，每次 SP 触发的 renew 加 1、达到 K 时拒绝，只有用户本人经 R2 才能清零（v2.2 按 R-4 改名）。起因：DSR 补充第 4 条（恶意 SP 测试）暴露出，不限次的 renew 会让 I2 在恶意 SP 下失效 | DSR 同意；推荐 K = 1 | 🟡 K 由作者定 |
| D-14 | **收窄 SP 在 token 上的权限面**：SP 不在 `transferFrom` 名单里；v2 的 `burnFromWithOpHash` 计入额度；v2 的 `recordDebtWithOpHash` 在 token 内检查 `creditLimitOf`。起因同上：三个入口在 v1 草稿里都能绕过 I2 | DSR 同意；并确认 `allowance()` 不再对 SP 特殊处理（§2.3） | ✅ |
| D-15 | 急停后换 SP：①照常等 48 h；②′急停后只能立即切到**预登记的备用 SP**（备用 SP 本身要经过 48 h 登记）。DSR 的原选项②会重新打开攻击面（§2.7） | **作者定：②′** | ✅ |
| D-16 | 续期方案：A（账户自己续期，需改 AirAccount）+ B（K=1 兜底）；否决 T-post；C 和 D 只作为可选项 | Codex 推荐 A；SP 同意 | 🟡 等作者选择；若选 A，需要在 airaccount-contract 开 issue |
| D-17 | Codex 第 1 轮的规范性修订 R-1…R-8（§2.8） | SP 已复核全部成立 | 🆕 等 DSR 知悉（R-6、R-7 会影响论文里 I6 和信用的表述） |
| D-18 | 续期：**A（AirAccount 用 `ACCOUNT_ONLY` 模式）+ B（其他账户用 `SP_K`，K = 1，K_MAX = 1）**，两个标志位分开 | **作者定：A + B，K = 1**（经 DSR 转达） | ✅；待在 airaccount-contract 开 issue |
| D-19 | 用户的每 spender 紧急开关（R-13）与 Q4"SP 最低 $1、不能撤到 0"冲突 | **作者定：允许用户在紧急时把 SP 额度撤到 0**（日常下限仍为 250 aPNTs，恢复走 R2；经 DSR 转达） | ✅ |
| D-20 | v2 的信用模式：按 R-10 实现验证期预留，**或者** v2 首版不提供信用（AOA 本来就不评估信用，RepCredit 走 legacy） | **作者定：Y**——5.5.0 首版带信用 + R-10 预留 + OFF/MANUAL/AUTO 社区策略；条件 1（AUTO 下用户入会时签一次 `requestCredit(maxCap)`）、条件 2、条件 3 均确认（§8.2、§8.3） | ✅ |

## 8. 作者新决定后的评估（v2.4）

**作者的决定**（经 DSR 转达，2026-09-12）：① 不考虑旧代币，取消 `tokenGen` 分流和 legacy 路径，D-1 作废，Q8①
随之作废；② RepCredit 论文的数据也改用 5.5.0，全局只用一套代码；③ D-4：SP 额度下限统一取 **250 aPNTs（≈ $5）**；
④ D-15 采用 **②′**。D-18、D-19 尚未答复。

### 8.1 原地升级还是全新部署（问题 a）：**建议原地升级**

| 维度 | 原地升级（同一个代理 `0x09DF…`） | 全新代理 |
|---|---|---|
| 需要重新接线的地方 | **无** | 至少 6 处：`Registry.setSuperPaymaster`（`Registry.sol:276`）、`BLSAggregator.setSuperPaymaster`（`:1529`，4.11 链上有这个 selector）、SP 的 `BLS_AGGREGATOR`（有 timelock）、工厂/aPNTs 的 `SUPERPAYMASTER`、EntryPoint 重新质押和存款（旧的质押要等 86,400 s 才能取回）、SDK/DVT/YAAA 的配置 |
| `sbtHolders` | 保留 | **全部清空**。它是 Registry 在注册角色时回调写入的（`Registry.sol:929`），新代理要为每个存量用户重新同步 |
| BLS 三腿（CC-115 B3 的冻结不变量） | **不变** | SP 那一腿要换，B3 清单要重建 |
| operator 的 aPNTs 存款、T0 的切换队列 | 保留 | 要先提出来再存进去；T0 队列丢失，需要重新排 7 天 timelock |
| 存储 | 只追加；**不再需要 `tokenGen`**（取消分流）；`pendingDebts`、旧的 `userOpState` 等变成废弃状态，留在原位即可；`__gap` 不变 | 干净，可以顺便整理掉 x402 的废弃槽 |
| 存量 operator | 仍然指向旧代币。validate 调用旧代币的 `tryLockForGas` 会 revert（AA33），**默认失败**，不会误放行；`configureOperator` 在配置时探测 `BALANCE_MODE_VERSION`，拒绝旧代币 | 不存在 |
| 部署脚本 | UUPS 升级 + 迁移脚本（新工厂、各社区发 v2 代币、operator 重新配置） | 全套 `DeployLive` + 重新接线 + SBT 重同步 |

结论：取消 legacy 分流之后，原地升级仍然是更干净的选择。它唯一的代价是存储里留下一些废弃状态，但对新代码没有影响；
全新代理的重新接线里任何一步漏掉，都会造成静默故障（CC-48 里"batch 漏了 `addAuthorizedSlasher` 导致零罚没"就是这一类问题）。

### 8.2 v2 首版必须带信用 + R-10 预留（问题 b）：**可行，而且 SP 净体积可能变小**

- **token 侧**：`tryReserveCredit` / `settleCredit` / `releaseStaleCredit`，结构与锁定对称（关联槽 `creditReservedOf[user]`、`_creditRes[opHash][user]{amount, locker}`，结算要求 transient 标记仍为 1）。估计 +1.0–1.5 KB，token 余量足够。
- **SP 侧**：取消 legacy 之后，可以**删掉** `_creditExceeded`、`_recordDebt`（包括它的 try/catch 和三个分支）、`retryPendingDebt`、`clearPendingDebt`，以及 legacy 的 context 分支；新增的只是信用分支上两次对 token 的调用。**净变化估计在 −300 到 +400 B 之间**（估算，要实测）。因此 **F1 变成"视实测再定"**：如果不拆 dryRun 也放得下，就保留在 SP 里，这样可以少改一轮 SDK 和 RepCredit 工具。
- **N-C1 在新代码上被修掉**：同一 bundle 里的第 k 笔信用 op，在验证期就会看到前面几笔的预留。RepCredit L249 可以用新证据成立，但证据必须**重新采集**，并且要有同一 bundle 多笔的 Measured 测试。
- `pendingDebts` 这套机制随 legacy 一起退役。v2 信用结算失败时，预留留下来，由 stale release 解除；**不存在"owner 把欠款转成债务"的按钮**，这一点对信任矩阵是加分。

### 8.3 社区级信用策略 AUTO / MANUAL（问题 c）：**可行，建议采用，附 3 个条件**

DSR 指出的冲突成立：RepCredit 的机制是"验证过的贡献 → 声誉 → 额度自动生效"，逐人审批会把这条自动映射切断。

**设计**：token 增加 `creditPolicy ∈ {OFF, MANUAL, AUTO}`（全局槽，由 communityOwner 设置，**切换要走 48 h timelock**）：

| 策略 | 用户的有效额度 |
|---|---|
| OFF | 0 |
| MANUAL | `min(用户申请上限, owner 逐人批准额, 协议上限, 全局分档)` |
| AUTO | `min(用户申请上限, 协议上限, 全局分档)`，不需要逐人批准 |

**条件 1：AUTO 下仍然要求用户本人申请一次**（`requestCredit(maxCap)`，可以在入会流程里用一次签名完成）。
这样 R-12 的"信用额度必须经用户本人授权"在两种模式下都成立，也符合 R1-3 要求的"用户可控"。如果 RepCredit
要求用户零操作，那么恶意 SP 下的额度暴露面会变成"每个成员 = 全局分档"，而且用户没有同意过，这需要 DSR
判断论文能否接受。

**条件 2：全局分档必须由 token 自己从 Registry 读取**，不能由 SP 传入。否则恶意 SP 可以随便报一个分档。
`tryReserveCredit` 在 SP 的验证帧里调用 `Registry.getCreditLimit(user)`：`globalReputation[user]` 是与 user
关联的槽，`creditTierConfig` 是非关联的只读槽，SP 已质押时这是被允许的（STO-033）。现有 validate 已经在做同样的读取。
token 模板的 immutable 里要加 `REGISTRY`。每笔信用 op 多约 5–10k gas。

**条件 3：信任矩阵要写明**：AUTO 模式把"额度多少"交给了 Registry 的声誉治理（DVT 证明、声誉提案、`creditTierConfig`
的 owner 权限）。这本来就是 RepCredit 的模型，但 AOA 这边要在信任矩阵里显式写出来。

**AUTO 模式下的 I6**：恶意 SP、不经任何 UserOp 时，每个用户被记的新债 ≤ `min(用户申请上限, 协议上限, 全局分档) − 现有债务 − 已有预留`；
没有申请过的用户为 0。xPNTs 的烧毁上界与额度路径相同（§2.5）。**恶意 SP 加上被操纵的声誉**：分档可能被抬高，
但受用户申请上限约束，这正是条件 1 必须保留的原因。

### 8.4 RepCredit 证据链的连带工作（问题 d）

| 仓库/环节 | 受影响的内容 |
|---|---|
| **SP（本仓库）** | 5.5.0 升级、AOA 工厂和 v2 模板、lens（如果需要 F1）、迁移脚本、`abis/` 重新生成；测试矩阵 §6；另开 issue 通知 sdk 和 dvt |
| **SDK** | ① SP ABI：新事件、`paymasterAndData` 在 offset 104 的标志字节（`ACCOUNT_RENEW` / `SP_RENEW`），如果 F1 落地还有 dryRun 迁到 lens；② xPNTs v2 的用户接口：`setAutoAllowance(BySig)`、`requestCredit`、`renewForSelf`、`disableSpenderForSelf`、`autoAllowance`、`lockedOf`，而且 **`allowance()` 语义变了**；③ gas 估算：paymaster 验证 gas 增加（锁定调用，约 45–100k，要实测），账户续期那一笔的 `verificationGasLimit` 增加，`paymasterPostOpGasLimit` ≥ 新的 `MIN_POST_OP_GAS`；④ R2 中继恢复路径；⑤ `scripts/repcredit-e2e.ts` 的 deployedStack pin（SP 版本和 codehash、代币地址、ABI 哈希），以及 dryRun 调用（`:1131`、`:1235`）；⑥ shape gate 要加上新结构 |
| **DVT** | 如果原地升级，BLS 三腿和 slash 路径不变；CC-28 的超发扫描要换成新代币的地址；如果监听事件，要加 `SponsorshipUnbacked`、Lock/Credit 系列事件；如果 AUTO 模式依赖声誉，声誉证明路径不变 |
| **YAAA** | SDK 升级；UI 要新增：额度显示、续期签名、信用申请、紧急停用 |
| **AirAccount** | 只有作者选了 D-18 的方案 A 才受影响：`validateUserOp` 里增加 `renewForSelf` 调用（我去开 issue） |
| **RepCredit 重跑** | 凡是经过 SP 结算或信用的证据都要重新采集：B4（SDK 重新 pin 到 5.5.0 + v2 代币）、B5（YAAA smoke）、B6 里经过 gasless/credit 的实验、新增 L249 的同一 bundle 多笔 Measured 测试、AUTO 模式下"声誉 → 额度"的映射证据。**如果原地升级，BLS/committee/slash 那部分证据（B3 清单、4.11 aggregator、verifier）不受影响**；如果换新代理，B3 也要重建 |

### 8.5 其他

- **D-4 = 250 aPNTs**：可行。要注意，单笔预留额与 `maxFeePerGas` 成正比：在 L1 上 gas 价格飙升时（例如 20 gwei、300k gas，约 900 aPNTs），额度在下限的用户会发不出交易。SDK 要在报价时提示，或者按额度倒推一个 `maxFeePerGas` 上限。OP 主网上没有这个问题。
- **D-15 = ②′**：按 §2.7 执行。
- **`tokenGen` 撤销**：§3.1 里的 byte 18 字段不再需要，SP 5.5.0 存储零新增。

### 8.6 决策总表（2026-09-12，作者经 DSR 确认）

| 项 | 决定 | 状态 |
|---|---|---|
| 升级方式 | 原地升级（§8.1）；不考虑旧代币，取消 `tokenGen` 和 legacy 路径；RepCredit 在 5.5.0 上重新采集证据，B3 保留 | ✅ |
| D-4 | SP 额度下限 250 aPNTs（≈ $5），各链统一；gas 飙升由 SDK 在报价时提示，或按剩余额度倒推 `maxFeePerGas` 上限 | ✅ |
| D-15 | ②′ 预登记备用 SP | ✅ |
| D-18 | A + B，K = 1 | ✅ |
| D-19 | 允许用户紧急撤到 0 | ✅ |
| D-20 | Y：首版带信用 + R-10 + OFF/MANUAL/AUTO | ✅ |
| §8.3 条件 1–3 | AUTO 需用户本人申请一次；分档由 token 从 Registry 读取；信任矩阵写明 | ✅ |
| D-9 | bundler 选型 | ⏳ 等 B 层实测 |
| 主网 | 默认 OP 主网 | ⏳ 待作者确认 |
| Codex 第 3 轮 | 以 v2.4 为范围 | ⏳ 进行中；§8.7 另做一轮定向挑战 |
| 额度来源 | **作者定**：可插拔 `creditTierSource`；5.5.0 只上线 GLOBAL；COMMUNITY 放到后续版本，前提是满足 §8.7 的 (i) 或 (ii)。RepCredit 社区用 AUTO + GLOBAL，AOA 评估社区用 OFF | ✅ |
| DVT 打分函数里有没有还债项（§8.7 问题 d） | 向 repo:dvt 询问；不阻塞 5.5.0，决定信任矩阵和 RepCredit 方法部分怎么写 | ⏳ 待发出询问 |
| Registry owner 可直接改分档和 source 白名单（EOA、无 timelock） | 产品层面的改进项，不阻塞 | 📝 已记录 |

### 8.7 额度来源：GLOBAL / COMMUNITY（v2.5）

**作者的模型**（经 DSR 转达）：信用默认关闭，但声誉照常累积；批准方式分 MANUAL / AUTO，额度来源分 GLOBAL / COMMUNITY；
额度 = `min(用户申请上限, 协议上限, 来源分档(声誉), [MANUAL 时加上社区批准的上限])`。**批准只开通资格并给出一个可选的
上限，额度仍然随声誉变化。**

**事实核查（源码）**

| 项 | 事实 |
|---|---|
| 全局声誉 | `Registry.batchUpdateGlobalReputation` 要求调用方在 `isReputationSource` 白名单里，**并且带 BLS 证明**（`Registry.sol:537`、`:556` 调 `_verifyBLS`）；分档 `creditTierConfig` 由 Registry owner 通过 `setCreditTier`（`:676`）设置，没有 timelock。Registry owner 和 source 白名单（`:848`）现在由 EOA `0xb560…` 控制 |
| 社区声誉 | `ReputationSystem.communityReputations[community][user]`（`ReputationSystem.sol:38`），合约**不可升级**（`Ownable`，`REGISTRY` 是 immutable）。`setCommunityReputation`（`:83–88`）只要求调用方是 owner 或 `isReputationSource` 白名单成员，**不需要 BLS 证明，也不检查调用方对这个 community 有没有权限**：任何一个白名单 source 都能改写**任何**社区的分数 |
| 声誉的输入有没有还债项（DSR 的问题 d） | 链上**没有**。`computeScore` 的输入是社区规则 × 活动计数 + NFT 持有加成（`:124–172`）；Registry 和 reputation 模块里没有 repay/debt 相关的输入。全局声誉的**分数本身**由 DVT 在链下算好、BLS 证明后写入，所以 **DVT 的打分函数里有没有还债项，SP 看不到**，要问 repo:dvt（未核实）。如果有，信用关闭的社区就不会产生这部分声誉 |
| 社区身份用哪个地址 | 工厂把 `msg.sender`（持有 COMMUNITY 角色的地址）作为这个社区的键，也作为初始的 `communityOwner`；但 `communityOwner` 以后可以转让（`transferCommunityOwnership`）。SP 的 operator 地址就是这个社区地址。**所以 COMMUNITY 来源要用 token 在初始化时固定下来的社区 ID**，不能用可变的 `communityOwner` |

**建议：额度来源做成可插拔的"分档源"，5.5.0 只上线 GLOBAL，COMMUNITY 放到后续版本。理由如下。**

1. **可插拔，避免以后再迁移一次代币**：token 是克隆，不能升级。如果把"分档表 + 声誉读取"硬编码进 5.5.0 模板，
   以后加 COMMUNITY 就要换模板、再迁移一次代币。改为 token 里只存一个 `creditTierSource` 地址（实现
   `ICreditTierSource.tierOf(community, user) returns (uint256)`，由 communityOwner 设置，切换走 48 h timelock，
   白名单用 codehash），5.5.0 提供一个 `GlobalTierSource`（读 `Registry.getCreditLimit`）。以后
   `CommunityTierSource` 只需要部署新合约，**不用迁移代币**。token 增加约 300 B，SP 不变。
2. **I6 与来源无关**：因为 R-12 的用户申请上限始终参与取最小值，恶意 SP 能记的新债永远 ≤ `min(用户申请上限, 协议上限)`，
   不论来源是什么，也不论来源是否被操纵。
3. **COMMUNITY 来源现在的信任面太宽**：没有 BLS 证明，而且白名单里任何一个 source 都能给任何社区的任何用户打分。
   它要上线，至少要满足下面两条之一：(i) `ReputationSystem` 改为按社区授权（只有该社区指定的 source 能写这个社区的分数），或者
   (ii) 社区分数的写入也要带 BLS 证明。两条都需要**新版 ReputationSystem**（它不可升级，只能新部署），这超出了 5.5.0 的范围。
4. RepCredit 按 DSR 的倾向用 AUTO + GLOBAL，AOA 用 OFF / MANUAL，5.5.0 覆盖了两篇论文要评估的全部组合。

**ERC-7562**：分档源在 SP 的验证帧里被调用。`GlobalTierSource` 读 `globalReputation[user]`（关联槽）和
`creditTierConfig`（非关联，只读，SP 已质押时允许，现有代码已经在读）。以后的 `CommunityTierSource` 读
`communityReputations[community][user]`（最内层键是 user，是关联槽）加上自己的分档表（非关联，只读）。对分档源合约
的调用每笔增加约 3–8k gas。

**四种组合下的恶意 SP 上界（I6 的信用部分；不经过任何 UserOp，每个用户）**

| 组合 | 只有 SP 是恶意的 | SP 与声誉来源串通（分档被抬到最高） |
|---|---|---|
| GLOBAL × AUTO | 新债 ≤ `min(申请上限, 协议上限, tier_G(rep)) − 现有债 − 已预留` | ≤ `min(申请上限, 协议上限)`；要抬高 tier_G，需要 BLS 法定人数，或者 Registry owner 改分档/白名单 |
| GLOBAL × MANUAL | 同上，再与 `approvedCap` 取最小值 | ≤ `min(申请上限, 协议上限, approvedCap)` |
| COMMUNITY × AUTO（后续版本） | 新债 ≤ `min(申请上限, 协议上限, tier_C(rep_C)) − …` | ≤ `min(申请上限, 协议上限)`；**只需要任意一个白名单 source**，门槛远低于 GLOBAL |
| COMMUNITY × MANUAL（后续版本） | 同上，再与 `approvedCap` 取最小值 | ≤ `min(申请上限, 协议上限, approvedCap)` |

没有调用过 `requestCredit` 的用户，四种组合下都是 0。

**信任矩阵新增行**：GLOBAL 来源信任 BLS 法定人数 + Registry owner（分档、source 白名单，目前是 EOA、没有 timelock）；
COMMUNITY 来源（后续版本）信任 ReputationSystem owner + source 白名单。在 ReputationSystem 改为按社区授权之前，任何一个
source 都能影响所有社区。
