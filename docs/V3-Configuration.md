# SuperPaymaster V3 Configuration

## Network Information

### Ethereum Sepolia Testnet
- **Chain ID**: 11155111
- **RPC URL**: https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
- **Explorer**: https://sepolia.etherscan.io

## Contract Addresses

### EntryPoint Contracts
| Version | Address | Status |
|---------|---------|--------|
| v0.6 | `0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789` | ✅ Deployed |
| v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ✅ Deployed |
| v0.8 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ✅ Deployed |

### Existing Contracts
| Contract | Address | Type | Verified |
|----------|---------|------|----------|
| **SBT** | `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f` | Soul-Bound Token | ✅ |
| **PNT** | `0x3e7B771d4541eC85c8137e950598Ac97553a337a` | ERC20 Token | ✅ |
| **SuperPaymaster (Legacy)** | `0x4e67678AF714f6B5A8882C2e5a78B15B08a79575` | Old Version | ✅ |

### V3 Contracts (To Deploy)
| Contract | Address | Status |
|----------|---------|--------|
| **Settlement** | TBD | 🔄 Development |
| **SuperPaymasterV7** | TBD | 🔄 Development |
| **SuperPaymasterV8** | TBD | ⏳ Future |

## Configuration Parameters

### Token Requirements
```solidity
MIN_TOKEN_BALANCE = 100 PNT (100 * 10^18 wei)
```
- Users must hold at least 100 PNT to qualify for gas sponsorship

### Settlement Settings
```solidity
SETTLEMENT_THRESHOLD = 1000 PNT (1000 * 10^18 wei)
```
- Batch settlement triggers when total pending fees exceed threshold

### SBT Requirements
- Users must hold at least 1 SBT (Soul-Bound Token)
- SBT Contract: `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f`

## Development Workflow

### Phase 1: V7 Development (Current)
1. ✅ Create development branch
2. 🔄 Define interfaces
3. 🔄 Develop Settlement contract
4. 🔄 Develop SuperPaymasterV7
5. ⏳ Unit tests
6. ⏳ Sepolia deployment

### Phase 2: V8 Migration (Future)
- After V7 stable for > 1 week
- After 100+ successful transactions

## Testing Strategy

### Local Testing
```bash
forge test -vvv
forge coverage
```

### Sepolia Testnet
1. Deploy Settlement contract
2. Deploy SuperPaymasterV7
3. Authorize Paymaster in Settlement
4. Fund Paymaster with ETH
5. Run integration tests

## Monitoring

### Key Metrics
- Total pending fees
- Number of sponsored UserOps
- Gas savings vs real-time transfer
- Settlement batch frequency

### Events to Monitor
- `GasSponsored(user, amount, token)`
- `GasRecorded(user, amount, token)`
- `FeesSettled(user, token, amount)`

## Security Considerations

1. **Access Control**
   - Only authorized Paymasters can record fees
   - Only owner can trigger settlements
   
2. **Reentrancy Protection**
   - All state changes before external calls
   - Use OpenZeppelin ReentrancyGuard

3. **Input Validation**
   - Validate all addresses (non-zero)
   - Check token balances before operations

## Upgrade Path

### V7 → V8 Migration
1. Complete V7 testing
2. Audit V7 contracts
3. Adapt V7 code to V8 EntryPoint
4. Run parallel testing
5. Gradual migration

---

**Last Updated**: 2025-01-05  
**Version**: 1.0  
**Status**: Development
