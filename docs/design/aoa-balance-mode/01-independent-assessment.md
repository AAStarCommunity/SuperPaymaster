# 01 · 独立评估：逐项结论

> 评估对象：DSR `AOA_Decision_1_2_RouteA_BoundedAllowance_2026-09-12.md` §8、§9、§11。
> 行号对应 `main @ 3b0d4821`。结论分四种：**OK / 需要修改 / 需要增加 / 不可行**。
> ERC-7562 规则编号以规范正文为准。这里同时写出规则的语义，编号记错时可以按语义复核。

## 0. 先说结论

作者定的方向（A2 验证期锁定、用户级信用开关、有界免授权额度）在 SP 这边**可以实现**。
但 DSR §9 的清单里有 **4 处需要改设计**，否则要么过不了 bundler 模拟，要么上线当天就坏：

1. **X1 的存储键顺序写反了。** ERC-7562 判断一个槽是否"与 sender 关联"，看的是最后一层
   keccak 的前 32 字节是不是该地址。所以 `mapping(user => mapping(spender => …))` 的最终槽
   是与 **spender** 关联的，**用户要放在最内层**。
2. **X2 不应在 validate 里校验 1271 签名。** 续期可以直接放进 `paymasterAndData`：
   EntryPoint v0.7 的 userOpHash 覆盖了 `paymasterAndData`，账户对这笔 UserOp 的签名本身
   就是授权。这样 validate 里既没有 1271 调用，也不用读 `deadline`（验证期禁止 TIMESTAMP）。
3. **X7（信用授权放在 token 里）+ Q8①（升级前给 RepCredit 用户批量写授权）做不到。**
   存量代币是 EIP-1167 克隆，不能加存储，所以旧代币上根本没有 `creditApproved` 这个槽可写。
   建议改为：**SP 保留一条 legacy 路径**，旧代币的 operator 继续按现状（信用路径）运行，一个
   字节都不变；只有新代币才走 balance mode。这样 RepCredit 不需要任何批量写入。
4. **漏了"锁定悬挂"。** 首次 postOp 回滚时，EntryPoint 不会再调用 paymaster，锁定的余额会
   永久冻结在用户账户里。需要一条释放路径，而且这条路径不能在同一笔交易里被用户用来
   自抽干。

另有 1 条要先核实的外部前提：SP 在 Sepolia 上只质押了 **0.1 ETH**。验证期读写 token 的
全局槽（STO-031/032/033）要求 paymaster 已质押，而且质押额要达到目标 bundler 设定的
`MIN_STAKE_VALUE`。规范只说这个值按链设定（约合 $1000 的原生币），**我没有核实过 Alto /
Rundler / SuperRelay 的实际配置**，必须实测。

体积：余量 1,007 B **已实测**。**F1（把 dryRun 拆到 lens 合约）实测能腾出 2,150 B**，拆完
余量是 3,157 B。按 02 的方案估算 SP 需要新增约 950–1,250 B，所以 **F1 是必需的，也是够的**。

---

## 1. xPNTsToken（X1–X8）

| # | 结论 | 理由 |
|---|---|---|
| X1 按 (用户, spender) 的额度与累计值 | **需要修改** | ① **键顺序**：DSR 写"用户在外层 → 与 sender 关联"，这是反的。Solidity 对 `m[k1][k2]` 算的槽是 `keccak(k2 ‖ keccak(k1 ‖ p))`，ERC-7562 的关联判据是 `slot == keccak(A ‖ x) + n`，所以这个槽关联的是 **k2**。要写 `mapping(address spender => mapping(address user => …))`，也就是**用户在最内层**；每用户总额的槽 `m[user]` 本来就关联 user。（spender=SP 时反过来写会落到 STO-032"与实体关联"，SP 已质押时也能过，但那是另一条规则，而且依赖质押。）② **扣减面**：额度必须同时约束三条路径：`transferFrom`、`burn(address,uint256)`（`xPNTsToken.sol:1072`）、SP 的特权锁定路径。只改 `allowance()` 的返回值不够，因为现有的 `_spendAllowance` 对名单内 spender 直接 return（`:469`）。③ **显式 `approve` 与自动额度的关系**要定义（建议：先用显式 approve，不够时再用自动额度），否则 aPNTs 的 operator `deposit`、x402 等依赖 `transferFrom` 的路径语义不清。④ 计价用 aPNTs（Q7），扣减时按"锁定时汇率"换算 |
| X2 EIP-712 续期与调额 | **需要修改** | 拆成两条路径：**(R1) UserOp 内续期**：`paymasterAndData` 里带一个标志位，SP 在 `lockForGas` 时先把已用额度清零。账户对 userOpHash 的签名覆盖 `paymasterAndData`（v0.7 `UserOperationLib` 对它做了 hash），账户签名失败时 EntryPoint 以 AA24 整笔回滚，paymaster 写的状态随之撤销。所以**不需要 1271，不需要 deadline，也不需要单独的 nonce**。只允许"清零"，不允许"调高"。**(R2) 独立交易调额**：`setAutoAllowance`（用户直接调用）和 `setAutoAllowanceBySig`（ECDSA + ERC-1271，经 OZ `SignatureChecker`，带 nonce 和 deadline）。它在验证期之外执行，ERC-7562 不管。调高上限只能走 R2，因为调高需要比"能发 UserOp"更强的授权（见 §8 的 a、c）。**v2 补充**：token 无法区分 renew 是不是来自真实的 UserOp，所以 R1 必须限次（02 D-13），否则恶意 SP 可以无限次清零额度 |
| X3 托管锁定 `lockForGas` / `settleLocked` | **OK，需要增加 4 点** | 方向正确：在 token 内部按用户做余额冻结，不发生转账，也不写 SP 在 token 里的余额槽。需要补的：① `lockForGas` **不能用 `nonReentrant`**（它会写 `_reentrancyStatus`，`:140`，这是非关联的全局槽）；也不能调 `_checkAndConsumeRateLimit`（`:943` 读 `block.timestamp`）；也**不能写任何全局计数器**（比如 `totalLocked`）。② 需要按单笔记账：`_locks[opHash][user]`（用户在最内层，是关联槽，**验证期可以写**）。"验证期不能写 opHash 键存储"这句话过强：决定能不能写的是**槽的关联关系**，不是键里有没有 opHash。`usedOpHashes[opHash]`（单层键，`:114`）不关联任何地址，所以它继续只在 postOp 里写，这一点不变。③ **锁定悬挂**（见 02 §2.4）。④ `settleLocked` 用**锁定时的汇率**（`xLocked / aReserved`）换算，避免同一 bundle 里汇率变化让结算超出锁定额 |
| X4 spender timelock | **OK，需要增加 1 点** | 急停之后换 SP 地址也要走 timelock，意味着 gas 路径会停 48 h。需要作者接受这个代价，或者允许"换回到一个已激活过、并通过 codehash 校验的 SP"。移除 spender、急停都即时生效，同意 |
| X5 codehash 白名单 | **需要修改** | ① **SP 是 UUPS 代理**，`extcodehash(SP)` 是代理自己的代码，永远不变；换 impl 不会改变它。所以"审计过的就是链上跑的那份"**对 SP 不成立**，只对不可升级的合约（如 `X402Facilitator`）成立。论文信任矩阵要写明：SP 的 impl 升级由 SP owner 治理，codehash 白名单约束不到。② 白名单不要放在 `FACTORY` 上读：`renounceFactory` 之后 `FACTORY = 0`（`:692`），白名单就没了来源。建议作为**模板的 immutable**（克隆通过 delegatecall 共享模板的 immutable）指向一个协议级登记合约 |
| X6 初始化时不把工厂加进名单 | **OK** | 已核实 `xPNTsFactory.sol` 里没有 `transferFrom`、`burn`、`burnFrom` 调用；工厂只以管理员身份（`onlyFactoryOrOwner`）调用 token |
| X7 用户级信用授权放在 token | **OK（只对新代币）/ 与 Q8① 冲突** | 放在社区自己的 token 里，治理边界最自然；SP 在验证期读 `creditLimitOf[user]` 是关联槽，没问题。**但它只存在于新模板**：旧克隆加不了这个槽，所以 DSR §11 Q8① 的"升级前批量写入授权"**不可行**。改用 legacy 路径（见 §8 的 f） |
| X8 新事件 | **OK** | 另加 `LockCreated / LockSettled / LockReleased`，方便链下对账和写 I4 不变量 |

## 2. SuperPaymaster（S1–S8）

| # | 结论 | 理由 |
|---|---|---|
| S1 validate 分流 | **需要修改** | 分流条件要先看 **operator 的代币代际**，再看用户授权：`gen == LEGACY` 时完全走现有代码；`gen == V2` 时先尝试 `tryLockForGas`（余额优先），不够再看用户是否获批信用。代际标志放在 `OperatorConfig` slot 0 的 byte 18，**0 = legacy**，这是升级安全的方向（与 credit-switch 的 `creditDisabled` 同一个道理）。已实测两个存量 operator 这几个字节都是 0。"获批用户也先走余额"是 DSR §2.4 的原意（"余额不足时才允许记债"），这里写成代码分支 |
| S2 `maxCost` 超上限直接拒绝 | **OK，建议挪到 token** | 由 `tryLockForGas` 在 `reserve > maxSingleTxLimit` 时返回失败，SP 不用多写代码。信用路径也要在验证期拒绝同样的情况（现在只在 postOp 的 `recordDebt` 里检查，`xPNTsToken.sol:540`） |
| S3 postOp 结算 | **OK，需要增加 2 点** | ① buffer 需要 `callGasLimit` 和 `paymasterPostOpGasLimit`，要从验证期通过 context 传过来。context 变长会增大 `c_wrap`，所以 c_wrap 的上界要按最终的 context 长度测。② `settleLocked` 包在 try/catch 里；进入 catch 时发 `SponsorshipUnbacked` 并置 `isBlocked`，**不写 `pendingDebts`**。现有的 `finalCharge`（`:1393`）只是 actual × (1+fee)，没有 postOp gas 和惩罚项的 buffer；v2 分支用 DSR §3.1.3 的公式，legacy 分支保持不变 |
| S4 第三路径 | **OK** | 只在 v2 分支上加。`pendingDebts += amount`（`:1490`）位于 if/else 之外，这个事实 credit-switch 已经证明过，新代码不能复用那个 else 分支 |
| S5 dryRun 同步 | **OK，随 F1 一起挪到 lens** | 见 F1 |
| S6 指向新工厂（T-A） | **需要修改** | 见 T-A：只切一次，直接切到 AOA 工厂 |
| S7 同 bundle 限频不改 | **同意** | v2 余额模式下每笔都先锁钱，同一 bundle 的第二笔在验证时就看到可用余额已经减少；operator 那边的 aPNTs 在验证期逐笔预扣（`:1228`，写的是 SP 自有存储）。`minTxInterval` 只剩防刷作用，论文不能再把它当安全机制 |
| S8 retry / clear 不改 | **同意，附一个条件** | 对**未获批**的 v2 用户，I3 保证 `pendingDebts` 永远不增加，这两个函数对他们没有作用。但对 legacy operator 和**获批信用**的 v2 用户，`onlyOwner` 仍然握着把 `pendingDebts` 变成真债务的按钮（`:1510`）。信任矩阵要把这一行写全，不能只写 AOA 评估社区的情况 |

## 3. 链上一致性（T-A、T-B）

| # | 结论 | 理由 |
|---|---|---|
| T-A SP 指向新工厂 | **需要修改** | ① DSR 写的目标是 `0x9f426568…`。但托管新 aPNTs 的是 `0x0E54b9e2…`，两者都与源码一致（已实测）。更重要的是，AOA 本身就需要**新模板 + 新工厂**，所以任何过渡性的切换都要再切一次。建议**只切一次，直接切到 AOA 工厂**。作者对 CC-119 T5 的决定（"用新工厂"）在执行时就落到这个地址。② DSR 说"换工厂后存量社区校验失败"，需要澄清：影响的只是**重新调用** `configureOperator`（`:277`，只在配置时校验 `getTokenAddress`，`:292`）。已配置的 operator 在 validate 和 postOp 里完全不读工厂，照常运行。③ "新工厂登记旧代币"**不可行也不可取**：工厂没有登记函数（只有 `deployxPNTsToken`）；而且旧代币没有 `lockForGas`，登记进来会得到一个声称支持 v2、实际一调就 revert 的 operator |
| T-B 实例代币比对 | **OK，给出方法** | 克隆的 runtime 是 45 字节的 EIP-1167 代理，直接比 `cast code` 没有意义。正确步骤：① 从代理字节码里取出 impl 地址，核对它等于 `factory.implementation()`；② 用模板的 runtime 和本地 artifact 比对，并按 `immutableReferences` 屏蔽 immutable 区间（方法同 [`../credit-switch/01`](../credit-switch/01-onchain-vs-local.md)）；③ 读出存储里的实际取值：`exchangeRate`、`SUPERPAYMASTER_ADDRESS`、名单、上限、`FACTORY`。第 ③ 步不能省，字节码一致不代表配置一致 |

## 4. 体积方案（F1–F4）

| # | 结论 | 理由 |
|---|---|---|
| F1 dryRun 拆到 lens | **OK，实测 −2,150 B（DSR 估 1,500–2,500）** | ① lens 需要的状态在 SP 上**全部已经是 public**：`operators`、`userOpState`、`sbtHolders`、`pendingDebts`、`cachedPrice`、`protocolFeeBPS`、`priceStalenessThreshold`、`aPNTsPriceUSD`、`isEligibleForSponsorship`。**不需要新增 getter**。内部常量（`MIN_POST_OP_GAS`、`VALIDATION_BUFFER_BPS`、各 offset）在 lens 里复制一份，并通过 `sp.version()` 校验版本号，版本不匹配就拒绝返回结果，不静默给出错误答案。② **对 SDK 的影响**：`aastar-sdk` 的 `packages/core/src/actions/superPaymaster.ts:1019`（`dryRunValidation` action 及其测试）要改成调用 lens；**`scripts/repcredit-e2e.ts:1131`、`:1235` 也调用它**，而这是 RepCredit 的证据工具，见 §8 的 f。本仓库的 `script/gasless-tests/test-group-I1-credit-ceiling-h1.js` 也要改。③ 这是公开 ABI 变更：要 bump `version()`、重新生成 `abis/`、通知 sdk 和 dvt。④ 必须有 **lens ↔ validate 一致性测试**（把两者对同一批 fuzz 输入的答案逐一比较）。dryRun 以前在 SP 内部都出现过漂移，挪到外部之后只会更容易漂移 |
| F2 逻辑尽量放进 xPNTs | **OK** | token 余量 9,275 B；估算 v2 新增约 4–5 KB，放得下（实现后实测）。工厂的 initcode 包含 token 的创建码，现在 25,182 B，远低于 EIP-3860 的 49,152 B |
| F3 价格换算做成外部库 | **可行但不建议** | 只省几百字节；验证期多一次 DELEGATECALL（ERC-7562 允许），但多了一个要部署和核对的地址。有了 F1 就不需要它 |
| F4 降低 optimizer runs | **同意，作为最后手段** | 会改变论文的 gas 数据；在 F1 之后没有必要 |

---

## 5. 专题 a · A2 放在 xPNTs 内部，能不能过 bundler 模拟

**原则上能，前提是满足以下五个条件；最终以目标 bundler 的整 bundle 模拟为准。**

| 条件 | 说明 |
|---|---|
| ① SP 已质押，且达到 bundler 的 `MIN_STAKE_VALUE` | `lockForGas` 要读 token 的全局槽（`exchangeRate`、`SUPERPAYMASTER_ADDRESS`、`emergencyDisabled`、`maxSingleTxLimit`、默认额度）。这些是非关联存储的只读访问，要求实体已质押（STO-033）。**现有 validate 已经依赖这一点**：它读 `token.exchangeRate()`（`:1205`），还读 Registry 的信用分档。实测 Sepolia 上 SP stake = 0.1 ETH、unstakeDelay = 86,400 s；unstakeDelay 达标，**stake 是否达标取决于 bundler 配置，未核实** |
| ② 验证期只写与 sender 关联的槽 | `_balances[user]` 不写（锁定不发生转账），`lockedOf[user]`、`_auto[SP][user]`、`_budget[user]`、`_locks[opHash][user]` 都要**把用户放在最内层**。**不写任何全局槽**：不写 `_reentrancyStatus`、`usedOpHashes`、`spenderRateLimit`，也不写任何 `total*` 计数器 |
| ③ 禁用 opcode | `lockForGas` 路径上不能出现 TIMESTAMP 和 NUMBER。续期走 R1 就不需要 deadline；限频继续用 `validAfter` 表达 |
| ④ sender 已部署，或者带 initCode 的 factory 已质押 | STO-021 的附加条件：账户还没部署时，访问它在外部合约里的关联槽，要求 factory 已质押。**这不是新约束**：现有 validate 已经读 `token.getDebt(user)` 和 `Registry.globalReputation[user]`。但新方案会在这类槽上**写入**，所以"SP 赞助创建账户的第一笔"必须专门测，也要核实 AirAccount factory 的质押状态 |
| ⑤ 同一 bundle 内不跨 sender 访问 | 因为②保证了只访问本 sender 的槽，多个 sender 的 op 在同一 bundle 里互不影响 |

**`usedOpHashes` 要不要调整**：不用。它继续只在 postOp 写（`settleLocked` 写它，legacy 的
`burnFromWithOpHash` 也写它，`:502`）。需要新增的是 `_locks[opHash][user]`：它**是**关联
槽，可以在验证期写。两者不冲突：前者负责防重放，后者负责记录锁了多少钱。

**transient storage**：如果按 02 §2.4 用 TSTORE 标记"本交易内的活锁"，规范对 transient
storage 适用同样的关联规则，槽也要以用户为最内层键。**要以 bundler 实测为准**，因为不同
bundler 对 TSTORE 的追踪实现不一定一致。

## 6. 专题 b · 覆盖 `_update` 与自动抵债、CC-28 冲突吗

**不冲突，但有两处实现顺序必须写死。**

- **mint 自动抵债**（`_update:612`，mint 之后立即 `_burn(to, repayXPNTs)`，`:633`）：规则是
  `balanceOf(from) − value ≥ lockedOf[from]`。mint 之前余额 ≥ 锁定额；mint 使余额增加
  `value`，抵债烧掉的量 ≤ `value`（原代码已证明），所以烧完后余额仍 ≥ 锁定额。**不冲突**。
  而且 I3 保证未获批用户没有债务，这条路径对他们根本不会触发。
- **CC-28 超发**：`isOverIssued` 只看 `totalSupply`、`issuanceCap` 和价值模型（`:864`）。锁定
  不改变供应量；结算烧币会减少供应量，方向与现在的 burn 一样。**不冲突**。
- **顺序一**：`settleLocked` 必须**先** `lockedOf[user] -= xLocked`，**再** `_burn(user, xCharge)`，
  否则 `_update` 会拒绝烧掉锁定中的余额。
- **顺序二**：`repayDebt`（`:578`）、`burn(from)`、`transferFrom`、`transferAndCall`、permit
  之后的转账，都经过 `_update`，都会被锁定规则约束。这正是我们要的效果，但要在测试里逐条覆盖，
  尤其是 `transferAndCall`（ERC-1363 回调里还能再转一次）。
- **急停**：建议 `lockForGas` 在 `emergencyDisabled` 时失败；`settleLocked` 对**已存在**的锁
  **照常结算**，因为它只能烧不超过预留额的钱，而这个预留是急停之前经过验证的。否则急停
  那一刻正在执行的 op 的锁都会悬挂。

## 7. 专题 c · 在 validate 里校验 1271

**能做，但不建议，而且没有必要。**

- 从 paymaster 帧调用 `sender.isValidSignature`：账户读自己的存储是允许的（STO-010）。但账户
  的 1271 实现可能读模块或 guardian 登记合约里的非关联槽（需要 paymaster 已质押），而且
  **不能有任何写入**；如果用了 P256 或 BLS 预编译，还要看目标链是否在允许列表里。能不能过，
  完全取决于**每一种账户实现**，SP 控制不了。验证 gas 也会明显上升。
- EIP-712 的 `deadline` 在验证期**读不了**（TIMESTAMP 被禁）。只能把它折进 `validUntil`，
  那样又要额外的编码。
- **替代方案 R1**（见 X2）：续期作为 `paymasterAndData` 里的一个标志位，由账户对 userOpHash
  的签名授权。validate 里零 1271 调用。
  **R1 的前提要写进信任矩阵**：谁能发出这个账户的 UserOp，谁就能续期。如果账户允许权限受限
  的 session key 或 agent key 签 UserOp，这些 key 也能续期（但不能调高上限）。
- 调高上限、给新 spender 开额度：走 R2（独立交易 + 1271），不在验证期。

## 8. 专题 d–g

### d · 体积

余量**仍是 1,007 B**（fresh `--force` 构建，`[profile.default]`，`3b0d4821`）。F1 **实测
−2,150 B**，拆完余量 3,157 B。按 02 §4 的估算，v2 分支需要约 950–1,250 B：**不拆装不下，
拆了之后还剩约 1.9–2.2 KB**。估算要在实现后重新测量。

### e · 克隆迁移与 T-A 的顺序

见 02 §5。要点：

1. **新模板和新工厂是同一次部署**。工厂的构造函数自己 `new xPNTsToken()`，并记在
   immutable `implementation` 里。部署时直接 `setSuperPaymasterAddress(SP)`，避免重演 CC-119
   T5 那种新工厂 `SUPERPAYMASTER = 0` 的漏项。
2. **SP 先升级，再切工厂**：SP 5.5.0 升级后，存量 operator 读到 `gen = 0`，走 legacy 路径，
   行为不变；然后 `setXPNTsFactory(AOA 工厂)`；最后 AOA 评估社区在新工厂发币并配置。
3. **存量社区不强制迁移**。愿意迁移的社区可以用"旧币烧、新币铸"的 1:1 兑换合约，用户自愿
   参与。存量债务（`debts[user]`，存在旧代币里）不跟着迁移，legacy 代币继续负责回收。
   **RepCredit 社区不迁移。**
4. **aPNTs 的角色要先拆开**：`0xBb46…`（新 aPNTs）是协议存款币，同时 AAStar 社区也把 aPNTs
   当作自己的 gas 代币（Jason 那个 operator 的 xPNTs 就是旧 aPNTs）。建议 **aPNTs 只做存款币，
   不套用 X1 额度**（operator 用显式 approve 存款）；AAStar 社区的 gas 代币在 AOA 工厂里另发
   一枚 v2 代币。这样 **9/11 的 aPNTs 切换（CC-119 T0）与 AOA 解耦**，只受 B6 冻结约束；真正
   要等 AOA 工厂定稿的只有工厂绑定（T5）。

### f · 升级前给 RepCredit 批量写授权，对冻结证据有没有风险

**这条执行不了（X7 在旧克隆上没有槽），也不需要执行。** 用 legacy 路径代替之后，风险变成
下面四条，需要 DSR 判断：

| 风险 | 程度 | 控制手段 |
|---|---|---|
| SP impl 被替换：RepCredit 证据跑在 5.4.2 上，升级之后链上跑的是 5.5.0 | 已有的交易回执不受影响。**如果**冻结证据要求"在活链上可复现"，那么复现时跑的是 5.5.0 的 legacy 路径 | ① 冻结清单记录 5.4.2 的 impl 地址、codehash 和有效区块区间；② **差分测试**：在 fork 上对 legacy operator 用相同输入分别跑 5.4.2 和 5.5.0，状态转移必须逐项相同 |
| F1 删掉了 SP 的 `dryRunValidation` | SDK 的 `scripts/repcredit-e2e.ts:1131/:1235` 在升级之后会失败 | 这个脚本要么固定在升级前的区块，要么改调 lens。**这是 F1 的代价，要 DSR 先同意** |
| legacy 路径被误改 | 一旦改了，RepCredit 社区的行为就会静默变化 | legacy 分支的代码不动；差分测试放进 CI |
| 同一个 SP 同时跑两种语义 | 论文可审计性的问题 | AOA 信任矩阵写明：legacy 代币的 operator 仍走信用路径，AOA 只评估 v2 社区 |

**另一个选项**（Q8 当时的备选）：给 AOA **单独部署一个 SP 代理**。这样 RepCredit 的链上栈
完全不动，也不需要 legacy 分支（能省下一部分体积）；代价是 AOA 测的是另一个部署实例。
**我倾向于维持作者选的原地升级 + legacy 分支**。但如果 DSR 认为"活链可复现"是冻结证据的
硬要求，就应该重新考虑单独部署。

### g · 遗漏或判断错的地方

1. **X1 键顺序**（§1）。
2. **锁定悬挂**：DSR 写了"postOp 不能回滚"，但只要 postOp 耗尽 gas 就会回滚。SP 虽然有
   `MIN_POST_OP_GAS = 200,000` 兜底，但"不太可能"不等于"不会发生"。释放路径的设计见 02 §2.4。
3. **$1 下限与 L1 单笔预留额**：锁定额 = `maxCost × (1 + fee + 10%)`。L1 上一笔 300k gas、
   5 gwei 的 op，按 ETH=$3000 算约 $4.5，约 225 aPNTs，已经超过 50 aPNTs 的下限。所以
   **下限必须 ≥ 目标链上单笔的最大预留额**，否则额度卡在下限的用户一笔也发不出去。OP 主网
   上这个问题基本不存在，但 Sepolia 测试时一定会遇到。
4. **显式 approve 与自动额度的关系**（§1 X1 ③），以及 aPNTs 存款路径（§8 e 第 4 条）。
5. **codehash 白名单约束不到 UUPS 代理**（§1 X5）。
6. **MIN_STAKE_VALUE 未核实**（§5 ①）。
7. **S7、S8 不改**：同意，理由和附加条件见 §2。
8. **"新工厂登记旧代币"不可行**（§3 T-A ③）。
9. **dryRun 被 RepCredit 的证据工具使用**：F1 会影响 RepCredit（§8 f）。
10. **注意 postOp 里的汇率**：结算要按锁定时的比例换算，不能按 postOp 时刻的实时汇率（§1 X3 ④）。
