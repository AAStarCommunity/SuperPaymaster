# Operations runbook — pending debt retry (H-01)

## What `pendingDebts` is

`SuperPaymaster.pendingDebts[token][user]` is a last-resort accumulator. During
`postOp`, `_recordDebt` tries, in order: `burnFromWithOpHash` (pull from the user's
xPNTs balance) → `recordDebtWithOpHash` (book the debt) → and only if BOTH revert does
the amount land in `pendingDebts`. In normal operation this is always 0. It is non-zero
only in exceptional cases (a single op whose aPNTs cost exceeds the token's
`maxSingleTxLimit`, an emergency-disabled token, or a temporarily unreachable token).

## The H-01 issue (fixed)

`recordDebt` reverts when `amount > maxSingleTxLimit` (5000 aPNTs). The old
`retryPendingDebt(token, user)` always retried the **full** pending balance, so once the
accumulator exceeded that limit the retry reverted forever — the debt could only be
written off via `clearPendingDebt` (the protocol eats it).

## The fix — chunked retry

```solidity
function retryPendingDebt(address token, address user, uint256 amount) external onlyOwner
```

`amount` is recorded this call and clamped to the pending balance; the remainder stays
in `pendingDebts`. So a balance larger than `maxSingleTxLimit` is drained over multiple
calls instead of writing it off.

## Management-backend / operational rule

To drain a stuck pending debt:

1. Read `pendingDebts(token, user)` and the token's `maxSingleTxLimit()` (5000 aPNTs default).
2. If `pending <= maxSingleTxLimit`: call `retryPendingDebt(token, user, 0)` once (0 = full balance).
3. If `pending > maxSingleTxLimit`: call `retryPendingDebt(token, user, maxSingleTxLimit)`
   **repeatedly** until `pendingDebts(token, user) == 0`. Each call books one chunk as
   real user debt.
4. Only use `clearPendingDebt(token, user)` (write-off, protocol absorbs the loss) when
   the debt is genuinely unrecoverable (token permanently unreachable / user gone).

**Backend implementation note:** the retry loop must be idempotent and re-read
`pendingDebts` after each tx (the value shrinks per call). Prefer recovering the debt
(step 3) over writing it off (step 4); reserve write-off for unrecoverable cases and log it.
