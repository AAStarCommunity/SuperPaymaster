# SuperPaymaster V3 修复部署指南

## 问题诊断

### 根本原因
之前的交易失败原因：`PostOpReverted` - Settlement 合约使用了错误的 Registry 地址

- ❌ 错误地址：`0x4e6748C62d8EBE8a8b71736EAABBB79575A79575` (不存在)
- ✅ 正确地址：`0x4e67678AF714f6B5A8882C2e5a78B15B08a79575` (已存在)

### 旧合约地址（需要废弃）
- Settlement (旧): `0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5`
- PaymasterV3 (旧): `0x1568da4ea1E2C34255218b6DaBb2458b57B35805`

## 修复步骤

### 1. 部署新的 Settlement 合约

使用 Remix IDE 或其他工具，用以下参数部署 `Settlement.sol`：

```solidity
// Constructor 参数
initialOwner: 0x411BD567E46C0781248dbB6a9211891C032885e5
registryAddress: 0x4e67678AF714f6B5A8882C2e5a78B15B08a79575  // ✅ 正确的 Registry
initialThreshold: 100000000000000000000  // 100 PNT
```

**或使用 cast 命令**（如果工具正常）：
```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster-Contract

# 部署 Settlement
forge create src/v3/Settlement.sol:Settlement \
  --rpc-url "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N" \
  --private-key "0x2717524c39f8b8ab74c902dc712e590fee36993774119c1e06d31daa4b0fbc81" \
  --constructor-args "0x411BD567E46C0781248dbB6a9211891C032885e5" "0x4e67678AF714f6B5A8882C2e5a78B15B08a79575" "100000000000000000000" \
  --legacy \
  --broadcast \
  --skip-simulation
```

### 2. 部署新的 PaymasterV3 合约

使用新 Settlement 地址部署 PaymasterV3：

```solidity
// Constructor 参数
entryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
owner: 0x411BD567E46C0781248dbB6a9211891C032885e5
sbtContract: 0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
gasToken: 0x090e34709a592210158aa49a969e4a04e3a29ebd
settlement: [新部署的 Settlement 地址]
minTokenBalance: 10000000000000000000  // 10 PNT
```

**或使用命令**：
```bash
# 替换 <NEW_SETTLEMENT> 为步骤1部署的地址
forge create src/v3/PaymasterV3.sol:PaymasterV3 \
  --rpc-url "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N" \
  --private-key "0x2717524c39f8b8ab74c902dc712e590fee36993774119c1e06d31daa4b0fbc81" \
  --constructor-args \
    "0x0000000071727De22E5E9d8BAf0edAc6f37da032" \
    "0x411BD567E46C0781248dbB6a9211891C032885e5" \
    "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f" \
    "0x090e34709a592210158aa49a969e4a04e3a29ebd" \
    "<NEW_SETTLEMENT>" \
    "10000000000000000000" \
  --legacy \
  --broadcast \
  --skip-simulation
```

### 3. 在 Registry 中注册新 PaymasterV3

```bash
# 替换 <NEW_PAYMASTER> 为步骤2部署的地址
cast send 0x4e67678AF714f6B5A8882C2e5a78B15B08a79575 \
  "registerPaymaster(address,string,uint256)" \
  "<NEW_PAYMASTER>" \
  "SuperPaymasterV3" \
  150 \
  --rpc-url "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N" \
  --private-key "0x2717524c39f8b8ab74c902dc712e590fee36993774119c1e06d31daa4b0fbc81" \
  --legacy
```

### 4. 为 PaymasterV3 充值 ETH

```bash
cast send "<NEW_PAYMASTER>" \
  --value 0.1ether \
  --rpc-url "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N" \
  --private-key "0x2717524c39f8b8ab74c902dc712e590fee36993774119c1e06d31daa4b0fbc81" \
  --legacy
```

### 5. 更新 .env.v3 配置

```bash
# 编辑 .env.v3 文件，更新以下变量：
SETTLEMENT_ADDRESS="<NEW_SETTLEMENT>"
PAYMASTER_V3_ADDRESS="<NEW_PAYMASTER>"
PAYMASTER_ADDRESS="<NEW_PAYMASTER>"
```

### 6. 验证部署

```bash
# 验证 Settlement 的 registry 地址是否正确
cast call <NEW_SETTLEMENT> "registry()(address)" \
  --rpc-url "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N"
# 应该返回: 0x4e67678AF714f6B5A8882C2e5a78B15B08a79575

# 验证 PaymasterV3 是否已注册
cast call 0x4e67678AF714f6B5A8882C2e5a78B15B08a79575 \
  "isPaymasterActive(address)(bool)" \
  "<NEW_PAYMASTER>" \
  --rpc-url "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N"
# 应该返回: true

# 验证 PaymasterV3 的 ETH 余额
cast balance "<NEW_PAYMASTER>" \
  --rpc-url "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N"
# 应该 > 0
```

### 7. 重新测试交易

使用之前的测试脚本：
```bash
cd /Users/jason/Dev/mycelium/my-exploration/design/SuperPaymasterV3
node test-e2e.js
```

## 预期结果

修复后，交易应该包含以下事件：
1. ✅ GasConsumed (PaymasterV3)
2. ✅ FeeRecorded (Settlement) - 新增
3. ✅ Transfer (PNT Token) - 之前缺失的！
4. ✅ UserOperationEvent (EntryPoint)

## 故障排除

如果 `forge` 命令仍然无法广播：

1. **使用 Remix IDE**：
   - 访问 https://remix.ethereum.org
   - 上传 `Settlement.sol` 和 `PaymasterV3.sol`
   - 编译并手动部署

2. **使用 Hardhat**：
   ```bash
   npx hardhat run scripts/deploy-v3.js --network sepolia
   ```

3. **检查 Foundry 版本**：
   ```bash
   forge --version
   # 如果版本过旧，更新：
   foundryup
   ```

## 关键修复点

部署脚本 `script/v3-deploy-simple.s.sol` 已修复：

**修改前**（硬编码错误地址）：
```solidity
address constant SUPERPAYMASTER_REGISTRY = 0x4e6748C62d8EBE8a8b71736EAABBB79575A79575;
```

**修改后**（从环境变量读取）：
```solidity
address registry = vm.envAddress("SUPER_PAYMASTER"); // 从 .env.v3 读取
```

这确保未来部署始终使用正确的 Registry 地址。
