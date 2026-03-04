# Changes

## 2026-03-04
- PaymasterV4.3: Token管理系统（`removeToken`, `getSupportedTokens`, `isTokenSupported`, `getSupportedTokensInfo`）
- PaymasterV4.3: `setTokenPrice` 增强零值校验，自动跟踪 supported tokens 列表
- 多链稳定币配置 (`deployments/stablecoins.json`): Ethereum/Optimism/Arbitrum/Base/Polygon/Sepolia
- 新增 ConfigureStablecoins / TestStablecoinSepolia / DeployAndTestV4 部署脚本
- 新增10个单元测试 + 13项Sepolia链上测试 (12 pass, 1 skip)
- 安全审查: 0 Critical / 0 High / 0 Medium（详见 `docs/Security-Review-V4.3-TokenManagement.md`）

## 2025-10-31
- 统一OpenZeppelin v5.0.2
- 删除废弃GasTokenV2
- 添加aPNTs部署脚本
- 添加社区注册页面
- GTokenStaking细粒度测试
- 安全审计工具评估文档
- 修复Slither重入漏洞
- SuperPaymasterV2添加SafeERC20

## 2025-10-30
- 完成统一xPNTs架构实现
- 添加部署指南和测试脚本
