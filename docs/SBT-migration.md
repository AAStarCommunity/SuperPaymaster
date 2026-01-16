# SuperPaymaster V3 & Paymaster V4 架构升级与 SBT 迁移技术总结

**日期**: 2026-01-07
**主题**: 身份验证体系重构、信用风控闭环及系统安全性加固

---

## 1. 核心架构演进：从“凭证驱动”到“身份驱动”

### 1.1 权威源的转移 (Source of Truth)
*   **过去**: 系统依赖 `MySBT` 合约的回调（`registerSBTHolder`）来通知 Paymaster 用户的准入资格。这是一种“凭证驱动”模型，即“因为你持有了 NFT，所以你拥有权限”。
*   **现在**: 决策权上移至 `Registry`（注册表）。`Registry` 作为系统的“大脑”，直接决定角色的建立与消失。
*   **逻辑**: 现在由 `Registry` 直接向 `SuperPaymaster` 推送（Push）用户的准入状态。

### 1.2 职责解耦 (Decoupling)
*   **Registry**: 负责业务决策、身份授权和多角色管理。
*   **MySBT**: 回归本质，仅作为身份的展示媒介（勋章/凭证）和元数据存储，不再参与支付链路的实时控制。
*   **SuperPaymaster**: 作为执行机构，维护本地化的“准入白名单”和“信用黑名单”，实现极速验证。

---

## 2. 关键安全与风控修复 (Security & Risk Control)

### 2.1 信用风控模型 (Credit Risk Model)
*   **机制**: 采用 **“异步监控 + 状态推送”** 模型。
*   **实现**: SuperPaymaster 不在验证阶段进行实时数值计算（以节省 Gas 并确保 4337 兼容性），而是由外部 DVT 节点网络监控用户信用。
*   **拦截**: 一旦用户信用耗尽，DVT 达成共识并通过 Registry 调用 `updateBlockedStatus` 将用户加入 SP 的本地黑名单映射。验证阶段仅需一次极速的 `SLOAD` 即可实现风控拦截。

### 2.2 预言机时效性防护 (Oracle Freshness)
*   **风险**: 防止预言机停更或 L2 排序器故障导致的陈旧价格套利。
*   **方案**: 引入可配置的 `priceStalenessThreshold`（默认 1 小时）。
*   **行为**: 验证阶段若发现价格数据超过阈值未更新，将直接拒绝交易（Fail-Closed）。

### 2.3 初始化安全防护 (Initialization Defense)
*   **工厂层 (Option 1)**: `PaymasterFactory` 在部署 Proxy 后立即通过 `staticcall` 检查 `owner()`。若初始化未按预期将权限移交给 Operator，则强制回滚。
*   **合约层**: `Paymaster` 构造函数中增加了 `_disableInitializers()`，彻底锁死逻辑合约（Implementation）被非法占用的可能性。

---

## 3. 业务逻辑闭环 (Business Logic Closure)

### 3.1 单账户多角色的幂等性
*   用户可以同时拥有 `ENDUSER`、`ANODE`、`COMMUNITY` 等多个角色。
*   **建立**: 注册第一个角色时铸造 SBT 并激活 SP 权限；注册后续角色时，仅在原有 SBT 上增加记录，权限保持激活。
*   **注销**: 只有当用户退出 **最后一个** 角色时，`Registry` 才会下令 `SuperPaymaster` 注销其权限，并命令 `MySBT` 销毁（Burn）该身份代币。

### 3.2 ERC-4337 高性能验证
*   **挑战**: 4337 协议严禁在 `validatePaymasterUserOp` 阶段进行复杂的外部合约调用。
*   **解决**: `SuperPaymaster` 内部维护了两个本地 `mapping`：
    1.  `sbtHolders`: 本地准入白名单（由 Registry 推送）。
    2.  `blockedUsers`: 本地信用黑名单（由 DVT 网络共识后推送）。
*   **效果**: 验证阶段仅需两次本地 `SLOAD`，无需访问外部合约，100% 兼容 Bundler 规则。

---

## 4. 移除的冗余代码说明
*   **MySBT 回调**: 移除了 `ISuperPaymasterCallback` 接口调用。理由是 `SuperPaymaster` 已不再提供这些接口，且由 `Registry` 统一管理更符合 V3 架构。
*   **V4 SBT 活动记录**: 移除了 `ActivityRecording` 逻辑。理由是简化 V4 架构，降低 Gas 消耗，将活跃度监控下沉到 Subgraph 或专门的监控合约中。

---

**结论**: 经过本次迁移与重构，SuperPaymaster 体系在逻辑上实现了从“准入”到“风控”再到“注销”的完整闭环，具备了主网部署的安全性与健壮性。
