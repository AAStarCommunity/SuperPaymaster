# Security Policy

## 🔒 Reporting Security Vulnerabilities

If you discover a security vulnerability in SuperPaymaster, please report it privately to our security team:

- **Email**: security@aastar.io
- **Discord**: Join our [Discord server](https://discord.gg/aastar) and DM the security team

**Please do not** create public GitHub issues for security vulnerabilities.

## 🛡️ Dependency Security

### Production Dependencies

Our production smart contracts and application have **zero known vulnerabilities** in direct dependencies:

```json
{
  "@openzeppelin/contracts": "^5.0.2",  // ✅ Secure
  "dotenv": "^17.2.3",                  // ✅ Secure
  "ethers": "^6.15.0"                   // ✅ Secure
}
```

**Verified**: `npm audit` shows 0 vulnerabilities in production code.

### Submodule Dependencies (Development Only)

GitHub Dependabot may report vulnerabilities in git submodules:
- `contracts/lib/openzeppelin-contracts` - OpenZeppelin test utilities
- `contracts/lib/forge-std` - Foundry testing framework
- `singleton-paymaster` - Pimlico reference implementation

**Important**: These vulnerabilities are in **development/testing dependencies only** and:
- ❌ Do NOT affect deployed smart contracts
- ❌ Do NOT affect production runtime
- ✅ Are external libraries maintained by their respective teams
- ✅ Are only used during local development and testing

### Why These Warnings Exist

GitHub's Dependabot scans all `package.json` files in the repository, including those in git submodules. These submodules contain development tools with their own dependencies, which may have known vulnerabilities in their **test/development dependencies**.

### What We Monitor

We actively monitor and update:
1. **Smart Contract Dependencies**: OpenZeppelin Contracts
2. **Application Dependencies**: ethers.js, dotenv
3. **Critical Security**: Solidity compiler versions, ERC-4337 implementations

## 🔐 Smart Contract Security

### Audit Status

- ✅ Internal security review completed
- ✅ Test coverage: 100+ test cases covering all critical paths
- 🔄 External audit: Planned for Q1 2025

### Security Best Practices

Our contracts follow:
- ✅ OpenZeppelin security standards
- ✅ ERC-4337 account abstraction specifications
- ✅ Reentrancy protection (ReentrancyGuard)
- ✅ Access control (Ownable)
- ✅ Pausable emergency mechanisms

### Deployed Contract Addresses

**Sepolia Testnet**:
- Registry: [View on Etherscan](https://sepolia.etherscan.io/)
- PaymasterV2: [View on Etherscan](https://sepolia.etherscan.io/)
- PaymasterV4: [View on Etherscan](https://sepolia.etherscan.io/)

All deployed contracts are verified on Etherscan.

## 📋 Security Checklist for Contributors

Before submitting PRs that modify smart contracts:

- [ ] Run full test suite: `forge test`
- [ ] Check gas optimization: `forge snapshot`
- [ ] Verify no new warnings: `forge build`
- [ ] Run security analysis: `slither .` (if available)
- [ ] Document any access control changes
- [ ] Test emergency pause/unpause mechanisms

## 🚨 Incident Response

In case of a security incident:

1. **Immediate**: Pause affected contracts (if pausable)
2. **Notify**: Alert team via security channels
3. **Investigate**: Root cause analysis
4. **Remediate**: Deploy fixes or upgrades
5. **Communicate**: Public disclosure after mitigation

## 📚 Resources

- [OpenZeppelin Security](https://docs.openzeppelin.com/contracts/5.x/security)
- [ERC-4337 Security Considerations](https://eips.ethereum.org/EIPS/eip-4337#security-considerations)
- [Ethereum Smart Contract Best Practices](https://consensys.github.io/smart-contract-best-practices/)

---

**Last Updated**: 2025-10-24
**Version**: 1.0.0
