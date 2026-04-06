# SuperPaymaster V5.3 — SDK E2E Scenario Guide

**Version**: SuperPaymaster-5.3.0
**Network**: Sepolia (Chain ID: 11155111) / Optimism Mainnet
**Date**: 2026-03-29
**Branch**: `feature/micropayment`

This guide documents all major business scenarios supported by SuperPaymaster V5.3, mapping each to the user-facing flow, on-chain contract calls, expected events, and the equivalent SDK API usage with viem.

---

## Contract Addresses (Sepolia)

| Contract | Address |
|---|---|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| SuperPaymaster (UUPS Proxy) | `0x829C3178DeF488C2dB65207B4225e18824696860` |
| Registry (UUPS Proxy) | `0xD88CF5316c64f753d024fcd665E69789b33A5EB6` |
| PaymasterFactory | `0x48c88B63512f4E697Ce606Ee73a5C6416FBD39Eb` |
| MicroPaymentChannel | `0x5753e9675f68221cA901e495C1696e33F552ea36` |
| AgentIdentityRegistry | `0x400624Fa1423612B5D16c416E1B4125699467d9a` |
| AgentReputationRegistry | `0x2D82b2De1A0745454cDCf38f8c022f453d02Ca55` |
| ReputationSystem | `0xB54F98b5133e8960ad92F03F98fc5868dd57deA2` |
| xPNTsFactory | `0xdEe2e78f0884a210Da64759FD306a7BfF5db4AA1` |
| MySBT | `0xf7D5C3c2443f8F0492fB9F5E2690ae6206Da0A9F` |
| aPNTs (GToken) | `0xEA4b9d046285DC21484174C36BbFb58015Ad5E1f` |
| USDC (Sepolia Circle) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

---

## Scenario 1: Basic Gasless Sponsorship (SBT-Gated)

**Summary**: A user who holds a MySBT token sends a UserOperation. SuperPaymaster validates SBT ownership in `validatePaymasterUserOp`, sponsors gas by consuming aPNTs from the operator's balance, and emits `TransactionSponsored` in postOp.

### Prerequisite State

- Community operator configured via `configureOperator()` with a valid xPNTs token and exchange rate.
- Operator has deposited aPNTs via `deposit()` or `depositFor()`.
- User's AA account address is linked via `Registry.registerRole(ROLE_ENDUSER, aaAccount, data)`.
- User's SBT status is enabled: `SuperPaymaster.sbtHolders[user] == true` (set by Registry when SBT is minted, or via `updateSBTStatus()` restricted to Registry).
- Operator ETH balance in EntryPoint is sufficient for gas prefunding.

### Step-by-Step Flow

1. **User** requests a gasless transaction (e.g., ERC20 transfer) via their AA wallet.
2. **SDK / bundler** constructs a `PackedUserOperation` with `paymasterAndData` pointing to SuperPaymaster:
   - Bytes 0-19: `SuperPaymaster` address
   - Bytes 20-35: `pmVerificationGasLimit` (uint128, e.g. 150000)
   - Bytes 36-51: `pmPostOpGasLimit` (uint128, e.g. 100000)
   - Bytes 52-71: `operatorAddress` (the xPNTs community operator)
3. **User (EOA owner)** signs the UserOp hash from EntryPoint.
4. **Bundler** submits `entryPoint.handleOps([userOp], beneficiary)`.
5. **EntryPoint** calls `SuperPaymaster.validatePaymasterUserOp()`:
   - Decodes `operatorAddress` from `paymasterAndData[52:72]`.
   - Calls `isEligibleForSponsorship(userOp.sender)` — checks `sbtHolders[sender]` OR `isRegisteredAgent(sender)`.
   - Checks operator is configured, not paused, and has sufficient aPNTs balance.
   - Checks `minTxInterval` (rate limiting).
   - Returns context bytes: `abi.encode(operator, user, initialAPNTs)`.
6. **EntryPoint** executes the user's `callData`.
7. **EntryPoint** calls `SuperPaymaster.postOp(PostOpMode, context, actualGasCost, actualUserOpFeePerGas)`:
   - Calculates final aPNTs charge via Chainlink price feed (or cached price).
   - Applies `protocolFeeBPS` on top of the base charge.
   - Calls `_consumeCredit(operator, user, aPNTsBase, preDeducted=true)` to record the deduction.
   - Emits `TransactionSponsored`.

### Contract Functions

```
// Setup (done once per operator)
SuperPaymaster.configureOperator(xPNTsToken, treasury, exchangeRate)
SuperPaymaster.deposit(amount)                // operator deposits aPNTs
Registry.registerRole(ROLE_ENDUSER, aaAccount, encodedData)

// Per-transaction (called by EntryPoint)
SuperPaymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost) → (context, validationData)
SuperPaymaster.isEligibleForSponsorship(user) → bool
SuperPaymaster.postOp(mode, context, actualGasCost, actualUserOpFeePerGas)

// Read
SuperPaymaster.sbtHolders(user) → bool
SuperPaymaster.operators(operator) → (aPNTsBalance, exchangeRate, isConfigured, isPaused, ...)
SuperPaymaster.cachedPrice() → (price, updatedAt, roundId, decimals)
```

### Expected Events

```
// Emitted in postOp
SuperPaymaster.TransactionSponsored(
    operator indexed,
    user indexed,
    uint256 aPNTsCharged,
    uint256 protocolFee,
    uint256 ethEquivalent
)

// Emitted by EntryPoint
EntryPoint.UserOperationEvent(
    userOpHash indexed,
    sender indexed,
    paymaster indexed,
    nonce,
    success,
    actualGasCost,
    actualGasUsed
)
```

### SDK Pseudo-code (viem)

```typescript
import {
  createWalletClient, createPublicClient, http, encodeAbiParameters,
  parseAbiParameters, encodeFunctionData, toHex, pad
} from 'viem';
import { sepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

const SUPER_PAYMASTER = '0x829C3178DeF488C2dB65207B4225e18824696860';
const ENTRY_POINT     = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const OPERATOR        = '0xYourOperatorAddress';

// 1. Build paymasterAndData
//    Layout: [paymaster 20B][pmVerifGas 16B][pmPostOpGas 16B][operator 20B]
const pmVerifGas  = pad(toHex(150000n), { size: 16 });
const pmPostOpGas = pad(toHex(100000n), { size: 16 });
const paymasterAndData = `${SUPER_PAYMASTER}${pmVerifGas.slice(2)}${pmPostOpGas.slice(2)}${OPERATOR.slice(2)}` as `0x${string}`;

// 2. Build the UserOp callData (AA wallet executes ERC20 transfer)
const callData = encodeFunctionData({
  abi: simpleAccountAbi,
  functionName: 'execute',
  args: [tokenAddress, 0n, encodeFunctionData({
    abi: erc20Abi,
    functionName: 'transfer',
    args: [recipientAddress, transferAmount]
  })]
});

// 3. Assemble PackedUserOperation (ERC-4337 v0.7)
const userOp = {
  sender: aaAccountAddress,
  nonce: await publicClient.readContract({ address: AA_ACCOUNT, abi: simpleAccountAbi, functionName: 'getNonce' }),
  initCode: '0x',
  callData,
  accountGasLimits: `0x${pad(toHex(200000n), { size: 16 }).slice(2)}${pad(toHex(200000n), { size: 16 }).slice(2)}`,
  preVerificationGas: 100000n,
  gasFees: `0x${pad(toHex(2000000000n), { size: 16 }).slice(2)}${pad(toHex(2000000000n), { size: 16 }).slice(2)}`,
  paymasterAndData,
  signature: '0x'
};

// 4. Sign
const userOpHash = await publicClient.readContract({
  address: ENTRY_POINT,
  abi: entryPointAbi,
  functionName: 'getUserOpHash',
  args: [userOp]
});
userOp.signature = await walletClient.signMessage({ message: { raw: userOpHash } });

// 5. Submit via bundler (or directly)
const txHash = await walletClient.writeContract({
  address: ENTRY_POINT,
  abi: entryPointAbi,
  functionName: 'handleOps',
  args: [[userOp], beneficiary]
});
```

### Test File Reference

- `script/gasless-tests/test-case-2-superpaymaster-xpnts1-fixed.js` — full E2E gasless flow with SuperPaymaster
- `script/gasless-tests/test-case-3-superpaymaster-xpnts2.js` — second operator variant
- Forge: `contracts/test/paymasters/superpaymaster/v3/SuperPaymasterVerification.t.sol`

---

## Scenario 2: PaymasterV4 Community Sponsorship

**Summary**: A community operator deploys their own PaymasterV4 instance via the factory. Users in that community send token transfers with zero gas using the PaymasterV4 address in `paymasterAndData`. The paymaster charges the AA wallet's deposited token balance.

### Prerequisite State

- Operator calls `PaymasterFactory.deployPaymaster(operator)` — creates a minimal proxy clone.
- Operator registers in Registry with `ROLE_PAYMASTER_AOA`.
- Operator calls `PaymasterV4.configureToken(tokenAddress, exchangeRate)` to whitelist the payment token.
- User's AA wallet holds the payment token and has a token balance deposited via `PaymasterV4.depositFor(aaAccount, tokenAddress, amount)`.
- PaymasterV4 has ETH deposited in EntryPoint via `entryPoint.depositTo(paymasterV4Address)`.

### Step-by-Step Flow

1. **User** requests a gasless transaction (ERC20 transfer, NFT mint, etc.).
2. **SDK** builds `paymasterAndData`:
   - Bytes 0-19: `paymasterV4Address`
   - Bytes 20-35: `pmVerificationGasLimit` (uint128)
   - Bytes 36-51: `pmPostOpGasLimit` (uint128)
   - Bytes 52-71: `tokenAddress` (whitelisted payment token)
3. **User** signs the UserOp hash.
4. **Bundler** submits `entryPoint.handleOps([userOp], beneficiary)`.
5. **EntryPoint** calls `PaymasterV4.validatePaymasterUserOp()`:
   - Decodes `tokenAddress` from `paymasterAndData[52:72]`.
   - Checks user has sufficient token deposit: `deposits[aaAccount][token] >= maxTokenCost`.
   - Pre-deducts the max token cost from user's deposit.
   - Returns context for postOp.
6. **EntryPoint** executes the user's callData.
7. **EntryPoint** calls `PaymasterV4.postOp()`:
   - Calculates actual token cost from `actualGasCost` via Chainlink oracle (`cachedPrice`).
   - Refunds over-charged tokens to user's deposit.
   - Emits `PostOpProcessed`.

### Contract Functions

```
// Factory deployment (one-time per operator)
PaymasterFactory.deployPaymaster(operator) → paymasterV4Address

// Operator setup
PaymasterV4.configureToken(tokenAddress, exchangeRate)
EntryPoint.depositTo{ value: ethAmount }(paymasterV4Address)

// User pre-funding
PaymasterV4.depositFor(aaAccount, tokenAddress, amount)

// Per-transaction (called by EntryPoint)
PaymasterV4.validatePaymasterUserOp(userOp, userOpHash, maxCost) → (context, validationData)
PaymasterV4.postOp(mode, context, actualGasCost, actualUserOpFeePerGas)

// Read
PaymasterFactory.paymasterByOperator(operator) → address
PaymasterV4.getSupportedTokens() → address[]
PaymasterV4.cachedPrice() → (price, updatedAt)
PaymasterV4.userDeposits(user, token) → uint256
```

### Expected Events

```
// Emitted in PaymasterV4.postOp
PaymasterV4.PostOpProcessed(
    user indexed,
    token indexed,
    tokensCharged,
    ethEquivalent
)

// Emitted by EntryPoint
EntryPoint.UserOperationEvent(userOpHash, sender, paymaster, nonce, success, actualGasCost, actualGasUsed)
```

### SDK Pseudo-code (viem)

```typescript
import { encodeFunctionData, pad, toHex } from 'viem';

// Resolve PaymasterV4 address for operator
const paymasterV4 = await publicClient.readContract({
  address: PAYMASTER_FACTORY,
  abi: paymasterFactoryAbi,
  functionName: 'paymasterByOperator',
  args: [operatorAddress]
});

// paymasterAndData layout: [paymasterV4 20B][pmVerifGas 16B][pmPostOpGas 16B][tokenAddress 20B]
const pmVerifGas  = pad(toHex(100000n), { size: 16 });
const pmPostOpGas = pad(toHex(80000n),  { size: 16 });
const paymasterAndData = `${paymasterV4}${pmVerifGas.slice(2)}${pmPostOpGas.slice(2)}${tokenAddress.slice(2)}` as `0x${string}`;

// Construct + sign userOp same as Scenario 1 but using paymasterV4 address and tokenAddress
// ...submit via entryPoint.handleOps
```

### Test File Reference

- `script/gasless-tests/test-case-1-paymasterv4.js` — full E2E PaymasterV4 gasless test
- `script/gasless-tests/test-group-B1-operator-config.js` — operator configuration checks
- `script/gasless-tests/test-group-B2-operator-deposit-withdraw.js` — deposit/withdraw flows
- Forge: `contracts/test/v4/PaymasterV4.t.sol`

---

## Scenario 3: x402 HTTP Payment (EIP-3009 USDC)

**Summary**: A client requests a resource protected by HTTP 402. The server returns payment requirements. The client signs an EIP-3009 `transferWithAuthorization` off-chain. A facilitator (operator running the x402-facilitator-node) calls `SuperPaymaster.settleX402Payment()` to atomically transfer USDC from payer to payee, deducting a facilitator fee.

### Prerequisite State

- SuperPaymaster V5.3.0 deployed with `settleX402Payment()` function.
- `facilitatorFeeBPS` set (e.g. 200 = 2%) via `setFacilitatorFeeBPS(200)`.
- Facilitator operator has `ROLE_PAYMASTER_SUPER` in Registry.
- Payer holds USDC (EIP-3009 compatible: Circle USDC supports `transferWithAuthorization`).
- x402 Facilitator Node running at `https://facilitator.yourdomain.com`.

### Step-by-Step Flow

1. **Client** makes an HTTP GET request to a paid resource.
2. **Server** responds with HTTP 402 and `X-Payment-Required` header (x402 v2 format):
   ```json
   {
     "scheme": "eip-3009",
     "networkId": "eip155:11155111",
     "facilitatorUrl": "https://facilitator.yourdomain.com",
     "paymentRequirements": {
       "asset": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
       "amount": "1000000",
       "payTo": "0xPayeeAddress",
       "maxTimeoutSeconds": 3600
     }
   }
   ```
3. **Client** calls `GET /quote` on facilitator to verify fee structure.
4. **Client** signs an EIP-3009 `TransferWithAuthorization` typed data:
   - `from`: payer address
   - `to`: SuperPaymaster address (receives USDC and splits to payee + fee)
   - `value`: full amount
   - `validAfter`: 0
   - `validBefore`: `now + 3600`
   - `nonce`: random bytes32
5. **Client** calls `POST /verify` on facilitator with the signed payment payload.
6. **Facilitator** validates signature and available balance.
7. **Client** calls `POST /settle` on facilitator (or facilitator does so automatically after verify).
8. **Facilitator** calls `SuperPaymaster.settleX402Payment()` on-chain.
9. **SuperPaymaster** uses EIP-3009 `IUSDC.transferWithAuthorization()` to pull USDC from payer.
10. SuperPaymaster splits: `payee` receives `amount * (10000 - feeBPS) / 10000`, facilitator fee goes to `facilitatorEarnings[facilitator][USDC]`.
11. **SuperPaymaster** emits `SettlementProcessed` and marks the nonce as consumed (replay protection).

### Contract Functions

```
// Facilitator setup
SuperPaymaster.setFacilitatorFeeBPS(uint256 feeBPS)

// Per-settlement (called by facilitator EOA)
SuperPaymaster.settleX402Payment(
    address from,
    address to,
    address asset,
    uint256 amount,
    uint256 validAfter,
    uint256 validBefore,
    bytes32 nonce,
    bytes signature
) → bytes32 settlementId

// Facilitator fee withdrawal
SuperPaymaster.withdrawFacilitatorEarnings(address token, uint256 amount)

// Read
SuperPaymaster.facilitatorFeeBPS() → uint256
SuperPaymaster.facilitatorEarnings(facilitator, token) → uint256
SuperPaymaster.x402SettlementNonces(nonce) → bool
```

### Expected Events

```
SuperPaymaster.SettlementProcessed(
    address indexed from,
    address indexed to,
    address indexed asset,
    uint256 amount,
    uint256 fee,
    bytes32 nonce
)
```

### EIP-3009 Typed Data (client-side signing)

```typescript
import { signTypedData } from 'viem/actions';

const domain = {
  name: 'USDC',
  version: '2',
  chainId: 11155111n,
  verifyingContract: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238'
};

const types = {
  TransferWithAuthorization: [
    { name: 'from',        type: 'address' },
    { name: 'to',          type: 'address' },
    { name: 'value',       type: 'uint256' },
    { name: 'validAfter',  type: 'uint256' },
    { name: 'validBefore', type: 'uint256' },
    { name: 'nonce',       type: 'bytes32' },
  ]
};

const nonce = `0x${Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('hex')}` as `0x${string}`;
const validBefore = BigInt(Math.floor(Date.now() / 1000) + 3600);

const signature = await walletClient.signTypedData({
  domain,
  types,
  primaryType: 'TransferWithAuthorization',
  message: {
    from: payerAddress,
    to: SUPER_PAYMASTER,       // SuperPaymaster receives, then splits
    value: amount,
    validAfter: 0n,
    validBefore,
    nonce
  }
});

// Call facilitator API
const response = await fetch(`${facilitatorUrl}/settle`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    from: payerAddress,
    to: payeeAddress,
    asset: USDC_ADDRESS,
    amount: amount.toString(),
    validAfter: '0',
    validBefore: validBefore.toString(),
    nonce,
    signature,
    scheme: 'eip-3009'
  })
});

// Facilitator calls on-chain (internally):
const settleTxHash = await walletClient.writeContract({
  address: SUPER_PAYMASTER,
  abi: superPaymasterAbi,
  functionName: 'settleX402Payment',
  args: [payerAddress, payeeAddress, USDC_ADDRESS, amount, 0n, validBefore, nonce, signature]
});
```

### Test File Reference

- `script/gasless-tests/test-x402-eip3009-settlement.js` — full E2E EIP-3009 settlement test (Sepolia verified)
- `script/gasless-tests/test-x402-permit2-settlement.js` — Permit2 variant (Sepolia verified)
- Forge: `contracts/test/paymasters/superpaymaster/v3/SuperPaymasterV5Features.t.sol` — `testSettleX402Payment_*` tests

---

## Scenario 4: Micropayment Channel

**Summary**: A payer opens a streaming channel with a deposit. They issue cumulative signed vouchers off-chain that the payee can settle at any time. The payee closes the channel with a final voucher and receives the net amount; the payer is refunded the remainder.

### Prerequisite State

- `MicroPaymentChannel` deployed at `0x5753e9675f68221cA901e495C1696e33F552ea36`.
- Payer holds aPNTs (or any ERC20 accepted as the channel token).
- Payer has approved `MicroPaymentChannel` to spend their tokens.
- Payee address is known.

### Step-by-Step Flow

1. **Payer** calls `aPNTs.approve(MicroPaymentChannel, depositAmount)`.
2. **Payer** calls `MicroPaymentChannel.openChannel(payee, token, deposit, salt, authorizedSigner)`:
   - Transfers `deposit` tokens from payer to MicroPaymentChannel.
   - Emits `ChannelOpened(channelId, payer, payee, token, deposit)`.
   - Returns `channelId = keccak256(abi.encode(payer, payee, token, salt))`.
3. **Payer** signs cumulative vouchers off-chain using EIP-712:
   - `Voucher { channelId, cumulativeAmount }` signed against MicroPaymentChannel domain.
4. **Payee** calls `MicroPaymentChannel.settleChannel(channelId, cumulativeAmount, signature)` at any point to claim intermediate payment:
   - Verifies payer signature.
   - Transfers `cumulativeAmount - alreadySettled` tokens to payee.
   - Updates `channel.settled`.
5. **Payee** calls `MicroPaymentChannel.closeChannel(channelId, finalCumulativeAmount, signature)` to finalize:
   - Verifies payer signature on final amount.
   - Transfers remaining tokens to payee.
   - Refunds `deposit - finalCumulativeAmount` to payer.
   - Sets `channel.finalized = true`.
   - Emits `ChannelClosed(channelId, totalSettled, refund)`.

**Dispute path (payer-initiated)**: If payee is unresponsive after channel time limit, payer can call `requestClose()`, wait for dispute window (15 minutes), then call `forceClose()`.

### Contract Functions

```
// MicroPaymentChannel at 0x5753e9675f68221cA901e495C1696e33F552ea36
MicroPaymentChannel.openChannel(
    address payee,
    address token,
    uint128 deposit,
    bytes32 salt,
    address authorizedSigner    // optional delegated signer, use address(0) for payer
) → bytes32 channelId

MicroPaymentChannel.settleChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature)
MicroPaymentChannel.closeChannel(bytes32 channelId, uint128 cumulativeAmount, bytes signature)

// Dispute resolution
MicroPaymentChannel.requestClose(bytes32 channelId)
MicroPaymentChannel.forceClose(bytes32 channelId)

// Read
MicroPaymentChannel.getChannel(channelId) → (payer, payee, token, authorizedSigner, deposit, settled, closeRequestedAt, finalized)
MicroPaymentChannel.VOUCHER_TYPEHASH() → bytes32
```

### Expected Events

```
MicroPaymentChannel.ChannelOpened(
    bytes32 indexed channelId,
    address indexed payer,
    address indexed payee,
    address token,
    uint128 deposit
)

MicroPaymentChannel.ChannelSettled(
    bytes32 indexed channelId,
    uint128 amount,
    uint128 totalSettled
)

MicroPaymentChannel.ChannelClosed(
    bytes32 indexed channelId,
    uint128 totalSettled,
    uint128 refund
)
```

### SDK Pseudo-code (viem)

```typescript
import { encodeAbiParameters, keccak256, toBytes, signTypedData } from 'viem';

const MPC_ADDRESS = '0x5753e9675f68221cA901e495C1696e33F552ea36';
const APNTS       = '0xEA4b9d046285DC21484174C36BbFb58015Ad5E1f';

// Step 1: Approve
await walletClient.writeContract({
  address: APNTS,
  abi: erc20Abi,
  functionName: 'approve',
  args: [MPC_ADDRESS, 2n ** 256n - 1n]
});

// Step 2: Open channel
const salt = keccak256(toBytes(Date.now().toString()));
const openTx = await walletClient.writeContract({
  address: MPC_ADDRESS,
  abi: mpcAbi,
  functionName: 'openChannel',
  args: [payeeAddress, APNTS, depositAmount, salt, zeroAddress]
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: openTx });
const channelId = receipt.logs[0].topics[1]; // ChannelOpened event, first indexed param

// Step 3: Sign a voucher (payer side, off-chain)
const voucherSignature = await walletClient.signTypedData({
  domain: {
    name: 'MicroPaymentChannel',
    version: '1.0.0',
    chainId: 11155111n,
    verifyingContract: MPC_ADDRESS
  },
  types: {
    Voucher: [
      { name: 'channelId',        type: 'bytes32' },
      { name: 'cumulativeAmount', type: 'uint128' }
    ]
  },
  primaryType: 'Voucher',
  message: { channelId, cumulativeAmount: partialAmount }
});

// Step 4: Payee settles partial (payee's wallet client)
await payeeWalletClient.writeContract({
  address: MPC_ADDRESS,
  abi: mpcAbi,
  functionName: 'settleChannel',
  args: [channelId, partialAmount, voucherSignature]
});

// Step 5: Payee closes channel with final voucher
const finalSignature = await walletClient.signTypedData({ /* same domain/types */
  primaryType: 'Voucher',
  message: { channelId, cumulativeAmount: finalAmount }
});

await payeeWalletClient.writeContract({
  address: MPC_ADDRESS,
  abi: mpcAbi,
  functionName: 'closeChannel',
  args: [channelId, finalAmount, finalSignature]
});
```

### Test File Reference

- `script/gasless-tests/test-micropayment-channel.js` — full lifecycle E2E test (Sepolia verified: open/settle/close)
- Forge: `contracts/test/v3/MicroPaymentChannel.t.sol` (if exists) or integration tests in V5Features suite

---

## Scenario 5: Reputation-Gated Sponsorship

**Summary**: A user earns a higher reputation score through on-chain activities. The `ReputationSystem` computes a composite score across community rules. A high enough score raises the user's credit tier in Registry, granting a higher credit limit and enabling SuperPaymaster to sponsor larger gas operations that would otherwise be blocked by the credit cap.

### Prerequisite State

- Community operator has `ROLE_COMMUNITY` in Registry.
- `ReputationSystem.setRule(ruleId, baseScore, activityBonus, maxBonus, description)` called by community.
- User has `ROLE_ENDUSER` in Registry.
- Registry has credit tiers configured: `setCreditTier(level, limitInAPNTs)` for levels 1-6+.
- `Registry.levelThresholds` set to define the reputation score → tier mapping.

### Step-by-Step Flow

1. **Community operator** calls `ReputationSystem.setRule(ruleId, 20, 5, 200, "activity")` to define a scoring rule.
2. **Community operator** calls `ReputationSystem.setCommunityReputation(community, user, score)` OR the reputation is updated via `ReputationSystem.computeScore()` using the user's activity data and written back.
3. **Community operator** calls `ReputationSystem.syncToRegistry(user, globalScore)` (or Registry reads via `globalReputation(user)`) — the global reputation score is written to `Registry.globalReputation[user]`.
4. **Registry** maps `globalReputation[user]` to a credit tier using `levelThresholds`:
   - `getCreditLimit(user)` iterates `levelThresholds` to find the matching tier, then returns `creditTierConfig[tier]`.
5. **SuperPaymaster** checks credit limit during `validatePaymasterUserOp`:
   - Computes the USD-equivalent cost of the UserOp using the Chainlink oracle.
   - Calls `Registry.getCreditLimit(user)`.
   - Rejects if `estimatedCost > creditLimit`.
6. With a higher reputation score, the user can now sponsor larger transactions.

### Contract Functions

```
// Community operator calls:
ReputationSystem.setRule(bytes32 ruleId, uint256 base, uint256 bonus, uint256 max, string desc)
ReputationSystem.setEntropyFactor(address community, uint256 factor)
ReputationSystem.setCommunityReputation(address community, address user, uint256 score)

// Read scoring
ReputationSystem.computeScore(
    address user,
    address[] communities,
    bytes32[][] ruleIds,
    uint256[][] activities
) → uint256 globalScore

// Admin sets tier thresholds (owner only)
Registry.setCreditTier(uint256 level, uint256 limitInAPNTs)
// levelThresholds are set separately via setLevelThresholds(uint256[])

// Read credit
Registry.getCreditLimit(user) → uint256
Registry.globalReputation(user) → uint256
Registry.levelThresholds(index) → uint256
Registry.creditTierConfig(level) → uint256
```

### Expected Events

```
ReputationSystem.ReputationUpdated(
    address indexed community,
    address indexed user,
    uint256 newScore
)

Registry.CreditTierUpdated(
    uint256 indexed level,
    uint256 newLimit
)
```

### SDK Pseudo-code (viem)

```typescript
// Community operator updates reputation
await communityWalletClient.writeContract({
  address: REPUTATION_SYSTEM,
  abi: reputationSystemAbi,
  functionName: 'setCommunityReputation',
  args: [communityAddress, userAddress, 850n]  // score 850/1000
});

// Admin sets credit tier 3 = $5 equivalent in aPNTs
const aPNTsLimit = parseUnits('5', 18) * 100n; // $5 at $0.05/aPNTs
await adminWalletClient.writeContract({
  address: REGISTRY,
  abi: registryAbi,
  functionName: 'setCreditTier',
  args: [3n, aPNTsLimit]
});

// Read what credit limit a user currently has
const creditLimit = await publicClient.readContract({
  address: REGISTRY,
  abi: registryAbi,
  functionName: 'getCreditLimit',
  args: [userAddress]
});
console.log(`User credit limit: ${formatEther(creditLimit)} aPNTs`);

// computeScore view call (no TX needed)
const score = await publicClient.readContract({
  address: REPUTATION_SYSTEM,
  abi: reputationSystemAbi,
  functionName: 'computeScore',
  args: [userAddress, [communityAddress], [[ruleId]], [[activityCount]]]
});
```

### Test File Reference

- `script/gasless-tests/test-group-D1-reputation-rules.js` — reputation rule CRUD + computeScore
- `script/gasless-tests/test-group-D2-credit-tiers.js` — credit tier config + getCreditLimit
- Forge: `contracts/test/v3/Registry.t.sol` — credit tier integration tests
- NEW: `test-group-G-reputation-credit-sponsorship.js` — integrated scenario showing reputation → credit → sponsorship gating

---

## Scenario 6: Agent Identity Sponsorship (ERC-8004)

**Summary**: An AI agent registers its identity in the `AgentIdentityRegistry`. The operator sets an agent-specific sponsorship policy with a per-BPS discount. When the agent sends a UserOp, `isEligibleForSponsorship()` returns true via the agent NFT path (not SBT), and the discounted rate is applied.

### Prerequisite State

- `AgentIdentityRegistry` deployed at `0x400624Fa1423612B5D16c416E1B4125699467d9a`.
- `AgentReputationRegistry` deployed at `0x2D82b2De1A0745454cDCf38f8c022f453d02Ca55`.
- Operator has wired `SuperPaymaster.setAgentIdentityRegistry(agentRegistryAddr)` and `setAgentReputationRegistry(repRegistryAddr)`.
- Agent has an EOA-controlled AA wallet address.

### Step-by-Step Flow

1. **Agent owner** calls `AgentIdentityRegistry.registerAgent(agentAAAddress)` — mints an Agent NFT, returns `agentId`.
2. **Agent reputation** is set: `AgentReputationRegistry.setReputation(agentId, agentId, 800)` (score 80/100 normalized).
3. **Operator** calls `SuperPaymaster.setAgentPolicies(policies)`:
   - `policies[0] = AgentPolicy { minReputationScore: 50, sponsorshipRateBPS: 5000, dailyUSDCap: 100e18 }` — 50% gas sponsorship for agents with score >= 50.
4. **Agent** sends a UserOp (e.g., making an on-chain API call on behalf of a user).
5. **SuperPaymaster.validatePaymasterUserOp** calls `isEligibleForSponsorship(agentAddress)`:
   - `sbtHolders[agentAddress]` is false.
   - `isRegisteredAgent(agentAddress)` → calls `AgentIdentityRegistry.isRegistered(agentAddress)` → true.
   - Eligibility confirmed via agent path.
6. **SuperPaymaster** calls `getAgentSponsorshipRate(agentAddress, operator)`:
   - Looks up agent reputation from `AgentReputationRegistry`.
   - Matches against operator's policies to find the highest eligible tier.
   - Returns BPS rate (e.g. 5000 = 50% discount means agent pays 50% of gas, operator covers 50%).
7. **SuperPaymaster** applies `_applyAgentSponsorship()` in postOp: reduces aPNTs deduction by the sponsorship BPS.
8. **SuperPaymaster** calls `_submitSponsorshipFeedback(agentAddress, success)` → `AgentReputationRegistry.giveFeedback(agentId, success)`.

### Contract Functions

```
// AgentIdentityRegistry
AgentIdentityRegistry.registerAgent(address agentAddress) → uint256 agentId
AgentIdentityRegistry.isRegistered(address agent) → bool
AgentIdentityRegistry.getAgentId(address agent) → uint256

// AgentReputationRegistry
AgentReputationRegistry.setReputation(uint256 agentId, uint256 dimension, uint256 score)
AgentReputationRegistry.getAverageScore(uint256 agentId) → uint256
AgentReputationRegistry.giveFeedback(uint256 agentId, bool success)

// SuperPaymaster — agent policy management
SuperPaymaster.setAgentPolicies(
    AgentPolicy[] calldata policies
    // AgentPolicy { uint256 minReputationScore, uint256 sponsorshipRateBPS, uint256 dailyUSDCap }
)
SuperPaymaster.getAgentSponsorshipRate(address agent, address operator) → uint256 bps
SuperPaymaster.isEligibleForSponsorship(address user) → bool

// Read
SuperPaymaster.agentIdentityRegistry() → address
SuperPaymaster.agentReputationRegistry() → address
SuperPaymaster.agentPolicies(operator, index) → AgentPolicy
```

### Expected Events

```
AgentIdentityRegistry.AgentRegistered(
    uint256 indexed agentId,
    address indexed agentAddress
)

SuperPaymaster.AgentSponsorshipApplied(
    address indexed agent,
    address indexed operator,
    uint256 originalCost,
    uint256 discountBPS,
    uint256 finalCost
)

SuperPaymaster.TransactionSponsored(
    operator indexed,
    user indexed,
    uint256 aPNTsCharged,
    uint256 protocolFee,
    uint256 ethEquivalent
)
```

### SDK Pseudo-code (viem)

```typescript
// 1. Register agent
const registerTx = await walletClient.writeContract({
  address: AGENT_IDENTITY_REGISTRY,
  abi: agentIdentityRegistryAbi,
  functionName: 'registerAgent',
  args: [agentAAAddress]
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: registerTx });
// Parse agentId from AgentRegistered event

// 2. Set agent reputation
await adminWalletClient.writeContract({
  address: AGENT_REPUTATION_REGISTRY,
  abi: agentReputationRegistryAbi,
  functionName: 'setReputation',
  args: [agentId, agentId, 800n]  // dimension = agentId, score = 800 (normalized to 80/100)
});

// 3. Operator sets agent policy
await operatorWalletClient.writeContract({
  address: SUPER_PAYMASTER,
  abi: superPaymasterAbi,
  functionName: 'setAgentPolicies',
  args: [[{
    minReputationScore: 50n,
    sponsorshipRateBPS: 5000n,  // 50% discount
    dailyUSDCap: parseUnits('100', 18)
  }]]
});

// 4. Verify eligibility
const eligible = await publicClient.readContract({
  address: SUPER_PAYMASTER,
  abi: superPaymasterAbi,
  functionName: 'isEligibleForSponsorship',
  args: [agentAAAddress]
});
console.log(`Agent eligible: ${eligible}`);  // true

const rate = await publicClient.readContract({
  address: SUPER_PAYMASTER,
  abi: superPaymasterAbi,
  functionName: 'getAgentSponsorshipRate',
  args: [agentAAAddress, operatorAddress]
});
console.log(`Sponsorship rate: ${rate} BPS (${Number(rate) / 100}%)`);  // 5000 BPS = 50%

// 5. Agent sends UserOp with same paymasterAndData as Scenario 1 — automatic discount applies
```

### Test File Reference

- Forge: `contracts/test/v3/SuperPaymasterV5Features.t.sol` — `testAgentSponsorship_*`, `testSetAgentPolicies_*`
- V5 Acceptance Report Section 0 — live E2E verification on Sepolia (registerAgent → setReputation → setAgentPolicies → isEligibleForSponsorship chain)
- NEW: `script/gasless-tests/test-group-G-agent-sponsorship.js` — agent identity + policy + gasless UserOp

---

## Scenario 7: Credit Tier Escalation

**Summary**: A new user starts at credit tier 0 (no credit). Over time they build reputation. An admin upgrades their tier. The higher tier grants a larger credit limit, enabling sponsorship of more expensive gas operations.

### Prerequisite State

- User has `ROLE_ENDUSER` in Registry (registered via `registerRole`).
- Credit tiers 1-6 configured with aPNTs limits.
- Level thresholds set: e.g., threshold[0]=200, threshold[1]=400, ..., threshold[5]=900.
- `globalReputation[user]` starts at 0 (new user).

### Step-by-Step Flow

**Phase A — New user (Tier 0, ~$0.50 limit):**

1. **User** registers as ENDUSER: `Registry.registerRole(ROLE_ENDUSER, aaAccount, encodeEndUserRoleData(...))`.
2. **Read**: `Registry.getCreditLimit(user)` → returns 0 (no tier match, default tier 0 limit, or the lowest configured tier).
3. **User** attempts a large gas operation → SuperPaymaster rejects with `CreditLimitExceeded` if cost > limit.

**Phase B — Reputation building:**

4. **Community** runs activities: user earns reputation points via `ReputationSystem.setCommunityReputation(community, user, 300)`.
5. **Community** calls sync (or Registry auto-reads): `Registry.globalReputation[user]` = 300.
6. `getCreditLimit(user)` now returns Tier 1 limit (threshold[0]=200 ≤ 300 < threshold[1]=400 → Tier 1).

**Phase C — Admin tier upgrade:**

7. **Admin** calls `Registry.setCreditTier(2, parseEther('10'))` to raise Tier 2 limit to 10 aPNTs.
8. Community boosts user further: `globalReputation[user]` = 450 → now Tier 2.
9. `getCreditLimit(user)` → 10 aPNTs (≈$0.50 @ $0.05/aPNTs at current price, but scalable).
10. **User** can now submit larger UserOps that cost up to 10 aPNTs in gas.

### Contract Functions

```
// User registration
Registry.registerRole(bytes32 ROLE_ENDUSER, address aaAccount, bytes encodedData)

// Admin tier management
Registry.setCreditTier(uint256 level, uint256 limitInAPNTs)
Registry.setLevelThresholds(uint256[] thresholds)

// Reputation-driven tier progression
ReputationSystem.setCommunityReputation(address community, address user, uint256 score)
Registry.globalReputation(user) → uint256    // read current score

// Credit check
Registry.getCreditLimit(address user) → uint256
Registry.creditTierConfig(uint256 level) → uint256
Registry.levelThresholds(uint256 index) → uint256

// SuperPaymaster credit enforcement (internal, checked during validatePaymasterUserOp)
// SuperPaymaster._consumeCredit(operator, user, aPNTsBase, preDeducted)
```

### Expected Events

```
Registry.RoleRegistered(
    bytes32 indexed roleId,
    address indexed user,
    uint256 tokenId
)

Registry.CreditTierUpdated(
    uint256 indexed level,
    uint256 newLimit
)

// Emitted if sponsorship blocked
SuperPaymaster.SponsorshipRejected(
    address indexed operator,
    address indexed user,
    string reason   // "CreditLimitExceeded"
)
```

### SDK Pseudo-code (viem)

```typescript
import { encodeAbiParameters, parseAbiParameters, parseEther } from 'viem';

// Encode ENDUSER role data: (address account, address community, string, string, uint256)
const encodedRoleData = encodeAbiParameters(
  parseAbiParameters('(address, address, string, string, uint256)'),
  [[aaAccountAddress, communityAddress, '', '', parseEther('0.3')]]
);

// Register user
await walletClient.writeContract({
  address: REGISTRY,
  abi: registryAbi,
  functionName: 'registerRole',
  args: [ROLE_ENDUSER_HASH, aaAccountAddress, encodedRoleData]
});

// Admin: Configure credit tiers
const tierConfigs = [
  [1n, parseEther('2')],    // Tier 1: 2 aPNTs (~$0.10)
  [2n, parseEther('10')],   // Tier 2: 10 aPNTs (~$0.50)
  [3n, parseEther('50')],   // Tier 3: 50 aPNTs (~$2.50)
];
for (const [level, limit] of tierConfigs) {
  await adminWalletClient.writeContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'setCreditTier',
    args: [level, limit]
  });
}

// Monitor user's credit limit over time
const creditLimit = await publicClient.readContract({
  address: REGISTRY,
  abi: registryAbi,
  functionName: 'getCreditLimit',
  args: [userAddress]
});

const globalRep = await publicClient.readContract({
  address: REGISTRY,
  abi: registryAbi,
  functionName: 'globalReputation',
  args: [userAddress]
});

console.log(`User rep: ${globalRep}, credit limit: ${formatEther(creditLimit)} aPNTs`);
```

### Test File Reference

- `script/gasless-tests/test-group-D2-credit-tiers.js` — setCreditTier, getCreditLimit, levelThresholds
- `script/gasless-tests/test-group-A1-registry-roles.js` — ENDUSER registration
- Forge: `contracts/test/v3/V3_DynamicLevelThresholds.t.sol` — boundary tests (20 levels, batch 200)
- NEW: `script/gasless-tests/test-group-G-credit-escalation.js` — full scenario from new user to tier 3

---

## Summary Table

| Scenario | Key Contracts | Primary User | Entry Point | Test File |
|---|---|---|---|---|
| 1. SBT Gasless | SuperPaymaster, Registry | AA wallet user | `entryPoint.handleOps` | `test-case-2-superpaymaster-xpnts1-fixed.js` |
| 2. PaymasterV4 | PaymasterV4, PaymasterFactory | AA wallet user | `entryPoint.handleOps` | `test-case-1-paymasterv4.js` |
| 3. x402 EIP-3009 | SuperPaymaster, USDC | HTTP client | `settleX402Payment()` | `test-x402-eip3009-settlement.js` |
| 4. MPC Channel | MicroPaymentChannel, aPNTs | Payer EOA | `openChannel/closeChannel` | `test-micropayment-channel.js` |
| 5. Reputation-Gated | ReputationSystem, Registry | Community operator | `setCommunityReputation` | `test-group-D1/D2.js` |
| 6. Agent (ERC-8004) | AgentIdentityRegistry, SuperPaymaster | Agent AA wallet | `entryPoint.handleOps` | `SuperPaymasterV5Features.t.sol` |
| 7. Credit Escalation | Registry, ReputationSystem | Admin + community | `setCreditTier`, `registerRole` | `test-group-D2-credit-tiers.js` |

---

## Gas Reference

| Operation | Gas Used | Notes |
|---|---|---|
| SuperPaymaster gasless TX | ~448,200 | Includes oracle read + postOp deduction |
| PaymasterV4 gasless TX | ~412,311 | Simpler path, no shared registry lookup |
| `settleX402Payment` (EIP-3009) | ~161,000 | EIP-3009 transferWithAuthorization + fee split |
| `settleX402Payment` (first nonce) | ~200,083 | Cold storage slots on Sepolia |
| `openChannel` (MPC) | ~163,085 | ERC20 transferFrom + channel struct write |
| `settleChannel` | ~72,074 | Signature verification + ERC20 transfer |
| `closeChannel` | ~97,605 | Final settlement + refund + finalization flag |
| `deposit()` aPNTs | ~77,166 | ERC20 transferFrom + balance update |
| `slashOperator` (WARNING) | ~119,419 | Slash record write + reputation update |

---

## Environment Variables Required

```bash
# Network
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/...
RPC_URL=<same or alias>

# Signers
PRIVATE_KEY=0x...           # Deployer / main operator
ANNI_PRIVATE_KEY=0x...      # Secondary operator (Anni)

# Test accounts
OPERATOR_ADDRESS=0x...
TEST_AA_ACCOUNT_ADDRESS_A=0x...
TEST_AA_ACCOUNT_ADDRESS_B=0x...
TEST_EOA_ADDRESS=0x...
OWNER2_ADDRESS=0x...
```

---

## Common Error Patterns

| Error | Root Cause | Fix |
|---|---|---|
| `SBTRequired` | `sbtHolders[user] = false` and not a registered agent | Mint SBT via `Registry.safeMintForRole(ROLE_ENDUSER, user, data)` or register as agent |
| `OperatorNotConfigured` | `operators[operator].isConfigured = false` | Call `SuperPaymaster.configureOperator(xPNTsToken, treasury, exchangeRate)` |
| `InsufficientAPNTs` | Operator aPNTs balance < estimated gas cost | Call `SuperPaymaster.depositFor(operator, amount)` |
| `PriceStale` | Chainlink price not updated within staleness window | Call `SuperPaymaster.updatePrice()` before submitting UserOp |
| `CreditLimitExceeded` | User's `getCreditLimit` < estimated aPNTs cost | Raise reputation score or admin escalates tier |
| `NonceAlreadyUsed` | x402 nonce reused in `settleX402Payment` | Generate fresh `bytes32` random nonce per payment |
| `ChannelFinalized` | Attempting to settle a closed MPC channel | Query `getChannel(channelId).finalized` before settlement |
| `DailyCapExceeded` | Agent's daily USD spend > `agentPolicies.dailyUSDCap` | Wait for UTC midnight reset or operator raises the cap |
