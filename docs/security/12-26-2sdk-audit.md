# SDK 安全与能力覆盖评估报告 (2025-12-26 第二轮)

**评估对象:** AAStar SDK (修复后版本) vs 链上合约
**评估状态:** ✅ V4 核心流程修复，🟠 管理功能仍有缺失

---

## 1. 概述 (Overview)

经过对修复后 SDK 代码 (`packages/paymaster/src/V4` 等) 的深度审计，确认 **Paymaster V4 的核心不匹配问题已解决**。SDK 现在的架构能够正确支持 V4 合约的“直接代币支付”模式。SDK 在用户侧（UserOp 发送）的闭环已经打通，但在协议管理侧（Admin）和密码学工具链上仍有改进空间。

---

## 2. 修复验证 (Verification of Fixes)

### ✅ Paymaster V4 (AOA+) - 核心交互修复
*   **状态:** **已修复**
*   **分析:** 
    *   移除了之前错误的 `StandalonePaymasterClient` (该客户端曾尝试调用合约中不存在的 `setVerifyingSigner`)。
    *   新增了 `getPaymasterV4Middleware`。
    *   **数据结构:** 正确实现了 `[Paymaster(20)] + [GasLimits(32)] + [Token(20)]` 的打包格式 (共 72 字节)，与 `PaymasterV4.sol` 的 `paymasterAndData` 解析逻辑 (从 offset 52 读取 Token) 完美匹配。
*   **结论:** 开发者现在可以调用该 Middleware 顺利发送 V4 支付请求。

### ✅ 目录与命名优化
*   **状态:** **已优化**
*   **分析:** 包结构重构为 `V4` 和 `SuperPaymaster`，命名清晰，消除了 `AOA-Plus` 的歧义，更符合工程规范。

---

## 3. 遗留差距与隐患 (Remaining Gaps & Risks)

### 3.1 Paymaster V4 管理端缺失 (🔴 High)
*   **问题:** SDK 尚未提供 `PaymasterV4Client` (Admin 版)。
*   **影响:** 开发者无法通过 SDK 调用以下核心配置方法：
    *   `addGasToken(address token)` / `removeGasToken`
    *   `addSBT(address sbt)` / `removeSBT`
    *   `withdrawPNT(address to, address token, uint256 amount)`
*   **后果:** Paymaster 的初始化和代币维护仍需依赖原始脚本，未集成进 SDK 能力库。

### 3.2 SuperPaymaster V3 动态定价配置缺失 (🟠 Medium)
*   **问题:** `SuperPaymasterClient` 仍未补全 `setXPNTsFactory` 方法。
*   **影响:** 合约已支持从 Factory 获取动态价格，但 SDK 无法开启此功能，迫使系统停留在 owner 手动设置价格的“半中心化”模式。

### 3.3 BLS 链下签名工具缺失 (🟠 Medium)
*   **问题:** `dvt.ts` 虽然提供了 `executeSlashWithProof` 的上链接口，但 SDK 依然缺少生成 BLS 签名和构造 `proof` 的链下工具类。
*   **影响:** 开发者在实现 DVT 验证节点时，必须引入额外的第三方密码学库来处理 BLS12-381 曲线，SDK 无法独立提供端到端的 DVT 支持。

### 3.4 API 安全误导 (🟡 Low)
*   **问题:** `StakingActions` 仍公开暴露 `lockStake`。
*   **事实:** 该方法受 `onlyRegistry` 保护，SDK 用户直接调用必败。
*   **建议:** 内部化此方法，引导用户通过 `Registry.registerRole` 间接调用。

---

## 4. 技术方案合理性评审 (Architecture Review)

1.  **Middleware 模式:** 采用 viem 的 middleware 模式生成 `paymasterAndData` 是当前 AA 生态的最佳实践，具有极强的兼容性。
2.  **解耦设计:** 核心包 (`core`) 提供 Action，SDK 包组合 Action 为 Client 的方案非常灵活，符合组合优于继承的设计原则。
3.  **FinanceClient:** 提供的 `depositETH` 现已确认是安全的，因为其调用的 `deposit()` 对应 `BasePaymaster` 提供的 ETH 充值入口。

---

## 5. 最终建议 (Final Recommendations)

1.  **补全 V4 Admin Client:** 在 `packages/paymaster/src/V4` 中增加 `admin.ts`，封装 Token 和 SBT 的维护接口。
2.  **集成 BLS 库:** 建议引入 `noble-bls12-381` 库，在 SDK 中提供一个简单的 `BLSSigner` 助手类，解决“有上链接口，无签名能力”的尴尬。
3.  **V3 价格联动:** 尽快在 SDK 中添加 `setXPNTsFactory` 接口，完成动态定价系统的最后一块拼图。

**总结:** 您对 V4 核心流程的重构非常成功，SDK 已具备基本生产能力。完成上述 Admin 能力的封装后，即可作为一个完整的协议 SDK 发布。
