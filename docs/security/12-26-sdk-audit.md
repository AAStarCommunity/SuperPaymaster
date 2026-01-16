# SDK 安全与能力覆盖评估报告 (2025-12-26)

**评估对象:** AAStar SDK (`@aastar/sdk` 及相关包) vs 链上合约 (`SuperPaymaster`, `Registry`, `PaymasterV4`)
**评估状态:** ⚠️ 发现关键架构不匹配 (Critical Mismatch)

---

## 1. 概述 (Overview)

经过对 SDK 源码与最新部署合约的深度对比分析，我们确认 SDK 在核心的 V3 (AOA) 功能上覆盖良好，但在最新的 V4 (AOA+) Paymaster 架构上存在**严重的方向性偏差**。此外，部分高级功能（如 BLS 签名生成、动态定价工厂配置）在 SDK 中缺失，限制了开发者的集成能力。

---

## 2. 差距分析 (Gap Analysis: Contracts vs SDK)

### 2.1 Paymaster V4 (AOA+) - 🔴 严重不匹配 (Critical)
*   **合约现状 (`PaymasterV4.sol`):**
    *   采用 **Token Paymaster** 模式。
    *   核心逻辑依赖 `addGasToken`、`addSBT`、`setMaxGasCostCap`。
    *   验证逻辑 (`validatePaymasterUserOp`) 检查用户是否持有指定 SBT 或代币，并直接扣费。
*   **SDK 现状 (`packages/paymaster/src/AOA-Plus`):**
    *   实现了一个 **Verifying Paymaster** 客户端 (`StandalonePaymasterClient`)。
    *   核心方法是 `setVerifyingSigner` 和 `deployStandalone`。
    *   依赖硬编码的 `PM_V4_ABI`，该 ABI 包含了合约中不存在的方法（如 `setVerifyingSigner`）。
*   **影响:**
    *   SDK 无法用于配置现有的 V4 合约（无法添加支持的代币/SBT）。
    *   SDK 缺少 V4 专用的 Middleware (`getV4PaymasterMiddleware`)，导致开发者无法生成符合 V4 格式要求的 `paymasterAndData` (需包含 `[paymaster][gasLimits][token]`)。

### 2.2 SuperPaymaster V3 (AOA) - 🟠 功能缺失
*   **合约现状:** 引入了 `xpntsFactory` 以支持动态预言机定价 (`setXPNTsFactory`)。
*   **SDK 现状:** `SuperPaymasterClient` 仅支持 `setAPNTSPrice` (静态价格)，缺少 `setXPNTsFactory` 方法。
*   **风险:** `paymaster.ts` 中的 `depositETH` 方法调用了 `deposit()` (带 value)。需确保合约继承链中的 `BasePaymaster` 实现了 `receive()` 或无参 `deposit()`，否则会与 `deposit(uint256)` (代币充值) 混淆导致调用失败。

### 2.3 注册表与身份 (Registry & Identity) - 🟡 工具缺失
*   **现状:** `Registry.sol` 的 `batchUpdateGlobalReputation` 需要提交 BLS 签名证明 (`proof`)。
*   **缺失:** SDK (`registry.ts`, `dvt.ts`) 提供了上链调用的接口，但**未提供生成 BLS 证明的链下工具**。
*   **影响:** 开发者无法使用纯 SDK 充当“信誉源”或 DVT 验证者，必须自行寻找第三方库来完成椭圆曲线签名和聚合。

### 2.4 质押模块 (Staking) - 🟡 API 设计误导
*   **问题:** `staking.ts` 导出了 `lockStake` 方法。
*   **事实:** 合约中 `lockStake` 被修饰符 `onlyRegistry` 保护，普通用户或 Operator 直接调用必败。
*   **建议:** 该方法应标记为 `internal` 或仅供 SDK 内部的 `registerRole` 流程调用，避免误导开发者。

---

## 3. 代码质量与结构 (Code Quality & Structure)

1.  **ABI 管理混乱:**
    *   核心包 (`@aastar/core`) 统一管理了大部分 ABI，结构良好。
    *   **例外:** `AOA-Plus` 包内部硬编码了 `PM_V4_ABI`，未引用核心包。这是导致 V4 接口与合约脱节的直接原因。
2.  **客户端组合模式 (Client Composition):**
    *   SDK 使用 `createOperatorClient` 等工厂方法将不同的 `actions` (staking, paymaster, registry) 组合到 viem client 中。这种设计模式非常优秀，易于扩展和维护。
3.  **依赖缺失:**
    *   `FinanceClient` 引用了 `wrapGTokenToXPNTs`，依赖一个 `wrap` 接口。当前合约仓库中未找到对应的 Converter 合约，属于隐式依赖。

---

## 4. 改进建议 (Recommendations)

### 🛑 立即修复 (Immediate Fixes)
1.  **重构 V4 客户端:**
    *   废弃当前的 `AOA-Plus` 实现。
    *   基于 `PaymasterV4Base.sol` 重新生成 ABI。
    *   实现 `addGasToken`, `addSBT`, `withdrawPNT` 等管理方法。
2.  **实现 V4 Middleware:**
    *   在 SDK 中增加 `getV4PaymasterMiddleware`，支持 V4 特有的 `paymasterAndData` 打包逻辑 (自动填充 GasLimit 和 Token 地址)。

### 🚀 功能增强 (Enhancements)
3.  **集成 BLS 库:**
    *   引入 `noble-bls12-381` 等库，在 SDK 中提供 `BLSSigner` 类，支持 `signMessage` 和 `aggregateSignatures`，打通 DVT 流程的最后一步。
4.  **完善 V3 配置:**
    *   在 `SuperPaymasterClient` 中增加 `setXPNTsFactory` 方法。

### 🛡️ 安全加固 (Security)
5.  **隐藏受限方法:** 从 `StakingActions` 的公开类型定义中移除 `lockStake`，或在文档中明确标注其仅供 Registry 内部调用。
6.  **同步 ABI:** 强制所有子包 (`paymaster`, `tokens`) 从 `@aastar/core` 导入 ABI，禁止局部硬编码。
