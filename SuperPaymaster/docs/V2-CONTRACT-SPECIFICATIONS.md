# SuperPaymaster v2.0 合约规范

## 合约架构关系图

```
Registry.sol (社区元信息中心)
    ├── CommunityProfile 存储
    ├── 多索引查询 (name/ENS/SBT)
    └── 路由到 Traditional Paymaster 或 SuperPaymaster

SuperPaymasterV2.sol (核心运营合约)
    ├── 实现 IPaymaster 接口
    ├── OperatorAccount[] 多账户管理
    ├── 与 GTokenStaking 交互
    ├── 接收 DVT/BLS Slash 指令
    └── 追踪 aPNTs 余额

GTokenStaking.sol (质押管理)
    ├── GToken → sGToken 转换
    ├── Slash感知份额计算
    ├── 7天解质押锁定
    └── 30 GT 最低质押

xPNTsFactory.sol (社区积分工厂)
    ├── 部署 xPNTsToken
    ├── AI预测建议充值金额
    └── 预授权配置

xPNTsToken.sol (社区积分Token)
    ├── ERC20 + EIP-2612 Permit
    ├── Override allowance() 预授权
    └── 与 aPNTs 1:1 兑换

MySBT.sol (社区身份Token)
    ├── ERC721 Non-Transferable
    ├── 社区活跃度追踪
    ├── 0.2 GT mint质押 + 0.1 GT burn费用
    └── 声誉系统集成

DVTValidator.sol (分布式验证节点)
    ├── 13个独立节点
    ├── 每小时检查 aPNTs 余额
    └── 提交验证记录到 BLS

BLSAggregator.sol (签名聚合器)
    ├── BLS签名聚合
    ├── 7/13 阈值验证
    └── 执行 Slash 到 SuperPaymaster
```

---

## 1. SuperPaymasterV2.sol

### 核心功能
- 实现标准 IPaymaster 接口（ERC-4337）
- 管理多个 Operator 账户
- 追踪 aPNTs 余额并与 xPNTs 兑换
- 执行 Slash 惩罚
- 声誉系统管理

### 关键数据结构

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@account-abstraction/contracts/interfaces/IPaymaster.sol";

contract SuperPaymasterV2 is IPaymaster {

    struct OperatorAccount {
        // 质押信息
        uint256 sGTokenLocked;      // 锁定的sGToken数量
        uint256 stakedAt;           // 质押时间

        // 运营余额
        uint256 aPNTsBalance;       // 当前aPNTs余额
        uint256 totalSpent;         // 累计消耗
        uint256 lastRefillTime;     // 最后充值时间
        uint256 minBalanceThreshold;// 最低余额阈值 (默认100 aPNTs)

        // 社区配置
        address[] supportedSBTs;    // 支持的SBT列表
        address xPNTsToken;         // 社区积分Token

        // 声誉系统
        uint256 reputationScore;    // 声誉分数 (Fibonacci等级)
        uint256 consecutiveDays;    // 连续运营天数
        uint256 totalTxSponsored;   // 赞助交易总数
        uint256 reputationLevel;    // 当前等级 (1-12)

        // 监控状态
        uint256 lastCheckTime;      // 最后检查时间
        bool isPaused;              // 是否暂停
        SlashRecord[] slashHistory; // 惩罚历史
    }

    struct SlashRecord {
        uint256 timestamp;          // 惩罚时间
        uint256 amount;             // 惩罚金额 (sGToken)
        uint256 reputationLoss;     // 声誉损失
        string reason;              // 惩罚原因
        SlashLevel level;           // 惩罚等级
    }

    enum SlashLevel {
        WARNING,                    // 仅警告
        MINOR,                      // 5% slash
        MAJOR                       // 10% slash + pause
    }

    // 状态变量
    mapping(address => OperatorAccount) public accounts;
    address public immutable GTOKEN_STAKING;
    address public immutable REGISTRY;
    address public immutable DVT_AGGREGATOR;

    uint256 public constant MIN_STAKE = 30 ether; // 30 GToken
    uint256 public constant MIN_APNTS_BALANCE = 100 ether; // 100 aPNTs

    // Fibonacci 声誉等级
    uint256[12] public REPUTATION_LEVELS = [
        1 ether,   // Level 1
        1 ether,   // Level 2
        2 ether,   // Level 3
        3 ether,   // Level 4
        5 ether,   // Level 5
        8 ether,   // Level 6
        13 ether,  // Level 7
        21 ether,  // Level 8
        34 ether,  // Level 9
        55 ether,  // Level 10
        89 ether,  // Level 11
        144 ether  // Level 12
    ];

    // 事件
    event OperatorRegistered(address indexed operator, uint256 stakedAmount);
    event aPNTsDeposited(address indexed operator, uint256 amount);
    event TransactionSponsored(address indexed operator, address indexed user, uint256 cost);
    event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level);
    event ReputationUpdated(address indexed operator, uint256 newScore, uint256 newLevel);

    /// @notice 注册新的 Operator
    /// @param sGTokenAmount 质押的sGToken数量
    /// @param supportedSBTs 支持的SBT列表
    /// @param xPNTsToken 社区积分Token地址
    function registerOperator(
        uint256 sGTokenAmount,
        address[] memory supportedSBTs,
        address xPNTsToken
    ) external {
        require(sGTokenAmount >= MIN_STAKE, "Insufficient stake");
        require(accounts[msg.sender].stakedAt == 0, "Already registered");

        // 从 GTokenStaking 转入 sGToken
        IGTokenStaking(GTOKEN_STAKING).lockStake(msg.sender, sGTokenAmount);

        accounts[msg.sender] = OperatorAccount({
            sGTokenLocked: sGTokenAmount,
            stakedAt: block.timestamp,
            aPNTsBalance: 0,
            totalSpent: 0,
            lastRefillTime: 0,
            minBalanceThreshold: MIN_APNTS_BALANCE,
            supportedSBTs: supportedSBTs,
            xPNTsToken: xPNTsToken,
            reputationScore: 0,
            consecutiveDays: 0,
            totalTxSponsored: 0,
            reputationLevel: 1,
            lastCheckTime: block.timestamp,
            isPaused: false,
            slashHistory: new SlashRecord[](0)
        });

        emit OperatorRegistered(msg.sender, sGTokenAmount);
    }

    /// @notice 充值 aPNTs (从 xPNTs 1:1兑换)
    /// @param amount 充值金额
    function depositAPNTs(uint256 amount) external {
        require(accounts[msg.sender].stakedAt > 0, "Not registered");

        address xPNTsToken = accounts[msg.sender].xPNTsToken;
        require(xPNTsToken != address(0), "xPNTs not configured");

        // 从用户转入 xPNTs (预授权已配置，无需 approve)
        IxPNTsToken(xPNTsToken).burn(msg.sender, amount);

        accounts[msg.sender].aPNTsBalance += amount;
        accounts[msg.sender].lastRefillTime = block.timestamp;

        emit aPNTsDeposited(msg.sender, amount);
    }

    /// @notice IPaymaster 接口实现 - 验证用户操作
    function validatePaymasterUserOp(
        UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override returns (bytes memory context, uint256 validationData) {
        // 1. 检查用户是否持有 SBT
        address operator = _extractOperator(userOp.paymasterAndData);
        address user = userOp.sender;

        require(!accounts[operator].isPaused, "Operator paused");
        require(_hasSBT(user, accounts[operator].supportedSBTs), "No SBT");
        require(accounts[operator].aPNTsBalance >= maxCost, "Insufficient aPNTs");

        // 2. 预扣费用
        accounts[operator].aPNTsBalance -= maxCost;

        // 3. 返回上下文（用于 postOp 退款）
        context = abi.encode(operator, user, maxCost);
        validationData = 0; // 验证通过
    }

    /// @notice IPaymaster 接口实现 - 交易后处理
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost
    ) internal override {
        (address operator, address user, uint256 maxCost) = abi.decode(
            context,
            (address, address, uint256)
        );

        if (mode == PostOpMode.opSucceeded || mode == PostOpMode.opReverted) {
            // 退还未使用的费用
            uint256 refund = maxCost - actualGasCost;
            accounts[operator].aPNTsBalance += refund;
            accounts[operator].totalSpent += actualGasCost;
            accounts[operator].totalTxSponsored += 1;

            emit TransactionSponsored(operator, user, actualGasCost);

            // 更新声誉
            _updateReputation(operator);
        }
    }

    /// @notice 执行 Slash (仅DVT Aggregator可调用)
    /// @param operator 被惩罚的Operator
    /// @param level 惩罚等级
    /// @param proof BLS聚合签名证明
    function executeSlashWithBLS(
        address operator,
        SlashLevel level,
        bytes memory proof
    ) external {
        require(msg.sender == DVT_AGGREGATOR, "Only DVT Aggregator");

        uint256 slashAmount;
        uint256 reputationLoss;

        if (level == SlashLevel.WARNING) {
            reputationLoss = 10;
        } else if (level == SlashLevel.MINOR) {
            slashAmount = accounts[operator].sGTokenLocked * 5 / 100; // 5%
            reputationLoss = 20;
        } else if (level == SlashLevel.MAJOR) {
            slashAmount = accounts[operator].sGTokenLocked * 10 / 100; // 10%
            reputationLoss = 50;
            accounts[operator].isPaused = true;
        }

        if (slashAmount > 0) {
            accounts[operator].sGTokenLocked -= slashAmount;
            IGTokenStaking(GTOKEN_STAKING).slash(operator, slashAmount, "Low aPNTs balance");
        }

        accounts[operator].reputationScore = accounts[operator].reputationScore > reputationLoss
            ? accounts[operator].reputationScore - reputationLoss
            : 0;

        accounts[operator].slashHistory.push(SlashRecord({
            timestamp: block.timestamp,
            amount: slashAmount,
            reputationLoss: reputationLoss,
            reason: "aPNTs balance below threshold",
            level: level
        }));

        emit OperatorSlashed(operator, slashAmount, level);
    }

    /// @notice 更新声誉
    function _updateReputation(address operator) internal {
        OperatorAccount storage account = accounts[operator];

        // 连续运营天数检查
        uint256 daysSinceLastCheck = (block.timestamp - account.lastCheckTime) / 1 days;
        if (daysSinceLastCheck > 0) {
            account.consecutiveDays += daysSinceLastCheck;
            account.lastCheckTime = block.timestamp;
        }

        // 检查升级条件
        if (account.consecutiveDays >= 30 &&
            account.totalTxSponsored >= 1000 &&
            account.aPNTsBalance * 100 / account.minBalanceThreshold >= 150) {

            uint256 currentLevel = account.reputationLevel;
            if (currentLevel < 12) {
                account.reputationLevel = currentLevel + 1;
                account.reputationScore = REPUTATION_LEVELS[currentLevel]; // 下一级要求

                emit ReputationUpdated(operator, account.reputationScore, account.reputationLevel);
            }
        }
    }

    /// @notice 检查用户是否持有指定SBT
    function _hasSBT(address user, address[] memory sbts) internal view returns (bool) {
        for (uint i = 0; i < sbts.length; i++) {
            if (IERC721(sbts[i]).balanceOf(user) > 0) {
                return true;
            }
        }
        return false;
    }

    /// @notice 从 paymasterAndData 提取 operator 地址
    function _extractOperator(bytes calldata paymasterAndData) internal pure returns (address) {
        // paymasterAndData 格式: [paymaster address (20 bytes)][operator address (20 bytes)][...]
        require(paymasterAndData.length >= 40, "Invalid data");
        return address(bytes20(paymasterAndData[20:40]));
    }
}
```

---

## 2. GTokenStaking.sol

### 核心功能
- GToken → sGToken 质押转换
- Slash感知份额计算
- 7天解质押锁定期

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract GTokenStaking {

    struct StakeInfo {
        uint256 amount;             // 质押的GToken数量
        uint256 sGTokenShares;      // 持有的sGToken份额
        uint256 stakedAt;           // 质押时间
        uint256 unstakeRequestedAt; // 请求解质押时间
    }

    mapping(address => StakeInfo) public stakes;

    uint256 public totalStaked;     // 总质押量
    uint256 public totalSlashed;    // 总Slash量
    uint256 public totalShares;     // 总份额

    address public GTOKEN;
    address public SUPERPAYMASTER;

    uint256 public constant UNSTAKE_DELAY = 7 days;
    uint256 public constant MIN_STAKE = 30 ether;

    /// @notice 质押 GToken，获得 sGToken 份额
    function stake(uint256 amount) external returns (uint256 shares) {
        require(amount >= MIN_STAKE, "Below minimum");

        // 转入 GToken
        IERC20(GTOKEN).transferFrom(msg.sender, address(this), amount);

        // 计算份额 (Slash感知)
        if (totalShares == 0) {
            shares = amount;
        } else {
            shares = amount * totalShares / (totalStaked - totalSlashed);
        }

        stakes[msg.sender] = StakeInfo({
            amount: amount,
            sGTokenShares: shares,
            stakedAt: block.timestamp,
            unstakeRequestedAt: 0
        });

        totalStaked += amount;
        totalShares += shares;
    }

    /// @notice 查询用户实际余额 (Slash后)
    function balanceOf(address user) public view returns (uint256) {
        StakeInfo memory info = stakes[user];
        if (info.sGTokenShares == 0) return 0;

        // 份额 * (总质押 - 总Slash) / 总份额
        return info.sGTokenShares * (totalStaked - totalSlashed) / totalShares;
    }

    /// @notice 执行 Slash (仅SuperPaymaster可调用)
    function slash(address operator, uint256 amount, string memory reason) external {
        require(msg.sender == SUPERPAYMASTER, "Only SuperPaymaster");
        require(amount <= balanceOf(operator), "Exceeds balance");

        totalSlashed += amount;

        emit Slashed(operator, amount, reason);
    }

    /// @notice 请求解质押
    function requestUnstake() external {
        require(stakes[msg.sender].sGTokenShares > 0, "No stake");
        stakes[msg.sender].unstakeRequestedAt = block.timestamp;
    }

    /// @notice 执行解质押 (7天后)
    function unstake() external {
        StakeInfo memory info = stakes[msg.sender];
        require(info.unstakeRequestedAt > 0, "Not requested");
        require(block.timestamp >= info.unstakeRequestedAt + UNSTAKE_DELAY, "Delay not passed");

        uint256 amount = balanceOf(msg.sender);

        totalStaked -= info.amount;
        totalSlashed -= (info.amount - amount); // 调整Slash计数
        totalShares -= info.sGTokenShares;

        delete stakes[msg.sender];

        IERC20(GTOKEN).transfer(msg.sender, amount);
    }

    event Slashed(address indexed operator, uint256 amount, string reason);
}
```

---

## 3. Registry.sol (Enhanced with Community Profiles)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract Registry {

    struct CommunityProfile {
        // 基本信息
        string name;
        string ensName;
        string description;
        string website;
        string logoURI;

        // 社交链接
        string twitterHandle;
        string githubOrg;
        string telegramGroup;

        // Token & SBT
        address xPNTsToken;
        address[] supportedSBTs;

        // Paymaster配置
        PaymasterMode mode;
        address paymasterAddress;
        address community;

        // 元数据
        uint256 registeredAt;
        uint256 lastUpdatedAt;
        bool isActive;
        uint256 memberCount;
    }

    enum PaymasterMode { INDEPENDENT, SUPER }

    mapping(address => CommunityProfile) public communities;
    mapping(string => address) public communityByName;
    mapping(string => address) public communityByENS;
    mapping(address => address) public communityBySBT;

    /// @notice 注册社区
    function registerCommunity(CommunityProfile memory profile) external {
        require(communities[msg.sender].registeredAt == 0, "Already registered");

        profile.community = msg.sender;
        profile.registeredAt = block.timestamp;
        profile.lastUpdatedAt = block.timestamp;
        profile.isActive = true;

        communities[msg.sender] = profile;
        communityByName[profile.name] = msg.sender;
        communityByENS[profile.ensName] = msg.sender;

        for (uint i = 0; i < profile.supportedSBTs.length; i++) {
            communityBySBT[profile.supportedSBTs[i]] = msg.sender;
        }
    }

    /// @notice 查询社区信息
    function getCommunityProfile(address communityId) external view returns (CommunityProfile memory) {
        return communities[communityId];
    }
}
```

---

**文档版本**: v2.0.0
**最后更新**: 2025-10-22
**状态**: 合约设计阶段
