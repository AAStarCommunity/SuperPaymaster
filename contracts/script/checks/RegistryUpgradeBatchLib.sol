// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Registry} from "src/core/Registry.sol";

interface IStakingSlasherAuth {
    function setAuthorizedSlasher(address slasher, bool authorized) external;
}

/**
 * @title RegistryUpgradeBatchLib
 * @notice The ONE definition of the 5.7.0 governance batch: its salt, its predecessor and
 *         the exact payloads, in order.
 *
 * @dev CC-48 round-8 LOW-5. `UpgradeRegistryTo580` built this batch inline and
 *      `CC48RegistryTimelockGovernance` rebuilt a hand-written copy of it, while the test's
 *      own NatSpec claimed it "binds to the shipped parameters rather than to a convenient
 *      reimplementation of them". That was false and measurable: changing the salt in the
 *      script left the test green, because the test held its own constant. A copy is not a
 *      binding.
 *
 *      Both the script and the test now call THIS library, so there is one salt, one
 *      predecessor and one payload builder in the repository. Changing any of them changes
 *      what the script emits AND what the test asserts, in the same edit — which is what
 *      the old comment claimed and this arrangement actually delivers.
 *
 *      Why the batch must stay atomic (the property the test exercises):
 *        - between (1) and (3) the new `maxTotalCreditExposure` slot reads 0, so every
 *          proposal carrying positive uplift reverts;
 *        - between (1) and (2) the still-wired predecessor has no `consumeGuardianExit`,
 *          so every ROLE_DVT `exitRole` reverts and DVT stake is stuck.
 *      A TimelockController operation id commits to the whole tuple, so any proper subset
 *      hashes to an id that was never scheduled and cannot be executed.
 */
library RegistryUpgradeBatchLib {
    /// @dev The salt the migration schedules under. Arbitrary but FIXED: it is what makes
    ///      the operation id reproducible from the published parameters, so an observer can
    ///      recompute the id a governance operator claims to have scheduled.
    bytes32 internal constant BATCH_SALT = bytes32(uint256(0x5600));

    /// @dev No predecessor: this batch does not depend on another queued operation.
    bytes32 internal constant NO_PREDECESSOR = bytes32(0);

    /// @dev Number of calls in the batch. Six when there is a DIFFERENT predecessor to
    ///      disarm; five when there is none, or when the aggregator is not being rotated
    ///      at all (a Registry-only upgrade keeps the same aggregator address). Read
    ///      `targets.length` rather than assuming one of them.
    uint256 internal constant BATCH_LENGTH = 6;
    uint256 internal constant BATCH_LENGTH_NO_REVOKE = 5;

    /// @notice Build the batch exactly as it is scheduled and executed.
    /// @param oldAggregator  predecessor to DISARM in (4). Pass address(0) on a first
    ///                       deployment; passing the SAME address as `newAggregator`
    ///                       (a Registry-only upgrade) correctly skips the revoke
    /// @param staking        GTokenStaking, target of the slasher calls in (3) and (4)
    /// @param proxy          the live Registry ERC1967 proxy — target of every step except (3)
    ///                       calls, so a batch that touches any other address is not this one
    /// @param newImpl        freshly built `Registry` 5.7.0 implementation
    /// @param newAggregator  `BLSAggregator` 4.11.0
    /// @param perProposalCap transaction-level aggregate uplift guard, aPNT wei
    /// @param totalCap       protocol-wide outstanding ceiling, aPNT wei
    /// @param seedUsers      every address that has EVER been the subject of a reputation
    ///                       proposal on the live Registry. Only membership matters: the
    ///                       contract reads each one's level out of its own
    ///                       `globalReputation` storage, so no operator arithmetic enters
    ///                       the stock. Addresses that were never promoted may be included
    ///                       harmlessly (they contribute zero) but must then be counted in
    ///                       the declared total, which is `seedUsers.length` here.
    function buildBatch(
        address proxy,
        address newImpl,
        address newAggregator,
        address oldAggregator,
        address staking,
        uint256 perProposalCap,
        uint256 totalCap,
        address[] memory seedUsers
    )
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        // There is a revoke step only when an authorisation actually becomes stale: a
        // first-ever deployment has no predecessor, and a Registry-only upgrade keeps the
        // SAME aggregator, whose authorisation must survive. Deciding the length here keeps
        // the caller from having to know.
        bool revokes = oldAggregator != address(0) && oldAggregator != newAggregator;
        uint256 len = revokes ? BATCH_LENGTH : BATCH_LENGTH_NO_REVOKE;
        targets = new address[](len);
        values = new uint256[](len);
        payloads = new bytes[](len);

        // 1. upgrade. `upgradeToAndCall(address,bytes)` is encoded by signature rather than
        //    by `abi.encodeCall` because it lives on the UUPS proxy surface, not on the
        //    `Registry` type.
        targets[0] = proxy;
        payloads[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
        // 2. re-point the aggregator, so ROLE_DVT exits have something to consume.
        targets[1] = proxy;
        payloads[1] = abi.encodeCall(Registry.setBLSAggregator, (newAggregator));
        // 3. authorise the NEW aggregator to slash. BLSAggregator is not upgradeable, so
        //    (2) points Registry at a FRESH ADDRESS, and `authorizedSlashers` is keyed by
        //    address — the predecessor's authorisation does not carry over. Omit this and
        //    `executeGuardianSlash` takes the try/catch path on every guardian
        //    (`slashByDVT` reverts with NotAuthorizedSlasher), the case expires after its
        //    window, every freeze is released, and the result is ZERO slashed, ZERO reverts
        //    and zero alarms — a silently disarmed slash path. It belongs in this batch
        //    rather than in a follow-up transaction for exactly that reason: the failure it
        //    prevents is invisible.
        //
        //    Same owner, so it can ride along: Registry, GTokenStaking and BLSAggregator all
        //    answer to one `owner()` (verified on Sepolia). If a deployment ever splits
        //    them, this step must move to that owner's own transaction and the preflight
        //    assertion below becomes the only guard.
        targets[2] = staking;
        payloads[2] = abi.encodeCall(IStakingSlasherAuth.setAuthorizedSlasher, (newAggregator, true));
        // 4. REVOKE the predecessor's slasher authorisation. `authorizedSlashers` is keyed
        //    by address and nothing clears it, so an aggregator that is no longer wired to
        //    anything keeps full authority to call `slashByDVT` and `slash` on every DVT's
        //    stake. Rotating away from a contract is not the same as disarming it: the
        //    deprecated build stays armed, including whatever bug or compromise motivated
        //    the rotation, and its own owner can still reach it. Granting the new authority
        //    without withdrawing the old one leaves the migration strictly permission-additive.
        //    Skipped when there is no predecessor, and — critically — when the predecessor
        //    IS the new aggregator. A Registry-only upgrade passes the same address as both,
        //    and revoking it here would undo the grant two lines above in the same atomic
        //    batch: the slash path would come out of the migration silently disarmed, which
        //    is the exact failure the grant was added to prevent.
        uint256 next = 3;
        if (revokes) {
            targets[next] = staking;
            payloads[next] = abi.encodeCall(IStakingSlasherAuth.setAuthorizedSlasher, (oldAggregator, false));
            unchecked { ++next; }
        }
        // 5. seed the caps, so the new slots are never live at 0.
        targets[next] = proxy;
        payloads[next] = abi.encodeCall(Registry.setCreditPolicy, (perProposalCap, totalCap));
        unchecked { ++next; }
        // 6. count the existing population and open the reputation path. Ordered AFTER (5)
        //    because finalizing the count checks the derived stock against the ceiling: a
        //    migration whose real exposure already exceeds the cap it declared fails here,
        //    atomically, instead of going live and wedging on the first proposal.
        targets[next] = proxy;
        payloads[next] = abi.encodeCall(Registry.seedCreditPopulation, (seedUsers, seedUsers.length, true));
    }

    /// @notice The "governance operator splits the batch to be careful" counterfactual:
    ///         step (1) alone.
    /// @dev    Kept here rather than in the test so the SUBSET is derived from the shipped
    ///         batch, not from a second hand-written guess at what step (1) looks like.
    function upgradeOnlySubBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads
    ) internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory p) {
        t = new address[](1);
        v = new uint256[](1);
        p = new bytes[](1);
        t[0] = targets[0];
        v[0] = values[0];
        p[0] = payloads[0];
    }
}
