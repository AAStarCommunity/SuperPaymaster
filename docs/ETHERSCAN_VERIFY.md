# Etherscan Contract Verification - MySBT v2.3

由于Foundry仍使用废弃的Etherscan API V1，需要通过网页界面手动验证合约。

## 📋 合约信息

**合约地址**: `0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8`

**网络**: Sepolia

**Etherscan URL**: https://sepolia.etherscan.io/address/0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8

## 🔧 验证步骤

### Step 1: 访问验证页面

访问: https://sepolia.etherscan.io/verifyContract?a=0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8

或者：
1. 访问合约页面: https://sepolia.etherscan.io/address/0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8
2. 点击 "Contract" 标签
3. 点击 "Verify and Publish"

### Step 2: 选择验证方式

选择: **Solidity (Standard JSON Input)**

点击 "Continue"

### Step 3: 填写合约详情

#### Compiler Details

- **Compiler Type**: Solidity (Standard-Json-Input)
- **Compiler Version**: `v0.8.28+commit.7893614a`
- **Open Source License**: MIT License (MIT)

#### Contract Details

- **Contract Address**: `0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8`
- **Contract Name**: `MySBT_v2_3`
- **Full Contract Path**: `src/paymasters/v2/tokens/MySBT_v2.3.sol:MySBT_v2_3`

#### Constructor Arguments (ABI-encoded)

```
000000000000000000000000868f843723a98c6eecc4bf0af3352c53d5004147000000000000000000000000d8235f8920815175bd46f76a2cb99e15e02ced680000000000000000000000003f7e822c7fd54dbf8df29c6ec48e08ce8acebeb3000000000000000000000000411bd567e46c0781248dbb6a9211891c032885e5
```

### Step 4: 上传Standard JSON Input

生成Standard JSON Input文件：

```bash
cd /Volumes/UltraDisk/Dev2/aastar/SuperPaymaster

# 生成标准JSON输入文件
forge verify-contract 0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8 \
  MySBT_v2_3 \
  --chain 11155111 \
  --show-standard-json-input > mysbt-v2.3-standard-json.json
```

然后：
1. 打开生成的 `mysbt-v2.3-standard-json.json`
2. 复制全部内容
3. 在Etherscan页面的 "Standard Input JSON" 文本框中粘贴

### Step 5: 提交验证

1. 填写验证码（CAPTCHA）
2. 点击 "Verify and Publish"
3. 等待验证完成（通常1-2分钟）

## ✅ 验证成功标志

验证成功后，你会看到：
- ✅ 绿色的 "Contract Source Code Verified" 标记
- 📄 完整的源代码显示
- 🔍 Read Contract 和 Write Contract 功能可用

## 🆘 如果验证失败

### 常见问题

#### 1. Constructor Arguments Mismatch

**解决方案**: 确认构造函数参数正确

验证参数：
```solidity
GTOKEN: 0x868F843723a98c6EECC4BF0aF3352C53d5004147
GTOKEN_STAKING: 0xD8235F8920815175BD46f76a2cb99e15E02cED68
REGISTRY: 0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3
DAO_MULTISIG: 0x411BD567E46C0781248dbB6a9211891C032885e5
```

#### 2. Compiler Version Mismatch

**解决方案**: 确认使用 `0.8.28`

检查：
```bash
grep "solc_version" foundry.toml
```

#### 3. Optimization Settings Mismatch

**解决方案**: 确认优化设置

From `foundry.toml`:
```toml
optimizer = true
optimizer_runs = 1000000
via_ir = true
```

## 🔄 替代方案：使用Sourcify

如果Etherscan验证失败，可以使用Sourcify：

```bash
# 安装Sourcify CLI
npm install -g @ethereum-sourcify/cli

# 验证合约
sourcify verify \
  --chain 11155111 \
  --address 0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8 \
  --path src/paymasters/v2/tokens/MySBT_v2.3.sol
```

## 📊 验证后可用功能

验证成功后，你可以：

1. **Read Contract** - 查询合约状态
   - VERSION()
   - VERSION_CODE()
   - paused()
   - MIN_ACTIVITY_INTERVAL()
   - 等等

2. **Write Contract** - 调用合约函数
   - mintOrAddMembership()
   - recordActivity()
   - bindCommunityNFT()
   - 等等

3. **The Graph Integration** - 子图可以自动获取ABI
   ```bash
   # 这样就可以正常工作了
   graph init mysbt-v-2-3
   ```

---

**合约**: MySBT v2.3 Security Enhanced
**地址**: 0xc1085841307d85d4a8dC973321Df2dF7c01cE5C8
**网络**: Sepolia
**状态**: 待验证
