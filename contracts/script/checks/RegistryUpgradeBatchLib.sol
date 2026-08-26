// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Registry} from "src/core/Registry.sol";

/**
 * @title RegistryUpgradeBatchLib
 * @notice The ONE definition of the 5.7.0 governance batch: its salt, its predecessor and
 *         the exact three payloads, in order.
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

    /// @dev Number of calls in the batch. Named so a reader can check the arrays below
    ///      against the three steps the header documents.
    uint256 internal constant BATCH_LENGTH = 4;

    /// @notice Build the batch exactly as it is scheduled and executed.
    /// @param proxy          the live Registry ERC1967 proxy — the ONLY target of all three
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
        uint256 perProposalCap,
        uint256 totalCap,
        address[] memory seedUsers
    )
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](BATCH_LENGTH);
        values = new uint256[](BATCH_LENGTH);
        payloads = new bytes[](BATCH_LENGTH);

        // 1. upgrade. `upgradeToAndCall(address,bytes)` is encoded by signature rather than
        //    by `abi.encodeCall` because it lives on the UUPS proxy surface, not on the
        //    `Registry` type.
        targets[0] = proxy;
        payloads[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
        // 2. re-point the aggregator, so ROLE_DVT exits have something to consume.
        targets[1] = proxy;
        payloads[1] = abi.encodeCall(Registry.setBLSAggregator, (newAggregator));
        // 3. seed the caps, so the new slots are never live at 0.
        targets[2] = proxy;
        payloads[2] = abi.encodeCall(Registry.setCreditPolicy, (perProposalCap, totalCap));
        // 4. count the existing population and open the reputation path. Ordered AFTER (3)
        //    because finalizing the count checks the derived stock against the ceiling: a
        //    migration whose real exposure already exceeds the cap it declared fails here,
        //    atomically, instead of going live and wedging on the first proposal.
        targets[3] = proxy;
        payloads[3] = abi.encodeCall(Registry.seedCreditPopulation, (seedUsers, seedUsers.length, true));
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
