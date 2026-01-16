# SuperPaymaster V3 Sepolia Modular Deployment & Verification Guide

This document outlines the step-by-step procedure for deploying the SuperPaymaster V3 stack on Sepolia, ensuring all dependencies and configurations are correctly initialized and verified.

## 0. Preparation
Ensure environment variables are set:
```bash
export PRIVATE_KEY=0x... (Jason/Supplier Key)
export ETHERSCAN_API_KEY=...
export RPC_URL="https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N"
export DEPLOYER_ADDR="0xb5600060e6de5E11D3636731964218E53caadf0E"
```

## 1. Modular Deployment Procedure

### Phase 1: Foundation (Steps 1-4)
| Step | Contract | Script | Verification Note |
| :--- | :--- | :--- | :--- |
| 1 | **GToken** | `01_DeployGToken.s.sol` | Standard ERC20 |
| 2 | **GTokenStaking** | `02_DeployGTokenStaking.s.sol` | Requires `GTOKEN_ADDR` |
| 3 | **MySBT** | `03_DeployMySBT.s.sol` | Pre-computes Registry address logic |
| 4 | **Registry** | `04_DeployRegistry.s.sol` | Core wiring hub |

### Phase 2: Paymaster & Factory (Steps 5-7)
| Step | Contract | Script | Verification Note |
| :--- | :--- | :--- | :--- |
| 5 | **xPNTsFactory** | `05_DeployFactory.s.sol` | Set `SP_ADDR` later |
| 6 | **Mock aPNTs** | `06_DeployMockCommunityToken.s.sol` | Deployed via Factory |
| 7 | **SuperPaymasterV3** | `07_DeploySuperPaymaster.s.sol` | Requires `REGISTRY` & `APNTS` |

### Phase 3: Modules (Auxiliary)
- **ReputationSystemV3**: Deployed with `Registry` address.
- **BLS/DVT Modules**: Deployed and set in `Registry`.

---

## 2. Dependency & Wiring Logic
After deployment, the following "Neural Connections" must be established:

1.  **Factory -> SP**: `factory.setSuperPaymasterAddress(SP_ADDR)`
2.  **aPNTs -> SP**: `apnts.setSuperPaymasterAddress(SP_ADDR)` (Enables burn logic)
3.  **MySBT/Staking -> Registry**: `setRegistry(REGISTRY_ADDR)`
4.  **Registry -> Modules**: `setReputationSource(...)`, `setBLSValidator(...)`

---

## 3. Verification & Audit
After all 11 steps, run the master audit script:
```bash
forge script contracts/script/checks/VerifyV3_1_1.s.sol --rpc-url $RPC_URL
```
**Success Criteria:**
- [x] All deep wiring checks return `true`.
- [x] Admin roles are correctly granted.
- [x] Initial balances are non-zero (if minted).

---

## 4. Troubleshooting
- **Rate Limit**: Use `--slow` flag in Forge.
- **Gas Pricing**: Use `--legacy` if Sepolia base fee is unstable.
- **Verification Failure**: Ensure constructor arguments matches exactly (use `cast abi-encode`).

## 5. Deployment Log (Sepolia - 2025-12-28)

The following addresses were deployed during the latest fresh initialization:


### ✅ Core Infrastructure (Redeployment Verified)
- **GToken**: `0xfc5671D606e8dd65EA39FB3f519443B7DAB40570` (Verified: Symbol=GToken)
- **GTokenStaking**: `0xB8C4Ed4906baF13Cb5fE49B1A985B76BAccEEC06` (Verified: Code Exists)
- **MySBT**: `0x925e2ad77CeD7b72C9e58D6BCDB2c994F705c53b` (Verified: Code Exists)
- **Registry**: `0xf265d21c2cE6B2fA5d6eD1A2d7b032F03516BE19` (Verified: Code Exists)
- **xPNTsFactory**: `0xbECF67cdf55b04E8090C0170AA2936D07e2b3708` (Verified: Code Exists)
- **aPNTs (Mock)**: `0xD348d910f93b60083bF137803FAe5AF25E14B69d` (Verified: Code Exists)
