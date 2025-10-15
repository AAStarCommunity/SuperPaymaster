# Phase 2 统一开发计划 - 运营者自助服务 + Paymaster 管理

## 🎯 Phase 2 目标

**核心目标**: 通过 Web 界面完成 Paymaster 的创建、配置、Stake、注册和管理

**应用**: `registry` 项目

**组成部分**:
1. **原始计划**: 运营者自助服务 (Operator Portal)
2. **新增功能**: Paymaster Deactivate 管理

---

## 📋 完整用户流程

### 主流程: Operator Portal

```
社区运营者访问 https://superpaymaster.aastar.io/operator
│
├─ Step 0: 选择模式
│   ├─ 🆕 新建 Paymaster → 进入 Step 1
│   └─ 📋 管理已有 Paymaster → 跳转 Step 5
│
├─ Step 1: 部署 PaymasterV4 合约
│   ├─ 连接 MetaMask (自动成为 Owner)
│   ├─ 填写配置表单
│   │   ├─ Community Name
│   │   ├─ Treasury Address (建议多签)
│   │   ├─ Gas to USD Rate (18 decimals, e.g., 4500e18 = $4500/ETH)
│   │   ├─ PNT Price USD (18 decimals, e.g., 0.02e18 = $0.02)
│   │   ├─ Service Fee Rate (basis points, 200 = 2%, max 1000 = 10%)
│   │   ├─ Max Gas Cost Cap (wei)
│   │   ├─ Min Token Balance (wei)
│   │   └─ Network (Sepolia)
│   ├─ 点击 "Deploy Paymaster"
│   ├─ 确认 MetaMask 交易 (~0.02 ETH gas)
│   └─ ✅ 获得 Paymaster 地址
│
├─ Step 2: 配置 Paymaster
│   ├─ 2.1 设置 SBT
│   │   ├─ 选项 A: 使用现有 SBT 合约
│   │   └─ 选项 B: 部署新 SBT (使用工厂合约)
│   ├─ 2.2 设置 Gas Token (PNT)
│   │   ├─ 选项 A: 使用现有 PNT 合约
│   │   └─ 选项 B: 部署新 PNT (使用 GasTokenFactoryV2)
│   ├─ 2.3 关联到 Paymaster
│   │   ├─ Call: paymaster.addSBT(sbtAddress)
│   │   └─ Call: paymaster.addGasToken(pntAddress)
│   └─ ✅ 配置完成
│
├─ Step 3: Stake 到 EntryPoint
│   ├─ 3.1 选择 EntryPoint 版本 (v0.7)
│   ├─ 3.2 存入 ETH
│   │   ├─ 输入金额 (建议 ≥ 0.1 ETH)
│   │   ├─ Call: entryPoint.depositTo{value}(paymaster)
│   │   └─ ✅ 查看余额
│   ├─ 3.3 Stake ETH (可选,增强信用)
│   │   ├─ 输入金额 (建议 ≥ 0.05 ETH)
│   │   ├─ Call: entryPoint.addStake{value}(unstakeDelay)
│   │   └─ ✅ 查看 Stake 状态
│   └─ 💡 提示: 至少需要 Deposit,Stake 可选
│
├─ Step 4: Stake GToken 并注册到 Registry
│   ├─ 4.1 获取 GToken
│   │   ├─ 测试网: Faucet 领取 (20 GToken)
│   │   └─ 主网: Uniswap 购买
│   ├─ 4.2 Approve GToken
│   │   ├─ Call: gToken.approve(registry, amount)
│   │   └─ 最小: 10 GToken
│   ├─ 4.3 Stake & Register
│   │   ├─ Call: registry.registerPaymaster(
│   │   │   paymaster,
│   │   │   gTokenAmount,
│   │   │   metadata
│   │   │ )
│   │   └─ ✅ 注册成功
│   └─ 🎉 Paymaster 现在已上线!
│
└─ Step 5: 管理 Paymaster (新增 Deactivate 功能)
    ├─ 5.1 查看状态
    │   ├─ EntryPoint Deposit 余额
    │   ├─ EntryPoint Stake 状态
    │   ├─ GToken Stake 金额
    │   ├─ Registry 激活状态 (Active/Inactive)
    │   └─ Treasury 累计收入
    │
    ├─ 5.2 调整参数
    │   ├─ Treasury (setTreasury)
    │   ├─ Gas to USD Rate (setGasToUSDRate)
    │   ├─ PNT Price USD (setPntPriceUSD)
    │   ├─ Service Fee Rate (setServiceFeeRate, max 10%)
    │   ├─ Max Gas Cost Cap (setMaxGasCostCap)
    │   ├─ Min Token Balance (setMinTokenBalance)
    │   ├─ Add/Remove SBT (addSBT/removeSBT)
    │   └─ Add/Remove GasToken (addGasToken/removeGasToken)
    │
    ├─ 5.3 暂停/恢复服务
    │   ├─ Pause (pause)
    │   └─ Unpause (unpause)
    │
    └─ 5.4 Registry 管理 (新增功能)
        ├─ **Deactivate from Registry** 🔴
        │   ├─ 说明: 停止接受新请求,但继续结算和 unstake
        │   ├─ 前置条件: Paymaster 已注册且 Active
        │   ├─ 操作: 调用 PaymasterV4_1.deactivateFromRegistry()
        │   └─ 结果: Registry 状态变为 Inactive
        │
        ├─ **完整退出流程** (Deactivate 后)
        │   ├─ 1. 等待所有交易结算完成
        │   ├─ 2. unstake() - 解锁质押
        │   ├─ 3. withdrawStake() - 提取 ETH
        │   └─ 4. 完全退出协议
        │
        └─ ⚠️ 注意: Activate 由 Registry 控制,需验证资格
```

---

## 🔧 技术实现

### 1. 合约层 (SuperPaymaster 仓库)

#### 1.1 新增合约: PaymasterV4_1.sol

**文件**: `contracts/src/v3/PaymasterV4_1.sol`

**基础**: 继承 PaymasterV4.sol,添加 Registry 管理功能

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PaymasterV4 } from "./PaymasterV4.sol";
import { ISuperPaymasterRegistry } from "../interfaces/ISuperPaymasterRegistry.sol";

/// @title PaymasterV4_1
/// @notice PaymasterV4 with Registry management capabilities
/// @dev Adds deactivateFromRegistry() for Paymaster lifecycle management
contract PaymasterV4_1 is PaymasterV4 {
    
    /// @notice SuperPaymaster Registry contract
    ISuperPaymasterRegistry public registry;
    
    /// @notice Registry has been updated
    event RegistryUpdated(address indexed registry);
    
    /// @notice Paymaster deactivated from Registry
    event DeactivatedFromRegistry(address indexed paymaster);
    
    /// @notice Registry not set
    error PaymasterV4_1__RegistryNotSet();
    
    constructor(
        IEntryPoint _entryPoint,
        address _owner,
        address _treasury,
        uint256 _gasToUSDRate,
        uint256 _pntPriceUSD,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _minTokenBalance
    ) PaymasterV4(
        _entryPoint,
        _owner,
        _treasury,
        _gasToUSDRate,
        _pntPriceUSD,
        _serviceFeeRate,
        _maxGasCostCap,
        _minTokenBalance
    ) {}
    
    /// @notice Set Registry contract address
    /// @param _registry Address of SuperPaymasterRegistry
    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert PaymasterV4__ZeroAddress();
        registry = ISuperPaymasterRegistry(_registry);
        emit RegistryUpdated(_registry);
    }
    
    /// @notice Deactivate this Paymaster from Registry
    /// @dev Only owner can call
    /// @dev Deactivate = stop accepting new requests, continue settlement & unstake
    /// @dev Complete exit: settlement → unstake → withdrawStake
    function deactivateFromRegistry() external onlyOwner {
        if (address(registry) == address(0)) {
            revert PaymasterV4_1__RegistryNotSet();
        }
        
        // Paymaster contract calls Registry.deactivate()
        // msg.sender will be this Paymaster address
        // Registry sets isActive = false
        registry.deactivate();
        
        emit DeactivatedFromRegistry(address(this));
    }
    
    /// @notice Get contract version
    function version() external pure returns (string memory) {
        return "PaymasterV4.1-Registry-v1.1.0";
    }
}
```

#### 1.2 更新接口: ISuperPaymasterRegistry.sol

**已完成**: 添加了 `deactivate()` 和 `activate()` 函数签名

```solidity
function deactivate() external;
function activate() external;
```

#### 1.3 部署脚本

**文件**: `contracts/script/DeployPaymasterV4_1.s.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import { PaymasterV4_1 } from "../src/v3/PaymasterV4_1.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract DeployPaymasterV4_1 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address entryPoint = vm.envAddress("ENTRY_POINT_V07");
        address owner = vm.envAddress("DEPLOYER_ADDRESS");
        address treasury = vm.envAddress("DEPLOYER_ADDRESS"); // 可自定义
        
        // Default values
        uint256 gasToUSDRate = 4500e18;        // $4500/ETH
        uint256 pntPriceUSD = 0.02e18;         // $0.02/PNT
        uint256 serviceFeeRate = 200;          // 2%
        uint256 maxGasCostCap = 0.1 ether;     // 0.1 ETH
        uint256 minTokenBalance = 100e18;      // 100 PNT
        
        vm.startBroadcast(deployerPrivateKey);
        
        PaymasterV4_1 paymaster = new PaymasterV4_1(
            IEntryPoint(entryPoint),
            owner,
            treasury,
            gasToUSDRate,
            pntPriceUSD,
            serviceFeeRate,
            maxGasCostCap,
            minTokenBalance
        );
        
        console.log("PaymasterV4_1 deployed at:", address(paymaster));
        console.log("Version:", paymaster.version());
        
        vm.stopBroadcast();
    }
}
```

---

### 2. 前端层 (registry 仓库)

#### 2.1 页面结构

```
registry/src/pages/
├── operator/
│   ├── OperatorPortal.tsx          # 主入口
│   ├── DeployPaymaster.tsx         # Step 1: 部署
│   ├── ConfigurePaymaster.tsx      # Step 2: 配置
│   ├── StakeEntryPoint.tsx         # Step 3: Stake
│   ├── RegisterToRegistry.tsx      # Step 4: 注册
│   └── ManagePaymaster.tsx         # Step 5: 管理 (含 Deactivate)
```

#### 2.2 核心组件: ManagePaymaster.tsx

```tsx
import { useState, useEffect } from 'react';
import { ethers } from 'ethers';

const PAYMASTER_V4_1_ABI = [
  'function owner() view returns (address)',
  'function registry() view returns (address)',
  'function setRegistry(address) external',
  'function deactivateFromRegistry() external',
  'function treasury() view returns (address)',
  'function setTreasury(address) external',
  // ... 其他管理函数
];

const REGISTRY_ABI = [
  'function paymasters(address) view returns (address,string,uint256,uint256,uint256,bool,uint256,uint256,uint256,uint256)',
  'function isPaymasterActive(address) view returns (bool)',
];

export function ManagePaymaster({ paymasterAddress }: { paymasterAddress: string }) {
  const [isOwner, setIsOwner] = useState(false);
  const [isActive, setIsActive] = useState(false);
  const [registrySet, setRegistrySet] = useState(false);
  const [loading, setLoading] = useState(false);
  
  // 检查 owner 和 Registry 状态
  useEffect(() => {
    async function checkOwnership() {
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const userAddress = await signer.getAddress();
      
      const paymaster = new ethers.Contract(
        paymasterAddress,
        PAYMASTER_V4_1_ABI,
        provider
      );
      
      const owner = await paymaster.owner();
      setIsOwner(owner.toLowerCase() === userAddress.toLowerCase());
      
      // 检查 Registry 是否已设置
      const registryAddr = await paymaster.registry();
      setRegistrySet(registryAddr !== ethers.ZeroAddress);
      
      // 检查 Registry 中的激活状态
      if (registryAddr !== ethers.ZeroAddress) {
        const registry = new ethers.Contract(
          registryAddr,
          REGISTRY_ABI,
          provider
        );
        const active = await registry.isPaymasterActive(paymasterAddress);
        setIsActive(active);
      }
    }
    
    checkOwnership();
  }, [paymasterAddress]);
  
  // 设置 Registry
  async function handleSetRegistry() {
    try {
      setLoading(true);
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const paymaster = new ethers.Contract(
        paymasterAddress,
        PAYMASTER_V4_1_ABI,
        signer
      );
      
      const registryAddress = import.meta.env.VITE_REGISTRY_ADDRESS;
      const tx = await paymaster.setRegistry(registryAddress);
      await tx.wait();
      
      alert('✅ Registry 设置成功!');
      setRegistrySet(true);
    } catch (error: any) {
      console.error('Set Registry failed:', error);
      alert('❌ 设置失败: ' + error.message);
    } finally {
      setLoading(false);
    }
  }
  
  // Deactivate from Registry
  async function handleDeactivate() {
    if (!confirm('确认要 Deactivate 此 Paymaster 吗?\n\n这将停止接受新请求,但会继续处理现有交易的结算。')) {
      return;
    }
    
    try {
      setLoading(true);
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const paymaster = new ethers.Contract(
        paymasterAddress,
        PAYMASTER_V4_1_ABI,
        signer
      );
      
      const tx = await paymaster.deactivateFromRegistry();
      await tx.wait();
      
      alert('✅ Paymaster 已 Deactivate!\n\n状态: 停止接受新请求\n继续: 交易结算和 unstake 流程');
      setIsActive(false);
    } catch (error: any) {
      console.error('Deactivate failed:', error);
      alert('❌ Deactivate 失败: ' + error.message);
    } finally {
      setLoading(false);
    }
  }
  
  if (!isOwner) {
    return (
      <div className="alert alert-warning">
        ⚠️ 您不是此 Paymaster 的 Owner,无法管理
      </div>
    );
  }
  
  return (
    <div className="manage-paymaster">
      <h2>管理 Paymaster</h2>
      
      <div className="status-section">
        <h3>状态</h3>
        <div className="status-item">
          <span>Registry 设置:</span>
          <span>{registrySet ? '✅ 已设置' : '⚠️ 未设置'}</span>
        </div>
        <div className="status-item">
          <span>激活状态:</span>
          <span>{isActive ? '🟢 Active' : '🔴 Inactive'}</span>
        </div>
      </div>
      
      <div className="actions-section">
        <h3>Registry 管理</h3>
        
        {!registrySet && (
          <button 
            onClick={handleSetRegistry}
            disabled={loading}
            className="btn btn-primary"
          >
            {loading ? '设置中...' : '🔗 设置 Registry'}
          </button>
        )}
        
        {registrySet && isActive && (
          <button 
            onClick={handleDeactivate}
            disabled={loading}
            className="btn btn-danger"
          >
            {loading ? '处理中...' : '🔴 Deactivate from Registry'}
          </button>
        )}
        
        {registrySet && !isActive && (
          <div className="alert alert-info">
            ℹ️ Paymaster 已 Deactivate
            
            <h4>完整退出流程:</h4>
            <ol>
              <li>✅ Deactivate (已完成)</li>
              <li>⏳ 等待所有交易结算完成</li>
              <li>⏳ unstake() - 解锁质押</li>
              <li>⏳ withdrawStake() - 提取 ETH</li>
            </ol>
            
            <p>
              <strong>注意</strong>: Reactivate 由 Registry 控制,需满足:
            </p>
            <ul>
              <li>Stake ≥ 最低要求</li>
              <li>Reputation 达标</li>
              <li>其他资格条件</li>
            </ul>
          </div>
        )}
      </div>
      
      {/* 其他管理功能: Treasury, Gas Rate, etc. */}
    </div>
  );
}
```

---

## 📊 开发任务清单

### Task 1: 合约开发 (3-4 hours)

- [ ] 1.1 创建 PaymasterV4_1.sol (继承 PaymasterV4)
- [ ] 1.2 添加 `setRegistry()` 函数
- [ ] 1.3 添加 `deactivateFromRegistry()` 函数
- [ ] 1.4 添加 events 和 errors
- [ ] 1.5 更新 ISuperPaymasterRegistry.sol (已完成 ✅)
- [ ] 1.6 编写单元测试
- [ ] 1.7 本地测试通过

### Task 2: 部署脚本 (1 hour)

- [ ] 2.1 创建 DeployPaymasterV4_1.s.sol
- [ ] 2.2 测试部署脚本
- [ ] 2.3 部署到 Sepolia
- [ ] 2.4 验证合约

### Task 3: Operator Portal 前端 (6-8 hours)

- [ ] 3.1 创建 OperatorPortal.tsx 主入口
- [ ] 3.2 Step 1: DeployPaymaster.tsx
- [ ] 3.3 Step 2: ConfigurePaymaster.tsx
- [ ] 3.4 Step 3: StakeEntryPoint.tsx
- [ ] 3.5 Step 4: RegisterToRegistry.tsx
- [ ] 3.6 Step 5: ManagePaymaster.tsx (含 Deactivate)
- [ ] 3.7 添加路由和导航
- [ ] 3.8 UI/UX 优化

### Task 4: E2E 测试 (2-3 hours)

- [ ] 4.1 测试完整部署流程
- [ ] 4.2 测试 Deactivate 功能
- [ ] 4.3 测试错误处理
- [ ] 4.4 测试权限控制

### Task 5: 文档 (1 hour)

- [ ] 5.1 更新 Operator Guide
- [ ] 5.2 创建 Deactivate 使用文档
- [ ] 5.3 更新 README

---

## ⏱️ 时间估算

| 任务 | 预计时间 |
|------|---------|
| 合约开发和测试 | 3-4 hours |
| 部署脚本 | 1 hour |
| Operator Portal 前端 | 6-8 hours |
| E2E 测试 | 2-3 hours |
| 文档 | 1 hour |
| **总计** | **13-17 hours** |

---

## 🎯 验收标准

### 合约功能
- ✅ PaymasterV4_1 成功部署
- ✅ Owner 可以设置 Registry
- ✅ Owner 可以调用 deactivateFromRegistry()
- ✅ 非 owner 无法调用
- ✅ Registry 状态正确更新
- ✅ 所有测试通过

### 前端功能
- ✅ Operator Portal 5 个步骤完整实现
- ✅ Deactivate 按钮仅 owner 可见
- ✅ Deactivate 功能正常工作
- ✅ 错误处理完善
- ✅ UI 清晰易用

### 文档
- ✅ 用户指南完整
- ✅ 代码注释清晰
- ✅ 部署记录详细

---

**优先级**: 🔴 高  
**预计完成**: 2-3 天  
**开始时间**: 2025-10-15

---

## 📝 注意事项

1. **合约版本管理**: PaymasterV4.sol 保持不变,所有新功能在 PaymasterV4_1.sol 实现
2. **向后兼容**: 旧的 PaymasterV4 继续可用,不受影响
3. **Deactivate 语义**: 停止新请求,继续结算和 unstake,不是完全退出
4. **Activate 控制**: 由 Registry 控制,需验证资格,Paymaster owner 不能自主 activate
5. **测试优先**: 所有功能必须有测试覆盖
