# SuperPaymaster V3 业务场景与 SDK 模块映射表

为了支持“独立 Paymaster 运营商”及“社区独立 Token 发行”的架构需求，我们将 80+ 个业务场景（Entity E1-E14）映射到以下 SDK 核心模块：

## 1. 模块定义声明

| 模块名称 | NPM 包名 | 核心职责 |
| :--- | :--- | :--- |
| **Core** | `@aastar/core` | 基础 ABI 定义、通用 Client 通信 |
| **Registry** | `@aastar/registry` | 社区/用户角色注册、关系维护、信用额度查询 |
| **Tokens** | `@aastar/tokens` | **[NEW]** xPNTs (E5) 铸造/销毁、MySBT (E3) 状态管理 |
| **Finance** | `@aastar/finance` | GToken (E1) 质押、Paymaster (E7/E9) 资金充值 (Pull/Push) |
| **Paymaster (Standalone)** | `@aastar/paymaster-v4` | **[NEW]** 独立 Paymaster V4/V4.1 (E7) 部署与配置 |
| **SuperPaymaster** | `@aastar/superpaymaster` | V3.3 混合支付中间件 (E9)、Context 构建 |
| **Reputation** | `@aastar/reputation` | 信誉分同步、排序规则配置 |
| **DVT/BLS** | `@aastar/dvt` | 验证器注册、BLS 聚合操作 |

---

## 2. 场景映射明细 (72+ 实测场景)

### 2.1 协议治理类 (R1: Protocol Admin)
| 场景 ID | 业务重点 | 推荐使用 SDK 路径 |
| :--- | :--- | :--- |
| S1.1 - S1.3 | GToken 部署、铸造、所有权管理 | `@aastar/finance` / `GTokenClient` |
| S4.1 - S4.3 | 全局角色创建、信用等级设置、信誉批量更新 | `@aastar/registry` / `RegistryAdminClient` |
| S9.1 - S9.2 | SuperPM 全局 token 设置、协议收入提取 | `@aastar/superpaymaster` / `SuperPMAdmin` |

### 2.2 社区运营类 (R2: Community Admin)
| 场景 ID | 业务重点 | 推荐使用 SDK 路径 |
| :--- | :--- | :--- |
| S4.4 - S4.6 | 社区注册 (E4) 与 SBT (E3) 自动发放 | `@aastar/registry`, `@aastar/tokens` |
| S11.1 - S11.2| 社区规则定制、熵因子设置 | `@aastar/reputation` |

### 2.3 独立转账代付类 (R3: PM Operator)
| 场景 ID | 业务重点 | 推荐使用 SDK 路径 |
| :--- | :--- | :--- |
| S7.1 - S7.2 | **独立运营**: V4 Paymaster 部署与签名者配置 | `@aastar/paymaster-v4` |
| S7.3 | 资金维护: 向 Paymaster 内部 deposit ETH | `@aastar/finance` |

### 2.4 超级代付类 (R4: SuperPM Operator)
| 场景 ID | 业务重点 | 推荐使用 SDK 路径 |
| :--- | :--- | :--- |
| S9.3 - S9.6 | V3 Operator 配置、xPNTs 抵押与收益管理 | `@aastar/superpaymaster`, `@aastar/finance` |

### 2.5 最终用户类 (R5: EndUser)
| 场景 ID | 业务重点 | 推荐使用 SDK 路径 |
| :--- | :--- | :--- |
| S4.7 - S4.8 | 用户注册、SBT 绑定与状态检测 | `@aastar/registry`, `@aastar/tokens` |
| S9.7 - S9.8 | **核心操作**: AA 账户 UserOp 代付执行 (Credit/Debt) | `@aastar/superpaymaster` / `Middleware` |
| S10.1 - S10.2| 信用评分查询与动态上限获取 | `@aastar/registry` / `CreditClient` |

### 2.6 安全与攻击面 (Edge Cases)
| 场景 ID | 业务重点 | 验证手段 (SDK 基建提供) |
| :--- | :--- | :--- |
| SB1 | 权限越权 (Unauthorized Access) | `@aastar/core` 提供基础 Revert 捕获 |
| SB2 | 资源竭尽 (Balance Exhaustion) | `@aastar/finance` 监控接口 |
| SB3 | 重入防护 (Reentrancy Guard) | `@aastar/core` 模拟攻击脚本 |

---

## 3. 结论
通过新增 `@aastar/tokens` 和 `@aastar/paymaster-v4`，SDK 已完全承载了 **《角色-实体交互矩阵》** 中的所有能力。
1. **独立运营支持**: `paymaster-v4` 模块解决了原有 SDK 对 standalone V4 支持不足的问题。
2. **多代币体系支持**: `tokens` 模块统一了 xPNTs 与 SBT 的交互入口。
