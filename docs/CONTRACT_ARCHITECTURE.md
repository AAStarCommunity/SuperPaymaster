# SuperPaymaster V3 核心合约体系架构文档

> 版本: SuperPaymaster V3.0.0 / Registry V3.0.0
> 状态: Release Candidate (v3.0.0-dev)

---

## 📅 版本变更摘要 (V2 -> V3)

V3 在保留 V2 核心业务逻辑（Gas 代付、多币种结算）的基础上，对底层治理架构进行了重构：

*   **Registry 重构**: 从静态枚举 (`Enum Types`) 升级为动态 **Role-Based** 系统 (`bytes32 roleId`)，支持更灵活的角色扩展。
*   **Staking 重构**: 从 `Locker` 授权模式升级为 **Role-Based Locking**，质押直接绑定角色，安全性更高。
*   **注册流程统一**: 所有角色（用户、社区、Paymaster、KMS）统一通过 `Registry.registerRole` 入口注册。
*   **经济模型落地**: 实装了 **Entry Burn** (注册销毁) 和 **Exit Fee** (退出费) 机制。

---

## 一、项目目标

SuperPaymaster 项目的核心目标是提供符合 **ERC-4337** 标准的 Paymaster 服务，支持 EntryPoint v0.7。通过在 UserOp 中指定 Paymaster 合约地址，用户可以实现 **Gasless (免 Gas)** 交易，使用社区代币 (xPNTs) 支付网络费用。

### Paymaster 模式支持

| 模式 | 合约 | 说明 | 适用场景 |
|------|------|------|----------|
| **V3 共享模式** | SuperPaymasterV3 | 多租户托管 Paymaster，集成 V3 Registry | 普通社区 / DAO |
| **V4 独立模式** | PaymasterV4 | 社区独立部署，自主管理 ETH 存款 | 高级技术团队 |

---

## 二、系统对象概览 (V3)

### 核心对象关系图

```mermaid
graph TD
    User((User/Wallet))
    subgraph Core[核心层]
        Registry[Registry V3<br/>(角色管理中心)]
        Staking[GTokenStaking V3<br/>(资金管理中心)]
        GToken[(GToken)]
        MySBT[MySBT V3<br/>(身份凭证)]
    end

    subgraph Service[服务层]
        SP[SuperPaymaster V3<br/>(Gas 代付服务)]
        EP[EntryPoint v0.7]
    end

    subgraph CommunityLayer[社区层]
        DAO[Community DAO]
        xPNTs[xPNTs Token<br/>(Gas Payment)]
    end

    %% Relationships
    User --1. Register Role--> Registry
    Registry --2. Mint SBT--> MySBT
    Registry --3. Lock Stake--> Staking
    User --Stake GToken--> Staking

    User --4. Send UserOp--> EP
    EP --5. Validate & Pay--> SP
    SP --6. Check Role--> Registry
    SP --7. Deduct xPNTs--> DAO
```

### 核心流转逻辑

1.  **统一注册**: 用户和社区都通过 `Registry` 注册身份。
2.  **资金托管**: 所有质押资金 (GToken) 由 `GTokenStaking` 统一管理，不再分散。
3.  **身份凭证**: `MySBT`作为链上身份凭证，记录用户所在的社区和角色。
4.  **服务鉴权**: `SuperPaymaster V3` 不再维护白名单，而是实时查询 `Registry` 确认用户和运营商的资格。

---

## 三、核心合约列表 (V3)

| 合约 | 版本 | 说明 | 关键职责 |
|------|------|------|----------|
| **Registry** | 3.0.0 | **核心大脑** | 管理 Role Config、用户注册、权限验证 |
| **GTokenStaking** | 3.0.0 | **金库** | 管理质押、Entry Burn (销毁)、Exit Fee (退出费) |
| **SuperPaymasterV3** | 3.0.0 | **服务入口** | ERC-4337 Paymaster，负责 Gas 代付和 xPNTs 扣费 |
| **MySBT** | 3.0.0 | **身份层** | ERC721 SBT，即"会员卡"，与 Registry 联动 |
| **GToken** | 2.0.0 | **治理代币** | 系统质押代币 |

---

## 四、角色定义 (Role System)

V3 使用 `bytes32` 标识符定义角色。

### 1. End User (终端用户)
*   **Role ID**: `keccak256("ENDUSER")`
*   **描述**: 使用 Gasless 服务的普通用户。
*   **前置要求**:
    *   持有 GToken (约 0.4 GT)
    *   通过 `Registry.registerRole` 注册
*   **成本模型**:
    *   **Stake**: 0.3 GT (退出时退还)
    *   **Entry Burn**: 0.1 GT (注册费，直接销毁)
    *   **Exit Fee**: 0 GT (目前设置为 0)

### 2. Community (社区)
*   **Role ID**: `keccak256("COMMUNITY")`
*   **描述**: 在系统内建立 DAO 的组织。
*   **功能**: 发行 xPNTs，为成员提供 Gas 赞助。
*   **成本模型**:
    *   Stake: 30 GT
    *   Entry Burn: 3 GT

### 3. Paymaster Operator (运营商)
*   **Role ID**: `keccak256("PAYMASTER_AOA")` 或 `keccak256("PAYMASTER_SUPER")`
*   **描述**: 为 SuperPaymaster 提供流动性支持的节点。
*   **鉴权**: SuperPaymaster 会检查 Operator 是否拥有上述角色之一。
*   **成本模型**:
    *   Stake: 30 GT (AOA) / 50 GT (SUPER)
    *   Entry Burn: 10% Stake

### 4. KMS / ANODE (基础设施)
*   **Role ID**: `keccak256("KMS")` / `keccak256("ANODE")`
*   **描述**: 提供密钥管理或计算服务的节点。

---

## 五、经济模型与资金流 (Tokenomics)

### 1. 注册与销毁 (Entry Burn)
当用户调用 `Registry.registerRole(roleId)` 时：
1.  用户 `approve` GToken 给 `GTokenStaking`。
2.  `GTokenStaking` 划转 `Stake + Burn` 总额。
3.  `Burn` 部分直接转入 **0x...dEaD** 地址销毁。
4.  `Stake` 部分记入用户的 `RoleLock`，不可流动。

### 2. 退出与费用 (Exit Fee)
当用户调用 `Registry.exitRole(roleId)` 时：
1.  `GTokenStaking` 解锁质押。
2.  计算 **Exit Fee** (如有配置，如 2%)。
3.  **Exit Fee** 转入协议财库 (Treasury)。
4.  **剩余资金 (Net Amount)** 全额退还给用户钱包。
5.  Registry 移除用户角色，SBT 可能会被标记失效或销毁。

### 3. Gas 赞助流程 (xPNTs)
这部分继承自 V2 逻辑，核心没有变化：

1.  **用户发起**: UserOp 携带 `paymasterAndData`。
2.  **验证**: SuperPaymaster 询问 Registry："该用户是 ENDUSER 吗？该 Operator 是 COMMUNITY 吗？"
3.  **执行**: EntryPoint 执行交易。
4.  **扣费 (PostOp)**:
    *   计算实际 Gas 消耗 (ETH)。
    *   通过 Oracle 获取 ETH/USD 和 xPNTs/USD 价格。
    *   计算所需 xPNTs 数量。
    *   从用户在 Operator 处的余额中扣除 xPNTs。

---

## 六、部署与配置流程

### 部署顺序
1.  **GToken** (Existing)
2.  **GTokenStaking V3** (Deploy check: GToken, Treasury)
3.  **MySBT V3** (Deploy check: Staking, Registry placeholder)
4.  **Registry V3** (Deploy check: Staking, MySBT)
5.  **SuperPaymaster V3** (Deploy check: Registry, PriceFeed)

### 关键配置 (Wiring)
部署完成后必须执行的连接操作：

1.  **Registry -> Staking**: Registry 必须被设定为 Staking 的 `Registry` 地址 (用于触发 Lock)。
2.  **MySBT -> Registry**: MySBT 需指向正确的 Registry (用于 Mint)。
3.  **SuperPaymaster -> Config**: 设置 `setProtocolTreasury` 和 `setAPNTsToken`。

---

## 七、合约存储布局 (Storage Layout)

### Registry V3
```solidity
mapping(bytes32 => RoleConfig) public roleConfigs;           // 角色配置 (Stake, Burn参数)
mapping(bytes32 => mapping(address => bool)) public hasRole; // 用户角色状态
mapping(bytes32 => address[]) public roleMembers;            // 角色成员列表
mapping(address => bytes) public roleMetadata;               // 用户元数据 (IPFS等)
```

### GTokenStaking V3
```solidity
mapping(address => mapping(bytes32 => RoleLock)) public roleLocks; // 用户->角色->锁定资金
mapping(address => StakeInfo) public stakes;                       // 用户总质押信息
mapping(bytes32 => RoleExitConfig) public roleExitConfigs;         // 角色推出费率配置
```

---

## 八、FAQ

**Q: V3 还能使用 V2 的 PaymasterFactory 吗？**
A: 不可以。V3 是全新的生态。如果需要独立部署 Paymaster，请使用适配 V3 Registry 的 `PaymasterV4`。

**Q: 用户退出社区需要支付罚金吗？**
A: 取决于 `RoleExitConfig`。目前的 EndUser 角色配置为 0 Exit Fee，即免费退出 (仅需 gas)。Community 角色可能会配置一定的 Exit Fee 以防止恶意频繁进出。

**Q: 旧的 SuperPaymasterV2 还能用吗？**
A: V2 合约仍在链上运行，但 V3 系统上线后，新用户应注册到 V3 Registry 使用 V3 Paymaster。V2 将进入维护模式。
