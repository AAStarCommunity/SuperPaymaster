# SuperPaymasterV2 API Reference

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

## Contract Information

- **Version**: v2.3.3
- **Sepolia Address**: `0x7c3c355d9aa4723402bec2a35b61137b8a10d5db`
- **EntryPoint**: v0.7 (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`)

## Data Structures

### OperatorAccount (struct)

```solidity
struct OperatorAccount {
    address xPNTsToken;         // Community xPNTs token
    address treasury;           // Treasury address
    bool isPaused;              // Paused status
    uint256 aPNTsBalance;       // aPNTs balance
    uint256 totalSpent;         // Total spent
    uint256 totalTxSponsored;   // Sponsored tx count
    uint256 stGTokenLocked;     // Locked stake
    uint256 exchangeRate;       // xPNTs <-> aPNTs rate (18 decimals)
    uint256 reputationScore;    // Reputation score
    uint256 reputationLevel;    // Level (1-12, Fibonacci)
    uint256 stakedAt;           // Stake timestamp
    uint256 lastRefillTime;     // Last refill time
    uint256 lastCheckTime;      // Last check time
    uint256 minBalanceThreshold;// Min balance threshold
    uint256 consecutiveDays;    // Consecutive active days
}
```

### SBTHolder (struct)

```solidity
struct SBTHolder {
    address holder;     // Holder address
    uint256 tokenId;    // MySBT token ID
}
```

### SlashLevel (enum)

```solidity
enum SlashLevel {
    WARNING,    // Warning only
    MINOR,      // 5% slash
    MAJOR       // 10% slash + pause
}
```

---

## Operator Functions

### depositAPNTs

Deposit aPNTs and register as operator.

```solidity
function depositAPNTs(
    address operator,
    uint256 amount,
    address xPNTsToken,
    address treasury,
    uint256 exchangeRate
) external
```

**Parameters:**
- `operator`: Operator address
- `amount`: aPNTs amount to deposit
- `xPNTsToken`: Community gas token
- `treasury`: Where user payments go
- `exchangeRate`: xPNTs:aPNTs rate (18 decimals, 1e18 = 1:1)

**Events:** `OperatorDeposited`

---

### withdrawAPNTs

Withdraw aPNTs balance.

```solidity
function withdrawAPNTs(uint256 amount) external
```

**Events:** `OperatorWithdrawn`

---

### updateOperatorConfig

Update operator configuration.

```solidity
function updateOperatorConfig(
    address xPNTsToken,
    address treasury,
    uint256 exchangeRate,
    uint256 minBalanceThreshold
) external
```

**Events:** `OperatorConfigUpdated`

---

### pauseOperator / unpauseOperator

```solidity
function pauseOperator() external
function unpauseOperator() external
```

**Events:** `OperatorPaused`, `OperatorUnpaused`

---

## SBT Registry Functions (v2.3.3)

### registerSBTHolder

Called by MySBT on mint.

```solidity
function registerSBTHolder(
    address holder,
    uint256 tokenId
) external
```

**Access:** MySBT contract only

---

### unregisterSBTHolder

Called by MySBT on burn.

```solidity
function unregisterSBTHolder(address holder) external
```

**Access:** MySBT contract only

---

## Read Functions

### accounts

Get operator account info.

```solidity
function accounts(address operator)
    external view
    returns (OperatorAccount memory)
```

---

### sbtHolders

Get SBT holder info.

```solidity
function sbtHolders(address holder)
    external view
    returns (SBTHolder memory)
```

---

### tokenIdToHolder

Get holder by token ID.

```solidity
function tokenIdToHolder(uint256 tokenId)
    external view
    returns (address)
```

---

### userDebts

Get user's total debt.

```solidity
function userDebts(address user)
    external view
    returns (uint256)
```

---

### userDebtsByToken

Get user's debt by token.

```solidity
function userDebtsByToken(address user, address token)
    external view
    returns (uint256)
```

---

### getOperatorForUser

Find operator for a user based on SBT.

```solidity
function getOperatorForUser(address user)
    external view
    returns (address operator)
```

---

### calculateGasCost

Calculate gas cost in aPNTs.

```solidity
function calculateGasCost(uint256 gasUsed)
    external view
    returns (uint256 aPNTsCost)
```

---

### getETHPrice

Get cached ETH/USD price.

```solidity
function getETHPrice()
    external view
    returns (int256 price, uint256 updatedAt)
```

---

## Admin Functions (Owner Only)

### setAPNTsToken

```solidity
function setAPNTsToken(address _aPNTs) external onlyOwner
```

---

### setSuperPaymasterTreasury

```solidity
function setSuperPaymasterTreasury(address _treasury) external onlyOwner
```

---

### setDVTAggregator

```solidity
function setDVTAggregator(address _dvt) external onlyOwner
```

---

### setDefaultSBT

```solidity
function setDefaultSBT(address _sbt) external onlyOwner
```

---

### slash

Slash operator's stake.

```solidity
function slash(
    address operator,
    uint256 amount,
    string memory reason,
    SlashLevel level
) external onlyOwner
```

**Events:** `OperatorSlashed`

---

## ERC-4337 Paymaster Functions

### validatePaymasterUserOp

Validate UserOperation (called by EntryPoint).

```solidity
function validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) external returns (bytes memory context, uint256 validationData)
```

---

### postOp

Post-operation handler (called by EntryPoint).

```solidity
function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 actualUserOpFeePerGas
) external
```

---

## Events

```solidity
event OperatorDeposited(address indexed operator, uint256 amount);
event OperatorWithdrawn(address indexed operator, uint256 amount);
event OperatorConfigUpdated(address indexed operator);
event OperatorPaused(address indexed operator);
event OperatorUnpaused(address indexed operator);
event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level, string reason);
event GasSponsored(address indexed operator, address indexed user, uint256 gasUsed, uint256 aPNTsCost);
event SBTHolderRegistered(address indexed holder, uint256 tokenId);
event SBTHolderUnregistered(address indexed holder);
event UserDebtRecorded(address indexed user, address indexed token, uint256 amount);
```

## Errors

```solidity
error OperatorNotFound(address operator);
error OperatorPaused(address operator);
error InsufficientBalance(uint256 available, uint256 required);
error InvalidOperator(address operator);
error InvalidUser(address user);
error UnauthorizedCaller(address caller);
error StalePriceData(uint256 updatedAt);
error PriceOutOfBounds(int256 price);
error UserNotSBTHolder(address user);
error DebtExceedsLimit(address user, uint256 debt);
```

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MIN_DEPOSIT` | 10 ether | Min aPNTs deposit |
| `MAX_GAS_LIMIT` | 1,000,000 | Max gas per operation |
| `PRICE_STALENESS` | 1 hour | Max price age |
| `MIN_ETH_PRICE` | $100 | Min valid ETH price |
| `MAX_ETH_PRICE` | $100,000 | Max valid ETH price |
| `VERSION` | "2.3.3" | Contract version |

## PaymasterAndData Format

For ERC-4337 v0.7, the `paymasterAndData` field is 72 bytes:

```
| Paymaster (20) | VerificationGasLimit (16) | PostOpGasLimit (16) | Operator (20) |
```

```javascript
const paymasterAndData = concat([
  SUPERPAYMASTER_ADDRESS,                              // 20 bytes
  pad(toHex(150000n), { size: 16, dir: 'left' }),     // 16 bytes
  pad(toHex(100000n), { size: 16, dir: 'left' }),     // 16 bytes
  OPERATOR_ADDRESS                                     // 20 bytes
]);
```

---

<a name="chinese"></a>

# SuperPaymasterV2 API 参考

**[English](#english)** | **[中文](#chinese)**

---

## 合约信息

- **版本**: v2.3.3
- **Sepolia 地址**: `0x7c3c355d9aa4723402bec2a35b61137b8a10d5db`
- **EntryPoint**: v0.7 (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`)

## 数据结构

### OperatorAccount (结构体)

```solidity
struct OperatorAccount {
    address xPNTsToken;         // 社区 xPNTs 代币
    address treasury;           // 财务地址
    bool isPaused;              // 暂停状态
    uint256 aPNTsBalance;       // aPNTs 余额
    uint256 totalSpent;         // 总支出
    uint256 totalTxSponsored;   // 赞助交易数
    uint256 stGTokenLocked;     // 锁定的质押
    uint256 exchangeRate;       // xPNTs <-> aPNTs 汇率（18 位小数）
    uint256 reputationScore;    // 声誉分数
    uint256 reputationLevel;    // 等级（1-12，斐波那契）
    uint256 stakedAt;           // 质押时间戳
    uint256 lastRefillTime;     // 最后充值时间
    uint256 lastCheckTime;      // 最后检查时间
    uint256 minBalanceThreshold;// 最低余额阈值
    uint256 consecutiveDays;    // 连续活跃天数
}
```

### SBTHolder (结构体)

```solidity
struct SBTHolder {
    address holder;     // 持有者地址
    uint256 tokenId;    // MySBT 代币 ID
}
```

### SlashLevel (枚举)

```solidity
enum SlashLevel {
    WARNING,    // 仅警告
    MINOR,      // 5% 惩罚
    MAJOR       // 10% 惩罚 + 暂停
}
```

---

## 运营商函数

### depositAPNTs

存入 aPNTs 并注册为运营商。

```solidity
function depositAPNTs(
    address operator,
    uint256 amount,
    address xPNTsToken,
    address treasury,
    uint256 exchangeRate
) external
```

**参数:**
- `operator`: 运营商地址
- `amount`: 存入的 aPNTs 数量
- `xPNTsToken`: 社区 Gas 代币
- `treasury`: 用户支付去向
- `exchangeRate`: xPNTs:aPNTs 汇率（18 位小数，1e18 = 1:1）

**事件:** `OperatorDeposited`

---

### withdrawAPNTs

提取 aPNTs 余额。

```solidity
function withdrawAPNTs(uint256 amount) external
```

**事件:** `OperatorWithdrawn`

---

### updateOperatorConfig

更新运营商配置。

```solidity
function updateOperatorConfig(
    address xPNTsToken,
    address treasury,
    uint256 exchangeRate,
    uint256 minBalanceThreshold
) external
```

**事件:** `OperatorConfigUpdated`

---

### pauseOperator / unpauseOperator

```solidity
function pauseOperator() external
function unpauseOperator() external
```

**事件:** `OperatorPaused`, `OperatorUnpaused`

---

## SBT 注册函数 (v2.3.3)

### registerSBTHolder

在 MySBT 铸造时调用。

```solidity
function registerSBTHolder(
    address holder,
    uint256 tokenId
) external
```

**访问权限:** 仅 MySBT 合约

---

### unregisterSBTHolder

在 MySBT 销毁时调用。

```solidity
function unregisterSBTHolder(address holder) external
```

**访问权限:** 仅 MySBT 合约

---

## 读取函数

### accounts

获取运营商账户信息。

```solidity
function accounts(address operator)
    external view
    returns (OperatorAccount memory)
```

---

### sbtHolders

获取 SBT 持有者信息。

```solidity
function sbtHolders(address holder)
    external view
    returns (SBTHolder memory)
```

---

### tokenIdToHolder

通过代币 ID 获取持有者。

```solidity
function tokenIdToHolder(uint256 tokenId)
    external view
    returns (address)
```

---

### userDebts

获取用户的总债务。

```solidity
function userDebts(address user)
    external view
    returns (uint256)
```

---

### userDebtsByToken

按代币获取用户债务。

```solidity
function userDebtsByToken(address user, address token)
    external view
    returns (uint256)
```

---

### getOperatorForUser

根据 SBT 查找用户的运营商。

```solidity
function getOperatorForUser(address user)
    external view
    returns (address operator)
```

---

### calculateGasCost

计算 aPNTs 形式的 Gas 成本。

```solidity
function calculateGasCost(uint256 gasUsed)
    external view
    returns (uint256 aPNTsCost)
```

---

### getETHPrice

获取缓存的 ETH/USD 价格。

```solidity
function getETHPrice()
    external view
    returns (int256 price, uint256 updatedAt)
```

---

## 管理函数（仅所有者）

### setAPNTsToken

```solidity
function setAPNTsToken(address _aPNTs) external onlyOwner
```

---

### setSuperPaymasterTreasury

```solidity
function setSuperPaymasterTreasury(address _treasury) external onlyOwner
```

---

### setDVTAggregator

```solidity
function setDVTAggregator(address _dvt) external onlyOwner
```

---

### setDefaultSBT

```solidity
function setDefaultSBT(address _sbt) external onlyOwner
```

---

### slash

惩罚运营商的质押。

```solidity
function slash(
    address operator,
    uint256 amount,
    string memory reason,
    SlashLevel level
) external onlyOwner
```

**事件:** `OperatorSlashed`

---

## ERC-4337 Paymaster 函数

### validatePaymasterUserOp

验证 UserOperation（由 EntryPoint 调用）。

```solidity
function validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) external returns (bytes memory context, uint256 validationData)
```

---

### postOp

操作后处理程序（由 EntryPoint 调用）。

```solidity
function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 actualUserOpFeePerGas
) external
```

---

## 事件

```solidity
event OperatorDeposited(address indexed operator, uint256 amount);      // 运营商存款
event OperatorWithdrawn(address indexed operator, uint256 amount);      // 运营商提款
event OperatorConfigUpdated(address indexed operator);                   // 运营商配置更新
event OperatorPaused(address indexed operator);                          // 运营商暂停
event OperatorUnpaused(address indexed operator);                        // 运营商取消暂停
event OperatorSlashed(address indexed operator, uint256 amount, SlashLevel level, string reason);  // 运营商被惩罚
event GasSponsored(address indexed operator, address indexed user, uint256 gasUsed, uint256 aPNTsCost);  // Gas 赞助
event SBTHolderRegistered(address indexed holder, uint256 tokenId);     // SBT 持有者注册
event SBTHolderUnregistered(address indexed holder);                     // SBT 持有者注销
event UserDebtRecorded(address indexed user, address indexed token, uint256 amount);  // 用户债务记录
```

## 错误

```solidity
error OperatorNotFound(address operator);                    // 未找到运营商
error OperatorPaused(address operator);                      // 运营商已暂停
error InsufficientBalance(uint256 available, uint256 required);  // 余额不足
error InvalidOperator(address operator);                      // 无效运营商
error InvalidUser(address user);                              // 无效用户
error UnauthorizedCaller(address caller);                     // 未授权调用者
error StalePriceData(uint256 updatedAt);                     // 价格数据过期
error PriceOutOfBounds(int256 price);                        // 价格超出范围
error UserNotSBTHolder(address user);                        // 用户非 SBT 持有者
error DebtExceedsLimit(address user, uint256 debt);          // 债务超限
```

## 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `MIN_DEPOSIT` | 10 ether | 最小 aPNTs 存款 |
| `MAX_GAS_LIMIT` | 1,000,000 | 每次操作最大 Gas |
| `PRICE_STALENESS` | 1 小时 | 最大价格有效期 |
| `MIN_ETH_PRICE` | $100 | 最小有效 ETH 价格 |
| `MAX_ETH_PRICE` | $100,000 | 最大有效 ETH 价格 |
| `VERSION` | "2.3.3" | 合约版本 |

## PaymasterAndData 格式

对于 ERC-4337 v0.7，`paymasterAndData` 字段为 72 字节：

```
| Paymaster (20) | VerificationGasLimit (16) | PostOpGasLimit (16) | Operator (20) |
```

```javascript
const paymasterAndData = concat([
  SUPERPAYMASTER_ADDRESS,                              // 20 字节
  pad(toHex(150000n), { size: 16, dir: 'left' }),     // 16 字节
  pad(toHex(100000n), { size: 16, dir: 'left' }),     // 16 字节
  OPERATOR_ADDRESS                                     // 20 字节
]);
```
