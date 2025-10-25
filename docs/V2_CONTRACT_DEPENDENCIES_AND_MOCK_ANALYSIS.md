# V2 合约依赖关系和 Mock 使用分析

**日期**: 2025-10-25
**作者**: Claude Code
**目的**: 分析 V2 系统合约依赖关系、GToken 引用方式、Mock 代码使用情况及影响评估

---

## 目录

1. [合约依赖关系图](#合约依赖关系图)
2. [Constructor 参数分析](#constructor-参数分析)
3. [GToken 引用方式详解](#gtoken-引用方式详解)
4. [Mock 代码使用情况](#mock-代码使用情况)
5. [影响评估](#影响评估)
6. [迁移策略](#迁移策略)

---

## 合约依赖关系图

### 核心依赖树

```
GToken (ERC20) - 生产 Governance Token
    │
    ├── GTokenStaking (constructor: address _gtoken)
    │       │
    │       ├── Registry (constructor: address _gtokenStaking)
    │       │       │
    │       │       └── xPNTsFactory (constructor: address _superPaymaster, address _registry)
    │       │
    │       ├── SuperPaymasterV2 (constructor: address _gtokenStaking, address _registry)
    │       │       │
    │       │       ├── DVTValidator (constructor: address _superPaymaster)
    │       │       │       │
    │       │       │       └── BLSAggregator (constructor: address _superPaymaster, address _dvtValidator)
    │       │       │
    │       │       └── xPNTsFactory (共享引用)
    │       │
    │       └── MySBT (constructor: address _gtoken, address _staking)
    │               │
    │               └── MySBTFactory (constructor: address _gtoken, address _staking)
    │
    └── EntryPoint v0.7 (外部合约: 0x0000000071727De22E5E9d8BAf0edAc6f37da032)
```

### 依赖关系矩阵

| 合约 | 直接依赖 | 间接依赖 | 可变性 |
|------|---------|---------|--------|
| **GToken** | - | - | ✅ 独立 |
| **GTokenStaking** | GToken | - | ❌ Immutable (constructor) |
| **Registry** | GTokenStaking | GToken | ❌ Immutable (constructor) |
| **SuperPaymasterV2** | GTokenStaking, Registry | GToken | ❌ Immutable (constructor) |
| **MySBT** | GToken, GTokenStaking | - | ❌ Immutable (constructor) |
| **MySBTFactory** | GToken, GTokenStaking | - | ❌ Immutable (constructor) |
| **xPNTsFactory** | SuperPaymasterV2, Registry | GToken, GTokenStaking | ❌ Immutable (constructor) |
| **DVTValidator** | SuperPaymasterV2 | GToken, GTokenStaking, Registry | ❌ Immutable (constructor) |
| **BLSAggregator** | SuperPaymasterV2, DVTValidator | GToken, GTokenStaking, Registry | ❌ Immutable (constructor) |

### 初始化连接（Setter Functions）

部署后需要调用的初始化函数：

```solidity
// Step 1: MySBT → SuperPaymaster
mysbt.setSuperPaymaster(address(superPaymaster));

// Step 2: SuperPaymaster → DVT Aggregator
superPaymaster.setDVTAggregator(address(blsAggregator));

// Step 3: SuperPaymaster → EntryPoint
superPaymaster.setEntryPoint(ENTRYPOINT_V07);

// Step 4: DVTValidator → BLS Aggregator
dvtValidator.setBLSAggregator(address(blsAggregator));

// Step 5: GTokenStaking → Treasury
gtokenStaking.setTreasury(treasuryAddress);

// Step 6: Configure Lockers (MySBT, SuperPaymaster)
gtokenStaking.configureLocker(address(mysbt), ...);
gtokenStaking.configureLocker(address(superPaymaster), ...);

// Step 7: Authorize Slashers
gtokenStaking.authorizeSlasher(address(superPaymaster), true);
gtokenStaking.authorizeSlasher(address(registry), true);
```

---

## Constructor 参数分析

### 1. GTokenStaking

```solidity
// src/paymasters/v2/core/GTokenStaking.sol:197
constructor(address _gtoken) Ownable(msg.sender) {
    if (_gtoken == address(0)) revert InvalidAddress(_gtoken);
    GTOKEN = _gtoken;  // ❌ IMMUTABLE - 部署后无法修改
}
```

**参数**:
- `_gtoken`: GToken ERC20 合约地址

**不可变性**:
- `GTOKEN` 是 `immutable` 变量
- 部署后无法修改，必须重新部署才能更换 GToken

**影响**:
- ✅ **新部署**: 使用生产 GToken (0x868F8...)
- ❌ **旧部署**: 使用 MockERC20 (0x54Afca...) - **必须废弃**

---

### 2. MySBT

```solidity
// src/paymasters/v2/tokens/MySBT.sol:162
constructor(address _gtoken, address _staking)
    ERC721("MySBT", "MySBT")
    Ownable(msg.sender)
{
    if (_gtoken == address(0) || _staking == address(0)) {
        revert InvalidAddress(address(0));
    }

    GTOKEN = _gtoken;          // ❌ IMMUTABLE
    GTOKEN_STAKING = _staking; // ❌ IMMUTABLE
    creator = msg.sender;
}
```

**参数**:
- `_gtoken`: GToken ERC20 合约地址
- `_staking`: GTokenStaking 合约地址

**不可变性**:
- `GTOKEN` 和 `GTOKEN_STAKING` 都是 `immutable`
- 依赖两个不可变地址

**影响**:
- ✅ **新部署**: 引用生产 GToken + 新 GTokenStaking
- ❌ **旧部署**: 引用 MockERC20 + 旧 GTokenStaking - **必须废弃**

---

### 3. SuperPaymasterV2

```solidity
// src/paymasters/v2/core/SuperPaymasterV2.sol:254
constructor(
    address _gtokenStaking,
    address _registry
) Ownable(msg.sender) {
    if (_gtokenStaking == address(0) || _registry == address(0)) {
        revert InvalidAddress(address(0));
    }

    GTOKEN_STAKING = _gtokenStaking; // ❌ IMMUTABLE
    REGISTRY = _registry;            // ❌ IMMUTABLE
    superPaymasterTreasury = msg.sender;
}
```

**参数**:
- `_gtokenStaking`: GTokenStaking 合约地址
- `_registry`: Registry 合约地址

**不可变性**:
- `GTOKEN_STAKING` 和 `REGISTRY` 都是 `immutable`
- 间接依赖 GToken（通过 GTokenStaking）

**影响**:
- ✅ **新部署**: 引用新 GTokenStaking（使用生产 GToken）
- ❌ **旧部署**: 引用旧 GTokenStaking（使用 MockERC20） - **必须废弃**

---

### 4. Registry

```solidity
// src/paymasters/v2/core/Registry.sol:184
constructor(address _gtokenStaking) Ownable(msg.sender) {
    if (_gtokenStaking == address(0)) {
        revert InvalidAddress(_gtokenStaking);
    }

    GTOKEN_STAKING = _gtokenStaking; // ❌ IMMUTABLE
}
```

**参数**:
- `_gtokenStaking`: GTokenStaking 合约地址

**不可变性**:
- `GTOKEN_STAKING` 是 `immutable`
- 间接依赖 GToken

**影响**:
- ✅ **新部署**: 引用新 GTokenStaking
- ❌ **旧部署**: 引用旧 GTokenStaking - **必须废弃**

---

### 5. xPNTsFactory

```solidity
// src/paymasters/v2/tokens/xPNTsFactory.sol:111
constructor(address _superPaymaster, address _registry) Ownable(msg.sender) {
    if (_superPaymaster == address(0) || _registry == address(0)) {
        revert InvalidAddress(address(0));
    }

    SUPER_PAYMASTER = _superPaymaster; // ❌ IMMUTABLE
    REGISTRY = _registry;              // ❌ IMMUTABLE
}
```

**参数**:
- `_superPaymaster`: SuperPaymasterV2 合约地址
- `_registry`: Registry 合约地址

**不可变性**:
- `SUPER_PAYMASTER` 和 `REGISTRY` 都是 `immutable`
- 间接依赖 GToken（通过 SuperPaymaster → GTokenStaking）

**影响**:
- ✅ **新部署**: 引用新 SuperPaymaster 和 Registry
- ❌ **旧部署**: 引用旧合约 - **必须废弃**

---

### 6. DVTValidator

```solidity
// src/paymasters/v2/monitoring/DVTValidator.sol:167
constructor(address _superPaymaster) Ownable(msg.sender) {
    if (_superPaymaster == address(0)) {
        revert InvalidAddress(_superPaymaster);
    }

    SUPER_PAYMASTER = _superPaymaster; // ❌ IMMUTABLE
}
```

**参数**:
- `_superPaymaster`: SuperPaymasterV2 合约地址

**不可变性**:
- `SUPER_PAYMASTER` 是 `immutable`

**影响**:
- ✅ **新部署**: 引用新 SuperPaymaster
- ❌ **旧部署**: 引用旧 SuperPaymaster - **必须废弃**

---

### 7. BLSAggregator

```solidity
// src/paymasters/v2/monitoring/BLSAggregator.sol:133
constructor(
    address _superPaymaster,
    address _dvtValidator
) Ownable(msg.sender) {
    if (_superPaymaster == address(0) || _dvtValidator == address(0)) {
        revert InvalidAddress(address(0));
    }

    SUPER_PAYMASTER = _superPaymaster; // ❌ IMMUTABLE
    DVT_VALIDATOR = _dvtValidator;     // ❌ IMMUTABLE
}
```

**参数**:
- `_superPaymaster`: SuperPaymasterV2 合约地址
- `_dvtValidator`: DVTValidator 合约地址

**不可变性**:
- `SUPER_PAYMASTER` 和 `DVT_VALIDATOR` 都是 `immutable`

**影响**:
- ✅ **新部署**: 引用新 SuperPaymaster 和 DVTValidator
- ❌ **旧部署**: 引用旧合约 - **必须废弃**

---

## GToken 引用方式详解

### 直接引用 GToken 的合约

1. **GTokenStaking** (src/paymasters/v2/core/GTokenStaking.sol)
   ```solidity
   address public immutable GTOKEN;  // Line 83

   constructor(address _gtoken) Ownable(msg.sender) {
       GTOKEN = _gtoken;  // 不可变，部署时设置
   }

   // 使用示例
   function stake(uint256 amount) external {
       IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), amount);
       // ...
   }
   ```

2. **MySBT** (src/paymasters/v2/tokens/MySBT.sol)
   ```solidity
   address public immutable GTOKEN;          // Line 105
   address public immutable GTOKEN_STAKING;  // Line 106

   constructor(address _gtoken, address _staking) {
       GTOKEN = _gtoken;
       GTOKEN_STAKING = _staking;
   }

   // 使用示例：mint SBT 需要销毁 GToken
   function mintSBT(address community) external returns (uint256, uint256) {
       IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), mintFee);
       IERC20(GTOKEN).burn(mintFee);  // 销毁 mint fee
       // ...
   }
   ```

3. **MySBTFactory** (src/paymasters/v2/tokens/MySBTFactory.sol)
   ```solidity
   address public immutable GTOKEN;
   address public immutable GTOKEN_STAKING;

   constructor(address _gtoken, address _staking) {
       GTOKEN = _gtoken;
       GTOKEN_STAKING = _staking;
   }

   // 部署新 MySBT 时传递 GToken
   function deploySBT() external returns (address) {
       MySBTWithNFTBinding newSBT = new MySBTWithNFTBinding(GTOKEN, GTOKEN_STAKING);
       return address(newSBT);
   }
   ```

### 间接引用 GToken 的合约

1. **SuperPaymasterV2** (间接通过 GTokenStaking)
   ```solidity
   address public immutable GTOKEN_STAKING;

   // 读取 operator 的 stGToken 余额
   function checkOperatorStake(address operator) internal view {
       uint256 stakedAmount = IGTokenStaking(GTOKEN_STAKING).balanceOf(operator);
       require(stakedAmount >= minOperatorStake, "Insufficient stake");
   }
   ```

2. **Registry** (间接通过 GTokenStaking)
   ```solidity
   address public immutable GTOKEN_STAKING;

   // 社区注册时检查 stGToken
   function registerCommunity(string memory name) external {
       uint256 balance = IGTokenStaking(GTOKEN_STAKING).balanceOf(msg.sender);
       // ...
   }
   ```

3. **xPNTsFactory** (间接通过 SuperPaymaster 和 Registry)
   ```solidity
   address public immutable SUPER_PAYMASTER;
   address public immutable REGISTRY;

   // 通过 SuperPaymaster 间接访问 GTokenStaking
   // 通过 Registry 间接访问 GTokenStaking
   ```

### 为什么旧部署无法修复？

**关键问题**: 所有 GToken 地址都是通过 `immutable` 变量存储的

```solidity
// ❌ 无法修改
address public immutable GTOKEN;

// ✅ 如果是这样就可以修改（但实际不是）
address public GTOKEN;
function updateGToken(address newGToken) external onlyOwner {
    GTOKEN = newGToken;
}
```

**Solidity Immutable 变量特性**:
- `immutable` 变量只能在 constructor 中赋值
- 部署后无法修改（写入合约 bytecode）
- Gas 优化：读取 immutable 比 storage 便宜

**影响链**:
```
MockERC20 (旧 GToken)
    │
    └── GTokenStaking (immutable GTOKEN = MockERC20) ❌
            │
            ├── MySBT (immutable GTOKEN = MockERC20) ❌
            │
            ├── SuperPaymasterV2 (immutable GTOKEN_STAKING) ❌
            │       │
            │       └── DVTValidator, BLSAggregator ❌
            │
            └── Registry (immutable GTOKEN_STAKING) ❌
                    │
                    └── xPNTsFactory ❌
```

**结论**:
- ✅ **唯一解决方案**: 重新部署整个 V2 系统
- ❌ **无法修复**: 旧部署的合约无法更新 GToken 引用
- ⚠️ **必须废弃**: 所有旧 V2 合约都必须停用

---

## Mock 代码使用情况

### 1. Mock 合约定义

#### 1.1 MockERC20 (contracts/test/mocks/MockERC20.sol)

```solidity
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    // ⚠️ 无 cap() 函数 - 无供应上限
    // ⚠️ 无 owner() 函数 - 无访问控制

    function mint(address to, uint256 amount) external {
        // ❌ 任何人都可以调用 - 极不安全
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}
```

**安全问题**:
- ❌ 无供应上限控制（没有 `cap()` 函数）
- ❌ 无访问权限控制（没有 `owner()` 或 Ownable）
- ❌ 任何人可以调用 `mint()` - 可以铸造无限代币
- ❌ 缺少 ERC20 标准事件（`Transfer`, `Approval`）
- ⚠️ **仅用于测试** - 禁止在 Sepolia/Mainnet 使用

#### 1.2 MockUSDT (src/mocks/MockUSDT.sol)

```solidity
contract MockUSDT is ERC20, Ownable {
    constructor() ERC20("Mock USDT", "USDT") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return 6;  // 模拟真实 USDT 的 6 位小数
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
```

**用途**:
- ✅ 仅用于测试
- ✅ 有 `onlyOwner` 限制
- ✅ 继承 OpenZeppelin ERC20 - 安全

#### 1.3 MockSBT (contracts/test/mocks/MockSBT.sol)

```solidity
contract MockSBT is ISBT {
    string public name = "Mock Soul-Bound Token";
    string public symbol = "MSBT";

    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 tokenId) external {
        require(to != address(0), "MockSBT: mint to zero address");
        require(_balances[to] == 0, "MockSBT: already owns SBT");
        // ...
    }
}
```

**用途**:
- ✅ 仅用于单元测试
- ✅ 不涉及生产部署

---

### 2. 部署脚本中的 Mock 使用

#### 2.1 DeploySuperPaymasterV2.s.sol

**使用位置**: script/DeploySuperPaymasterV2.s.sol:346-397

```solidity
// Line 44: Mock GToken 声明
address public GTOKEN;

// Line 111-144: GToken 部署逻辑
function _deployGToken() internal {
    console.log("Step 1: Deploying GToken (Mock)...");

    try vm.envAddress("GTOKEN_ADDRESS") returns (address existingGToken) {
        // ✅ 优先使用环境变量中的生产 GToken
        GTOKEN = existingGToken;
        console.log("Using existing GToken:", GTOKEN);

        // ✅ CRITICAL SAFETY CHECK (Phase 22 新增)
        (bool hasCapSuccess,) = GTOKEN.call(abi.encodeWithSignature("cap()"));
        (bool hasOwnerSuccess,) = GTOKEN.call(abi.encodeWithSignature("owner()"));

        require(hasCapSuccess, "SAFETY: GToken must have cap() function");
        require(hasOwnerSuccess, "SAFETY: GToken must have owner() function");

        console.log("Safety checks passed: cap() and owner() verified");
    } catch {
        // ✅ 仅在 local anvil (chainid 31337) 部署 Mock
        require(
            block.chainid == 31337,
            "SAFETY: MockERC20 can only be deployed on local anvil (chainid 31337)"
        );

        GTOKEN = address(new MockERC20("GToken", "GT", 18));
        console.log("Deployed Mock GToken (LOCAL ONLY):", GTOKEN);

        MockERC20(GTOKEN).mint(msg.sender, 1_000_000 ether);
        console.log("Minted 1,000,000 GT to deployer");
    }
}

// Line 346-397: MockERC20 定义（嵌入在脚本中）
contract MockERC20 {
    // ... (同 contracts/test/mocks/MockERC20.sol)
}
```

**安全机制** (Phase 22 改进):
1. ✅ **环境变量优先**: 必须设置 `GTOKEN_ADDRESS`
2. ✅ **合约能力验证**: 检查 `cap()` 和 `owner()` 函数
3. ✅ **网络限制**: Mock 仅允许在 chainid 31337 (local anvil)
4. ✅ **清晰日志**: 明确标记 "LOCAL ONLY"

**Phase 21 的问题** (已修复):
- ❌ 缺少环境变量检查
- ❌ 缺少合约能力验证
- ❌ 缺少网络限制（允许在 Sepolia 部署 Mock）
- ❌ 导致错误部署 MockERC20 到 Sepolia

---

#### 2.2 V2 测试脚本中的 Mock 使用

**涉及的脚本**:
- `script/v2/Step1_Setup.s.sol` - 创建 aPNTs token
- `script/v2/Step2_OperatorRegister.s.sol` - Operator 质押 GToken
- `script/v2/Step3_OperatorDeposit.s.sol` - Operator 存入 aPNTs
- `script/v2/Step4_UserPrep.s.sol` - 用户准备资金
- `script/v2/Step6_Verification.s.sol` - 验证系统
- `script/v2/TestV2FullFlow.s.sol` - 完整流程测试
- `script/v2/TestRegistryLaunchPaymaster.s.sol` - Registry 集成测试
- `script/v2/MintSBTForSimpleAccount.s.sol` - SBT mint 测试

**使用模式**:

```solidity
// 示例: Step2_OperatorRegister.s.sol:39
import "../../contracts/test/mocks/MockERC20.sol";

MockERC20 gtoken;

function run() external {
    // 从环境变量读取 GToken 地址
    gtoken = MockERC20(vm.envAddress("GTOKEN_ADDRESS"));

    // 使用 gtoken.mint() 为测试准备资金
    gtoken.mint(operatorAddress, 1000 ether);

    // Operator 质押
    gtoken.approve(address(gtokenStaking), stakeAmount);
    gtokenStaking.stake(stakeAmount);
}
```

**问题分析**:

1. **类型转换错误**:
   ```solidity
   // ❌ 错误：将生产 GToken 强制转换为 MockERC20
   gtoken = MockERC20(vm.envAddress("GTOKEN_ADDRESS"));

   // ❌ 调用 mint() 会失败（生产 GToken 没有 mint 函数）
   gtoken.mint(operatorAddress, 1000 ether);
   ```

2. **接口不兼容**:
   - 生产 GToken (Governance Token): 继承 OpenZeppelin ERC20Capped
   - MockERC20: 简化的 ERC20 实现，有 `mint()` 函数
   - 强制类型转换会导致调用不存在的函数

3. **修复建议**:
   ```solidity
   // ✅ 正确：使用 IERC20 接口
   import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

   IERC20 gtoken;

   function run() external {
       gtoken = IERC20(vm.envAddress("GTOKEN_ADDRESS"));

       // ✅ 不调用 mint()，假设 deployer 已有足够余额
       // 或通过 faucet 获取

       gtoken.approve(address(gtokenStaking), stakeAmount);
       gtokenStaking.stake(stakeAmount);
   }
   ```

---

### 3. TypeScript/Frontend 中的 Mock 使用

**搜索结果**: 未发现前端代码中直接使用 Mock 合约

**Registry 前端** (registry/):
- ✅ 使用标准 ERC20 ABI
- ✅ 通过环境变量配置合约地址
- ✅ 不依赖 Mock 合约

**Faucet 后端**:
- ✅ 直接使用生产 GToken 地址
- ✅ 未受 MockERC20 影响

---

## 影响评估

### 1. 已部署合约影响分析

#### 旧部署（使用 MockERC20）❌

| 合约 | 地址 | GToken 引用 | 状态 | 必须操作 |
|------|------|------------|------|---------|
| **GTokenStaking** | 0xc3aa5816B000004F790e1f6B9C65f4dd5520c7b2 | MockERC20 (0x54Afca...) | ❌ 不安全 | 🔴 **废弃** |
| **MySBT** | 0xB330a8A396Da67A1b50903E734750AAC81B0C711 | MockERC20 (0x54Afca...) | ❌ 不安全 | 🔴 **废弃** |
| **xPNTsFactory** | 0x356CF363E136b0880C8F48c9224A37171f375595 | 间接引用 Mock | ❌ 不安全 | 🔴 **废弃** |
| **SuperPaymasterV2** | 0xb96d8BC6d771AE5913C8656FAFf8721156AC8141 | 间接引用 Mock | ❌ 不安全 | 🔴 **废弃** |

**安全风险**:
- ❌ 任何人可以铸造无限 MockERC20
- ❌ 质押系统毫无意义（stGToken 基于可无限铸造的代币）
- ❌ 经济模型完全崩溃
- ❌ 无法转移到 multisig 治理（Mock 无 owner）

**影响范围**:
- 🔴 **所有已注册的 Operator**: 需要重新在新合约注册
- 🔴 **所有已质押的用户**: 需要迁移到新合约
- 🔴 **所有已部署的 MySBT**: 需要重新部署
- 🔴 **所有已部署的 xPNTs token**: 需要重新部署

---

#### 新部署（使用生产 GToken）✅

| 合约 | 地址 | GToken 引用 | 状态 | 操作 |
|------|------|------------|------|------|
| **GToken** | 0x868F843723a98c6EECC4BF0aF3352C53d5004147 | - | ✅ 生产级 | ✅ 保持 |
| **GTokenStaking** | 0x199402b3F213A233e89585957F86A07ED1e1cD67 | Production (0x868F8...) | ✅ 安全 | ✅ 使用 |
| **Registry V2** | 0x3ff7f71725285dB207442f51F6809e9C671E5dEb | 间接引用 Production | ✅ 安全 | ✅ 使用 |
| **SuperPaymasterV2** | 0x2bc6BC8FfAF5cDE5894FcCDEb703B18418092FcA | 间接引用 Production | ✅ 安全 | ✅ 使用 |
| **xPNTsFactory** | 0xE3461BC2D55B707D592dC6a8269eBD06b9Af85a5 | 间接引用 Production | ✅ 安全 | ✅ 使用 |
| **MySBT** | 0xd4EFD5e2aC1b2cb719f82075fAFb69921E0F8392 | Production (0x868F8...) | ✅ 安全 | ✅ 使用 |
| **DVTValidator** | 0xBb3838C6532374417C24323B4f69F76D319Ac40f | 间接引用 Production | ✅ 安全 | ✅ 使用 |
| **BLSAggregator** | 0xda2b62Ef9f6fb618d22C6D5B9961e304335Bc0Ff | 间接引用 Production | ✅ 安全 | ✅ 使用 |

**安全特性**:
- ✅ 21M 供应上限（`cap() = 21000000 ether`）
- ✅ 访问控制（`owner() = 0xe24b6f...`）
- ✅ 无法任意铸造
- ✅ 符合 ERC20Capped 标准
- ✅ 可转移到 multisig 治理

---

### 2. 用户数据迁移影响

#### 需要迁移的数据

1. **GTokenStaking**:
   - ❌ **无法自动迁移** stGToken 余额
   - 用户需要：
     1. 从旧合约 unstake（7天等待期）
     2. 在新合约重新 stake

2. **MySBT**:
   - ❌ **无法迁移** SBT tokenId
   - 用户需要：
     1. Burn 旧 SBT（0.1 stGT 费用）
     2. Mint 新 SBT（新合约）

3. **Operator 注册**:
   - ❌ **无法迁移** Operator 状态
   - Operator 需要：
     1. 从旧合约 deregister
     2. 在新合约重新 register

4. **xPNTs Token**:
   - ❌ **无法迁移** 已部署的 token
   - 社区需要：
     1. 使用新 xPNTsFactory 重新部署
     2. 迁移用户余额（需要自定义脚本）

---

### 3. 前端配置影响

#### Registry 前端

**文件**: `registry/src/config/networkConfig.ts`

**Phase 21 配置** (错误):
```typescript
gToken: "0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35", // ❌ MockERC20
gTokenStaking: "0xc3aa5816B000004F790e1f6B9C65f4dd5520c7b2",
minGTokenStake: "100", // ❌ 错误值
```

**Phase 22 配置** (修复):
```typescript
gToken: "0x868F843723a98c6EECC4BF0aF3352C53d5004147", // ✅ Governance Token
gTokenStaking: "0x199402b3F213A233e89585957F86A07ED1e1cD67",
registryV2: "0x3ff7f71725285dB207442f51F6809e9C671E5dEb",
superPaymasterV2: "0x2bc6BC8FfAF5cDE5894FcCDEb703B18418092FcA",
xPNTsFactory: "0xE3461BC2D55B707D592dC6a8269eBD06b9Af85a5",
mySBT: "0xd4EFD5e2aC1b2cb719f82075fAFb69921E0F8392",
minGTokenStake: "30", // ✅ 修正
```

**影响**:
- ✅ 前端现在显示正确的余额
- ✅ 用户可以正常获取 GToken（faucet 地址一致）
- ✅ 质押要求显示正确（30 stGT）

---

### 4. Faucet 后端影响

**状态**: ✅ **未受影响**

**原因**:
- Faucet 一直使用生产 GToken (0x868F8...)
- 未引用 MockERC20
- 配置独立于前端

**结论**:
- ✅ 无需修改
- ✅ 继续正常运行

---

## 迁移策略

### 方案 A: 完全迁移（推荐）✅

**步骤**:

1. **宣布旧合约废弃**:
   ```
   - 在前端添加醒目的迁移通知
   - 设置迁移截止日期（建议 30 天）
   - 提供迁移教程和工具
   ```

2. **用户迁移**:
   ```
   Step 1: Unstake from Old GTokenStaking
   - Call: oldStaking.requestUnstake(amount)
   - Wait: 7 days
   - Call: oldStaking.unstake()

   Step 2: Burn Old MySBT (if applicable)
   - Call: oldMySBT.burnSBT(tokenId)
   - Receive: 0.2 stGT back (minus 0.1 fee)

   Step 3: Stake to New GTokenStaking
   - Approve: gtoken.approve(newStaking, amount)
   - Stake: newStaking.stake(amount)

   Step 4: Mint New MySBT (if applicable)
   - Approve: gtoken.approve(newMySBT, mintFee)
   - Mint: newMySBT.mintSBT(community)
   ```

3. **Operator 迁移**:
   ```
   Step 1: Deregister from Old SuperPaymaster
   - Call: oldSuperPaymaster.deregisterOperator()

   Step 2: Unstake from Old GTokenStaking
   - (Same as user migration)

   Step 3: Re-stake to New GTokenStaking
   - (Same as user migration)

   Step 4: Re-register to New SuperPaymaster
   - Call: newSuperPaymaster.registerOperator(communityName, communityENS)
   - Deposit aPNTs: newSuperPaymaster.depositaPNTs(amount)
   ```

4. **社区迁移 xPNTs**:
   ```
   Step 1: 记录旧 token 的所有持有者和余额
   - Event: xPNTs.Transfer(from, to, amount)
   - 使用 Etherscan API 或 TheGraph

   Step 2: 使用新 xPNTsFactory 部署新 token
   - Call: newFactory.deployxPNTsToken(name, symbol, community, ENS)

   Step 3: Airdrop 到旧持有者
   - Call: newXPNTs.mint(holder, balance) (需要 owner 权限)
   ```

5. **前端完全切换**:
   ```
   - 移除所有旧合约地址
   - 仅显示新合约地址
   - 添加"已迁移"标记
   ```

**优点**:
- ✅ 彻底解决安全问题
- ✅ 统一用户体验
- ✅ 简化维护

**缺点**:
- ❌ 需要用户主动操作
- ❌ 7天 unstake 延迟
- ❌ 可能损失部分用户

---

### 方案 B: 双系统并行（不推荐）❌

**步骤**:

1. 保持旧合约运行（只读模式）
2. 新合约正常运行
3. 前端同时显示两个系统

**优点**:
- ✅ 用户可以选择迁移时间

**缺点**:
- ❌ 维护成本翻倍
- ❌ 用户困惑（两个版本）
- ❌ 旧合约仍有安全风险
- ❌ 无法完全解决问题

**结论**: ❌ **不推荐** - 应采用方案 A

---

### 推荐时间表

**Week 1** (2025-10-28 - 2025-11-03):
- ✅ Phase 22 完成（新合约已部署）
- 📢 发布迁移公告
- 📝 准备迁移文档和教程
- 🛠️ 开发迁移辅助工具

**Week 2-4** (2025-11-04 - 2025-11-24):
- 👥 用户主动迁移期
- 📊 跟踪迁移进度
- 💬 提供技术支持
- 🎁 考虑激励早期迁移用户（gas 补贴？）

**Week 5** (2025-11-25 - 2025-12-01):
- ⚠️ 迁移截止提醒
- 🔄 协助剩余用户迁移

**Week 6+** (2025-12-02+):
- 🔒 旧合约标记为"已废弃"
- 🚫 前端移除旧合约入口
- ✅ 完全切换到新系统

---

## 附录

### A. 完整合约地址列表

#### 生产环境（Sepolia Testnet）

**V1 系统** (保持不变):
```
Registry V1.2:      0x838da93c815a6E45Aa50429529da9106C0621eF0
PaymasterV4:        0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445
PNT Token:          0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
GasTokenFactory:    0x6720Dc8ce5021bC6F3F126054556b5d3C125101F
SBT Contract:       0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
Mock USDT:          0x14EaC6C3D49AEDff3D59773A7d7bfb50182bCfDc
```

**V2 系统 - 旧部署** (❌ 已废弃):
```
MockERC20 (假GToken): 0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35 ❌
GTokenStaking:         0xc3aa5816B000004F790e1f6B9C65f4dd5520c7b2 ❌
MySBT:                 0xB330a8A396Da67A1b50903E734750AAC81B0C711 ❌
xPNTsFactory:          0x356CF363E136b0880C8F48c9224A37171f375595 ❌
SuperPaymasterV2:      0xb96d8BC6d771AE5913C8656FAFf8721156AC8141 ❌
```

**V2 系统 - 新部署** (✅ 生产使用):
```
GToken (Governance):  0x868F843723a98c6EECC4BF0aF3352C53d5004147 ✅
GTokenStaking:        0x199402b3F213A233e89585957F86A07ED1e1cD67 ✅
Registry V2:          0x3ff7f71725285dB207442f51F6809e9C671E5dEb ✅
SuperPaymasterV2:     0x2bc6BC8FfAF5cDE5894FcCDEb703B18418092FcA ✅
xPNTsFactory:         0xE3461BC2D55B707D592dC6a8269eBD06b9Af85a5 ✅
MySBT:                0xd4EFD5e2aC1b2cb719f82075fAFb69921E0F8392 ✅
DVTValidator:         0xBb3838C6532374417C24323B4f69F76D319Ac40f ✅
BLSAggregator:        0xda2b62Ef9f6fb618d22C6D5B9961e304335Bc0Ff ✅
```

**共享合约**:
```
EntryPoint v0.7:      0x0000000071727De22E5E9d8BAf0edAc6f37da032
```

---

### B. 关键交易和事件

**新部署交易**:
- Deployer: `0x411BD567E46C0781248dbB6a9211891C032885e5`
- 部署时间: 2025-10-25
- Gas Used: 28,142,074
- 部署成本: 0.000028142327278666 ETH

**验证状态**:
- ⚠️ Etherscan 验证失败（API V2 迁移问题）
- ✅ 合约代码已公开（可手动验证）

---

### C. 参考文档

- [GTOKEN_INCIDENT_2025-10-25.md](./GTOKEN_INCIDENT_2025-10-25.md) - 事件详细报告
- [Changes.md](./Changes.md) - 项目变更历史
- [README.md](../README.md) - 项目总览

---

**文档版本**: 1.0
**最后更新**: 2025-10-25
**状态**: ✅ 已完成
