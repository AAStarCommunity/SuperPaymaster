# accountToUser Binding Authorization — Design Doc

Status: **Accepted (Option C) — 2026-04-16**
Driver: follow-up to Codex review on PR #84 (feat/ticket-model).

---

## 1. Problem Origin

### 1.1 Background

PR #84 tightened `Registry.registerRole` so that only the `user` themselves
(i.e. `msg.sender == user`) can self-register. This closes a griefing attack
where a third party could consume a victim's GToken allowance to bind them to
an unwanted role/community.

However, the community-sponsored airdrop path remains:
`Registry.safeMintForRole(roleId, user, data)` — gated only by
`hasRole[ROLE_COMMUNITY][msg.sender]`.

### 1.2 The Vulnerability Codex Flagged

`safeMintForRole(ROLE_ENDUSER, fakeUser, EndUserRoleData{account: victimSmartAccount, ...})`
lets any `ROLE_COMMUNITY` holder **first-claim** the binding

```
accountToUser[victimSmartAccount] = fakeUser
```

without proving that `fakeUser` controls `victimSmartAccount`. Subsequent
legitimate registrations by the real owner would be blocked by the
`existingOwner != user` collision check we added.

Today `accountToUser` is not consumed by any on-chain authorization flow, so
the damage is limited to "mapping pollution + SBT metadata". But the moment
any paymaster, bundler, or AA flow treats `accountToUser` as authoritative
("this smart account belongs to this user"), the hijacking becomes a real
security boundary violation.

### 1.3 Quote from Codex

> I'd treat the follow-up EIP-712 account-signed binding as **required
> before** using `accountToUser` for anything security-relevant.

This doc proposes the "before" fix so that `accountToUser` can be made
authoritative from day one.

---

## 2. Options Considered

### Option A — SDK / application-layer signature verification only

SDKs verify a user-provided signature before calling `safeMintForRole`.
Contract interface unchanged.

- **Security**: zero on-chain guarantee. Ethereum is permissionless — any
  rogue community can bypass the SDK with a one-liner `cast send`.
- **Effect**: cosmetic; equivalent to current state plus documentation.
- **Verdict**: **rejected**. Off-chain verification cannot protect on-chain
  state that other contracts / actors will eventually rely on.

### Option B — On-chain EIP-712 signature verification

Add `bytes calldata accountSig` to `safeMintForRole` (or a new entrypoint).
Implement EIP-712 domain separator, typed struct hash, `ECDSA.recover`, and a
nonce mapping for replay protection.

- **Security**: strong. No one can bind an account they don't control.
- **Cost**:
  - ~500–1,000 bytes bytecode (domain separator + typed-hash + recover +
    per-account nonce mapping).
  - Registry current EIP-170 margin is 1,398 bytes — it fits, but eats over
    half the budget.
  - Smart contract wallets (ERC-1271) would need an extra code path for
    signature verification via `isValidSignature`, further increasing cost.
- **Verdict**: usable but heavy. Good fit if we need off-chain signed
  authorization (e.g. meta-transactions). Overkill for a problem that can
  be solved by simple authentication.

### Option C — Separation of Concerns: account self-binding (chosen)

Split `safeMintForRole(ENDUSER)` into two independent responsibilities:

1. **Badge issuance** — community mints the ENDUSER SBT and registers the
   role. Does **not** touch `accountToUser`. (stays in `safeMintForRole`)
2. **Account binding** — a new function `bindAccount(address user)` where
   `msg.sender` is the account itself, asserting "I am controlled by
   `user`". This writes `accountToUser[msg.sender] = user`.

- **Security**: strong. `msg.sender == account` natively proves account
  control (EOA: EOA signs the tx; smart account: AA userOp routed through
  the account's own signature validation).
- **Cost**: ~40 lines Solidity, negligible bytecode.
- **UX**: two-step flow
  1. Community → `safeMintForRole(ENDUSER, user, data)` (airdrop SBT)
  2. User's account (EOA or smart account via AA) → `bindAccount(user)`
     (establish authority)
- **AA-native**: matches the natural lifecycle of an AA smart account —
  create account → account makes its first authenticated transaction.
- **Verdict**: **accepted**. Minimum code change, maximum clarity, no
  EIP-712 plumbing.

---

## 3. Why Option C Over B

Both B and C achieve the same security goal. C wins because:

1. **No new crypto primitives on-chain** — ECDSA is already in the
   runtime via other paths, but Option C doesn't need it at all for the
   binding path. Option B introduces an EIP-712 domain, struct hash, and
   nonce mapping just to work around the fact that `safeMintForRole` and
   account-binding are conceptually different actions.
2. **ERC-1271 complexity is avoided** — smart account wallets can't sign
   ECDSA directly. Option B would need to branch on EOA vs. contract
   callers. Option C sidesteps this: if the account can call, it's
   authenticated by definition.
3. **Better conceptual model** — community issuing an SBT ("you're a
   member") is legitimately community's prerogative. Claiming that a
   smart account belongs to a user is legitimately the account's
   prerogative. Separating them maps better to reality.
4. **Bytecode budget** — we have 1,398 bytes spare in Registry after PR
   #84. Option B would take ~1,000 of them. Option C takes ~200.
5. **Future-proof** — if we ever want meta-transactions (sponsor pays gas
   for the binding), we can add EIP-712 on top of Option C without
   restructuring.

---

## 4. Implementation (Option C)

### 4.1 Changes to `Registry._validateAndProcessRole`

```solidity
} else if (roleId == ROLE_ENDUSER) {
    EndUserRoleData memory data = abi.decode(roleData, (EndUserRoleData));
    if (!hasRole[ROLE_COMMUNITY][data.community]) revert InvalidParam();
    stakeAmount = data.stakeAmount;
    sbtData = abi.encode(data.community, "");
    // Note: accountToUser binding is intentionally NOT written here.
    // Smart account / EOA must call bindAccount() themselves to establish
    // authoritative "this account belongs to this user" mapping. This
    // prevents a rogue community from hijacking arbitrary smart-account
    // bindings via safeMintForRole.
}
```

The `data.account` field is retained in the `EndUserRoleData` struct for
backward compatibility with existing SDK call-sites, but is ignored
on-chain. SDKs should migrate to omit it (and we'll remove the field in a
future ABI-break sweep).

### 4.2 New function + event

```solidity
event AccountBound(address indexed account, address indexed user);

function bindAccount(address user) external {
    if (user == address(0)) revert InvalidParam();
    if (!hasRole[ROLE_ENDUSER][user]) revert RoleNotGranted(ROLE_ENDUSER, user);
    address existing = accountToUser[msg.sender];
    if (existing != address(0) && existing != user) revert InvalidParam();
    accountToUser[msg.sender] = user;
    emit AccountBound(msg.sender, user);
}
```

Design points:
- **`msg.sender` is the account** — no separate address parameter. This
  makes the authentication implicit and unforgeable.
- **Idempotent on same user** — calling again with the same `user` is a
  no-op (doesn't revert). Simplifies client flows that retry.
- **Blocks overwrite to different user** — once bound, must be unbound by
  `unbindAccount` (future work if needed) before rebinding.
- **Requires user has ROLE_ENDUSER** — prevents binding to a user who
  hasn't completed onboarding.
- **No nonce / no signature** — `msg.sender == account` is the
  authentication.

### 4.3 SDK migration

**Before (PR #84):**
```typescript
// Community airdrop — binds accountToUser atomically
await registry.safeMintForRole(
  ROLE_ENDUSER,
  userAddr,
  encode(EndUserRoleData({account: smartAccountAddr, community, ...}))
);
```

**After (this PR):**
```typescript
// Step 1: Community airdrops SBT (no account binding)
await registryAsCommunity.safeMintForRole(
  ROLE_ENDUSER,
  userAddr,
  encode(EndUserRoleData({account: ignored, community, ...}))
);

// Step 2: Smart account proves ownership (run via AA userOp)
await smartAccountClient.sendTransaction({
  to: registry.address,
  data: registry.interface.encodeFunctionData("bindAccount", [userAddr]),
});
```

The `account` field in `EndUserRoleData` is now advisory only — SDKs may
pass `address(0)` or the expected account; either way it is not stored.

---

## 5. Tests

- `bindAccount` happy path (EOA msg.sender self-binds)
- `bindAccount` reverts when target user lacks `ROLE_ENDUSER`
- `bindAccount` reverts on `user == address(0)`
- `bindAccount` is idempotent (same user, same account, second call is a no-op)
- `bindAccount` reverts when attempting to overwrite to a different user
- `safeMintForRole(ROLE_ENDUSER, ...)` by a rogue community no longer
  writes `accountToUser` (hijack-prevention regression test)
- `registerRole(ROLE_ENDUSER, ...)` by the user themselves no longer
  writes `accountToUser` (now purely a role/SBT action)
- AA smart account flow: `msg.sender` is the smart account → writes
  `accountToUser[smartAccount] = user` ✅

---

## 6. Follow-ups (Out of Scope for This PR)

- **Unbind flow**: add `unbindAccount()` callable by the bound account if
  the user loses control of the account or migrates. Tentatively low
  priority — account migration is rare and can be handled by deploying a
  fresh account + binding.
- **Meta-transaction layer**: if paying gas on behalf of users becomes a
  requirement, layer EIP-712 on top of `bindAccount` in a separate PR.
  Option C is forward-compatible with this.
- **Revisit `EndUserRoleData.account` field**: after SDKs migrate, drop
  the field from the struct in a dedicated ABI-break PR.
