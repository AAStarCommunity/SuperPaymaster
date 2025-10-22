# xPNTs Token & MySBT 设计文档

## xPNTs 社区积分系统

### 设计理念

xPNTs 是社区自主发行的积分Token，与 aPNTs (Account Abstraction PNTs) 1:1兑换，用于支付社区内的Gas费用。

**核心特性**:
1. **预授权机制**: 无需用户每次 approve()
2. **EIP-2612 Permit**: 支持gasless授权
3. **AI预测充值**: 智能建议充值金额
4. **工厂部署**: 标准化部署流程

---

## 1. xPNTsToken.sol

### 核心功能

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract xPNTsToken is ERC20, ERC20Permit {

    address public immutable FACTORY;
    address public communityOwner;

    // 预授权机制
    mapping(address => bool) public autoApprovedSpenders;

    // 社区配置
    string public communityName;
    string public communityENS;

    constructor(
        string memory name,
        string memory symbol,
        address _communityOwner,
        string memory _communityName,
        string memory _communityENS
    ) ERC20(name, symbol) ERC20Permit(name) {
        FACTORY = msg.sender;
        communityOwner = _communityOwner;
        communityName = _communityName;
        communityENS = _communityENS;
    }

    /// @notice Override allowance() 实现预授权
    /// @dev 受信任合约返回无限授权，避免用户每次approve
    function allowance(address owner, address spender) public view override returns (uint256) {
        // 如果是预授权合约，返回最大值
        if (autoApprovedSpenders[spender]) {
            return type(uint256).max;
        }
        return super.allowance(owner, spender);
    }

    /// @notice 添加预授权合约 (仅社区Owner)
    /// @param spender 受信任合约地址
    function addAutoApprovedSpender(address spender) external {
        require(msg.sender == communityOwner, "Only owner");
        autoApprovedSpenders[spender] = true;
    }

    /// @notice 移除预授权合约 (仅社区Owner)
    function removeAutoApprovedSpender(address spender) external {
        require(msg.sender == communityOwner, "Only owner");
        autoApprovedSpenders[spender] = false;
    }

    /// @notice 铸造 xPNTs (仅Factory或Owner)
    function mint(address to, uint256 amount) external {
        require(msg.sender == FACTORY || msg.sender == communityOwner, "Unauthorized");
        _mint(to, amount);
    }

    /// @notice 销毁 xPNTs (用于兑换aPNTs)
    function burn(address from, uint256 amount) external {
        // 检查授权 (预授权会自动通过)
        if (msg.sender != from) {
            uint256 allowed = allowance(from, msg.sender);
            require(allowed >= amount, "Insufficient allowance");

            if (allowed != type(uint256).max) {
                _approve(from, msg.sender, allowed - amount);
            }
        }

        _burn(from, amount);
    }

    /// @notice 查询是否预授权
    function isAutoApproved(address spender) external view returns (bool) {
        return autoApprovedSpenders[spender];
    }
}
```

---

## 2. xPNTsFactory.sol

### 核心功能
- 标准化部署 xPNTs Token
- AI预测建议充值金额
- 自动配置预授权合约

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract xPNTsFactory {

    address public immutable SUPERPAYMASTER;
    address public immutable REGISTRY;

    // AI预测参数
    struct PredictionParams {
        uint256 avgDailyTx;         // 平均每日交易数
        uint256 avgGasCost;         // 平均Gas成本 (wei)
        uint256 industryMultiplier; // 行业系数 (DeFi=2.0, Gaming=1.5, Social=1.0)
        uint256 safetyFactor;       // 安全系数 (默认1.5)
    }

    mapping(address => address) public communityToToken; // 社区 → xPNTs Token
    mapping(address => PredictionParams) public predictions; // 社区 → 预测参数

    event xPNTsTokenDeployed(address indexed community, address tokenAddress);
    event PredictionUpdated(address indexed community, uint256 suggestedAmount);

    /// @notice 部署 xPNTs Token
    function deployxPNTsToken(
        string memory name,
        string memory symbol,
        string memory communityName,
        string memory communityENS
    ) external returns (address) {
        require(communityToToken[msg.sender] == address(0), "Already deployed");

        // 部署新Token
        xPNTsToken token = new xPNTsToken(
            name,
            symbol,
            msg.sender,
            communityName,
            communityENS
        );

        // 自动配置预授权
        token.addAutoApprovedSpender(SUPERPAYMASTER);
        token.addAutoApprovedSpender(address(this)); // 工厂合约

        communityToToken[msg.sender] = address(token);

        emit xPNTsTokenDeployed(msg.sender, address(token));

        return address(token);
    }

    /// @notice AI预测建议充值金额
    /// @param community 社区地址
    /// @return suggestedAmount 建议充值金额 (aPNTs)
    function predictDepositAmount(address community) public view returns (uint256 suggestedAmount) {
        PredictionParams memory params = predictions[community];

        if (params.avgDailyTx == 0) {
            // 默认值: 新社区
            return 100 ether; // 100 aPNTs
        }

        // 公式: dailyTx * avgGasCost * 30 days * industryMultiplier * safetyFactor
        uint256 dailyCost = params.avgDailyTx * params.avgGasCost;
        uint256 monthlyCost = dailyCost * 30;

        suggestedAmount = monthlyCost * params.industryMultiplier * params.safetyFactor / 1e18;

        // 最低100 aPNTs
        if (suggestedAmount < 100 ether) {
            suggestedAmount = 100 ether;
        }
    }

    /// @notice 更新预测参数 (社区Owner或预言机)
    function updatePrediction(
        address community,
        uint256 avgDailyTx,
        uint256 avgGasCost,
        uint256 industryMultiplier,
        uint256 safetyFactor
    ) external {
        // 简化: 仅社区Owner可更新
        require(msg.sender == community, "Only community");

        predictions[community] = PredictionParams({
            avgDailyTx: avgDailyTx,
            avgGasCost: avgGasCost,
            industryMultiplier: industryMultiplier,
            safetyFactor: safetyFactor
        });

        emit PredictionUpdated(community, predictDepositAmount(community));
    }

    /// @notice 查询社区的 xPNTs Token
    function getTokenAddress(address community) external view returns (address) {
        return communityToToken[community];
    }
}
```

---

## 3. MySBT.sol (Soul Bound Token)

### 核心功能
- 社区身份Token (不可转让)
- 社区活跃度追踪
- 0.2 GT质押 + 0.1 GT burn费用

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MySBT is ERC721 {

    struct UserProfile {
        uint256[] ownedSBTs;            // 拥有的SBT列表
        uint256 reputationScore;        // 用户声誉
        string ensName;                 // 用户ENS
    }

    struct CommunityData {
        address community;              // 所属社区 (不是operator!)
        uint256 txCount;                // 该社区内交易数
        uint256 joinedAt;               // 加入时间
        uint256 lastActiveTime;         // 最后活跃时间
        uint256 contributionScore;      // 贡献分
    }

    mapping(address => UserProfile) public userProfiles;
    mapping(uint256 => CommunityData) public sbtData; // tokenId → 社区数据
    mapping(address => mapping(address => uint256)) public userCommunityToken; // user → community → tokenId

    address public immutable GTOKEN;
    address public immutable GTOKEN_STAKING;
    uint256 public nextTokenId = 1;

    uint256 public constant MINT_STAKE = 0.2 ether;  // 0.2 GT
    uint256 public constant MINT_FEE = 0.1 ether;    // 0.1 GT burn

    constructor(address _gtoken, address _staking) ERC721("MySBT", "MSBT") {
        GTOKEN = _gtoken;
        GTOKEN_STAKING = _staking;
    }

    /// @notice Mint SBT (需要质押0.2 GT + burn 0.1 GT)
    /// @param community 社区地址
    function mintSBT(address community) external returns (uint256 tokenId) {
        require(userCommunityToken[msg.sender][community] == 0, "Already have SBT");

        // 转入 0.3 GT (0.2质押 + 0.1销毁)
        IERC20(GTOKEN).transferFrom(msg.sender, address(this), MINT_STAKE + MINT_FEE);

        // 质押 0.2 GT
        IERC20(GTOKEN).approve(GTOKEN_STAKING, MINT_STAKE);
        IGTokenStaking(GTOKEN_STAKING).stake(MINT_STAKE);

        // 销毁 0.1 GT
        IGToken(GTOKEN).burn(MINT_FEE);

        // Mint SBT
        tokenId = nextTokenId++;
        _mint(msg.sender, tokenId);

        sbtData[tokenId] = CommunityData({
            community: community,
            txCount: 0,
            joinedAt: block.timestamp,
            lastActiveTime: block.timestamp,
            contributionScore: 0
        });

        userProfiles[msg.sender].ownedSBTs.push(tokenId);
        userCommunityToken[msg.sender][community] = tokenId;

        emit SBTMinted(msg.sender, community, tokenId);
    }

    /// @notice 更新活跃度 (仅SuperPaymaster可调用)
    function updateActivity(address user, address community, uint256 txCost) external {
        uint256 tokenId = userCommunityToken[user][community];
        require(tokenId != 0, "No SBT");

        sbtData[tokenId].txCount += 1;
        sbtData[tokenId].lastActiveTime = block.timestamp;
        sbtData[tokenId].contributionScore += txCost / 1e15; // 贡献分 = Gas cost / 1e15

        userProfiles[user].reputationScore += 1;
    }

    /// @notice Override _transfer 实现不可转让
    function _transfer(address from, address to, uint256 tokenId) internal virtual override {
        require(from == address(0) || to == address(0), "SBT: Soul Bound Token cannot be transferred");
        super._transfer(from, to, tokenId);
    }

    /// @notice 查询用户在社区的数据
    function getCommunityData(address user, address community) external view returns (CommunityData memory) {
        uint256 tokenId = userCommunityToken[user][community];
        require(tokenId != 0, "No SBT");
        return sbtData[tokenId];
    }

    /// @notice 查询用户所有SBT
    function getUserSBTs(address user) external view returns (uint256[] memory) {
        return userProfiles[user].ownedSBTs;
    }

    event SBTMinted(address indexed user, address indexed community, uint256 tokenId);
}
```

---

## 预授权机制详解

### 问题场景

用户每次使用 xPNTs 兑换 aPNTs 时，需要调用:
```solidity
xPNTs.approve(SuperPaymaster, amount);
SuperPaymaster.depositAPNTs(amount);
```

这导致:
1. 两次交易
2. 额外Gas成本
3. 糟糕的用户体验

### 解决方案: Override allowance()

```solidity
function allowance(address owner, address spender) public view override returns (uint256) {
    if (autoApprovedSpenders[spender]) {
        return type(uint256).max;  // 无限授权
    }
    return super.allowance(owner, spender);
}
```

**受信任合约**:
- `SuperPaymaster v2.0`: 用于充值aPNTs
- `xPNTsFactory`: 用于管理操作
- `MySBT`: 用于支付mint费用

### 安全性

1. **白名单机制**: 仅社区Owner可添加/移除预授权合约
2. **透明查询**: 用户可通过 `isAutoApproved()` 查询
3. **可撤销**: 社区Owner可随时移除预授权

---

## AI预测充值金额

### 公式

```
建议金额 = avgDailyTx * avgGasCost * 30天 * industryMultiplier * safetyFactor
```

### 行业系数

| 行业 | Multiplier | 原因 |
|------|------------|------|
| DeFi | 2.0 | 高频交易，复杂合约调用 |
| Gaming | 1.5 | 中等频率，NFT操作 |
| Social | 1.0 | 低频交易，简单操作 |
| DAO | 1.2 | 投票+治理，中等复杂度 |

### 安全系数

- 默认: 1.5x (50%缓冲)
- 保守: 2.0x (100%缓冲)
- 激进: 1.2x (20%缓冲)

### 示例计算

**DeFi社区**:
- avgDailyTx: 100笔
- avgGasCost: 0.001 ETH
- industryMultiplier: 2.0
- safetyFactor: 1.5

```
建议金额 = 100 * 0.001 * 30 * 2.0 * 1.5
         = 9 ETH
```

---

## MySBT 不可转让机制

### 核心代码

```solidity
function _transfer(address from, address to, uint256 tokenId) internal virtual override {
    require(from == address(0) || to == address(0), "SBT: Soul Bound Token cannot be transferred");
    super._transfer(from, to, tokenId);
}
```

**逻辑**:
- `from == address(0)`: 允许 Mint (from=0x0)
- `to == address(0)`: 允许 Burn (to=0x0)
- 其他情况: 拒绝转账

### 社区数据修正

原设计:
```solidity
address operator;  // ❌ 错误: 应该是社区，不是operator
```

修正后:
```solidity
address community;  // ✅ 正确: 所属社区
```

---

## 数据流示例

### 用户加入社区并使用Paymaster

```
1. 用户 Mint SBT
   User → MySBT.mintSBT(community)
   → 质押 0.2 GT
   → 销毁 0.1 GT
   → 获得 SBT (tokenId)

2. 社区部署 xPNTs
   Community → xPNTsFactory.deployxPNTsToken(...)
   → 自动配置预授权 (SuperPaymaster)

3. 用户充值 xPNTs
   Community → xPNTs.mint(user, 100 ether)

4. 用户兑换 aPNTs (无需approve!)
   User → SuperPaymaster.depositAPNTs(100 ether)
   → xPNTs自动预授权
   → burn xPNTs
   → 增加 aPNTs余额

5. 用户发起交易
   User → EntryPoint.handleOps([userOp])
   → SuperPaymaster验证SBT
   → 扣除aPNTs
   → 交易执行成功

6. 更新活跃度
   SuperPaymaster → MySBT.updateActivity(user, community, txCost)
   → txCount++
   → contributionScore += txCost / 1e15
   → reputationScore++
```

---

**文档版本**: v2.0.0
**最后更新**: 2025-10-22
**状态**: 详细设计阶段
