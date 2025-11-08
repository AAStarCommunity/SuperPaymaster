# 🚀 统一xPNTs架构部署指南

**版本**: v1.0
**日期**: 2025-10-30
**状态**: 准备部署Sepolia测试网

---

## ✅ 测试状态

| 类别 | 状态 | 详情 |
|------|------|------|
| 单元测试 | ✅ 149/149通过 | 包括PaymasterV4_1, xPNTs, aPNTs测试 |
| MySBT修复 | ✅ 完成 | verifyCommunityMembership逻辑修复 |
| 编译验证 | ✅ 通过 | 154文件编译成功，无错误 |
| 架构验证 | ✅ 完成 | 统一计算流程验证通过 |

---

## 📝 需要修改的文件清单

### 1. 前端代码（Registry）

#### `/Volumes/UltraDisk/Dev2/aastar/registry/src/pages/resources/GetXPNTs.tsx`

**修改前**:
```typescript
"function deployxPNTsToken(string memory name, string memory symbol, string memory communityName, string memory communityENS) external returns (address)",
```

**修改后**:
```typescript
"function deployxPNTsToken(string memory name, string memory symbol, string memory communityName, string memory communityENS, uint256 exchangeRate, address paymasterAOA) external returns (address)",
```

**调用修改**:
```typescript
// 修改前
const tx = await factory.deployxPNTsToken(
  tokenName,
  tokenSymbol,
  communityName,
  communityENS
);

// 修改后
const tx = await factory.deployxPNTsToken(
  tokenName,
  tokenSymbol,
  communityName,
  communityENS,
  ethers.parseEther("1"),  // exchangeRate: 1:1 默认
  ethers.ZeroAddress       // paymasterAOA: 使用SuperPaymaster V2（AOA+模式）
);
```

#### `/Volumes/UltraDisk/Dev2/aastar/registry/src/pages/operator/deploy-v2/steps/Step4_DeployResources.tsx`

**相同修改**：
- 更新ABI定义（6参数）
- 更新函数调用（添加exchangeRate和paymasterAOA参数）

---

### 2. 部署脚本更新

#### PaymasterV4部署脚本（待创建）

```solidity
// script/DeployPaymasterV4_AOA.s.sol
contract DeployPaymasterV4_AOA is Script {
    function run() external {
        // ... setup ...

        // ✅ 新增：xPNTsFactory地址
        address xpntsFactory = vm.envAddress("XPNTS_FACTORY_ADDRESS");

        PaymasterV4_1 paymaster = new PaymasterV4_1(
            ENTRYPOINT_V07,
            deployer,
            treasury,
            ETH_USD_PRICE_FEED,
            SERVICE_FEE_RATE,
            MAX_GAS_COST_CAP,
            xpntsFactory,      // ← 新增参数
            initialSBT,
            initialGasToken,
            registry
        );
    }
}
```

---

### 3. Launch Paymaster Repo更新

**位置**: 未知（需要用户提供）

**需要更新**:
1. 使用xPNTs合约而不是GasTokenV2
2. 调用deployxPNTsToken时传入6个参数
3. PaymasterV4部署时传入xpntsFactory地址

---

## 🔧 部署步骤

### Sepolia测试网部署

#### Step 1: 部署SuperPaymaster V2系统

```bash
# 设置环境变量
export PRIVATE_KEY="0x..."
export GTOKEN_ADDRESS="0x..."
export RPC_URL="https://sepolia.infura.io/v3/..."

# 运行部署脚本
forge script script/DeploySuperPaymasterV2.s.sol:DeploySuperPaymasterV2 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

**记录部署地址**:
- xPNTsFactory: `0x...`
- SuperPaymaster V2: `0x...`
- Registry: `0x...`
- MySBT: `0x...`

#### Step 2: 部署PaymasterV4 (AOA模式)

```bash
# 设置xPNTsFactory地址
export XPNTS_FACTORY_ADDRESS="0x..."  # 从Step 1获取

# 运行AOA部署脚本
forge script script/DeployPaymasterV4_AOA.s.sol:DeployPaymasterV4_AOA \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

#### Step 3: 部署xPNTs Token

**方式1: 通过前端（推荐）**
1. 打开Registry前端
2. 进入"Get xPNTs"页面
3. 填写：
   - Token Name: "My Community Points"
   - Token Symbol: "xMC"
   - Community Name: "My Community"
   - Community ENS: "mycommunity.eth"
   - Exchange Rate: 1 (默认1:1)
   - Paymaster Address: `0x...` (AOA模式) 或 `0x0` (AOA+模式)

**方式2: 通过脚本**
```javascript
const factory = new ethers.Contract(XPNTS_FACTORY, ABI, signer);
const tx = await factory.deployxPNTsToken(
  "My Community Points",
  "xMC",
  "My Community",
  "mycommunity.eth",
  ethers.parseEther("1"),  // 1:1 exchangeRate
  paymasterAddress         // AOA模式的paymaster地址
);
```

---

## 🧪 端到端测试流程

### 测试1: AOA+模式（使用SuperPaymaster V2）

```bash
# 1. 部署xPNTs (paymasterAOA = 0x0)
node scripts/deploy-xpnts-aoa-plus.js

# 2. 运营者注册到SuperPaymaster
node script/v2/Step2_OperatorRegister.s.sol

# 3. 用户存款aPNTs
node script/v2/TestV2FullFlow.s.sol

# 4. 测试UserOp
node scripts/test-userOp-with-superpaymaster.js
```

### 测试2: AOA模式（使用PaymasterV4）

```bash
# 1. 部署PaymasterV4
forge script script/DeployPaymasterV4_AOA.s.sol --broadcast

# 2. 部署xPNTs (paymasterAOA = PaymasterV4地址)
node scripts/deploy-xpnts-aoa.js

# 3. 添加xPNTs到PaymasterV4
node scripts/add-xpnts-to-paymaster.js

# 4. 测试UserOp
node scripts/test-paymaster-v4-final.js
```

---

## 📊 验证清单

### 架构验证

- [x] xPNTsFactory.aPNTsPriceUSD初始值为0.02e18
- [x] xPNTsFactory.getAPNTsPrice()返回0.02e18
- [x] xPNTsFactory.updateAPNTsPrice()仅owner可调用
- [x] xPNTsToken.exchangeRate初始值为1e18
- [x] xPNTsToken.updateExchangeRate()仅owner可调用
- [x] PaymasterV4使用统一计算流程
- [x] 安全模型：运营者只审批自己的paymaster

### 功能验证

- [ ] xPNTsFactory部署到Sepolia
- [ ] SuperPaymaster V2部署到Sepolia
- [ ] PaymasterV4部署到Sepolia（AOA模式）
- [ ] xPNTs部署成功（AOA+模式）
- [ ] xPNTs部署成功（AOA模式）
- [ ] aPNTs价格动态更新功能
- [ ] exchangeRate更新功能
- [ ] UserOp执行成功（AOA+模式）
- [ ] UserOp执行成功（AOA模式）

### 前端验证

- [ ] Registry前端部署xPNTs成功
- [ ] 显示正确的exchangeRate
- [ ] 显示正确的paymasterAOA地址
- [ ] 交易确认显示正确信息

---

## 🔍 常见问题

### Q1: exchangeRate应该设置为多少？

**A**: 默认为1e18（1:1比例）。如果社区希望：
- 1 aPNTs = 2 xPNTs → exchangeRate = 2e18
- 1 aPNTs = 0.5 xPNTs → exchangeRate = 0.5e18

### Q2: AOA模式和AOA+模式有什么区别？

**A**:
- **AOA模式**: 运营者部署自己的PaymasterV4，完全控制
  - paymasterAOA = PaymasterV4地址
  - 自定义service fee
  - 独立treasury
- **AOA+模式**: 使用共享的SuperPaymaster V2
  - paymasterAOA = 0x0
  - 统一service fee
  - 共享treasury

### Q3: 如何更新aPNTs价格？

**A**:
```solidity
// 仅xPNTsFactory owner可调用
factory.updateAPNTsPrice(0.03e18);  // 更新为$0.03
```

### Q4: 工厂是否可以转账用户的xPNTs？

**A**: 不可以。修改后的架构中，工厂不再拥有通用转账权限。只有：
- SuperPaymaster V2 (AOA+模式)
- 运营者指定的PaymasterV4 (AOA模式)

---

## 📞 支持

**技术问题**: https://github.com/aastar-community/SuperPaymaster/issues
**文档**: https://docs.aastar.community
**Discord**: https://discord.gg/aastar

---

**部署完成时间**: 待定
**验证者**: Claude Code
**状态**: ✅ 准备部署
