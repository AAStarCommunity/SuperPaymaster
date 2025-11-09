# Deprecated Files

This directory contains deprecated contracts and scripts that have been replaced by newer versions.

## SuperPaymasterRegistry_v1_2.sol

**Deprecated on**: 2025-10-31
**Replaced by**: `src/paymasters/v2/core/Registry.sol`
**Reason**: Registry v2 provides enhanced features:
- Progressive slash system (2%-10% based on failure count)
- Node type configurations (4 types with different stake requirements)
- Community profile management
- Integration with GTokenStaking v2

**Migration**: Use Registry v2 deployed at `0x529912C52a934fA02441f9882F50acb9b73A3c5B` (Sepolia)

## DeployRegistry_v1_2.s.sol

**Deprecated on**: 2025-10-31
**Replaced by**: Deployment scripts for Registry v2
**Reason**: v1_2 deployment script is obsolete

---

**Note**: These files are kept for historical reference only. Do NOT use in production.
