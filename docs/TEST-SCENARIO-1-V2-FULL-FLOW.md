# 测试场景1: SuperPaymaster v2.0 完整流程测试

## 🎯 测试目标
验证SuperPaymaster v2.0的完整operator注册和用户交易赞助流程

## ⚠️ 当前实现限制

### 已实现功能 ✅
- Operator注册（stake + lock sGToken）
- aPNTs余额管理（operator预充值）
- SBT验证机制
- ERC-4337 validatePaymasterUserOp + postOp

### 未实现功能 ❌
1. **用户xPNTs支付逻辑** - 当前没有从用户转账xPNTs到treasury的代码
2. **汇率计算** - 没有aPNTs <-> xPNTs的汇率转换
3. **Treasury配置** - 没有treasury地址来接收用户支付

### 当前经济模型
```
用户发起交易 → SuperPaymaster验证SBT → 扣除operator的aPNTs → 交易完成
                                        ↑
                                    用户不需要支付xPNTs
```

### 理想经济模型（需要补充实现）
```
用户发起交易 → SuperPaymaster验证SBT → 扣除operator的aPNTs
              ↓                          ↓
          转账xPNTs到treasury         退还剩余aPNTs
```

---

## 📋 测试阶段划分

### 阶段1: 社区Operator设置 (已完成✅)

**角色**: Community Operator (OWNER2)
- 地址: `0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA`
- 私钥: `0xc801db57d05466a8f16d645c39f59aeb0c1aee15b3a07b4f5680d3349f094009`

**已完成步骤**:
1. ✅ 获取50 GToken
2. ✅ Stake 35 GToken → 获得35 sGToken
3. ✅ 创建xPNTsToken (`0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a`)
4. ✅ 注册operator（lock 30 sGToken）

---

### 阶段2: Operator充值aPNTs

**目标**: Operator预充值aPNTs用于赞助用户交易

#### 步骤2.1: Mint xPNTs给operator

```bash
# 合约地址
XPNTS_TOKEN=0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a
OPERATOR=0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA
OPERATOR_KEY=0xc801db57d05466a8f16d645c39f59aeb0c1aee15b3a07b4f5680d3349f094009
PAYMASTER=0xeC3f8d895dcD9f9055e140b4B97AF523527755cF

# Mint 10000 xPNTs给operator（社区发行）
cast send $XPNTS_TOKEN \
  "mint(address,uint256)" \
  $OPERATOR \
  10000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OPERATOR_KEY
```

**验证**:
```bash
cast call $XPNTS_TOKEN "balanceOf(address)(uint256)" $OPERATOR --rpc-url $SEPOLIA_RPC_URL
# 预期输出: 10000000000000000000000 (10000 xPNTs)
```

#### 步骤2.2: 授权SuperPaymaster使用xPNTs

```bash
# Approve SuperPaymaster
cast send $XPNTS_TOKEN \
  "approve(address,uint256)" \
  $PAYMASTER \
  1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OPERATOR_KEY
```

#### 步骤2.3: Deposit aPNTs (burn xPNTs 1:1)

```bash
# Deposit 1000 aPNTs (burn 1000 xPNTs)
cast send $PAYMASTER \
  "depositAPNTs(uint256)" \
  1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OPERATOR_KEY
```

**验证operator账户**:
```bash
# 查询operator账户
cast call $PAYMASTER \
  "getOperatorAccount(address)" \
  $OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL | cast --abi-decode "f()(uint256,uint256,uint256,uint256,uint256,uint256,address[],address,uint256,uint256,uint256,uint256,bool)"

# 检查aPNTsBalance字段应该为1000e18
```

---

### 阶段3: 用户准备

**角色**: 测试用户 (TEST_EOA)
- 地址: `0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d`
- 需要准备: SBT, 测试USDC, xPNTs余额

#### 步骤3.1: 用户mint SBT

**前提**: 用户需要先有GToken和stake

```bash
TEST_USER=0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d
GTOKEN=0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35
GTOKEN_STAKING=0xD8235F8920815175BD46f76a2cb99e15E02cED68
MYSBT=0x82737D063182bb8A98966ab152b6BAE627a23b11

# 1. Mint GToken给用户
cast send $GTOKEN "mint(address,uint256)" $TEST_USER 10000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $DEPLOYER_KEY

# 2. 用户stake 1 GToken
# (需要TEST_USER的私钥)
cast send $GTOKEN "approve(address,uint256)" $GTOKEN_STAKING 1000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $TEST_USER_KEY

cast send $GTOKEN_STAKING "stake(uint256)" 1000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $TEST_USER_KEY
```

**问题**: 需要TEST_USER的私钥才能操作，但env中没有。

**解决方案**: 使用OWNER2作为测试用户（已有私钥和stake）

#### 步骤3.2: Mint SBT

```bash
# 使用OWNER2作为测试用户
TEST_USER=$OPERATOR
TEST_USER_KEY=$OPERATOR_KEY

# Mint费用检查
cast call $MYSBT "mintFee()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# Approve GToken for SBT mint fee
cast send $GTOKEN "approve(address,uint256)" $MYSBT 1000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $TEST_USER_KEY

# Mint SBT (假设community是xPNTs token地址)
cast send $MYSBT \
  "mintSBT(address)" \
  $XPNTS_TOKEN \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $TEST_USER_KEY \
  --gas-limit 600000
```

**验证SBT**:
```bash
cast call $MYSBT "balanceOf(address)(uint256)" $TEST_USER --rpc-url $SEPOLIA_RPC_URL
# 应该 > 0
```

#### 步骤3.3: 给用户200 xPNTs和测试USDC

```bash
# Mint 200 xPNTs给用户
cast send $XPNTS_TOKEN \
  "mint(address,uint256)" \
  $TEST_USER \
  200000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OPERATOR_KEY

# 部署测试USDC (如果没有)
# 或者使用Sepolia上的测试USDC
```

---

### 阶段4: 发起UserOperation（关键测试）

**⚠️ 重要**: 当前实现**不会从用户转账xPNTs**！

#### 预期行为 vs 实际行为

| 操作 | 预期行为 | 实际行为 |
|------|---------|---------|
| 验证SBT | ✅ 检查用户是否持有SBT | ✅ 已实现 |
| 检查aPNTs余额 | ✅ operator有足够aPNTs | ✅ 已实现 |
| 扣除aPNTs | ✅ 预扣maxCost | ✅ 已实现 |
| **用户支付xPNTs** | ✅ **转xPNTs到treasury** | ❌ **未实现** |
| 交易后退款 | ✅ 退还未使用aPNTs | ✅ 已实现 |

#### 步骤4.1: 准备UserOp脚本

**位置**: `script/v2/SendUserOp.s.sol` (需要创建)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

contract SendUserOp is Script {
    function run() external {
        // TODO: 构建UserOperation
        // - sender: TEST_USER
        // - callData: 转账0.9 USDC
        // - paymasterAndData: encode(PAYMASTER, OPERATOR)
    }
}
```

#### 步骤4.2: 使用Bundler发送UserOp

**当前问题**:
1. 需要运行本地bundler或使用Pimlico等服务
2. UserOp签名需要TEST_USER的Account Abstraction钱包
3. 测试环境复杂

**简化测试方案**:
```bash
# 直接调用validatePaymasterUserOp测试
# 模拟EntryPoint调用
```

---

### 阶段5: 验证结果

#### 检查operator账户变化

```bash
# 交易前aPNTs余额
BALANCE_BEFORE=1000e18

# 交易后
cast call $PAYMASTER "getOperatorAccount(address)" $OPERATOR --rpc-url $SEPOLIA_RPC_URL

# 预期:
# - aPNTsBalance: 减少~20-30 aPNTs
# - totalSpent: 增加~20-30 aPNTs
# - totalTxSponsored: +1
```

#### 检查用户xPNTs余额（当前不变）

```bash
cast call $XPNTS_TOKEN "balanceOf(address)(uint256)" $TEST_USER --rpc-url $SEPOLIA_RPC_URL

# ❌ 预期: 200 - 20 = 180 xPNTs
# ✅ 实际: 200 xPNTs (不变，因为未实现转账逻辑)
```

---

## 🔧 需要补充的功能

### 1. 添加Treasury地址

```solidity
// SuperPaymasterV2.sol
address public treasury;

function setTreasury(address _treasury) external onlyOwner {
    treasury = _treasury;
}
```

### 2. 在postOp中转账xPNTs

```solidity
function postOp(
    uint8 mode,
    bytes calldata context,
    uint256 actualGasCost
) external {
    // ... existing code ...

    if (mode <= 1) {
        // 计算xPNTs费用 (1:1汇率)
        uint256 xPNTsCost = actualGasCost; // 简化假设

        // 从用户转账xPNTs到treasury
        address xPNTsToken = accounts[operator].xPNTsToken;
        IxPNTsToken(xPNTsToken).transferFrom(user, treasury, xPNTsCost);

        // ... existing refund logic ...
    }
}
```

### 3. 添加汇率配置

```solidity
// 汇率: 1 aPNTs = X xPNTs (scaled by 1e18)
mapping(address => uint256) public exchangeRate; // operator => rate

function setExchangeRate(uint256 rate) external {
    exchangeRate[msg.sender] = rate;
}
```

---

## 📊 完整测试脚本

### 一键执行脚本

```bash
#!/bin/bash
# test-v2-full-flow.sh

set -e

source env/.env

XPNTS_TOKEN=0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a
OPERATOR=$OWNER2_ADDRESS
OPERATOR_KEY=$OWNER2_PRIVATE_KEY

echo "=== 阶段2: Operator充值aPNTs ==="

# Mint 10000 xPNTs
cast send $XPNTS_TOKEN "mint(address,uint256)" $OPERATOR 10000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OPERATOR_KEY

# Approve
cast send $XPNTS_TOKEN "approve(address,uint256)" $SUPER_PAYMASTER_V2_ADDRESS 1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OPERATOR_KEY

# Deposit
cast send $SUPER_PAYMASTER_V2_ADDRESS "depositAPNTs(uint256)" 1000000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OPERATOR_KEY

echo "=== 阶段3: 用户准备 ==="

# 检查SBT (已有)
SBT_BALANCE=$(cast call $MYSBT_ADDRESS "balanceOf(address)(uint256)" $OPERATOR --rpc-url $SEPOLIA_RPC_URL)
echo "SBT Balance: $SBT_BALANCE"

# Mint 200 xPNTs给用户
cast send $XPNTS_TOKEN "mint(address,uint256)" $OPERATOR 200000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OPERATOR_KEY

echo "=== 阶段4: 验证operator状态 ==="
cast call $SUPER_PAYMASTER_V2_ADDRESS "getOperatorAccount(address)" $OPERATOR --rpc-url $SEPOLIA_RPC_URL

echo "=== 测试准备完成 ==="
echo "❌ 注意: UserOp测试需要bundler环境，当前实现不会扣除用户xPNTs"
```

---

## 🎯 测试结论

### 当前可测试范围
1. ✅ Operator注册流程
2. ✅ aPNTs充值和余额管理
3. ✅ SBT验证逻辑
4. ⚠️ UserOp验证（需要bundler）

### 无法测试
1. ❌ 用户xPNTs支付（未实现）
2. ❌ Treasury接收（未配置）
3. ❌ 汇率转换（未实现）

### 建议
1. **先补充用户支付逻辑**再进行完整测试
2. 或者**先测试纯预充值模式**（operator免费赞助）
3. 明确v2.0的经济模型设计意图

---

**下一步**: 补充实现缺失功能或调整测试预期
