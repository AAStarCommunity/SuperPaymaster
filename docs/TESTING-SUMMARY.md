# SuperPaymaster v2.0 测试方案总结

## 📚 测试文档索引

本测试方案包含三个详细场景：

1. **[TEST-SCENARIO-1-V2-FULL-FLOW.md](./TEST-SCENARIO-1-V2-FULL-FLOW.md)** - v2完整流程测试
2. **[TEST-SCENARIO-2-V4-LEGACY-FLOW.md](./TEST-SCENARIO-2-V4-LEGACY-FLOW.md)** - v4传统流程测试
3. **[TEST-SCENARIO-3-HYBRID-MODE.md](./TEST-SCENARIO-3-HYBRID-MODE.md)** - 混合模式与迁移

---

## 🎯 快速开始

### 前置条件

```bash
# 1. 环境配置
source env/.env

# 2. 检查部署状态
cast code $SUPER_PAYMASTER_V2_ADDRESS --rpc-url $SEPOLIA_RPC_URL | head -c 100

# 3. 检查账户余额
cast balance $DEPLOYER_ADDRESS --rpc-url $SEPOLIA_RPC_URL
cast balance $OWNER2_ADDRESS --rpc-url $SEPOLIA_RPC_URL
```

### 快速测试 (5分钟)

**测试operator充值和查询**:

```bash
#!/bin/bash
# quick-test.sh

source env/.env

XPNTS_TOKEN=0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a
OPERATOR=$OWNER2_ADDRESS
OPERATOR_KEY=$OWNER2_PRIVATE_KEY

echo "=== 快速测试: v2 Operator充值 ==="

# 1. Mint xPNTs
cast send $XPNTS_TOKEN "mint(address,uint256)" $OPERATOR 10000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OPERATOR_KEY

# 2. Approve
cast send $XPNTS_TOKEN "approve(address,uint256)" $SUPER_PAYMASTER_V2_ADDRESS 1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OPERATOR_KEY

# 3. Deposit
cast send $SUPER_PAYMASTER_V2_ADDRESS "depositAPNTs(uint256)" 1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OPERATOR_KEY

# 4. 查询
echo "查询operator账户..."
cast call $SUPER_PAYMASTER_V2_ADDRESS "getOperatorAccount(address)" $OPERATOR --rpc-url $SEPOLIA_RPC_URL

echo "✅ 快速测试完成"
```

---

## 🔍 关键发现

### ✅ 已实现功能

1. **Operator注册系统**
   - GToken stake机制
   - sGToken lock验证
   - xPNTsToken关联
   - 支持的SBT配置

2. **aPNTs余额管理**
   - Operator通过burn xPNTs充值
   - aPNTs余额查询
   - 预扣和退款机制

3. **ERC-4337集成**
   - validatePaymasterUserOp
   - postOp处理
   - SBT验证

4. **安全机制**
   - ReentrancyGuard防护
   - CEI模式
   - Slash系统

### ✅ 新增功能（Phase 5 - 2025-10-23）

1. **用户xPNTs支付逻辑** ✅ 已实现
   ```solidity
   // validatePaymasterUserOp中:
   // 1. 计算aPNTs成本（Wei → USD → aPNTs，含2% fee）
   // 2. 计算xPNTs成本（基于operator汇率）
   // 3. 从用户转账xPNTs到operator's treasury
   // 4. 扣除operator的aPNTs余额
   ```

2. **汇率计算** ✅ 已实现
   ```solidity
   // OperatorAccount.exchangeRate: 18 decimals, 默认1e18 = 1:1
   // Operator可通过updateExchangeRate()自定义汇率
   // 支持灵活定价策略
   ```

3. **Treasury配置** ✅ 已实现
   ```solidity
   // OperatorAccount.treasury: 每个operator独立的treasury地址
   // 用户支付的xPNTs转入此地址
   // Operator可通过updateTreasury()修改
   ```

4. **Gas计算逻辑** ✅ 借鉴PaymasterV4
   ```solidity
   // _calculateAPNTsAmount(): Wei → USD → aPNTs
   // _calculateXPNTsAmount(): aPNTs → xPNTs
   // 2% service fee作为协议收入（不退款）
   ```

### 当前经济模型（✅ Phase 5 + 5.2实现）

**关键概念**:
- **aPNTs** = AAStar社区的ERC20 token（0.02 USD each）- Operator购买并deposit
- **xPNTs** = 各operator社区发行的token - 用户持有并支付

```
        Operator充值流程（购买backing资产）
┌──────────┐  购买aPNTs    ┌───────────┐
│ Operator │──────────────→│AAStar市场 │
└──────────┘                └───────────┘
      ↓
  depositAPNTs(aPNTs)
      ↓
┌─────────────────┐
│SuperPaymaster合约│  ← aPNTs存入合约
└─────────────────┘
      ↓
  aPNTs余额记录+

        用户交易流程（双重支付）
┌─────────┐  支付xPNTs     ┌────────────────┐
│  User   │─────────────→ │Operator Treasury│ (社区收入)
└────┬────┘                └────────────────┘
     │ SBT验证
     │ validatePaymasterUserOp
     ↓
┌─────────────────┐  aPNTs  ┌─────────────────────┐
│SuperPaymaster合约│────────→│SuperPaymaster Treasury│ (协议收入)
└─────────────────┘          └─────────────────────┘
      ↓
Operator余额 - aPNTs

✅ 用户支付xPNTs到operator's treasury（社区收入）
✅ Operator消耗预充值的aPNTs（backing资产）
✅ 消耗的aPNTs转入SuperPaymaster treasury（协议收入）
✅ 两种token完全分离（aPNTs ≠ xPNTs）
✅ 2% service fee不退款（已计入aPNTs消耗）
```

### 双重支付机制

1. **用户侧**: 支付xPNTs（社区积分）到operator's treasury
   - xPNTs是operator发行的社区token
   - 汇率由operator设置（默认1:1）
   - 成为operator的社区收入

2. **Operator侧**: 消耗aPNTs余额（gas backing）
   - aPNTs是AAStar的token（0.02 USD each）
   - Operator提前购买并deposit
   - 消耗的aPNTs转入SuperPaymaster treasury

3. **汇率转换**: xPNTs amount = aPNTs amount × exchangeRate
   - 允许operator自定义xPNTs相对于aPNTs的价值
   - 支持灵活定价策略

4. **Service fee**: aPNTs含2%上浮，作为协议收入
   - Gas cost计算时加2%
   - 不退款，直接进入SuperPaymaster treasury

---

## 📋 测试优先级

### P0 (必须完成)

- [x] Operator注册流程
- [x] aPNTs充值和查询
- [x] SBT验证机制
- [x] **用户xPNTs支付逻辑** ✅ Phase 5完成
- [x] **汇率配置** ✅ Phase 5完成
- [x] **Treasury地址配置** ✅ Phase 5完成

### P1 (重要)

- [ ] 完整UserOp测试（需要bundler）
- [ ] MySBT铸造和验证
- [ ] Slash机制测试
- [ ] DVT validator注册

### P2 (建议)

- [ ] v4兼容性测试
- [ ] 混合模式测试
- [ ] 用户迁移流程
- [ ] 压力测试

---

## ✅ Phase 5 实现总结 (2025-10-23)

### 1. Operator级别Treasury配置 ✅

**文件**: `src/v2/core/SuperPaymasterV2.sol`

```solidity
// OperatorAccount结构体中添加
struct OperatorAccount {
    ...
    address treasury;        // Operator独立的treasury地址
    uint256 exchangeRate;    // xPNTs <-> aPNTs汇率
}

// Setter函数
function updateTreasury(address newTreasury) external {
    // Operator可更新自己的treasury
}

// Event
event TreasuryUpdated(address indexed operator, address indexed newTreasury);
```

### 2. validatePaymasterUserOp中转账xPNTs ✅

**实现方式**：借鉴PaymasterV4，直接在validate阶段完成支付

```solidity
function validatePaymasterUserOp(...) external returns (...) {
    // 1. 计算aPNTs成本（Wei → USD → aPNTs，含2% fee）
    uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);

    // 2. 基于operator汇率计算xPNTs成本
    uint256 xPNTsAmount = _calculateXPNTsAmount(operator, aPNTsAmount);

    // 3. 从用户转账xPNTs到operator's treasury
    IERC20(xPNTsToken).transferFrom(user, treasury, xPNTsAmount);

    // 4. 扣除operator的aPNTs余额（不退款）
    accounts[operator].aPNTsBalance -= aPNTsAmount;

    emit TransactionSponsored(operator, user, aPNTsAmount, xPNTsAmount, block.timestamp);
}

// postOp简化为空（无退款逻辑）
function postOp(...) external {
    require(msg.sender == ENTRY_POINT, "Only EntryPoint");
    // Empty - 2% upcharge不退款，作为协议收入
}
```

### 3. 汇率配置系统 ✅

```solidity
// Storage (在OperatorAccount中)
uint256 exchangeRate;  // 18 decimals, 1e18 = 1:1

// Setter
function updateExchangeRate(uint256 newRate) external {
    if (accounts[msg.sender].stakedAt == 0) revert NotRegistered(msg.sender);
    if (newRate == 0) revert InvalidAmount(newRate);
    accounts[msg.sender].exchangeRate = newRate;
    emit ExchangeRateUpdated(msg.sender, newRate);
}

// Event
event ExchangeRateUpdated(address indexed operator, uint256 newRate);
```

### 4. Gas计算辅助函数 ✅

```solidity
// 计算aPNTs成本（含2% service fee）
function _calculateAPNTsAmount(uint256 gasCostWei) internal view returns (uint256) {
    uint256 gasCostUSD = (gasCostWei * gasToUSDRate) / 1e18;
    uint256 totalCostUSD = gasCostUSD * (BPS_DENOMINATOR + serviceFeeRate) / BPS_DENOMINATOR;
    uint256 aPNTsAmount = (totalCostUSD * 1e18) / aPNTsPriceUSD;
    return aPNTsAmount;
}

// 基于汇率计算xPNTs成本
function _calculateXPNTsAmount(address operator, uint256 aPNTsAmount) internal view returns (uint256) {
    uint256 rate = accounts[operator].exchangeRate;
    if (rate == 0) rate = 1 ether; // Fallback to 1:1
    return (aPNTsAmount * rate) / 1e18;
}
```

### 5. aPNTs Token配置 & 正确的经济模型 ✅ (Phase 5.2)

**关键修正**: aPNTs和xPNTs是两种完全不同的token

```solidity
// Storage
address public aPNTsToken;              // AAStar社区的ERC20 token
address public superPaymasterTreasury;  // 接收消耗的aPNTs

// Setter (onlyOwner)
function setAPNTsToken(address newToken) external onlyOwner {
    aPNTsToken = newToken;
    emit APNTsTokenUpdated(oldToken, newToken);
}

function setSuperPaymasterTreasury(address newTreasury) external onlyOwner {
    superPaymasterTreasury = newTreasury;
    emit SuperPaymasterTreasuryUpdated(oldTreasury, newTreasury);
}

// depositAPNTs: Operator转入aPNTs（不是xPNTs）
function depositAPNTs(uint256 amount) external nonReentrant {
    // Operator购买的aPNTs转入SuperPaymaster合约
    IERC20(aPNTsToken).transferFrom(msg.sender, address(this), amount);
    accounts[msg.sender].aPNTsBalance += amount;
}

// validatePaymasterUserOp: 双重转账
function validatePaymasterUserOp(...) external returns (...) {
    // 1. 用户xPNTs → Operator treasury
    IERC20(xPNTsToken).transferFrom(user, operatorTreasury, xPNTsAmount);

    // 2. 合约aPNTs → SuperPaymaster treasury
    IERC20(aPNTsToken).transfer(superPaymasterTreasury, aPNTsAmount);

    // 3. 扣除operator余额
    accounts[operator].aPNTsBalance -= aPNTsAmount;
}
```

**关键区别**:
- ✅ aPNTs：AAStar token（Operator购买并deposit作为backing）
- ✅ xPNTs：社区token（用户持有并支付给operator）
- ✅ 两者完全独立，通过汇率关联
- ✅ aPNTs backing：存在SuperPaymaster合约，消耗后转treasury

---

## 🧪 测试脚本合集

### script/v2/TestOperatorSetup.s.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

contract TestOperatorSetup is Script {
    function run() external {
        // 1. Mint xPNTs
        // 2. Deposit aPNTs
        // 3. Query account
    }
}
```

### script/v2/TestUserFlow.s.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

contract TestUserFlow is Script {
    function run() external {
        // 1. Mint SBT
        // 2. Get xPNTs
        // 3. Prepare UserOp
    }
}
```

---

## 📊 测试矩阵

| 测试场景 | v4 Paymaster | v2 Paymaster | 预期结果 |
|---------|-------------|-------------|---------|
| 用户有PNT + v1 SBT | ✅ 成功 | ❌ 不支持PNT | v4可用 |
| 用户有xPNTs + MySBT | ❌ 不支持xPNTs | ⚠️ 成功（但不扣xPNTs）| v2可用（待完善）|
| 用户两者都有 | ✅ 成功 | ⚠️ 成功（但不扣xPNTs）| 混合模式 |
| 用户两者都没有 | ❌ 失败 | ❌ 失败 | 需要资产 |

---

## 🎯 下一步行动

### 立即执行 (本周)

1. **补充用户支付逻辑** - 在postOp中添加xPNTs转账
2. **添加treasury配置** - 设置用户支付目标地址
3. **添加汇率配置** - 支持operator自定义aPNTs/xPNTs汇率
4. **运行快速测试** - 验证operator充值流程

### 短期计划 (2周)

1. **搭建bundler环境** - 使用Pimlico或本地bundler
2. **完整UserOp测试** - 端到端交易测试
3. **MySBT测试** - 验证SBT铸造和验证
4. **更新测试文档** - 补充实际测试结果

### 中期计划 (1个月)

1. **v4兼容性测试** - 验证v4继续可用
2. **混合模式测试** - 同一用户切换测试
3. **DVT validator注册** - 去中心化监控
4. **压力测试** - 高并发场景

### 长期计划 (3个月)

1. **用户迁移支持** - 提供迁移工具
2. **社区运营** - 吸引operator注册
3. **经济模型验证** - 真实环境测试
4. **主网部署准备** - 专业审计

---

## 📖 相关资源

### 文档
- [部署报告](./Changes.md)
- [安全审计](./SECURITY-AUDIT-REPORT-v2.0-beta.md)
- [场景1: v2完整流程](./TEST-SCENARIO-1-V2-FULL-FLOW.md)
- [场景2: v4传统流程](./TEST-SCENARIO-2-V4-LEGACY-FLOW.md)
- [场景3: 混合模式](./TEST-SCENARIO-3-HYBRID-MODE.md)

### 外部资源
- [ERC-4337 Spec](https://eips.ethereum.org/EIPS/eip-4337)
- [Pimlico Documentation](https://docs.pimlico.io/)
- [Alchemy Account Kit](https://www.alchemy.com/account-kit)
- [Sepolia Etherscan](https://sepolia.etherscan.io/)

---

## ✅ 总结

### 当前状态
- ✅ 核心合约已部署
- ✅ Operator注册流程可用
- ✅ aPNTs充值机制可用
- ⚠️ 用户支付逻辑待实现
- ⚠️ 完整UserOp测试需要bundler

### 关键问题
1. **用户xPNTs支付未实现** - 这是v2经济模型的核心
2. **汇率配置缺失** - 需要支持灵活定价
3. **Treasury地址未配置** - 用户支付无目标

### 建议
1. **优先补充用户支付逻辑**
2. **先测试预充值模式**（operator免费赞助）
3. **明确v2经济模型**（预充值 vs 实时支付）

---

**最后更新**: 2025-10-22
**测试环境**: Sepolia Testnet
**合约版本**: v2.0-beta
