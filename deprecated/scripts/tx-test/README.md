# ERC-4337 交易测试脚本

基于 @aastar/shared-config v0.2.10 的完整测试流程

## 📁 目录结构

```
scripts/tx-test/
├── README.md                           # 本文件
├── 0-check-deployed-contracts.js       # ✅ 前置检查脚本
├── 1-create-simple-accounts.js         # 🚧 创建 Simple Account
├── 2-setup-communities-and-xpnts.js    # 🚧 设置社区和 xPNTs
├── 3-mint-assets-to-accounts.js        # 🚧 Mint 资产
├── 4-test-aoa-paymaster.js             # 🚧 AOA 模式测试
├── 5-test-aoa-plus-paymaster.js        # 🚧 AOA+ 模式测试
└── utils/
    ├── config.js                       # ✅ 配置和合约地址
    ├── logger.js                       # ✅ 日志工具
    └── contract-checker.js             # ✅ 合约检查工具
```

## 🚀 使用方法

### 前提条件

1. 配置 `.env` 文件：
   ```bash
   SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
   DEPLOYER_PRIVATE_KEY="0x..."
   OWNER2_PRIVATE_KEY="0x..."
   ```

2. 安装依赖：
   ```bash
   pnpm install
   ```

### 运行流程

#### 步骤 0：前置检查
```bash
node scripts/tx-test/0-check-deployed-contracts.js
```

检查项：
- ✅ 核心合约部署状态
- ✅ GToken 和 GTokenStaking 绑定
- ✅ GTokenStaking Locker 配置
- ✅ SuperPaymasterV2 参数配置
- ✅ xPNTs autoApprovedSpenders
- ✅ Simple Account 部署状态
- ✅ 测试账户资产余额
- ✅ 运营方注册状态

#### 步骤 1：创建 Simple Account（如需要）
```bash
node scripts/tx-test/1-create-simple-accounts.js
```

功能：
- 使用 SimpleAccountFactory 创建 Account A/B/C
- 验证部署和 owner 配置
- 如果已存在，则跳过创建

#### 步骤 2：设置社区和 xPNTs（如需要）
```bash
node scripts/tx-test/2-setup-communities-and-xpnts.js
```

功能：
- 注册 AAStar 和 BuilderDAO 社区到 Registry
- 使用 xPNTsFactory 部署 aPNTs 和 bPNTs
- 配置 autoApprovedSpenders
- 如果已存在，则验证配置

#### 步骤 3：Mint 资产
```bash
node scripts/tx-test/3-mint-assets-to-accounts.js
```

功能：
- Mint 1000 GToken 给测试账户
- Mint 1 个 SBT 给测试账户
- Mint 1000 aPNTs 给测试账户
- Mint 1000 bPNTs 给测试账户

#### 步骤 4：测试 AOA 模式
```bash
node scripts/tx-test/4-test-aoa-paymaster.js
```

测试场景：
- Account A 向 B 转账 0.5 bPNTs
- 使用 PaymasterV4.1 支付 gas
- 验证余额变化和 gasless 特性

#### 步骤 5：测试 AOA+ 模式
```bash
node scripts/tx-test/5-test-aoa-plus-paymaster.js
```

测试场景：
- Account A 向 B 转账 0.5 aPNTs
- 使用 SuperPaymasterV2 支付 gas
- 验证余额变化、operator aPNTs 消费和 gasless 特性

## 🔑 核心特性

### 智能检查机制

所有脚本都会先检查现有状态：
- ✅ 如果合约已部署，则验证配置
- ✅ 如果账户已创建，则检查资产
- ✅ 避免重复创建，节省 gas

### 完整的日志输出

使用彩色日志输出：
- 🔵 INFO - 信息提示
- ✅ SUCCESS - 成功操作
- ⚠️  WARNING - 警告信息
- ❌ ERROR - 错误信息
- 📊 TABLE - 表格数据

### 错误处理

- 所有操作都有 try-catch 包裹
- 详细的错误信息输出
- 提供下一步操作建议

## 📋 合约地址（v0.2.10）

| 合约 | 地址 |
|------|------|
| SuperPaymasterV2 | `0x95B20d8FdF173a1190ff71e41024991B2c5e58eF` |
| PaymasterV4.1 | `0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38` |
| Registry | `0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A` |
| GToken | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | `0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa` |
| MySBT | `0x73E635Fc9eD362b7061495372B6eDFF511D9E18F` |
| xPNTsFactory | `0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd` |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |

## 📝 测试账户

| 账户 | 地址 | 类型 |
|------|------|------|
| Deployer | `0x411BD567E46C0781248dbB6a9211891C032885e5` | EOA |
| OWNER2 | `0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA` | EOA |
| Account A | `0xf0e96d5fDCCCA9B67929600615EB04e5f11D4584` | Simple Account |
| Account B | `0x57b2e6f08399c276b2c1595825219d29990d0921` | Simple Account |
| Account C | `0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce` | Simple Account |

## 🐛 故障排查

### 问题 1：RPC_URL 未配置
```
Error: Missing required private keys in .env file
```
**解决**：在项目根目录创建 `.env` 文件并配置必要的环境变量

### 问题 2：ABI 文件未找到
```
Error: Cannot find module '../../../out/GToken.sol/GToken.json'
```
**解决**：运行 `forge build` 编译合约生成 ABI

### 问题 3：合约未部署
```
Error: call revert exception
```
**解决**：检查 shared-config 中的合约地址是否正确部署

## 📚 参考文档

- [完整测试流程文档](../../docs/transaction-test-with-AOA-v2.md)
- [@aastar/shared-config](https://www.npmjs.com/package/@aastar/shared-config)
- [ERC-4337 官方文档](https://eips.ethereum.org/EIPS/eip-4337)

---

**版本**：v2.0
**最后更新**：2025-11-02
**基于合约版本**：@aastar/shared-config v0.2.10
