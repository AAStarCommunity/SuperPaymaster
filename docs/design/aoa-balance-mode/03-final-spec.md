# 03 · SP 5.5.0 + xPNTs v2 规范（v4.1，冻结）

> **v4.0 冻结：后续修改须递增版本并登记进 EVIDENCE-INDEX。**
>
> **v4.1（2026-09-16，勘误，D5c-1 有界符号验证发现，经 DSR 复核并确认）**：D5c-1（`D5c-1-halmos.md`，EVIDENCE-INDEX H-01…H-05）在按规范字面断言 A-3 时，发现代码允许 SP 调用 `burn(SP 自己, x)`（`from == msg.sender` 时跳过防火墙，`xPNTsTokenV2.sol:133–136` 与 `burn(x)`（`:138`）等价），这只会烧掉 SP 自己持有的 xPNTs，不影响用户余额，DSR 与作者核实后确认**不改合约、改规范表述**。同一交付物里，作者决定 I2 的范围明确排除用户显式 ERC-20 `approve` 的额度（那是普通授权，用户自己负责；按 A-3 这项排除只影响非 SP 的 spender），并新增单步性质 I2-F 作为"额度调低/撤销立刻生效"这条论文主张的直接依据；连带更正"累计 ≤ cap"的表述——调低 cap 不回溯清零 `used`，所以准确说法是"≤ 窗口内生效过的最大 cap"，v4.0.1 及更早版本的字面表述比代码语义更强，这里改的是规范表述，不是放宽安全性。改动：不变量表 I2、§2.1 A-3。harness 已按本版本的表述作为最终口径实现并通过判定（`verify-d5c1.py`：266 行，0 处不一致）。
>
> **v4.0.1（2026-09-13，勘误，DSR 验收发现）**：§10.7 SP owner 行与 §10.8 RDR-7 ① 把 `slashOperator` 写成"owner 路径不设 30% 上限"，与源码不符。`slashOperator`（`cbcb7045` `:951`）须先 `queueSlash`（`:953`）、有 24h 冷却（`:956`），并调用 `_slash(…, applyCap = true)`（`:957`），每次 ≤ 余额的 30%（`:1027`；由 `972279dc` p0-14 引入，5.4.2 `d651646a` 起即如此），与 BLS 路径（`:1002`）相同。RDR-7 ② 的结论不变（owner 被攻破 → 全部 operator aPNTs），但依据改为"通过升级拿走"，并补上路径说明。其余内容与 v4.0 相同。
>
> **v4.0（2026-09-13）**：规范清理并冻结，依据是排期定稿 CC-122（DSR `AOA_RepCredit_Sequencing_Plan_2026-09-13.md` §7–§10，后节优先）。本版只改文档，基线 commit `cbcb7045`（`feat/aoa-balance-mode-5.5.0`）。改动：
> 1. **D-9 bundler**：审阅记录下方"作者已定"一句（`cbcb7045` 上的 L16）和 §0 D-9 行（同上 L47）改为 v3.9 已执行的调整：主用自托管 Rundler v0.11.0（`2a3db237`，`same_sender_mempool_count = 1`），交叉验证 Alto v1.2.5（`45bbf341`）；保留历史说明。B 层"两个 bundler 都要测"的要求不变。
> 2. **§6 前置条件**：所有"RepCredit B6 冻结"改为"RepCredit F0 硬验收包通过恢复演练（CC-122 R1）"（倒排表、前提行、第 1 步 ④、§6.1 P2）；第 7c 步去掉 RepCredit 开 AUTO，改为指向 CC-122 R3；第 10 步改为指向 CC-122 R3–R5。
> 3. **runbook 新增**：第 5c 步（Registry 升级到 D5b 实现）；A3b 的 go/no-go 检查点 P1 / P2；第 5 步读回 `priceStalenessThreshold ∈ [60, 86400]`；每个写链阶段单独放行；M1–M3 在 Sepolia（A5s）的两步所有权与一次 `scheduleBatch`，`AOAProtocolRegistry` 与 AOA 工厂的 owner 一并转给 timelock（单步，转后读回）；感知 timelock 的升级流程纳入 rc1 门槛（A2）的 fork 演练；发布身份（commit + runtime codehash）。
> 4. **§10.7b**：GOV-5 行改为 Part B 定稿设计（`fe3a728c` 实验报告 B2–B4）；GOV-2 行的体积数字改为 `cbcb7045` 实测。
> 5. **C2**：与 Part B 定稿（384 B / 352 B 两种长度）核对一致；补上 D5b 扩展函数也在 bundle 中途测试的覆盖范围内。
> 6. **§10.8b R-AMS**：`SETTLE_GAS_BOUND` / `MIN_POST_OP_GAS` 在 Part B 之后是有硬边界的治理参数，调整时效 ≥ 96h；超出硬上界才需要 UUPS 升级。
> 7. **§10.8 改名"研究部署复核闸门"**：RDR-1…RDR-7（按计划 §9.1(1) 与 §10 的修订）。
> 8. **新增 §10.8c"产品上线审计闸门"**：原 AUD-1…AUD-4（及 §11.1 R10-M5 的两条追加）整体移入，范围扩大。
> 9. **"审计"措辞**：全文核对，不再出现暗示已做外部审计、或把外部审计当作论文前置条件的说法；§10.7 信任矩阵的说法与 RDR 一致。
> 10. **CC-30 盘点**（`docs/PRODUCTION_READINESS.md`）：外部审计项改为"研究部署：RDR-1…7；产品上线：§10.8c"。
>
> 顺带更正（均以 `cbcb7045` 源码为准）：§3.1 标注 Part B / D5b 会追加存储；§3.2 的 context 字段按实际的 11 个字改写并注明 Part B 的第 12 个字；§5 补 `cbcb7045` 的体积实测；§11.1 R10-M5 指向 §10.8c。
>
> **v4.0 合入前的补充**（SP 协调会话的决定；冻结版以 EVIDENCE-INDEX 的 S-01 行登记的 commit 为准，`70f8085f` 那一版不作为冻结版）：(a) 白名单按源码统一写成**一个** `AOAProtocolRegistry` 合约（三类 `KIND_SP` / `KIND_SPENDER` / `KIND_TIER_SOURCE`，token 经 immutable `PROTOCOL_REGISTRY` 引用）：§2.1、C-5、§10.5、§10.7、M1、AUD-1、AUD-5、R10-M5、§11.2；(b) M1 写明 `AOAProtocolRegistry` 与 AOA 工厂是单步 `Ownable`，转移后读回 `owner() == timelock`；(c) 全文 `SuperPaymaster.sol` / `Registry.sol` / `BasePaymasterUpgradeable.sol` 的行号按 `cbcb7045` 重核（§10.2 表整表重映射，含 token 三个文件；已不存在的引用写明）；(d) RDR-7 与 §10.7 SP owner 行补全最坏损失：owner 被攻破时加上 SP 持有的 aPNTs 与恶意 SP 可销毁的 xPNTs（I6 上界，逐项对照源码），合约漏洞一格写明依据与待验证假设；(e) Part B 的 Codex 状态：5 轮，第 5 轮（收尾，`fe3a728c`）APPROVE；(f) 体积：补上"这正是 D5b 拆分的原因、≥ 1,024 是发布门槛"；(g) §10.8c 移到 §10.8b 之后；(h) `upgrade-governance-eval.md` 末行改为指向 §10.8 / §10.8c。
>
> ---
>
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
> 每一轮的发现都由 SP 对照源码复核后才并入。**作者已定（2026-09-12）**：D-21 不处理（测试数据）；主网 = OP 主网；D-9 = 自托管 Rundler v0.11.0 主用、Alto v1.2.5 交叉验证（DSR 经作者授权确定；2026-09-12 原定 Alto 主用，v3.9 改为 Rundler，原因是 Alto v1.2.6 起 safe mode 对 EntryPoint v0.7 不可用，见 §0 D-9 行）；DVT 询问走 Seeder（CC-121）。
>
> **状态：v3.9-rc（2026-09-13）：D6——按 R10-M1b / R10-M2 重写 §10.2 状态转移表，按模式拆开 opReverted 行，每一格补上 file:line；I10 的措辞同步到在途预留（operator 在 release 后净额为 0，G 由 SP 的 ETH 押金承担）；D3 发现：`SETTLE_GAS_BOUND` 从 80k 改为 160k（§10.1 ③）；验证期对 token 的三处调用（`exchangeRate` / `tryLockForGas` / `tryReserveCredit`）改为只拷 32 字节的低层调用，revert、短返回、畸形返回一律 fail closed 为 sigFail（§3.3；Codex D3 指出 typed try 挡不住解码失败）、I2 的"用户亲自操作"加以澄清、I6 的烧毁上界改用 §10.2 的公式。**
> v3.8-rc（2026-09-12）：并入 Codex 第 10 轮（1 High + 5 Medium）和 D1 的实现期发现（token 拆成核心和扩展、工厂接收预先部署的模板），见 §11。**
> v3.7-rc（2026-09-12）：并入 DSR 以 Reviewer 1 视角做的验收复核（B-1…B-7 High、独立审计闸门〔v4.0 起改为 §10.8 研究部署复核闸门，外部审计移到 §10.8c 产品上线审计闸门〕、Medium B-9/B-11/B-12），规范性内容在 §10，它优先于前文。**
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
| D-9 | **主用：自托管 Alchemy Rundler v0.11.0（commit `2a3db237`）**，配置固定加 `--pool.same_sender_mempool_count 1`（§3.2、§6 运营前置条件）；Sepolia 和 OP 主网用同一版本、同一份配置，ERC-7562 规则检查不关闭（启动命令见 `b-layer/README.md` §3、§5）；SP 5.5.0、VerifyingPaymaster、TokenPaymaster 走同一个实例（便于复现，也去掉厂商 bundler 给不同 paymaster 不同 PVG 这个混杂因素）。**交叉验证：自托管 Pimlico Alto v1.2.5（commit `45bbf341`），开启 safe mode**，只在 B 层测 ERC-7562 兼容性，不参与 gas 数据。**Alto ≥ v1.2.6 不可用**：从 v1.2.6 起，safe mode 对 EntryPoint v0.7 的模拟结果解码错了层（它取最后一帧当作 `simulateValidation` 的 revert，而那一帧其实是 EntryPoint 内层 `DelegateAndRevert(bool,bytes)`，selector `0x99410554`），合规的对照 op 也全部被拒（证据与二分定位见 `b-layer/README.md` §2 发现 1）。质押按 Rundler 的**默认**门槛（`--min_stake_value` 1 ETH、`--min_unstake_delay` 86400 s，与 ERC-7562 的 MIN_UNSTAKE_DELAY 一致，`b-layer/README.md` §0），不为 SP 调低；SP 在两条链上的质押补足到门槛以上（runbook 第 5b 步；Sepolia 的 SP 2026-09-13 实测只有 0.1 ETH）。Rundler 的版本号、配置文件、启动命令写进论文附录。**历史**：2026-09-12 原定"Alto 主用、Rundler 交叉验证"；v3.9（2026-09-13）按本行原来的兜底条款（"Alto 某项过不了而 Rundler 能过时改用 Rundler"）改为 Rundler 主用，原因是上面的 Alto v1.2.6+ 回归，另外 Alto v1.2.5 在 safe mode 下还有两处与 SP 无关的上游缺陷（`b-layer/README.md` §5） | DSR 定（经作者授权）2026-09-12；v3.9 调整 2026-09-13 ✅ |
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
协议白名单 `PROTOCOL_REGISTRY`（immutable，指向**一个** `AOAProtocolRegistry` 合约，内分三类：`KIND_SP` 按代理地址登记，`KIND_SPENDER` 与 `KIND_TIER_SOURCE` 按实现合约 codehash 登记；`xPNTsV2Base.sol:53`，`AOAProtocolRegistry.sol:24–26`）。（源码核对：上面的额度、下限、`K`、48 h 在 `cbcb7045` 里都是 `constant`，`xPNTsV2Base.sol:29–35`，名称是 `TIMELOCK` 而不是 `SPENDER_TIMELOCK`；只有 `PROTOCOL_REGISTRY` 是 immutable。）

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
| A-3 | **（v4.1 更正，见文件头勘误）** 当前 SP 或历史 SP 作为调用者时，凡是 `from ≠ msg.sender` 的 `transferFrom` / `burn(address,uint256)` 一律 revert（不论是否有显式 approve）；SP 通过 `burn(x)` 或 `burn(SP 自己, x)`（`from == msg.sender`）只能减少**它自己**的余额，这不受 A-3 约束。SP 能减少**任何其他账户**余额的途径，只有 `settleLocked` / `settleCredit`，数额受 I6 约束 |
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
| C-5 | 分档源切换：queue → 48 h → execute，执行时检查 codehash 在 `AOAProtocolRegistry` 的 `KIND_TIER_SOURCE` 白名单里（`xPNTsTokenV2Ext.sol:196`）。5.5.0 的 `GlobalTierSource.tierOf(_, user) = Registry.getCreditLimit(user)` |

**验证期访问清单**（B 层逐项测；清单之外，token 在验证期不得访问任何槽）

| 帧 | 访问 | 槽 | 规则 |
|---|---|---|---|
| SP（已质押） | 读 | `SUPERPAYMASTER_ADDRESS`、`historicalSP[SP]`、`emergencyDisabled`、`exchangeRate`、`maxSingleTxLimit`、`creditPolicy`、`policyEpoch`、`creditTierSource`、`community`；Registry 的 `creditTierConfig`、`globalReputation[u]`、**`levelThresholds` 的长度和元素、Registry 代理的 EIP-1967 实现槽**（v3.9，D5 B7 的 trace 补全，发现 F3；都是已质押 SP 对非实体合约的只读，STO-033 允许） | STO-033 |
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

**实现位置（D6）**：S-0 在 `xPNTsTokenV2.sol:87–93`（`initialize` 内；`cbcb7045`，原写 `:85–91`）。以下各转移都在 `xPNTsTokenV2Ext.sol` 中：S-1 `:223`、S-2 `:245`、S-3 `:257`、S-4 `:268`、S-5 `:280`（propose）和 `:289`（designate）、S-6 `:301`、S-7 `:311`；`_setCurrentSP` 在 `:318`，负责 `historicalSP` 写入和清空 pending。
覆盖测试：`xPNTsTokenV2Test.test_S1_S3_rotation_after_timelock`、`test_factory_proposal_cannot_override_community_and_is_cancelled_by_emergency`、`test_S6_S7_standby_recovery`，以及 `xPNTsTokenV2D3Test` 的 `test_S2_*`、`test_S3_*`、`test_A10_*`。

**为什么急停期间还允许 S-3**（与 Codex 第 8 轮的建议不同）：如果急停期间只能走备用 SP，那么没有预设备用 SP 的社区会永久卡在急停状态（S-7 要求 current 不等于被撤销的地址）。只允许 communityOwner 发起、已公示满 48 h 的提议，它的安全性和备用 SP 相同（都是 48 h 前就公开的地址），而且不会卡死。

**由此得到的性质**：急停之后，恢复只有两条路：S-6 立即切到 48 h 前就公开的备用 SP，或者 S-3 等一个 48 h 的提议到期；然后才能 S-7 解除急停。
工厂在任何时候都**不能**让一个 SP 地址不经 48 h 公示就生效（创世 S-0 除外，那时代币还没有持有人）。
切换 token 的 SP 之后，社区还要在新 SP 上 `configureOperator`，否则新 SP 的 validate 会因为 operator 未配置而拒绝，这是默认失败。

## 3. SuperPaymaster 5.5.0（原地升级）

### 3.1 存储

**零新增**，`__gap` 不变。（v4.0 注：这句是 v3.0 时的设计，已不准确：实现按 R10-M1b 在末尾追加了在途记录 `_inflight`，`__gap` 28 → 27（`SuperPaymaster.sol:1552–1555`，`cbcb7045`）。Part B 合入后再追加 gas 参数与待生效参数两个槽，D5b 再追加 guardian 与全局 `paused`（打包一个槽）和 ERC-7201 命名空间里的 `pendingOwner`，都只允许作为写明的新增项出现，见 §10.7b GOV-2 规范 A、D 和 GOV-5 ①。）

| 状态 | 处理 |
|---|---|
| `operators[*]` | 保留。旧代币的 operator 必须在升级前暂停（§6） |
| `userOpState` | **保留并继续使用**：`isBlocked` 由 validate 读取，Registry 的黑名单同步（`updateBlockedStatus`，SP `:669` ← Registry `:639`；行号按 `cbcb7045`）写入。旧的封禁记录**沿用** |
| `_settledDebtOps` | **保留并继续使用**，作为 postOp 的幂等锁（SP `:1340–1341`，`cbcb7045`）；旧的 hash 无害 |
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

（v4.0 注：上面的 context 是 v3.0 的草稿。`cbcb7045` 实际是 11 个字、352 B 的 `OpCtx`：`token, user, a0, opHash, operator, mode, callGas, postOpGas, price, decimals, aPriceUSD`（`SuperPaymaster.sol:54–66`；后三个是 R10-M3 的价格快照）。Part B 合入后末尾追加第 12 个字（验证时的 gas 参数快照），共 384 B；两种长度的处理见 §10.7b GOV-5 ④ 和 C2。）

**SDK 与 D7 的强制规范（v3.9，D5 B 层 F1/F2）**：
- **`paymasterPostOpGasLimit ≥ 200,000`（= `MIN_POST_OP_GAS`）写死**，不能用 bundler 的估算值：Rundler v0.11.0 的估算结果里没有这个字段，Alto v1.2.5 在不传的情况下只估到 114,560。
- **`paymasterVerificationGasLimit` 必须设下限**：不传时 Rundler 估成 38,403，而 SP 验证实测需要 198k–238k。下限按**最坏路径实测值加余量**来定（初稿建议 250k），**要在最坏路径（冷槽、CREDIT、SP_RENEW、多笔同 sender）上验证之后才写死**。估算请求里一定要带上 paymaster 的 gas 字段。
- **在 F1 的处理方式确定之前：同一 sender 同时只能有 1 笔在途 op 经过 SP**（SDK 和 AirAccount 侧强制）。这也是 runbook 和 D7 的前置条件。
- **已实测**：我们自托管的 Rundler（论文实验用的就是它）配置 `--pool.same_sender_mempool_count 1`，B2b 的第 2、3 笔在提交时就被拒（`-32505`），SP 没有被封（`b-layer/F1-investigation.md`，`c0d9e350`）。局限：只对未质押的 sender 生效，只保护我们自己的节点，同一 sender 的 op 只能串行发送。F1 已定性为生态层面的交互（标准 TokenPaymaster 同样被封），处理方向等作者决定。

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
| I2 | 对任意 (user, spender)：自上次合法重置以来经 `transferFrom`、`burn(from)`、`settleLocked` 的**自动额度**（`_auto`/`_budget`）累计 ≤ cap；各 spender 的累计之和 ≤ 总额上限；两次用户亲自操作之间，SP 转述的续期 ≤ K。**v3.9 澄清**："用户亲自操作"指用户本人发起的任意一次续期（`renewForSelf` 或 R2 `ACT_RENEW`），**不论指定哪个 spender**；A-6 的 `_renew` 总会把 `autoRenewUsed` 清零，所以用户续期任何 spender 都会重新开放 SP 的 K 次续期。每次重新开放都来自用户的签名或调用，所以 SP 在一个窗口内最多获得 K 次续期。**v4.1 更正（见文件头勘误）**：I2 的范围明确为**自动**额度；用户经 ERC-20 `approve` 显式授权的额度不计入 I2（那是普通的 ERC-20 授权，由用户自己负责；按 A-3，SP 永远用不了显式授权，所以这项排除只与非 SP 的 spender 有关），显式授权的消费单独受"消费量 ≤ 授权量、且消费不影响自动额度的计数器"约束。**I2-F（新增单步性质）**：任意一步中，`used_after − used_before ≤ max(0, cap_now − used_before)`（`_auto`、`_budget` 各一份，`cap_now` 为该步生效的 cap）；这是"用户可以把额度调低或撤到 0、并且下一步立刻生效"这条论文主张的直接依据。**累计上界的准确表述**：由于调低 cap 不会回溯清零 `used`，"累计 ≤ cap"这句话准确说是"累计 ≤ 自上次重置以来窗口内**生效过的最大** cap"，v4.0.1 及更早版本"used ≤ cap"的字面表述比这更强，代码行为是有意为之，这里只是改正规范表述 |
| I3 | 新债务只能由 `settleCredit` 产生，而且只能消费一笔在准入时满足 C-1 的有效预留。`creditPolicy == OFF`、没有有效的当期申请、已撤回或已停用，这些状态**阻止新的预留**；债务在这些状态下仍可能增加，但**只能**来自消费此前已准入的预留（与 E-2、C-3、C-4 一致，§9 R4-H4） |
| I4 | 每笔交易结束时：`lockedOf[u] == Σ _locks[·][u].xLocked`，`creditReservedOf[u] == Σ _creditRes[·][u].amount`，并且 `balanceOf(u) ≥ lockedOf[u]` |
| I5 | 活标记为 0 之后，任何记录都只能被 stale release 处理，不能再被结算 |
| I6 | **恶意 SP**（impl 被任意替换、不经过任何 UserOp），每个用户：按锁定路径结算的 aPNTs 等值 ≤ `min(剩余 SP 额度 + K·SP cap, 剩余总额 + K·总额上限)`；xPNTs 烧毁量 ≤ `min(余额, Σ xc_i)`，`xc_i = min(x0_i, ceil(c_i · x0_i / a0_i))`（§10.2 的公式；**v3.9 修正**：原来写的 `Σ ceil(aCharge_i · rate_i / 1e18)` 每笔会少算最多 1 wei，按 lock 时的比例结算时可能被合法地超出，I 层用 `test_I6_literalBurnBound_offByOneWei` 复现）；新债分两部分：(i) 新预留只能在当期 epoch 内准入，额度 ≤ `max(0, min(有效的当期 requestedCap, PROTOCOL_CREDIT_CEILING) − debts − reserved)`；(ii) epoch、策略或分档源变化之后，**不能再准入新预留**，但此前已准入的预留仍然可以结算，每笔只能把自己那笔 reservation 转成不超过其 amount 的债务，所以这一部分的新增债务 ≤ 失效那一刻的 `creditReservedOf`（与额度来源无关，与策略无关，见 02 §8.7 的四格表）；转走的量 = 0。**范围**：只是 token 侧的上界 |
| I7 | `effectiveCreditCap` 是所有信用判断的唯一来源（结构性要求，由测试在每个信用入口上断言） |

## 5. 体积

| 项 | 数值 |
|---|---|
| SP 当前 | 23,569 B，余量 1,007 B（**实测**；这是 5.4.2 基线 `3b0d4821` 的数字，见 EVIDENCE-INDEX §2.2）。**v4.0 更新**：5.5.0 在 `cbcb7045` 上实测 **22,942 B，余量 1,634 B**（default profile；Part B / D5b 合入后的数字见 §10.7b GOV-2、GOV-5） |
| F1 能腾出的空间 | 2,150 B（**实测**，带对照组） |
| 5.5.0 的净变化 | 删除 legacy 信用逻辑，加上新的流程、context、buffer 和 dryRun 镜像：**不能拿估算做决定**（Codex 第 3 轮） |
| 发布门槛 | 实测 runtime ≤ 24,576 − **1,024 B**（给以后的修复留出空间）；不满足就执行 F1 |
| token v2 | 15,301 B + 估算 5–7 KB，要实测；工厂 initcode 远低于 49,152 B |

## 6. 升级与迁移 runbook（Codex H3-1、H3-2）

**F1 处理方向（作者 2026-09-13 确认）**：① 自托管 Rundler 配置 `same_sender_mempool_count = 1`（已实测有效）+ ② SDK 限制单 sender 单笔在途 op + AirAccount 账户侧守卫（方案 A 账户在验证期读 `lockedOf(me)`；需要在 airaccount-contract 仓库开 issue）+ ④ 论文作为生态层面的限制披露（附 TokenPaymaster 对照）；③（合约层改为验证不依赖同 bundle 状态）列为研究项。

**运营前置条件**：同一 sender 同时只能有 1 笔在途 op 经过 SP（见 §3.2 的 SDK 规范）。自托管 Rundler 配置 `--pool.same_sender_mempool_count 1`（已实测有效，局限见 §3.2）。

**倒排时间表（升级日 = T；DSR 2026-09-13 要求放在最前面）**

| 时点 | 事项 | 约束来源 |
|---|---|---|
| **T − 7d 之前（GOV-1 已生效时为 T − 7d − 48h）** | 第 1 步 ①–③：取消 `0xBb46` → 部署 `APNTsCapped` → `setAPNTsToken(APNTsCapped)` 重新排队 | SP 的 `APNTS_TOKEN_TIMELOCK = 7 days`；GOV-1 之后每一笔 owner 调用还要加 48h |
| T − 7d 到 T | 通知各 operator 在 T 当天准备好取出和重新存入；确认 RepCredit F0 硬验收包已通过恢复演练（CC-122 R1） | CC-122（计划 §7.2） |
| T | 第 0 步的 fork 层级检查 → 第 1 步 ④ 执行切换 → 第 2–7c 步（含 5c） | — |
| 主网前（Sepolia 上即 A5s） | M1–M3（GOV-1..3）、7d（铸币权交给多签） | §10.7b |

前提：RepCredit F0 硬验收包通过恢复演练（CC-122 R1；这是 A3a 的前置条件，因此也是本 runbook 任何写链步骤的前置条件）+ 作者 review 通过 + §8 的测试全绿。（v4.0 之前这里写的是"DSR 发布 B6 evidence frozen"，已被 CC-122 取代：RepCredit 在 5.5.0 上重新采集，不再等 5.4.2 上的 B6。）

**写链阶段逐一放行（CC-122，计划 §8.2 第 4 条）**：A3a（T − 7d 的取消、部署 `APNTsCapped`、重新排队，部署也算写链）、A3b（升级窗口，T 当天的第 0–7c 步，含 5c）、A5s（Sepolia 上的 M1–M3）、rc2 升级、A6（OP 主网部署），**每一个阶段都要作者单独、明确地放行（go）**。放行只对该阶段有效，不跨阶段沿用；中途中止后重新开始，也要重新放行。

**A3b 的 go/no-go 检查点（计划 §8.2 第 3 条）**。任何 drain 或读回不满足，就取消本窗口，不临场绕过（计划 §7.1 A3b）：
- **P1 = 第 1 步 ④ 执行完**（`executeAPNTsTokenChange`，operator 改存 `APNTsCapped`）。执行之后可以停在这里：SP 仍是 5.4.2，operator 在 SP 里的存款已经是 `APNTsCapped`。在 ④ 之前随时可以中止：`executeAPNTsTokenChange`（`SuperPaymaster.sol:434`）只检查 `block.timestamp ≥ pendingAPNTsTokenEta`（`:437`），**没有过期时间**，所以挂着的切换会保留到下一个窗口，不需要重新排队、不需要再等 7 天。
- **P2 = 第 5 步 `upgradeToAndCall`，这是不可回退点**：降级回 5.4.2 会丢掉在途与预留的语义（5.4.2 的源码里没有 `_inflight` 和 `releaseStaleSponsorship`，已在 RepCredit 用的 `d651646a` 上核对；也没有 v2 token 的结算路径），所以此后只能向前修。A5s 之前 owner 仍是 EOA，向前修还可以直接由 EOA 执行；A5s 之后要走 timelock（§10.7b C）。

| 步 | 动作 | 验收（每一步都要带正对照读回） | 必须记录的证据（P2 起强制，缺一项该步不算完成） |
|---|---|---|---|
| 0 | **fork 层级检查（§10.8b R-AMS）**：`eth_config` 读 `current` / `next`，`next` 是 Amsterdam 就阻塞；盘点：枚举所有 `operators[*]`；按 `DebtRecordFailed` 事件枚举 `pendingDebts` 非零的条目；确认 `pendingAPNTsToken` 的状态 | 盘点表入库；日志扫描按"归档 RPC + 扫描完整性"纪律做交叉验证 | `eth_config` 原始响应（current/next）+ 读取时的区块号；CLZ 探针响应；盘点 JSON（两个端点、扫描区间、事件计数、正对照）及其 sha256 |
| 1 | aPNTs 切换（T0）。**作者决定（2026-09-13，经 DSR，第二次）：两条链都换成 `APNTsCapped`**（设计见 `apnts-capped-design.md`；minter 和 capGuardian 都是治理多签 `0x51eD…E114`；Sepolia 用一个**标明为测试值**的上限；主网初始上限 **300,000e18**，见 §10.7b GOV-4）。这一决定取代了原先"切换到 `0xBb46`"的分支 A。步骤：① `cancelAPNTsTokenChange()` 取消挂着的 `0xBb46`（即时，没有 timelock；`setAPNTsToken` 本来就会覆盖 pending，但显式取消更清楚）；② 部署 `APNTsCapped`；③ `setAPNTsToken(APNTsCapped)` 重新排队，**ETA = 当时 + 7 天**（`APNTS_TOKEN_TIMELOCK`），所以**至少要在升级窗口 7 天之前排队**；如果 GOV-1 已经生效，每一笔 owner 调用还要再加 48h 的 timelock；④ 在升级窗口内执行，前提是 RepCredit F0 硬验收包已通过恢复演练（CC-122 R1）；④ 就是检查点 P1（见上）：快照 → 各 operator 取出全部余额 → revenue 取到只剩 0.1 → 读回前提 → `executeAPNTsTokenChange` → 按 1:1 用 `APNTsCapped` 重新存入（由 minter 多签给 operator 铸造）。**`0xBb46` 的处置**：弃用；按 7d 的做法 renounceFactory 并转给多签之后闲置，SP 只接受 `APNTS_TOKEN`，所以它剩下的铸币能力不影响 SP 的偿付能力。实现：`UpgradeToV5_5_0.executePendingAPNTs(ops)`（按新流程改写，fork 演练待完成） | 取消后 `pendingAPNTsToken == 0`；排队后 `pendingAPNTsToken == APNTsCapped`、`pendingAPNTsTokenEta == 排队时间 + 7 天`；执行后 `APNTS_TOKEN == APNTsCapped`；每个 operator 的余额 == 快照 × 1；`totalTrackedBalance == Σ + revenue`；`APNTsCapped.totalSupply() ≤ cap` | 每一笔的 tx hash + 区块号，以及每次读回的区块号：① `cancelAPNTsTokenChange`（取消 0xBb46）；② `APNTsCapped` 部署 tx + runtime codehash + timelock 地址，GOV-1 accept 的 schedule / execute tx；③ `setAPNTsToken(APNTsCapped)` 重新排队 tx（**排队区块时间 ≤ T − 7d**），`pendingAPNTsToken` / `pendingAPNTsTokenEta` 读回值；④ 快照读回、各 operator `withdraw`、revenue 提取、`executeAPNTsTokenChange`、minter 多签 `mint`、1:1 `deposit` 每一笔 |
| 2 | `pendingDebts`：逐条对账，要么先用 5.4.2 的 `retryPendingDebt`/`clearPendingDebt` 处理，要么在文档里明确核销 | 所有条目为 0，或者有核销记录 | 每条 `retryPendingDebt` / `clearPendingDebt` 的 tx hash + 区块号，或核销记录（条目、金额、依据）；读回区块号 |
| 3 | 用 `setOperatorPaused`（SP `:645`）暂停所有旧代币的 operator；等 mempool 里的旧 op 清空 | 各 operator `isPaused == true` | 每个 operator 的 `setOperatorPaused(op, true)` tx hash + 区块号；`isPaused` 读回区块号 |
| 4 | 按顺序部署：`GlobalTierSource` → codehash 白名单登记 → AOA 工厂（构造时生成 v2 模板，把默认分档源传给 token 的 initialize，**立即** `setSuperPaymasterAddress(SP)`）；如果需要 F1，再部署 lens | 模板 codehash 与 artifact 一致；工厂的 SUPERPAYMASTER 等于 SP | `GlobalTierSource`、`AOAProtocolRegistry`、每次 `bootstrapApprove`、`seal`、`xPNTsTokenV2Ext`、模板 `xPNTsTokenV2`、`xPNTsFactoryV2`、Lens 的 tx hash + 区块号 + 地址 + runtime codehash；模板 codehash 读回区块号 |
| 5 | 升级之前核对 5.5.0 impl 的构造参数（`REGISTRY`、`ETH_USD_PRICE_FEED`、`entryPoint`）；SP `upgradeToAndCall` → 5.5.0。**这是检查点 P2（不可回退点）**。impl 必须从 tag 编译，runtime codehash 与发布证明一致（见下方"发布身份"） | `version()`；三个 immutable 读回，并与 5.4.2 一致；BLS 三腿不变；`sbtHolders` 抽样；`userOpState` 抽样；**`priceStalenessThreshold ∈ [60, 86400]`**（v4.0：全新部署由 `initialize` 强制这个范围，`SuperPaymaster.sol:309`，自 `cbcb7045` 起；原地升级的代理保留旧值，而 5.5.0 没有 setter，所以只能在这里读回断言；Sepolia 2026-09-13 的读数为 4200（`cbcb7045` 的提交说明；v4.0 起草时在 Sepolia 块 11,694,182 经 publicnode 单一端点复读，仍为 4200）；`UpgradeToV5_5_0` 第 5 步读回已断言该范围，`UpgradeToV5_5_0.s.sol:586`） | 5.5.0 impl 部署 tx + runtime codehash；`upgradeToAndCall` tx hash + 区块号；`version()`、三个 immutable、ERC-1967 槽、`priceStalenessThreshold` 的读回区块号 |
| 5b | **SP 在 EntryPoint 的质押补足到 ≥ 1 ETH，`unstakeDelaySec` ≥ 86400**（v3.9，D-9 调整：主用 bundler Rundler v0.11.0 的默认门槛是 1 ETH / 86400 s，与 ERC-7562 的 MIN_UNSTAKE_DELAY 一致；SP 在验证期读全局槽，依赖 STO-033，不质押就会被 bundler 拒绝）。owner 调用 `SP.addStake{value: 差额}(max(86400, 当前 delay))`。2026-09-13 的实测：Sepolia 的 SP `0x09DF…` 和 OP 主网的 SP `0xA2c9…` 质押都只有 **0.1 ETH**（delay 86400） | `EntryPoint.getDepositInfo(SP)`：`staked == true`、`stake ≥ 1e18`、`unstakeDelaySec ≥ 86400`、`withdrawTime == 0` | `addStake` tx hash + 区块号（**补足到 1 ETH / 86400 s**）；`getDepositInfo(SP)` 原始读回 + 区块号 |
| 5c | **（v4.0 新增，CC-122 / 计划 §8.1 第 1 条）Registry `upgradeToAndCall` → D5b 的 Registry 实现**：GOV-2 在 Registry 上只加两步所有权（`pendingOwner` 放在 ERC-7201 命名空间槽，不占顺序布局）并在 `initialize` 里拒绝零 owner（目前 `Registry.sol:87–88` 直接 `_transferOwnership(_owner)`），**不加 guardian**（§10.7b GOV-2 规范 A、B.5）。这是 Registry 的字节码变更，必须单独升级；它必须在 M1 之前完成，否则 M1 的两步转移在 Registry 上无从执行。前置：D5b 验收通过；**存储布局门槛**：`scripts/check_storage_layout.py` 按 §10.7b D 扩展后的版本，对 `storage-layout/Registry.json` 只允许写明的新增项（Registry 的顺序布局应当完全不变），外加 ERC-7201 槽位置的 `vm.load` 测试；impl 从 tag 编译，runtime codehash 与发布证明一致；Registry 体积在 D5b 之后重测（`cbcb7045` 实测 23,038 B，余量 1,538，runs 200） | `version()` 读回等于 D5b 定下的 Registry 版本号（当前是 `Registry-5.8.0`，`Registry.sol:27`）；ERC-1967 实现槽等于新 impl；`owner()` 不变、`pendingOwner() == 0`；**BLS 三腿不变**（`SP.BLS_AGGREGATOR`、`Registry.blsAggregator`、`DVT.BLS_AGGREGATOR`，与第 5 步同一组读回，`UpgradeToV5_5_0.s.sol:570–572`）；Registry 原始槽抽样逐字节不变 | Registry impl 部署 tx + runtime codehash；`upgradeToAndCall` tx hash + 区块号；`version()`、实现槽、owner、`pendingOwner`、BLS 三腿的读回区块号。**对 RepCredit 的影响**：Registry 的 impl codehash 会变，RepCredit B3′ 的"Registry source"要按新 impl 出清单；B3-old 引用的 Registry 与 5.5.0 之后链上的不是同一份字节码，要写进 RepCredit 的 ERRATA 和 limitations（CC-122，由 RepCredit 侧执行） |
| 6 | `SP.setXPNTsFactory(AOA 工厂)`（CC-119 T5） | 读回 | `setXPNTsFactory` tx hash + 区块号；`xpntsFactory()` 读回区块号 |
| 7a | 各社区在 AOA 工厂发 v2 代币（community 固定；`creditPolicy` 初始为 OFF），operator **仍处于暂停状态** | 代币 codehash 与模板一致；默认分档源读回正确 | 每个社区发币（`deployxPNTsToken`）的 tx hash + 区块号 + 代币地址 + codehash；**AOA 评估社区 `creditPolicy() == 0`（OFF）的读回值与读回区块号** |
| 7b | **D-21（作者定：不处理）**：旧代币里的债务都是测试数据，直接放弃，只在迁移记录里写一句。下面保留原来的三个选项，仅作记录：(a) 把核对过的旧债导入 v2 代币；(b) 在 v2 代币上把欠债用户标记为不可开通信用；(c) 核销并在迁移记录里披露总额。**(a) 或 (b) 需要 v2 模板多一个一次性函数**（`importLegacyDebt(users, amounts)` 或 `setCreditIneligible(users)`，只有 communityOwner 能调，只能在 `creditPolicy` 首次离开 OFF 之前调用，而且之后永久关闭）；(c) 不需要改接口 | 对账记录入库；**这是 7c 的前置验收条件** | 对账 / 放弃记录（文件路径 + sha256） |
| 7c | **先 `SP.updatePrice()`，读回 `cachedPrice.updatedAt > 0` 且未过期**（D3 §8(a)：价格缓存为 0 时 validate 会 revert，得到 AA33 而不是 sigFail）→ `configureOperator` → 取消暂停（此时只有余额模式）。**升级窗口内所有社区的 `creditPolicy` 都保持 OFF**。（v4.0：原来写在这里的"RepCredit 社区 `queueCreditPolicy(AUTO)`，48 h 后 execute"已移出升级窗口：RepCredit 社区开 AUTO 属于 CC-122 R3，在 A4 之后的 RepCredit 独占测量窗内进行） | 探测通过；每个社区一笔余额模式 op 成功 | `updatePrice` tx hash + 区块号 + `cachedPrice.updatedAt` 读回；每个 operator 的 `configureOperator` tx；解除暂停 `setOperatorPaused(op, false)` tx；每个社区验收 op 的 TxHash + UserOpHash + 区块号；每个社区解除暂停后再读一次 `creditPolicy == OFF`（值 + 区块号） |
| 7d | **主网前**（任何时候都可以执行，作者要求保证随时可转）：aPNTs 铸币权交给 Mycelium Safe：先由当前 communityOwner 调 `renounceFactory()`，再 `transferCommunityOwnership(Safe)`（单步转移、没有 accept，**地址必须核对两遍**）。主网的新 aPNTs 部署时直接由 Safe 持有；是否在 mint 里强制上限，见 `apnts-mint-authority.md` §4，由作者决定 | `communityOwner == Safe`；`FACTORY == 0`；EOA 和工厂调 `mint` 都 revert，Safe 调 `mint` 成功（fork 演练，块 11692415，已通过） | `renounceFactory`、`transferCommunityOwnership(Safe)` 的 tx hash + 区块号；`communityOwner` / `FACTORY` 读回区块号；负对照 revert 的调用记录 |
| M1 | **主网前（GOV-1）；在 Sepolia 上就是 A5s**（v4.0 按计划 §8.1 第 2 条、§10.1 ★4 重写）：SP 和 Registry 的 owner 转给 **48h TimelockController**：proposer / canceller 是 AAStar 社区治理多签 = Mycelium 多签 `0x51eD…E114`；**executor 只授予治理多签**，不开放给任何人（这是 §10.7b C2 的纵深防御，合约的正确性不依赖它）；admin 已放弃。**两步转移**（前提：D5b 已随第 5 步、第 5c 步上链）：① EOA 分别调用 `SP.transferOwnership(timelock)`、`Registry.transferOwnership(timelock)`，这只记录 `pendingOwner`，owner 仍是 EOA；② 治理多签在 timelock 上用**一个** `scheduleBatch` 同时提交 [`SP.acceptOwnership()`, `Registry.acceptOwnership()`, `SP.setGuardian(Safe)`]，**只等一次 48h**，然后 `executeBatch`。timelock 配错（角色或 minDelay 不对）时 accept 执行不了，EOA 仍是 owner，这就是天然的中止点。**同一阶段一并转给这把 timelock**（计划 §10.1 ★4，属于 M-6，不是可选项）：`AOAProtocolRegistry` 的 owner（三类白名单都在这一个合约里，token 经 immutable `PROTOCOL_REGISTRY` 引用它）和 AOA 工厂 `xPNTsFactoryV2` 的 owner。**这两个合约都是 OZ v5.0.2 的单步 `Ownable`**（`AOAProtocolRegistry.sol:5`、`:23`；`xPNTsFactoryV2.sol:5`、`:40`，构造时 `Ownable(msg.sender)`，`:191`），不是 GOV-2 的两步所有权：`transferOwnership(timelock)` 一笔即生效，**没有 accept 这一步，也就没有 timelock 配错时的天然中止点**。所以：发送前**地址核对两遍**（与 SP、Registry 第 ① 步写入的 timelock 地址逐字节相同）；发送后立即读回 **`owner() == timelock`**（两个合约各一次，记录区块号）。代价：`revokeApproval`（`AOAProtocolRegistry.sol:82`，onlyOwner）从即时变成 ≥ 48h；已激活对象的应急路径在 token 层（§10.7 O2 行），不受影响。**timelock 的选择**：Sepolia 上已有的 48h TimelockController `0x86C86c789EDc099801cc6a5F48334F1D67dC9564`（`deployments/config.sepolia.json` L32）的角色配置必须先读回，`apnts-capped-deliverable.md` L124 记录治理多签既不是它的 proposer 也不是 canceller；SP 倾向新部署一把符合 GOV-1 的（计划 §8.7）。整条路径（含 `scheduleBatch`）要在 rc1 门槛（A2）的 fork 演练里走通（见下方"rc1 门槛的 fork 演练范围"） | `owner() == timelock`、`pendingOwner() == 0`（SP 和 Registry 都要）；`AOAProtocolRegistry.owner() == timelock`、`xPNTsFactoryV2.owner() == timelock`；timelock `getMinDelay() == 172800`；proposer、canceller、executor 各角色的读回（executor 只有多签）；负对照：原 EOA 调用 `upgradeToAndCall` 会 revert，timelock 在 48h 之前执行也会 revert，非多签调用 `executeBatch` 会 revert | 两笔 `transferOwnership(timelock)`（SP、Registry）；`scheduleBatch` / `executeBatch` 的 tx hash + 区块号；`AOAProtocolRegistry` 与 `xPNTsFactoryV2` 的 `transferOwnership` tx；`owner()`、`pendingOwner()`、`getMinDelay()`、各角色读回区块号；负对照 revert 的调用记录 |
| M2 | **主网前（GOV-2）**：`setGuardian(Safe)`，已包含在 M1 的 `scheduleBatch` 里，不单独排队；演练：guardian 暂停 → validate 返回 sigFail；guardian 尝试恢复、升级、动资金，都 revert；timelock 恢复 | guardian 地址读回；上面各项正对照和负对照 | `setGuardian` 所在的 `scheduleBatch` / `executeBatch` tx；演练中每次 pause、恢复与负对照调用的 tx hash 或 revert 记录 + 区块号 |
| M3 | **主网前（GOV-3）**：确认 `setAPNTSPrice` 只能由 timelock 调用（GOV-1 完成后自动如此） | EOA 调用 revert；timelock 的提案在 48h 之后执行成功 | EOA 调用 revert 的记录；timelock 提案 schedule / execute tx + 区块号 |
| 8 | 旧代币：不迁移余额（旧债已在 7b 处理）；如果需要，另外提供 1:1 兑换合约，由用户自愿兑换，欠债用户能否兑换按 D-21 的结论决定 | — | 兑换合约（如有）的部署 tx + codehash |
| 9 | 下游：SDK / DVT / YAAA 按 02 §8.4 执行；在 airaccount-contract 开 issue（方案 A） | — | 下游 issue / PR 链接 |
| 10 | **（v4.0 改为指针）RepCredit 的后续工作不属于本 runbook**：RepCredit 社区开 AUTO（R3）、SDK 5.5.0 与 YAAA smoke（R4）、在 5.5.0 上按新协议重新实验（R5，含 L249 的同 bundle 实验，放在隔离 harness 里做，不走正式 bundler），都按 **CC-122 R3–R5** 执行，在 A4 之后的 RepCredit 独占测量窗内进行（计划 §7.1、§7.4、§8.3）。AOA 侧的"B 层在真实 Sepolia 上复跑"属于 A4（计划 §7.4 第 4 条、§8.3 第 10 条），证据要求见 §6.1 P2 | — | 由 CC-122 各阶段自己的证据要求约束；本 runbook 不另立 |

**rc1 门槛（A2）的 fork 演练范围（v4.0，计划 §8.1 第 2 条）**。A5s 之后 EOA 路径就没有了，第一次在真链上走 schedule → 48h → execute 时出错，就要再赔 48h，所以感知 timelock 的流程必须在 rc1 门槛就上 fork 演练（不广播）：
1. 第 0–7c 步（EOA 路径）加第 5c 步（Registry）。
2. A3a 完整路径：取消 `0xBb46` → 部署 `APNTsCapped` → 重新排队 → 快进 7 天 → 第 1 步 ④ 执行。（`EVIDENCE-INDEX.md` 记录：第 1 步 ④ 目前**没有脚本**，F-01 只演练到重新排队；这一项要补上。）
3. M1–M3：两步转移 + 一个 `scheduleBatch` [SP.acceptOwnership, Registry.acceptOwnership, SP.setGuardian(Safe)]，以及 `AOAProtocolRegistry` 与 AOA 工厂的单步 owner 转移（含 `owner() == timelock` 读回）；负对照包括 timelock 配错时 accept 执行不了。
4. **感知 timelock 的升级流程**（§10.7b C）：rc1 → rc1′（只改一个无害常量的 dummy bump）经 timelock 升级：部署 impl → `schedule(upgradeToAndCall)` → 48h → `execute` → 读回 `version()` 与实现槽。
5. **C2 的 bundle 中途测试**（§10.7b C2）：A2 冻结 rc1 的 runtime fixture；A3b 之后与链上实测的 runtime codehash 核对，一致才能作为之后 C2 测试里的"上一个发布版本"。实验分支现有的 fixture（`superpaymaster-5.5.0-impl.creation.hex`，22,915 B 那一版源码）早于 `cbcb7045`，不能直接沿用。之后的每一个 rc(n+1)（例如 RDR 复核产生字节码修复时的 rc2）都要跑一次 rc(n) → rc(n+1) 的前向和回滚两个方向的 bundle 中途测试。

**发布身份（v4.0，计划 §8.2 第 5 条）**：rc1、rc2、final 的 `version()` 一律是 `"SuperPaymaster-5.5.0"`，身份用 **commit + runtime codehash** 标识，不用版本字符串区分。**final tag 必须指向最后一个完成 Sepolia 回归的 rc 的同一个 commit**（只多一个 tag），链上 codehash 与从 tag 重新编译的结果逐字节相等。"在 final tag 上重跑全部验收"指离线重跑；字节码没变的话，链上 A4 不用重做。实验分支的 `SPReleaseVersionPin` 测试（`SP.version()`、lens 的 `version()` 与 lens 的 `EXPECTED_SP_VERSION` 三者一致）随 Part B 合入后作为门禁；实验分支上的 `"SuperPaymaster-5.5.1-exp"` 合入时要改回 `"SuperPaymaster-5.5.0"`。

### 6.1 P2 / P4 证据采集规范（强制；登记到 `EVIDENCE-INDEX.md`）

背景：到本节写入时（2026-09-13），**5.5.0 在任何公网上都还没有一笔交易**；P1 的所有交易哈希都只存在于本地 anvil 或本地 fork 上（见 [`EVIDENCE-INDEX.md`](EVIDENCE-INDEX.md) 的 local-anvil / fork-simulation 行）。P2、P4 产生的才是 onchain-real 证据，必须按下面的格式留存，否则不能写进论文。

**通用要求（P2、P4 都适用）**
1. 每一笔交易：tx hash、区块号、区块时间、`from`、`to`、`status`、`gasUsed`、`effectiveGasPrice`，以及**完整回执 JSON**（`eth_getTransactionReceipt` 原样保存）。用 `script/evidence/fetch-public-receipts.mjs` 采集（只读）。
2. 每一次读回：调用、返回值、**读回所在的区块号**；只写"读回通过"不算记录。
3. 每一个部署的合约：地址、部署 tx、runtime codehash、源码 commit、产物路径与编译设置（runs / evm / via_ir），以及与 profile.default 产物的比对结果。
4. 所有文件放在 `docs/design/aoa-balance-mode/data/onchain-real/<阶段>-<日期>/`，同目录放 `EVIDENCE.sha256`（`shasum -a 256 -c` 可验证）和采集脚本的 commit；写入后不再改动，更正只能新增带版本号的文件。
5. RPC：日志扫描按"归档 RPC + 扫描完整性"纪律，两个独立端点交叉比对；含 key 的 RPC URL 不落盘。

**P2（Sepolia，RepCredit F0 硬验收包通过恢复演练之后，CC-122 R1）必须逐条记录**：取消 0xBb46 的切换；部署 APNTsCapped（及 GOV-1 timelock 的 accept）；重新排队 `setAPNTsToken(APNTsCapped)`（排队时刻 ≤ T − 7d，记录 ETA 读回）；质押补足到 1 ETH / 86400 s；部署 GlobalTierSource / AOAProtocolRegistry / seal / 工厂 / 模板；SP 升级到 5.5.0；Registry 升级到 D5b 实现（第 5c 步）；`setXPNTsFactory`；发币；`updatePrice`；`configureOperator`；解除暂停。每步 tx hash + 读回区块号（上表第 4 列）。另外：**AOA 评估社区 `creditPolicy == OFF` 的读回（值 + 区块号）**；**B 层在真实 Sepolia 上的复跑**（每个用例的 UserOpHash / TxHash / 区块号 / bundler 原始响应）。登记模板：`data/templates/p2-sepolia-runbook.csv`。

**P4（OP 主网）必须记录**
- 部署：5.5.0（proxy + impl + v2 栈）以及受控基线 **VerifyingPaymaster、TokenPaymaster** 的部署 tx、地址、runtime codehash、源码 commit 与编译设置。模板：`data/templates/p4-deployments.csv`。
- bundler：自托管 **Rundler** 的版本与 commit、完整配置文件（及其 sha256）、启动命令原文（必须含 `--pool.same_sender_mempool_count 1`）、运行期间的日志。
- 每一笔实验 op 一行 CSV：TxHash、UserOpHash、区块号、`txGasUsed`、`actualGasUsed`、`actualGasCost`、PVG 与各项 gas limit、**L1 数据费**（OP 回执的 `l1Fee` 及其构成字段）、charge（aPNTs 与 xPNTs）、按 G2 同一换算得到的 `charge_eth`、多付率（ppm，定义与 `script/evidence/overpay-stats.mjs` 相同）。模板：`data/templates/p4-op-mainnet-ops.csv`。
- CSV 与**采集脚本的 commit**、原始回执 JSON 一起存档，并附 sha256 清单；多付统计用 `script/evidence/overpay-stats.mjs` 的同一定义（均值 = floor(Σppm / n)，P95 = 最近秩 a[⌈0.95n⌉−1]）重算。

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
- 迁移：在 fork 上把 runbook 完整走一遍（v4.0：范围见 §6"rc1 门槛（A2）的 fork 演练范围"）；遇到旧代币的 operator 返回 sigFail，而不是 AA33。
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
- **B bundler**：Alto 和 Rundler，规则检查打开（Alto 为 safe mode）；版本按 §0 D-9：Rundler v0.11.0 主用、Alto v1.2.5 交叉验证（Alto ≥ v1.2.6 不可用）。要逐项核对：
  - SP 质押是否达到门槛；
  - §2.3 验证期访问清单里的每一行；
  - AirAccount 带 initCode 的首笔，factory 质押在门槛上下两种情况；
  - `renewForSelf` 的实际 trace；
  - 验证期 TSTORE；
  - 各种错误码：AA23、AA24、AA33、AA34。
- **G gas**：`C_WRAP` 上界的 trace；`MIN_POST_OP_GAS` ≥ postOp 最坏路径的实测 gas。
- **迁移**：在 fork 上把 runbook 完整走一遍，包括读回 impl 的三个 immutable。（v4.0：范围以 §6 的"rc1 门槛（A2）的 fork 演练范围"为准，即 0–7c + 5c + A3a + M1–M3 + 经 timelock 的升级 + C2；原来写的"0–10"中第 8–10 步是升级后的迁移和下游工作，放进 rc1 门槛会形成循环依赖，计划 §7.10 第 5 条。）

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
行号对应 `cbcb7045`（v4.0 从原来的 D3 头部 `1f8769c7` 逐行重映射：按原行的源码内容在新树里定位；`SP`、`T`、`B` 有行移，`X` 引用的两行没有变）；`SP` = `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`，`T` = `contracts/src/tokens/v2/xPNTsTokenV2.sol`，`B` = `…/v2/xPNTsV2Base.sol`，`X` = `…/v2/xPNTsTokenV2Ext.sol`，`EP` = 规范 EntryPoint v0.7（codehash `0x8db5ff69…`）。

| 事件 \ 状态 | 用户 xPNTs 余额 | lockedOf | creditReservedOf | debts | operator aPNTsBalance | SP 持有的 aPNTs | protocolRevenue | in-flight `_inflight[h]` | EP ETH 押金（SP） | xPNTs totalSupply |
|---|---|---|---|---|---|---|---|---|---|---|
| operator `deposit(amt)` | | | | | +amt（SP:784） | +amt（SP:773） | | | | |
| operator `withdraw(amt)` | | | | | −amt（SP:838） | −amt（SP:842） | | | | |
| validate 失败（sigFail，SP:1192–1264 各 return） | | | | | | | | | | |
| BALANCE 锁定（validate） | | +x0（T:239） | | | −a0（SP:1267） | | **不变** | 写入 (op, a0)（SP:1269–1270） | −prefund（EP `_validatePaymasterPrepayment`） | |
| CREDIT 预留（validate） | | | +a0（T:304） | | −a0（SP:1267） | | **不变** | 写入 (op, a0)（SP:1269–1270） | −prefund（同上） | |
| postOp 成功（BALANCE） | −xc（T:266） | −x0（T:262） | | | +(a0−c)（SP:1364） | | +c（SP:1365） | 删除（SP:1362） | +(prefund−G)（EP `_postExecution`） | −xc（T:266） |
| postOp 成功（CREDIT） | | | −a0（T:321） | +c（T:324） | +(a0−c)（SP:1364） | | +c（SP:1365） | 删除（SP:1362） | +(prefund−G) | |
| opReverted（BALANCE，用户执行 revert） | −xc（T:266） | −x0（T:262） | | | +(a0−c)（SP:1364） | | +c（SP:1365） | 删除（SP:1362） | +(prefund−G) | −xc |
| opReverted（CREDIT，用户执行 revert） | | | −a0（T:321） | +c（T:324） | +(a0−c)（SP:1364） | | +c（SP:1365） | 删除（SP:1362） | +(prefund−G) | |
| postOp 回滚（I10；用户执行一并撤销） | | 锁留下（活标记随交易结束清零） | 预留留下 | | 暂不退（仍是 −a0） | | **不变** | 保留，活标记清零 | +(prefund−G)（EP 以 postOpReverted 模式二次 `_postExecution`） | |
| stale release（锁，交易之后，任何人） | | −x0（B:318；T:272 入口） | | | | | | | | |
| stale release（预留，交易之后） | | | −a0（B:328；T:328 入口） | | | | | | | |
| `releaseStaleSponsorship(h)`（交易之后，任何人） | | | | | +a0（SP:1378） | | | 删除（SP:1377） | | |
| `withdrawProtocolRevenue(amt)` | | | | | | −amt（SP:864） | −amt（SP:862） | | | |
| `mint(m)` 且有债（自动抵债） | +m − rx（B:251–252） | | | −ra（B:250） | | | | | | +m − rx |
| 用户停用 / 恢复（X:66–67） | | | | | | | | | | |
| 急停 / 更换 SP | 已有的锁、预留照常由原 locker 结算（T:254）或交易后释放 | | | | | | | 原 SP 的 in-flight 照常结算或释放 | | |
| 迁移（§6） | 旧代币不动；v2 从 0 开始 | 0 | 0 | 0 | 原 operator 的余额保留 | | | 空 | | |

前置条件：BALANCE 锁定要求 `balance − lockedOf ≥ x0`，且额度、总额、单笔上限、停用标志都满足（T:189–213）；CREDIT 预留要求 C-1（T:277–288）；postOp 结算要求 L-3（T:252–255，T:315–318）；postOp 入口要求 `gasleft() ≥ SETTLE_GAS_BOUND`（SP:1330）；同一 opHash 的 postOp 只记账一次（SP:1340–1341，P1-17）。
opReverted 与 postOp 成功走同一段代码：SP 的 postOp 不区分 `PostOpMode`（SP:1322）。在两种模式下，速率限制时间戳都会写入（SP:1335–1336）。
`ra`、`rx` 是自动抵债的 aPNTs 额和 xPNTs 额（B:243–254）。
**守恒**：对每一笔 op，operator 净变化 = −c（结算）或 0（回滚后 release）；protocolRevenue 只在 postOp 结算时增加 c。验证期不再预记收入，因此不存在"退款被 protocolRevenue 截断"的问题（R10-M1b）。
**测试**：`SuperPaymasterV55Test.test_balance_mode_end_to_end`（operator 净减 == 收入增 == 烧币量）、`test_I10_stale_sponsorship_restores_operator`、`test_I10_release_refused_while_in_flight`、`test_I8_settle_failure_rolls_back_user_execution_e2e`、`xPNTsTokenV2Test.test_L3_…`/`test_L4_…`，以及 D3 的 A 层和 I 层。

### 10.3 B-6：预留额（规范）

```
a_gas = ceil( maxCost × cachedPrice.price × 1e18 / (10^decimals × aPNTsPriceUSD) )      // 用缓存价，验证期采样（SuperPaymaster.sol:1167–1168 `_calculateAPNTsAmount`，validate 在 :1253 调用；cbcb7045）
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
**`AOAProtocolRegistry` 的 `KIND_SP` 类（协议治理维护的代理地址白名单；token 经 immutable `PROTOCOL_REGISTRY` 调用 `isApprovedSP`，例如 `xPNTsTokenV2.sol:89`、`xPNTsTokenV2Ext.sol:237`、`:263`）**，只确认"这是一个协议认可的 SP 代理"；实现的风险归入 SP 的升级治理（信任矩阵 §10.7）。
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
| SP owner | UUPS 升级；`setOperatorPaused`（`:645`）；`setProtocolFee`（`:515`，上限 20%）；`setTreasury`（`:525`）；`setAPNTSPrice`（`:493`）；`emergencySetPrice`（`:578`，1 h timelock）；`setXPNTsFactory`（`:531`，**即时生效**）；BLS 聚合器（`initBLSAggregator` `:1060`，`queueBLSAggregator` `:1068` / `applyBLSAggregator` `:1075`）；`slashOperator`（`:951`；须先 `queueSlash`（`:953`），24h 冷却（`:956`），经 `_slash(…, true)`（`:957`）每次 ≤ 余额的 30%（`:1027`））；`updateReputation`（`:965`）；`setAgentRegistries`（`:1474`，影响资格判定）；`withdrawProtocolRevenue`（`:852`）；EntryPoint 存款与质押（Base `:48`–`:64`）。行号按 `cbcb7045` | 升级为恶意实现：拿走 EntryPoint 押金与质押、SP 持有的全部 aPNTs（operator 余额 + `protocolRevenue`）；社区 xPNTs **只能被销毁、不能被转走**（SP 不是 spender，A-3），每用户上界见 I6；可以暂停或罚没 operator（`slashOperator` 每次 ≤ 余额 30%、24h 冷却；拿走全部 operator aPNTs 靠的是**升级**，不是罚没）。研究部署下的合计上界见 §10.8 RDR-7 ②③ | 建议把升级权和即时生效的配置放到 timelock 后面（产品改进项）；论文如实写成信任假设 |
| **（DSR，2026-09-13）SP 的升级权** | `_authorizeUpgrade` 是 `onlyOwner`，**没有 timelock**（`BasePaymasterUpgradeable.sol:42`）；owner 是 **EOA `0xb560…`**（Sepolia 实测），单步 `Ownable` | 即时替换实现：可以拿走 operator 存款、revenue、EP 押金和质押；**用户的 xPNTs 受 I6 保护**（token 侧的上界不依赖 SP 的实现） | **主网前决策项**：T1（owner 换成 TimelockController 48 h，Mycelium Safe 担任 proposer/canceller）+ G（guardian 只能暂停和全局停止赞助，恢复必须走 timelock）；Registry 同样处理。评估见 `upgrade-governance-eval.md` |
| Registry owner | 即时替换 BLS 聚合器（`Registry.sol:283`）；立即升级（`:967`）；`setCreditTier`（`:676`）；`setReputationSource`（`:848`）；`setLevelThresholds`（`:870`）；`setSuperPaymaster`（`:276`） | 绕过 BLS、改变 AUTO 额度 | 用户申请上限约束信用暴露（I6）；建议 timelock。黑名单更新现在要求非空 BLS proof（`:619`–`:640`） |
| `AOAProtocolRegistry` 的 owner（一个合约、一个 owner，管三类白名单 `KIND_SP` / `KIND_SPENDER` / `KIND_TIER_SOURCE`，`AOAProtocolRegistry.sol:23–26`；OZ 单步 `Ownable`） | 增删白名单（`bootstrapApprove` `:53`、`seal` `:61`、`proposeApproval` `:66`、`revokeApproval` `:82`） | 把恶意合约加入白名单 | 白名单只是**必要条件**：激活仍需 communityOwner 提议并等 48 h；只在激活时检查，事后移除不影响已激活的；`seal()` 之后"加入"本身要等 48 h（§11.2 第 3 条）；**v4.0：owner 在 A5s / 主网前与 AOA 工厂的 owner 一并转给 GOV-1 的 48h timelock（runbook M1）** |
| （DSR O2）白名单撤销的范围 | `AOAProtocolRegistry.revokeApproval` **只影响以后的激活**，不会撤下已经激活的 SP、spender 或分档源 | 已激活的对象出问题时，白名单撤销无济于事 | 已激活对象的应急路径在 **token 层**：SP → `emergencyRevokePaymaster`（S-4），之后走 S-6 切到备用 SP 或 S-3 换 SP；spender → `removeAutoApprovedSpender`（即时生效）；分档源 → `queueTierSource` 换源（48 h），紧急时可以先 `queueCreditPolicy(OFF)`，或者由用户自己 `disableSpenderForSelf` / `revokeCredit` |
| 工厂（owner） | 创世配置（S-0、A-10）；对已部署 token 发起 SP 提议（S-1，communityOwner 可以取消） | 创世时写入错误的 SP 或 spender | 创世配置读回（runbook 第 7a 步）；之后没有即时权限 |
| communityOwner | 策略切换、MANUAL 批准、调汇率（有上下限）、spender 提议、急停、备用 SP；类型：EOA 或 Safe；可以用 `transferCommunityOwnership` 转让 | 可用性攻击（反复切换）；不能越过用户的申请上限 | 建议使用 Safe；恢复程序：由现任 owner 转让，丢失 key 时无法恢复（论文写明） |
| operator | `configureOperator`、`minTxInterval`、存取 aPNTs | 只影响自己的社区 | — |
| keeper（任何人） | `updatePrice`（Chainlink，permissionless） | 价格来自 Chainlink，keeper 不能伪造 | 陈旧度通过 `validUntil` 约束 |
| BLS 法定人数、中继、能签 UserOp 的主体 | 见 §7 | — | — |

**v4.0 口径**：上表"建议 timelock / 产品改进项"的几处，作者已在 §10.7b 定为主网前的前提（GOV-1 timelock、GOV-2 guardian 与两步所有权、GOV-3 改价走 timelock），白名单与 AOA 工厂的 owner 也在 M1 一并转入。本矩阵描述的是经过 §10.8 研究部署复核闸门（工具验证、有界符号验证、AI 辅助的对抗审阅、能找到时的人工复核）的代码，**没有经过外部审计**；表中的"最坏后果"在研究部署期间由 RDR-6 的押金与铸造上限约束，owner 被攻破时的最坏损失按 RDR-7 计。外部审计只在 §10.8c 产品上线时进行。

### 10.7b 主网前的治理决策项（作者 2026-09-13 决定，经 DSR 转达）

> 编号说明（更正）：本节第一版把"aPNTs 铸币权"记为 GOV-2、"gas 常数参数化"记为 GOV-3。作者的决定使用 DSR 的编号，本节以此为准：原来的铸币权项改为 GOV-4，gas 常数项改为 GOV-5。

| # | 事项 | 作者决定 | 落地 |
|---|---|---|---|
| GOV-1 | SP 和 Registry 的 owner / 升级权 | **同意**：两者的 owner 都改为 **48h TimelockController**，作为主网上线的前提 | runbook 主网前步骤 M1；评估见 `upgrade-governance-eval.md` T1 |
| GOV-2 | 止损开关 + 安全的所有权转移 | **同意**：加 **guardian**（G，只能暂停、只能全局停止赞助，恢复必须走 timelock，不能升级，不能动资金）和 **Ownable2Step** | 要改代码（SP 以及 Registry 的所有权转移）。**存储必须升级安全（见下方 GOV-2 存储设计）**。实现和 Codex 都在主网前完成（D5b），体积按 D5b 实测（main 当前 22,942 B，余量 1,634：v4.0 在 `cbcb7045` 上 `forge build`，default profile，runs 500 / cancun / via_ir，产物 metadata 里的 source keccak 与源码一致；合入 Part B 后约 1,035，这是实验分支在 22,915 B 基线上的测量，合入后必须实测；须拆分，见 D5b-design §1：这正是 D5b 把 SP 拆成核心 + SuperPaymasterAdmin 扩展的原因，"余量 ≥ 1,024"的 CI 检查是发布门槛）；Registry 侧的升级见 runbook 第 5c 步；runbook M1（`scheduleBatch` 里的 `setGuardian`）、M2 |
| GOV-3 | aPNTs 价格（`setAPNTSPrice`） | **走 48h timelock，只能由 AAStar 社区治理多签更改**（即 GOV-1 那个 timelock，proposer 是这把治理多签），**不设 keeper 例外** | GOV-1 完成后自动生效，不另改代码；治理多签 = **Mycelium 多签 `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`**（作者确认，三条链同地址，Sepolia 上是 2-of-3）。作者补充：aPNTs 作为 xPNTs 的一种，发行量和信用由 reputation system 按发行量、行业参数等做动态分析并实时展示，这属于 reputation system 的范围，不进 SP 5.5.x |
| GOV-4 | aPNTs 铸币权（原 GOV-2） | **已定（作者 2026-09-13，经 DSR）**：(b) 两条链都用 `APNTsCapped`：mint 强制上限；调高只能由治理多签 `0x51eD…E114` 经 48h timelock 执行；调低即时生效；minter 和 capGuardian 都是治理多签。**主网初始上限 300,000e18**（DSR 按作者口径计算：10 个社区 × 100 人 × 20 笔/月 × 每笔约 0.624 aPNTs × 12 个月 × 2 ≈ 299,482，取整，约合 $6,000；buffer 收紧后同一口径约为 242,880）；Sepolia 用标明为测试值的上限。(a) 适用于被弃用的旧 aPNTs `0xBb46`：renounceFactory 并转给多签后闲置（已演练，runbook 7d）。**TODO，不进 5.5.0**：(c) 售卖合约（独立小合约，按收款铸造，由多签把 minter 转给它）；(d) SP 侧的存款速率上限；reputation 的背书率监测（EntryPoint 押金价值 ÷ operator 持有的 aPNTs 负债，低于 1.2 报警） | `APNTsCapped` 作为独立小交付物实现，由 DSR 验收；设计见 `apnts-capped-design.md` |
| GOV-5 | gas 常数参数化 + buffer 收紧（原 GOV-3） | **作者决定（2026-09-13）：这些参数不要写死在合约里，要能动态调整，由 SDK 控制；具体方式交 SP 决定。SP 的决定**：两类参数分开处理。① **每笔 op 的 gas limit 和费用参数**（`paymasterPostOpGasLimit`、`paymasterVerificationGasLimit`、`callGasLimit`、maxFee、maxRate）本来就由 SDK 动态设置；② **安全下限和计费常数**（`MIN_POST_OP_GAS`、`SETTLE_GAS_BOUND`、`C_POSTOP`、`C_WRAP`）**不能交给 SDK**：SDK 和 UserOp 都在攻击者手里，C_POSTOP 设低就等于让 SP 补贴，破坏 I9。所以它们由合约强制执行，但**不写死在字节码里**，改成链上治理参数，SDK 从链上的 `gasParams()` 读取当前值，据此动态设置每笔 op 的 gas。**采纳 Part A**（C_WRAP 5k，Codex APPROVE；C_POSTOP 的默认值在 Part B 中定为 175k）。**采纳 Part B 定稿**（v4.0 更新；实验分支 `exp/buffer-and-params`，合约 `6c3a9a0e`，报告 `fe3a728c` 的 `buffer-and-params-experiment.md` B2–B4；Codex 第 1 轮 2 个 HIGH + 1 个 MEDIUM（B2 修复），第 2、3 轮各 1 个 HIGH（B3、B4 修复）；第 4 轮只有 1 条 LOW，是变异表的标注错误，已在 `fe3a728c` 更正，合约代码未改；**Part B 定稿：Codex 5 轮，第 5 轮（收尾，`fe3a728c`）APPROVE**，没有新发现，结论经 SP 协调会话转达，收尾复核记录见 `buffer-and-params-experiment.md`）：① `MIN_POST_OP_GAS`、`SETTLE_GAS_BOUND`、`C_WRAP`、`C_POSTOP` **四个参数打包在一个存储槽**（4 × uint32），待生效值和 eta 在另一个槽；槽全为 0 时取默认值 200k / 160k / 5k / 175k，所以原地升级不需要初始化。② 修改走 `queueGasParams` → 合约内部 **48h** → `executeGasParams`（两者都是 onlyOwner，可以 `cancelGasParams`）；GOV-1 之后 owner 是 48h timelock，所以**从提案到生效 ≥ 96h**（timelock 48h + 内部队列 48h；计划 §8.2 第 6 条：有意的纵深防御，不改）。③ **硬边界**（queue 和 execute 两处都检查）：SETTLE ∈ [155k, 1M]；MIN ∈ [SETTLE + 20k, 2M]；C_POSTOP ∈ [175k, MIN]；C_WRAP ∈ [5k, 50k]。所有能通过边界检查的配置都满足当前的 G 层规则，全下限组合另经 G 层规则和 G2 fuzz 验证补贴为 0（报告 B2 §2）。④ 验证时把当时的整个参数槽作为 **context 的第 12 个字**追加在末尾，context 为 **384 B**；前 11 个字与 5.5.0 完全相同，每个字保持 ABI 规范类型。postOp 按长度区分：384 B 读快照；**352 B 是 5.5.0 产生的旧格式，走旧规则回退**：入口检查用 SETTLE 160k，buffer 用 5.5.0 的原公式（`postOpGasLimit + ⌈10%·(callGas + postOpGas)⌉ + 30k`），结果仍受 a0 封顶。这样即使参数修改或实现升级、回滚发生在 bundle 中途，已通过验证的 op 也按验证时的那组参数结算（C2）。⑤ 中间格式 `e0cf0dc8`（12 字但没有长度判断）和 `fb64e7eb`（快照打包进第 9 个字）**永远不得部署**。⑥ **体积**：SP runtime 23,541 B、余量 1,035（**实验分支上的测量**，那时 main 的基线是 22,915 B；main 此后到 `cbcb7045` 为 22,942 B，D5b 要在合入后重新实测，见 GOV-2 行和 D5b-design §1；基线多出的 27 B 线性叠加会让余量逼近甚至低于 1,024，但 via_ir 下体积不能线性相加，**合入后必须实测**）。**这正是 D5b §1 把 SP 拆成核心 + SuperPaymasterAdmin 扩展的原因**（`D5b-design.md` §1–§2），而"余量 ≥ 1,024"的 CI 检查是**发布门槛**（D5b-design §2 第 7 条；rc1 门槛 A2 的 CI 条件），不满足不能出 rc。放不下时按 D5b-design §1 的规则拆出 SuperPaymasterAdmin 扩展（v3.x 写的"放不下时 Part B 只保留 `C_POSTOP` 和 `SETTLE_GAS_BOUND` 两个参数"这条退路，已被这条拆分规则取代）。另注：C_POSTOP 是 gas 单位，不随 gas 价格或市场波动变化，只随代码或硬分叉（R-AMS）变化；价格因素已经由 `actualUserOpFeePerGas` 和价格快照动态处理 | 与 GOV-2 合并为 D5b 实施，由 DSR 验收 |

**GOV-2 规范（第 3 版）**。第一版写的是"采用 OZ `Ownable2Step`"，不是升级安全的；第二版给了 ERC-7201 的存储设计，但 Codex 收尾审查指出它还有 1 个 Critical 和若干 High/Medium 问题。以下为最终规范，D5b 按此实现。

*A. 存储与继承*
- 事实：SP（`BasePaymasterUpgradeable`）和 Registry 都继承 OZ v5.0.2 的**非 upgradeable** `Ownable`，`_owner` 在顺序存储的 slot 0，紧接着就是 `_status`（slot 1）。**禁止把基类改成 OZ `Ownable2Step`**：它会在 `_owner` 之后插入 `_pendingOwner`，让之后的每一个槽后移一格。
- 两步转移的状态 `pendingOwner` 放在 **ERC-7201 命名空间槽**（`keccak256(abi.encode(uint256(keccak256("aastar.storage.Ownership2Step")) - 1)) & ~bytes32(uint256(0xff))`）。SP 和 Registry 共用同一个 abstract（如 `Ownable2StepNamespaced`，继承 `Ownable`）。
- SP 的 guardian 和全局 `paused` 追加在 SP 顺序布局的末尾，打包进一个槽（`__gap` 从 27 缩到 26，**末端槽位不变**）。**Registry 只加两步转移，不加 guardian。**

*B. 行为（每条都要有测试）*
1. `transferOwnership(newOwner)` **必须显式带 `onlyOwner`**（Solidity 的 override 不会继承修饰器）：记录 `pendingOwner = newOwner`，发出 `OwnershipTransferStarted(owner, newOwner)`。**`newOwner == address(0)` 表示取消**，清空 pending（与 OZ `Ownable2Step` 一致）；再次调用会替换原来的提名。
2. `acceptOwnership()`：`msg.sender == pendingOwner` 才能调用，然后调 `_transferOwnership(msg.sender)`。
3. **覆盖 `_transferOwnership`：先删除 pending，再调 `super._transferOwnership`**。这样任何修改 owner 的路径（accept、initialize、将来的 reinitializer）都会清掉旧的提名，旧提名不能在之后接管。
4. `renounceOwnership()` 一律 revert。
5. **非零 owner**：两边的初始化都必须拒绝 `address(0)`。SP 已经这样做了（`SuperPaymaster.sol:299`，`initialize` 在 `:293`）；**Registry.initialize 目前直接调 `_transferOwnership(_owner)`，不检查零地址（`Registry.sol:87–88`），要补上**。
6. guardian（只在 SP）：`setGuardian` 只能由 owner 调用；guardian **只能**做下面两件事：① `setOperatorPaused(op, true)`，传 `false` 必须 revert（不能沿用现有的 bool setter 简单改成 `onlyOwnerOrGuardian`）；② 把全局 `paused` 从 false 设为 true。**解除暂停（包括逐个 operator 的解除和全局解除）只能由 owner（timelock）执行。** 全局 `paused` 的检查要放在 `validatePaymasterUserOp` 解析 operator 和 paymasterAndData **之前**，这样格式错误的 op 也会返回 sigFail，而不是 revert。**暂停不能影响 postOp、`releaseStaleSponsorship`、token 侧的 stale release**，已经在途的 op 照常结算或释放。

*C. 升级流程（GOV-1 之后）*
- M1 之后，`deploy-core` 当前走的 `UpgradeLive`（EOA 直接调用 `upgradeToAndCall`，`UpgradeLive.s.sol:131`）就不能用了。**需要一个感知 timelock 的流程**：部署新的 impl（按 default artifact、读回校验）→ 在 timelock 上 `schedule(upgradeToAndCall(impl, 初始化 calldata))` → 等 48h → `execute` → 读回 `version()` 和实现槽。这个流程随 D5b 一起实现，并在 fork 上演练；**v4.0：演练是 rc1 门槛（A2）的一部分**，包括 rc1 → rc1′ 的 dummy bump 和 C2 的前向、回滚两个 bundle 中途测试（§6"rc1 门槛（A2）的 fork 演练范围"）。

*C2. OpCtx 是升级兼容面（v3.9，Codex 对实验分支 Part B 第 2 轮审查的 High）*
- 背景：validate 返回的 context 由 EntryPoint 保存，同一 `handleOps` 里的 postOp 会原样收到它。如果 SP 的实现**在同一个 bundle 中途**被升级（owner 是 open executor 的 TimelockController 时，一笔 UserOp 就能执行已到期的升级；即使 executor 限定为多签，只要多签本身是一个以 UserOp 方式运作的 4337 账户，同样可能），前面按旧实现验证的 op，会由新实现来执行 postOp。context 格式一旦不兼容（例如新实现读取旧 context 里并不存在的字节），postOp 就会 panic：用户的执行被撤销，gas 却由 SP 押金承担，这就是押金耗损攻击。
- **规则（v3.10 更正为双向）**：任何 SP 升级都必须保证 context **双向兼容**：① 上一版实现产生的 context 能被新实现正确结算（前向）；② 新实现产生的 context 在**回滚**到上一版之后，也能被上一版正确结算（反向；回滚是支持的操作，见 `docs/deployment/2026-06-01-security-upgrade-checklist.md:117`）。
  - **更正（Codex 对实验分支 Part B 第 3 轮的 High）**：v3.9 写的是"新增信息放进已有字的空闲位"，这是错的。对声明为窄类型的字（例如 `uint8 decimals`），Solidity 0.8 的 ABI 解码器会校验高位（`validator_revert_uint8`），旧实现遇到高位非零就 revert。因此**已有字必须保持 ABI 规范值，不得往里塞位**。
  - 正确做法：新增信息**追加在末尾**（新的一个字）。新实现按长度区分：旧长度走明确、安全的回退，新长度才读取追加的字，其他长度没有快照、按旧规则处理（短于旧长度的在 `abi.decode` 时 revert）；绝不越界读取。旧实现解码静态 struct 时会忽略末尾多出的字节（必须用回滚测试证明，不能靠假设）。
  - **v4.0 与 Part B 定稿核对（一致）**：`6c3a9a0e` 按上面的做法实现：新实现输出 **384 B**（5.5.0 的 11 个字原样不动 + 第 12 个快照字），只在长度恰好是 384 时读第 12 个字；**352 B** 是 5.5.0 产生的 context，走 5.5.0 规则（SETTLE 160k + 5.5.0 的 buffer 原公式，受 a0 封顶，见 §10.7b GOV-5 ④）。回滚方向由 `SuperPaymasterV55UpgradeRace.t.sol` 的回滚测试实际证明（5.5.0 解码 384 B 时忽略末尾的字）。按报告 B4 的更正，长度判断是纵深防御：EntryPoint 用标准 ABI 编码调用 `postOp`，context 是 calldata 的最后一个动态尾部，只删掉长度条件是等价变异（`b-nolen-asm`，四列全绿）。
  - 测试：每次升级都要有两个 bundle 中途测试。前向：op0 经 timelock 从上一个发布版本升级到新版本，后面按旧实现验证的 op 全部正常结算。反向：op0 经 timelock 回滚到上一个发布版本，后面按新实现验证的 op 全部正常结算。**从未发布过的中间格式**（例如实验分支的 `e0cf0dc8` 和 `fb64e7eb`）一律不得部署。
  - **覆盖范围包括 D5b 的扩展函数**（v4.0，D5b-design §2 第 6 条）：D5b 把治理和管理函数移到 SuperPaymasterAdmin 扩展之后，升级时核心和扩展一起更换；bundle 中途测试（从 main 上的 5.5.0 升级到 D5b，以及回滚）要覆盖攻击者的 op 在 bundle 中途经 timelock 执行扩展里的函数（例如已到期的参数修改、暂停），断言已通过验证的 op 照常结算。之后每个 rc 的上一个发布版本，以链上实测 codehash 对应的 fixture 为准（§6"rc1 门槛（A2）的 fork 演练范围"第 5 条）。
- 纵深防御：GOV-1 的 timelock executor 只授予多签（不开放给任何人）；runbook 的升级步骤在暂停状态下进行（第 3 步暂停 operator）。**合约的正确性不依赖这两点。**
- 目前的 5.4.2 → 5.5.0 升级由 EOA 以单独的交易执行，不存在 bundle 中途的窗口；GOV-1 生效之后的所有升级都适用本规则。

*D. 门槛与测试*
- **存储门槛**：`scripts/check_storage_layout.py` 目前只做逐字节相等的快照比对（`:98`），而 `update` 会直接覆盖基线（`:86`），所以它表达不了"只允许写明的新增槽"。D5b 要把它扩展为：与旧基线比较，只允许在列出的位置出现新增项（`__gap` 缩小、末端不变），其他一律报错；另外单独写一个测试，用 `vm.load` 断言 ERC-7201 槽的位置和内容。
- **必须覆盖**：非 owner 提名 revert；替换提名、用零地址取消；只有被提名的人能 accept；每条 `_transferOwnership` 路径都会清空 pending；两个合约的全新初始化（包括 Registry 的零 owner 被拒）；两个代理都从当前线上的旧实现原地升级，状态读回不变；用真实的 48h TimelockController 完成两个代理的 accept；guardian 解除单个 operator 暂停被拒；全局暂停时格式错误的 op 返回 sigFail；暂停期间 postOp 和 release 照常工作。
- **负对照**：一个 scratch 实现改成继承 OZ `Ownable2Step`，布局门槛必须报错；另一个 scratch 实现的 `transferOwnership` 覆盖漏掉 `onlyOwner`，测试必须变红。

### 10.8 研究部署复核闸门（v4.0 改名并重写；原"独立审计闸门"移到 §10.8c）

**作者决定（2026-09-13，计划 §9.1，经 §10 修订；CC-122）**：本文是博士论文的研究制品，**不做付费外部审计**。论文按"已机械验证的损失上界"收窄主张（不主张"资产安全"），把"未经外部审计"写进 limitations，并把主网实验的风险压在实验押金以内。外部审计属于产品上线，见 §10.8c。

**位置**：A4（Sepolia 最终治理状态下的真实链验证）之后、A6（OP 主网部署）之前，是 A6 的硬前置条件。**A6 部署的 commit = 通过本闸门的 final tag**（取代原 AUD-4；final tag 与最后一个完成 Sepolia 回归的 rc 是同一个 commit，见 §6"发布身份"）。部署后仍按 §11.1 R10-M5 的第二条核对链上字节码（SP 实现槽与 runtime codehash、token 模板与克隆的实现地址、`AOAProtocolRegistry`、EntryPoint v0.7 的 runtime codehash，编译器与依赖版本锁定）。复核一旦产生字节码修复，旧的 A4 就作废，要重新出 rc 并在 Sepolia 回归（经 timelock 升级，含 C2 测试）。

| # | 条件 | 负责 |
|---|---|---|
| RDR-1 | 工具验证全部通过：I1–I10 不变量 fuzz（含 G2 的 EntryPoint 级 fuzz）、变异测试、B 层 ERC-7562 合规、对抗测试（含恶意 SP 全 selector） | SP |
| RDR-2 | **Halmos 有界符号验证**核心性质全部通过：A-3（SP 与 `historicalSP` 永远不能 `transferFrom` / `burn(from)`）、I2（额度累计上界）、I6（恶意 SP 只能销毁、不能转走，新债 ≤ 用户申请上限）、I9（没有后盾的赞助 = 0，以"settle 不可静默失败"的形式表达）、`APNTsCapped` 的 CAP-1。分两段交付：D5c-1（A-3、I2、I6、CAP-1）与 D5c-2（I9 + RDR-3）。**这是有界的符号验证，不是覆盖全部输入的完整证明**：I9 是"算术引理 + 具体价格点上的控制流"；I2 / I6 收不拢归纳步时退到深度 k 的有界 invariant，并如实写成"深度 k 有界"；循环展开深度 `--loop N` 等边界和抽象逐条登记进 EVIDENCE-INDEX；Halmos 把除法当作未解释函数，"通过"可靠，反例要在 forge 里用具体值重放（计划 §10.2） | SP |
| RDR-3 | 静态分析：Slither 与 Aderyn 报告逐条分诊（真问题已修 / 误报说明理由），存档并登记进 EVIDENCE-INDEX | SP |
| RDR-4 | **公开征求复核**：代码开源，写好 `SECURITY.md`，在 ERC-4337 社区与 Ethereum Magicians 发出 review 请求；收到的问题逐条记录并处理，致谢写进论文 | 作者 + SP |
| RDR-5 | **能找到人工复核就做**：非作者的安全研究者复核核心的验证与结算路径，签一页复核记录；**找不到就在 limitations 如实写"没有独立人工复核"，不阻塞** | 作者 |
| RDR-6 | **主网风险上界**：① SP 在 EntryPoint 的押金按 **D_cap = N_SP × c̄_eth × (1 + m) + F** 设上限（N_SP 是样本协议里 SP 的 op 总数，包括失败样本和重试；c̄_eth 是 Sepolia A4 实测 P95 乘以 OP 的 maxFee 上限；m 是价格波动余量；F 是押金下限 = B_max × 各项 gas limit 之和 × maxFee 上限），算出后写死在 runbook；基线 paymaster 的押金按同一公式分别计算，一并计入总暴露。**冻结条件是"押金 ≥ F"，不是"押金不变"**：collector 在每笔发送之前读 `balanceOf(SP)`，"余额 − 本笔预估成本 < F"就停止采样，这一笔记为"前置条件未满足"、不发送；只能在窗口之间由协议账户按固定额度补充，每次补充都登记；万一出现 AA31，归为基础设施失败、单独计数（计划 §10.3）。② 主网 `APNTsCapped` 只按实验需要铸造，铸造之后**立即由 capGuardian 执行 `lowerCap(已铸量)`**，使研究部署期间的上限等于实际铸造量，而不是 300,000e18（计划 §10.4）。③ guardian 预先就位。④ 主网实验限定在一个时间窗内，采完就提走押金；GOV-1 之后提款也要走 timelock，所以**窗口开始时就预先 schedule `withdrawTo`，ETA 设在窗口结束时刻**（既不违反"窗口内不能有 timelock 操作到期"，提款也不会晚 48h）。⑤ 只用协议控制的账户，不涉及真实用户资金。⑥ **暴露清单包括旧的主网部署**：OP 主网上现有的 SP `0xA2c9…`（质押 0.1 ETH，owner 是 EOA）和 V4 paymaster 实例；处置二选一（暂停并提走押金、解除质押；或者明确写成"不在研究部署范围内"并列出现有押金），**待作者在 A6 前决定（W-2）**；主网 SP 的质押暴露（保持 ≥ 1 ETH，或自托管 Rundler 调低 minStake）同样**待作者决定（W-1）**（计划 §10.1 ★3、§10.5） | SP + 作者 |
| RDR-7 | **作者书面接受风险**：A6 放行时，作者签一份风险接受记录，写明实际押金、aPNTs 铸造量、时间窗与最坏损失。**最坏损失**（计划 §10.1 ★2；v4.0 按 `cbcb7045` 源码补全，行号为 `SuperPaymaster.sol`，另注明的除外）：<br>① **合约漏洞被利用时 = 押金**。理由：`operators[op].aPNTsBalance` 在源码里只有三类减少路径：(a) validate 的在途预留 `−a0`（`:1267`），postOp 退回 `a0 − c`（`:1364`，`c ≤ a0`，`c` 记入 `protocolRevenue`，`:1365`），或交易后 `releaseStaleSponsorship` 全额退回（`:1378`），所以每笔 op 的净扣减 ≤ a0，且就是这笔 op 的 gas 结算额；(b) `withdraw`（`:838`），只能由 operator 本人取自己的余额；(c) `_slash`（`:1035`、`:1039`），入口是 BLS 路径 `executeSlashWithBLS`（`:977`，只有 `BLS_AGGREGATOR` 能调，每次上限为余额的 30%，`:1027`）和 owner 路径 `slashOperator`（`:951`；须先 `queueSlash`、24h 冷却，同样经 `_slash(…, true)`（`:957`）每次 ≤ 余额的 30%）；罚没额记入 `protocolRevenue`，仍在 SP 内，只能由 owner 经 `withdrawProtocolRevenue`（`:852`）取出。所以只要不是 owner 或 BLS 法定人数，按代码的预期路径 operator 的 aPNTs 不会流出 SP。"= 押金"的前提是被利用的漏洞不打开 (a)–(c) 之外的扣减路径：守恒测试（§10.2 守恒、`test_balance_mode_end_to_end`）和 RDR-1 / RDR-2 支撑这一点，但**它不是证明，列为待验证假设**。BLS 法定人数被攻破属于信任假设（研究部署中三把 guardian 私钥由同一方持有，见 RepCredit 的 limitations），不算在这一格里。<br>② **owner 被攻破时 = 押金 + 质押（≥ 1 ETH）+ SP 持有的全部 aPNTs（operator 余额与 `protocolRevenue`；研究部署下 operator 由协议控制，二者都是 `APNTsCapped`，合计 ≤ 已铸造量，即 `lowerCap` 之后的 cap）+ 社区 xPNTs 的销毁量（见 ③）**。**路径说明（v4.0.1 更正）**：拿走全部 operator aPNTs 靠的是**升级**成恶意实现；`slashOperator` 单独使用时每 24h 最多扣余额的 30%（n 次后剩 0.7ⁿ），GOV-1 之后每次还要先等 48h timelock。质押部分：owner 要先 `unlockStake`、等 86400 s 再 `withdrawStake`，GOV-1 之后每一步还要先等 48h timelock，所以至少有 48h + 1d 的可见窗口，但 guardian 无法阻止。<br>③ **恶意（被升级的）SP 能销毁的社区 xPNTs**：SP **不是** spender：S-0 不把它写入 `autoApprovedSpenders`（`xPNTsTokenV2.sol:87–93`），`transferFrom` / `burn(from)` 对当前 SP 和 `historicalSP` 一律 revert（A-3，`xPNTsTokenV2.sol:146`）。它能造成损失的只有锁定→结算（`tryLockForGas` `xPNTsTokenV2.sol:224` → `settleLocked` `:249`）和信用（`tryReserveCredit` `:298` → `settleCredit` `:312`）两条路径，上界就是 I6：每个用户，锁定路径结算的 aPNTs 等值 ≤ `min(该 SP 的剩余自动额度 + K·SP cap, 剩余总额 + K·总额上限)`（`_remainingWith`，`xPNTsV2Base.sol:275–285`；SP 转述的续期在 `_lockDecision` 里把两处 `used` 视为 0，受 `autoRenewUsed < K` 约束，`xPNTsTokenV2.sol:198–205`；`K = 1`、默认 SP cap = 默认总额 = 5,000 aPNTs，`xPNTsV2Base.sol:29–32`；`renewalMode` 为 `ACCOUNT_ONLY` 的账户没有 SP 转述续期，`K·cap` 一项为 0，`xPNTsTokenV2.sol:199`），折合的 xPNTs 按锁定时的汇率计，且不超过余额；信用路径新增债务 ≤ `effectiveCreditCap` ≤ 用户自己的 `requestedCap`（`xPNTsTokenV2.sol:336–349`），`creditPolicy == OFF` 时为 0（`:338`，AOA 评估社区就是 OFF）；债务之后在给该用户 mint 时自动抵扣，烧掉的是新铸的 xPNTs（`xPNTsV2Base.sol:242–256`）。xPNTs **只能被销毁，不能被转走**（I6、A-3）。研究部署中所有账户都由协议控制，所以这一项 ≤ Σ（各测试账户的上述上界）。源码给出的上界与 §4 I6 的文字一致，没有发现出入 | 作者 |

**AI 多轮对抗审阅（Codex）是 RDR-1 的前置条件**，在论文里如实写成"**AI 辅助的对抗审阅**"，不是审计，也不冒充独立审计。Slither、Aderyn、Halmos、fuzz 同样只是工具验证。

**论文措辞（计划 §10.1 ★1，P5 使用）**：
> We verify bounded-loss properties (I1–I10) of the evaluated commit by EntryPoint-level invariant fuzzing, mutation testing, bounded symbolic verification of the core invariants (Halmos; bounds and abstractions listed in Appendix X), and ERC-7562 compliance checks on two production bundler implementations (Rundler v0.11.0, Alto v1.2.5) in a local environment. The artifact has not undergone an external security audit; mainnet measurements were conducted with protocol-controlled accounts under capped deposits, and production deployment would require an independent audit.

### 10.8b R-AMS：Amsterdam（EIP-8037/8038）的前向兼容风险（v3.9，D5 B0 发现）

当前目标链（Sepolia、OP 主网、OP Sepolia）都在 Osaka（证据见 `b-layer/README.md` §0）。一旦 Amsterdam 在某条目标链上激活，EIP-8037（state-gas 计量）和 EIP-8038（state 访问重新定价）会让 SSTORE、SLOAD、CALL 变贵。在 geth 的 Amsterdam 级 dev 链上已经实测到：验证期写一个新槽，会耗尽 100k 的 paymaster 验证 gas。影响如下：
- 验证期写入（锁记录、预留、在途记录，都是从零写成非零）→ `paymasterVerificationGasLimit` 要调高（SDK 侧）。
- **（v4.0 更新）Part B 合入之后，`SETTLE_GAS_BOUND`（默认 160k）、`MIN_POST_OP_GAS`（默认 200k）以及 `C_POSTOP`、`C_WRAP` 是有硬边界的治理参数**（§10.7b GOV-5：SETTLE ∈ [155k, 1M]，MIN ∈ [SETTLE + 20k, 2M]，C_POSTOP ∈ [175k, MIN]，C_WRAP ∈ [5k, 50k]），不再是写死在字节码里的常量；但默认值和硬边界本身仍在字节码里。在 Amsterdam 下它们可能不够用，不够时 postOp 会 revert，也就是 I10 情形：用户的执行被撤销、没有损失，但赞助不可用。（Part B 合入之前，即 `cbcb7045` 的 5.5.0，它们仍是字节码常量：`SuperPaymaster.sol:107`、`:124`。）
- **调整时效**：GOV-1 之后，经治理调整参数要 **≥ 96h**（timelock 48h + SP 内部参数队列 48h，计划 §8.2 第 6 条；有意的纵深防御，不改）。这个时效写进论文的 limitations。**所需的值超出硬上界**（或者 Amsterdam 让 W_postop、wrap 上升到需要提高硬下限，见实验报告 B2 §2 的 R-AMS 注）时，仍然只能通过 SP 的 UUPS 升级（GOV-1 之后同样经 48h timelock，并遵守 C2）。
- **触发条件（可检查）**：任何一条目标链公布了 Amsterdam 的激活时间 → 在 Amsterdam 级的链上重跑 G 层（T-R14-09、no-OOG 扫描、C_WRAP）和 B 层 → 如果当前参数不够，在硬边界内的，走 `queueGasParams` → `executeGasParams`（≥ 96h）；超出硬边界的，走 UUPS 升级；两种情况都同步更新 SDK 的 gas 取值。由于调整至少要 96h，重测必须在激活时间之前至少留出这段时间（再加上 UUPS 路径所需的开发与复核时间）。
- **上线前检查（runbook 第 0 步的附加项）**：用 `eth_config` 读目标链的 `current` 和 `next` fork（如果链不开放 `eth_config`，就用该链官方公布的升级时间表，外加 opcode 探针）。**`next` 是 Amsterdam，或者已经启用了 EIP-8037/8038，就阻塞上线**，先完成上一条的重测。
- 论文口径：所有测量都注明硬分叉层级（Osaka + BPO2），R-AMS 写进 limitations 和前向风险（DSR 负责）。

### 10.8c 产品上线审计闸门（v4.0 新增；内容来自原 §10.8 AUD-1…AUD-4 与 §11.1 R10-M5）

**触发条件**：产品面向真实用户、有真实资金流入时才启动（届时再考虑外部审计或资助渠道，计划 §9.3 O-2、O-3）。**与论文无关**，不是论文的前置条件。**在它通过之前，任何主网部署都只能作为"研究部署"**，受 §10.8 RDR-6 的上限约束。

| 步 | 内容 | 验收 |
|---|---|---|
| AUD-1 | 冻结审计 commit，写明范围：SP 5.5.0（**含 D5b 的 SuperPaymasterAdmin 扩展**）、**Registry 的 GOV-2 改动**（两步所有权、零 owner 拒绝，runbook 第 5c 步）、xPNTs v2 模板（核心 + 扩展）、AOA 工厂、`GlobalTierSource`、lens（如有）、`AOAProtocolRegistry`（三类白名单都在这一个合约里）、**`APNTsCapped`**，以及 **TimelockController 的配置**（proposer / canceller / executor / admin、minDelay） | commit hash 与范围写进 `docs/audit/` |
| AUD-2 | 由**独立的外部审计方**审计（不能由 Slither、Echidna、Halmos 或 AI 审阅代替，它们只是前置条件） | 报告原文入库 |
| AUD-3 | 修复 commit；有 High 或以上的修复时，必须复审。审计 commit 之后**任何**在范围内的代码改动都要审计方复审；未解决的 Medium 要逐条说明处理（§11.1 R10-M5 第一条） | **High 及以上全部关闭**，复审结论入库 |
| AUD-4 | 产品上线所用部署的 commit 必须等于"审计 commit + 已复审的修复"；审计产生字节码修复 → 旧的 A4 作废 → 出 rc(n+1) → 经 timelock 在 Sepolia 回归（含 C2），版本标识按 §6"发布身份" | 部署记录里写明 commit 对应关系 |
| AUD-5 | 部署后核对：SP 实现槽和 runtime codehash、token 模板与克隆的实现地址、`AOAProtocolRegistry`，以及 EntryPoint v0.7 的 runtime codehash；锁定编译器和依赖版本（§11.1 R10-M5 第二条） | 核对记录入库 |

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
| R10-M1b | postOp 回滚时 operator 的 `a0` 被直接记成收入 | **D2 实现在途预留**：validate 时 `operator.aPNTsBalance −= a0`，`inflight[opHash] = (operator, a0)` 写在 SP 自己的存储里（SP 已质押，STO-031），并 TSTORE 一个活标记；postOp 时 `protocolRevenue += c`，`operator += a0 − c`，删掉 inflight；新增 `releaseStaleSponsorship(opHash)`（任何人都能调、幂等、要求活标记为 0），把 `a0` 全额退回 operator。这样也去掉了"退款被 protocolRevenue 截断"的问题（SP `:1397`，指 R10-M1b 之前的代码；该截断逻辑在 5.5.0 中已不存在，`cbcb7045` 的 `:1397` 是别的代码）。体积按 D4 实测 |
| R10-M2 | §10.2 的表和现有代码不一致（退款被截断；opReverted 行留了空格） | 以在途预留为准重写表格；opReverted 按 BALANCE 和 CREDIT 拆成两行，各自完整写出增减量（D6 补 file:line 时一并完成） |
| R10-M3 | §10.3 buffer 的量纲没写清楚 | `bufWei = (postOpGasLimit + ⌈(callGasLimit + postOpGasLimit)·10/100⌉ + C_WRAP) × actualUserOpFeePerGas`；`c = min(a0, ⌈calc_snap(actualGasCost + bufWei) × (BPS + fee) / BPS⌉)`。**`calc_snap` 用验证时的价格快照**，通过 context 传给 postOp，不在 postOp 里重新读缓存价 |
| R10-M4 | §10.5 的 `SP_REGISTRY` 没有同步到前文 | 实现中 SP 登记在 `AOAProtocolRegistry` 的 `KIND_SP` 下，按地址登记；§2.5 的 S-0 / S-1 / S-3 / S-5 / S-6 一律指这个地址白名单，不再说 codehash；§10.7 补上"S-0 创世不需要 48 h"这个例外 |
| R10-M5 | §10.8 审计闸门没有证明"部署的字节码就是审计过的字节码" | AUD 追加两条：审计 commit 之后**任何**在范围内的代码改动都要审计方复审，未解决的 Medium 要逐条说明处理；部署后核对 SP 实现槽和 runtime codehash、token 模板与克隆的实现地址、`AOAProtocolRegistry`，以及 EntryPoint v0.7 的 runtime codehash，并锁定编译器和依赖版本。（v4.0：这两条随原 AUD 一起移到 §10.8c 的 AUD-3、AUD-5；部署后核对这一条同样适用于 §10.8 研究部署） |

### 11.2 实现期发现（D1）

1. **单体 token 实测 30,388 B，超过 EIP-170。** 拆成核心（`xPNTsTokenV2`，19,509 B）和扩展（`xPNTsTokenV2Ext`，21,922 B），扩展经 fallback 以 DELEGATECALL 调用；
   存储布局由同一条继承链保证一致，并由 `scripts/check-xpnts-v2-layout.py` 复核。**验证期入口全部在核心合约里。** 以此取代 §5 里 token 的体积估算。
2. **工厂改为接收预先部署好的模板**（EIP-3860：核心和扩展的创建码加起来放不进工厂的构造函数）。部署顺序见 D1-traceability §1。
3. **白名单合约 `AOAProtocolRegistry` 有部署期 bootstrap**：`seal()` 之前 owner 可以即时批准，之后新增批准要走 48 h，撤销即时生效，`seal()` 不可逆。**runbook 第 4 步**改为"部署 → bootstrap → `seal()` → 读回 `sealed_() == true`"，这一步完成之前不得部署工厂，也不得有任何社区发币。**信任矩阵**：`seal()` 之前 owner 对三类白名单是完全信任，之后新增要经过 48 h 公示。
4. **SDK 要合并核心和扩展的 ABI**，因为调用都发往同一个地址。
