# ERC-8004 Agent Identity — 集成设计与 Gap 分析

> 记录于 2026-05-21，基于 SuperPaymaster + AirAccount + ERC-8004 官方规范的联合讨论。

---

## 1. ERC-8004 规范概述

ERC-8004（Trustless Agents，2025-08 由 Marco De Rossi 等人提出，2026-01-29 上主网）定义了 AI agent 的链上身份层，核心是三个注册表合约。

### 1.1 三个注册表

| 注册表 | 职责 | 部署状态 |
|--------|------|---------|
| **IdentityRegistry** | ERC-721，为 agent 铸造 NFT（agentId = tokenId），绑定 agent 的执行钱包地址 | ✅ 已预部署 |
| **ReputationRegistry** | 标准化声誉反馈存储（giveFeedback / readFeedback） | ✅ 已预部署 |
| **ValidationRegistry** | TEE/validator 结果上链（仍在与 TEE 社区讨论中） | ❌ 未部署 |

### 1.2 预部署地址（无许可，任何人直接使用）

| 网络 | IdentityRegistry | ReputationRegistry |
|------|-----------------|-------------------|
| **Sepolia** | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| **Mainnet / Base / Arbitrum / Optimism / Polygon 等** | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` |

**不需要我们部署任何合约**，直接接入已有单例即可。

### 1.3 Agent 标识符结构

```
agentRegistry: {namespace}:{chainId}:{identityRegistry}
               e.g. "eip155:11155111:0x8004A818..."

agentId: ERC-721 tokenId（由 register() 铸造时分配）
```

### 1.4 关键函数（IdentityRegistry）

| 函数 | 说明 |
|------|------|
| `register(agentURI)` | 铸造 agent NFT，msg.sender 成为 owner（人类），返回 agentId |
| `setAgentWallet(agentId, wallet)` | 绑定 agent 的执行钱包，需 EIP-712/ERC-1271 签名证明 wallet 控制权，transfer 后自动清除 |
| `getAgentWallet(agentId)` | 查询 agent 绑定的执行钱包地址 |
| `ownerOf(agentId)` | ERC-721 标准，返回 agent NFT 的持有人（人类账户） |
| `balanceOf(owner)` | ERC-721 标准，查询某地址持有的 agent NFT 数量 |
| **`isRegisteredAgent()`** | **不存在**，官方合约无此函数（见 §3.1 兼容性问题） |

---

## 2. 人类账户 ↔ Agent 账户绑定机制

### 2.1 绑定的本质

ERC-8004 的 IdentityRegistry 本身就是绑定关系的载体：

```
ERC-721 tokenId (agentId)
  ├── ownerOf(agentId)         → 人类账户（NFT 持有者）
  └── getAgentWallet(agentId)  → agent 执行钱包（EIP-712 授权绑定）
```

- **人类 → agent**：`balanceOf(human)` 列出人类持有的所有 agentId；`getAgentWallet(agentId)` 得到 agent 执行地址
- **agent → 人类**：`ownerOf(agentId)` 直接返回人类地址（公开，ERC-721 标准行为）

### 2.2 完整绑定流程

```
Step 1: 人类 AA 账户（AirAccount）
  → IdentityRegistry.register(agentURI)
  → 铸造 agentId，ownerOf(agentId) = 人类地址

Step 2: Agent 执行钱包（agent 自己签名）
  → IdentityRegistry.setAgentWallet(agentId, agentWalletAddr)
    [需要 agentWalletAddr 持有者的 EIP-712 签名证明控制权]
  → getAgentWallet(agentId) = agentWalletAddr

Step 3: AirAccount 侧记录（可选，本地可见性）
  → AirAccount.setAgentWallet(agentId, agentWalletAddr, 0x8004A818...)
    [AAStarAirAccountBase.sol:1536，M7.16/C17 已实现]
  → 人类 AA 账户本地存有 agentId → wallet 映射
```

### 2.3 隐私分析

| 查询方向 | 链上可见性 | 说明 |
|---------|-----------|------|
| 人类 → agent 列表 | 公开（ERC-721 Transfer 事件可遍历） | 接受这个 trade-off |
| agent → 人类 | 公开（`ownerOf`） | 与 NFT 标准一致 |
| 需要更强隐私 | 用 commitment 方案 | `keccak256(humanAddr, salt)` 替代直接存储，证明时公布 salt |

对于当前阶段，ERC-721 的公开绑定满足需求；隐私增强可作为后续迭代。

---

## 3. 兼容性问题与现有代码 Gap

### 3.1 接口不匹配分析（SuperPaymaster 不需要改）

**问题表象**：SuperPaymaster 调用 `IAgentIdentityRegistry.isRegisteredAgent(account)`，但 ERC-8004 官方合约（`IdentityRegistryUpgradeable.sol`）**没有这个函数**，只有 ERC-721 继承的 `balanceOf(account)`。直接把 ERC-8004 地址传给 `setAgentRegistries()` 会导致永远返回 false。

**为何测试通过**：`SuperPaymasterV5Features.t.sol:39` 定义了一个**测试本地 mock**，它确实实现了 `isRegisteredAgent()`。`contracts/src/mocks/MockAgentIdentityRegistry.sol` 是另一个文件，并未被主测试使用。测试环境和生产环境用的是不同的 mock。

**解法：部署薄适配器，SuperPaymaster 零改动**

新建 `ERC8004Adapter.sol`，实现 `IAgentIdentityRegistry` 接口，内部委托给真实 ERC-8004：

```solidity
contract ERC8004Adapter is IAgentIdentityRegistry {
    address public immutable erc8004Registry;

    constructor(address _registry) {
        erc8004Registry = _registry;
    }

    /// ERC-7562 合规：读取的是 ERC-8004._balances[account]，
    /// 属于 UserOp sender 的关联存储，bundler 不会拒绝。
    function isRegisteredAgent(address account) external view returns (bool) {
        return IERC721(erc8004Registry).balanceOf(account) > 0;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return IERC721(erc8004Registry).balanceOf(owner);
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        return IERC721(erc8004Registry).ownerOf(agentId);
    }
}
```

`setAgentRegistries(adapterAddr, 0x8004B663...)` 指向 adapter，不直接指向 ERC-8004。

### 3.2 Gap 汇总表

| 项目 | 当前状态 | 所需工作 | 优先级 |
|------|---------|---------|--------|
| ERC-8004 合约部署 | ✅ 官方已预部署 | 无需任何部署 | — |
| **SuperPaymaster 合约改动** | ✅ **不需要** | 零改动 | — |
| `ERC8004Adapter` 合约 | ❌ 未实现 | 新建 ~30 行适配器，部署一次 | **P0** |
| `agentIdentityRegistry` Sepolia 配置 | ❌ `address(0)` | `setAgentRegistries(adapter, 0x8004B663...)` | **P1** |
| AirAccount `setAgentWallet()` 接入真实地址 | ⚠️ 已实现但未用真实注册表 | 传入 `0x8004A818...` 替代 mock | **P1** |
| 人类 `register()` 铸造 agentId | ❌ 未做 | 人类账户调 IdentityRegistry.register() | **P2** |
| Agent 调 `setAgentWallet()` 绑定执行钱包 | ❌ 未做 | Agent 钱包 EIP-712 签名调用 | **P2** |
| E2E 测试（G2）切换到真实 ERC-8004 | ⚠️ 当前用 inline mock | adapter 部署后替换地址回归 | **P1** |
| ValidationRegistry 集成 | ❌ 规范未定稿 | 等待 TEE 社区讨论 | P3 |

---

## 4. 完成 Feature 的具体步骤

### Phase 1：部署 ERC8004Adapter（SuperPaymaster 零改动）

1. **新建 `contracts/src/adapters/ERC8004Adapter.sol`**：实现 `IAgentIdentityRegistry`，内部委托 `balanceOf`
2. **forge test**：确认现有 G2 测试仍通过（test mock 不受影响）
3. **部署 adapter 到 Sepolia**：`forge script` 或 `cast`
4. **PR + 合并**

### Phase 2：Sepolia 接线（链上配置，不需要合约升级）

```bash
# SuperPaymaster owner 调用
cast send 0x506962D17AEA6E7A15fd3479D8c4E2ABBBF91112 \
  "setAgentRegistries(address,address)" \
  0x8004A818BFB912233c491871b3d84c89A494BD9e \
  0x8004B663056A597Dffe9eCcC1965A193B7388713 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

### Phase 3：端到端绑定流程验证

1. 人类账户调 `IdentityRegistry.register(agentURI)` → 获得 agentId
2. Agent 执行钱包调 `setAgentWallet(agentId, agentWalletAddr)` + EIP-712 签名
3. AirAccount 调 `setAgentWallet(agentId, agentWallet, 0x8004A818...)` 本地记录
4. 构造 agent 发送的 UserOp，paymasterAndData 指向 SuperPaymaster
5. 验证 `isRegisteredAgent(agentWallet)` 返回 true，UserOp 被赞助
6. 验证 `ownerOf(agentId)` 返回人类地址（反向查找）

### Phase 4：更新 E2E 测试

- `test-group-G2-agent-identity-sponsorship.js`：将 mock 地址替换为真实 ERC-8004 Sepolia 地址
- 补充测试：注册 agent → 绑定钱包 → gasless UserOp 全流程

---

## 5. 相关代码位置

| 文件 | 说明 |
|------|------|
| `contracts/src/interfaces/v3/IAgentIdentityRegistry.sol` | 需修改：移除 isRegisteredAgent |
| `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:1465` | 需修改：balanceOf 判断 |
| `contracts/src/mocks/MockAgentIdentityRegistry.sol` | 测试 mock，balanceOf 已实现，无需改 |
| `script/gasless-tests/test-group-G2-agent-identity-sponsorship.js` | Phase 4 替换为真实地址 |
| `../airaccount-contract/src/core/AAStarAirAccountBase.sol:1536` | setAgentWallet 已实现，Phase 3 接入 |

---

---

## 6. 分析演进记录（决策日志）

> 本节记录完整的讨论过程，包括错误方案和修正路径，供 AirAccount 团队审阅时还原推理链条。

### 6.1 第一轮（错误方案）：修改 SuperPaymaster 接口

**初始判断**：SuperPaymaster 调用 `isRegisteredAgent(account)`，该函数在 ERC-8004 中不存在，因此必须修改 SuperPaymaster，把判断逻辑从 `isRegisteredAgent()` 改为 `balanceOf(account) > 0`。

**代码改动草案（已废弃）**：
```solidity
// ❌ 废弃方案 — 修改 SuperPaymaster
function isRegisteredAgent(address account) public view returns (bool) {
    address reg = agentIdentityRegistry;
    if (reg == address(0)) return false;
    // 直接调 ERC-8004 的 balanceOf
    return IERC721(reg).balanceOf(account) > 0;
}
```

**用户推翻理由**：能否不改 SuperPaymaster？有没有其他方式？

**根本问题**：这个方案存在更深的逻辑错误（见 §6.3），即使实现也不正确。

---

### 6.2 第二轮（半正确方案）：薄适配器 ERC8004Adapter

**改进思路**：不修改 SuperPaymaster，部署一个薄适配器合约实现 `IAgentIdentityRegistry` 接口，内部委托给 ERC-8004。

```solidity
// ⚠️ 半正确方案 — 接口问题解决，但逻辑仍有缺陷（见 §6.3）
contract ERC8004Adapter is IAgentIdentityRegistry {
    address public immutable erc8004Registry;

    function isRegisteredAgent(address account) external view returns (bool) {
        return IERC721(erc8004Registry).balanceOf(account) > 0;
    }
    // ...
}
```

**SuperPaymaster 零改动**：`setAgentRegistries(adapterAddr, ...)` 指向 adapter。

**当时评估**：✅ SuperPaymaster 不需要改；❌ 仍未解决更深层问题（见下）。

---

### 6.3 第三轮（关键发现）：两层结构性错误

#### Layer 2 错误：AirAccount `setAgentWallet` 参数不匹配

检查 `airaccount-contract/src/core/AAStarAirAccountBase.sol:1536`：

```solidity
// ❌ AirAccount 现有实现 — 调用 2 参数版本
function setAgentWallet(uint256 agentId, address agentWallet, address erc8004Registry) external onlyOwner {
    (bool ok,) = erc8004Registry.call(
        abi.encodeWithSignature("setAgentWallet(uint256,address)", agentId, agentWallet)
        //                                      ^^^^^^^^^^^^^^^^^^^
        //  2 个参数！实际 ERC-8004 需要 4 个参数
    );
    (ok); // 忽略返回值 → SILENT FAILURE，链上绑定从未写入
    emit AgentWalletSet(agentId, agentWallet);  // 事件照常发出，造成假象
}
```

**真实 ERC-8004 签名**（来自 `IdentityRegistryUpgradeable.sol`）：
```solidity
// ✅ 真实 ERC-8004 函数签名
function setAgentWallet(
    uint256 agentId,
    address newWallet,
    uint256 deadline,        // ← 第3个参数：EIP-712 截止时间
    bytes calldata signature  // ← 第4个参数：agentWallet 自签名证明控制权
) external
```

**影响**：AirAccount 调用 `setAgentWallet` 时，ERC-8004 合约收到错误的 selector，低层 call 静默失败，`ok=false` 被忽略，事件照样 emit，表面上一切正常，实际链上从未建立绑定。

#### Layer 3 错误：`balanceOf` 的语义错位

ERC-8004 的 NFT 归属关系：

```
IdentityRegistry (ERC-721)
  ownerOf(agentId)         → 人类账户（NFT 持有者）
  getAgentWallet(agentId)  → agent 执行钱包
```

`register()` 铸造时：`ownerOf(agentId) = msg.sender`（人类），agentWallet 初始也是 msg.sender。

**核心矛盾**：

| 场景 | `balanceOf(agentWallet)` | SuperPaymaster 能赞助? |
|------|--------------------------|----------------------|
| 人类和 agent 是同一地址 | > 0 | ✅ 偶然正确 |
| 人类持有 NFT，agent 是独立执行钱包 | = 0（agentWallet 不持有 NFT） | ❌ 永远返回 false |

**结论**：ERC8004Adapter 方案中 `balanceOf(agentWallet) > 0` 只有在人类和 agent 共用同一地址时才能工作；一旦绑定了独立 agent 执行钱包，查询就失效。这个方案从根本上不能支持人类↔agent 双账户模型。

---

### 6.4 最终架构：AirAccount 部署自定义 AgentRegistry

**核心思路**：ERC-8004 是 NFT 身份层（可选使用），不是 SuperPaymaster 查询的直接来源。AirAccount 部署一个自定义的 `AgentRegistry`，维护 `agentWallet → humanOwner` 映射，直接实现 `IAgentIdentityRegistry` 接口。

```solidity
// ✅ 最终方案 — AirAccount 团队负责部署
contract AgentRegistry {
    // 核心状态
    mapping(address agentWallet => address humanOwner) public agentToHuman;
    mapping(address human => address[]) public humanAgents;

    // 注册：人类账户调用，声明 agentWallet 属于自己
    function registerAgent(address agentWallet) external {
        require(agentToHuman[agentWallet] == address(0), "already registered");
        agentToHuman[agentWallet] = msg.sender;
        humanAgents[msg.sender].push(agentWallet);
        emit AgentRegistered(msg.sender, agentWallet);
    }

    // SuperPaymaster 调用的入口
    function isRegisteredAgent(address account) external view returns (bool) {
        return agentToHuman[account] != address(0);
    }

    // IAgentIdentityRegistry 接口兼容
    function balanceOf(address owner) external view returns (uint256) {
        return humanAgents[owner].length;
    }

    // ownerOf 语义：给定 agentWallet 找人类账户（非 tokenId 语义）
    function ownerOf(uint256) external pure returns (address) {
        return address(0); // SP 不依赖此函数
    }

    // 查询：agent → 人类（可选隐私增强：用 commitment 替代直接存储）
    function getHumanOwner(address agentWallet) external view returns (address) {
        return agentToHuman[agentWallet];
    }

    // 查询：人类 → agent 列表
    function getAgents(address human) external view returns (address[] memory) {
        return humanAgents[human];
    }
}
```

**ERC-8004 在此架构中的位置**：可选的 NFT 身份层。人类注册 agentId 后，可在 AgentRegistry 的 `registerAgent` 中同时验证 `ERC8004.ownerOf(agentId) == msg.sender`，实现 ERC-8004 背书。但这是 AirAccount 的内部策略，不影响 SuperPaymaster。

---

### 6.5 各方职责分工

| 团队 | 工作内容 | 优先级 |
|------|---------|--------|
| **AirAccount** | 部署 `AgentRegistry.sol`（~60行） | P0 |
| **AirAccount** | 更新 `setAgentWallet()` 调用 `agentRegistry.registerAgent(agentWallet)` | P0 |
| **AirAccount** | 可选：在 `registerAgent` 内校验 ERC-8004 `ownerOf(agentId) == msg.sender` | P2 |
| **SuperPaymaster** | **零改动**（代码不变） | — |
| **SuperPaymaster owner** | `setAgentRegistries(agentRegistryAddr, 0x8004B663...)` 链上配置一次 | P1 |
| **双方** | E2E 测试：人类注册 agent → agent 发 UserOp → SuperPaymaster 赞助 | P1 |

---

### 6.6 为何不直接用 ERC8004Adapter（最终放弃原因汇总）

| 问题 | 说明 |
|------|------|
| `isRegisteredAgent` 不存在 | ERC-8004 只有 ERC-721 标准函数，adapter 需自己实现 |
| `balanceOf(agentWallet) > 0` 语义错 | NFT 由人类持有，agent 执行钱包的 balanceOf 为 0 |
| AirAccount 绑定写入永久失败 | 2-param 调用 vs 4-param 真实签名，低层静默失败 |
| 适配器成本 ≠ 0 | 比直接部署 AgentRegistry 更复杂（需要 ERC-8004 + adapter 两层） |

**结论**：ERC8004Adapter 只解决了接口层问题，没有解决数据层问题。正确路径是 AgentRegistry，ERC-8004 仅作为可选的 NFT 背书层。

---

### 6.7 隐私增强（可选后续迭代）

当前 AgentRegistry 直接存储 `agentWallet → humanOwner`，链上完全公开。若需更强隐私：

```solidity
// commitment 方案：存储哈希，证明时公布 salt
mapping(address agentWallet => bytes32 humanCommitment) public agentToHumanHash;

function registerAgentPrivate(address agentWallet, bytes32 commitment) external {
    // commitment = keccak256(abi.encodePacked(msg.sender, salt))
    agentToHumanHash[agentWallet] = commitment;
}

// 验证时：提交 (humanAddr, salt)，链下验证 keccak256(humanAddr, salt) == commitment
```

当前阶段公开映射满足需求，隐私增强作为后续迭代。

---

*文档版本：2026-05-21 | 关联：SuperPaymaster v5.3.2，ERC-8004 主网上线 2026-01-29*
