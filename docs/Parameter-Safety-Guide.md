# SuperPaymaster Parameter Safety & Configuration Guide

**Date**: 2026-03-22
**Scope**: SuperPaymaster V5.2 + PaymasterV4 V4.3.1
**Network targets**: Sepolia (testnet), Optimism/Mainnet (production)

---

## 1. Contract Version Registry

| Contract | Version | Upgrade Pattern | Chain(s) |
|----------|---------|----------------|----------|
| GToken | `GToken-2.1.2` | Pointer-replacement | All |
| GTokenStaking | `Staking-3.2.0` | Pointer-replacement | All |
| MySBT | `MySBT-3.1.3` | Pointer-replacement | All |
| Registry | `Registry-4.1.0` | **UUPS Proxy** | All |
| SuperPaymaster | `SuperPaymaster-5.2.0` | **UUPS Proxy** | All |
| PaymasterBase | `PaymasterV4-4.3.1` | Direct deploy | Per-community |
| Paymaster (V4) | `PMV4-Deposit-4.3.0` | EIP-1167 Proxy | Per-community |
| PaymasterFactory | `PaymasterFactory-1.0.2` | Direct deploy | All |
| xPNTsToken | `XPNTs-3.0.0-unlimited` | EIP-1167 Proxy | Per-community |
| xPNTsFactory | `xPNTsFactory-2.1.0-clone-optimized` | Direct deploy | All |
| BLSValidator | `BLSValidator-0.3.2` | Direct deploy | All |
| BLSAggregator | `BLSAggregator-3.2.1` | Direct deploy | All |
| DVTValidator | `DVTValidator-0.3.2` | Direct deploy | All |
| ReputationSystem | `Reputation-0.3.2` | Direct deploy | All |

### Version Verification

```bash
# On-chain version check
cast call <address> "version()(string)" --rpc-url $RPC_URL

# Batch check all contracts
./version-check-onchain.sh
```

---

## 2. Hardcoded Safety Constants

These values are immutable in bytecode and cannot be changed after deployment.

### SuperPaymaster Constants

| Constant | Value | Unit | Purpose |
|----------|-------|------|---------|
| `BPS_DENOMINATOR` | 10,000 | — | 100% = 10,000 bps |
| `MAX_PROTOCOL_FEE` | 2,000 | bps | Protocol fee hardcap (20%) |
| `MAX_FACILITATOR_FEE` | 500 | bps | x402 facilitator fee hardcap (5%) |
| `VALIDATION_BUFFER_BPS` | 1,000 | bps | 10% pre-deduction buffer |
| `MIN_ETH_USD_PRICE` | 100 × 1e8 | 8 dec | $100 minimum |
| `MAX_ETH_USD_PRICE` | 100,000 × 1e8 | 8 dec | $100,000 maximum |
| `PRICE_CACHE_DURATION` | 300 | seconds | 5 min cache window |
| `PAYMASTER_DATA_OFFSET` | 52 | bytes | ERC-4337 v0.7 standard |
| `MAX_AGENT_POLICIES` | 10 | count | Agent policy array cap |
| `PERMIT2` | `0x000...22D...BA3` | address | Uniswap Permit2 |

### PaymasterV4 Constants

| Constant | Value | Unit | Purpose |
|----------|-------|------|---------|
| `BPS_DENOMINATOR` | 10,000 | — | 100% = 10,000 bps |
| `MAX_SERVICE_FEE` | 1,000 | bps | Service fee hardcap (10%) |
| `MAX_SBTS` | 5 | count | Supported SBT limit |
| `MAX_GAS_TOKENS` | 10 | count | Supported token limit |
| `MIN_ETH_USD_PRICE` | 100 × 1e8 | 8 dec | $100 minimum |
| `MAX_ETH_USD_PRICE` | 100,000 × 1e8 | 8 dec | $100,000 maximum |
| `VALIDATION_BUFFER_BPS` | 1,000 | bps | 10% pre-deduction buffer |

---

## 3. Configurable Parameters — Safe Ranges

### SuperPaymaster

| Parameter | Setter | Range | Recommended | Risk if Misconfigured |
|-----------|--------|-------|-------------|----------------------|
| `protocolFeeBPS` | `setProtocolFee()` | 0–2,000 | 500–1,000 | >1,000: users overpay; 0: no protocol revenue |
| `aPNTsPriceUSD` | `setAPNTSPrice()` | >0 (18 dec) | 0.02–0.05 ether | Too low: gas underpayment; Too high: user cost spike |
| `facilitatorFeeBPS` | `setFacilitatorFeeBPS()` | 0–500 | 50–200 | >200: facilitators resist adoption |
| `operatorFacilitatorFees[op]` | `setOperatorFacilitatorFee()` | 0–500 | 0 (use default) | Per-operator override; 0 = use global |

### PaymasterV4

| Parameter | Setter | Range | Recommended | Risk if Misconfigured |
|-----------|--------|-------|-------------|----------------------|
| `serviceFeeRate` | `setServiceFeeRate()` | 0–1,000 | 300–500 | >500: expensive; 0: no fee collection |
| `maxGasCostCap` | `setMaxGasCostCap()` | 1 wei – 100 ether | 0.01–1 ether | Too high: arithmetic overflow risk; Too low: legit ops rejected |
| `priceStalenessThreshold` | `setPriceStalenessThreshold()` | >0 | 3,600 (1 hr) | <300: oracle cache constantly stale; >86,400: stale price risk |
| `tokenPrices[token]` | `setTokenPrice()` | >0 (8 dec) | Match market | Wrong price: under/overcharging users |

### Oracle Configuration

| Network | Chainlink Heartbeat | Recommended Staleness | Feed |
|---------|--------------------|-----------------------|------|
| Ethereum Mainnet | 3,600s | 3,600–7,200s | ETH/USD |
| Optimism | 1,200s | 1,200–3,600s | ETH/USD |
| Arbitrum | 1,200s | 1,200–3,600s | ETH/USD |
| Sepolia | Variable | 3,600s (test tolerance) | ETH/USD |

**Rule**: `priceStalenessThreshold >= Chainlink heartbeat × 1.5`

---

## 4. Arithmetic Safety Analysis

### PaymasterV4 `_calculateTokenCost` (v4.3.1)

The token cost calculation uses OpenZeppelin `Math.mulDiv` for 512-bit intermediate precision:

```
partA = gasCostWei × ethUsdPrice × totalRate
result = Math.mulDiv(partA, 10^tokenDecimals, denominator)
```

**Overflow boundaries** for `partA` (uint256 max ≈ 1.16 × 10^77):

| Variable | Max Safe Value | Typ Value | Headroom |
|----------|---------------|-----------|----------|
| `gasCostWei` | 100 ether (1e20) | 0.01 ether (1e16) | 10,000x |
| `ethUsdPrice` | 1e13 ($100K × 1e8) | 3e11 ($3K) | 33x |
| `totalRate` | 11,000 (10K + 1K buffer) | 10,500 | ~1x |

Worst case: `1e20 × 1e13 × 11000 = 1.1e37` — well within uint256.

`Math.mulDiv(1.1e37, 1e18, denominator)` uses 512-bit intermediate → safe for all token decimals ≤ 24.

### SuperPaymaster `_consumeCredit`

Fee application: `finalCharge = aPNTsBase × (BPS_DENOMINATOR + protocolFeeBPS) / BPS_DENOMINATOR`

Max: `aPNTsBase × 12,000 / 10,000` = 1.2x — no overflow risk.

---

## 5. Oracle Validation Checklist

Both SuperPaymaster and PaymasterV4 now validate:

| Check | SuperPaymaster | PaymasterV4 (v4.3.1) |
|-------|---------------|----------------------|
| `price > 0` | `_updatePriceCache()` | `updatePrice()` |
| `price ∈ [MIN, MAX]` | `_updatePriceCache()` | `updatePrice()` |
| `updatedAt > 0` | `_updatePriceCache()` | `updatePrice()` + realtime path |
| Staleness check | `_updatePriceCache()` | `updatePrice()` (with underflow guard) |
| Fallback to cache | `_getEthUsdPrice()` | `_calculateTokenCost()` cached path |

### Monitoring Recommendations

1. **Track events**: `PriceUpdated`, `OracleFallbackTriggered`
2. **Alert on**: No `PriceUpdated` for > 2× heartbeat
3. **Keeper frequency**: Match Chainlink heartbeat (call `updatePrice()` every heartbeat)

### Debt & Settlement Monitoring

SuperPaymaster's postOp uses try-catch for external `recordDebt()` calls. When the call fails, debt is stored in `pendingDebts` mapping and can be retried.

**Critical Events to Monitor:**

| Event | Severity | Action Required |
|-------|----------|----------------|
| `DebtRecordFailed(token, user, amount)` | **HIGH** | Immediate alert. Debt accumulated but not recorded on xPNTs. Call `retryPendingDebt(token, user)` to retry. |
| `PendingDebtRetried(token, user, amount)` | INFO | Debt successfully retried. Clear alert. |
| `PendingDebtCleared(token, user, amount)` | WARN | Admin cleared debt without recording. Review if intentional. |
| `X402PaymentSettled(payer, payee, asset, amount, fee, nonce)` | INFO | x402 settlement executed. Track for revenue accounting. |

**Recovery Procedures:**

1. **When `DebtRecordFailed` fires:**
   - Check if xPNTs token contract is responsive: `cast call <xPNTs> "totalSupply()"`
   - If responsive: call `retryPendingDebt(token, user)` — anyone can call
   - If unresponsive: escalate to admin, consider `clearPendingDebt(token, user)` (owner-only)

2. **Monitoring query (read pending debts):**
   ```bash
   cast call <SuperPaymaster> "pendingDebts(address,address)(uint256)" <token> <user> --rpc-url $RPC_URL
   ```

3. **Alert thresholds:**
   - Any `DebtRecordFailed` → PagerDuty/Slack alert (P1)
   - `pendingDebts > 0` for > 1 hour → escalate to P0
   - Multiple `DebtRecordFailed` from same token → investigate token contract health

---

## 6. Fee Stacking Model

When a user sends a gasless transaction through SuperPaymaster:

```
Base cost (aPNTs)
  + Protocol fee: base × protocolFeeBPS / 10,000
  − Agent sponsorship: (base + fee) × sponsorshipBPS / 10,000  [if agent]
  = Final charge to operator
```

For x402 settlement (settleX402PaymentPermit2):

```
Payment amount
  × facilitatorFeeBPS / 10,000 = Facilitator fee
  Payee receives: amount − fee
```

**Maximum total take rate** (worst case):
- Gas sponsorship: 20% protocol + 10% validation buffer = 32% effective
- x402 settlement: 5% facilitator fee

---

## 7. Deployment Checklist

### Pre-Deployment

- [ ] Verify `forge build --sizes` → all contracts < 24,576 bytes
- [ ] Run `forge test` → 0 failures
- [ ] Confirm oracle feed address matches target network
- [ ] Set `priceStalenessThreshold` ≥ network heartbeat × 1.5
- [ ] Verify `protocolFeeBPS` ≤ 2,000 and `facilitatorFeeBPS` ≤ 500
- [ ] Check `maxGasCostCap` < 100 ether
- [ ] Validate all token decimals ≤ 24

### Post-Deployment

- [ ] Call `version()` and confirm expected string
- [ ] Execute `updatePrice()` from keeper — verify no revert
- [ ] Configure at least one operator via `configureOperator()`
- [ ] Deposit aPNTs for operator via `deposit()` or `depositFor()`
- [ ] Test gasless transfer end-to-end
- [ ] Set up oracle keeper cron (interval = network heartbeat)
- [ ] Enable monitoring for `PriceUpdated` and `OracleFallbackTriggered`

### UUPS Upgrade Checklist

- [ ] Deploy new implementation with same immutable constructor args
- [ ] Call `upgradeToAndCall(newImpl, "")` from proxy owner
- [ ] Verify `version()` returns updated string
- [ ] Run sanity smoke test (deposit + gasless transfer)
- [ ] Update `deployments/config.<network>.json` with new impl address

---

## 8. Changelog

| Date | Version | Changes |
|------|---------|---------|
| 2026-03-22 | V5.2.0 | Agent sponsorship policies, x402 Permit2 settlement, EIP-1153 cache, feedback submission |
| 2026-03-22 | V4.3.1 | `_calculateTokenCost` mulDiv fix, oracle `updatedAt` validation, staleness check |
