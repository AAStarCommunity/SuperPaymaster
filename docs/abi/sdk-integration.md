# SuperPaymaster — SDK Integration Guide

Integration flows for the main capabilities. Signatures/selectors are authoritative in [`reference.md`](./reference.md); working examples are the scripts under [`script/gasless-tests/`](../../script/gasless-tests/).

Key addresses are environment-specific — read them from `deployments/config.<network>.json` (`superPaymaster`, `paymasterFactory`, `aPNTs`, `entryPoint`, `microPaymentChannel`).

> EntryPoint v0.7: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

---

## 1. Gasless UserOp via SuperPaymaster (AOA+)

1. Operator is configured once: `configureOperator(xPNTsToken, treasury)` and funded with the canonical aPNTs via `deposit(amount)` (the token is `SuperPaymaster.APNTS_TOKEN()` — **not** necessarily `config.aPNTs`; read it dynamically).
2. The user must be sponsorship-eligible: `isEligibleForSponsorship(sender)` (SBT holder OR registered agent).
3. Build a PackedUserOperation whose `paymasterAndData` = `paymaster(20) ‖ verificationGasLimit(16) ‖ postOpGasLimit(16) ‖ operator(20) ‖ [maxRate(32)]`.
4. Submit via `EntryPoint.handleOps([userOp], beneficiary)`. On success the operator's aPNTs balance is debited (worst-case by `maxFeePerGas`, refunded in postOp) and the user's xPNTs are burned (or debt recorded — see §2).

> **AA34 (paymaster sigFailed)** usually means a gate failed: operator unconfigured/paused, user not eligible, rate-limited (`minTxInterval`), credit ceiling exceeded, or **operator balance below the worst-case lock**. Keep the operator funded above one op's worst case.

Example: `test-case-2-superpaymaster-xpnts1-fixed.js`.

## 2. Credit / debt path

If `IERC20(xPNTsToken).balanceOf(user) < charge`, postOp records debt instead of burning, up to `getCreditLimit(user)`. Check headroom with `getAvailableCredit(user, token)`; repay with `repayDebt`.

Example: `test-case-4-superpaymaster-credit-path.js` (it prints whether it took the burn or debt branch).

## 3. x402 settlement (facilitator)

**EIP-3009 (USDC native):** payer signs `TransferWithAuthorization` over a recipient-bound nonce = `keccak256(abi.encode(payee, salt))`; facilitator calls `settleX402Payment(from, to, asset, amount, validAfter, validBefore, salt, signature)`. Payee receives `amount − fee`; fee accrues to the facilitator (`facilitatorFeeBPS`, e.g. 100 = 1%).

**Direct (xPNTs, C-02):** payer signs an EIP-712 `X402PaymentAuthorization(from,to,asset,amount,maxFee,validBefore,nonce)` bound to this SuperPaymaster's domain; facilitator calls `settleX402PaymentDirect(...)`. The recipient is bound into the signature — redirecting it reverts `InvalidX402Signature` (drain protection). Replays revert `NonceAlreadyUsed`.

Examples: `test-x402-eip3009-settlement.js`, `test-x402-direct-settle.js`.

## 4. MicroPayment channel

```
openChannel(payee, token, deposit, salt, authorizedSigner)   // lock deposit, returns channelId (from event)
  → payer signs cumulative vouchers off-chain (EIP-712 Voucher{channelId, cumulativeAmount})
settleChannel(channelId, cumulativeAmount, signature)        // payee draws the cumulative amount
closeChannel(channelId, cumulativeAmount, signature)         // final settle to payee + refund remainder to payer
```

Example: `test-micropayment-channel.js`.

## 5. PaymasterV4 (independent, AOA)

Fund a user's gas budget: `approve(pmV4, amount)` then `pmV4.depositFor(user, token, amount)`. The token must be enabled via `setTokenPrice(token, usdPrice8dec)`; check `isTokenSupported(token)`. Gas is debited from the per-user `balances(user, token)` ledger (no burn).

Examples: `test-case-1-paymasterv4.js`, `test-group-P2-paymasterv4-lifecycle.js`.

## Quick reference: key selectors

| selector | function |
|---|---|
| `0xb6b55f25` | `deposit(uint256)` |
| `0x7344209c` | `settleX402PaymentDirect(address,address,address,uint256,uint256,uint256,bytes32,bytes)` |
| `0x6a16e22d` | `isEligibleForSponsorship(address)` |

Full index in [`selectors.md`](./selectors.md).
