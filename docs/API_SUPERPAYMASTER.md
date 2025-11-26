# SuperPaymasterV2 API Reference

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
