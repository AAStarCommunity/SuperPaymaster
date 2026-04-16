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
  via public state getters. Registry queries `minThreshold()` for validator
  quorum checks.

### Replay / input hardening

- `verifyAndExecute` and `executeProposal` now reject `proposalId == 0`
  (previously used as a sentinel that bypassed `executedProposals`). Callers
  must supply a non-zero proposal identifier.
- `setMinThreshold` enforces `minThreshold <= defaultThreshold`.

## MySBT

- `struct CommunityMembership.lastActiveTime` removed. Activity timestamps are
  tracked in the `lastActivityTime` mapping (per tokenId/community).
- `mapping weeklyActivity` removed (unused since v3.1). Query
  `ActivityRecorded` events via The Graph for historical activity.

## Deploy script updates

- `DeployLive.s.sol` / `DeployAnvil.s.sol`: call `registry.syncExitFees([...])`
  after `setStaking` to propagate operator-role exit fees into GTokenStaking.
- `07b_DeployBLSModules.s.sol`: uses `aggregator.setMinThreshold(3)` (old
  `setThreshold` never existed on BLSAggregator).
- Legacy scripts referencing the removed APIs moved to `deprecated/scripts/`.

## Outstanding follow-ups

- F5 (BLSAggregator signer-mask validation against the registered validator
  set) tracked separately — requires EIP-2537 precompile work, shipping in a
  subsequent PR.
- F2 (`verifyAndExecute` message-hash mismatch with Registry’s secondary BLS
  verify) kept as-is for now; revisit when the Registry verify path is
  redesigned.
