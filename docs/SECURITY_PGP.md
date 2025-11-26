# Security Policy

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

## Reporting Security Vulnerabilities

If you discover a security vulnerability in SuperPaymaster contracts, please report it responsibly.

### Contact

**Email**: security@aastar.io

**PGP Key**: Available upon request

### Reporting Process

1. **Do NOT** disclose vulnerabilities publicly before contacting us
2. Email us with detailed vulnerability information
3. Include:
   - Contract address and network
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact assessment
   - Suggested fix (if any)

4. We will acknowledge receipt within 48 hours
5. We will provide an initial assessment within 7 days

### Scope

The following contracts are in scope:

| Contract | Network | Address |
|----------|---------|---------|
| SuperPaymasterV2 | Sepolia | `0x7c3c355d9aa4723402bec2a35b61137b8a10d5db` |
| MySBT v2.4.5 | Sepolia | `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7` |
| Registry v2.2.1 | Sepolia | `0xf384c592D5258c91805128291c5D4c069DD30CA6` |
| GToken | Sepolia | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | Sepolia | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |
| xPNTsFactory | Sepolia | `0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd` |

### Out of Scope

- Third-party contracts (EntryPoint, OpenZeppelin)
- Frontend applications
- Off-chain infrastructure
- Already known issues

## Bug Bounty Program

We offer rewards for responsible disclosure:

| Severity | Reward |
|----------|--------|
| Critical | Up to $10,000 |
| High | Up to $5,000 |
| Medium | Up to $1,000 |
| Low | Up to $200 |

### Severity Classification

**Critical**:
- Direct theft of funds
- Permanent freezing of funds
- Privilege escalation to admin

**High**:
- Indirect theft requiring specific conditions
- Temporary freezing of funds
- Bypass of security controls

**Medium**:
- Griefing attacks
- DoS attacks on critical functions
- Information disclosure

**Low**:
- Gas inefficiencies
- Minor access control issues
- Non-critical function failures

## Security Measures

### Smart Contract Security

1. **Access Control**
   - Owner-only functions for critical operations
   - DAO multisig for MySBT admin functions
   - Oracle-restricted failure reporting

2. **Reentrancy Protection**
   - ReentrancyGuard on all state-changing functions
   - Checks-Effects-Interactions pattern

3. **Input Validation**
   - Parameter bounds checking
   - Address zero checks
   - Amount validation

4. **Pausability**
   - Emergency pause functionality
   - DAO-controlled unpause

### Economic Security

1. **Staking Requirements**
   - Minimum stake for operators
   - Lock periods for SBT holders
   - Slashing for malicious behavior

2. **Price Oracle**
   - Chainlink price feeds
   - Staleness checks
   - Price bounds validation

3. **Debt Limits**
   - Maximum debt per user
   - Debt tracking by token

## Audit Status

| Audit | Status | Date |
|-------|--------|------|
| Internal Review | Completed | Nov 2025 |
| External Audit | Pending | TBD |

## Known Limitations

1. **Oracle Dependency**: Price calculations depend on Chainlink oracle availability
2. **Centralization**: Some admin functions are centralized (mitigated by DAO multisig)
3. **Gas Costs**: Complex operations may have high gas costs

## Changelog

### v2.4.5 (MySBT)
- Added SuperPaymaster callback integration
- Improved contract size optimization

### v2.3.3 (SuperPaymaster)
- Internal SBT registry for gas optimization
- Debt tracking by token
- PostOp payment model

### v2.2.1 (Registry)
- Auto-stake registration
- Duplicate prevention

## Resources

- [Contract Architecture](./CONTRACT_ARCHITECTURE.md)
- [Developer Guide](./DEVELOPER_INTEGRATION_GUIDE.md)
- [GitHub Repository](https://github.com/AAStar/SuperPaymaster)

---

<a name="chinese"></a>

# 安全策略

**[English](#english)** | **[中文](#chinese)**

---

## 报告安全漏洞

如果你发现 SuperPaymaster 合约中的安全漏洞，请负责任地报告。

### 联系方式

**邮箱**: security@aastar.io

**PGP 密钥**: 可应要求提供

### 报告流程

1. 在联系我们之前**请勿**公开披露漏洞
2. 通过邮件发送详细的漏洞信息
3. 包含：
   - 合约地址和网络
   - 漏洞描述
   - 复现步骤
   - 潜在影响评估
   - 建议的修复方案（如有）

4. 我们将在 48 小时内确认收到
5. 我们将在 7 天内提供初步评估

### 范围

以下合约在范围内：

| 合约 | 网络 | 地址 |
|------|------|------|
| SuperPaymasterV2 | Sepolia | `0x7c3c355d9aa4723402bec2a35b61137b8a10d5db` |
| MySBT v2.4.5 | Sepolia | `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7` |
| Registry v2.2.1 | Sepolia | `0xf384c592D5258c91805128291c5D4c069DD30CA6` |
| GToken | Sepolia | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | Sepolia | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |
| xPNTsFactory | Sepolia | `0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd` |

### 范围外

- 第三方合约（EntryPoint、OpenZeppelin）
- 前端应用
- 链下基础设施
- 已知问题

## 漏洞赏金计划

我们为负责任的披露提供奖励：

| 严重程度 | 奖励 |
|----------|------|
| 严重 | 最高 $10,000 |
| 高 | 最高 $5,000 |
| 中 | 最高 $1,000 |
| 低 | 最高 $200 |

### 严重程度分类

**严重**：
- 直接盗取资金
- 永久冻结资金
- 权限提升至管理员

**高**：
- 需要特定条件的间接盗取
- 临时冻结资金
- 绕过安全控制

**中**：
- 恶意攻击
- 关键功能的 DoS 攻击
- 信息泄露

**低**：
- Gas 效率低下
- 轻微的访问控制问题
- 非关键功能失败

## 安全措施

### 智能合约安全

1. **访问控制**
   - 关键操作仅限所有者
   - MySBT 管理功能使用 DAO 多签
   - 预言机限制的故障报告

2. **重入保护**
   - 所有状态更改函数使用 ReentrancyGuard
   - 检查-效果-交互模式

3. **输入验证**
   - 参数边界检查
   - 零地址检查
   - 金额验证

4. **可暂停性**
   - 紧急暂停功能
   - DAO 控制的取消暂停

### 经济安全

1. **质押要求**
   - 运营商最低质押
   - SBT 持有者锁定期
   - 恶意行为惩罚

2. **价格预言机**
   - Chainlink 价格信息
   - 过期检查
   - 价格边界验证

3. **债务限制**
   - 每用户最大债务
   - 按代币追踪债务

## 审计状态

| 审计 | 状态 | 日期 |
|------|------|------|
| 内部审查 | 已完成 | 2025年11月 |
| 外部审计 | 待定 | 待定 |

## 已知限制

1. **预言机依赖**：价格计算依赖 Chainlink 预言机可用性
2. **中心化**：部分管理功能是中心化的（通过 DAO 多签缓解）
3. **Gas 成本**：复杂操作可能有较高 Gas 成本

## 变更日志

### v2.4.5 (MySBT)
- 添加 SuperPaymaster 回调集成
- 改进合约大小优化

### v2.3.3 (SuperPaymaster)
- 用于 Gas 优化的内部 SBT 注册
- 按代币追踪债务
- PostOp 支付模型

### v2.2.1 (Registry)
- 自动质押注册
- 重复注册防止

## 资源

- [合约架构](./CONTRACT_ARCHITECTURE.md)
- [开发者指南](./DEVELOPER_INTEGRATION_GUIDE.md)
- [GitHub 仓库](https://github.com/AAStar/SuperPaymaster)
