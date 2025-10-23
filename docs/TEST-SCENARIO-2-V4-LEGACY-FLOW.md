# 测试场景2: Paymaster v4 传统流程测试

## 🎯 测试目标
验证SuperPaymaster v4（已部署）在v2部署后是否仍然正常工作

## 📋 已部署的v1.x合约信息

### 从env/.env读取
```bash
# v1.x系统
PAYMASTER_V4_ADDRESS=0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445
SUPER_PAYMASTER_REGISTRY_V1_2=0x838da93c815a6E45Aa50429529da9106C0621eF0
PNT_TOKEN_ADDRESS=0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
SBT_CONTRACT_ADDRESS=0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
```

---

## 🔍 前置检查

### 1. 确认v4合约架构

```bash
# 检查PaymasterV4是否存在
cast code $PAYMASTER_V4_ADDRESS --rpc-url $SEPOLIA_RPC_URL | head -c 100
# 应该返回bytecode (非0x)

# 检查Registry
cast code $SUPER_PAYMASTER_REGISTRY_V1_2 --rpc-url $SEPOLIA_RPC_URL | head -c 100

# 检查PNT Token
cast call $PNT_TOKEN_ADDRESS "name()(string)" --rpc-url $SEPOLIA_RPC_URL
cast call $PNT_TOKEN_ADDRESS "symbol()(string)" --rpc-url $SEPOLIA_RPC_URL

# 检查SBT
cast call $SBT_CONTRACT_ADDRESS "name()(string)" --rpc-url $SEPOLIA_RPC_URL
```

### 2. 检查测试账户状态

```bash
TEST_USER=$OWNER2_ADDRESS  # 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA
TEST_USER_KEY=$OWNER2_PRIVATE_KEY

# 检查PNT余额
cast call $PNT_TOKEN_ADDRESS "balanceOf(address)(uint256)" $TEST_USER --rpc-url $SEPOLIA_RPC_URL

# 检查SBT余额
cast call $SBT_CONTRACT_ADDRESS "balanceOf(address)(uint256)" $TEST_USER --rpc-url $SEPOLIA_RPC_URL

# 检查ETH余额
cast balance $TEST_USER --rpc-url $SEPOLIA_RPC_URL
```

---

## 📝 v4 Paymaster工作原理

### 架构对比

**v4 (PNT + SBT模式)**:
```
用户持有SBT + PNT → PaymasterV4验证 → 扣除PNT → 赞助交易
                                    ↓
                              PNT转到paymaster
```

**v2 (xPNTs + aPNTs模式)**:
```
用户持有SBT + xPNTs → SuperPaymasterV2验证 → 扣除operator的aPNTs → 赞助交易
                                           ↓
                                    (应该)扣除用户xPNTs
```

### 关键区别
| 特性 | v4 | v2 |
|------|----|----|
| 用户支付代币 | PNT | xPNTs (多种) |
| 赞助方式 | 用户直接支付PNT | Operator预充值aPNTs |
| SBT要求 | 统一SBT | 支持多种SBT |
| 去中心化 | 中心化paymaster | Operator竞争市场 |

---

## 🧪 测试步骤

### 阶段1: 准备测试用户（如果没有PNT和SBT）

#### 步骤1.1: Mint PNT给测试用户

```bash
# 检查PNT合约owner
OWNER=$(cast call $PNT_TOKEN_ADDRESS "owner()(address)" --rpc-url $SEPOLIA_RPC_URL)
echo "PNT Owner: $OWNER"

# 如果deployer是owner，mint PNT
if [ "$OWNER" == "$DEPLOYER_ADDRESS" ]; then
    cast send $PNT_TOKEN_ADDRESS \
      "mint(address,uint256)" \
      $TEST_USER \
      1000000000000000000000 \
      --rpc-url $SEPOLIA_RPC_URL \
      --private-key $PRIVATE_KEY
else
    echo "❌ Deployer不是PNT owner，无法mint"
fi
```

#### 步骤1.2: Mint SBT给测试用户

```bash
# 检查SBT是否可mint
cast call $SBT_CONTRACT_ADDRESS "balanceOf(address)(uint256)" $TEST_USER --rpc-url $SEPOLIA_RPC_URL

# 如果余额为0，尝试mint
# (需要知道SBT的mint函数签名)
```

---

### 阶段2: 部署测试USDT合约

```bash
# 创建简单的MockUSDT
cat > script/v4/DeployMockUSDT.s.sol << 'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../../src/mocks/MockERC20.sol";

contract DeployMockUSDT is Script {
    function run() external {
        vm.startBroadcast();

        MockERC20 usdt = new MockERC20("Test USDT", "USDT", 6);

        console.log("MockUSDT deployed:", address(usdt));

        vm.stopBroadcast();
    }
}
EOF

# 部署
forge script script/v4/DeployMockUSDT.s.sol:DeployMockUSDT \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --private-key $PRIVATE_KEY
```

---

### 阶段3: 构建和发送UserOperation

#### 问题: v4需要什么格式的UserOp？

v4应该遵循ERC-4337标准，需要：
1. **Account Abstraction钱包** (SmartAccount)
2. **Bundler服务**
3. **UserOp签名**

#### 简化测试方案: 直接调用paymaster函数

**如果v4有类似接口**:
```bash
# 检查v4的函数列表
cast interface $PAYMASTER_V4_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# 查找验证函数
# - validatePaymasterUserOp
# - sponsorUserOp
# - 或其他相关函数
```

---

### 阶段4: 使用Pimlico/Stackup测试（推荐）

#### 步骤4.1: 创建Account Abstraction钱包

使用`@alchemy/aa-sdk`或`permissionless`:

```typescript
// test-v4-userop.ts
import { createSmartAccountClient } from "permissionless";
import { sepolia } from "viem/chains";

const smartAccount = await createSmartAccountClient({
  chain: sepolia,
  transport: http(SEPOLIA_RPC_URL),
  // ... 配置
});

// 构建UserOp
const userOp = await smartAccount.prepareUserOperation({
  to: USDT_ADDRESS,
  value: 0n,
  data: encodeFunctionData({
    abi: erc20ABI,
    functionName: "transfer",
    args: [RECIPIENT, parseUnits("0.9", 6)]
  }),
  // 指定v4 paymaster
  paymaster: PAYMASTER_V4_ADDRESS,
  paymasterData: "0x..."
});

// 发送
const txHash = await smartAccount.sendUserOperation(userOp);
```

---

## 🔧 完整Shell脚本测试

```bash
#!/bin/bash
# test-v4-legacy.sh

set -e

source env/.env

echo "=== SuperPaymaster v4 传统流程测试 ==="

# 1. 检查v4合约存在
echo "检查PaymasterV4..."
V4_CODE=$(cast code $PAYMASTER_V4_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
if [ ${#V4_CODE} -lt 10 ]; then
    echo "❌ PaymasterV4未部署"
    exit 1
fi
echo "✅ PaymasterV4存在"

# 2. 检查用户PNT余额
echo "检查用户PNT余额..."
PNT_BALANCE=$(cast call $PNT_TOKEN_ADDRESS "balanceOf(address)(uint256)" $OWNER2_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
echo "PNT Balance: $PNT_BALANCE"

if [ "$PNT_BALANCE" == "0" ]; then
    echo "尝试mint PNT..."
    cast send $PNT_TOKEN_ADDRESS "mint(address,uint256)" $OWNER2_ADDRESS 1000000000000000000000 \
      --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY || echo "❌ Mint失败，可能权限不足"
fi

# 3. 检查SBT
echo "检查用户SBT..."
SBT_BALANCE=$(cast call $SBT_CONTRACT_ADDRESS "balanceOf(address)(uint256)" $OWNER2_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
echo "SBT Balance: $SBT_BALANCE"

if [ "$SBT_BALANCE" == "0" ]; then
    echo "❌ 用户没有SBT，需要手动mint"
fi

# 4. 检查v4函数
echo "检查PaymasterV4接口..."
cast interface $PAYMASTER_V4_ADDRESS --rpc-url $SEPOLIA_RPC_URL > /tmp/v4-interface.txt
cat /tmp/v4-interface.txt

echo ""
echo "=== v4状态检查完成 ==="
echo "⚠️ 完整UserOp测试需要bundler环境"
echo ""
echo "建议:"
echo "1. 使用Pimlico/Stackup bundler服务"
echo "2. 或使用Alchemy/Biconomy SDK"
echo "3. 确保用户有PNT和SBT"
```

---

## 🎯 预期结果

### 成功场景
1. ✅ 用户有足够PNT余额
2. ✅ 用户持有SBT
3. ✅ PaymasterV4验证通过
4. ✅ 扣除用户PNT
5. ✅ 交易被赞助执行
6. ✅ USDT转账成功

### 可能的错误

| 错误 | 原因 | 解决方案 |
|------|------|---------|
| InsufficientPNT | PNT余额不足 | Mint更多PNT |
| NoSBTFound | 用户没有SBT | Mint SBT |
| PaymasterRevert | Paymaster逻辑错误 | 检查v4代码 |
| UnauthorizedCaller | 不是EntryPoint调用 | 使用bundler |

---

## 📊 v4 vs v2 对比测试

### 相同用户，不同paymaster

```bash
# 场景A: 使用v4 paymaster
# - 用户: OWNER2
# - Paymaster: v4 (0xBC56D8...)
# - 支付: PNT
# - SBT: v1 SBT

# 场景B: 使用v2 paymaster
# - 用户: OWNER2
# - Paymaster: v2 (0xeC3f8d...)
# - 支付: xPNTs (理论上，实际未实现)
# - SBT: MySBT (v2)
```

### 测试矩阵

| 场景 | Paymaster | 用户代币 | SBT | 预期结果 |
|------|-----------|---------|-----|---------|
| 1 | v4 | PNT | v1 SBT | ✅ 成功 |
| 2 | v4 | xPNTs | v1 SBT | ❌ 不支持xPNTs |
| 3 | v2 | PNT | v2 MySBT | ❌ 不支持PNT |
| 4 | v2 | xPNTs | v2 MySBT | ⚠️ 成功（但不扣xPNTs）|

---

## 🔗 相关资源

- [ERC-4337 Spec](https://eips.ethereum.org/EIPS/eip-4337)
- [Pimlico Bundler](https://docs.pimlico.io/)
- [Stackup Bundler](https://docs.stackup.sh/)
- [Alchemy Account Kit](https://www.alchemy.com/account-kit)

---

## ✅ 测试检查清单

- [ ] v4合约存在且有code
- [ ] PNT合约可访问
- [ ] SBT合约可访问
- [ ] 测试用户有PNT余额
- [ ] 测试用户有SBT
- [ ] 部署测试USDT
- [ ] 搭建bundler环境
- [ ] 发送UserOp
- [ ] 验证交易成功
- [ ] 检查PNT余额变化

---

**结论**: v4和v2是**独立系统**，v4继续使用PNT+SBT，v2使用xPNTs+MySBT，互不影响。
