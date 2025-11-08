# SuperPaymaster 部署顺序规范

## 关键依赖关系

SuperPaymasterV2 合约的 `REGISTRY` 字段是 **immutable**（不可变），因此必须严格按照以下顺序部署：

## 正确的部署顺序

```
1. Registry v2.2.0
   ↓ (获取新地址)
2. SuperPaymasterV2 v2.0.1 (使用新 Registry 地址作为构造参数)
   ↓
3. 配置 Locker (将两个合约添加到 GTokenStaking 的授权 locker 列表)
```

## 依赖原因

### SuperPaymasterV2 → Registry
```solidity
// contracts/src/paymasters/v2/core/SuperPaymasterV2.sol:93
address public immutable REGISTRY;
```

SuperPaymasterV2 需要通过 Registry 获取：
- 社区元数据
- SBT 验证信息
- 运营商注册状态

### 部署脚本逻辑

```bash
# 1. 部署 Registry v2.2.0
forge script script/DeployRegistry_v2_2_0.s.sol:DeployRegistry_v2_2_0 \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv

# 2. 更新 .env 中的 REGISTRY 地址
REGISTRY=<new_registry_address>

# 3. 部署 SuperPaymasterV2 v2.0.1
forge script script/DeploySuperPaymasterV2_0_1.s.sol:DeploySuperPaymasterV2_0_1 \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv

# 4. 配置 Locker
forge script script/ConfigureLockers_v2.s.sol:ConfigureLockers_v2 \
  --sig 'run(address,address)' <superpaymaster_addr> <registry_addr> \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
```

## 历史记录

### 2025-11-08: 发现部署顺序问题
- **问题**: 先部署了 SuperPaymasterV2，使用了旧的 Registry 地址
- **原因**: 未意识到 REGISTRY 是 immutable
- **解决**: 先部署 Registry，再重新部署 SuperPaymasterV2

### v2 部署地址 (Sepolia) - 2025-11-08

✅ **成功部署（正确顺序）**:
1. **Registry v2.2.0**: `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75`
2. **SuperPaymasterV2 v2.0.1**: `0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC`

**依赖版本**:
- GToken: `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc`
- GTokenStaking v2.0.1: `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0`
- EntryPoint v0.7: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

❌ **失败部署（错误顺序 - 已废弃）**:
- SuperPaymasterV2 (第一次): `0x33A31d52db2ef2497e93226e0ed1B5d587D7D5e8` - 使用了旧 Registry
- SuperPaymasterV2 (第二次): `0x5675062cA5D98c791972eAC24eFa3BC3EBc096f3` - 使用了旧 Registry

## 注意事项

1. **永远不要**先部署 SuperPaymasterV2，因为它的 REGISTRY 地址无法更新
2. **部署前**先检查 .env 中的 REGISTRY 地址是否为最新版本
3. **测试网部署**失误成本较低，但生产环境部署必须严格按顺序执行
