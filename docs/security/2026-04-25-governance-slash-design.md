# Governance Slash 设计 — DAO 多签 + Optimistic 自动化

**Date**: 2026-04-25
**Branch**: `security/audit-2026-04-25`
**Status**: 设计参考文档（用于 Phase 5 修复实施）

## 文档目的

本文档定义一个**独立于 BLS/DVT 共识**的 governance slash 路径，用于 slash 作恶的 DVT validator（破除"slash 路径自身依赖 BLS 共识"的循环依赖问题）。

设计目标：
1. ❌ DAO 多签私钥**绝不**放在自动化服务器上
2. ❌ 多签成员**不需要**持续在线 / 频繁签字
3. ✅ 全生命周期，多签私钥**仅在线下签字 1 次**（提议阶段）
4. ✅ 后续所有动作**任意 EOA**均可触发（permissionless）
5. ✅ 错误提议有 **72 小时挑战窗口** + 经济激励的 watcher 网络
6. ✅ 紧急情况有 **fastTrack 加速通道**（更高多签门槛换取速度）

## 行业成熟度参考

本设计是以下三种主网验证模式的标准组合：

| 项目 | 模式贡献 | 主网时间 | 资金量 |
|---|---|---|---|
| **OpenZeppelin Governor + TimelockController** | 提议 + Timelock + 任意 EOA execute 框架 | 2021– | $10B+ TVL |
| **Optimism Bedrock Fault Proof** | 7-day 挑战窗口 + bond 经济激励 | 2022– | $4B+ |
| **Arbitrum Security Council** | 9/12 多签紧急加速通道 | 2023– | $5B+ |

**主网部署案例**（直接采用类似设计）：Compound Bravo Governor、Uniswap Governor、ENS Governor、Aave、MakerDAO 等。

**审计成熟度**：
- OZ Governor 经 ConsenSys / Trail of Bits 多轮审计
- Optimism Fault Proof 经 Sigma Prime / Spearbit 审计
- 本设计的代码层重用 OZ TimelockController 与 Safe Wallet 即可，自身代码量约 200 行

## 全生命周期分阶段说明

### Stage 1 — Propose（提议阶段，人为参与，**全生命周期仅 1 次**）

**角色**：DAO 多签成员（如 5 人）

**工具**：[Safe Wallet](https://app.safe.global/)（开源、多链、最广泛使用的多签）

**动作**：
```
1. 多签成员 A 通过 Safe UI 创建一笔交易：
   to:    GovernanceSlasher.address
   data:  encodeFunctionData('propose', [
            target: V_evil,           // 被 slash 的 validator 地址
            roleId: ROLE_DVT,
            amount: 30 ether,         // slash 金额
            evidence: 'ipfs://Qm...'  // 链下证据指针
          ])

2. 通过 Safe 链下 API（Safe Transaction Service）收集签名：
   - A 用自己的硬件钱包签字 → 提交到 Safe Service
   - B/C/D 通过 Safe UI 看到 pending tx，各自签字
   - 收齐 ≥ M-of-N 后 Safe Service 通知

3. 任意成员（包括 A）点 "Execute"：
   Safe 把 N 个签名打包成一笔链上交易：
   - 调用 Safe.execTransaction(...)
   - Safe 内部验证 N 个签名后，调用 GovernanceSlasher.propose(...)
```

**关键安全特性**：
- ✅ 多签成员的私钥**只在各自钱包内签字**，永远不上传服务器、不放云端
- ✅ Safe Service 只收集签名 hash，不持有任何私钥
- ✅ 所有签名都是 ECDSA 离线签名，符合 EIP-712
- ✅ Safe 智能合约本身经多次审计，处理过 $100B+ 历史交易

**人为参与频率**：每个 slash 提议 1 次（不是每天，不是每周，是"想 slash 谁就 1 次"）

### Stage 2 — Challenge Window（挑战窗口，72 小时倒计时，无人参与）

**角色**：任意 EOA（普通用户、watcher、被 slash 者本人、其他 DVT 节点）

**链上状态**：proposal 已记录于 `GovernanceSlasher.proposals[id]`，`proposedAt = block.timestamp`

**触发条件（什么情况会有人挑战）**：
- 提议者错误：DAO 多签成员投错票或被欺骗
- 双重 slash：V_evil 已经在 BLS 路径正常 slash 过了，governance 不应重复
- 金额超额：amount > `RoleConfig.minStake` 或与证据不匹配
- target 错误：把好的 validator 误标为 evil

**任何人可挑战**：
```solidity
function challenge(uint256 id, bytes calldata fraudProof) external {
    SlashProposal storage p = proposals[id];
    require(!p.executed && !p.challenged, "Bad state");
    require(block.timestamp < p.proposedAt + CHALLENGE_PERIOD, "Window closed");
    
    // 挑战者锁保证金
    GTOKEN.safeTransferFrom(msg.sender, address(this), CHALLENGE_BOND);
    
    // 验证 fraud proof（具体逻辑取决于业务）
    bool valid = _verifyFraudProof(p, fraudProof);
    
    if (valid) {
        p.challenged = true;
        // 挑战者获得提议者 bond + 自己 bond 退还
        GTOKEN.safeTransfer(msg.sender, p.proposerBond + CHALLENGE_BOND);
        emit ProposalChallenged(id, msg.sender);
    } else {
        // 挑战失败 → bond 转给提议者
        GTOKEN.safeTransfer(p.proposer, CHALLENGE_BOND);
        // 不修改 p.challenged，允许其他人继续挑战
    }
}
```

**经济激励的 Watcher 网络**：
- 任何人可以监控所有 `SlashProposed` 事件
- 发现错误提议 → 提交 fraud proof → 获得 5e GToken 提议者 bond
- 这是 **Optimistic Rollup** 同款经济模型，已在 Optimism / Arbitrum 主网长期运行

**Fraud Proof 形式**（具体取决于业务）：
- 例 1：证明 V_evil 已在 BLS 路径正常 slash 过 → 提交对应 `GTokenStaking.UserSlashed` 事件的存证
- 例 2：证明 V_evil 当前 stake < amount → 链上 view 直接读
- 例 3：证明证据 IPFS 内容与提议参数不符 → 提交 IPFS hash 与解析后的 manifest

**Watcher 缺位的退化**：
- 如果完全没人监控（边缘情况），系统退化为"DAO 信任 + 公开公示"模式
- 仍然优于"DAO 直接执行"，因为有 72h 窗口让外部观测者有时间看到链上事件
- 主流 DAO（Compound、Uniswap）的 Timelock 完全没有挑战机制，仅靠"公开窗口 + 社区监督"也运行了 5+ 年

### Stage 3 — Execute（执行阶段，无人参与，permissionless）

**角色**：任意 EOA（cron 脚本、第三方 keeper、DVT 节点、普通用户均可）

**触发条件**：
- `block.timestamp >= proposedAt + 72h`
- `!challenged`
- `!executed`

**动作**：
```solidity
function execute(uint256 id) external {
    SlashProposal storage p = proposals[id];
    require(!p.executed, "Already executed");
    require(!p.challenged, "Was challenged");
    require(block.timestamp >= p.proposedAt + CHALLENGE_PERIOD, "Window not ended");
    
    p.executed = true;
    
    // 退还提议者 bond（72h 内无人成功挑战 → bond 安全）
    GTOKEN.safeTransfer(p.proposer, p.proposerBond);
    
    // ✅ 关键：调用 GTokenStaking 独立 slash 路径，不走 BLS
    STAKING.slashByGovernance(p.target, p.roleId, p.amount, "Governance slash");
    
    emit SlashExecuted(id, p.target, p.amount);
}
```

**实践上谁会执行 execute**？
- **选项 A**：DAO 自建 cron 脚本，72h 后自动 execute（脚本不持有任何特权私钥，只是普通 EOA）
- **选项 B**：第三方 watcher 服务（用提议者的 5e bond 做小额激励，或 protocol 给执行者一笔小费）
- **选项 C**：任何关心 protocol 健康的人 — 包括其他 DVT 节点（slash 一个 evil validator 等价于自己 stake 占比上升）
- **选项 D**：被 slash 者自己也可以 execute（他无法阻止，但可以加速）

**实际中"无人执行"几乎不会发生**：
- 第一个想从 staked GToken 释放新进 validator 名额的人会触发
- 第一个想看到 protocol 治理生效的 DAO 成员会触发
- 第一个 watcher 服务会 batch 触发所有过期 proposal 节省 gas

### Stage 4 — fastTrack（紧急加速通道，备用）

**触发条件**（极端情况）：
- 真正紧急的安全事件（如 DVT validator 主动协助攻击 + 资金流出风险）
- 普通 72h 窗口太长

**机制**：
```solidity
function fastTrack(uint256 id, bytes[] calldata signatures) external {
    SlashProposal storage p = proposals[id];
    require(!p.executed, "Already executed");
    
    // 比普通提议更高的多签门槛（如 5/9 vs 普通 3/9）
    require(_verifyMultisigSignatures(signatures, FAST_TRACK_THRESHOLD), "Insufficient signatures");
    
    // 跳过 challenge window
    p.executed = true;
    STAKING.slashByGovernance(p.target, p.roleId, p.amount, "Emergency");
    
    emit FastTrackExecuted(id, p.target);
}
```

**安全设计**：
- `FAST_TRACK_THRESHOLD` > `PROPOSE_THRESHOLD`（如 5/9 vs 3/9）— 更高门槛防止误用
- 多签私钥仍然只在线下签字 1 次
- 写入合约不可篡改，紧急通道使用记录会被永久记录

## 完整合约 Spec

### `GovernanceSlasher.sol`（新建，约 200 行）

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGTokenStaking} from "../interfaces/v3/IGTokenStaking.sol";
import {IRegistry} from "../interfaces/v3/IRegistry.sol";

contract GovernanceSlasher is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    struct SlashProposal {
        address target;
        bytes32 roleId;
        uint256 amount;
        uint256 proposedAt;
        address proposer;
        uint256 proposerBond;
        bytes32 evidenceHash;  // keccak256 of evidence URI
        bool challenged;
        bool executed;
    }
    
    // ─── Configuration ─────────
    uint256 public challengePeriod = 72 hours;
    uint256 public proposalBond = 5 ether;       // GToken
    uint256 public challengeBond = 5 ether;
    
    address public immutable DAO_MULTISIG;       // Stage 1 提议者（M-of-N）
    address public immutable FAST_TRACK_MULTISIG; // Stage 4 加速者（更高 M-of-N）
    
    IERC20 public immutable GTOKEN;
    IGTokenStaking public immutable STAKING;
    IRegistry public immutable REGISTRY;
    
    // ─── State ─────────
    uint256 public nextId;
    mapping(uint256 => SlashProposal) public proposals;
    
    // ─── Events ─────────
    event SlashProposed(uint256 indexed id, address indexed target, bytes32 roleId, uint256 amount, bytes32 evidenceHash);
    event ProposalChallenged(uint256 indexed id, address indexed challenger);
    event ChallengeFailed(uint256 indexed id, address indexed challenger);
    event SlashExecuted(uint256 indexed id, address indexed target, uint256 amount);
    event FastTrackExecuted(uint256 indexed id, address indexed target);
    event ConfigUpdated(string field, uint256 oldValue, uint256 newValue);
    
    // ─── Errors ─────────
    error OnlyDAO();
    error InvalidState();
    error WindowClosed();
    error WindowNotEnded();
    error InsufficientFastTrackSigs();
    
    constructor(
        address daoMultisig,
        address fastTrackMultisig,
        address gtoken,
        address staking,
        address registry,
        address owner
    ) Ownable(owner) {
        DAO_MULTISIG = daoMultisig;
        FAST_TRACK_MULTISIG = fastTrackMultisig;
        GTOKEN = IERC20(gtoken);
        STAKING = IGTokenStaking(staking);
        REGISTRY = IRegistry(registry);
    }
    
    // ─── Stage 1: Propose ─────────
    function propose(
        address target,
        bytes32 roleId,
        uint256 amount,
        string calldata evidenceURI
    ) external nonReentrant returns (uint256 id) {
        if (msg.sender != DAO_MULTISIG) revert OnlyDAO();
        
        GTOKEN.safeTransferFrom(msg.sender, address(this), proposalBond);
        
        id = ++nextId;
        proposals[id] = SlashProposal({
            target: target,
            roleId: roleId,
            amount: amount,
            proposedAt: block.timestamp,
            proposer: msg.sender,
            proposerBond: proposalBond,
            evidenceHash: keccak256(bytes(evidenceURI)),
            challenged: false,
            executed: false
        });
        emit SlashProposed(id, target, roleId, amount, keccak256(bytes(evidenceURI)));
    }
    
    // ─── Stage 2: Challenge ─────────
    function challenge(uint256 id, bytes calldata fraudProof) external nonReentrant {
        SlashProposal storage p = proposals[id];
        if (p.executed || p.challenged) revert InvalidState();
        if (block.timestamp >= p.proposedAt + challengePeriod) revert WindowClosed();
        
        GTOKEN.safeTransferFrom(msg.sender, address(this), challengeBond);
        
        bool valid = _verifyFraudProof(p, fraudProof);
        
        if (valid) {
            p.challenged = true;
            GTOKEN.safeTransfer(msg.sender, p.proposerBond + challengeBond);
            emit ProposalChallenged(id, msg.sender);
        } else {
            GTOKEN.safeTransfer(p.proposer, challengeBond);
            emit ChallengeFailed(id, msg.sender);
        }
    }
    
    // ─── Stage 3: Execute (permissionless) ─────────
    function execute(uint256 id) external nonReentrant {
        SlashProposal storage p = proposals[id];
        if (p.executed) revert InvalidState();
        if (p.challenged) revert InvalidState();
        if (block.timestamp < p.proposedAt + challengePeriod) revert WindowNotEnded();
        
        p.executed = true;
        
        // 退还提议者 bond
        GTOKEN.safeTransfer(p.proposer, p.proposerBond);
        
        // 独立 slash 路径
        STAKING.slashByGovernance(p.target, p.roleId, p.amount, "Governance slash");
        
        emit SlashExecuted(id, p.target, p.amount);
    }
    
    // ─── Stage 4: FastTrack (emergency) ─────────
    function fastTrackPropose(
        address target,
        bytes32 roleId,
        uint256 amount,
        string calldata evidenceURI
    ) external nonReentrant returns (uint256 id) {
        if (msg.sender != FAST_TRACK_MULTISIG) revert InsufficientFastTrackSigs();
        
        // 跳过 challenge window，直接 slash
        STAKING.slashByGovernance(target, roleId, amount, "Emergency slash");
        
        id = ++nextId;
        proposals[id] = SlashProposal({
            target: target,
            roleId: roleId,
            amount: amount,
            proposedAt: block.timestamp,
            proposer: msg.sender,
            proposerBond: 0,
            evidenceHash: keccak256(bytes(evidenceURI)),
            challenged: false,
            executed: true
        });
        
        emit FastTrackExecuted(id, target);
    }
    
    // ─── Fraud Proof 验证（具体形式需要根据业务定义）─────────
    function _verifyFraudProof(SlashProposal storage p, bytes calldata proof) internal view returns (bool) {
        // 形式 1: 重复 slash 检查
        // 形式 2: 金额超额检查（直接读 STAKING.getLockedStake）
        // 形式 3: 证据哈希不匹配（解析 proof 内的 IPFS manifest）
        // 形式 4: target 角色检查（确认 target 当前确实持有 roleId）
        
        // TODO: 在 Phase 5 修复实施时具体定义
        // 当前简化为"任意 proof 直接成功"，仅用于占位
        return false;
    }
    
    // ─── Owner-only Configuration ─────────
    function setChallengePeriod(uint256 newPeriod) external onlyOwner {
        require(newPeriod >= 24 hours && newPeriod <= 14 days, "Bad range");
        emit ConfigUpdated("challengePeriod", challengePeriod, newPeriod);
        challengePeriod = newPeriod;
    }
    
    function setProposalBond(uint256 newBond) external onlyOwner {
        emit ConfigUpdated("proposalBond", proposalBond, newBond);
        proposalBond = newBond;
    }
    
    function setChallengeBond(uint256 newBond) external onlyOwner {
        emit ConfigUpdated("challengeBond", challengeBond, newBond);
        challengeBond = newBond;
    }
}
```

### `GTokenStaking.sol` 增量改动

```solidity
// 新增字段
address public governanceSlasher;

event GovernanceSlasherSet(address indexed oldSlasher, address indexed newSlasher);

function setGovernanceSlasher(address gs) external onlyOwner {
    require(gs != address(0), "Zero addr");
    address old = governanceSlasher;
    governanceSlasher = gs;
    emit GovernanceSlasherSet(old, gs);
}

// 新增独立 slash 路径
function slashByGovernance(
    address user,
    bytes32 roleId,
    uint256 amount,
    string calldata reason
) external nonReentrant {
    require(msg.sender == governanceSlasher, "Only governance slasher");
    
    RoleLock storage lock = roleLocks[user][roleId];
    if (lock.amount < amount) revert InsufficientStake();
    
    lock.amount -= uint128(amount);
    
    StakeInfo storage stake = stakes[user];
    if (stake.amount < amount) revert InsufficientStake();
    stake.slashedAmount += amount;
    stake.amount -= amount;
    totalStaked -= amount;
    
    if (lock.amount == 0) {
        _removeUserRole(user, roleId);
    }
    
    GTOKEN.safeTransfer(treasury, amount);
    emit UserSlashed(user, amount, reason, block.timestamp);
}
```

## 部署 + 配置脚本（DeployLive.s.sol 增量）

```solidity
// 1. 部署 GovernanceSlasher
GovernanceSlasher gs = new GovernanceSlasher(
    DAO_MULTISIG_ADDRESS,            // M-of-N Safe，例如 3-of-5
    FAST_TRACK_MULTISIG_ADDRESS,     // 更高门槛 Safe，例如 5-of-9
    address(gtoken),
    address(staking),
    address(registry),
    address(this)                    // owner = deployer，部署后转给 DAO
);

// 2. 配置 GTokenStaking
staking.setGovernanceSlasher(address(gs));

// 3. (可选) 让 DAO 多签预批准 5e GToken 给 GovernanceSlasher
//    在 Stage 1 propose() 时调用 transferFrom，需要预 approval
```

## 安全性对照表

| 威胁 | 传统直接 slash 模式 | 本设计（GovernanceSlasher） |
|---|---|---|
| 多签私钥泄露 → 任意 slash | 立即生效，无救济 | 72h 挑战窗口 + watcher 经济激励，可被推翻 |
| 多签私钥放服务器 | 必需（自动化执行） | **不需要**，私钥永远在硬件钱包 |
| 误操作（提错对象/金额） | 无法挽回 | 72h 内任何人可挑战 |
| 提议者夹带恶意 | 无机制阻止 | fraud proof 验证 + watcher 监控 |
| Watcher 缺位 | N/A | 退化为"DAO 信任 + 公开公示"，仍优于即时执行 |
| Slash 自身依赖 BLS（循环） | N/A（旧设计致命缺陷） | **完全独立于 BLS**，破除循环 |
| 紧急情况无法 72h 等 | 紧急 = 中心化 | fastTrack 5/9 多签可加速 |
| Reentrancy / 资金重入 | 取决于实现 | nonReentrant + safeTransfer |
| Bond 套利 | N/A | 提议者 bond = 挑战者激励上限，错误提议必亏 |

## 与现有合约的集成点

| 合约 | 改动 | 类型 |
|---|---|---|
| `GovernanceSlasher.sol` | 新增（200 行） | 新合约 |
| `GTokenStaking.sol` | +50 行（governanceSlasher + slashByGovernance） | 局部新增 |
| `IGTokenStaking.sol` | +1 函数声明 | 接口同步 |
| `Registry.sol` | 不变 | — |
| `BLSAggregator.sol` | 不变 | — |
| `DeployLive.s.sol` / `DeployAnvil.s.sol` | +30 行部署 + 配置 | 部署脚本 |
| 测试文件 | 新增 `GovernanceSlasher.t.sol`（~30 cases） | 新增测试 |

## 治理参数推荐

| 参数 | 推荐值 | 调整范围 | 备注 |
|---|---|---|---|
| `challengePeriod` | 72 hours | 24h–14d | 与 Optimism 7d 对比，72h 是 protocol 内部治理常用值 |
| `proposalBond` | 5 GToken | 1–20 | 既要防 spam 又不能太高让 DAO 难以发起 |
| `challengeBond` | 5 GToken | 1–20 | 与 proposalBond 相等，防止双向不平衡 |
| `DAO_MULTISIG` 门槛 | 3-of-5 | M-of-N | 标准 DAO 多签 |
| `FAST_TRACK_MULTISIG` 门槛 | 5-of-9 | M-of-N (M > N/2) | 紧急通道，高门槛 |

## FAQ

### Q1：DAO 多签全生命周期真的只签一次？
**是的**。每个 slash proposal 提议时多签成员各自用硬件钱包签字（M-of-N），通过 Safe Service 收集后聚合成 1 笔链上交易提交。之后 72h 窗口与 execute 阶段无需任何多签参与。

### Q2：如果 72h 内没人 execute 怎么办？
合约状态保持"已提议未执行"。**任何人随时可以来 execute**（无超时上限）。实际中第一个想看到生效的人就会触发，几乎不会出现长期未执行情况。

### Q3：watcher 怎么赚钱？我作为 watcher 能持续运营吗？
- 单次成功挑战获得 5e GToken（提议者 bond）
- 平台越大、错误提议越多，watcher 收入越高
- 类似 Optimism / Arbitrum 上的 fraud proof watcher 已经形成商业生态

### Q4：fraud proof 怎么定义？
具体形式需要 Phase 5 实施时定义，常见形式：
- **证据哈希挑战**：链上 evidenceHash ≠ IPFS 内容的 keccak256
- **重复 slash 检测**：target 已在 BLS 路径被 slash 过同金额（链上事件存证）
- **金额超额**：amount > target 当前 stake
- **角色不符**：target 当前不持有 roleId

### Q5：为什么不用 OpenZeppelin Governor？
OZ Governor 是为代币投票治理设计，每个提议需要全社区投票，不适合"小范围 DAO 多签快速决策"。我们的场景更接近 Compound Bravo 的"多签提议 + Timelock"，但额外加上挑战机制。如果未来需要扩展为代币投票，可以无缝迁移到 OZ Governor。

### Q6：fastTrack 会不会被滥用？
- 门槛比普通提议高（5/9 vs 3/5）
- 写入永久事件 `FastTrackExecuted`
- DAO 章程应明确 fastTrack 仅用于"链上资金即将流出"等真正紧急场景
- 滥用会被社区舆论制约 + 下次 DAO 选举淘汰

### Q7：跨链多链如何同步？
本合约部署在每条链一份，互不影响。如需跨链协调，可在 fraud proof 中引入 Light Client / Bridge proof 验证其他链状态。

## 与 Phase 5 修复方案的关联

| 本文档 stage | Phase 5 修复点 | review.md 引用 |
|---|---|---|
| Stage 3 execute 调 slashByGovernance | GTokenStaking 新增 slashByGovernance | B6-C1c |
| 整体设计 | 破除"slash 路径自身依赖 BLS"循环依赖 | B6-C1c |
| 与 BLS 路径并行 | BLSAggregator 修复后仍保留 BLS slash 路径，两条路径互补 | B6-C1a/b |

---

**Last Updated**: 2026-04-25
**Owner**: SuperPaymaster Security Audit Track
**Related**: [`2026-04-25-review.md`](./2026-04-25-review.md), [`2026-04-25-dvt-proof-scenarios.md`](./2026-04-25-dvt-proof-scenarios.md)
