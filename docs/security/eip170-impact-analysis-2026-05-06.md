# EIP-170 Compression Impact Analysis
**Date**: 2026-05-06  
**Branch**: security/audit-2026-04-25  
**Commit**: 290104a  
**Contract**: SuperPaymaster.sol  

---

## 1. Background

EIP-170 caps Ethereum runtime bytecode at **24,576 bytes**. `main` had SuperPaymaster at **26,166 bytes** (+1,590 over limit), blocking CI on PRs #110/#113/#114. The security audit branch compressed it to **24,541 bytes** (35 bytes under limit as of the restored try/catch in `getAgentSponsorshipRate`).

---

## 2. Changes Made and Their Impact

### 2.1 DRYRUN_* and other constants → `internal`

| Constant | Before | After | Bytes saved |
|----------|--------|-------|-------------|
| `DRYRUN_PAYMASTER_NOT_REGISTERED` | `public` | `internal` | ~50 |
| `DRYRUN_OPERATOR_PAUSED` | `public` | `internal` | ~50 |
| `DRYRUN_INSUFFICIENT_BALANCE` | `public` | `internal` | ~50 |
| `DRYRUN_INVALID_XPNTS_TOKEN` | `public` | `internal` | ~50 |
| `DRYRUN_XPNTS_BURN_FAILED` | `public` | `internal` | ~50 |
| `DRYRUN_SUCCESS` | `public` | `internal` | ~50 |
| `PRICE_CACHE_DURATION` | `public` | `internal` | ~50 |
| `MIN_ETH_USD_PRICE` | `public` | `internal` | ~50 |
| `MAX_ETH_USD_PRICE` | `public` | `internal` | ~50 |
| `PAYMASTER_DATA_OFFSET` | `public` | `internal` | ~50 |
| `RATE_OFFSET` | `public` | `internal` | ~50 |
| `BPS_DENOMINATOR` | `public` | `internal` | ~50 |
| `MAX_PROTOCOL_FEE` | `public` | `internal` | ~50 |
| `VALIDATION_BUFFER_BPS` | `public` | `internal` | ~50 |
| `CHAINLINK_STALE_THRESHOLD` | `public` | `internal` | ~50 |
| `EMERGENCY_PRICE_DEVIATION_BPS` | `public` | `internal` | ~50 |

**Estimated total savings: ~800 bytes**

**Impact**:  
- Off-chain callers (SDK, frontend, scripts) that read these constants via `contract.DRYRUN_PAYMASTER_NOT_REGISTERED()` or similar will get a revert — the ABI getter no longer exists.  
- The values are `constant` (compile-time literals), so any consuming contract that imports SuperPaymaster directly will still inline them correctly — only external ABI callers are affected.
- `DryRunValidation.t.sol` was updated: all `paymaster.DRYRUN_*()` calls replaced with hardcoded `bytes32(...)` values.

**Risk**: **MEDIUM** for integrators using these constants via ABI.  
**Mitigation**: Publish the constant values in the SDK / ABIs documentation. Any off-chain monitor or frontend checking dryrun reason codes must hardcode the values.

---

### 2.2 Remove dead `useRealtime` branch from `_calculateAPNTsAmount`

The function previously accepted `bool useRealtime` and had a branch that called `ETH_USD_PRICE_FEED.latestRoundData()` directly. This branch was **never called** in production — all callers passed `false` (cache-only).

**Estimated savings: ~400 bytes**

**Impact**:  
- Real-time Chainlink query path is now unreachable. Cache-only pricing is the sole code path.  
- This was already the intended behavior (see break-glass mechanism for emergency price updates).  
- If someone wanted real-time pricing, they would call `updatePrice()` first (which still exists).

**Risk**: **LOW** — the removed path was dead code.  
**Mitigation**: Document that pricing is always cache-based; keepers must call `updatePrice()` regularly.

---

### 2.3 Remove `oracleDecimals` storage variable

Chainlink USD price feeds always return 8 decimals. The `oracleDecimals` storage slot was initialized via `ETH_USD_PRICE_FEED.decimals()` in `initialize()` and consumed 1 storage slot (32 bytes on-chain, plus getter bytecode).

**Estimated savings: ~150 bytes**

**Impact**:  
- `oracleDecimals` is no longer readable via ABI (was previously a `public` storage var).
- All internal price calculations hardcode `8` — correct for Chainlink ETH/USD on all chains.
- UUPS upgrade: storage layout is NOT affected — the removed variable was in the implementation, not proxy storage.

**Risk**: **LOW** for current chains. **MEDIUM** if ever deploying to a chain with a Chainlink feed that uses different decimals (unlikely for ETH/USD).  
**Mitigation**: Add a sanity assertion in `updatePrice()` or `initialize()` to confirm `decimals() == 8`, reverting if not.

---

### 2.4 Remove unused `bytes memory` param from internal `_slash()`

The `_slash(address operator, address community, uint256 amount, bytes memory)` internal function accepted a `bytes memory data` param that was passed but never used.

**Estimated savings: ~80 bytes**

**Impact**: Pure internal refactor. No external ABI surface changed.  
**Risk**: **NONE**.

---

### 2.5 Drop try/catch in `configureOperator` factory check → direct call

Before:
```solidity
try IxPNTsFactory(xpntsFactory).getTokenAddress(msg.sender) returns (address validToken) {
    if (validToken != xPNTsToken) revert InvalidXPNTsToken();
} catch {
    revert FactoryVerificationFailed();
}
```
After:
```solidity
address validToken = IxPNTsFactory(xpntsFactory).getTokenAddress(msg.sender);
if (validToken != xPNTsToken) revert InvalidXPNTsToken();
```

**Estimated savings: ~34 bytes**

**Impact**:  
- If `xpntsFactory` is set to a malicious/broken contract, `configureOperator` will now bubble the raw revert from the factory instead of reverting with `FactoryVerificationFailed`.  
- The custom error `FactoryVerificationFailed` was removed from the ABI.  
- In practice, `xpntsFactory` is set by the owner during `initialize()` and should always be the trusted `xPNTsFactory` deployment.

**Risk**: **LOW** — factory address is owner-controlled. Error message changes but behavior is equivalent.  
**Mitigation**: Ensure `xpntsFactory` is validated at deploy time and not mutable without timelock.

---

### 2.6 Remove `xPNTsAmount` from `validatePaymasterUserOp` context encoding

Context encoding changed from 6-field to 5-field:

| Field | Before | After |
|-------|--------|-------|
| `token` | ✅ slot 0 | ✅ slot 0 |
| `xPNTsAmount` (estimated) | ✅ slot 1 | ❌ removed |
| `user` | ✅ slot 2 | ✅ slot 1 |
| `initialAPNTs` | ✅ slot 3 | ✅ slot 2 |
| `userOpHash` | ✅ slot 4 | ✅ slot 3 |
| `operator` | ✅ slot 5 | ✅ slot 4 |

**Estimated savings: ~39 bytes** (one fewer ABI word + decode logic)

**Impact**:  
- `postOp` no longer receives the estimated xPNTs amount (it was only used for logging/debugging; the actual burn is recalculated in postOp from `initialAPNTs`).  
- Any off-chain tool that decoded the `context` field from EntryPoint events or transaction calldata will get wrong offsets if using the old 6-field schema.  
- 4 test files required updating: `Coverage_Supplement.t.sol`, `SuperPaymasterHardenVerification.t.sol`, `SuperPaymasterV3.t.sol`, `SuperPaymaster_BurnRestore.t.sol`.

**Risk**: **MEDIUM** — breaking change for any SDK/indexer that decodes the context field from transaction data.  
**Mitigation**: Update ABI documentation and SDK context decoder. Context is an internal implementation detail (not emitted as an event), so impact is limited to deep integrations that trace calldata.

---

### 2.7 Remove `AgentSponsorshipApplied` event

The event `AgentSponsorshipApplied(operator, user, bps)` was declared but the `_applyAgentSponsorship` path that emitted it was not yet wired in V3 (V5.1 feature). Removed as dead code.

**Impact**: The event will not appear in ABI. If any frontend already subscribed to it (unlikely since it was never emitted), those subscriptions will silently receive no events.  
**Risk**: **NONE** for current deployment.

---

### 2.8 Restore try/catch in `getAgentSponsorshipRate` (post-compression fix)

After the initial EIP-170 compression was committed, Codex audit identified that `IAgentReputationRegistry.getSummary()` was called without try/catch — any revert in the external registry would propagate and revert the entire `getAgentSponsorshipRate` view call.

This was restored in commit `8e6d0cc`, adding 4 bytes (24,537 → 24,541). Still 35 bytes under limit.

**Risk if not fixed**: Operator frontend/SDK calls to `getAgentSponsorshipRate` would revert if the reputation registry is unresponsive, disrupting UX for agents even when no actual sponsorship decision is needed.

---

## 3. Cumulative Risk Summary

| Change | External ABI Impact | Integrator Action Required |
|--------|---------------------|---------------------------|
| Constants → internal | ❌ Getters removed | SDK: hardcode or document constant values |
| Remove useRealtime | None | None |
| Remove oracleDecimals | ❌ Getter removed | SDK: remove references to `oracleDecimals()` |
| Remove `bytes memory` from `_slash` | None (internal) | None |
| Drop try/catch in configureOperator | ⚠️ Error name changed | SDK: handle generic revert instead of FactoryVerificationFailed |
| Remove xPNTsAmount from context | ❌ Context schema change | SDK/indexer: update context decoder offset |
| Remove AgentSponsorshipApplied event | None (never emitted) | None |

**Overall risk**: LOW for launch (no deployed users yet). Would be HIGH for a live mainnet upgrade with existing integrators.

---

## 4. Size Budget Going Forward

Current state after all fixes:

| State | Bytes | Headroom |
|-------|-------|---------|
| EIP-170 limit | 24,576 | — |
| After EIP-170 commit | 24,537 | +39 |
| After try/catch restore | 24,541 | **+35** |

**35 bytes of headroom is extremely tight.** Any non-trivial feature addition will exceed the limit.

---

## 5. Future Countermeasures

### 5.1 Immediate (before next feature)

1. **Automated size gate in CI**: Add `forge build --sizes | awk '/SuperPaymaster/ && $2 > 24500 {exit 1}'` to the CI workflow so any PR that pushes the contract beyond a soft cap of 24,500 bytes fails before merging.

2. **Size budget tracking**: Maintain a `SIZE_BUDGET.md` that records each feature's bytecode cost before it lands, establishing a known cost model.

### 5.2 Short-term (next sprint)

3. **Extract Agent V5 features to a separate module contract**: `AgentSponsorshipModule.sol` — a separate contract that SuperPaymaster `delegatecall`s into via a registry pattern. This carves out ~2-3 KB of agent-related logic from the main contract.

4. **Library extraction**: Move the BPS arithmetic helpers, oracle math, and debt calculation into a `SuperPaymasterLib` library contract deployed once and `using` linked. Libraries with `pure`/`view` functions deployed as separate contracts reduce the main contract by the size of those functions.

5. **Use EIP-2535 Diamond proxy** (evaluate): Split SuperPaymaster into multiple facets (pricing, operator management, validation, postOp). Each facet is a separate contract below 24,576 bytes, and the diamond delegates to the appropriate facet. Major refactor — only worthwhile if V5+ adds >1 KB of new features.

### 5.3 Medium-term

6. **Via-IR optimization tuning**: The current `optimizer_runs = 10000` is optimized for gas at the cost of code size. Reducing to `200` can cut 5-15% of bytecode at the cost of ~3-8% higher gas per call. Consider a split: production deploy with `200` runs (for size), testnet with `10000` (for gas benchmarking).

7. **UUPS implementation split**: Keep the proxy storage layout but split the implementation into `SuperPaymasterCore` (validation + postOp) and `SuperPaymasterAdmin` (configuration + operator management). Use `fallback` delegation within the main contract. This requires careful storage layout coordination.

8. **Evaluate Solidity 0.8.34+**: Newer compiler versions often include codegen improvements that reduce output size. Monitor release notes.

### 5.4 Constant table for integrators

The following constants were made `internal` and are no longer ABI-readable. SDK and off-chain tools must use these hardcoded values:

| Constant | Value |
|----------|-------|
| `DRYRUN_PAYMASTER_NOT_REGISTERED` | `keccak256("DRYRUN_PAYMASTER_NOT_REGISTERED")[:32]` |
| `DRYRUN_OPERATOR_PAUSED` | `keccak256("DRYRUN_OPERATOR_PAUSED")[:32]` |
| `DRYRUN_INSUFFICIENT_BALANCE` | `keccak256("DRYRUN_INSUFFICIENT_BALANCE")[:32]` |
| `DRYRUN_INVALID_XPNTS_TOKEN` | `keccak256("DRYRUN_INVALID_XPNTS_TOKEN")[:32]` |
| `DRYRUN_XPNTS_BURN_FAILED` | `keccak256("DRYRUN_XPNTS_BURN_FAILED")[:32]` |
| `DRYRUN_SUCCESS` | `keccak256("DRYRUN_SUCCESS")[:32]` |
| `PRICE_CACHE_DURATION` | `300` (seconds) |
| `PAYMASTER_DATA_OFFSET` | `52` |
| `RATE_OFFSET` | `72` |
| `BPS_DENOMINATOR` | `10000` |
| `MAX_PROTOCOL_FEE` | `2000` (20%) |
| `VALIDATION_BUFFER_BPS` | `1000` (10%) |
| `CHAINLINK_STALE_THRESHOLD` | `3600` (1 hour) |
| `EMERGENCY_PRICE_DEVIATION_BPS` | `2000` (20%) |

> **Note**: The actual `bytes32` values for DRYRUN_* constants should be obtained by running `forge test --match-test test_DryRun -vvvv` and reading the logged values from `DryRunValidation.t.sol`.

---

## 6. Lessons Learned

1. **Public constants are expensive**: Each `public constant` generates a getter function (~50 bytes). For a contract with 16 public constants, that's ~800 bytes of pure getter overhead. Prefer `internal` for constants that are only needed for logic, not external consumption.

2. **try/catch has non-trivial size cost**: Each try/catch adds ~30-100 bytes. Use it only for genuinely fault-isolated external calls. Internal calls and trusted external calls (same deployer) can use direct calls.

3. **Context ABI encoding affects only depth-1 callers**: The EntryPoint calls `postOp` with the raw `context` bytes — no one in the ERC-4337 standard decodes it except the paymaster itself. Context format changes are safe from a protocol perspective but break any tooling that traces calldata.

4. **Size monitoring must be part of CI, not a post-hoc check**: The EIP-170 overflow was not caught until PRs were blocked. Automating this check prevents future surprises.
