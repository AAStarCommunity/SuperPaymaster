# 设计提案：社区自持的「信用/债务支付」开关

**状态**：提案，未实现。**优先级：不插队**——这是纯产品变更，不是论文相关，
按现行约定在 RepCredit 冻结期（不合论文线、不部署 4.12、等 DSR 发布
"B6 evidence frozen"）内不动。

## 1. 问题：现在不是「默认开」，是「强制开且关不掉」

`SuperPaymaster.sol:832`：

```solidity
function _creditExceeded(address token, address user, uint256 charge) internal view returns (bool) {
    uint256 used = IxPNTsToken(token).getDebt(user) + pendingDebts[token][user];
    return used + charge > REGISTRY.getCreditLimit(user);
}
```

**这是纯信用判据，完全不看余额。** 两头都不对：

| 用户状态 | 现在的结果 | 直觉期望 |
|---|---|---|
| 余额 10000 xPNTs，已欠 300 | **拒绝**（付得起也发不出去） | 通过 |
| 余额 0，无欠账 | **放行** → postOp 烧不动 → 记欠账 | 拒绝 |

所以「把额度调成 0」**不等于**「有余额就付、没余额就拒」，而是
**所有人一笔都发不出去**（`charge > 0` 恒成立）。

而且额度在 Registry（`Registry.sol:890`）：

```solidity
return creditTierConfig[_levelForReputation(globalReputation[user])];
```

**按用户全局声誉分档，不分社区。** 链上实测：level 1–3 = 300 xPNTs，
level 4 = 600，level 5 = 1000。也就是每个人自动带 300 的信用，**社区无权拒绝**。

### 1.1 一个必须先修的假注释

`_recordDebt` 的注释（`:1446`）说 `_creditExceeded` 有「validation-time balance
短路，让零信用用户用余额付」。**代码里没有这个短路**——`b9c13af7`（balance-aware）
之后被 `c6493ade`（audit H-1 Plan A）拿掉了，注释没跟着改。

这条注释正好在描述本提案想要的模式，**任何来评估这个问题的人都会先被它误导**。
它是独立的、零风险的文档修正，可以先于本提案单独修掉。

## 2. 关键发现：else 分支已经把「纯余额模式」写好了

`_recordDebt:1459` 的超上限分支**已经**实现了「不记可回收欠账」：

```solidity
} else {
    userOpState[operator][user].isBlocked = true;
}
pendingDebts[token][user] += amount;
emit DebtRecordFailed(token, user, amount);
```

所以**「关闭信用」≈「永远走 else 分支」**。这不是要新造一套机制，是把一条已存在
的路径变成可选择的。

## 3. 提案

### 3.1 存储：`bool creditDisabled`，放 OperatorConfig slot 0 byte 18

`ISuperPaymaster.sol:13` 当前 slot 0：

```
uint128 aPNTsBalance (16B) | bool isConfigured (byte 16) | bool isPaused (byte 17)
→ 18 B 已用，还剩 14 B
```

放 byte 18 **不新增 slot、不移动任何现有字段偏移**，因此不会重演 v5.3.2→5.3.3
那次 `isConfigured` 从 byte 28 移到 byte 16、导致「全体 operator 看起来未配置」的
事故（该事故被记录在同一个 struct 的注释 `:15-21`）。

### 3.2 命名方向是安全属性，不是风格

**必须叫 `creditDisabled`，不能叫 `creditEnabled`。**

SP 是 UUPS **就地升级**，新 bool 对所有存量 operator 默认读出 `false`：

| 命名 | 升级瞬间存量社区的行为 |
|---|---|
| `creditEnabled` | 全部静默变成**无信用** → 用户集体交易失败 |
| `creditDisabled` | 全部保持**现状（有信用）** ← 唯一安全的方向 |

这恰好和「**默认打开**」的产品要求一致——不是巧合，是同一个约束的两种说法。

### 3.3 API：加一个重载，不改现有签名

```solidity
// 保留，语义 = 信用打开（现状）
function configureOperator(address xPNTsToken, address _opTreasury) external;

// 新增：社区部署时显式指定
function configureOperator(address xPNTsToken, address _opTreasury, bool creditEnabled) external;

// 新增：事后自助改（照抄 setMinTxInterval:605 的范式）
function setCreditEnabled(bool enabled) external;
```

selector 实测无碰撞：

```
configureOperator(address,address)        0x5c7c4b5f   (现有)
configureOperator(address,address,bool)   0xd0df3ed6   (新增)
configureOperator(address,address,uint256)0x847807f2   (历史上的旧三参形式，已废弃)
```

`setMinTxInterval`（`:605`）就是「社区自助、不经治理」的现成范式：
`operators[msg.sender].x = v`。开关照抄即可——**权限边界是 msg.sender 自己**，
不需要 owner，也不需要 Registry 改动。

### 3.4 部署时覆盖默认值

`configureOperator` 在 6 个现役部署脚本里被调用：

```
contracts/script/v3/DeployRepCreditSepolia.s.sol:130
contracts/script/v3/InitializeAAStar.s.sol:95
contracts/script/v3/DeployLive.s.sol:484
contracts/script/v3/DeployAnvil.s.sol:183, :217
contracts/script/v3/TestAccountPrepare.s.sol:116
```

改成读一个环境变量，**合约默认与部署默认可以不同**——这正是需求里
「我部署初始化这个社区的时候，默认配置就是不打开信用支付」：

```solidity
// 合约层默认 = true（升级安全 + 存量社区不变）
// 部署层默认由 profile 决定，可与合约层不同
bool creditEnabled = vm.envOr("COMMUNITY_CREDIT_ENABLED", true);
superPaymaster.configureOperator(token, treasury, creditEnabled);
```

于是三层语义清晰分离：

| 层 | 默认 | 谁能改 |
|---|---|---|
| 合约存储 | 信用**开**（`creditDisabled = false`） | —— |
| 部署脚本 | 由 `COMMUNITY_CREDIT_ENABLED` 决定，可设成关 | 部署者 |
| 运行时 | 承接部署时的值 | **社区自己**（`setCreditEnabled`） |

### 3.5 完整改动面（4 处，勿漏第三处）

| 位置 | 改什么 |
|---|---|
| `ISuperPaymaster.sol:13` | slot 0 加 `bool creditDisabled` |
| `SuperPaymaster.sol:832` `_creditExceeded` | 关闭信用时改判余额 |
| `:1217`（validate）**和 `:1331`（dryRun）** | 两个调用点都要跟随 |
| `:1445` `_recordDebt` | 关闭信用时跳过 `recordDebtWithOpHash`，直接走已有 else 分支 |

`:1331` 是 dryRun 路径。**漏掉它会让 gas 估算与真实执行给出不同答案**，
而这种不一致在测试里通常不会红。

### 3.6 余额判据的单位陷阱

charge 是 **aPNTs**，余额是 **xPNTs**。换算在
`xPNTsToken.burnFromWithOpHash:512`：

```solidity
uint256 xPNTsToBurn = (amountAPNTs * rate + 1e18 - 1) / 1e18;   // ceil
```

所以判据必须是：

```solidity
IERC20(token).balanceOf(user) >= (charge * rate + 1e18 - 1) / 1e18
```

**向上取整必须保留**——向下取整会让「余额刚好差 1 wei」的情况通过验证、在 postOp
烧不动。

好消息：`exchangeRate` 在 validate 里**已经读过一次**（`:1205` 的 maxRate 防
rug-pull 检查），直接复用即可，**不增加外部调用**。

ERC-7562 合规性：`balanceOf(sender)` 属 sender-associated storage，与现有
`isRegisteredAgent(account)` 是同一个论证（其注释 `:1605-1610` 已写明该论证）。

## 4. 开关解决不了的事——必须先讲清楚

用户可以**在自己的 UserOp 内部**把 xPNTs 转走：验证时余额够，postOp 时烧不动。
这一笔的 gas 已经花出去了，链上追不回。

**纯余额模式下这笔损失仍然由社区承担**，只能靠 `isBlocked` 防止同一手法被重复
利用。这正是 audit H-1（`:1446` 注释）当年记录的那个攻击面。

所以开关能保证的是「**不会累积可回收欠账**」，**不是**「**永不亏一笔**」。
这个区别必须写进社区文档，否则社区会以为关掉信用等于零风险。

## 5. 可行性

- **EIP-170**：SuperPaymaster 当前 runtime **23,569 B，余量 1,007 B**
  （2026-09-06 现量）。本改动估计 200–400 B，装得下。
  **但按项目铁律，估算不算数——实现完必须重新量一次**，且要量
  `[profile.default]`（`deploy-core` 从不设 `FOUNDRY_PROFILE`）。
- **升级方式**：UUPS，`upgradeToAndCall`，不必重新部署。
- **对下游的影响**：新增 2 个外部函数 → 公开 ABI 变更 → 按 `CLAUDE.md` 需
  bump `version()`、重生成 `abis/*.json`、通知 `repo:sdk` 与 `repo:dvt`。
- **测试**：至少要覆盖「信用开/关 × 余额足/不足 × 中途抽干」六格，且
  **dryRun 与 validate 必须给出相同答案**（见 3.5）。

## 6. 未决问题

1. **`getCreditLimit` 仍是全局的。** 本提案只让社区做二元开关，不让社区设**自己的**
   额度。若要「社区 A 给 500、社区 B 给 100」，需要动 Registry 的信用模型，
   那是更大的改动，且与 RepCredit 论文线相关——不应混进这个产品变更。
2. **关闭信用的社区，其用户的 `globalReputation` 还要不要涨？** 声誉当前由
   还债行为驱动；纯余额社区不产生债务记录。这条影响 RepCredit 的输入，
   **需要 DSR 判断**，不能由本提案单方面决定。
3. 是否需要一个事件 `CreditPolicyChanged(operator, enabled)` 供 SDK/监控消费——
   倾向需要，成本极低。
