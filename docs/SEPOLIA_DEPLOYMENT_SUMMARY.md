# Sepolia Deployment Summary - V3.1.1 (2025-12-28 Final)

## ✅ Core Infrastructure (Base Layer)
| Contract | Address | Notes |
|:---------|:--------|:------|
| **GToken** | `0xfc5671D606e8dd65EA39FB3f519443B7DAB40570` | DAO Governance |
| **GTokenStaking** | `0xB8C4Ed4906baF13Cb5fE49B1A985B76BAccEEC06` | Staking & Locking |
| **MySBT** | `0x925e2ad77CeD7b72C9e58D6BCDB2c994F705c53b` | Identity & Reputation |
| **Registry** | `0xf265d21c2cE6B2fA5d6eD1A2d7b032F03516BE19` | Universal Role/Address Storage |

## ✅ Paymaster Ecosystem (Service Layer)
| Contract | Address | Notes |
|:---------|:--------|:------|
| **xPNTsFactory** | `0xbECF67cdf55b04E8090C0170AA2936D07e2b3708` | Token Factory |
| **PaymasterFactory** | `0x7F89A36728678dF08dcfCA7D2128933Aa9A1Ed98` | V4 Factory (Anni) |
| **PaymasterV4Impl** | `0xA96b2bB34edeCaEA8E05021Dc69a0a9f4C90f5A2` | V4.1 Implementation |
| **SuperPaymasterV3** | `0xd6EACcC89522f1d507d226495adD33C5A74b6A45` | Global Paymaster (Aggregator) |
| **PaymasterV4** | `0xb78d77Eb3EED175F4979967181EC340fAE27b85D` | Community Instance (Direct) |

## ✅ Community Tokens
| Token | Address | Community |
|:------|:--------|:----------|
| **aPNTs** | `0xD348d910f93b60083bF137803FAe5AF25E14B69d` | AAStar Community A (Mock) |
| **bPNTs** | `0xd7036a4a98AF3586C3E6416fBFeC3c1e8b6e0575` | AAStar Community B |

## 🔗 Wiring & Status
- **Core Wiring**: All V3 contracts wired to Registry `0xf265...`
- **Factory**: Wired to SuperPaymaster `0xd6EA...`
- **Tokens**: `aPNTs` and `bPNTs` wired to SuperPaymaster `0xd6EA...`
- **V4**: Configured with Registry, MySBT, and bPNTs (Fee Token)

## 📋 Next Steps
1. **SDK Setup**: Update `aastar-sdk/.env.sepolia` with these addresses.
2. **Initialization**: Run SDK scripts to Mint Tokens, Register Community, Configure Operator.
3. **Stage 3 Experiment**: Ready for multi-tenant scenarios.
