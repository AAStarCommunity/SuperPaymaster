# Security Policy

## Reporting Security Vulnerabilities

If you discover a security vulnerability in SuperPaymaster contracts, please report it responsibly.

### Contact

**Email**: security@aastar.io

**PGP Key**: Available upon request

### Reporting Process

1. **Do NOT** disclose vulnerabilities publicly before contacting us
2. Email us with detailed vulnerability information
3. Include:
   - Contract address and network
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact assessment
   - Suggested fix (if any)

4. We will acknowledge receipt within 48 hours
5. We will provide an initial assessment within 7 days

### Scope

The following contracts are in scope:

| Contract | Network | Address |
|----------|---------|---------|
| SuperPaymasterV2 | Sepolia | `0x7c3c355d9aa4723402bec2a35b61137b8a10d5db` |
| MySBT v2.4.5 | Sepolia | `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7` |
| Registry v2.2.1 | Sepolia | `0xf384c592D5258c91805128291c5D4c069DD30CA6` |
| GToken | Sepolia | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | Sepolia | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |
| xPNTsFactory | Sepolia | `0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd` |

### Out of Scope

- Third-party contracts (EntryPoint, OpenZeppelin)
- Frontend applications
- Off-chain infrastructure
- Already known issues

## Bug Bounty Program

We offer rewards for responsible disclosure:

| Severity | Reward |
|----------|--------|
| Critical | Up to $10,000 |
| High | Up to $5,000 |
| Medium | Up to $1,000 |
| Low | Up to $200 |

### Severity Classification

**Critical**:
- Direct theft of funds
- Permanent freezing of funds
- Privilege escalation to admin

**High**:
- Indirect theft requiring specific conditions
- Temporary freezing of funds
- Bypass of security controls

**Medium**:
- Griefing attacks
- DoS attacks on critical functions
- Information disclosure

**Low**:
- Gas inefficiencies
- Minor access control issues
- Non-critical function failures

## Security Measures

### Smart Contract Security

1. **Access Control**
   - Owner-only functions for critical operations
   - DAO multisig for MySBT admin functions
   - Oracle-restricted failure reporting

2. **Reentrancy Protection**
   - ReentrancyGuard on all state-changing functions
   - Checks-Effects-Interactions pattern

3. **Input Validation**
   - Parameter bounds checking
   - Address zero checks
   - Amount validation

4. **Pausability**
   - Emergency pause functionality
   - DAO-controlled unpause

### Economic Security

1. **Staking Requirements**
   - Minimum stake for operators
   - Lock periods for SBT holders
   - Slashing for malicious behavior

2. **Price Oracle**
   - Chainlink price feeds
   - Staleness checks
   - Price bounds validation

3. **Debt Limits**
   - Maximum debt per user
   - Debt tracking by token

## Audit Status

| Audit | Status | Date |
|-------|--------|------|
| Internal Review | Completed | Nov 2025 |
| External Audit | Pending | TBD |

## Known Limitations

1. **Oracle Dependency**: Price calculations depend on Chainlink oracle availability
2. **Centralization**: Some admin functions are centralized (mitigated by DAO multisig)
3. **Gas Costs**: Complex operations may have high gas costs

## Changelog

### v2.4.5 (MySBT)
- Added SuperPaymaster callback integration
- Improved contract size optimization

### v2.3.3 (SuperPaymaster)
- Internal SBT registry for gas optimization
- Debt tracking by token
- PostOp payment model

### v2.2.1 (Registry)
- Auto-stake registration
- Duplicate prevention

## Resources

- [Contract Architecture](./CONTRACT_ARCHITECTURE.md)
- [Developer Guide](./DEVELOPER_INTEGRATION_GUIDE.md)
- [GitHub Repository](https://github.com/AAStar/SuperPaymaster)
