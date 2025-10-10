# SimpleAccountFactoryV2 Deployment Summary

## 📋 Overview

SimpleAccountFactoryV2 is an upgraded version of the SimpleAccountFactory that creates SimpleAccountV2 accounts. The key improvement is **support for MetaMask's `personal_sign` method** while maintaining backward compatibility with raw signatures.

## 🎯 Why V2?

### Problem
MetaMask disabled the `eth_sign` method for security reasons, which was required by SimpleAccountV1's signature verification. This caused transaction signing to fail with:
```
MetaMask - RPC Error: The method 'eth_sign' does not exist / is not available.
```

### Solution
SimpleAccountV2 implements dual signature verification:
1. **Personal Sign Format** (Primary): Verifies signatures with `\x19Ethereum Signed Message:\n32` prefix (MetaMask's `signMessage`)
2. **Raw Signature Format** (Fallback): Backward compatible with direct hash signatures

## 📦 Deployment Details

### Network
- **Network**: Sepolia Testnet
- **Chain ID**: 11155111

### Deployed Contracts

| Contract | Address | Description |
|----------|---------|-------------|
| **SimpleAccountFactoryV2** | `0x8B516A71c134a4b5196775e63b944f88Cc637F2b` | Factory for creating V2 accounts |
| **SimpleAccountV2 Implementation** | `0x174f4b95baf89E1295F1b3826a719F505caDD02A` | Account implementation contract |
| **EntryPoint v0.7** | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ERC-4337 EntryPoint (unchanged) |

### Deployment Transaction
- **TX Hash**: `0xaacfec8df7119aed0608a2a9920e98598dbf2aba0d8e3ac213028c4710e6ecbb`
- **Block**: 9381381
- **Gas Used**: 2,239,570 gas
- **Gas Price**: 0.001000113 gwei
- **Cost**: 0.00000223982307141 ETH
- **Deployer**: `0x411BD567E46C0781248dbB6a9211891C032885e5`

### Etherscan Links
- Factory: https://sepolia.etherscan.io/address/0x8B516A71c134a4b5196775e63b944f88Cc637F2b
- Implementation: https://sepolia.etherscan.io/address/0x174f4b95baf89E1295F1b3826a719F505caDD02A

## 🧪 Testing Results

All local tests passed successfully before deployment:

### Test Suite: SimpleAccountFactoryV2Test

✅ **test_CreateAccountV2** (gas: 165,479)
- Verified account creation
- Confirmed version "2.0.0"
- Validated owner assignment

✅ **test_SignatureVerificationWithPersonalSign** (gas: 173,977)
- Tested MetaMask `personal_sign` format
- Verified signature with Ethereum message prefix
- Validation data: 0 (success)

✅ **test_SignatureVerificationWithRawSign** (gas: 178,126)
- Tested backward compatibility
- Verified raw signature format
- Validation data: 0 (success)

✅ **test_CreateAccountDeterministic** (gas: 164,800)
- Verified CREATE2 deterministic addressing
- Confirmed idempotent behavior (same salt returns existing account)

**Total**: 4 tests passed, 0 failed

## 🔧 Technical Implementation

### SimpleAccountV2 Signature Verification

```solidity
function _validateSignature(PackedUserOperation calldata userOp, bytes32 userOpHash)
internal override virtual returns (uint256 validationData) {
    
    // Try personal_sign format first (MetaMask signMessage)
    bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
    address recoveredFromPersonalSign = ECDSA.recover(ethSignedMessageHash, userOp.signature);
    
    if (recoveredFromPersonalSign == owner) {
        return SIG_VALIDATION_SUCCESS;
    }
    
    // Fallback to raw signature (backward compatibility)
    address recoveredFromRaw = ECDSA.recover(userOpHash, userOp.signature);
    
    if (recoveredFromRaw == owner) {
        return SIG_VALIDATION_SUCCESS;
    }
    
    return SIG_VALIDATION_FAILED;
}
```

### Key Features

1. **Dual Signature Support**
   - Primary: `personal_sign` with prefix
   - Fallback: Raw `eth_sign` signature

2. **Version Tracking**
   ```solidity
   function version() public pure virtual returns (string memory) {
       return "2.0.0";
   }
   ```

3. **UUPS Upgradeable**
   - Inherits from `UUPSUpgradeable`
   - Owner can upgrade implementation

4. **CREATE2 Deployment**
   - Deterministic addresses based on owner + salt
   - `getAddress(owner, salt)` for address prediction

## 📝 Migration Notes

### For New Accounts
- Simply create accounts using SimpleAccountFactoryV2
- No migration needed, works immediately with MetaMask `signMessage`

### For Existing V1 Accounts
- Option 1: Continue using V1 accounts (requires enabling `eth_sign` in MetaMask dev settings)
- Option 2: Create new V2 account (recommended for production)
- UUPS upgrade is possible but not recommended due to complexity

### MetaMask Configuration (Development Only)
For testing with `eth_sign` (V1 accounts):
1. Open MetaMask Settings
2. Advanced → Show test networks
3. Security & privacy → Enable "Eth_sign requests"

⚠️ **Warning**: `eth_sign` is disabled by default for security reasons. Only enable for development/testing.

## 🔐 Security Considerations

### Why Personal Sign is Safer
- Adds `\x19Ethereum Signed Message:\n32` prefix
- Prevents signature reuse across different contexts
- Industry standard (EIP-191)
- Enabled by default in MetaMask

### Why Eth_Sign was Disabled
- Can sign arbitrary data
- Potential phishing attack vector
- No context about what's being signed
- Deprecated in MetaMask for user safety

## 📚 Documentation Updates

Updated files:
- `/projects/demo/src/components/ContractInfo.tsx` - Factory address
- `/projects/demo/README.md` - Contract addresses table
- `/projects/demo/CONTRACTS_UPDATE.md` - Contract information
- `/projects/env/.env` - Environment variables

## 🚀 Next Steps

1. ✅ Deploy SimpleAccountFactoryV2 to Sepolia
2. ✅ Update demo configuration
3. ✅ Update documentation
4. 🔄 Test account creation in demo UI
5. 🔄 Test gasless transaction flow
6. 🔄 Verify MetaMask signature compatibility

## 📞 Support

- **Deployment Script**: `/projects/SuperPaymaster/script/DeployFactoryV2.s.sol`
- **Test Suite**: `/projects/SuperPaymaster/test/SimpleAccountFactoryV2.t.sol`
- **Factory Contract**: `/projects/SuperPaymaster/contracts/src/SimpleAccountFactoryV2.sol`
- **Account Contract**: `/projects/SuperPaymaster/contracts/src/SimpleAccountV2.sol`

## 📅 Deployment Date
- **Date**: 2025-10-10
- **Deployed by**: Claude Code Assistant
- **Network**: Sepolia Testnet
