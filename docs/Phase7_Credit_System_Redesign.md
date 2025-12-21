# Phase 7: Credit System Redesign (用户信用债务系统)

## 1. 核心问题与其解决
当前的 V3 Credit 系统设计存在记账主体错位的问题。运营商不应承担债务，债务必须归属于享受了 Gas 垫付服务的具体用户。

**解决方案**: 实施 **Debt-First (负债优先)** 模型。我们将债务逻辑下沉到 `xPNTsToken` (ERC20) 合约中。该 Token 合约将维护两个状态：
1. **Balance**: 正常的代币余额。
2. **Debt**: 欠款余额 (计价单位: xPNTs)。

## 2. 详细业务逻辑

### 2.1 角色与资产
- **用户 (EndUser)**: 服务的消费者，欠债方。
- **社区 (Community/Operator)**: 服务的提供者，Gas 费用的实际支付方 (支付 aPNTs)。
- **SuperPaymaster**: 执行机构，负责扣款和记账。

### 2.2 流程 A: 发生透支 (Gas 支付)
当用户余额不足，但信用额度 (Credit Limit) 足够时：
1. **Operator 支付**: SuperPaymaster 从 Operator 账户中销毁 aPNTs (支付给协议)。
2. **User 记账**: SuperPaymaster 计算 `xPNTsValue = aPNTsValue * Rate`，调用 `xPNTsToken.recordDebt(user, xPNTsValue)`。
3. **Token 状态**: `xPNTsToken` 增加用户的 debt (xPNTs 单位)。
*注意: 此时用户的 balance 为 0 (或保持不变)，但 debt 增加。*

### 2.3 流程 B: 自动还款 (收入抵扣)
当用户通过由于贡献或其他原因获得 xPNTs 收入 (Transfer / Mint) 时：
1. **拦截收入**: `xPNTsToken` 在 `_update` (转账钩子) 中检测接收方 (`to`) 是否有 `debt > 0`。
2. **计算抵扣**: `repayAmount = min(incomingAmount, debt)` (都是 xPNTs 单位，无需换算)。
3. **执行还款**:
   - **销毁**: 将 `repayAmount` 的 xPNTs 直接销毁 (Burn)。
   - **平账**: 减少用户的 debt (xPNTs 单位)。
   - **入账**: 剩余的 `incomingAmount - repayAmount` 进入用户的 balance。
4. **记录日志**: 抛出 `DebtRepaid(user, repayAmountXPNTs, offsetDebtAPNTs)` 事件，供社区后端对账。

## 3. 合约修改计划

### 3.1 `IxPNTsToken.sol` (接口)
需要新增接口供 Paymaster 调用：
```solidity
function recordDebt(address user, uint256 amountXPNTs) external;
function getDebt(address user) external view returns (uint256);
```

### 3.2 `xPNTsToken.sol` (实现)
- **Storage**: 新增 `mapping(address => uint256) public debts;` // xPNTs units
- **Permission**: `recordDebt` 函数需修饰为 `onlySuperPaymaster` (复用现有的 `SUPERPAYMASTER_ADDRESS` 变量)。
- **Core Logic**:
  - 重写 `_update` 函数实现“拦截-销毁-记账”逻辑。
  - 确保 `recordDebt` 只增加债务，不影响当前余额。

### 3.3 `SuperPaymasterV3.sol` (业务层)
- **Verification**: 在 `validatePaymasterUserOp` 中：
  - 读取 `token.getDebt(sender)`。
  - 计算 `AvailableCredit = CreditLimit - CurrentDebt`。
  - 如果 `Cost > AvailableCredit`，则拒绝交易。
- **PostOp**: 在 `postOp` 中：
  - 如果使用了 Credit 模式，调用 `token.recordDebt(sender, cost)`。

### 3.4 `xPNTsFactory.sol` (工厂)
因为 `xPNTsToken` 的逻辑改变了，我们需要重新部署 `xPNTsToken` Implementation 合约。Factory 合约通常存储了 Implementation 地址。需要调用 Factory 的更新函数指向新的 Implementation。

## 4. 验证计划 (Test Plan)

### 场景一：透支消费
1. Alice (余额 0) 发起交易。
2. Paymaster 验证通过 (User Credit > 0)。
3. Operator 余额减少 (支付了 Gas)。
4. Alice 的 Token 合约中 debt 增加。

### 场景二：部分还款
1. 给 Alice 转账 50 xPNTs (欠债 100 等值)。
2. Alice 余额仍为 0。
3. Alice debt 减少。
4. 50 xPNTs 被销毁。

### 场景三：完全还款与盈余
1. 给 Alice 再转账 100 xPNTs (欠债 50 等值)。
2. Alice debt 归零。
3. Alice 余额增加 50。
4. 50 xPNTs 被销毁。
