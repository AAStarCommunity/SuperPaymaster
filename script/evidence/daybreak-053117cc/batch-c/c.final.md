Audited commit `053117cc8ca31eb69ae1f62755a1d7790e71190f` read-only. No files were modified, no network/RPC was used, and no build was necessary. The checked-out source reports `SuperPaymaster-5.5.2`; reachability below uses the supplied 5.5.0 deployment assumptions.

## New / newly confirmed findings

### M-02 — Medium — Exited or under-staked operators remain authorized until an external watcher pauses them

- **Location:** [SuperPaymaster.sol:272](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:272), [SuperPaymasterAdmin.sol:117](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:117), [Registry.sol:373](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:373)
- **Precondition and sequence:**
  1. A valid COMMUNITY/PAYMASTER_SUPER operator calls `configureOperator`, setting `isConfigured=true`.
  2. After its role lock expires, it calls `Registry.exitRole(ROLE_PAYMASTER_SUPER)`.
  3. Registry removes the role and releases the stake, but does not clear or pause the SuperPaymaster configuration.
  4. Before a third party calls `pauseUnderstakedOperator`, UserOperations selecting that operator reach validation.
  5. Validation checks only `isConfigured` and `isPaused`; it does not verify the current role or effective stake, so sponsorship continues.
- **Impact:** The operator can continue using a privileged, ostensibly stake-backed service after recovering its admission stake. This creates an unbounded watcher race and breaks the role/stake accountability invariant. An already submitted bundle can also land before the permissionless pause.
- **5.5.0 reachability:** **Yes.** It is especially straightforward because an operator normally retains its COMMUNITY role, so exiting PAYMASTER_SUPER does not trigger final-role cleanup. The supplied “no slashing enabled” configuration removes an additional accountability mechanism.
- **Minimal fix:** Add a Registry-only revocation hook that atomically sets `isPaused=true` or `isConfigured=false` when PAYMASTER_SUPER is removed, before stake release. Avoid a live Registry call in validation; a pushed local authorization bit preserves the existing ERC-7562 validation surface.
- **Classification note:** This confirms the previously unverified note in `docs/security/2026-05-31-pk-audit-findings.md`; it was not listed among the accepted rc8 residuals.

### L-01 — Low — Chainlink cache accepts future-dated rounds

- **Location:** [SuperPaymasterAdmin.sol:521](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:521), particularly lines 526–529.
- **Precondition and sequence:**
  1. The configured feed returns an in-range price, valid round relation, and `updatedAt > block.timestamp`.
  2. Anyone calls `updatePrice()`.
  3. The stale check accepts the future timestamp and caches it.
  4. Validation computes `validUntil = updatedAt + priceStalenessThreshold`, extending the price’s apparent lifetime into the future.
- **Impact:** A faulty or compromised feed report can keep a stale or incorrect price usable beyond the intended staleness window, mispricing reservations and final charges. It can also cause underflow in the fresh-Chainlink comparison inside `updatePriceDVT`, obstructing that fallback route.
- **5.5.0 reachability:** **Conditional, not under normal Chainlink behavior.** The configured feed must return a future timestamp.
- **Minimal fix:** Reject `updatedAt == 0` and `updatedAt > block.timestamp + TIMESTAMP_GRACE_SECONDS` before caching. Apply the same guarded comparison before subtracting `chainlinkUpdatedAt` in `updatePriceDVT`.

### I-01 — Info — Oracle decimal compatibility is assumed rather than enforced

- **Location:** [SuperPaymasterAdmin.sol:529](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:529)
- **Precondition and sequence:** Deploy an implementation with a feed whose `decimals()` is not eight; call `updatePrice`; the cache nevertheless records `decimals: 8`; validation and settlement then scale the price as eight-decimal data.
- **Impact:** Mispricing by a power-of-ten factor on an incorrectly configured network or feed replacement.
- **5.5.0 reachability:** **No for the intended eight-decimal ETH/USD feed; configuration hazard only.**
- **Minimal fix:** Require `ETH_USD_PRICE_FEED.decimals() == 8` at construction/deployment, or cache the actual decimals and explicitly bound them.

## Confirmations of known/disclosed items

### K-01 — Low — Same-bundle rate-limit bypass remains

- **Location:** [SuperPaymaster.sol:315](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:315), [SuperPaymaster.sol:454](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:454)
- **Precondition and sequence:** A bundler includes two operations for the same `(operator, sender)` in one bundle. Both validations read the old `lastTimestamp`; neither updates it. Both pass, then their respective `postOp` calls write the timestamp.
- **Impact:** Bypasses `minTxInterval` within one bundle. Each operation still independently reserves and pays, limiting the effect.
- **5.5.0 reachability:** **Yes.**
- **Minimal fix:** The documented sender-associated transient same-bundle marker, after validation against the supported production bundler tracers.

### K-02 — Info — ERC-7562 compliance remains conditional on the configured identity registry

- **Location:** [SuperPaymaster.sol:524](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:524)
- **Precondition and sequence:** Configure a nonzero identity registry that executes TIMESTAMP/NUMBER or reads forbidden storage; validate a sender without cached SBT eligibility; validation calls that registry.
- **Impact:** Bundlers reject affected UserOperations even though `try/catch` converts Solidity reverts to `false`; opcode and storage-rule violations cannot be caught.
- **5.5.0 reachability:** **The call path is reachable** because the checked-in Sepolia configuration names a nonzero registry. An actual violation depends on that exact implementation; it was not inspected through network/RPC.
- **Minimal fix:** Keep the path disabled until the exact runtime hash and complete opcode/storage trace are pinned, as already required by the disclosure document.

### K-03 — Low — Stale-Chainlink BLS price updates permit cumulative drift

- **Location:** [SuperPaymasterAdmin.sol:465](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:465)
- **Precondition and sequence:** Chainlink is stale; an authorized aggregator/quorum repeatedly invokes `updatePriceDVT` with strictly increasing timestamps and each price within ±20% of the preceding cached price.
- **Impact:** Multiple accepted updates can compound toward the absolute price bounds, changing user charges and operator reservations substantially.
- **5.5.0 reachability:** **Yes for the authorized BLS price path.** The supplied absence of slasher authority does not disable price updates.
- **Minimal fix:** Bind DVT prices to a non-compounding anchor or cumulative time-window bound, and route the selector through a dedicated proof-checked path rather than generic execution.

The native balance and credit validation paths contain no direct TIMESTAMP/NUMBER use; timestamp writes remain in `postOp`. Reservation, settlement, stale release, price/fee snapshots, and xPNTs lock/credit accounting otherwise remained internally conserved in the reviewed flows.

**Counts — NEW: Critical 0, High 0, Medium 1, Low 1, Info 1 | Known confirmations: Critical 0, High 0, Medium 0, Low 2, Info 1.**