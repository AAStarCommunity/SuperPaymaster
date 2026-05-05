# Wave 1 — Consensus & Identity (P0 fixes)

**Branch**: `fix/p0-wave1-consensus`
**Base**: `main` (f23bd43)
**Target PR**: separate from Wave 2 / Wave 3
**Spec**: `docs/security/2026-04-26-p0-prelaunch.md` (audit branch) §3

## Scope

5 P0 items affecting BLS / DVT / consensus layer:

| # | ID | File | Status |
|---|---|---|---|
| P0-1 | B6-C1a | `BLSAggregator.sol`, `BLSValidator.sol` (delete) | TODO |
| P0-2 | B6-C1b | `DVTValidator.sol::addValidator` + deploy config | TODO |
| P0-3 | B6-C2 | `Registry.sol::updateOperatorBlacklist` | TODO |
| P0-4 | B6-H1 | `DVTValidator.sol::executeWithProof` | TODO |
| P0-17 | Codex B-N5 | `DVTValidator.sol::markProposalExecuted/executeWithProof` | DOING |

## Design (locked per 2026-04-28 user decisions)

### P0-1: BLS aggregate signature verification
- Use solady `BLS12_381` standard helpers; do NOT hand-roll
- `BLSAggregator.verify(message, signerMask, sig)` reconstructs `pkAgg` from on-chain `blsPublicKeys[validator]` for each set bit in `signerMask`
- Drop the user-supplied `pkAgg` parameter entirely
- DELETE `BLSValidator.sol` (unused after refactor)
- Add invariant test: ∀ proof.signerMask, popcount(mask) ≥ threshold ⇒ pkAgg derived from on-chain PKs

### P0-2: Validator stake gate
- `DVTValidator.addValidator(address, blsPK)` reads minStake dynamically from `staking.getRoleConfig(ROLE_DVT)`
- Require: `registry.hasRole(addr, ROLE_DVT)` AND `staking.roleLocks(addr, ROLE_DVT).amount >= roleConfig.minStake`
- NO hardcoded minStake number — config-driven
- Deploy-time: `Registry.configureRole(ROLE_DVT, ..., minStake: 200 ether, ...)` (10x current 20 ether default)

### P0-3: updateOperatorBlacklist hardening
- Caller restricted: `msg.sender == blsAggregator` (NOT `isReputationSource`)
- Always require proof: `require(proof.length > 0)`
- Decode proof as `(uint256 signerMask, bytes sig)`
- Message hash includes `chainid + proposalId + nonce`:
  ```solidity
  bytes32 message = keccak256(abi.encode(
      block.chainid,
      proposalId,
      blacklistNonce++,
      operator, users, statuses
  ));
  ```
- Use P0-1 fixed `blsAggregator.verify(message, signerMask, sig)`
- Add monotonic `blacklistNonce` storage var

### P0-4: executeWithProof access control
- Add modifier `onlyAuthorizedExecutor`: `msg.sender == BLS_AGGREGATOR || isValidator[msg.sender]`
- Apply to `DVTValidator.executeWithProof`

### P0-17: Pre-poison defense (depth)
- In `markProposalExecuted`: add `require(p.operator != address(0), "no proposal")`
- In `executeWithProof`: add same check before any state read
- In `createProposal`: explicit `p.executed = false` (defensive — current behavior gives this for auto-increment ids but documents intent)
- Combined with P0-1 + P0-4 fixes, defense-in-depth: even if BLSAggregator is compromised, can't mark non-existent proposals

## Execution order

1. **P0-17** (smallest, lowest risk) — DOING FIRST
2. **P0-4** (one modifier addition)
3. **P0-2** (`addValidator` stake check)
4. **P0-3** (Registry blacklist refactor — depends on P0-1 verify signature)
5. **P0-1** (largest, BLS rewrite + library integration)

## Tests required

Per `docs/security/2026-04-25-review.md` §5.4.1:

- [ ] `test_BLS_RejectsForgedPK`
- [ ] `test_AddValidator_RevertsIfNotDVTRole`
- [ ] `test_AddValidator_RevertsIfStakeBelowMinStake`
- [ ] `test_UpdateBlacklist_RevertsOnEmptyProof`
- [ ] `test_UpdateBlacklist_RevertsCrossChainReplay`
- [ ] `test_ExecuteWithProof_RevertsForAnonymousCaller`
- [ ] `test_MarkProposalExecuted_RevertsForNonExistentId`

Plus invariants in `contracts/test/v3/invariants/`:
- [ ] `INV_BLS_PkAggDerivedFromOnChain` (Echidna)

## PR description template

> Wave 1 of P0 pre-launch fixes (5 items, BLS/DVT/consensus layer).
> Spec: docs/security/2026-04-26-p0-prelaunch.md (security/audit-2026-04-25)
> Decisions: docs/security/2026-04-26-decision-records.md (D1-D8, V4 launch confirmed)
> Threat model: docs/security/2026-04-26-threat-model.md (T-01..T-04, T-09)

## Status log

- 2026-04-28: branch created from main; plan documented; starting with P0-17
