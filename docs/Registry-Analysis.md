# Registry合约分析与改进方案

## 1. 当前实现问题分析

### 1.1 Registry v2.0（src/paymasters/v2/core/Registry.sol）

#### 问题1：硬编码Minimum Stake
```solidity
// 第74-78行：硬编码constant，无法修改
uint256 public constant MIN_STAKE_AOA = 30 ether;
uint256 public constant MIN_STAKE_SUPER = 50 ether;
```

**缺陷**：
- ❌ 无法通过治理调整（constant不可变）
- ❌ 只支持2种模式（AOA/SUPER），无扩展性
- ❌ 未来增加validator/oracle等节点类型需要重新部署合约

#### 问题2：节点类型单一
```solidity
// 第26-29行：只支持Paymaster模式
enum PaymasterMode {
    INDEPENDENT,  // AOA独立模式
    SUPER         // SuperPaymaster共享模式
}
```

**缺陷**：
- ❌ 未来无法注册validator、oracle、sequencer等节点
- ❌ 枚举值无法扩展（硬编码）

#### 问题3：缺少节点类型配置
```solidity
// 注册时硬编码检查模式
if (profile.mode == PaymasterMode.INDEPENDENT) {
    if (stGTokenAmount < MIN_STAKE_AOA) {
        revert InsufficientStake(stGTokenAmount, MIN_STAKE_AOA);
    }
}
```

**问题**：
- ❌ 如何支持validator需要100 GT，oracle需要20 GT？
- ❌ 如何支持不同slash比例（paymaster 10% vs validator 30%）？

---

### 1.2 Registry v1.2（src/paymasters/registry/SuperPaymasterRegistry_v1_2.sol）

#### 优势：可配置Minimum Stake
```solidity
// 第60行：状态变量，可通过updateMinStake修改
uint256 public minStakeAmount;

// 第591-596行：治理可调整
function updateMinStake(uint256 _newMinStake) external onlyOwner {
    uint256 oldMinStake = minStakeAmount;
    minStakeAmount = _newMinStake;
    emit MinStakeUpdated(oldMinStake, _newMinStake);
}
```

#### 问题：只支持单一质押要求
```solidity
// 第198行：所有paymaster使用相同的minStakeAmount
if (msg.value < minStakeAmount) revert SuperPaymasterRegistry__InsufficientStake();
```

**缺陷**：
- ❌ 无法区分不同节点类型
- ❌ 所有注册者使用相同的最低质押要求

---

## 2. 对比总结

| 特性 | Registry v1.2 | Registry v2.0 | 理想方案 |
|------|---------------|---------------|---------|
| **Stake要求可配置** | ✅ 可调整 | ❌ 硬编码constant | ✅ 需要 |
| **多模式支持** | ❌ 单一要求 | ✅ AOA/SUPER | ✅ 需要 |
| **多节点类型** | ❌ 不支持 | ❌ 不支持 | ✅ **必需** |
| **Slash比例配置** | ❌ 固定 | ❌ 固定10% | ✅ 需要 |
| **扩展性** | ⚠️ 有限 | ❌ 枚举硬编码 | ✅ 需要 |
| **stGToken集成** | ❌ 使用ETH | ✅ 使用stGToken | ✅ 必需 |

---

## 3. 改进方案：支持多节点类型的Registry

### 3.1 核心设计：NodeType配置系统

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title RegistryV3 - 多节点类型注册系统
 * @notice 统一注册Paymaster、Validator、Oracle、Sequencer等去中心化节点
 * @dev 通过NodeType配置实现不同节点的差异化要求
 */
contract RegistryV3 is Ownable, ReentrancyGuard {

    // ====================================
    // Node Type System
    // ====================================

    /// @notice 节点类型枚举（可扩展）
    enum NodeType {
        PAYMASTER_AOA,      // 0: AOA独立Paymaster
        PAYMASTER_SUPER,    // 1: SuperPaymaster共享模式
        VALIDATOR,          // 2: 区块验证者
        ORACLE,             // 3: 价格预言机
        SEQUENCER,          // 4: 排序器
        BRIDGE_RELAYER      // 5: 跨链中继
        // 未来可添加更多类型...
    }

    /// @notice 节点类型配置
    struct NodeTypeConfig {
        bool enabled;               // 是否启用此节点类型
        uint256 minStake;           // 最低质押要求（stGToken）
        uint256 slashThreshold;     // 触发slash的失败次数
        uint256 slashPercentage;    // Slash比例（basis points）
        uint256 minRegistrationFee; // 注册费用（可选）
        string description;         // 节点类型描述
    }

    /// @notice 节点信息（替代CommunityProfile）
    struct NodeInfo {
        // 基础信息
        address nodeAddress;        // 节点地址
        NodeType nodeType;          // 节点类型
        string name;                // 节点名称
        string ensName;             // ENS域名
        string description;         // 节点描述

        // 关联资源
        address[] supportedAssets;  // 支持的资产列表（SBT/Token）
        address rewardRecipient;    // 奖励接收地址

        // 状态
        uint256 stGTokenLocked;     // 锁定的stGToken数量
        uint256 registeredAt;       // 注册时间
        uint256 lastActiveAt;       // 最后活跃时间
        bool isActive;              // 激活状态

        // 声誉
        uint256 failureCount;       // 失败次数
        uint256 totalSlashed;       // 累计slash数量
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice GTokenStaking合约
    IGTokenStaking public immutable GTOKEN_STAKING;

    /// @notice 节点类型配置：NodeType => NodeTypeConfig
    mapping(NodeType => NodeTypeConfig) public nodeTypeConfigs;

    /// @notice 注册的节点：节点地址 => NodeInfo
    mapping(address => NodeInfo) public nodes;

    /// @notice 按类型索引节点：NodeType => 节点地址列表
    mapping(NodeType => address[]) public nodesByType;

    /// @notice 按名称索引：lowercase name => 节点地址
    mapping(string => address) public nodeByName;

    /// @notice Oracle地址
    address public oracle;

    // ====================================
    // Events
    // ====================================

    event NodeTypeConfigured(
        NodeType indexed nodeType,
        uint256 minStake,
        uint256 slashThreshold,
        uint256 slashPercentage,
        bool enabled
    );

    event NodeRegistered(
        address indexed nodeAddress,
        NodeType indexed nodeType,
        string name,
        uint256 stGTokenLocked
    );

    event NodeSlashed(
        address indexed nodeAddress,
        uint256 amount,
        uint256 newStake,
        string reason
    );

    event NodeTypeChanged(
        address indexed nodeAddress,
        NodeType oldType,
        NodeType newType
    );

    // ====================================
    // Errors
    // ====================================

    error NodeTypeNotEnabled(NodeType nodeType);
    error InsufficientStake(uint256 provided, uint256 required);
    error NodeAlreadyRegistered(address nodeAddress);
    error NodeNotRegistered(address nodeAddress);
    error NameAlreadyTaken(string name);

    // ====================================
    // Constructor
    // ====================================

    constructor(address _gtokenStaking) Ownable(msg.sender) {
        require(_gtokenStaking != address(0), "Invalid staking address");
        GTOKEN_STAKING = IGTokenStaking(_gtokenStaking);

        // 初始化默认节点类型配置
        _initializeDefaultNodeTypes();
    }

    /**
     * @notice 初始化默认节点类型
     * @dev 部署时设置默认配置，后续可通过治理修改
     */
    function _initializeDefaultNodeTypes() internal {
        // Paymaster AOA: 30 GT, 10次失败, 10% slash
        nodeTypeConfigs[NodeType.PAYMASTER_AOA] = NodeTypeConfig({
            enabled: true,
            minStake: 30 ether,
            slashThreshold: 10,
            slashPercentage: 1000,  // 10% (basis points)
            minRegistrationFee: 0,
            description: "AOA Independent Paymaster"
        });

        // Paymaster Super: 50 GT, 10次失败, 10% slash
        nodeTypeConfigs[NodeType.PAYMASTER_SUPER] = NodeTypeConfig({
            enabled: true,
            minStake: 50 ether,
            slashThreshold: 10,
            slashPercentage: 1000,
            minRegistrationFee: 0,
            description: "SuperPaymaster Shared Mode"
        });

        // Validator: 100 GT, 5次失败, 30% slash
        nodeTypeConfigs[NodeType.VALIDATOR] = NodeTypeConfig({
            enabled: true,
            minStake: 100 ether,
            slashThreshold: 5,
            slashPercentage: 3000,  // 30%
            minRegistrationFee: 0,
            description: "Block Validator"
        });

        // Oracle: 20 GT, 15次失败, 5% slash
        nodeTypeConfigs[NodeType.ORACLE] = NodeTypeConfig({
            enabled: true,
            minStake: 20 ether,
            slashThreshold: 15,
            slashPercentage: 500,   // 5%
            minRegistrationFee: 0,
            description: "Price Oracle"
        });

        // Sequencer: 200 GT, 3次失败, 50% slash
        nodeTypeConfigs[NodeType.SEQUENCER] = NodeTypeConfig({
            enabled: false,  // 暂不启用
            minStake: 200 ether,
            slashThreshold: 3,
            slashPercentage: 5000,  // 50%
            minRegistrationFee: 0,
            description: "Transaction Sequencer"
        });

        // Bridge Relayer: 80 GT, 8次失败, 15% slash
        nodeTypeConfigs[NodeType.BRIDGE_RELAYER] = NodeTypeConfig({
            enabled: false,  // 暂不启用
            minStake: 80 ether,
            slashThreshold: 8,
            slashPercentage: 1500,  // 15%
            minRegistrationFee: 0,
            description: "Cross-chain Bridge Relayer"
        });
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice 配置节点类型（治理功能）
     * @param nodeType 节点类型
     * @param config 配置参数
     * @dev 只有owner可调用，实现动态调整各节点类型要求
     */
    function configureNodeType(
        NodeType nodeType,
        NodeTypeConfig calldata config
    ) external onlyOwner {
        require(config.slashPercentage <= 10000, "Invalid slash percentage");

        nodeTypeConfigs[nodeType] = config;

        emit NodeTypeConfigured(
            nodeType,
            config.minStake,
            config.slashThreshold,
            config.slashPercentage,
            config.enabled
        );
    }

    /**
     * @notice 批量配置节点类型
     * @param nodeTypes 节点类型数组
     * @param configs 配置数组
     */
    function configureNodeTypesBatch(
        NodeType[] calldata nodeTypes,
        NodeTypeConfig[] calldata configs
    ) external onlyOwner {
        require(nodeTypes.length == configs.length, "Length mismatch");

        for (uint256 i = 0; i < nodeTypes.length; i++) {
            require(configs[i].slashPercentage <= 10000, "Invalid slash percentage");
            nodeTypeConfigs[nodeTypes[i]] = configs[i];

            emit NodeTypeConfigured(
                nodeTypes[i],
                configs[i].minStake,
                configs[i].slashThreshold,
                configs[i].slashPercentage,
                configs[i].enabled
            );
        }
    }

    // ====================================
    // Registration Functions
    // ====================================

    /**
     * @notice 注册新节点
     * @param nodeType 节点类型
     * @param name 节点名称
     * @param ensName ENS域名（可选）
     * @param description 节点描述
     * @param supportedAssets 支持的资产列表
     * @param stGTokenAmount 锁定的stGToken数量
     * @dev 统一的注册入口，支持所有节点类型
     */
    function registerNode(
        NodeType nodeType,
        string calldata name,
        string calldata ensName,
        string calldata description,
        address[] calldata supportedAssets,
        uint256 stGTokenAmount
    ) external nonReentrant {
        // 1. 验证节点类型已启用
        NodeTypeConfig memory config = nodeTypeConfigs[nodeType];
        if (!config.enabled) {
            revert NodeTypeNotEnabled(nodeType);
        }

        // 2. 验证未注册
        if (nodes[msg.sender].registeredAt != 0) {
            revert NodeAlreadyRegistered(msg.sender);
        }

        // 3. 验证最低质押要求
        if (stGTokenAmount < config.minStake) {
            revert InsufficientStake(stGTokenAmount, config.minStake);
        }

        // 4. 验证名称唯一性
        string memory lowercaseName = _toLowercase(name);
        if (nodeByName[lowercaseName] != address(0)) {
            revert NameAlreadyTaken(name);
        }

        // 5. 锁定stGToken
        GTOKEN_STAKING.lockStake(
            msg.sender,
            stGTokenAmount,
            string(abi.encodePacked("Registry: ", name))
        );

        // 6. 存储节点信息
        nodes[msg.sender] = NodeInfo({
            nodeAddress: msg.sender,
            nodeType: nodeType,
            name: name,
            ensName: ensName,
            description: description,
            supportedAssets: supportedAssets,
            rewardRecipient: msg.sender,
            stGTokenLocked: stGTokenAmount,
            registeredAt: block.timestamp,
            lastActiveAt: block.timestamp,
            isActive: true,
            failureCount: 0,
            totalSlashed: 0
        });

        // 7. 更新索引
        nodesByType[nodeType].push(msg.sender);
        nodeByName[lowercaseName] = msg.sender;

        emit NodeRegistered(msg.sender, nodeType, name, stGTokenAmount);
    }

    /**
     * @notice 更改节点类型（需满足新类型的质押要求）
     * @param newNodeType 新节点类型
     * @dev 例如：Paymaster升级为Validator，需补充质押
     */
    function changeNodeType(NodeType newNodeType) external {
        NodeInfo storage node = nodes[msg.sender];
        if (node.registeredAt == 0) {
            revert NodeNotRegistered(msg.sender);
        }

        NodeTypeConfig memory newConfig = nodeTypeConfigs[newNodeType];
        if (!newConfig.enabled) {
            revert NodeTypeNotEnabled(newNodeType);
        }

        // 检查当前质押是否满足新类型要求
        if (node.stGTokenLocked < newConfig.minStake) {
            revert InsufficientStake(node.stGTokenLocked, newConfig.minStake);
        }

        // 从旧类型列表移除
        _removeFromTypeList(node.nodeType, msg.sender);

        // 添加到新类型列表
        nodesByType[newNodeType].push(msg.sender);

        NodeType oldType = node.nodeType;
        node.nodeType = newNodeType;

        emit NodeTypeChanged(msg.sender, oldType, newNodeType);
    }

    // ====================================
    // Slash Functions
    // ====================================

    /**
     * @notice 报告节点失败
     * @param nodeAddress 节点地址
     * @dev 根据节点类型使用对应的slash配置
     */
    function reportFailure(address nodeAddress) external {
        require(msg.sender == oracle || msg.sender == owner(), "Unauthorized");

        NodeInfo storage node = nodes[nodeAddress];
        if (node.registeredAt == 0) {
            revert NodeNotRegistered(nodeAddress);
        }

        node.failureCount++;
        node.lastActiveAt = block.timestamp;

        // 获取该节点类型的配置
        NodeTypeConfig memory config = nodeTypeConfigs[node.nodeType];

        // 达到阈值则触发slash
        if (node.failureCount >= config.slashThreshold) {
            _slashNode(nodeAddress, config);
        }
    }

    /**
     * @notice 执行slash
     * @param nodeAddress 节点地址
     * @param config 节点类型配置
     */
    function _slashNode(
        address nodeAddress,
        NodeTypeConfig memory config
    ) internal {
        NodeInfo storage node = nodes[nodeAddress];

        // 计算slash数量（使用节点类型的百分比）
        uint256 slashAmount = node.stGTokenLocked * config.slashPercentage / 10000;

        // 执行slash
        uint256 slashed = GTOKEN_STAKING.slash(
            nodeAddress,
            slashAmount,
            string(abi.encodePacked(
                "Registry slash: ",
                node.name,
                " - ",
                _toString(node.failureCount),
                " failures"
            ))
        );

        // 更新状态
        node.stGTokenLocked -= slashed;
        node.totalSlashed += slashed;
        node.failureCount = 0;  // 重置计数

        // 如果质押低于最低要求，停用节点
        if (node.stGTokenLocked < config.minStake) {
            node.isActive = false;
        }

        emit NodeSlashed(nodeAddress, slashed, node.stGTokenLocked, "Failure threshold reached");
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice 获取指定类型的所有节点
     * @param nodeType 节点类型
     * @return addresses 节点地址列表
     */
    function getNodesByType(NodeType nodeType) external view returns (address[] memory) {
        return nodesByType[nodeType];
    }

    /**
     * @notice 获取指定类型的活跃节点
     * @param nodeType 节点类型
     * @return activeNodes 活跃节点地址列表
     */
    function getActiveNodesByType(NodeType nodeType) external view returns (address[] memory) {
        address[] storage allNodes = nodesByType[nodeType];
        uint256 activeCount = 0;

        // 计数活跃节点
        for (uint256 i = 0; i < allNodes.length; i++) {
            if (nodes[allNodes[i]].isActive) {
                activeCount++;
            }
        }

        // 构建结果数组
        address[] memory activeNodes = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allNodes.length; i++) {
            if (nodes[allNodes[i]].isActive) {
                activeNodes[index] = allNodes[i];
                index++;
            }
        }

        return activeNodes;
    }

    /**
     * @notice 获取节点类型配置
     * @param nodeType 节点类型
     * @return config 配置信息
     */
    function getNodeTypeConfig(NodeType nodeType) external view returns (NodeTypeConfig memory) {
        return nodeTypeConfigs[nodeType];
    }

    // ====================================
    // Internal Helpers
    // ====================================

    function _removeFromTypeList(NodeType nodeType, address nodeAddress) internal {
        address[] storage list = nodesByType[nodeType];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == nodeAddress) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    function _toLowercase(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(strBytes.length);

        for (uint256 i = 0; i < strBytes.length; i++) {
            if (strBytes[i] >= 0x41 && strBytes[i] <= 0x5A) {
                result[i] = bytes1(uint8(strBytes[i]) + 32);
            } else {
                result[i] = strBytes[i];
            }
        }

        return string(result);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
```

---

## 4. 改进方案优势

### 4.1 灵活的配置系统

| 配置项 | Registry v1.2 | Registry v2.0 | **RegistryV3** |
|--------|---------------|---------------|----------------|
| **最低质押** | ✅ 可调整（单一） | ❌ 硬编码 | ✅ **按节点类型配置** |
| **Slash阈值** | ❌ 不支持 | ❌ 硬编码10次 | ✅ **按节点类型配置** |
| **Slash比例** | ❌ 不支持 | ❌ 硬编码10% | ✅ **按节点类型配置** |
| **节点类型** | ❌ 单一 | ⚠️ 2种（硬编码） | ✅ **6+种（可扩展）** |

### 4.2 示例配置

```solidity
// Paymaster AOA: 低风险，低要求
NodeTypeConfig({
    enabled: true,
    minStake: 30 ether,          // 30 GT
    slashThreshold: 10,           // 10次失败
    slashPercentage: 1000,        // 10% slash
    minRegistrationFee: 0,
    description: "AOA Independent Paymaster"
})

// Validator: 高风险，高要求
NodeTypeConfig({
    enabled: true,
    minStake: 100 ether,          // 100 GT（更高）
    slashThreshold: 5,            // 5次失败（更严格）
    slashPercentage: 3000,        // 30% slash（更重）
    minRegistrationFee: 0,
    description: "Block Validator"
})

// Oracle: 中等风险
NodeTypeConfig({
    enabled: true,
    minStake: 20 ether,           // 20 GT（较低）
    slashThreshold: 15,           // 15次失败（更宽松）
    slashPercentage: 500,         // 5% slash（较轻）
    minRegistrationFee: 0,
    description: "Price Oracle"
})
```

### 4.3 治理可升级

```solidity
// 例如：市场波动，需降低Paymaster质押要求
registry.configureNodeType(
    NodeType.PAYMASTER_AOA,
    NodeTypeConfig({
        enabled: true,
        minStake: 20 ether,  // 从30降到20
        slashThreshold: 10,
        slashPercentage: 1000,
        minRegistrationFee: 0,
        description: "AOA Independent Paymaster"
    })
);

// 批量调整多个节点类型
NodeType[] memory types = [NodeType.PAYMASTER_AOA, NodeType.PAYMASTER_SUPER];
NodeTypeConfig[] memory configs = [...];
registry.configureNodeTypesBatch(types, configs);
```

---

## 5. 合并建议

### 5.1 迁移路径

**方案A：渐进式迁移（推荐）**
1. 部署RegistryV3，初始只启用Paymaster类型
2. 将v1.2和v2.0的注册者逐步迁移到v3
3. 启用新节点类型（Validator、Oracle等）
4. 废弃v1.2和v2.0

**方案B：直接替换**
1. 部署RegistryV3
2. 通过脚本批量导入v1.2/v2.0的注册数据
3. 立即切换到v3

### 5.2 兼容性处理

```solidity
// RegistryV3添加迁移函数
function migrateFromV1(
    address[] calldata oldNodes,
    string[] calldata names,
    uint256[] calldata stakes
) external onlyOwner {
    for (uint256 i = 0; i < oldNodes.length; i++) {
        // 导入旧数据，设置为PAYMASTER_AOA类型
        nodes[oldNodes[i]] = NodeInfo({
            nodeAddress: oldNodes[i],
            nodeType: NodeType.PAYMASTER_AOA,
            name: names[i],
            // ...
            stGTokenLocked: stakes[i],
            registeredAt: block.timestamp,
            isActive: true,
            failureCount: 0,
            totalSlashed: 0
        });
    }
}
```

---

## 6. Registry v2.0的其他问题

### 问题1：缺少节点升级路径
```solidity
// 当前无法从AOA升级到SUPER
// 新增changeNodeType()函数解决
```

### 问题2：Slash后无恢复机制
```solidity
// 建议增加质押补充功能
function addStake(uint256 amount) external {
    NodeInfo storage node = nodes[msg.sender];
    require(node.registeredAt != 0, "Not registered");

    // 锁定额外的stGToken
    GTOKEN_STAKING.lockStake(msg.sender, amount, "Add stake");
    node.stGTokenLocked += amount;

    // 如果满足最低要求，自动重新激活
    NodeTypeConfig memory config = nodeTypeConfigs[node.nodeType];
    if (node.stGTokenLocked >= config.minStake) {
        node.isActive = true;
    }
}
```

### 问题3：缺少声誉奖励机制
```solidity
// 建议增加成功计数和声誉分数
struct NodeInfo {
    // ...
    uint256 successCount;      // 成功次数
    uint256 totalAttempts;     // 总尝试次数
    uint256 reputationScore;   // 声誉分数（0-10000）
}

function recordSuccess(address nodeAddress) external {
    require(msg.sender == oracle, "Unauthorized");
    NodeInfo storage node = nodes[nodeAddress];

    node.successCount++;
    node.totalAttempts++;

    // 自动计算声誉分数
    node.reputationScore = (node.successCount * 10000) / node.totalAttempts;
}
```

---

## 7. 总结

### 核心改进
1. ✅ **支持多节点类型**：Paymaster、Validator、Oracle等
2. ✅ **可配置质押要求**：每种节点类型独立配置
3. ✅ **差异化Slash策略**：高风险节点更严格
4. ✅ **治理可升级**：通过configureNodeType动态调整
5. ✅ **节点类型切换**：支持升级/降级

### 合并建议
- **废弃v1.2**：ETH质押已过时，stGToken是未来
- **升级v2.0**：硬编码改为配置系统
- **采用RegistryV3**：统一注册入口，支持所有节点类型

### 下一步
1. 实现RegistryV3合约
2. 编写迁移脚本
3. 部署测试网验证
4. 编写治理提案
5. 主网升级

---

**技术负责人审批**: ____________
**日期**: 2025-01-26
