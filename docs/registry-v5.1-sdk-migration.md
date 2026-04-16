# Registry v5.1 / Staking v4.2 — SDK Migration Notes

Breaking ABI changes introduced alongside the ticket-model refactor and
Registry-size reduction. No users are on production yet, so shims were not added.

## Registry

### Removed

- `struct Registry.PaymasterRoleData` — was never decoded inside the contract.
  SDKs must pass the stake amount directly.

  **Before:**
  ```solidity
  bytes memory data = abi.encode(Registry.PaymasterRoleData({
      paymasterContract: pmProxy,
      name: "Jason V4 PM",
      apiEndpoint: "https://rpc.aastar.io/pm",
      stakeAmount: 30 ether
  }));
  registry.registerRole(ROLE_PAYMASTER_AOA, user, data);
  ```

  **After:**
  ```solidity
  registry.registerRole(ROLE_PAYMASTER_AOA, user, abi.encode(uint256(30 ether)));
  ```

  Applies to: `ROLE_PAYMASTER_AOA`, `ROLE_PAYMASTER_SUPER`, `ROLE_DVT`,
  `ROLE_ANODE`, `ROLE_KMS`. Metadata (name, API endpoint, paymaster contract)
  is tracked in PaymasterFactory / per-paymaster state instead.

- `struct RoleConfig.isOperatorRole` — eliminated. Behaviour now derives from
  `minStake` (zero = ticket-only, non-zero = operator).
- `mapping proposedRoleNames`, `roleOwners`, `roleLockDurations` — unused
  deprecated getters removed.
- `mapping executedProposals` and `error ProposalExecuted()` — replay
  protection now lives in `BLSAggregator` only.
- `error NoExitForTicketOnlyRoles()` — replaced by
  `error NoStakeToExit()` (raised via `roleStakes[roleId][user] == 0`).

### Added / Changed

- `RoleConfig.ticketPrice` replaces `entryBurn`. Tokens are transferred to
  treasury instead of burned, preserving the 21M GT cap.
- COMMUNITY / ENDUSER exit fees are now 0 (they have no stake to withdraw).

## GTokenStaking (v4.2.0)

### Removed

- `function lockStake(address,bytes32,uint256,uint256,address)` — deprecated
  entry that burned tokens. All registrations now go through
  `lockStakeWithTicket`.
- `event TokensBurned` — only emitted by the deleted `lockStake`.

### Kept / Unified

- `function lockStakeWithTicket(user, roleId, stakeAmount, ticketPrice, payer)`
  is the single registration entrypoint. `stakeAmount == 0` routes the ticket
  straight to treasury and skips lock creation; `stakeAmount > 0` creates a
  `RoleLock` as before.
- `event StakeLocked(user, roleId, amount, ticketPrice, timestamp)` — field
  `entryBurn` renamed to `ticketPrice`.
- `event TicketBurned(user, roleId, ticketPrice, payer)` — emitted whenever a
  ticket is paid, including the ticket-only path.
- `struct RoleLock.ticketPrice` replaces `RoleLock.entryBurn`.
- `version()` returns `"Staking-4.2.0"`.

## BLSAggregator

### Interface rename

- `IBLSAggregator.threshold()` → `IBLSAggregator.minThreshold()`. The concrete
  contract exposes both `minThreshold` (safety floor) and `defaultThreshold`
  via public state getters. The interface now declares both.
  Registry's `batchUpdateGlobalReputation` queries `defaultThreshold()` for
  stronger consensus on reputation updates (was previously `minThreshold()`).

### Replay / input hardening

- `verifyAndExecute` and `executeProposal` now reject `proposalId == 0`
  (previously used as a sentinel that bypassed `executedProposals`). Callers
  must supply a non-zero proposal identifier. **Breaking change:** any
  off-chain signer that previously relied on `proposalId = 0` for one-shot
  calls must now generate unique non-zero IDs.
- `setMinThreshold` enforces `minThreshold <= defaultThreshold`.
- `Registry.batchUpdateGlobalReputation` now rejects `proposalId == 0` as
  well (via `InvalidProposalId`).

## MySBT

- `struct CommunityMembership.lastActiveTime` removed. Activity timestamps are
  tracked in the `lastActivityTime` mapping (per tokenId/community).
- `mapping weeklyActivity` removed (unused since v3.1). Query
  `ActivityRecorded` events via The Graph for historical activity.

## Deploy script updates

- `DeployLive.s.sol` / `DeployAnvil.s.sol`: **must** call
  `registry.syncExitFees([ROLE_PAYMASTER_AOA, ROLE_PAYMASTER_SUPER, ROLE_DVT,
  ROLE_ANODE, ROLE_KMS])` after `setStaking`. Without this call, operator
  role exit fees in GTokenStaking stay at zero — `previewExitFee`/
  `unlockAndTransfer` will not apply the configured fee. New deploys inherit
  this step; existing ops scripts must be updated.
- `07b_DeployBLSModules.s.sol`: uses `aggregator.setMinThreshold(3)` (old
  `setThreshold` never existed on BLSAggregator).
- Legacy scripts referencing the removed APIs moved to `deprecated/scripts/`.

## registerRole authorization (breaking)

- `Registry.registerRole(roleId, user, data)` now requires
  `msg.sender == user`. Previously any address could call on behalf of
  `user` as long as `user` had a matching GToken allowance, allowing
  grief-attacks that drained a victim's allowance to bind them to an
  unwanted community. If sponsored registration is needed later, a new
  `registerRoleFor(user, sig)` entry with EIP-712 authorization will be
  added separately.
- **Community-sponsored registration still works** via
  `Registry.safeMintForRole(roleId, user, data)`. That function is gated by
  `hasRole[ROLE_COMMUNITY][msg.sender]` and remains the intended path for
  community airdrops / user onboarding.
- `accountToUser[data.account]` is **no longer written** by `registerRole`
  or `safeMintForRole`. The mapping is now populated **only** by the account
  itself calling `Registry.bindAccount(user)` after the ENDUSER role has
  been granted. This closes the hijack vector where a rogue ROLE_COMMUNITY
  holder could first-claim `accountToUser[X] = fakeUser` via
  `safeMintForRole`. The full rationale and the options considered are
  documented in `docs/design/accountToUser-binding-auth.md`.
- `data.account` is retained on `EndUserRoleData` for SDK backward-compat
  but has no on-chain effect. The `data.account == address(0)` guard was
  removed along with the write.
- **SDK migration — two-step onboarding**:
  1. Community calls `safeMintForRole(ROLE_ENDUSER, user, data)` to mint
     the SBT (unchanged).
  2. The user's smart account (or EOA) calls `registry.bindAccount(user)`
     itself. This is the authoritative binding; because `msg.sender` on this
     call IS the account, no signature is needed and no rogue community
     can hijack the mapping.
  Paymasters / AA flows must continue to key off `accountToUser[msg.sender]`
  — unbound accounts are simply unrecognized and must go through
  `bindAccount` once.
- `bindAccount` is idempotent on the same user and reverts on attempts to
  rebind to a different user (`InvalidParam`) or when `user` does not hold
  ROLE_ENDUSER (`RoleNotGranted`).

## Proxy upgrade note (⚠️ storage layout break)

Registry v5.1 **removes** four storage mappings:
`proposedRoleNames`, `roleOwners`, `roleLockDurations`, `executedProposals`.
This shifts the storage slot index of every subsequent mapping
(`globalReputation`, `lastReputationEpoch`, `creditTierConfig`,
`isReputationSource`, `levelThresholds`). Existing proxies **cannot be
upgraded** — they must be redeployed.

Since no production users exist yet, we accept the redeploy cost in exchange
for a clean storage layout and the EIP-170 bytecode margin recovered by the
deletion.

## Outstanding follow-ups

- F5 (BLSAggregator signer-mask validation against the registered validator
  set) tracked separately — requires EIP-2537 precompile work, shipping in a
  subsequent PR.
- F2 (`verifyAndExecute` message-hash mismatch with Registry’s secondary BLS
  verify) kept as-is for now; revisit when the Registry verify path is
  redesigned.
