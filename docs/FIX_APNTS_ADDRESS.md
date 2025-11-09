# aPNTs Address Configuration Fix

## Issue Summary

**Date**: 2025-11-09
**Severity**: Critical - Deposit functionality broken
**Error**: `AddressEmptyCode(address)`

Users were unable to deposit aPNTs to SuperPaymaster with error:
```
execution reverted {
  code: 3,
  message: 'execution reverted',
  data: '0x9996b3150000000000000000000000002ee6b2bc43022c37b5efb533836495209de5eca8'
}
```

## Root Cause

Address mismatch between frontend configuration and contract configuration:

| Component | aPNTs Address | Has Code? |
|-----------|---------------|-----------|
| SuperPaymaster (old) | `0x2EE6b2bC43022c37B5eFb533836495209dE5ecA8` | ❌ No |
| shared-config v0.3.1 | `0xBD0710596010a157B88cd141d797E8Ad4bb2306b` | ✅ Yes |

**Flow**:
1. Frontend uses shared-config address (`0xBD07...`)
2. User approves `0xBD07...`
3. User calls `depositAPNTs(1000 ether)`
4. SuperPaymaster tries to transfer from **its configured address** (`0x2ee6...`)
5. SafeERC20 checks if `0x2ee6...` has code
6. No code found → `AddressEmptyCode(0x2ee6...)` error

## Error Selector Decoding

```bash
$ cast 4byte 0x9996b315
AddressEmptyCode(address)
```

This is an OpenZeppelin `Address.sol` library error thrown when calling a contract that doesn't exist.

## Fix Applied

**Script**: `script/v2/FixAPNTsAddress.s.sol`

**Action**: Called `SuperPaymaster.setAPNTsToken(0xBD0710596010a157B88cd141d797E8Ad4bb2306b)`

**Executor**: Deployer account `0x411BD567E46C0781248dbB6a9211891C032885e5`

**Result**:
```
Current aPNTs token: 0x2EE6b2bC43022c37B5eFb533836495209dE5ecA8
Has code: false

Updating aPNTs token address...
Transaction sent!

New aPNTs token: 0xBD0710596010a157B88cd141d797E8Ad4bb2306b
Has code: true

SUCCESS! aPNTs address fixed.
```

## Verification

```bash
# Check new address
cast call 0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC "aPNTsToken()" --rpc-url $SEPOLIA_RPC_URL
# Returns: 0x000000000000000000000000BD0710596010a157B88cd141d797E8Ad4bb2306b ✅

# Verify it has code
cast code 0xBD0710596010a157B88cd141d797E8Ad4bb2306b --rpc-url $SEPOLIA_RPC_URL | head -c 100
# Returns: 0x608060... ✅
```

## Impact

✅ **Fixed**: Users can now deposit aPNTs successfully
✅ **No data loss**: No user funds affected (issue prevented deposits, didn't lock funds)
✅ **Aligned**: SuperPaymaster configuration now matches shared-config

## Prevention

1. **Deployment checklist**: Verify all token addresses have deployed contracts
2. **Shared-config sync**: Always use shared-config as single source of truth
3. **Pre-deployment validation**: Add script to verify all configured addresses:
   ```solidity
   require(aPNTsToken.code.length > 0, "aPNTs not deployed");
   ```

## Related Files

- Fix script: `script/v2/FixAPNTsAddress.s.sol`
- SuperPaymaster: `contracts/src/paymasters/v2/core/SuperPaymasterV2.sol:768`
- Frontend config: `registry/src/config/networkConfig.ts:121`
- shared-config: `node_modules/@aastar/shared-config/dist/index.js`
