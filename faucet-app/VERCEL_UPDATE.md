# Vercel 环境变量更新说明

## GasTokenV2 部署后需要更新的 Vercel 环境变量

### 变更内容

将 PNT Token 从 V1 更新到 V2 (GasTokenV2):

- **旧地址**: `0x090e34709a592210158aa49a969e4a04e3a29ebd` (PNT V1)
- **新地址**: `0xD14E87d8D8B69016Fcc08728c33799bD3F66F180` (PNTv2)

### 更新步骤

#### 方式 1: 通过 Vercel Dashboard (推荐)

1. 访问 Vercel Dashboard: https://vercel.com/dashboard
2. 选择项目: `gastoken-faucet`
3. 进入 **Settings** → **Environment Variables**
4. 找到 `PNT_TOKEN_ADDRESS` 变量
5. 点击 **Edit**
6. 修改值为: `0xD14E87d8D8B69016Fcc08728c33799bD3F66F180`
7. 点击 **Save**
8. 触发重新部署:
   - 进入 **Deployments** 标签
   - 点击最新部署的 **...** 菜单
   - 选择 **Redeploy**

#### 方式 2: 通过 Vercel CLI

```bash
# 安装 Vercel CLI (如果还没有)
npm i -g vercel

# 登录
vercel login

# 进入项目目录
cd faucet-app

# 更新环境变量
vercel env rm PNT_TOKEN_ADDRESS production
vercel env add PNT_TOKEN_ADDRESS production
# 输入新值: 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180

# 重新部署
vercel --prod
```

### 验证更新

#### 1. 检查环境变量
```bash
vercel env ls
```

应该看到:
```
PNT_TOKEN_ADDRESS    Production    0xD14E...F180
```

#### 2. 测试 Mint 功能

访问: https://gastoken-faucet.vercel.app

1. 输入测试地址
2. 点击 "Mint 100 PNT"
3. 检查交易:
   - 应该 mint 的是 PNTv2 (0xD14E87d8D8B69016Fcc08728c33799bD3F66F180)
   - 交易成功后，用户应该自动有 MAX approval 到 PaymasterV4

#### 3. 验证 Etherscan

查看页面底部的合约地址链接:
- 应该显示: `PNT: 0xD14E...F180 (PNTv2)`
- 点击链接应该跳转到新的 GasTokenV2 合约

### 完整的环境变量列表

更新后的完整配置:

```env
# RPC URL
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/...

# Owner Private Key (用于支付 gas)
SEPOLIA_PRIVATE_KEY=0x...

# Contract Addresses
SBT_CONTRACT_ADDRESS=0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
PNT_TOKEN_ADDRESS=0xD14E87d8D8B69016Fcc08728c33799bD3F66F180  # ← 已更新
```

### 相关合约信息

#### GasTokenV2 (PNTv2)
- **地址**: `0xD14E87d8D8B69016Fcc08728c33799bD3F66F180`
- **Factory**: `0x6720Dc8ce5021bC6F3F126054556b5d3C125101F`
- **Paymaster**: `0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445` (PaymasterV4)
- **特性**: 自动 approve 到 Paymaster, 可更新 Paymaster 地址

#### 其他合约
- **SBT**: `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f`
- **PaymasterV4**: `0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445`

### Etherscan 链接

- [GasTokenV2 (PNTv2)](https://sepolia.etherscan.io/address/0xD14E87d8D8B69016Fcc08728c33799bD3F66F180)
- [GasTokenFactoryV2](https://sepolia.etherscan.io/address/0x6720Dc8ce5021bC6F3F126054556b5d3C125101F)
- [PaymasterV4](https://sepolia.etherscan.io/address/0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445)
- [MySBT](https://sepolia.etherscan.io/address/0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f)

### 常见问题

#### Q: 更新后旧的 PNT V1 还能用吗?
A: 可以,但需要手动 approve 到 PaymasterV4。新的 PNTv2 有自动 approve 功能。

#### Q: 用户已经有的 PNT V1 怎么办?
A: 可以继续使用,但建议从 faucet 领取新的 PNTv2 来体验自动 approve 功能。

#### Q: 更新后需要重新注册到 PaymasterV4 吗?
A: 已完成注册。PNTv2 已经在 PaymasterV4 中注册为支持的 GasToken。

### 回滚方案

如果需要回滚到旧版本:

```bash
# 回滚环境变量
vercel env rm PNT_TOKEN_ADDRESS production
vercel env add PNT_TOKEN_ADDRESS production
# 输入旧值: 0x090e34709a592210158aa49a969e4a04e3a29ebd

# 重新部署
vercel --prod
```

### 部署日志

- **部署时间**: 2025-10-07
- **GasTokenV2 部署 TX**: [查看 broadcast/DeployGasTokenV2.s.sol/11155111/run-latest.json]
- **注册 TX**: `0x72761e65a871e5709807bfbb1799f5fb4462376a0da832fad0bd2221ed1ee955`
