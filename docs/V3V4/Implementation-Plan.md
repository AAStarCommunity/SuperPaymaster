# SuperPaymaster V3.0 Implementation Plan

**目标**: 基于 Pimlico SingletonPaymaster 重构，实现无需链下签名、基于 SBT+PNT 的链上 Gas 赞助方案

**开发策略**: V7 先行 → 测试验证 → V8 迁移

---

## 📋 项目背景

### 核心改造需求
1. **去除链下签名依赖** - 无需 Pimlico API 签名，链上直接验证资格
2. **SBT 资格验证** - 用户必须持有指定 SBT（Soul-Bound Token）
3. **PNT 余额检查** - 用户账户需有足够 PNT（ERC20）余额
4. **延迟批量结算** - postOp 仅记账，通过结算合约异步批量扣款
5. **自定义 Token** - 支持配置任意 ERC20 作为 Gas Token

### 技术收益
- **Gas 优化**: 批量结算可节省 50%+ gas（相比实时 ERC20 转账）
- **去中心化**: 无需中心化 API，完全链上验证
- **灵活性**: 支持自定义 SBT + ERC20 组合

---

## 🎯 Phase 1: V7 版本重构（当前阶段）

### 目标
在 SingletonPaymasterV7 基础上实现核心功能，充分测试后再迁移到 V8

### Timeline
**预计 2-3 周**
- Week 1: 合约开发 + 单元测试
- Week 2: 集成测试 + Sepolia 部署
- Week 3: Dashboard 集成 + 端到端测试

---

## 📦 阶段一：V7 核心合约开发

### Task 1.1: 准备工作环境
**时间**: 1 天  
**负责人**: Developer  
**输出**: 开发环境就绪

- [x] 克隆 singleton-paymaster 到本地
- [ ] 创建新分支 `feat/superpaymaster-v3-v7`
- [ ] 安装依赖并验证编译通过
- [ ] 配置 Foundry 测试环境

**验收标准**:
```bash
forge build
forge test
# 所有原始测试通过
```

---

### Task 1.2: 接口定义
**时间**: 1 天  
**负责人**: Developer  
**输出**: 合约接口文件

#### 新增文件

**1. `src/interfaces/ISBT.sol`**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISBT {
    /// @notice Check if an address holds at least one SBT
    /// @param account Address to check
    /// @return True if account holds SBT
    function balanceOf(address account) external view returns (uint256);
}
```

**2. `src/interfaces/ISettlement.sol`**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISettlement {
    /// @notice Record gas fee for a user
    /// @param user User address
    /// @param token ERC20 token address
    /// @param amount Fee amount in token
    function recordGasFee(
        address user,
        address token,
        uint256 amount
    ) external;
    
    /// @notice Get pending balance for a user
    function getPendingBalance(
        address user,
        address token
    ) external view returns (uint256);
}
```

**3. `src/interfaces/ISuperPaymasterV3.sol`**
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ISuperPaymasterV3 {
    // Events
    event SBTUpdated(address indexed oldSBT, address indexed newSBT);
    event TokenUpdated(address indexed oldToken, address indexed newToken);
    event SettlementUpdated(address indexed oldSettlement, address indexed newSettlement);
    event GasSponsored(address indexed user, uint256 amount, address token);
    event GasRecorded(address indexed user, uint256 amount, address token);
    
    // Configuration
    function setSBTContract(address _sbt) external;
    function setGasToken(address _token) external;
    function setSettlementContract(address _settlement) external;
    
    // View functions
    function sbtContract() external view returns (address);
    function gasToken() external view returns (address);
    function settlementContract() external view returns (address);
}
```

**验收标准**: 所有接口文件编译通过

---

### Task 1.3: SuperPaymasterV7 合约重构
**时间**: 3-4 天  
**负责人**: Developer  
**输出**: 核心 Paymaster 合约

#### 修改文件: `src/SuperPaymasterV7.sol`

**核心改动点**:

1. **移除签名验证逻辑**
```solidity
// 删除原有的 _validateSignature() 相关代码
// 删除 paymasterAndData 中的签名字段解析
```

2. **新增配置参数**
```solidity
contract SuperPaymasterV7 {
    address public sbtContract;      // SBT 合约地址
    address public gasToken;         // Gas Token (PNT) 地址
    address public settlementContract; // 结算合约地址
    uint256 public minTokenBalance;  // 最小 Token 余额要求
    
    constructor(
        address _entryPoint,
        address _sbt,
        address _token,
        address _settlement,
        uint256 _minBalance
    ) {
        // 初始化逻辑
    }
}
```

3. **重写 validatePaymasterUserOp**
```solidity
function _validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) internal override returns (bytes memory context, uint256 validationData) {
    address sender = userOp.sender;
    
    // 1. 检查 SBT 持有
    require(
        ISBT(sbtContract).balanceOf(sender) > 0,
        "SuperPaymaster: No SBT"
    );
    
    // 2. 检查 Token 余额
    uint256 balance = IERC20(gasToken).balanceOf(sender);
    require(
        balance >= minTokenBalance,
        "SuperPaymaster: Insufficient token balance"
    );
    
    // 3. 估算费用（用于后续记账）
    uint256 estimatedFee = maxCost; // 简化版，实际需计算
    
    // 4. 编码 context 用于 postOp
    context = abi.encode(sender, gasToken, estimatedFee);
    
    // 5. 返回验证通过
    validationData = 0; // 0 表示验证成功
}
```

4. **重写 postOp 记账逻辑**
```solidity
function _postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 actualUserOpFeePerGas
) internal override {
    // 解码 context
    (address user, address token, uint256 estimatedFee) = 
        abi.decode(context, (address, address, uint256));
    
    // 计算实际费用（根据实际 gas 消耗）
    uint256 actualFee = actualGasCost; // 简化版
    
    // 调用结算合约记账
    ISettlement(settlementContract).recordGasFee(
        user,
        token,
        actualFee
    );
    
    emit GasRecorded(user, actualFee, token);
}
```

**验收标准**:
- 合约编译通过
- 移除所有签名相关代码
- SBT 和 Token 验证逻辑完整
- postOp 正确调用结算合约

---

### Task 1.4: Settlement 结算合约开发
**时间**: 2-3 天  
**负责人**: Developer  
**输出**: 结算合约

#### 新增文件: `src/Settlement.sol`

**核心功能**:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Settlement is Ownable {
    // 用户 => Token => 欠费金额
    mapping(address => mapping(address => uint256)) public pendingFees;
    
    // 累计欠费总额
    mapping(address => uint256) public totalPending;
    
    // 授权的 Paymaster 合约
    mapping(address => bool) public authorizedPaymasters;
    
    // 批量结算阈值
    uint256 public settlementThreshold = 100 ether;
    
    // Events
    event FeeRecorded(address indexed user, address indexed token, uint256 amount);
    event FeesSettled(address indexed user, address indexed token, uint256 amount);
    event PaymasterAuthorized(address indexed paymaster, bool status);
    
    constructor(address initialOwner) Ownable(initialOwner) {}
    
    /// @notice Record gas fee (only callable by authorized Paymaster)
    function recordGasFee(
        address user,
        address token,
        uint256 amount
    ) external onlyAuthorizedPaymaster {
        pendingFees[user][token] += amount;
        totalPending[token] += amount;
        
        emit FeeRecorded(user, token, amount);
    }
    
    /// @notice Batch settle fees (callable by keeper/owner)
    function settleFees(
        address[] calldata users,
        address token,
        address treasury
    ) external onlyOwner {
        uint256 totalSettled = 0;
        
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 pending = pendingFees[user][token];
            
            if (pending > 0) {
                // Transfer from user to treasury
                IERC20(token).transferFrom(user, treasury, pending);
                
                totalSettled += pending;
                pendingFees[user][token] = 0;
                
                emit FeesSettled(user, token, pending);
            }
        }
        
        totalPending[token] -= totalSettled;
    }
    
    /// @notice Authorize Paymaster contract
    function setPaymasterAuthorization(address paymaster, bool status) 
        external 
        onlyOwner 
    {
        authorizedPaymasters[paymaster] = status;
        emit PaymasterAuthorized(paymaster, status);
    }
    
    /// @notice Get pending balance
    function getPendingBalance(address user, address token) 
        external 
        view 
        returns (uint256) 
    {
        return pendingFees[user][token];
    }
    
    modifier onlyAuthorizedPaymaster() {
        require(
            authorizedPaymasters[msg.sender],
            "Settlement: Not authorized paymaster"
        );
        _;
    }
}
```

**验收标准**:
- 记账功能正常
- 批量结算逻辑完整
- 权限控制到位
- 事件正确触发

---

### Task 1.5: 单元测试开发
**时间**: 3 天  
**负责人**: Developer  
**输出**: 完整测试套件

#### 新增文件: `test/SuperPaymasterV7.t.sol`

**测试用例**:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {SuperPaymasterV7} from "../src/SuperPaymasterV7.sol";
import {Settlement} from "../src/Settlement.sol";
import {MockSBT} from "./mocks/MockSBT.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract SuperPaymasterV7Test is Test {
    SuperPaymasterV7 paymaster;
    Settlement settlement;
    MockSBT sbt;
    MockERC20 pnt;
    
    address user = address(0x123);
    address treasury = address(0x456);
    
    function setUp() public {
        // Deploy mocks
        sbt = new MockSBT();
        pnt = new MockERC20("PNT", "PNT");
        
        // Deploy settlement
        settlement = new Settlement(address(this));
        
        // Deploy paymaster
        paymaster = new SuperPaymasterV7(
            ENTRYPOINT_V07,
            address(sbt),
            address(pnt),
            address(settlement),
            100 ether // minTokenBalance
        );
        
        // Authorize paymaster
        settlement.setPaymasterAuthorization(address(paymaster), true);
        
        // Mint SBT and tokens to user
        sbt.mint(user, 1);
        pnt.mint(user, 1000 ether);
    }
    
    function test_ValidateWithSBTAndBalance() public {
        // Test validation passes when user has SBT and sufficient balance
    }
    
    function test_RevertWhenNoSBT() public {
        // Test validation fails when user has no SBT
    }
    
    function test_RevertWhenInsufficientBalance() public {
        // Test validation fails when token balance too low
    }
    
    function test_PostOpRecordsGasFee() public {
        // Test postOp correctly records fee in settlement contract
    }
    
    function test_BatchSettlement() public {
        // Test batch settlement transfers tokens correctly
    }
}
```

**测试覆盖率要求**: > 90%

**验收标准**:
```bash
forge test -vvv
# 所有测试通过
forge coverage
# 覆盖率 > 90%
```

---

### Task 1.6: Sepolia 测试网部署
**时间**: 2 天  
**负责人**: Developer  
**输出**: 测试网合约地址

#### 部署脚本: `script/DeploySuperPaymasterV7.s.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {SuperPaymasterV7} from "../src/SuperPaymasterV7.sol";
import {Settlement} from "../src/Settlement.sol";

contract DeploySuperPaymasterV7 is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy Settlement
        Settlement settlement = new Settlement(deployer);
        console.log("Settlement deployed:", address(settlement));
        
        // 2. Deploy SuperPaymasterV7
        SuperPaymasterV7 paymaster = new SuperPaymasterV7(
            0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789, // EntryPoint V0.7 Sepolia
            vm.envAddress("SBT_CONTRACT_ADDRESS"),
            vm.envAddress("PNT_CONTRACT_ADDRESS"),
            address(settlement),
            vm.envUint("MIN_TOKEN_BALANCE")
        );
        console.log("SuperPaymasterV7 deployed:", address(paymaster));
        
        // 3. Authorize Paymaster
        settlement.setPaymasterAuthorization(address(paymaster), true);
        
        vm.stopBroadcast();
    }
}
```

**部署步骤**:
1. 准备环境变量（.env）
2. 运行部署脚本
3. 验证合约（Etherscan）
4. 记录合约地址

**验收标准**:
- Sepolia 上成功部署
- Etherscan 验证通过
- 合约地址记录在文档中

---

### Task 1.7: Dashboard 集成
**时间**: 3 天  
**负责人**: Frontend Developer  
**输出**: Dashboard 支持 V3 合约

#### 功能清单

1. **部署 SuperPaymaster V7**
   - 表单输入：SBT 地址、PNT 地址、最小余额
   - 自动部署 Settlement + Paymaster
   - 显示部署地址

2. **管理界面**
   - 配置 SBT 合约
   - 配置 Gas Token
   - 设置最小余额要求
   - 查看结算合约状态

3. **监控面板**
   - 查看 Pending Fees
   - 批量结算操作
   - 事件日志查看

**验收标准**:
- Dashboard 可正常部署 V7 合约
- 所有配置项可编辑
- 实时显示合约状态

---

## 📦 阶段二：V8 迁移升级

### 前置条件
- ✅ V7 版本所有测试通过
- ✅ Sepolia 测试网运行稳定 > 1 周
- ✅ 至少完成 100 笔真实交易测试

### Task 2.1: V8 合约适配
**时间**: 2 天  
**负责人**: Developer  

**主要改动**:
1. 升级到 EntryPoint V0.8
2. 适配 EIP-7702 delegation 支持
3. 更新 PackedUserOperation 结构

### Task 2.2: 测试迁移
**时间**: 1 天  
**负责人**: Developer  

- 复制 V7 测试用例
- 适配 V8 EntryPoint
- 验证所有测试通过

### Task 2.3: 部署和验证
**时间**: 1 天  
**负责人**: Developer  

- Sepolia 部署 V8 版本
- 对比测试 V7 vs V8
- 性能和 Gas 对比

---

## 🎯 里程碑和交付物

### Milestone 1: V7 开发完成 (Week 2)
- [ ] 所有合约代码完成
- [ ] 单元测试覆盖率 > 90%
- [ ] 本地测试全部通过

### Milestone 2: V7 测试网部署 (Week 2)
- [ ] Sepolia 成功部署
- [ ] Etherscan 验证
- [ ] 集成测试通过

### Milestone 3: Dashboard 集成 (Week 3)
- [ ] 前端集成完成
- [ ] 端到端测试通过
- [ ] 用户文档完成

### Milestone 4: V8 迁移完成 (Week 4)
- [ ] V8 合约开发完成
- [ ] V8 测试网部署
- [ ] 性能对比报告

---

## 📊 风险评估与应对

### 风险 1: SBT 合约接口不统一
**影响**: 高  
**概率**: 中  
**应对**: 
- 设计通用 ISBT 接口
- 支持多种 SBT 标准（ERC721, ERC1155）
- 提供 Adapter 模式

### 风险 2: 结算合约 Gas 成本过高
**影响**: 高  
**概率**: 中  
**应对**:
- 优化 mapping 结构
- 使用 Gas 高效的数据结构
- 批量结算时合并操作

### 风险 3: EntryPoint V0.8 兼容性问题
**影响**: 中  
**概率**: 低  
**应对**:
- 先完成 V7 稳定版本
- 充分测试后再迁移
- 保持 V7 和 V8 并行维护

---

## 📚 参考资料

- [Pimlico SingletonPaymaster](https://github.com/pimlicolabs/singleton-paymaster)
- [ERC-4337 Specification](https://eips.ethereum.org/EIPS/eip-4337)
- [EntryPoint V0.7 Docs](https://docs.alchemy.com/reference/eth-sendUserOperation-v07)
- [Singleton-Analysis.md](./Singleton-Analysis.md)

---

## 👥 团队分工

| 角色 | 职责 | 工作量 |
|------|------|--------|
| Smart Contract Developer | V7/V8 合约开发 | 70% |
| Frontend Developer | Dashboard 集成 | 20% |
| QA Engineer | 测试和验证 | 10% |

---

## 📅 时间表总览

```
Week 1: 合约开发 + 单元测试
├── Day 1-2: 接口定义 + 环境准备
├── Day 3-4: SuperPaymasterV7 重构
└── Day 5-7: Settlement 合约 + 测试

Week 2: 集成测试 + Sepolia 部署
├── Day 8-9: 集成测试开发
├── Day 10-11: Sepolia 部署
└── Day 12-14: 端到端测试

Week 3: Dashboard 集成
├── Day 15-17: 前端开发
├── Day 18-19: UI/UX 测试
└── Day 20-21: 文档编写

Week 4: V8 迁移（可选）
├── Day 22-23: V8 合约适配
├── Day 24: 测试迁移
└── Day 25: 部署和验证
```

---

## ✅ 验收标准

### 功能验收
- [ ] 用户持有 SBT 才能获得 Gas 赞助
- [ ] PNT 余额低于阈值时拒绝赞助
- [ ] postOp 正确记账到 Settlement 合约
- [ ] 批量结算功能正常工作
- [ ] 支持自定义 SBT 和 Token 配置

### 性能验收
- [ ] 单笔 UserOp gas 消耗 < 50k（记账模式）
- [ ] 批量结算 gas 节省 > 50%（对比实时转账）
- [ ] Dashboard 响应时间 < 2s

### 安全验收
- [ ] 无已知安全漏洞
- [ ] 通过 Slither 静态分析
- [ ] 关键函数有 reentrancy guard
- [ ] 权限控制完整

---

**文档版本**: v1.0  
**创建日期**: 2025-01-05  
**负责人**: Jason  
**状态**: Planning → Development
