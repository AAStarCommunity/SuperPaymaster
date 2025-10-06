# SuperPaymaster V3 汇率设计方案

## 文档版本
- 创建时间: 2025-10-06
- 作者: Jason
- 状态: 设计讨论阶段

## 1. 设计目标

### 1.1 核心需求
- **汇率设定**: PNT:ETH = 1:100 (即 1 PNT = 0.01 ETH)
- **记账单位**: Settlement合约记录ETH金额 (wei)
- **结算单位**: 实际扣除PNT代币
- **汇率转换**: 在结算时将ETH金额转换为PNT数量扣除

### 1.2 实际场景
```
PNT初始价格: $0.02-0.03 USD
一次ERC20转账gas成本: 2.5 PNT (正常情况)
价格波动范围: 2.6-2.7 PNT (±10%正常波动)
剧烈波动处理: 扣除更多PNT 或 延迟结算
```

### 1.3 计算示例
```
Gas成本: 0.00038 ETH (记录在Settlement)
汇率: 1 PNT = 0.01 ETH
需要扣除: 0.00038 ETH ÷ 0.01 = 0.038 PNT
```

## 2. 当前实现分析

### 2.1 当前流程
```
1. EntryPoint调用PaymasterV3.validatePaymasterUserOp()
   - 检查: SBT余额 > 0
   - 检查: PNT余额 >= 10 PNT (minTokenBalance)
   ✅ 通过验证

2. EntryPoint执行UserOp
   - PaymasterV3从自己的deposit支付gas (ETH)
   
3. EntryPoint调用PaymasterV3.postOp()
   - 计算: actualGasCost (ETH wei)
   - 调用: Settlement.recordGasFee(user, PNT地址, actualGasCost, hash)
   
4. Settlement存储记录
   - 记录金额: actualGasCost (ETH wei)
   - 标记token: PNT代币地址
   - 状态: Pending
   - ❌ 用户PNT余额未减少

5. Owner调用Settlement.settleFees()
   - 当前逻辑: 只修改状态 Pending → Settled
   - ❌ 没有实际转账PNT
   - ❌ 没有汇率转换
```

### 2.2 存在的问题

**问题1: 单位不匹配**
```
记录的金额: 380009120000 wei (0.00038 ETH)
但token字段: PNT代币地址
问题: 0.00038 个PNT ≠ 0.00038 ETH 的价值
```

**问题2: 没有实际扣款**
```
Settlement.settleFees() 只改状态,不转账
用户PNT余额始终不变
```

**问题3: Registry的feeRate未使用**
```
Registry.feeRate = 100 (1% basis points)
这不是PNT:ETH汇率
且当前代码完全没有使用这个值
```

## 3. 设计方案对比

### 方案A: 修改Registry存储汇率 ❌ 不推荐

**修改内容:**
```solidity
// 需要修改已部署的Registry合约
struct PaymasterInfo {
    uint256 feeRate;       // 已有
    uint256 exchangeRate;  // 新增: PNT:ETH汇率
    address gasToken;      // 新增: PNT代币地址
}
```

**缺点:**
- Registry是外部已部署合约 (0x4e67678AF714f6B5A8882C2e5a78B15B08a79575)
- 可能被多个Paymaster共享
- 修改需要重新部署,影响所有使用方
- 升级成本高

### 方案B: Settlement独立管理汇率 ✅ 推荐

**设计思路:**
```solidity
// Settlement.sol 新增状态变量
mapping(address => uint256) public paymasterExchangeRates;  // paymaster => 汇率
mapping(address => address) public paymasterGasTokens;      // paymaster => PNT地址
address public treasury;  // 接收PNT的财库地址

// Owner配置函数
function setPaymasterExchangeRate(address paymaster, uint256 rate) external onlyOwner;
function setPaymasterGasToken(address paymaster, address token) external onlyOwner;
function setTreasury(address _treasury) external onlyOwner;
```

**优点:**
- 不依赖Registry修改
- Settlement完全控制汇率
- 支持不同Paymaster使用不同汇率
- 易于未来扩展(动态汇率、多PNT支持)

## 4. 汇率表示方法

### 4.1 精度设计

**使用1e18精度:**
```solidity
// exchangeRate = 1e16 表示 1 PNT = 0.01 ETH

// 计算公式
uint256 pntAmount = (ethAmountWei * 1e18) / exchangeRate;

// 示例计算
ethAmountWei = 380009120000 wei (0.00038 ETH)
exchangeRate = 1e16 (1 PNT = 0.01 ETH)

pntAmount = 380009120000 * 1e18 / 1e16
          = 380009120000 * 100
          = 38000912000000 wei
          = 0.038 PNT (18 decimals)
```

### 4.2 汇率配置示例

**场景1: 1 PNT = 0.01 ETH (1:100)**
```
exchangeRate = 1e18 / 100 = 1e16
或
exchangeRate = 0.01 * 1e18 = 1e16
```

**场景2: 1 PNT = 0.005 ETH (1:200)**
```
exchangeRate = 1e18 / 200 = 5e15
```

**场景3: 动态汇率(根据市场价)**
```
假设 PNT = $0.025, ETH = $2500
则 1 PNT = 0.025 / 2500 = 0.00001 ETH
exchangeRate = 0.00001 * 1e18 = 1e13
```

## 5. 完整结算流程设计

### 5.1 Phase 1: 初始配置

```bash
# 1. 部署时配置
Settlement.setTreasury(0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C)
Settlement.setPaymasterExchangeRate(
    0x1568da4ea1E2C34255218b6DaBb2458b57B35805,  # PaymasterV3
    1e16  # 1 PNT = 0.01 ETH
)
Settlement.setPaymasterGasToken(
    0x1568da4ea1E2C34255218b6DaBb2458b57B35805,  # PaymasterV3
    0x3e7B771d4541eC85c8137e950598Ac97553a337a   # PNT Token
)

# 2. 用户授权Settlement
# 每个用户需要执行一次
PNT.approve(Settlement地址, type(uint256).max)
```

### 5.2 Phase 2: UserOp执行流程

```
用户提交UserOp
  ↓
EntryPoint → PaymasterV3.validatePaymasterUserOp()
  - 验证: SBT > 0 ✅
  - 验证: PNT >= 10 ✅
  ↓
EntryPoint执行UserOp (从PaymasterV3 deposit扣ETH)
  ↓
EntryPoint → PaymasterV3.postOp()
  - actualGasCost = 380009120000 wei
  ↓
PaymasterV3 → Settlement.recordGasFee()
  - user: 0x411BD...
  - token: 0x3e7B... (PNT)
  - amount: 380009120000 (ETH wei)
  - userOpHash: 0xabc...
  ↓
Settlement存储:
  - FeeRecord.amount = 380009120000 (ETH wei)
  - FeeRecord.status = Pending
  - pendingAmounts[user][PNT] += 380009120000
```

### 5.3 Phase 3: 批量结算流程

```
Owner调用: Settlement.settleFees(recordKeys[], settlementHash)
  ↓
对每条记录:
  1. 读取: record = _feeRecords[recordKey]
  2. 获取汇率:
     - exchangeRate = paymasterExchangeRates[record.paymaster]
     - gasToken = paymasterGasTokens[record.paymaster]
  
  3. 汇率转换:
     - ethAmount = record.amount  // 380009120000 wei
     - pntAmount = (ethAmount * 1e18) / exchangeRate
     - pntAmount = 380009120000 * 1e18 / 1e16 = 38000912000000 (0.038 PNT)
  
  4. 可选:添加手续费
     - if (feeRate > 0) {
         fee = (pntAmount * feeRate) / 10000
         pntAmount += fee
       }
     - 如果feeRate=100 (1%):
       pntAmount = 0.038 * 1.01 = 0.03838 PNT
  
  5. 扣除PNT:
     - IERC20(gasToken).transferFrom(
         record.user,      // from: 用户
         treasury,         // to: 财库
         pntAmount         // amount: 0.03838 PNT
       )
  
  6. 更新状态:
     - record.status = Settled
     - record.settlementHash = settlementHash
     - pendingAmounts[user][token] -= ethAmount
     - totalPending[token] -= ethAmount
  
  7. 触发事件:
     - emit FeeSettled(recordKey, pntAmount, settlementHash)
```

## 6. 经济模型分析

### 6.1 成本计算 (1 PNT = 0.01 ETH)

**单次ERC20转账:**
```
Gas Price: 1 Gwei
Total Gas: 380,000
Gas Cost: 0.00038 ETH

PNT成本:
- 基础: 0.00038 ETH / 0.01 = 0.038 PNT
- 加1%费率: 0.038 * 1.01 = 0.03838 PNT
```

**价格验证:**
```
假设 PNT = $0.025, ETH = $2500
1 PNT = 0.01 ETH 是否合理?

0.01 ETH = $25
但 1 PNT = $0.025
不匹配! ❌

调整汇率:
如果 PNT = $0.025, ETH = $2500
应该 1 PNT = 0.025 / 2500 = 0.00001 ETH (1:100,000)
exchangeRate = 1e13

用户成本:
0.00038 ETH / 0.00001 = 38 PNT 一次转账
```

### 6.2 汇率校准建议

**方案1: 固定汇率 (简单)**
```
设定目标: 1次转账 ≈ 2.5 PNT
当前gas成本: 0.00038 ETH

计算汇率:
1 PNT = 0.00038 / 2.5 = 0.000152 ETH
exchangeRate = 0.000152 * 1e18 = 1.52e14

验证:
pntAmount = 0.00038 * 1e18 / 1.52e14 = 2.5 PNT ✅
```

**方案2: 锚定USD价格 (推荐)**
```
假设:
- PNT目标价: $0.025
- ETH当前价: $2500
- Gas成本: $0.95

步骤1: 计算PNT:ETH汇率
1 PNT = $0.025
1 ETH = $2500
1 PNT = 0.025 / 2500 = 0.00001 ETH
exchangeRate = 1e13

步骤2: 计算一次转账PNT成本
Gas = 0.00038 ETH = $0.95
PNT = 0.95 / 0.025 = 38 PNT

步骤3: 如果希望降低到2.5 PNT/次
需要提高PNT价格: $0.95 / 2.5 = $0.38/PNT
或提供补贴: 38 - 2.5 = 35.5 PNT (92.8%补贴)
```

### 6.3 100 PNT余额够用吗?

**场景1: 汇率 1:100 (1 PNT = 0.01 ETH)**
```
每次转账: 0.038 PNT
100 PNT可用次数: 100 / 0.038 ≈ 2631次 ✅
```

**场景2: 汇率 1:100,000 (1 PNT = 0.00001 ETH)**
```
每次转账: 38 PNT
100 PNT可用次数: 100 / 38 ≈ 2.6次 ⚠️
建议minTokenBalance提高到500 PNT
```

**场景3: 目标2.5 PNT/次**
```
每次转账: 2.5 PNT
100 PNT可用次数: 100 / 2.5 = 40次 ✅
```

## 7. 风险与挑战

### 7.1 汇率波动风险

**问题:** Gas price剧烈波动导致PNT扣除量不稳定

```
Gas Price: 1 Gwei → 10 Gwei (10倍)
PNT成本: 2.5 PNT → 25 PNT

用户余额不足可能导致结算失败
```

**解决方案:**
1. **设置gas price上限**
   - PaymasterV3在验证时检查maxFeePerGas
   - 超过阈值拒绝赞助
   
2. **动态调整minTokenBalance**
   - 根据近期平均gas price调整
   - 例: gasPrice > 10 Gwei时, minTokenBalance = 50 PNT

3. **延迟结算机制**
   - 用户余额不足时,记录为SettlementFailed
   - 等待用户充值后再次尝试
   - 设置grace period (7天内补足)

### 7.2 PNT价格波动风险

**问题:** PNT市场价格波动影响实际成本

```
初始: PNT = $0.025, 用户付 2.5 PNT = $0.0625
波动后: PNT = $0.05, 用户付 2.5 PNT = $0.125 (翻倍)
```

**解决方案:**
1. **定期更新汇率**
   - 每周根据PNT/ETH市场价更新
   - 使用价格预言机(Chainlink)

2. **设置汇率波动上限**
   - 单次调整不超过±20%
   - 需要governance投票通过

3. **用户锁定汇率**
   - 用户可以预付PNT锁定当前汇率
   - 类似"充值卡"模式

### 7.3 用户授权问题

**问题:** 用户必须approve Settlement合约才能扣款

```
未授权: transferFrom失败 → 结算失败
恶意撤销授权: 绕过付费
```

**解决方案:**
1. **在PaymasterV3验证时检查授权**
   ```solidity
   uint256 allowance = IERC20(gasToken).allowance(user, settlement);
   require(allowance >= estimatedCost, "Insufficient allowance");
   ```

2. **使用permit (EIP-2612)**
   - 用户签名授权,bundler提交
   - 无需提前approve交易

3. **黑名单机制**
   - 多次结算失败的用户加入黑名单
   - 拒绝提供gas赞助

## 8. 实施路线图

### Phase 1: 固定汇率 + 单一PNT (MVP)

**目标:** 验证核心流程,快速上线

**实现:**
- Settlement添加汇率管理功能
- settleFees()添加转账逻辑
- 手动配置exchangeRate = 1e14 (目标2.5 PNT/次)
- 要求用户提前approve

**时间:** 1周

### Phase 2: 动态汇率 + 风控机制

**目标:** 应对价格波动,保护协议和用户

**实现:**
- 集成Chainlink价格预言机
- 添加汇率更新函数(Owner调用)
- 实现延迟结算机制
- 添加gas price上限检查

**时间:** 2-3周

### Phase 3: 多PNT支持 + 用户选择

**目标:** 支持多种代币支付,提升用户体验

**实现:**
- Settlement支持多token映射
- 用户在paymasterAndData中指定token
- 不同token不同汇率
- 自动选择最优token

**时间:** 1-2个月

## 9. 配置清单

### 9.1 部署后立即配置

```bash
# Settlement配置
Settlement.setTreasury(0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C)

# PaymasterV3配置汇率 (目标: 2.5 PNT/次)
Settlement.setPaymasterExchangeRate(
    0x1568da4ea1E2C34255218b6DaBb2458b57B35805,  # PaymasterV3
    152000000000000  # 1.52e14 (1 PNT = 0.000152 ETH)
)

Settlement.setPaymasterGasToken(
    0x1568da4ea1E2C34255218b6DaBb2458b57B35805,
    0x3e7B771d4541eC85c8137e950598Ac97553a337a  # PNT
)
```

### 9.2 用户准备

```bash
# 每个用户需要执行
PNT.approve(
    0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5,  # Settlement
    type(uint256).max
)
```

### 9.3 验证检查

```bash
# 检查配置
cast call $SETTLEMENT "paymasterExchangeRates(address)" $PAYMASTER_V3
# 期望: 152000000000000 (0x89e425a5dc00)

cast call $SETTLEMENT "paymasterGasTokens(address)" $PAYMASTER_V3
# 期望: 0x3e7B771d4541eC85c8137e950598Ac97553a337a

cast call $SETTLEMENT "treasury()" 
# 期望: 0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C

# 检查用户授权
cast call $PNT "allowance(address,address)" $USER $SETTLEMENT
# 期望: > 0
```

## 10. 下一步讨论事项

### 10.1 待确认的设计决策

1. **汇率精确值**
   - 选项A: 1:100 (1 PNT = 0.01 ETH)
   - 选项B: 1:100,000 (1 PNT = 0.00001 ETH, 按$0.025计算)
   - 选项C: 自定义 (目标2.5 PNT/次)
   - **您的倾向?**

2. **手续费率 (feeRate)**
   - 当前Registry中的100 (1%)是否保留?
   - 是作为额外费用还是已包含在汇率中?
   - **建议:** 初期设为0,后续根据需要开启

3. **minTokenBalance调整**
   - 当前: 10 PNT
   - 如果每次2.5 PNT: 建议提高到50 PNT (20次余量)
   - 如果每次38 PNT: 建议提高到500 PNT (13次余量)
   - **您的期望值?**

4. **Treasury地址**
   - 当前配置: 0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C
   - 是否为最终地址?
   - 建议使用多签钱包

### 10.2 技术实现优先级

**必须实现 (MVP):**
- [ ] Settlement添加汇率存储
- [ ] Settlement添加PNT转账逻辑
- [ ] 配置脚本

**高优先级:**
- [ ] 用户授权检查
- [ ] 余额不足处理
- [ ] Gas price上限保护

**中优先级:**
- [ ] 动态汇率更新
- [ ] 价格预言机集成
- [ ] 延迟结算机制

**低优先级:**
- [ ] 多PNT支持
- [ ] 用户锁定汇率
- [ ] 前端界面

### 10.3 测试计划

1. **单元测试**
   - 汇率转换计算正确性
   - PNT转账成功/失败处理
   - 边界条件测试

2. **集成测试**
   - 完整UserOp → 结算流程
   - 多用户批量结算
   - 异常场景(余额不足、未授权)

3. **Sepolia测试网验证**
   - 部署修改后的Settlement
   - 配置汇率和token
   - 执行真实UserOp
   - 验证PNT扣除正确

4. **主网部署前审计**
   - 代码安全审计
   - 经济模型审查
   - 压力测试

## 11. 参考资料

### 11.1 相关合约
- Settlement: `0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5`
- PaymasterV3: `0x1568da4ea1E2C34255218b6DaBb2458b57B35805`
- Registry: `0x4e67678AF714f6B5A8882C2e5a78B15B08a79575`
- PNT Token: `0x3e7B771d4541eC85c8137e950598Ac97553a337a`
- Treasury: `0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C`

### 11.2 Gas成本参考
- 账户验证: ~100,000 gas
- ERC20转账: ~50,000 gas
- Paymaster验证: ~150,000 gas
- PostOp记账: ~80,000 gas
- **总计: ~380,000 gas**

### 11.3 价格假设
- ETH: $2,500
- PNT目标价: $0.02-0.03
- Gas Price: 1-10 Gwei (Sepolia) / 10-50 Gwei (Mainnet)

---

**文档状态:** 等待讨论和确认
**下一步:** 根据讨论结果确定具体汇率和实现优先级
