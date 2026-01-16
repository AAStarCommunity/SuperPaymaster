# SuperPaymaster V3.2 更新报告 (Changelog)

本报告详细说明了近期修改的 **6个核心合约文件** 及其变更原因。修改主要涉及 **Credit System (信用系统重构)**、**Slashing (惩罚机制)** 和 **Role Management (角色管理)** 三个部分。

所有修改均为了符合 V3.1/V3.2 的架构设计目标（去中心化、安全性、债务账本统一）。

---

## 1. Credit System Redesign (信用系统重构)

涉及文件：`xPNTsToken.sol`, `SuperPaymasterV3.sol`, `IxPNTsToken.sol`

### 🛠️ `contracts/src/tokens/xPNTsToken.sol`
*   **修改内容**:
    1.  新增 `mapping(address => uint256) public debts;` 存储用户债务。
    2.  新增 `function recordDebt(...)` 供 Paymaster 记录欠款。
    3.  **核心**: 重写 `_update` 函数。当 Token 发生转移（包括 Mint）时，检查接收方是否有债务。如果有，自动扣除转入金额进行销毁（Burn）以偿还债务。
    4.  版本号更新为 `2.2.0-credit`。
*   **修改原因**:
    *   实施 **"Debt-First" (债务优先)** 模型。旧版将债务记在 Paymaster 本地，但这会导致用户在收到代币后无法自动还款，且 Paymaster 资金池与用户各欠各的，账目混乱。
    *   将债务逻辑下沉到 Token 合约，确保**任何**收入（转账、空投、即时充值）都会优先填平债务，这是最安全的信用风控模型。

### 🛠️ `contracts/src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol`
*   **修改内容**:
    1.  **删除** `userDebts` mapping（旧的债务记录）。
    2.  **修改** `validatePaymasterUserOp`: 不再检查本地债务，改为调用 `xPNTsToken.getDebt()` 获取真实债务，并结合 Registry 的信用额度（把 aPNTs 额度换算为 xPNTs）进行拦截检查。
    3.  **修改** `postOp`: 当用户使用信用消费时，不再更新本地变量，而是调用 `xPNTsToken.recordDebt()`。
    4.  **删除** `_autoRepayDebt` 函数（已废弃）。
*   **修改原因**:
    *   配合 Token 合约的改动，移除冗余的本地账本，实现“单一事实来源（Single Source of Truth）”。确保 Paymaster 的逻辑与 Token 的自动还款逻辑一致。

### 🛠️ `contracts/src/interfaces/IxPNTsToken.sol`
*   **修改内容**:
    1.  增加 `getDebt` 和 `recordDebt` 接口定义。
    2.  增加 `exchangeRate` 接口定义。
*   **修改原因**:
    *   为了让 SuperPaymasterV3 能够调用 xPNTsToken 的新功能。

---

## 2. Slashing Configuration (惩罚机制 - Phase 5/6)

涉及文件：`GTokenStaking.sol`, `IGTokenStakingV3.sol`

### 🛠️ `contracts/src/core/GTokenStaking.sol`
*   **修改内容**:
    1.  新增 `slashByDVT(...)` 和 `slashByTier(...)` 函数。
    2.  实现了具体的质押扣除逻辑。
*   **修改原因**:
    *   落实 Phase 5 的 **Two-Tier Slashing** 设计。允许通过 DVT 共识（或治理）对恶意 Operator 进行质押金扣除（Level 1 扣除 10%，Level 2 扣除 100%）。

### 🛠️ `contracts/src/interfaces/IGTokenStakingV3.sol`
*   **修改内容**:
    1.  暴露 Slash 相关接口。
    2.  增加 `setRegistry` 等管理接口。
*   **修改原因**:
    *   标准化接口，允许 SuperPaymaster 和其他核心组件调用 Staking 合约的惩罚功能。

---

## 3. Role & Registry Fixes (角色管理 - Phase 6)

涉及文件：`Registry.sol`

### 🛠️ `contracts/src/core/Registry.sol`
*   **修改内容**:
    1.  `registerRole` 函数增加了对 `roleConfig` 的详细校验（minStake, exitFee）。
    2.  修复了 `EndUser` 角色的配置逻辑。
*   **修改原因**:
    *   在之前的部署测试中，发现 Registry 对某些特殊角色（如 EndUser，无需质押但有 Entry/Exit Fee）的处理有 Bug。此修改确保了所有生态角色都能正确注册和管理。

---

## 总结
这 6 个文件的修改构成了 **SuperPaymaster V3.2** 的完整升级：
1.  **底座 (Registry/Staking)**: 修复了角色准入和惩罚机制。
2.  **核心 (xPNTsToken)**: 接管了债务账本，实现了自动还款。
3.  **业务 (SuperPaymaster)**: 对接了新的债务系统，去除了本地冗余状态。

请确认以上修改是否符合预期。
