# PaymasterV4_1i 快速部署命令

## 🚀 一键部署脚本

### 1. 部署实现合约 (使用 Blockscout 验证)

```bash
# 加载环境变量
source .env

# 部署 + Blockscout 验证（会自动同步到 Etherscan）
forge script script/DeployPaymasterV4_1i.s.sol:DeployPaymasterV4_1i \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://eth-sepolia.blockscout.com/api/ \
  -vvvv
```

**优势**：
- ✅ Blockscout 验证成功后自动同步到 Etherscan
- ✅ 无需 Etherscan API Key
- ✅ 更快的验证速度

**预期输出**：
```
=== Deployment Successful ===
Implementation: 0x...
Version: PaymasterV4.1i-v1.0.0

✅ Blockscout verification: Pass
📍 Etherscan URL: https://sepolia.etherscan.io/address/0x...
```

### 2. 保存实现地址

```bash
# 从输出复制地址
export V4_1i_IMPLEMENTATION="0x..."
echo "V4_1i_IMPLEMENTATION=$V4_1i_IMPLEMENTATION" >> .env
```

---

## 🏭 注册到 Factory

### 方式 A: 直接调用（如果你是 owner）

```bash
source .env

cast send $PAYMASTER_FACTORY \
  "addImplementation(string,address)" \
  "v4.1i" \
  $V4_1i_IMPLEMENTATION \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 方式 B: Safe 多签（推荐生产环境）

**创建 Safe 交易**：
```
To: 0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920
Value: 0
Data: 调用 addImplementation(string,address)
  - version: "v4.1i"
  - implementation: 0x... (你的实现地址)
```

**验证注册**：
```bash
cast call $PAYMASTER_FACTORY \
  "implementations(string)(address)" \
  "v4.1i" \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## 🧪 测试 Factory 部署

```bash
source .env

forge script script/TestPaymasterV4_1i_Factory.s.sol:TestPaymasterV4_1i_Factory \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

**验证输出**：
```
✅ Paymaster Address: 0x...
✅ Version: PaymasterV4.1i-v1.0.0
✅ Owner: 0x411BD567E46C0781248dbB6a9211891C032885e5
✅ EntryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
✅ All Verifications Passed
```

---

## 💰 配置 Paymaster

### 充值 ETH

```bash
source .env
export PAYMASTER_PROXY="0x..."  # 从测试输出复制

# 1. 充值 Paymaster
cast send $PAYMASTER_PROXY \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 2. Deposit 到 EntryPoint
cast send $PAYMASTER_PROXY \
  "depositToEntryPoint()()" \
  --value 0.05ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 验证状态

```bash
# EntryPoint deposit
cast call $PAYMASTER_PROXY "getDeposit()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# Owner
cast call $PAYMASTER_PROXY "owner()(address)" --rpc-url $SEPOLIA_RPC_URL

# Paused
cast call $PAYMASTER_PROXY "paused()(bool)" --rpc-url $SEPOLIA_RPC_URL

# Registry
cast call $PAYMASTER_PROXY "isRegistrySet()(bool)" --rpc-url $SEPOLIA_RPC_URL
```

---

## 🔐 (可选) 转让给 Safe

```bash
source .env
export SAFE_ADDRESS="0x..."

# 转让 Paymaster ownership
cast send $PAYMASTER_PROXY \
  "transferOwnership(address)" \
  $SAFE_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 验证
cast call $PAYMASTER_PROXY "owner()(address)" --rpc-url $SEPOLIA_RPC_URL
```

---

## 📊 快速检查清单

```bash
# 一键检查所有状态
echo "=== PaymasterV4_1i Status ==="
echo "Implementation:" $(cast call $PAYMASTER_FACTORY "implementations(string)(address)" "v4.1i" --rpc-url $SEPOLIA_RPC_URL)
echo "Proxy:" $PAYMASTER_PROXY
echo "Version:" $(cast call $PAYMASTER_PROXY "version()(string)" --rpc-url $SEPOLIA_RPC_URL)
echo "Owner:" $(cast call $PAYMASTER_PROXY "owner()(address)" --rpc-url $SEPOLIA_RPC_URL)
echo "Deposit:" $(cast call $PAYMASTER_PROXY "getDeposit()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
echo "Paused:" $(cast call $PAYMASTER_PROXY "paused()(bool)" --rpc-url $SEPOLIA_RPC_URL)
echo "Registry:" $(cast call $PAYMASTER_PROXY "isRegistrySet()(bool)" --rpc-url $SEPOLIA_RPC_URL)
```

---

## 🔗 相关链接

- Factory: https://sepolia.etherscan.io/address/0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920
- Registry: https://sepolia.etherscan.io/address/0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A
- EntryPoint v0.7: https://sepolia.etherscan.io/address/0x0000000071727De22E5E9d8BAf0edAc6f37da032
