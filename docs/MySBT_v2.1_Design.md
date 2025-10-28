# MySBT v2.1 - 白板身份证完整设计方案

> **版本**: v2.1-final
> **日期**: 2025-10-28
> **状态**: 设计定稿，待实施

---

## 目录

1. [核心理念](#核心理念)
2. [架构设计](#架构设计)
3. [技术规格](#技术规格)
4. [实施计划](#实施计划)
5. [测试方案](#测试方案)
6. [部署清单](#部署清单)

---

## 核心理念

### 白板身份证（White-label SBT）

**核心概念**：一个用户一个 SBT，多个社区共同认证。

```
用户 Alice
  └─ SBT Token #123 (白板身份证)
      ├─ 首发社区: BreadCommunity (永久记录)
      ├─ 成员资格: [BreadCommunity, AlphaCommunity, GammaDAO]
      ├─ NFT 绑定: [Bread NFT #456, Alpha NFT #789]
      └─ 头像: BAYC #1234 (自定义)
```

### 设计原则

1. **一人一证**：避免 SBT 泛滥，一个用户只需一个 SBT
2. **社区共写**：多个社区可在同一个 SBT 上添加成员资格
3. **幂等安全**：重复 mint 不会创建新 SBT，只添加记录
4. **无需许可**：任何在 Registry 注册的社区都可调用
5. **灵活验证**：基础成员资格 + NFT reputation boost
6. **DAO 治理**：参数由多签管理，合约逻辑不可更改

---

## 架构设计

### 1. 核心数据结构

#### SBTData - SBT 基本信息

```solidity
struct SBTData {
    address holder;            // SBT 持有者
    address firstCommunity;    // 首次发行社区（永久不可更改）
    uint256 mintedAt;          // 铸造时间
    uint256 totalCommunities;  // 加入社区总数
}
```

**关键点**：
- `firstCommunity` 记录首次为用户发行 SBT 的社区，永久不可更改
- 这是社区的"第一发行权"记录，具有历史意义

#### CommunityMembership - 社区成员资格

```solidity
struct CommunityMembership {
    address community;          // 社区地址
    uint256 joinedAt;          // 加入时间
    uint256 lastActiveTime;    // 最后活跃时间
    bool isActive;             // 是否活跃
    string metadata;           // 社区自定义元数据（IPFS URI）
}
```

**存储方式**：
```solidity
mapping(uint256 => CommunityMembership[]) public memberships;
mapping(uint256 => mapping(address => uint256)) public membershipIndex;
```

#### NFTBinding - NFT 绑定（可选，用于 Reputation 提升）

```solidity
struct NFTBinding {
    address nftContract;
    uint256 nftTokenId;
    address community;         // 所属社区
    uint256 bindTime;
    bool isActive;
    NFTBindingMode mode;       // CUSTODIAL / NON_CUSTODIAL
}
```

#### AvatarSetting - 用户头像

```solidity
struct AvatarSetting {
    address nftContract;       // 任意 ERC721 NFT
    uint256 nftTokenId;
    bool isCustom;            // true=用户主动设置，false=自动设置
}
```

---

### 2. 幂等性 Mint 机制

#### 函数签名

```solidity
function mintOrAddMembership(address user, string memory metadata)
    external
    nonReentrant
    returns (uint256 tokenId, bool isNewMint)
```

#### 调用者权限

```solidity
require(_isValidCommunity(msg.sender), "Community not registered in Registry");

function _isValidCommunity(address community) internal view returns (bool) {
    try IRegistryV2(REGISTRY).getCommunityProfile(community) returns (
        CommunityProfile memory profile
    ) {
        return profile.isActive;  // 必须在 Registry 注册且活跃
    } catch {
        return false;
    }
}
```

**关键限制**：只有在 Registry 注册并 stake 了 GToken 的社区才能调用。

#### 执行逻辑

**首次 Mint（isNewMint = true）**：
1. 创建 SBT 数据，记录 `firstCommunity`
2. 添加首个社区成员资格
3. Lock 0.3 stGToken（从用户账户）
4. Burn 0.1 GToken（从用户账户）
5. Mint ERC721 Token

**后续添加（isNewMint = false）**：
1. 检查是否已有该社区记录
2. 无记录：添加新社区成员资格
3. 有记录：更新活跃状态和元数据

**示例流程**：

```typescript
// AAA 社区给用户 Alice mint
await sbt.mintOrAddMembership(alice, "ipfs://aaa-metadata");
// → 创建 SBT #1, firstCommunity = AAA, Lock 0.3 sGT, Burn 0.1 GT

// BBB 社区给用户 Alice mint（已有 SBT）
await sbt.mintOrAddMembership(alice, "ipfs://bbb-metadata");
// → SBT #1 不变, 添加 BBB 成员资格, 无需再次 Lock/Burn

// AAA 社区再次给 Alice mint（幂等性）
await sbt.mintOrAddMembership(alice, "ipfs://aaa-updated-metadata");
// → SBT #1 不变, 更新 AAA 成员资格的 metadata 和活跃时间
```

---

### 3. Reputation 系统

#### 架构：外部计算器模式

```solidity
interface IReputationCalculator {
    function calculateReputation(
        address user,
        address community,
        uint256 sbtTokenId
    ) external view returns (uint256 communityScore, uint256 globalScore);
}

address public reputationCalculator;  // 可由 DAO 更新
```

**优势**：
- ✅ 合约逻辑可升级（更换计算器合约）
- ✅ 计算复杂度不受限（可使用 Chainlink Functions）
- ✅ 多种计算模式共存（默认 + 自定义）

#### 默认计算规则

**社区内 Reputation（0-100分）**：
- 有 SBT 成员资格：20分
- 绑定社区 NFT：+3分/个
- 最近4周每周活跃：+1分/周

**全局 Reputation（0-1000分）**：
- 每个社区成员资格：+50分
- 每个 NFT 绑定：+20分
- 总活跃周数：+5分/周

#### 活跃度记录

**链上被动记录（推荐）**：

```solidity
function recordActivity(address user) external {
    require(_isValidCommunity(msg.sender), "Not registered community");

    uint256 tokenId = userToSBT[user];
    require(tokenId != 0, "No SBT");

    uint256 currentWeek = block.timestamp / 1 weeks;
    weeklyActivity[tokenId][msg.sender][currentWeek] = true;

    memberships[tokenId][idx].lastActiveTime = block.timestamp;
}
```

**集成到 Paymaster**（Phase 2）：

```solidity
// PaymasterV4.sol
function _validatePaymasterUserOp(...) internal override returns (...) {
    // ... 原有验证逻辑

    // 记录活跃度（不影响验证，失败不回滚）
    try IMySBT(SBT_ADDRESS).recordActivity(sender) {} catch {}

    // ... 返回验证结果
}
```

---

### 4. 头像系统

#### 三级优先级

```solidity
function getAvatarURI(uint256 tokenId) external view returns (string memory) {
    // 1. 用户自定义头像（最高优先级）
    if (sbtAvatars[tokenId].isCustom) {
        return IERC721Metadata(sbtAvatars[tokenId].nftContract)
            .tokenURI(sbtAvatars[tokenId].nftTokenId);
    }

    // 2. 第一个绑定的 NFT 头像（自动设置）
    if (sbtAvatars[tokenId].nftContract != address(0)) {
        return IERC721Metadata(sbtAvatars[tokenId].nftContract)
            .tokenURI(sbtAvatars[tokenId].nftTokenId);
    }

    // 3. 首发社区默认头像
    return communityDefaultAvatar[sbtData[tokenId].firstCommunity];
}
```

#### 设置规则

**自动设置**：
- 用户绑定第一个 NFT 时，自动设置为该 NFT 头像
- `isCustom = false`（标记为自动）

**用户主动设置**：
- 用户可选择任意拥有的 ERC721 NFT 作为头像
- `isCustom = true`（标记为手动，优先级最高）

**跨账户授权**（可选）：

```solidity
// 方案1: 委托授权
mapping(address => mapping(uint256 => mapping(address => bool))) public avatarDelegation;

function delegateAvatarUsage(address nftContract, uint256 nftTokenId, address delegatee) external {
    require(IERC721(nftContract).ownerOf(nftTokenId) == msg.sender, "Not owner");
    avatarDelegation[nftContract][nftTokenId][delegatee] = true;
}

// 方案2: 签名验证
function setAvatar(address nftContract, uint256 nftTokenId, bytes memory signature) external {
    // 验证签名是否来自 NFT 所有者
}
```

---

### 5. NFT 绑定机制（可选）

#### 两种绑定模式

**CUSTODIAL（托管模式）**：
- NFT 转移到 SBT 合约保管
- 更安全，无法转移 NFT
- 适用于社区身份核心凭证

**NON_CUSTODIAL（保留模式）**：
- NFT 留在用户钱包
- 仅记录绑定关系
- 适用于灵活展示

#### 绑定函数

```solidity
function bindCommunityNFT(
    address community,
    address nftContract,
    uint256 nftTokenId,
    NFTBindingMode mode
) external nonReentrant {
    uint256 tokenId = userToSBT[msg.sender];
    require(tokenId != 0, "No SBT");

    // 验证成员资格
    uint256 idx = membershipIndex[tokenId][community];
    require(memberships[tokenId][idx].isActive, "Not community member");

    // 验证 NFT 所有权
    require(IERC721(nftContract).ownerOf(nftTokenId) == msg.sender, "Not NFT owner");

    // 执行绑定
    if (mode == NFTBindingMode.CUSTODIAL) {
        IERC721(nftContract).transferFrom(msg.sender, address(this), nftTokenId);
    }

    nftBindings[tokenId][community] = NFTBinding({...});

    // 自动设置头像（如果这是第一个绑定）
    if (sbtAvatars[tokenId].nftContract == address(0)) {
        sbtAvatars[tokenId] = AvatarSetting({
            nftContract: nftContract,
            nftTokenId: nftTokenId,
            isCustom: false
        });
    }
}
```

---

### 6. 验证函数

#### 基础成员资格验证

```solidity
function verifyCommunityMembership(address user, address community)
    external
    view
    returns (bool isMember)
{
    uint256 tokenId = userToSBT[user];
    if (tokenId == 0) return false;

    uint256 idx = membershipIndex[tokenId][community];
    if (idx >= memberships[tokenId].length) return false;

    return memberships[tokenId][idx].isActive;
}
```

**Paymaster 集成**：
```solidity
require(
    ISBT(SBT_ADDRESS).verifyCommunityMembership(sender, address(this)),
    "Not community member"
);
```

#### Reputation 验证

```solidity
function getCommunityReputation(address user, address community)
    external
    view
    returns (uint256 score)
{
    // 使用外部计算器（如果设置）
    if (reputationCalculator != address(0)) {
        (score, ) = IReputationCalculator(reputationCalculator)
            .calculateReputation(user, community, userToSBT[user]);
        return score;
    }

    // Fallback：默认计算
    return _calculateDefaultReputation(userToSBT[user], community);
}
```

---

### 7. DAO 治理

#### 可治理参数

```solidity
modifier onlyDAO() {
    require(msg.sender == daoMultisig, "Only DAO");
    _;
}

// 1. Lock 数量
function setMinLockAmount(uint256 _amount) external onlyDAO;

// 2. Mint 费用
function setMintFee(uint256 _fee) external onlyDAO;

// 3. Reputation 计算器
function setReputationCalculator(address _calculator) external onlyDAO;

// 4. DAO 多签地址
function setDAOMultisig(address _newDAO) external onlyDAO;
```

#### 社区自治权限

```solidity
// 社区可设置自己的默认头像（无需 DAO）
function setCommunityDefaultAvatar(string memory avatarURI) external {
    communityDefaultAvatar[msg.sender] = avatarURI;
}
```

---

## 技术规格

### 合约依赖

```solidity
// Core
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Interfaces
import "../interfaces/Interfaces.sol";  // IGTokenStaking, IGToken
import "./IRegistryV2.sol";
import "./IReputationCalculator.sol";
```

### Solidity 版本

```solidity
pragma solidity ^0.8.23;
```

### Gas 优化

1. **存储优化**：使用 `membershipIndex` 映射避免数组遍历
2. **View 函数**：Reputation 计算为 `view`，不消耗 gas
3. **Try-Catch**：活跃记录失败不影响主逻辑
4. **Batch 操作**：支持批量查询（前端调用）

---

## 实施计划

### Phase 1: 合约开发与测试（Week 1-2）

**任务清单**：
- [x] 方案讨论与定稿
- [ ] 创建 MySBT_v2.1.sol 合约
- [ ] 创建 IReputationCalculator.sol 接口
- [ ] 创建 DefaultReputationCalculator.sol 实现
- [ ] 创建 MySBT_v2.1.t.sol 测试文件
- [ ] 编写完整测试套件（覆盖率 >90%）
- [ ] 本地 Anvil 测试

**测试场景**：
1. ✅ 幂等性 Mint
   - 首次 mint 创建 SBT
   - 重复 mint 添加记录
   - 同社区重复 mint 更新元数据

2. ✅ Registry 权限验证
   - 未注册社区无法调用
   - 注册但不活跃的社区无法调用
   - 注册且活跃的社区可调用

3. ✅ NFT 绑定
   - CUSTODIAL 模式转移 NFT
   - NON_CUSTODIAL 模式仅记录
   - 自动设置头像

4. ✅ 头像系统
   - 默认社区头像
   - 自动设置（绑定 NFT）
   - 手动设置（任意 NFT）
   - 优先级正确

5. ✅ Reputation 计算
   - 默认计算逻辑
   - 外部计算器调用
   - 活跃度记录

6. ✅ Soul Bound
   - Mint 和 Burn 正常
   - Transfer 被禁止

7. ✅ DAO 治理
   - 参数更新
   - 权限转移

### Phase 2: Sepolia 部署与验证（Week 3）

**任务清单**：
- [ ] 编写部署脚本
- [ ] Sepolia 测试网部署
- [ ] Etherscan/Sourcify 验证合约
- [ ] 配置 DAO 多签（Gnosis Safe）
- [ ] 设置初始参数
- [ ] 集成测试

**部署顺序**：
1. 部署 MySBT 合约
2. 部署 DefaultReputationCalculator
3. 设置 Reputation 计算器
4. 转移 DAO 权限到多签
5. 验证所有合约

### Phase 3: 前端开发（Week 4-5）

**页面结构**：

```
/get-sbt
├── UserView (用户视图)
│   ├── SBT 信息展示
│   ├── 社区成员资格列表
│   ├── Reputation 得分
│   ├── 头像设置
│   └── NFT 绑定
│
├── CommunityAdminView (社区管理视图)
│   ├── 设置社区默认头像
│   ├── 为成员批量 mint SBT
│   ├── 发行社区 NFT
│   └── 记录用户活跃
│
└── StatsView (统计视图)
    ├── 总用户数
    ├── 总社区数
    └── 活跃度趋势
```

**技术栈**：
- React + TypeScript
- ethers.js v6
- TanStack Query（数据缓存）
- Wagmi（钱包连接）

### Phase 4: Paymaster 集成（Week 6）

**任务清单**：
- [ ] 修改 PaymasterV4.sol
- [ ] 添加 `recordActivity()` 调用
- [ ] 测试 Reputation 变化
- [ ] 部署更新的 Paymaster
- [ ] 端到端测试

**代码修改**：

```solidity
// PaymasterV4.sol
function _validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) internal override returns (bytes memory context, uint256 validationData) {
    address sender = userOp.sender;

    // 1. 验证 SBT 成员资格
    require(
        ISBT(SBT_ADDRESS).verifyCommunityMembership(sender, address(this)),
        "Not community member"
    );

    // 2. 检查 Reputation（可选）
    uint256 reputation = ISBT(SBT_ADDRESS).getCommunityReputation(sender, address(this));
    require(reputation >= MIN_REPUTATION, "Low reputation");

    // 3. 记录活跃度（不影响验证）
    try ISBT(SBT_ADDRESS).recordActivity(sender) {} catch {}

    // 4. 原有验证逻辑
    // ...

    return (context, validationData);
}
```

### Phase 5: 主网部署（Week 7-8）

**Pre-deployment 清单**：
- [ ] 代码审计（可选）
- [ ] 测试网完整测试（至少1周）
- [ ] 文档完善
- [ ] 社区公告

**部署清单**：
- [ ] 多签部署合约
- [ ] 验证合约
- [ ] 配置参数
- [ ] Registry 集成
- [ ] 前端上线
- [ ] 监控配置

---

## 测试方案

### 单元测试

```solidity
// MySBT_v2.1.t.sol
contract MySBTTest is Test {
    MySBT public sbt;
    MockRegistry public registry;
    MockGTokenStaking public staking;

    function setUp() public {
        // 部署 mock 合约
        // 初始化测试环境
    }

    function test_MintNewSBT() public {
        // 测试首次 mint
    }

    function test_IdempotentMint() public {
        // 测试幂等性
    }

    function test_RegistryPermission() public {
        // 测试 Registry 权限
    }

    function test_NFTBinding() public {
        // 测试 NFT 绑定
    }

    function test_ReputationCalculation() public {
        // 测试 Reputation 计算
    }

    function test_AvatarPriority() public {
        // 测试头像优先级
    }

    function test_SoulBound() public {
        // 测试不可转移
    }
}
```

### 集成测试

```typescript
// e2e/sbt-flow.spec.ts
describe('SBT Complete Flow', () => {
  it('should mint SBT for new user', async () => {
    // 社区为用户 mint
  });

  it('should add multiple communities', async () => {
    // 多个社区添加成员资格
  });

  it('should bind NFT and update reputation', async () => {
    // 绑定 NFT，验证 reputation 提升
  });

  it('should set custom avatar', async () => {
    // 设置自定义头像
  });

  it('should record activity via Paymaster', async () => {
    // 通过 Paymaster 记录活跃
  });
});
```

### 压力测试

```typescript
// stress-test/batch-mint.ts
async function testBatchMint() {
  const users = generateRandomUsers(1000);

  for (const user of users) {
    await sbt.mintOrAddMembership(user, metadata);
  }

  // 验证：无 gas 超限，无状态错误
}
```

---

## 部署清单

### Sepolia Testnet

| 合约 | 地址 | 验证 | 状态 |
|------|------|------|------|
| MySBT v2.1 | TBD | ⏳ | 待部署 |
| DefaultReputationCalculator | TBD | ⏳ | 待部署 |
| DAO Multisig (Gnosis Safe) | TBD | ⏳ | 待创建 |

### Mainnet

| 合约 | 地址 | 验证 | 状态 |
|------|------|------|------|
| MySBT v2.1 | TBD | ⏳ | 待部署 |
| DefaultReputationCalculator | TBD | ⏳ | 待部署 |
| DAO Multisig | TBD | ⏳ | 待创建 |

### 环境变量配置

```bash
# .env.sepolia
VITE_MYSBT_ADDRESS=0x...
VITE_REPUTATION_CALCULATOR_ADDRESS=0x...
VITE_DAO_MULTISIG_ADDRESS=0x...

# 依赖合约
VITE_GTOKEN_ADDRESS=0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35
VITE_GTOKEN_STAKING_ADDRESS=0xc3aa5816B000004F790e1f6B9C65f4dd5520c7b2
VITE_REGISTRY_V2_1_ADDRESS=0x3F7E822C7FD54dBF8df29C6EC48E08Ce8AcEBeb3
```

---

## 常见问题（FAQ）

### Q1: 为什么不用工厂合约？

**A**: 白板架构下，所有用户共享一个 MySBT 合约。工厂合约会让每个社区部署独立 SBT，导致用户拥有多个 SBT（泛滥）。

### Q2: 社区如何验证用户身份？

**A**: 调用 `verifyCommunityMembership(user, community)` 验证基础成员资格，或使用 `getCommunityReputation(user, community)` 获取增强验证（包含 NFT 和活跃度）。

### Q3: 用户如何退出社区？

**A**: 目前版本不支持主动退出（成员资格设为 inactive 需要社区操作）。未来版本可添加 `leaveCommunity()` 函数。

### Q4: Reputation 计算可以升级吗？

**A**: 可以！通过 `setReputationCalculator()` 更换外部计算器合约，无需更改主合约。

### Q5: NFT 绑定后可以解绑吗？

**A**: 可以，调用 `unbindNFT()` 函数（需要实现解绑逻辑）。托管模式会返还 NFT，非托管模式仅删除记录。

### Q6: DAO 多签由谁控制？

**A**: 初始由项目方设置，后续可转移给社区 DAO。建议使用 Gnosis Safe 3/5 或 5/7 多签。

---

## 联系与贡献

- **GitHub**: [AAStarCommunity/SuperPaymaster](https://github.com/AAStarCommunity/SuperPaymaster)
- **文档**: `/docs/MySBT_v2.1_Design.md`
- **测试**: `/contracts/test/MySBT_v2.1.t.sol`

---

**License**: MIT
