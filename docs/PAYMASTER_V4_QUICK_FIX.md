# PaymasterV4 快速修复指南

## ❌ 常见错误: AA33 reverted 0x8a7638fa

### 错误含义
这是 `PaymasterV4__InsufficientPNT()` 错误，表示：
1. PNT 余额不足（< 20 PNT）
2. **或者 PNT 没有授权给 PaymasterV4** ⚠️

### 快速诊断

```bash
# 设置你的账户地址
ACCOUNT="0x你的账户地址"

# 1. 检查 PNT 余额
cast call 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180 \
  "balanceOf(address)(uint256)" \
  $ACCOUNT \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# 2. 检查 PNT 授权 (最重要!)
cast call 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180 \
  "allowance(address,address)(uint256)" \
  $ACCOUNT \
  0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445 \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# 如果返回 0，说明没有授权！
```

## ✅ 解决方案

### 方案 1: 使用 Faucet 获取 PNT (推荐)

```bash
# 访问 faucet 获取 100 PNT
https://gastoken-faucet.vercel.app

# 输入你的账户地址，点击 "Mint 100 PNT"
```

### 方案 2: 直接授权 PNT

如果你是 **SimpleAccount** 或其他 AA 账户：

```bash
# 通过账户的 execute 函数授权
cast send $ACCOUNT \
  "execute(address,uint256,bytes)" \
  0xD14E87d8D8B69016Fcc08728c33799bD3F66F180 \
  0 \
  $(cast calldata "approve(address,uint256)" 0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445 $(cast max-uint)) \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $YOUR_PRIVATE_KEY
```

如果你是 **EOA** (普通地址)：

```bash
# 直接授权
cast send 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180 \
  "approve(address,uint256)" \
  0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445 \
  $(cast max-uint) \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $YOUR_PRIVATE_KEY
```

### 方案 3: 使用 Ethers.js 授权

```javascript
const { ethers } = require("ethers");

const ACCOUNT = "0x你的账户地址";
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";
const PRIVATE_KEY = "0x你的私钥";
const RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY";

async function approve() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);
  
  // SimpleAccount ABI
  const accountABI = [
    "function execute(address dest, uint256 value, bytes calldata func) external"
  ];
  
  // PNT Token ABI
  const pntABI = [
    "function approve(address spender, uint256 amount) external returns (bool)"
  ];
  
  const account = new ethers.Contract(ACCOUNT, accountABI, signer);
  const pnt = new ethers.Contract(PNT_TOKEN, pntABI, provider);
  
  // 构造 approve calldata
  const approveCalldata = pnt.interface.encodeFunctionData("approve", [
    PAYMASTER_V4,
    ethers.MaxUint256  // 授权无限额度
  ]);
  
  // 通过 SimpleAccount 执行
  const tx = await account.execute(PNT_TOKEN, 0, approveCalldata);
  console.log("Transaction hash:", tx.hash);
  
  const receipt = await tx.wait();
  console.log("✅ Approved! Block:", receipt.blockNumber);
}

approve().catch(console.error);
```

## 📋 完整检查清单

在提交 UserOperation 之前，确保：

- [ ] ✅ PNT 余额 ≥ 20 PNT
- [ ] ✅ PNT 已授权给 PaymasterV4 (allowance > 0)
- [ ] ✅ 如果账户已部署，有 1 个 SBT
- [ ] ✅ PaymasterAndData 格式正确 (72 bytes)
- [ ] ✅ 使用正确的 PaymasterV4 地址: `0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445`

## 🔧 验证授权成功

```bash
# 再次检查授权
cast call 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180 \
  "allowance(address,address)(uint256)" \
  $ACCOUNT \
  0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445 \
  --rpc-url $SEPOLIA_RPC_URL

# 应该返回一个很大的数字 (如果授权了 MaxUint256)
# 例如: 115792089237316195423570985008687907853269984665640564039457584007913129639935
```

## 🎯 其他常见错误

### AA33 reverted 0x6e8065c8 - AlreadyExists
**原因**: 尝试添加已存在的 token  
**解决**: Token 已经注册，无需再次添加

### AA33 reverted 0xadec25a0 - InvalidTokenBalance
**原因**: PNT 余额 < 20 PNT  
**解决**: 使用 faucet 获取更多 PNT

### AA33 reverted 0x... - NoValidSBT
**原因**: 已部署账户没有 SBT  
**解决**: 访问 https://gastoken-faucet.vercel.app mint SBT

## 📞 获取帮助

- **Faucet**: https://gastoken-faucet.vercel.app
- **文档**: https://github.com/AAStarCommunity/SuperPaymaster/blob/master/docs/STANDARD_4337_TRANSACTION_CONFIG.md
- **GitHub Issues**: https://github.com/AAStarCommunity/SuperPaymaster/issues

---

**更新时间**: 2025-10-07  
**PaymasterV4**: 0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445  
**Network**: Sepolia Testnet
