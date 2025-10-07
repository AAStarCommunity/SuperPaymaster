# SuperPaymaster Frontend Deployment Plan - Vercel

## 📋 部署概览

**目标平台**: Vercel  
**项目类型**: Next.js 14 App Router  
**预估时间**: 10-15分钟  
**域名**: `superpaymaster.vercel.app` (免费) / 自定义域名 (可选)

## 🚀 Vercel 部署步骤

### 1. 准备工作 (2分钟)

#### 检查项目状态
```bash
# 确保前端可以正常启动
cd frontend
npm run build  # 检查构建是否成功
npm run dev     # 确保本地运行正常
```

#### 环境变量准备
创建 `frontend/.env.production` 文件：
```env
# 已部署的SuperPaymaster合约地址
NEXT_PUBLIC_SUPER_PAYMASTER_V6="0x..."
NEXT_PUBLIC_SUPER_PAYMASTER_V7="0x..."
NEXT_PUBLIC_SUPER_PAYMASTER_V8="0x..."

# RPC节点 (使用免费的公共RPC)
NEXT_PUBLIC_SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/demo"
NEXT_PUBLIC_MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/demo"

# WalletConnect项目ID (可选，如果需要更多钱包支持)
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID="your_project_id"
```

### 2. Vercel账户设置 (1分钟)

1. 访问 [vercel.com](https://vercel.com)
2. 使用GitHub账户登录
3. 授权Vercel访问GitHub仓库

### 3. 项目导入和配置 (3分钟)

#### 导入项目
1. 点击 "New Project"
2. 选择 `SuperPaymaster-Contract` 仓库
3. **重要**: 设置 Root Directory 为 `frontend`
4. Framework Preset 会自动检测为 Next.js

#### 构建设置
```json
{
  "buildCommand": "npm run build",
  "outputDirectory": ".next",
  "installCommand": "npm install",
  "devCommand": "npm run dev"
}
```

### 4. 环境变量配置 (3分钟)

在Vercel项目设置中添加：

| Name | Value | Environment |
|------|-------|-------------|
| `NEXT_PUBLIC_SUPER_PAYMASTER_V6` | `0x你的V6合约地址` | Production, Preview |
| `NEXT_PUBLIC_SUPER_PAYMASTER_V7` | `0x你的V7合约地址` | Production, Preview |
| `NEXT_PUBLIC_SUPER_PAYMASTER_V8` | `0x你的V8合约地址` | Production, Preview |
| `NEXT_PUBLIC_SEPOLIA_RPC_URL` | `https://eth-sepolia.g.alchemy.com/v2/demo` | All |

### 5. 首次部署 (2分钟)

1. 点击 "Deploy" 开始构建
2. 等待构建完成 (~90秒)
3. 获得部署URL: `https://your-project-name.vercel.app`

### 6. 域名配置 (可选，5分钟)

#### 免费Vercel域名
- 自动获得: `superpaymaster-dashboard.vercel.app`
- 可在项目设置中自定义前缀

#### 自定义域名 (如果需要)
1. 项目设置 → Domains
2. 添加域名: `app.superpaymaster.xyz`
3. 配置DNS记录:
   ```
   Type: CNAME
   Name: app
   Value: cname.vercel-dns.com
   ```

## 🔧 优化配置

### Next.js配置优化
创建 `frontend/next.config.js`:
```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
  // 静态导出优化
  output: 'export',
  trailingSlash: true,
  
  // 图片优化
  images: {
    unoptimized: true
  },
  
  // 环境变量
  env: {
    CUSTOM_KEY: process.env.CUSTOM_KEY,
  },
  
  // 构建优化
  swcMinify: true,
  
  // 安全headers
  async headers() {
    return [
      {
        source: '/(.*)',
        headers: [
          {
            key: 'X-Frame-Options',
            value: 'DENY',
          },
          {
            key: 'X-Content-Type-Options',
            value: 'nosniff',
          },
        ],
      },
    ]
  },
}

module.exports = nextConfig
```

### 性能优化设置
```json
{
  "functions": {
    "app/**": {
      "maxDuration": 30
    }
  },
  "crons": []
}
```

## 📱 移动端优化

### PWA支持 (可选)
1. 安装 `next-pwa`:
```bash
npm install next-pwa
```

2. 配置 `next.config.js`:
```javascript
const withPWA = require('next-pwa')({
  dest: 'public'
})

module.exports = withPWA({
  // 现有配置...
})
```

## 🔄 自动部署流程

### Git集成
- ✅ **main分支**: 自动部署到生产环境
- ✅ **PR预览**: 每个Pull Request自动创建预览环境
- ✅ **分支部署**: 可为特定分支设置部署环境

### 部署触发器
```bash
# 推送到main分支触发生产部署
git push origin main

# 创建PR触发预览部署  
gh pr create --title "新功能" --body "描述"
```

## 🛡️ 安全和监控

### 环境变量安全
- ✅ 生产环境变量加密存储
- ✅ 预览环境隔离
- ✅ 敏感信息不在客户端暴露

### 监控配置
```javascript
// vercel.json
{
  "functions": {
    "app/api/**": {
      "maxDuration": 10
    }
  },
  "headers": [
    {
      "source": "/api/(.*)",
      "headers": [
        { "key": "Access-Control-Allow-Origin", "value": "*" },
        { "key": "Access-Control-Allow-Methods", "value": "GET, POST, PUT, DELETE, OPTIONS" }
      ]
    }
  ]
}
```

## 📊 成本估算

### Vercel免费额度
- ✅ **带宽**: 100GB/月
- ✅ **函数调用**: 1M次/月  
- ✅ **构建时间**: 6000分钟/月
- ✅ **团队成员**: 最多3人

### 预期使用量
- **带宽**: 约5-10GB/月 (正常使用)
- **函数调用**: 约10K-50K次/月
- **构建**: 约100-200次/月

**结论**: 免费额度完全足够！

## 🚨 故障排除

### 常见问题

1. **构建失败 - 找不到模块**
```bash
# 解决方案: 检查package.json依赖
cd frontend
rm -rf node_modules package-lock.json
npm install
```

2. **环境变量未生效**
```bash
# 检查变量名必须以NEXT_PUBLIC_开头
NEXT_PUBLIC_CONTRACT_ADDRESS="0x..." ✅
CONTRACT_ADDRESS="0x..." ❌
```

3. **页面404错误**
```bash
# 检查next.config.js的output设置
output: 'export', // 用于静态站点
// 或者移除此配置用于SSR
```

4. **钱包连接问题**
```bash
# 确保HTTPS环境（Vercel自动提供）
# 检查WalletConnect配置
```

### 调试工具
- **Vercel函数日志**: 实时查看服务端日志
- **浏览器控制台**: 检查客户端错误
- **Vercel Analytics**: 性能监控

## ✅ 部署检查清单

### 部署前检查
- [ ] 本地构建成功 (`npm run build`)
- [ ] 合约地址已准备
- [ ] 环境变量文件创建
- [ ] GitHub仓库权限设置

### 部署后验证
- [ ] 网站能正常访问
- [ ] 钱包连接功能正常
- [ ] 合约交互正常
- [ ] 移动端适配良好
- [ ] 页面加载速度满意

### 发布后操作
- [ ] 在GitHub README中更新Demo链接
- [ ] 分享给团队成员测试
- [ ] 设置监控和报警
- [ ] 准备自定义域名 (可选)

## 🔗 相关链接

- **Vercel文档**: https://vercel.com/docs
- **Next.js部署**: https://nextjs.org/docs/deployment
- **项目仪表板**: https://vercel.com/dashboard
- **域名管理**: https://vercel.com/docs/concepts/projects/domains

---

**预计总时间**: 10-15分钟  
**技术难度**: ⭐⭐ (简单)  
**维护成本**: 极低 (自动化部署)