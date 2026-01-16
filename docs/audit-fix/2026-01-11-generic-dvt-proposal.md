# Generic DVT Proposal 方案

> **创建日期**: 2026-01-11  
> **版本**: 1.0  
> **目标**: 将 BLSAggregator 从"硬编码专用执行器"升级为"通用 Proposal 执行器"

---

## 1. 问题分析

### 1.1 当前限制

当前 `BLSAggregator.verifyAndExecute()` 存在以下硬编码限制：

```solidity
// contracts/src/modules/monitoring/BLSAggregator.sol:122-148
function verifyAndExecute(
    uint256 proposalId,
    address operator,
    uint8 slashLevel,           // ← 硬编码参数
    address[] calldata repUsers, // ← 硬编码参数
    uint256[] calldata newScores,
    uint256 epoch,
    bytes calldata proof
) external nonReentrant {
    // ...
    bytes32 expectedMessageHash = keccak256(abi.encode(
        proposalId, operator, slashLevel, repUsers, newScores, epoch, block.chainid
    )); // ← 硬编码 Hash 结构
    
    // ...
    REGISTRY.batchUpdateGlobalReputation(...); // ← 硬编码执行路径
    _executeSlash(...);                         // ← 硬编码执行路径
}
```

**问题**：如果要新增 `UpdatePrice` 或 `UpdateConfig` 类型的 Proposal，必须修改并重新部署 BLSAggregator。

---

## 2. 解决方案

### 2.1 设计原则

1. **保持兼容性**：保留现有 `verifyAndExecute()` 用于 Slash/Reputation
2. **新增通用接口**：添加 `executeProposal()` 用于任意目标合约调用
3. **最小改动**：只修改 BLSAggregator，不改动 Registry

### 2.2 改动范围

| 合约 | 改动类型 | 说明 |
|------|---------|------|
| `BLSAggregator.sol` | **新增函数** | 添加 `executeProposal()` |
| `Registry.sol` | **无需改动** | 权限控制已就绪 (`isReputationSource`) |
| `SuperPaymaster.sol` | **无需改动** | 已有 `setBLSAggregator()` 授权机制 |
| 目标合约（新业务） | **按需添加** | 新 Proposal 需要目标合约有对应函数 |

---

## 3. 实施方案

### 3.1 新增 `executeProposal` 函数

```solidity
// ========================================
// Generic Proposal Execution
// ========================================

event ProposalExecuted(uint256 indexed proposalId, address indexed target, bytes32 callDataHash);
error ProposalExecutionFailed(uint256 proposalId, bytes returnData);
error InvalidTarget(address target);

/**
 * @notice Execute any proposal via BLS consensus (Generic DVT)
 * @param proposalId Unique proposal ID
 * @param target Target contract to call
 * @param callData Encoded function call (abi.encodeCall)
 * @param proof BLS aggregated signature proof
 */
function executeProposal(
    uint256 proposalId,
    address target,
    bytes calldata callData,
    bytes calldata proof
) external nonReentrant {
    // 1. Access Control
    if (msg.sender != DVT_VALIDATOR && msg.sender != owner()) {
        revert UnauthorizedCaller(msg.sender);
    }
    if (target == address(0)) revert InvalidTarget(target);
    if (executedProposals[proposalId]) revert ProposalAlreadyExecuted(proposalId);
    
    // 2. Construct Generic Message Hash
    bytes32 expectedMessageHash = keccak256(abi.encode(
        proposalId,
        target,
        keccak256(callData),  // Hash callData to save gas
        block.chainid         // Prevent cross-chain replay
    ));
    
    // 3. Verify BLS Signatures
    _checkSignatures(proposalId, proof, expectedMessageHash);
    
    // 4. Execute Call
    (bool success, bytes memory returnData) = target.call(callData);
    if (!success) revert ProposalExecutionFailed(proposalId, returnData);
    
    // 5. Mark as Executed
    executedProposals[proposalId] = true;
    if (DVT_VALIDATOR != address(0)) {
        IDVTValidator(DVT_VALIDATOR).markProposalExecuted(proposalId);
    }
    
    emit ProposalExecuted(proposalId, target, keccak256(callData));
}
```

### 3.2 新增 Proposal 的工作流

当需要支持新的 Proposal 类型（如 `UpdatePrice`）时：

```
┌────────────────────────────────────────────────────────────────┐
│  步骤 1: 在目标合约添加 DVT 专用函数                            │
├────────────────────────────────────────────────────────────────┤
│  // SuperPaymaster.sol 或 Registry.sol                         │
│  function updatePriceDVT(int256 newPrice) external {           │
│      require(msg.sender == BLS_AGGREGATOR, "Only DVT");        │
│      // ... 执行价格更新逻辑                                    │
│  }                                                             │
└────────────────────────────────────────────────────────────────┘
                             ↓
┌────────────────────────────────────────────────────────────────┐
│  步骤 2: 链下 DVT 节点达成共识                                  │
├────────────────────────────────────────────────────────────────┤
│  messageHash = keccak256(abi.encode(                           │
│      proposalId,                                               │
│      targetAddress,    // e.g. SuperPaymaster                  │
│      keccak256(callData), // abi.encodeCall(updatePriceDVT...) │
│      chainId                                                   │
│  ));                                                           │
│  // DVT 节点对 messageHash 进行 BLS 签名                        │
└────────────────────────────────────────────────────────────────┘
                             ↓
┌────────────────────────────────────────────────────────────────┐
│  步骤 3: 提交到链上执行                                         │
├────────────────────────────────────────────────────────────────┤
│  BLSAggregator.executeProposal(                                │
│      proposalId,                                               │
│      superPaymasterAddress,                                    │
│      abi.encodeCall(ISuperPaymaster.updatePriceDVT, newPrice), │
│      aggregatedProof                                           │
│  );                                                            │
└────────────────────────────────────────────────────────────────┘
```

---

## 4. 安全考量

### 4.1 权限隔离

**关键原则**：BLSAggregator 只是"中继器"，不拥有任何特权

| 目标合约 | 授权机制 | 说明 |
|---------|---------|------|
| Registry | `isReputationSource[BLSAggregator]` | 只能调用 `batchUpdateGlobalReputation` |
| SuperPaymaster | `msg.sender == BLS_AGGREGATOR` | 只能调用 `executeSlashWithBLS` |
| 新合约 | 需要显式授权 | 新函数必须检查 `msg.sender` |

### 4.2 防止滥用

```solidity
// ✅ 好的做法：目标函数有权限检查
function updatePriceDVT(int256 price) external {
    require(msg.sender == BLS_AGGREGATOR, "Only DVT");
    // ...
}

// ❌ 危险：没有权限检查
function setOwner(address newOwner) external {
    owner = newOwner; // 任何人都能调用！
}
```

### 4.3 永远不要授予 Owner 权限

```solidity
// ❌ 永远不要这样做
registry.transferOwnership(address(blsAggregator));

// ✅ 正确做法：只授予特定功能的权限
registry.setReputationSource(address(blsAggregator), true);
```

---

## 5. 验证计划

### 5.1 单元测试

```bash
# 运行现有 DVT 测试（确保兼容性）
forge test --match-contract DVTSlashTest -vvv

# 运行 BLS 相关测试
forge test --match-path "*DVT*" -vvv
```

### 5.2 新增测试用例

在 `contracts/test/v3/` 下新增 `GenericDVTProposal.t.sol`：

```solidity
function test_ExecuteProposal_Success() public {
    // 构造通用 Proposal
    bytes memory callData = abi.encodeCall(
        IMockTarget.someFunction,
        (param1, param2)
    );
    
    // 模拟 BLS 签名
    bytes memory proof = _mockBLSProof(...);
    
    // 执行
    aggregator.executeProposal(1, targetAddress, callData, proof);
    
    // 验证
    assertTrue(aggregator.executedProposals(1));
    assertEq(mockTarget.lastParam(), param1);
}

function test_ExecuteProposal_Unauthorized_Reverts() public {
    vm.prank(attacker);
    vm.expectRevert(abi.encodeWithSelector(
        BLSAggregator.UnauthorizedCaller.selector, attacker
    ));
    aggregator.executeProposal(1, target, callData, proof);
}

function test_ExecuteProposal_TargetReverts() public {
    bytes memory badCallData = abi.encodeCall(
        IMockTarget.revertingFunction,
        ()
    );
    
    vm.expectRevert(); // ProposalExecutionFailed
    aggregator.executeProposal(2, target, badCallData, proof);
}
```

---

## 6. 部署步骤

1. **修改 BLSAggregator.sol** - 添加 `executeProposal()` 函数
2. **更新版本号** - `BLSAggregator-3.2.0`
3. **编译并测试** - `forge build && forge test`
4. **部署新 Aggregator** - `forge script ...`
5. **更新关联合约** - 
   - `Registry.setReputationSource(newAggregator, true)`
   - `SuperPaymaster.setBLSAggregator(newAggregator)`
6. **禁用旧 Aggregator** - `Registry.setReputationSource(oldAggregator, false)`

---

## 7. 版本对照

| 版本 | 功能 |
|------|------|
| 3.1.4 (当前) | 硬编码 Slash + Reputation |
| 3.2.0 (目标) | + 通用 `executeProposal()` |

---

## 8. 未来扩展

有了通用 `executeProposal()` 后，可以轻松支持：

- ✅ 去中心化价格更新 (`updatePriceDVT`)
- ✅ 去中心化配置修改 (`updateConfigDVT`)
- ✅ 去中心化紧急暂停 (`pauseDVT`)
- ✅ 跨合约联动操作
