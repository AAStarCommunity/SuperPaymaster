# Paymaster Deactivate 功能需求

## 📋 问题描述

### Deactivate 生命周期说明

**Deactivate 的含义**:
- ✅ 停止接受新的 gas 支付请求
- ✅ 继续处理已有交易的结算流程
- ✅ 继续完成 unstake 流程
- ❌ **不是**完全退出协议

**完整退出流程**:
```
Active Paymaster
  ↓
deactivate() → isActive = false (停止接受新请求)
  ↓
等待所有关联交易结算完成
  ↓
unstake() → 解锁质押
  ↓
withdrawStake() → 完全退出协议
```

### 当前状况

Registry v1.2 提供了 `deactivate()` 函数供 Paymaster 停用自己:

```solidity
// SuperPaymasterRegistry_v1_2.sol
function deactivate() external {
    PaymasterInfo storage pm = paymasters[msg.sender];
    if (pm.paymasterAddress == address(0)) {
        revert SuperPaymasterRegistry__PaymasterNotRegistered();
    }
    
    pm.isActive = false;
    
    emit PaymasterDeactivated(msg.sender);
}
```

**核心问题**: `msg.sender` 必须是 Paymaster 合约地址本身。

### 当前 Paymaster V4 的限制

Paymaster V4 合约目前**没有**提供任何函数让 owner 调用 Registry 的 `deactivate()`:

```solidity
// PaymasterV4.sol - 当前 owner 可调用的函数
function setTreasury(address _treasury) external onlyOwner;
function setGasToUSDRate(uint256 _gasToUSDRate) external onlyOwner;
function setPntPriceUSD(uint256 _pntPriceUSD) external onlyOwner;
// ... 其他配置函数

// ❌ 没有这个函数:
// function deactivateFromRegistry() external onlyOwner;
```

### 影响

- **无法停用的 Paymasters**: 当前有 6 个零交易的 Paymaster 无法被 owner 停用
- **资源浪费**: 这些 Paymaster 仍在 `getActivePaymasters()` 列表中
- **用户体验**: Registry 前端显示无用的 Paymaster

#### 受影响的 Paymasters

```
#0: 0x9091a98e43966cDa2677350CCc41efF9cedeff4c (0 交易)
#1: 0x19afE5Ad8E5C6A1b16e3aCb545193041f61aB648 (0 交易)
#2: 0x798Dfe9E38a75D3c5fdE53FFf29f966C7635f88F (0 交易)
#3: 0xC0C85a8B3703ad24DeD8207dcBca0104B9B27F02 (0 交易)
#4: 0x11bfab68f8eAB4Cd3dAa598955782b01cf9dC875 (0 交易)
#5: 0x17fe4D317D780b0d257a1a62E848Badea094ed97 (0 交易)

Owner: 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA (OWNER2_ADDRESS)
```

---

## ✅ 解决方案

### 方案 1: 添加 Paymaster 合约函数 (推荐)

#### 1.1 合约改动

在 `PaymasterV4.sol` 中添加:

```solidity
// 导入 Registry 接口
import { ISuperPaymasterRegistry } from "../interfaces/ISuperPaymasterRegistry.sol";

contract PaymasterV4 is Ownable, ReentrancyGuard {
    // 添加 Registry 地址存储
    ISuperPaymasterRegistry public registry;
    
    // 构造函数或 setter 设置 Registry
    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert PaymasterV4__ZeroAddress();
        registry = ISuperPaymasterRegistry(_registry);
        emit RegistryUpdated(_registry);
    }
    
    /// @notice Deactivate this Paymaster from Registry
    /// @dev Only owner can call, Paymaster will call Registry.deactivate()
    /// @dev Deactivate = stop accepting new requests, but continue settlement & unstake process
    /// @dev Complete exit requires: settlement of all pending txs → unstake → full withdrawal
    function deactivateFromRegistry() external onlyOwner {
        if (address(registry) == address(0)) {
            revert PaymasterV4__RegistryNotSet();
        }
        
        // Paymaster 合约调用 Registry.deactivate()
        // msg.sender 将是 Paymaster 地址
        // Registry 将 isActive 设置为 false
        registry.deactivate();
        
        emit DeactivatedFromRegistry(address(this));
    }
    
    // ❌ 不添加 activateInRegistry()
    // Activation 由 Registry 合约控制，需验证:
    // 1. Stake 是否满足最低要求
    // 2. Reputation 是否达标
    // 3. 其他资格条件
    // Paymaster owner 不能自主 activate
    
    // 新增 events
    event RegistryUpdated(address indexed registry);
    event DeactivatedFromRegistry(address indexed paymaster);
    event ActivatedInRegistry(address indexed paymaster);
    
    // 新增 error
    error PaymasterV4__RegistryNotSet();
}
```

#### 1.2 前端 UI 改动

在 Registry 管理页面添加 Deactivate/Activate 按钮:

**文件**: `registry/src/pages/PaymasterManagement.tsx`

```tsx
import { ethers } from 'ethers';

const PAYMASTER_ABI = [
  'function owner() view returns (address)',
  'function deactivateFromRegistry()',
  'function activateInRegistry()',
  'function registry() view returns (address)',
];

function PaymasterManagementCard({ paymaster }: { paymaster: PaymasterInfo }) {
  const { address, isActive } = paymaster;
  const [isOwner, setIsOwner] = useState(false);
  const [loading, setLoading] = useState(false);
  
  // 检查当前用户是否是 owner
  useEffect(() => {
    async function checkOwner() {
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const userAddress = await signer.getAddress();
      
      const contract = new ethers.Contract(address, PAYMASTER_ABI, provider);
      const owner = await contract.owner();
      
      setIsOwner(owner.toLowerCase() === userAddress.toLowerCase());
    }
    checkOwner();
  }, [address]);
  
  // Deactivate 函数
  async function handleDeactivate() {
    try {
      setLoading(true);
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      
      const contract = new ethers.Contract(address, PAYMASTER_ABI, signer);
      
      // 调用 Paymaster 的 deactivateFromRegistry()
      const tx = await contract.deactivateFromRegistry();
      await tx.wait();
      
      alert('✅ Paymaster deactivated successfully!');
      // 刷新页面
      window.location.reload();
    } catch (error) {
      console.error('Deactivate failed:', error);
      alert('❌ Deactivate failed: ' + error.message);
    } finally {
      setLoading(false);
    }
  }
  
  // Activate 函数
  async function handleActivate() {
    // 类似实现...
  }
  
  return (
    <div className="paymaster-card">
      <h3>{address}</h3>
      <p>Status: {isActive ? '✅ Active' : '⚠️ Inactive'}</p>
      
      {isOwner && (
        <div className="owner-actions">
          {isActive ? (
            <button 
              onClick={handleDeactivate} 
              disabled={loading}
              className="btn-danger"
            >
              {loading ? 'Processing...' : '🔴 Deactivate'}
            </button>
          ) : (
            <button 
              onClick={handleActivate} 
              disabled={loading}
              className="btn-success"
            >
              {loading ? 'Processing...' : '🟢 Activate'}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
```

---

### 方案 2: 通用 Execute 函数 (更灵活)

为 Paymaster 添加通用的合约调用能力:

```solidity
/// @notice Execute arbitrary contract call (owner only)
/// @dev Allows owner to make Paymaster call any contract
function execute(
    address target,
    uint256 value,
    bytes calldata data
) external onlyOwner returns (bytes memory) {
    (bool success, bytes memory result) = target.call{value: value}(data);
    require(success, "Execute failed");
    return result;
}
```

**使用示例**:

```typescript
// 前端调用
const paymasterContract = new ethers.Contract(paymasterAddress, ABI, signer);

// 构造 Registry.deactivate() 的 calldata
const registryInterface = new ethers.Interface(['function deactivate()']);
const calldata = registryInterface.encodeFunctionData('deactivate');

// 通过 Paymaster 的 execute() 调用 Registry.deactivate()
await paymasterContract.execute(
  registryAddress,
  0, // value
  calldata
);
```

**优势**:
- ✅ 更通用,未来可用于其他合约调用
- ✅ 无需为每个功能添加专门函数

**劣势**:
- ⚠️ 安全风险更高,需要仔细审计
- ⚠️ 前端调用更复杂

---

## 🎯 推荐实现方案

### 短期 (推荐方案 1)

1. **合约升级**: 
   - 部署新的 PaymasterV4.1,添加 `deactivateFromRegistry()` 和 `activateInRegistry()`
   - 为现有 Paymaster 添加 `setRegistry()` 配置

2. **前端开发**:
   - Registry 管理页面添加 Deactivate/Activate 按钮
   - 仅对 Paymaster owner 显示

3. **使用流程**:
   ```
   Owner 访问 Registry 管理页面
     → 连接钱包
     → 系统检测是否是 Paymaster owner
     → 显示 Deactivate/Activate 按钮
     → 点击按钮 → 调用 Paymaster.deactivateFromRegistry()
     → Paymaster 调用 Registry.deactivate()
     → 状态更新
   ```

### 长期 (可选方案 2)

考虑为 PaymasterV5 添加通用 `execute()` 函数,提供更大灵活性。

---

## 📊 影响评估

### 合约改动

- **文件**: `contracts/src/v3/PaymasterV4.sol`
- **新增代码**: ~50 行
- **Gas 影响**: 
  - `setRegistry()`: ~45,000 gas (一次性)
  - `deactivateFromRegistry()`: ~55,000 gas
  - `activateInRegistry()`: ~55,000 gas

### 前端改动

- **文件**: `registry/src/pages/PaymasterManagement.tsx`
- **新增代码**: ~100 行
- **UI 组件**: 新增 Deactivate/Activate 按钮

### 测试需求

1. **合约测试**:
   - ✅ Owner 可成功调用 `deactivateFromRegistry()`
   - ✅ 非 owner 无法调用
   - ✅ Registry 未设置时报错
   - ✅ 状态正确更新

2. **前端测试**:
   - ✅ 仅 owner 看到按钮
   - ✅ 交易成功提示
   - ✅ 交易失败错误处理
   - ✅ 状态实时更新

---

## 📝 待办事项

### Phase 1: 合约开发

- [ ] 在 `PaymasterV4.sol` 添加 Registry 相关函数
- [ ] 添加必要的 events 和 errors
- [ ] 编写单元测试
- [ ] 部署到 Sepolia 测试网
- [ ] 为现有 Paymaster 调用 `setRegistry()`

### Phase 2: 前端开发

- [ ] 创建 `PaymasterManagement.tsx` 页面
- [ ] 实现 owner 检测逻辑
- [ ] 添加 Deactivate/Activate 按钮
- [ ] 错误处理和用户提示
- [ ] UI/UX 测试

### Phase 3: 部署和迁移

- [ ] 更新 6 个无交易 Paymaster 的 Registry 配置
- [ ] 逐个测试 deactivate 功能
- [ ] 更新文档
- [ ] 发布新版本

---

## 🔗 相关文件

- **合约**: `SuperPaymaster/contracts/src/v3/PaymasterV4.sol`
- **Registry**: `SuperPaymaster/contracts/src/SuperPaymasterRegistry_v1_2.sol`
- **前端**: `registry/src/pages/PaymasterManagement.tsx`
- **脚本**: `scripts/deactivate-paymasters.ts` (临时方案,废弃)

---

## 📅 时间估计

- **合约开发**: 2-3 小时
- **测试**: 1-2 小时
- **前端开发**: 3-4 小时
- **部署和迁移**: 1-2 小时
- **总计**: 7-11 小时

---

**优先级**: 🔴 高 (影响 Registry 数据质量和用户体验)

**创建时间**: 2025-10-15  
**创建人**: Claude AI Assistant
