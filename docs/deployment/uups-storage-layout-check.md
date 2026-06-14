# UUPS Storage-Layout Pre-Upgrade Check (Audit M-4)

**When:** before EVERY UUPS upgrade of `Registry` or `SuperPaymaster` (the two
ERC1967 proxies). A storage-layout mismatch between the old and new
implementation silently corrupts proxy state — there is no on-chain guard, so
this check is the gate.

## Why

`Registry` and `SuperPaymaster` are UUPS proxies: the proxy holds storage, the
implementation holds code. An upgrade swaps the code but keeps the storage. If
the new implementation reorders, retypes, inserts, or removes a state variable
above the `__gap`, every slot after the change is misread. `forge` cannot catch
this for you across two separately-compiled versions — you must diff the
layouts.

Invariants that MUST hold across an upgrade:
- Existing variables keep the **same slot and offset** (append-only changes only).
- New variables are appended **before** the `__gap`, and `__gap` shrinks by the
  exact number of slots consumed.
- `immutable`/`constant` values live in code, not storage — they may change
  freely (e.g. `entryPoint`, `REGISTRY`, `ETH_USD_PRICE_FEED`).
- ERC-7201 namespaced storage (OZ `Initializable`, ReentrancyGuard transient)
  does not collide with the linear layout — verify it stayed namespaced.

## How

```bash
# 1. Dump the CURRENTLY-DEPLOYED implementation's layout (checkout its tag/commit first)
git checkout <deployed-tag>
forge inspect SuperPaymaster storage-layout > /tmp/sp-old.json
forge inspect Registry         storage-layout > /tmp/reg-old.json

# 2. Dump the NEW implementation's layout (the upgrade candidate)
git checkout <upgrade-branch>
forge inspect SuperPaymaster storage-layout > /tmp/sp-new.json
forge inspect Registry         storage-layout > /tmp/reg-new.json

# 3. Diff. The `storage` array entries (label, slot, offset, type) for every
#    PRE-EXISTING variable must be IDENTICAL. Only appended entries (before gap)
#    and a correspondingly-shrunk __gap are allowed.
diff <(jq '.storage' /tmp/sp-old.json)  <(jq '.storage' /tmp/sp-new.json)
diff <(jq '.storage' /tmp/reg-old.json) <(jq '.storage' /tmp/reg-new.json)
```

Any diff on an existing variable's `slot`/`offset`/`type` = **STOP, do not
upgrade**. A diff that only appends new variables + shrinks `__gap` by the matching
count = OK.

## Pre-upgrade checklist

- [ ] `forge inspect` layout diff for `SuperPaymaster` shows append-only changes
- [ ] `forge inspect` layout diff for `Registry` shows append-only changes
- [ ] `__gap` shrank by exactly the number of new slots in each contract
- [ ] No existing variable changed slot/offset/type
- [ ] `immutable`/`constant` changes reviewed (code-only, safe)
- [ ] `version()` string bumped so the new impl is identifiable on-chain
- [ ] EIP-170: `forge build --sizes` shows both proxies' impls under 24,576 B

> Note: `SuperPaymaster` runtime size is currently ~126 B under the EIP-170
> limit. Any upgrade that adds code must reclaim bytes first (see the
> behavior-preserving extraction pattern used in PRs #274/#276), or it will not
> deploy.
