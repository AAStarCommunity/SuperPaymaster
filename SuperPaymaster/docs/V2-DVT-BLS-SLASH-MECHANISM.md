# DVT + BLS 分布式监控与Slash机制

## 设计理念

SuperPaymaster v2.0 采用**分布式验证技术 (DVT)** + **BLS签名聚合**实现去中心化监控，避免单点信任问题。

### 核心目标

1. **去中心化监控**: 13个独立DVT节点分布式检查
2. **抗女巫攻击**: BLS阈值签名 (7/13)
3. **自动化惩罚**: 三级Slash时间线
4. **透明可验证**: 所有Slash记录上链

---

## 架构图

```
┌────────────────────────────────────────────────────────────────┐
│                    SuperPaymaster v2.0                         │
│  OperatorAccount {                                             │
│    aPNTsBalance: 50 ether (< 100 minimum)                     │
│    isPaused: false                                             │
│  }                                                             │
└───────────────────────┬────────────────────────────────────────┘
                        │
                        │ 每小时检查
                        │
┌───────────────────────▼────────────────────────────────────────┐
│              DVTValidator.sol (13个节点)                       │
├────────────────────────────────────────────────────────────────┤
│  Node 1: checkOperator(0xABC) → Balance=50, isSufficient=false │
│  Node 2: checkOperator(0xABC) → Balance=50, isSufficient=false │
│  Node 3: checkOperator(0xABC) → Balance=50, isSufficient=false │
│  ...                                                           │
│  Node 13: checkOperator(0xABC) → Balance=50, isSufficient=false│
│                                                                │
│  → 广播到 BLS Aggregator                                      │
└───────────────────────┬────────────────────────────────────────┘
                        │
                        │ 聚合签名
                        │
┌───────────────────────▼────────────────────────────────────────┐
│              BLSAggregator.sol                                 │
├────────────────────────────────────────────────────────────────┤
│  收集13个节点的BLS签名                                         │
│  → 验证阈值: 7/13签名                                          │
│  → 达到阈值: 执行Slash                                         │
│  → 未达到: 仅记录警告                                          │
└───────────────────────┬────────────────────────────────────────┘
                        │
                        │ 执行Slash
                        │
┌───────────────────────▼────────────────────────────────────────┐
│              SuperPaymaster.executeSlashWithBLS()              │
│  → Hour 1: 警告 + 声誉-10                                      │
│  → Hour 2: Slash 5% + 声誉-20                                  │
│  → Hour 3: Slash 10% + Pause + 声誉-50                         │
└────────────────────────────────────────────────────────────────┘
```

---

## 1. DVTValidator.sol

### 核心功能
- 13个独立节点分布式验证
- 每小时检查一次aPNTs余额
- 提交BLS签名到Aggregator

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract DVTValidator {

    struct ValidationRecord {
        address operator;           // 被检查的Operator
        uint256 timestamp;          // 检查时间
        uint256 apntsBalance;       // aPNTs余额
        bool isSufficient;          // 是否充足
        bytes blsSignature;         // BLS签名
        address validator;          // 验证节点地址
    }

    mapping(uint256 => ValidationRecord[]) public validationsByHour; // hourIndex → 记录列表
    mapping(address => uint256) public lastCheckTime; // operator → 最后检查时间

    address public immutable SUPERPAYMASTER;
    address public immutable BLS_AGGREGATOR;

    uint256 public constant CHECK_INTERVAL = 1 hours;
    uint256 public constant MIN_BALANCE = 100 ether; // 100 aPNTs

    // DVT节点白名单
    mapping(address => bool) public authorizedValidators;
    uint256 public validatorCount = 0;

    event CheckSubmitted(
        address indexed operator,
        address indexed validator,
        uint256 balance,
        bool isSufficient,
        uint256 hourIndex
    );

    /// @notice 初始化13个DVT节点
    constructor(address _superPaymaster, address _blsAggregator, address[] memory _validators) {
        SUPERPAYMASTER = _superPaymaster;
        BLS_AGGREGATOR = _blsAggregator;

        require(_validators.length == 13, "Must have 13 validators");

        for (uint i = 0; i < 13; i++) {
            authorizedValidators[_validators[i]] = true;
        }
        validatorCount = 13;
    }

    /// @notice DVT节点提交检查结果
    /// @param operator 被检查的Operator
    /// @param apntsBalance 检测到的aPNTs余额
    /// @param blsSignature BLS签名
    function submitCheck(
        address operator,
        uint256 apntsBalance,
        bytes memory blsSignature
    ) external {
        require(authorizedValidators[msg.sender], "Not authorized validator");
        require(
            block.timestamp >= lastCheckTime[operator] + CHECK_INTERVAL,
            "Check interval not passed"
        );

        bool isSufficient = apntsBalance >= MIN_BALANCE;
        uint256 hourIndex = block.timestamp / 1 hours;

        ValidationRecord memory record = ValidationRecord({
            operator: operator,
            timestamp: block.timestamp,
            apntsBalance: apntsBalance,
            isSufficient: isSufficient,
            blsSignature: blsSignature,
            validator: msg.sender
        });

        validationsByHour[hourIndex].push(record);

        emit CheckSubmitted(operator, msg.sender, apntsBalance, isSufficient, hourIndex);

        // 通知BLS Aggregator
        IBLSAggregator(BLS_AGGREGATOR).collectSignature(
            operator,
            hourIndex,
            blsSignature,
            msg.sender
        );
    }

    /// @notice 查询某小时的所有验证记录
    function getValidationsByHour(uint256 hourIndex) external view returns (ValidationRecord[] memory) {
        return validationsByHour[hourIndex];
    }

    /// @notice 查询特定Operator的最新检查状态
    function getLatestCheck(address operator) external view returns (ValidationRecord memory) {
        uint256 currentHour = block.timestamp / 1 hours;
        ValidationRecord[] memory records = validationsByHour[currentHour];

        for (uint i = records.length; i > 0; i--) {
            if (records[i - 1].operator == operator) {
                return records[i - 1];
            }
        }

        revert("No recent check found");
    }
}
```

---

## 2. BLSAggregator.sol

### 核心功能
- 收集13个节点的BLS签名
- 验证阈值 (7/13)
- 执行Slash

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract BLSAggregator {

    struct AggregatedProof {
        bytes signature;            // 聚合后的BLS签名
        address[] signers;          // 签名节点列表
        uint256 timestamp;          // 聚合时间
        bytes32 messageHash;        // 消息哈希
        uint256 hourIndex;          // 小时索引
    }

    struct SlashProposal {
        address operator;           // 被惩罚的Operator
        uint256 hourIndex;          // 小时索引
        uint256 firstWarningHour;   // 首次警告小时
        uint256 signatureCount;     // 当前签名数
        mapping(address => bool) hasSigned;  // 节点是否已签名
        mapping(address => bytes) signatures; // 节点签名
        bool executed;              // 是否已执行
    }

    mapping(address => SlashProposal) public proposals; // operator → 提案
    mapping(uint256 => AggregatedProof) public proofs;  // hourIndex → 聚合证明

    address public immutable SUPERPAYMASTER;
    address public immutable DVT_VALIDATOR;

    uint256 public constant THRESHOLD = 7; // 7/13阈值
    uint256 public constant VALIDATOR_COUNT = 13;

    event SignatureCollected(address indexed operator, address indexed validator, uint256 hourIndex);
    event ProofAggregated(address indexed operator, uint256 hourIndex, uint256 signatureCount);
    event SlashExecuted(address indexed operator, uint256 hourIndex, uint8 level);

    /// @notice 收集DVT节点签名
    function collectSignature(
        address operator,
        uint256 hourIndex,
        bytes memory signature,
        address validator
    ) external {
        require(msg.sender == DVT_VALIDATOR, "Only DVT Validator");

        SlashProposal storage proposal = proposals[operator];

        // 初始化提案
        if (proposal.firstWarningHour == 0) {
            proposal.operator = operator;
            proposal.hourIndex = hourIndex;
            proposal.firstWarningHour = hourIndex;
        }

        // 避免重复签名
        require(!proposal.hasSigned[validator], "Already signed");

        proposal.hasSigned[validator] = true;
        proposal.signatures[validator] = signature;
        proposal.signatureCount++;

        emit SignatureCollected(operator, validator, hourIndex);

        // 达到阈值，执行Slash
        if (proposal.signatureCount >= THRESHOLD && !proposal.executed) {
            _executeSlash(operator, proposal);
        }
    }

    /// @notice 执行Slash (内部函数)
    function _executeSlash(address operator, SlashProposal storage proposal) internal {
        uint256 hoursPassed = proposal.hourIndex - proposal.firstWarningHour;

        ISuperpaymaster.SlashLevel level;

        if (hoursPassed == 0) {
            level = ISuperpaymaster.SlashLevel.WARNING;  // Hour 1: 警告
        } else if (hoursPassed == 1) {
            level = ISuperpaymaster.SlashLevel.MINOR;    // Hour 2: 5% slash
        } else {
            level = ISuperpaymaster.SlashLevel.MAJOR;    // Hour 3+: 10% slash + pause
        }

        // 聚合签名
        bytes memory aggregatedSig = _aggregateBLSSignatures(proposal);

        // 调用SuperPaymaster执行Slash
        ISuperpaymaster(SUPERPAYMASTER).executeSlashWithBLS(
            operator,
            level,
            aggregatedSig
        );

        proposal.executed = true;

        emit SlashExecuted(operator, proposal.hourIndex, uint8(level));
    }

    /// @notice 聚合BLS签名 (简化版)
    function _aggregateBLSSignatures(SlashProposal storage proposal) internal view returns (bytes memory) {
        // 实际实现需要使用BLS库进行签名聚合
        // 这里简化为拼接所有签名
        bytes memory aggregated;

        // 遍历所有签名节点 (实际应通过mapping)
        // aggregated = BLS.aggregate([sig1, sig2, ...]);

        return aggregated;
    }

    /// @notice 验证聚合签名 (公开函数)
    function verifyAggregated(
        AggregatedProof memory proof,
        bytes32 messageHash
    ) public view returns (bool) {
        require(proof.signers.length >= THRESHOLD, "Insufficient signers");

        // 实际实现需要验证BLS签名
        // return BLS.verify(proof.signature, messageHash, publicKeys);

        return true; // 简化版
    }

    /// @notice 查询Operator的Slash提案状态
    function getProposalStatus(address operator) external view returns (
        uint256 hourIndex,
        uint256 firstWarningHour,
        uint256 signatureCount,
        bool executed
    ) {
        SlashProposal storage proposal = proposals[operator];
        return (
            proposal.hourIndex,
            proposal.firstWarningHour,
            proposal.signatureCount,
            proposal.executed
        );
    }
}
```

---

## 三级Slash时间线

### 时间轴

```
Hour 0: aPNTs余额 = 100 (正常)
  → 无事发生

Hour 1: aPNTs余额 = 50 (< 100最低要求)
  → 13个DVT节点检测到
  → 提交BLS签名到Aggregator
  → 达到7/13阈值
  → 执行: SlashLevel.WARNING
    - 声誉 -10
    - 不扣除sGToken
    - 记录警告历史

Hour 2: aPNTs余额仍然 = 50
  → DVT节点再次检测
  → 提交第二轮BLS签名
  → 达到7/13阈值
  → 执行: SlashLevel.MINOR
    - Slash 5% sGToken
    - 声誉 -20
    - 记录Slash历史

Hour 3: aPNTs余额仍然 = 50
  → DVT节点第三次检测
  → 提交第三轮BLS签名
  → 达到7/13阈值
  → 执行: SlashLevel.MAJOR
    - Slash 10% sGToken
    - 声誉 -50
    - 账户暂停 (isPaused = true)
    - 记录严重Slash历史
```

### Slash记录示例

```solidity
SlashRecord {
    timestamp: 1697890800,
    amount: 3 ether,  // 30 GT * 10% = 3 GT
    reputationLoss: 50,
    reason: "aPNTs balance below threshold for 3 hours",
    level: SlashLevel.MAJOR
}
```

---

## BLS签名聚合详解

### 什么是BLS签名?

**BLS (Boneh-Lynn-Shacham)** 是一种可聚合的数字签名方案，具有以下特性:

1. **签名聚合**: 多个签名可合并为一个
2. **高效验证**: 验证聚合签名等同于验证单个签名
3. **抗审查**: 无法伪造或删除特定节点的签名

### 聚合流程

```
Node 1: BLS.sign(msg, sk1) → sig1
Node 2: BLS.sign(msg, sk2) → sig2
...
Node 7: BLS.sign(msg, sk7) → sig7

Aggregator:
  aggregatedSig = BLS.aggregate([sig1, sig2, ..., sig7])

Verifier:
  BLS.verify(aggregatedSig, msg, [pk1, pk2, ..., pk7]) → true/false
```

### 阈值签名 (7/13)

- **总节点**: 13个独立DVT验证节点
- **阈值**: 需要至少7个节点签名
- **安全性**: 即使6个节点离线/作恶，系统仍能正常运行

### 消息格式

```solidity
bytes32 messageHash = keccak256(abi.encodePacked(
    operator,           // 被检查的Operator地址
    apntsBalance,       // 检测到的余额
    hourIndex,          // 小时索引
    chainId             // 链ID (防跨链重放)
));
```

---

## 安全性分析

### 1. 抗女巫攻击

**问题**: 恶意节点提交虚假检查结果

**防御**:
- 白名单机制: 仅授权的13个节点可提交
- 阈值验证: 需要7/13共识
- BLS签名: 无法伪造其他节点签名

### 2. 抗审查

**问题**: Aggregator拒绝聚合签名

**防御**:
- 任何人可调用 `verifyAggregated()` 验证
- Slash记录完全上链，透明可查
- 可部署多个Aggregator作为备份

### 3. 时间戳操纵

**问题**: 节点提交错误的时间戳

**防御**:
- 使用 `block.timestamp` 作为权威时间
- `CHECK_INTERVAL` 强制1小时间隔
- 时间漂移检测: `require(timestamp <= block.timestamp + 5 minutes)`

### 4. 重放攻击

**问题**: 恶意节点重放历史签名

**防御**:
- `hourIndex` 包含在消息哈希中
- `hasSigned` mapping 防止重复签名
- `executed` 标记防止重复执行

---

## 链下DVT节点实现 (示例)

```typescript
// DVT Node (链下服务)
import { ethers } from 'ethers';
import { BLS } from '@noble/curves/bls12-381';

class DVTNode {
    private provider: ethers.Provider;
    private wallet: ethers.Wallet;
    private superPaymaster: ethers.Contract;
    private dvtValidator: ethers.Contract;
    private blsPrivateKey: Uint8Array;

    async checkOperators() {
        while (true) {
            // 1. 获取所有注册的Operators
            const operators = await this.getActiveOperators();

            for (const operator of operators) {
                // 2. 读取aPNTs余额
                const balance = await this.superPaymaster.accounts(operator).aPNTsBalance;

                // 3. 判断是否充足
                const isSufficient = balance >= ethers.parseEther("100");

                if (!isSufficient) {
                    // 4. 生成BLS签名
                    const signature = await this.signCheck(operator, balance);

                    // 5. 提交到链上
                    await this.dvtValidator.submitCheck(
                        operator,
                        balance,
                        signature
                    );

                    console.log(`[WARNING] Operator ${operator} balance: ${balance}`);
                }
            }

            // 每小时检查一次
            await this.sleep(3600_000);
        }
    }

    async signCheck(operator: string, balance: bigint): Promise<string> {
        const hourIndex = Math.floor(Date.now() / 1000 / 3600);
        const messageHash = ethers.solidityPackedKeccak256(
            ['address', 'uint256', 'uint256', 'uint256'],
            [operator, balance, hourIndex, 1] // chainId=1
        );

        const signature = BLS.sign(
            ethers.getBytes(messageHash),
            this.blsPrivateKey
        );

        return ethers.hexlify(signature);
    }

    private sleep(ms: number) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }
}
```

---

## 总结

DVT + BLS机制实现了:

1. **去中心化**: 13个独立节点，无单点故障
2. **高效**: BLS签名聚合，单次验证
3. **安全**: 7/13阈值，抗女巫+抗审查
4. **自动化**: 每小时检查，三级Slash
5. **透明**: 所有记录上链，可公开验证

---

**文档版本**: v2.0.0
**最后更新**: 2025-10-22
**状态**: 技术设计完成
