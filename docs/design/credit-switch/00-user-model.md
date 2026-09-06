# SuperPaymaster 用户模型：核心行为与角色

> **来源纪律**：本文每一条都取自关键路径**源码**，不取自文档。行号对应
> `main @ d2fe85a7`。任何一条读起来像结论的句子，后面都跟着它的出处。

## 1. 核心行为，一句话

终端用户发一笔 UserOp，**ETH gas 由 SuperPaymaster 垫付**，用户事后被扣**社区积分
xPNTs**；社区（operator）预存 **aPNTs** 作为垫付额度，协议按 bps 抽成。

## 2. 三段热路径

### 2.1 准入 — `validatePaymasterUserOp`（`contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:1138`）

`paymasterAndData` 的布局（源码注释 `:1198`）：

```
[paymaster(20)] [gasLimits(32)] [operator(20)] [maxRate(32)]
```

逐条门禁，按代码顺序：

**所有**失败行为都是同一件事——返回 `("", _packValidationData(true, 0, 0))`，即
ERC-4337 的 sigFailure，**不 revert**（`:1151`/`:1161`/`:1166`/`:1175`/`:1184`/`:1206`/
`:1218`/`:1224` 逐行核过，是同一个表达式）。初稿在后三行改用了「拒绝」，紧跟在
revert/sigFailure 的对比之后，会被读成换了机制。

| 检查 | 位置 | 失败行为 |
|---|---|---|
| operator 已配置 | `:1150` | sigFailure（不 revert） |
| 未暂停 | `:1160` | 同上 |
| **身份**：`isEligibleForSponsorship(sender)` | `:1165` | 同上 |
| `paymasterPostOpGasLimit >= MIN_POST_OP_GAS` | `:1174` | 同上 |
| 未被该 operator 拉黑 | `:1183` | 同上 |
| 限频（`minTxInterval`） | `:1193` | 不拒绝，改用 `validAfter` 表达 |
| **汇率承诺**：`exchangeRate() > maxRate` | `:1205` | 同上 |
| **信用上限**：`_creditExceeded(...)` | `:1217` | 同上 |
| operator 余额足够 | `:1223` | 同上 |

通过后**乐观扣款**（`:1228`）：

```solidity
config.aPNTsBalance -= uint128(aPNTsAmount);
config.totalSpent   += aPNTsAmount;
protocolRevenue     += aPNTsAmount;
```

两个值得单独说的设计：

- **身份是双通道**（`:1600`）：`return sbtHolders[user] || isRegisteredAgent(user);`
  —— 持 SBT 的人，**或** ERC-8004 注册的 Agent。后者用专用的
  `isRegisteredAgent()` 而不是通用 `balanceOf()`，注释（`:1608`）说明理由是「只让
  ERC-8004 合规的 registry 算数，而不是任意 ERC-721」。
- **汇率承诺防的是 rug pull**：用户签名时把能接受的最高汇率写进 calldata，社区在
  签名之后偷偷调价就会让这笔 UserOp 失效，而不是让用户按新价被扣。

### 2.2 计价 — `_calculateAPNTsAmount`（`:1126`）

```solidity
Math.mulDiv(ethAmountWei * uint256(ethUsdPrice), 1e18,
            (10**decimals) * aPNTsPriceUSD, Math.Rounding.Ceil)
```

用的是**缓存价**（`cachedPrice`），不是实时 Chainlink 调用——ERC-7562 不允许在
validation 里读任意外部状态。缓存的陈旧度通过 `validUntil` 表达（`:1156`）。

验证阶段按 `1 + protocolFeeBPS + VALIDATION_BUFFER_BPS` 多扣一点（`:1211`），
注释（V3.5 FIX）说明是「防 PostOp 资不抵债」。

### 2.3 结算 — `postOp`（`:1346`）

顺序本身是安全属性，不是风格：

1. **无条件**更新限频时间戳（`:1362`）——注释写明即使 op revert 也计入，防 griefing
2. **幂等锁先于一切记账**（`:1381`）：`if (_settledDebtOps[userOpHash]) return;`
   注释说明它必须覆盖整个记账块（退款 + `protocolRevenue` 扣回），而不只是记账那一步
3. `finalCharge = actualAPNTsCost × (1 + protocolFeeBPS)`（`:1393`）
4. **用户真正付钱**在 `_recordDebt`（`:1444`）
5. 多扣的退还 operator，`protocolRevenue` 同步扣回（`:1409`）

## 3. 用户到底怎么付钱 — `_recordDebt`（`:1444`）

```solidity
try IxPNTsToken(token).burnFromWithOpHash(user, amount, opHash) {} catch {
    if (getDebt + pendingDebts + amount <= REGISTRY.getCreditLimit(user)) {
        try IxPNTsToken(token).recordDebtWithOpHash(...) { return; } catch {}
    } else {
        userOpState[operator][user].isBlocked = true;   // 封住重复
    }
    pendingDebts[token][user] += amount;
    emit DebtRecordFailed(token, user, amount);
}
```

- **首选**：从用户 xPNTs 余额烧掉（带 opHash 重放保护）
- **烧不动**（新用户没余额）：退到记欠账，但**必须在信用上限内**
- **超上限**：这一笔 gas 已经花了、追不回，于是把用户对该 operator 置 `isBlocked`，
  避免同一手法被重复利用。

> ⚠️ 初稿这里写的是「**只能**把用户置 `isBlocked`」，读起来像「超上限就不再记账了」。
> **不对**，而且上面八行的代码块自己就写着：`pendingDebts[token][user] += amount` 在
> `if/else` **之外**，两条分支都会走到；`retryPendingDebt`（`:1493`，`onlyOwner`）还能
> 把它转成真正的 token 债务。这是 README 阅读顺序里的**第一份**文档，所以这句话是最先
> 被读到的一句——它曾经和 [02 §2](02-credit-switch-design.md) 推翻的结论是同一个形状。

aPNTs → xPNTs 的换算在 `xPNTsToken.burnFromWithOpHash:512`：
`xPNTs = ceil(amountAPNTs × exchangeRate / 1e18)`。**charge 是 aPNTs 计价，余额是
xPNTs 计价**——任何要比较两者的新代码都必须先过这一步换算。

## 4. 角色：7 个，来自 `contracts/src/interfaces/v3/IRegistry.sol:7-13`

```solidity
ROLE_COMMUNITY / ROLE_ENDUSER / ROLE_PAYMASTER_AOA
ROLE_PAYMASTER_SUPER / ROLE_DVT / ROLE_ANODE / ROLE_KMS
```

| 角色 | 代码里它到底做什么 |
|---|---|
| `ENDUSER` | 被赞助的两条身份通道之一。**唯一允许重复 `registerRole` 的角色**（`Registry.sol:326`） |
| `COMMUNITY` | 社区主体。`configureOperator` 硬性要求它（`SuperPaymaster.sol:281`），且绑定的 xPNTs 必须等于 `xPNTsFactory.getTokenAddress(msg.sender)`（`:292`）——不能拿任意 ERC20 冒充 |
| `PAYMASTER_SUPER` | AOA+ 共享模式 operator。`deposit()` 要过 `_requireSuperOperatorRole()`（`:715`） |
| `PAYMASTER_AOA` | 独立模式，每社区一个 EIP-1167 克隆 |
| `DVT` | 监督/罚没节点。退出要过 `IGuardianExitGate(blsAggregator).consumeGuardianExit`（`Registry.sol:352`） |
| `ANODE` | 节点角色 |
| `KMS` | 密钥托管角色 |

### 共同机制（`Registry.registerRole:317`）

- **只能本人调**：`if (msg.sender != user) revert Unauthorized();`（`:319`）
- 质押 GToken（`_enforceMinStake`，`:331`）+ 付 `ticketPrice`
- mint 一枚 SBT（`:343`）

### 退出（`exitRole:348`）的一个非显然设计

释放质押以 `GTOKEN_STAKING.getLockedStake` 为准，**不信本地 `roleStakes` 缓存**
（`:360`，标注 M-6）。注释给的理由：缓存是 best-effort 同步的（`GTokenStaking._syncRegistry`
里的 try/catch），若某次同步失败，按缓存判断会「要么困住一笔真实的锁，要么让退出
因 NoLockFound 而砖化」。

## 5. 资金从哪来 — `deposit`（`:714`）/ `_creditDeposit`（`:723`）

```solidity
IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
operators[operator].aPNTsBalance += uint128(amount);
totalTrackedBalance += amount;
```

另有 `depositFor`（`:759`）和 ERC1363 `onTransferReceived` 推送模式，三者共用
`_creditDeposit` 记账。
