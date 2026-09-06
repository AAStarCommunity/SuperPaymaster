# 信用/债务支付开关 — 设计分支

本目录记录一次完整的评估：从「用户到底在做什么」出发，核对「链上跑的是不是我们
的代码」，最后落到「社区能不能自己关掉信用支付」。

三份文档**都以关键路径源码为准，不以既有文档为准**；每条结论后面跟着它的出处
（`file:line`）或它的测量方式。

| 文档 | 内容 | 一句话结论 |
|---|---|---|
| [00-user-model.md](00-user-model.md) | 核心用户行为 + 7 个角色 | 用户发 UserOp，SP 垫 ETH，用户事后被扣 xPNTs；社区预存 aPNTs |
| [01-onchain-vs-local.md](01-onchain-vs-local.md) | Sepolia 链上 vs 本地逐字节比对 | 5 个合约一致（差异全在 immutable 内），3 个「同版本号代码不同」，1 个工厂指向旧部署 |
| [02-credit-switch-design.md](02-credit-switch-design.md) | 开关提案 | 现在不是「默认开」而是「强制开且关不掉」；开关可做，改动面 4 处 |

## 结论摘要

**能做到，方向可行**，但比初稿估计的要多做一步。

初稿曾断言「`_recordDebt` 的超上限分支已经实现了不记可回收欠账，所以关闭信用 ≈
永远走 else 分支」。**这条被推翻了**：`pendingDebts += amount` 写在 if/else **之外**
（两条分支都会走到），而 `retryPendingDebt`（`:1493`，`onlyOwner`）能把
`pendingDebts` 转成真正的 token 债务。所以 else 分支既累积欠账、那笔欠账也确实可
回收——初稿的说法字面上就不成立。它被留在
[02 §2](02-credit-switch-design.md#2-一条被推翻的关键发现else-分支不是纯余额模式)
当反例，因为它是最容易被直接照着实现的那一条。

正确做法是给关闭信用**一条新的第三路径**：既不 `recordDebtWithOpHash`，**也不写
`pendingDebts`**，发一个区别于 `DebtRecordFailed` 的事件。

三层默认值分离，正好满足「合约默认打开、部署时可覆盖」：

```
合约存储层   信用【开】   (creditDisabled = false)   ← 升级安全的唯一方向
部署脚本层   由 COMMUNITY_CREDIT_ENABLED 决定，可设成【关】
运行时       社区自己 setCreditEnabled(bool) 随时改
```

`creditDisabled` 这个**否定式命名不是风格问题**：SP 是 UUPS 就地升级，新 bool 对
存量 operator 默认读出 `false`。叫 `creditEnabled` 会让升级瞬间所有社区静默变成
无信用、用户集体交易失败。

## 两条必须先说清楚的话

1. **开关不等于零风险，而且它换掉的是可追偿性。** 用户能在自己的 UserOp 内部抽干
   xPNTs，让验证时够、postOp 时不够。那一笔 gas 已经花掉、追不回。纯余额模式下这笔
   损失由社区承担，**且链上不再留下可追偿记录**。所以「关掉信用」不是「更安全」，
   是**用可追偿性换确定性**。
2. **有一条注释在说谎。** `SuperPaymaster.sol:1446` 声称 `_creditExceeded` 有余额
   短路，代码里没有（`c6493ade` 拿掉了，注释没跟）。它描述的恰好就是本提案想做的
   模式，会误导任何来评估这个问题的人——建议先于本提案单独修掉。

## 状态

**提案，未实现，不插队。** 纯产品变更，非论文相关；按现行约定在 RepCredit 冻结期
内不动。开工前需要 DSR 就 [02 §6 未决问题 2](02-credit-switch-design.md#6-未决问题)
（关闭信用的社区其用户声誉是否仍增长）给出判断。
