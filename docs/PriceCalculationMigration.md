# PaymasterV4 Price Calculation Migration Guide

**Version**: v4.1 → v4.2
**Date**: 2025-10-26
**Breaking Changes**: Yes
**Audience**: Developers & End Users

---

## Executive Summary

PaymasterV4 price calculation has been fundamentally upgraded from **manual price configuration** to **real-time oracle-based pricing** with **token-level price management**.

### What Changed?

| Aspect | Before (v4.1) | After (v4.2) |
|--------|---------------|--------------|
| **ETH Price Source** | Manual (`gasToUSDRate`) | Chainlink Oracle (real-time) |
| **Token Price Source** | Paymaster (`pntPriceUSD`) | GasToken contract (per-token) |
| **Price Updates** | Owner calls setter functions | Automatic (Chainlink) + Token admin |
| **Exchange Rate** | Single global rate | Per-token with base/derived support |
| **Registry Address** | Mutable (settable) | Immutable (constructor-only) |

### Key Benefits

- ✅ **Real-time pricing**: Chainlink provides live ETH/USD rates
- ✅ **Enhanced security**: Immutable Registry prevents runtime attacks
- ✅ **Token flexibility**: Each GasToken manages its own price
- ✅ **Multi-tier support**: Base tokens (aPNT) + Derived tokens (xPNT)
- ✅ **Automatic calculation**: Effective price = base price × exchange rate

---

## For Developers

### 1. Constructor Signature Changes

#### PaymasterV4

**Before (8 parameters)**:
```solidity
constructor(
    address _entryPoint,
    address _owner,
    address _treasury,
    uint256 _gasToUSDRate,      // ❌ REMOVED
    uint256 _pntPriceUSD,       // ❌ REMOVED
    uint256 _serviceFeeRate,
    uint256 _maxGasCostCap,
    uint256 _minTokenBalance
)
```

**After (7 parameters)**:
```solidity
constructor(
    address _entryPoint,
    address _owner,
    address _treasury,
    address _ethUsdPriceFeed,   // ✅ NEW: Chainlink price feed
    uint256 _serviceFeeRate,
    uint256 _maxGasCostCap,
    uint256 _minTokenBalance
)
```

#### GasTokenV2

**Before (4 parameters)**:
```solidity
constructor(
    string memory name,
    string memory symbol,
    address _paymaster,
    uint256 _exchangeRate
)
```

**After (6 parameters)**:
```solidity
constructor(
    string memory name,
    string memory symbol,
    address _paymaster,
    address _basePriceToken,    // ✅ NEW: Base token for derived tokens
    uint256 _exchangeRate,
    uint256 _priceUSD           // ✅ NEW: USD price for base tokens
)
```

#### PaymasterV4_1

**Before (10 parameters)**:
```solidity
constructor(
    address _entryPoint,
    address _owner,
    address _treasury,
    uint256 _gasToUSDRate,      // ❌ REMOVED
    uint256 _pntPriceUSD,       // ❌ REMOVED
    uint256 _serviceFeeRate,
    uint256 _maxGasCostCap,
    uint256 _minTokenBalance,
    address _initialSBT,
    address _initialGasToken
)
```

**After (10 parameters, different)**:
```solidity
constructor(
    address _entryPoint,
    address _owner,
    address _treasury,
    address _ethUsdPriceFeed,   // ✅ NEW: Chainlink feed
    uint256 _serviceFeeRate,
    uint256 _maxGasCostCap,
    uint256 _minTokenBalance,
    address _initialSBT,
    address _initialGasToken,
    address _registry           // ✅ NEW: Immutable registry
)
```

### 2. Removed Functions & Events

#### PaymasterV4

```solidity
// ❌ REMOVED - No longer needed
function setGasToUSDRate(uint256 _rate) external onlyOwner;
function setPntPriceUSD(uint256 _price) external onlyOwner;

// ❌ REMOVED - No longer emitted
event GasToUSDRateUpdated(uint256 oldRate, uint256 newRate);
event PntPriceUpdated(uint256 oldPrice, uint256 newPrice);

// ❌ REMOVED - Replaced by Chainlink
function gasToUSDRate() external view returns (uint256);
function pntPriceUSD() external view returns (uint256);
```

#### PaymasterV4_1

```solidity
// ❌ REMOVED - Registry is immutable now
function setRegistry(address _registry) external onlyOwner;

// ❌ REMOVED - No longer needed
event RegistryUpdated(address indexed registry);
```

### 3. New Functions & Properties

#### PaymasterV4

```solidity
// ✅ NEW - Chainlink price feed address (immutable)
AggregatorV3Interface public immutable ethUsdPriceFeed;

// ✅ NEW - Get current ETH price from Chainlink
function getEthPriceUSD() internal view returns (uint256) {
    (, int256 price,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();
    require(block.timestamp - updatedAt <= 3600, "Stale price");
    // ... decimal conversion
}
```

#### GasTokenV2

```solidity
// ✅ NEW - Base token for price reference
address public basePriceToken;

// ✅ NEW - Token price in USD (18 decimals)
uint256 public priceUSD;

// ✅ NEW - Get raw USD price
function getPrice() external view returns (uint256);

// ✅ NEW - Set price (owner only)
function setPrice(uint256 _priceUSD) external onlyOwner;

// ✅ NEW - Get effective price (auto-calculates for derived tokens)
function getEffectivePrice() external view returns (uint256);
```

### 4. Price Calculation Logic

#### Old Flow (Manual)

```solidity
// Static values set by owner
uint256 ethPrice = paymaster.gasToUSDRate();     // e.g., 4500e18
uint256 tokenPrice = paymaster.pntPriceUSD();    // e.g., 0.02e18

// Simple calculation
uint256 gasCostUSD = (gasCostWei * ethPrice) / 1e18;
uint256 tokensNeeded = (gasCostUSD * 1e18) / tokenPrice;
```

#### New Flow (Oracle + Token)

```solidity
// Step 1: Get real-time ETH price from Chainlink
(, int256 ethUsdPrice,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();
require(block.timestamp - updatedAt <= 3600, "Price stale");

// Step 2: Normalize decimals (Chainlink uses 8, we use 18)
uint8 decimals = ethUsdPriceFeed.decimals();  // 8
uint256 ethPriceUSD = uint256(ethUsdPrice) * 1e18 / (10 ** decimals);

// Step 3: Calculate gas cost in USD
uint256 gasCostUSD = (gasCostWei * ethPriceUSD) / 1e18;

// Step 4: Get token's effective price (handles base/derived automatically)
uint256 tokenPriceUSD = IGasTokenPrice(gasToken).getEffectivePrice();

// Step 5: Calculate required tokens
uint256 tokensNeeded = (gasCostUSD * 1e18) / tokenPriceUSD;
```

### 5. Token Price Management

#### Base Token (aPNT)

```solidity
// Deploy base token with direct USD price
GasTokenV2 aPNT = new GasTokenV2(
    "Alpha Points",
    "aPNT",
    address(paymaster),
    address(0),        // basePriceToken = 0 (this is a base token)
    1e18,              // exchangeRate = 1:1
    0.02e18            // priceUSD = $0.02
);

// getEffectivePrice() returns priceUSD directly
uint256 price = aPNT.getEffectivePrice();  // 0.02e18 ($0.02)
```

#### Derived Token (xPNT)

```solidity
// Deploy derived token with 1:4 exchange rate
GasTokenV2 xPNT = new GasTokenV2(
    "X Points",
    "xPNT",
    address(paymaster),
    address(aPNT),     // basePriceToken = aPNT address
    4e18,              // exchangeRate = 1:4 (1 xPNT = 4 aPNT)
    0                  // priceUSD ignored for derived tokens
);

// getEffectivePrice() calculates: aPNT price × exchangeRate
uint256 price = xPNT.getEffectivePrice();
// = aPNT.getPrice() * 4e18 / 1e18
// = 0.02e18 * 4e18 / 1e18
// = 0.08e18 ($0.08)
```

### 6. Deployment Example

#### Before

```javascript
// Deploy PaymasterV4_1
const paymaster = await PaymasterV4_1.deploy(
    ENTRY_POINT,
    owner.address,
    treasury.address,
    ethers.parseEther("4500"),      // gasToUSDRate
    ethers.parseEther("0.02"),      // pntPriceUSD
    200,                             // serviceFeeRate (2%)
    ethers.parseEther("1"),         // maxGasCostCap
    ethers.parseEther("1000"),      // minTokenBalance
    sbtAddress,
    gasTokenAddress
);

// Set registry after deployment
await paymaster.setRegistry(registryAddress);

// Deploy GasToken
const aPNT = await GasTokenV2.deploy(
    "Alpha Points",
    "aPNT",
    paymasterAddress,
    ethers.parseEther("1")          // exchangeRate
);
```

#### After

```javascript
// Get Chainlink price feed address for your network
const CHAINLINK_ETH_USD = {
    mainnet: "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419",
    sepolia: "0x694AA1769357215DE4FAC081bf1f309aDC325306",
    polygon: "0xAB594600376Ec9fD91F8e885dADF0CE036862dE0"
};

// Deploy PaymasterV4_1 with immutable registry
const paymaster = await PaymasterV4_1.deploy(
    ENTRY_POINT,
    owner.address,
    treasury.address,
    CHAINLINK_ETH_USD.sepolia,      // ✅ Chainlink feed address
    200,                             // serviceFeeRate (2%)
    ethers.parseEther("1"),         // maxGasCostCap
    ethers.parseEther("1000"),      // minTokenBalance
    sbtAddress,
    gasTokenAddress,
    registryAddress                  // ✅ Immutable registry
);

// Deploy base token
const aPNT = await GasTokenV2.deploy(
    "Alpha Points",
    "aPNT",
    paymasterAddress,
    ethers.ZeroAddress,             // ✅ basePriceToken (0 for base)
    ethers.parseEther("1"),         // exchangeRate (1:1)
    ethers.parseEther("0.02")       // ✅ priceUSD ($0.02)
);

// Deploy derived token
const xPNT = await GasTokenV2.deploy(
    "X Points",
    "xPNT",
    paymasterAddress,
    await aPNT.getAddress(),        // ✅ basePriceToken (aPNT)
    ethers.parseEther("4"),         // exchangeRate (1:4)
    0                                // priceUSD (ignored)
);
```

### 7. Chainlink Price Feed Addresses

#### Mainnet

| Network | ETH/USD Feed Address |
|---------|----------------------|
| Ethereum | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Polygon | `0xAB594600376Ec9fD91F8e885dADF0CE036862dE0` |
| Arbitrum | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` |
| Optimism | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` |
| Base | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| BSC | `0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e` |

#### Testnet

| Network | ETH/USD Feed Address |
|---------|----------------------|
| Sepolia | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Mumbai | `0xd0D5e3DB44DE05E9F294BB0a3bEEaF030DE24Ada` |
| Arbitrum Sepolia | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` |
| Base Sepolia | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` |

**Reference**: [Chainlink Price Feeds](https://docs.chain.link/data-feeds/price-feeds/addresses)

### 8. Migration Checklist

- [ ] Update deployment scripts with new constructor signatures
- [ ] Add Chainlink price feed addresses for target networks
- [ ] Deploy base tokens with `basePriceToken = address(0)`
- [ ] Deploy derived tokens with reference to base token
- [ ] Remove calls to `setGasToUSDRate()` and `setPntPriceUSD()`
- [ ] Remove calls to `setRegistry()` (set in constructor)
- [ ] Update frontend to read `ethUsdPriceFeed` instead of `gasToUSDRate`
- [ ] Update token price management UI to call `gasToken.setPrice()`
- [ ] Test price staleness handling (Chainlink data > 1 hour old)
- [ ] Verify `getEffectivePrice()` calculation for derived tokens

### 9. Testing Considerations

```solidity
// Test Chainlink price feed
function testChainlinkPriceFeed() public {
    MockChainlinkPriceFeed feed = new MockChainlinkPriceFeed(8, 4500e8);

    // Deploy paymaster with mock feed
    PaymasterV4 pm = new PaymasterV4(
        entryPoint,
        owner,
        treasury,
        address(feed),  // Mock feed
        200,
        1e18,
        1000e18
    );

    // Test price calculation
    uint256 gasCost = 0.001 ether;
    address token = address(aPNT);

    uint256 required = pm.estimatePNTCost(gasCost, token);
    // Expected: 0.001 ETH × $4500 = $4.5
    //           $4.5 / $0.02 = 225 aPNT
    assertEq(required, 225e18);
}

// Test stale price rejection
function testStalePrice() public {
    MockChainlinkPriceFeed feed = new MockChainlinkPriceFeed(8, 4500e8);
    feed.setStale(block.timestamp - 7200);  // 2 hours old

    // Should revert
    vm.expectRevert("Stale price");
    paymaster.estimatePNTCost(0.001 ether, address(aPNT));
}

// Test derived token pricing
function testDerivedTokenPrice() public {
    // aPNT = $0.02
    // xPNT = 4:1 ratio

    uint256 aPntPrice = aPNT.getEffectivePrice();
    uint256 xPntPrice = xPNT.getEffectivePrice();

    assertEq(aPntPrice, 0.02e18);
    assertEq(xPntPrice, 0.08e18);  // $0.02 × 4
}
```

### 10. Error Handling

```solidity
// Chainlink errors
error StalePriceData();          // Price update > 1 hour old
error InvalidChainlinkResponse(); // Round not complete or invalid

// GasToken errors
error ZeroExchangeRate();        // Exchange rate cannot be 0
error InvalidBasePriceToken();   // Base token doesn't implement IGasTokenPrice

// Migration errors
error RegistryAlreadySet();      // Only set in constructor now
error CannotUpdateRegistry();    // Registry is immutable
```

---

## For Users

### What's Changing?

Your **gas sponsorship experience remains the same**, but the pricing is now **more accurate and fair**.

### Key Improvements

#### 1. **Real-Time ETH Prices**

**Before**: Gas costs were calculated using manually updated ETH prices that could be outdated.

**Now**: Prices come from Chainlink, a decentralized oracle network used by major DeFi protocols. Updates happen automatically when market prices change.

**Example**:
- **Old**: Owner sets ETH = $4500. Market drops to $4000. You still pay based on $4500.
- **New**: Chainlink shows ETH = $4000. You pay the correct current price.

#### 2. **Multiple Token Types**

**Before**: All PNT tokens had the same value.

**Now**: Different point types can have different values:

| Token Type | Description | Example Price |
|------------|-------------|---------------|
| **aPNT** (Base) | Alpha Points - Base currency | $0.02 per point |
| **xPNT** (4×) | Premium Points - 4× value | $0.08 per point |
| **bPNT** (0.5×) | Bronze Points - Half value | $0.01 per point |

**Why this matters**: You can earn premium tokens worth more, so you need fewer of them to pay for gas.

#### 3. **Fairer Pricing**

**Example Transaction**:
- Gas needed: 0.001 ETH
- Current ETH price (Chainlink): $4,200
- Gas cost in USD: 0.001 × $4,200 = **$4.20**

**Payment Options**:

| Token | Price per Token | Tokens Needed | You Pay |
|-------|-----------------|---------------|---------|
| aPNT | $0.02 | 210 aPNT | 210 points |
| xPNT (4×) | $0.08 | 52.5 xPNT | 53 points |
| bPNT (0.5×) | $0.01 | 420 bPNT | 420 points |

**The system automatically picks the token you have enough balance of.**

### Common Scenarios

#### Scenario 1: Single Token User

**You have**: 500 aPNT
**Transaction cost**: $4.20 (210 aPNT)

**Result**: ✅ Transaction succeeds, you pay 210 aPNT, balance = 290 aPNT

---

#### Scenario 2: Multiple Tokens

**You have**:
- 100 aPNT ($2.00 worth)
- 50 xPNT ($4.00 worth)

**Transaction cost**: $4.20

**Result**:
- aPNT insufficient (need 210, have 100)
- xPNT sufficient (need 53, have 50) ❌
- **Transaction fails** - please acquire more tokens

---

#### Scenario 3: Premium Token Advantage

**You earn premium tokens through achievements**

**Transaction cost**: $4.20

| Scenario | Regular User | Premium User |
|----------|--------------|--------------|
| Token Type | aPNT ($0.02) | xPNT ($0.08) |
| Needed | 210 tokens | 53 tokens |
| **Savings** | - | **75% fewer tokens!** |

### Security Improvements

#### Immutable Registry

**Before**: The paymaster owner could change the registry address anytime.

**Now**: The registry address is locked at deployment and **cannot be changed**.

**Why this matters**:
- ✅ You can trust the paymaster won't switch to a malicious registry
- ✅ No unexpected behavior changes
- ✅ Transparent and auditable

### What You Need to Do

**Nothing!**

These are backend improvements. Your experience remains:
1. Hold qualifying points/tokens
2. Submit UserOperations
3. Gas is automatically paid from your token balance

The difference is now you get **fairer, real-time pricing** automatically.

### Frequently Asked Questions

#### Q: Will my existing tokens still work?

**A**: Existing tokens need to be re-deployed with the new pricing system. Your balance will be migrated by the token issuer.

#### Q: How often do prices update?

**A**:
- **ETH/USD**: Updates when market moves significantly (via Chainlink)
- **Token prices**: Updated by token administrators as needed
- **Effective prices**: Calculated automatically in real-time

#### Q: What if Chainlink data is unavailable?

**A**: The system has a **1-hour staleness check**. If Chainlink data is older than 1 hour, transactions will fail with "Stale price" error. This protects you from paying incorrect amounts.

#### Q: Can I see current prices?

**A**: Yes, call these view functions (no gas cost):

```javascript
// Get current ETH price
const ethPriceFeed = await paymaster.ethUsdPriceFeed();
const priceFeed = await ethers.getContractAt("AggregatorV3Interface", ethPriceFeed);
const { answer } = await priceFeed.latestRoundData();
console.log("ETH/USD:", ethers.formatUnits(answer, 8));

// Get token price
const aPntPrice = await aPNT.getEffectivePrice();
console.log("aPNT Price:", ethers.formatEther(aPntPrice), "USD");

// Estimate cost for a transaction
const gasCost = ethers.parseEther("0.001");  // 0.001 ETH gas
const tokensNeeded = await paymaster.estimatePNTCost(gasCost, aPNT.address);
console.log("Tokens needed:", ethers.formatEther(tokensNeeded));
```

#### Q: What happens to my tokens during migration?

**A**: Your token issuer will:
1. Snapshot your current balance
2. Deploy new token contracts with pricing
3. Mint equivalent balance to your address
4. Notify you of the new token address

**Your balance and ownership remain the same.**

### Support Contacts

**Technical Issues**: Submit to [GitHub Issues](https://github.com/aastar/SuperPaymaster/issues)
**Security Concerns**: security@aastar.community
**General Questions**: support@aastar.community

---

## Summary

### For Developers

- 🔧 Update constructor signatures (6-7 parameters)
- 🔗 Integrate Chainlink price feeds
- 🏗️ Re-deploy contracts with new pricing system
- 🧪 Test price calculations and staleness handling
- 📚 Update documentation and frontend

### For Users

- ✅ **Better pricing** - Real-time ETH prices via Chainlink
- ✅ **More options** - Multiple token tiers (base/premium)
- ✅ **Enhanced security** - Immutable registry
- ✅ **No action needed** - Changes are backend only
- ✅ **Transparent** - All prices visible on-chain

### Timeline

- **Code Complete**: 2025-10-26
- **Testing**: 1-2 weeks
- **Testnet Deployment**: TBD
- **Mainnet Deployment**: After security audit
- **User Migration**: Coordinated with token issuers

---

**Last Updated**: 2025-10-26
**Version**: 1.0
**Authors**: AAstar Development Team
