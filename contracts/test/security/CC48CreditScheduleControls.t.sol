// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IMySBT.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @notice CC-48 round-9 — the credit SCHEDULE, and the ledger that has to survive it.
///
///  HIGH-B1        `setCreditTier` / `setLevelThresholds` change the real credit limit of
///                 every tracked user. Round-8 let them do that while `totalCreditExposure`
///                 sat still, so the protocol-wide cap went on measuring a world that no
///                 longer existed (one owner call, 16.6x decoupling). They now discard the
///                 ledger and shut the reputation path until governance re-counts.
///  MED-HIGH-B3    the migration baseline is no longer a number an operator types. The
///                 contract reads each declared member's level out of its own storage, an
///                 unseeded proxy issues nothing, and a member the list missed is booked on
///                 first touch instead of being lost.
///  LOW-B4         `totalCreditExposure` measures exposure ABOVE the permissionless
///                 level-1 floor. That is a complete stock over ALL addresses, because a
///                 never-promoted address contributes exactly zero to it. These tests pin
///                 the semantics the NatSpec now claims — including what it does NOT cover.
///  LOW-B5         this whole suite runs on the `initialize` defaults. The round-8 suites
///                 zeroed tier 1 in `setUp`, which is why 1318 green tests could not see
///                 B1 or B4 at all: the quantity under test was set to zero before testing.
///  LOW-B6         the tier table is monotonic by enforcement, not by comment.
///
/// Nothing here calls `setCreditTier(1, 0)`. That is the point.

contract ScheduleMockSBT is IMySBT {
    function mintForRole(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function airdropMint(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function getUserSBT(address) external pure returns (uint256) { return 1; }
    function getSBTData(uint256) external pure returns (SBTData memory) {
        return SBTData(address(0), address(0), 0, 0);
    }
    function verifyCommunityMembership(address, address) external pure returns (bool) { return true; }
    function deactivateMembership(address, address) external pure {}
    function deactivateAllMemberships(address) external pure {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external pure {}
    function burnSBT(address) external pure {}
}

contract ScheduleMockBLS {
    function defaultThreshold() external pure returns (uint256) { return 2; }
    function verify(bytes32, uint256, uint256, bytes calldata) external pure returns (bool) { return true; }
}

contract CC48CreditScheduleControlsTest is Test {
    Registry registry;
    address source = address(0x5150);

    // The `initialize` defaults, restated here so a silent change to them fails a test
    // rather than quietly re-basing every number below.
    uint256 constant TIER1 = 100 ether;
    uint256 constant TIER2 = 100 ether;
    uint256 constant TIER3 = 300 ether;
    uint256 constant TIER4 = 600 ether;
    uint256 constant TIER5 = 1000 ether;
    uint256 constant TIER6 = 2000 ether;

    function setUp() public {
        ScheduleMockSBT sbt = new ScheduleMockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
        registry.setBLSAggregator(address(new ScheduleMockBLS()));
        registry.setReputationSource(source, true);
        // Caps only. The TIER SCHEDULE is left exactly as `initialize` wrote it.
        registry.setCreditPolicy(type(uint256).max, type(uint256).max);
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(uint256(3), bytes(""));
    }

    function _user(uint256 i) internal pure returns (address) {
        return address(uint160(0xC000 + i));
    }

    function _submit(uint256 id, address user, uint256 score, uint256 epoch) internal {
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = user;
        scores[0] = score;
        vm.prank(source);
        registry.batchUpdateGlobalReputation(id, users, scores, epoch, _proof());
    }

    function _seed(address[] memory users) internal {
        registry.seedCreditPopulation(users, users.length, true);
    }

    function _list(address a) internal pure returns (address[] memory users) {
        users = new address[](1);
        users[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory users) {
        users = new address[](2);
        users[0] = a;
        users[1] = b;
    }

    /// The ledger, recomputed here from the PUBLIC state rather than from the internal
    /// helper under test, so a bug in that helper cannot agree with itself.
    function _realExposureAboveFloor(address[] memory users) internal view returns (uint256 sum) {
        uint256 floorLimit = registry.creditTierConfig(1);
        for (uint256 i = 0; i < users.length; i++) {
            uint256 limit = registry.getCreditLimit(users[i]);
            if (limit > floorLimit) sum += limit - floorLimit;
        }
    }

    // =================================================================
    // LOW-B5 / LOW-B4 — the defaults, and what the counter does and does not measure
    // =================================================================

    function test_InitializeTierDefaultsSurviveUntouched() public view {
        assertEq(registry.creditTierConfig(1), TIER1);
        assertEq(registry.creditTierConfig(2), TIER2);
        assertEq(registry.creditTierConfig(3), TIER3);
        assertEq(registry.creditTierConfig(4), TIER4);
        assertEq(registry.creditTierConfig(5), TIER5);
        assertEq(registry.creditTierConfig(6), TIER6);
    }

    /// LOW-B4. An address nobody has ever proposed on holds the level-1 floor, and that
    /// floor is deliberately NOT in `totalCreditExposure`. The old docstring called the
    /// counter "the running sum, over all users, of the credit limit implied by their
    /// current global reputation", which this state falsifies. The current docstring
    /// describes exposure ABOVE the floor, which this state satisfies.
    function test_UntouchedAddressHoldsTheFloorAndContributesNothing() public view {
        assertEq(registry.getCreditLimit(_user(1)), TIER1, "every address holds the floor");
        assertEq(registry.globalReputation(_user(1)), 0);
        assertEq(registry.totalCreditExposure(), 0, "and contributes zero to the bound");
    }

    /// The floor is unbounded BY CONSTRUCTION -- it is granted to addresses that do not
    /// exist yet -- so no counter in this contract can bound it. Stating that in a test
    /// keeps the honest reading of the NatSpec from drifting back into the false one.
    function test_TheFloorIsNotAndCannotBeBoundedByTheCap() public {
        registry.setCreditPolicy(type(uint256).max, 0); // ceiling of ZERO
        // ...and yet a thousand fresh addresses each still hold TIER1 of drawable credit.
        for (uint256 i = 900; i < 910; i++) {
            assertEq(registry.getCreditLimit(_user(i)), TIER1);
        }
        assertEq(registry.totalCreditExposure(), 0, "the cap governs the reputation path only");
    }

    /// A promotion books the ABOVE-FLOOR delta, not the whole limit.
    function test_PromotionBooksOnlyTheAboveFloorDelta() public {
        _submit(1, _user(1), 100, 1); // rep 100 => level 4
        assertEq(registry.getCreditLimit(_user(1)), TIER4);
        assertEq(registry.totalCreditExposure(), TIER4 - TIER1);
        assertEq(registry.totalCreditExposure(), _realExposureAboveFloor(_list(_user(1))));
    }

    // =================================================================
    // HIGH-B1 — a schedule change cannot leave the ledger behind
    // =================================================================

    /// The round-8 defect, reproduced as the reviewer measured it: two users at rep 100,
    /// one `setCreditTier` call, and a ledger that used to keep reading the old number
    /// while the drawable total multiplied.
    function test_TierRepriceCannotSilentlyDecoupleTheLedger() public {
        _submit(1, _user(1), 100, 1);
        _submit(2, _user(2), 100, 1);
        address[] memory both = _list(_user(1), _user(2));

        uint256 ledgerBefore = registry.totalCreditExposure();
        assertEq(ledgerBefore, 2 * (TIER4 - TIER1), "ledger agrees with reality before");
        assertEq(ledgerBefore, _realExposureAboveFloor(both));

        // Owner calls, no proposal, no BLS proof -- and every level-4 user's limit jumps
        // by 9399 aPNT. (Top-down, because the table is monotonic by enforcement now.)
        registry.setCreditTier(6, 9999 ether);
        registry.setCreditTier(5, 9999 ether);
        registry.setCreditTier(4, 9999 ether);
        assertEq(registry.getCreditLimit(_user(1)), 9999 ether, "reality moved");

        // Round-8 behaviour was: ledger still 1000 aPNT, reality 19798 aPNT, cap still
        // measuring the ledger. Round-9: the ledger is discarded and issuance stops.
        assertEq(registry.totalCreditExposure(), 0, "stale stock discarded, not kept");
        assertEq(registry.creditPopulationSeededAt(), 0, "reputation path shut");
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(3);
        scores[0] = 100;
        vm.prank(source);
        vm.expectRevert(Registry.CreditPopulationNotSeeded.selector);
        registry.batchUpdateGlobalReputation(3, users, scores, 1, _proof());

        // Re-counting restores a ledger that matches the NEW reality, computed by the
        // contract from its own storage.
        _seed(both);
        assertEq(registry.totalCreditExposure(), 2 * (9999 ether - TIER1));
        assertEq(registry.totalCreditExposure(), _realExposureAboveFloor(both), "ledger == reality");
    }

    /// Same property for the other setter the reviewer named.
    function test_ThresholdMoveCannotSilentlyDecoupleTheLedger() public {
        _submit(1, _user(1), 100, 1); // level 4 under the default thresholds
        assertEq(registry.totalCreditExposure(), TIER4 - TIER1);

        // Move the thresholds so rep 100 now lands at level 6.
        uint256[] memory t = new uint256[](5);
        t[0] = 1; t[1] = 2; t[2] = 3; t[3] = 4; t[4] = 5;
        registry.setLevelThresholds(t);
        assertEq(registry.getCreditLimit(_user(1)), TIER6, "reality moved");
        assertEq(registry.totalCreditExposure(), 0, "stale stock discarded");
        assertEq(registry.creditPopulationSeededAt(), 0, "reputation path shut");

        _seed(_list(_user(1)));
        assertEq(registry.totalCreditExposure(), TIER6 - TIER1);
        assertEq(registry.totalCreditExposure(), _realExposureAboveFloor(_list(_user(1))));
    }

    /// Fail-closed at the ceiling: if the re-priced schedule does not FIT under the
    /// protocol cap, the re-count is refused rather than accepted-and-wedged. Governance
    /// has to raise the ceiling deliberately, which is a separate, visible decision.
    function test_RepricingAboveTheCeilingIsRefusedAtTheRecount() public {
        registry.setCreditPolicy(type(uint256).max, 1000 ether);
        _submit(1, _user(1), 100, 1);
        assertEq(registry.totalCreditExposure(), TIER4 - TIER1);

        registry.setCreditTier(6, 5000 ether);
        registry.setCreditTier(5, 5000 ether);
        registry.setCreditTier(4, 5000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                Registry.TotalCreditExposureExceeded.selector, 5000 ether - TIER1, 1000 ether
            )
        );
        _seed(_list(_user(1)));

        // Raise the ceiling first, and the same re-count lands.
        registry.setCreditPolicy(type(uint256).max, 10_000 ether);
        _seed(_list(_user(1)));
        assertEq(registry.totalCreditExposure(), 5000 ether - TIER1);
    }

    /// A deployment configures its tier economics BEFORE it has any users, and that must
    /// not shut a path that has nothing to re-count. With nobody tracked, the stock is
    /// provably zero under any schedule, so the invalidation is a no-op.
    function test_SchedulingBeforeAnyUserExistsDoesNotShutThePath() public {
        assertEq(registry.creditPopulationTotal(), 0);
        uint256 seededAt = registry.creditPopulationSeededAt();
        assertGt(seededAt, 0, "a fresh Registry is seeded by initialize");

        registry.setCreditTier(6, 4000 ether);
        uint256[] memory t = new uint256[](5);
        t[0] = 13; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 611;
        registry.setLevelThresholds(t);

        assertEq(registry.creditPopulationSeededAt(), seededAt, "still open");
        _submit(1, _user(1), 100, 1);
        assertEq(registry.totalCreditExposure(), TIER4 - TIER1);
    }

    // =================================================================
    // MEDIUM-HIGH-B3 — seeding derives, it does not trust
    // =================================================================

    /// The slots a pre-5.8.0 proxy carries: all zero, including the seeded-at flag.
    function _makeProxyLookPre580() internal {
        vm.store(address(registry), bytes32(uint256(27)), bytes32(0)); // creditPopulationTotal
        vm.store(address(registry), bytes32(uint256(29)), bytes32(0)); // creditPopulationEpoch
        vm.store(address(registry), bytes32(uint256(30)), bytes32(0)); // creditPopulationSeededAt
    }


    /// A pre-5.8.0 proxy has never written a population marker for anyone, so the
    /// simulation has to clear the per-address slot too -- otherwise the fixture's own
    /// proposals (run against the new implementation) leave markers behind that the real
    /// migration would never see.
    function _forgetPopulationMarkers(address[] memory users) internal {
        for (uint256 i = 0; i < users.length; i++) {
            vm.store(
                address(registry),
                keccak256(abi.encode(users[i], uint256(28))), // creditPopulationEpochOf
                bytes32(0)
            );
        }
    }

    function test_UnseededProxyIssuesNothing() public {
        _makeProxyLookPre580();
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(1);
        scores[0] = 100;
        vm.prank(source);
        vm.expectRevert(Registry.CreditPopulationNotSeeded.selector);
        registry.batchUpdateGlobalReputation(1, users, scores, 1, _proof());
    }

    /// The seed takes MEMBERSHIP, and reads every level itself. An operator repeating the
    /// round-8 recipe ("sum GlobalReputationUpdated into an aPNT baseline") has nowhere to
    /// put the number, and the tier-1 holders that recipe omitted are the addresses that
    /// contribute zero anyway -- which is the whole reason the omission was invisible.
    function test_SeedDerivesEachLevelFromStorage() public {
        _submit(1, _user(1), 100, 1);   // level 4
        _submit(2, _user(2), 1000, 1);  // clamped to 100 => level 4 as well
        _submit(3, _user(3), 20, 1);    // level 2

        vm.store(address(registry), bytes32(uint256(25)), bytes32(0)); // wipe the ledger
        address[] memory all = new address[](3);
        all[0] = _user(1); all[1] = _user(2); all[2] = _user(3);
        _makeProxyLookPre580();
        _forgetPopulationMarkers(all);
        _seed(all);

        assertEq(registry.totalCreditExposure(), _realExposureAboveFloor(all));
        assertEq(registry.totalCreditExposure(), (TIER4 - TIER1) * 2 + (TIER2 - TIER1));
        assertEq(registry.creditPopulationTotal(), 3);
    }

    /// A truncated calldata batch cannot be declared complete.
    function test_SeedRefusesAHeadcountItDidNotReach() public {
        _makeProxyLookPre580();
        // Both addresses are strangers to the ledger. On a genuinely pre-5.8.0 proxy that
        // is the NORMAL case -- their marker slot has never been written -- so this also
        // pins the offset that keeps "never counted" from reading as "already counted".
        address[] memory two = _list(_user(1), _user(2));
        vm.expectRevert(Registry.CreditPopulationCountMismatch.selector);
        registry.seedCreditPopulation(two, 3, true);

        // The honest count lands.
        registry.seedCreditPopulation(two, 2, true);
        assertEq(registry.creditPopulationTotal(), 2);
    }

    /// Seeding in several batches is supported, and the path stays shut until the last
    /// one declares completion.
    function test_SeedCanBeBatchedAndOnlyFinalizeOpensThePath() public {
        _submit(1, _user(1), 100, 1);
        _submit(2, _user(2), 100, 1);
        vm.store(address(registry), bytes32(uint256(25)), bytes32(0));
        _makeProxyLookPre580();
        _forgetPopulationMarkers(_list(_user(1), _user(2)));

        registry.seedCreditPopulation(_list(_user(1)), 0, false);
        assertEq(registry.creditPopulationSeededAt(), 0, "not open after a partial batch");
        assertEq(registry.totalCreditExposure(), TIER4 - TIER1, "but the stock is accumulating");

        // Overlapping batches are idempotent: _user(1) is counted once.
        registry.seedCreditPopulation(_list(_user(1), _user(2)), 2, true);
        assertGt(registry.creditPopulationSeededAt(), 0);
        assertEq(registry.creditPopulationTotal(), 2);
        assertEq(registry.totalCreditExposure(), 2 * (TIER4 - TIER1));
    }

    /// A member the list missed is not lost: the first proposal that touches them books
    /// their whole standing above-floor limit, and that backfill is deliberately kept out
    /// of the per-proposal cap, which measures what THIS proposal issued.
    function test_MissedMemberIsBackfilledWithoutTrippingThePerProposalCap() public {
        _submit(1, _user(1), 100, 1);
        vm.store(address(registry), bytes32(uint256(25)), bytes32(0));
        _makeProxyLookPre580();
        _forgetPopulationMarkers(_list(_user(1)));
        registry.seedCreditPopulation(new address[](0), 0, true); // seeded as "nobody"
        assertEq(registry.totalCreditExposure(), 0);

        // A per-proposal cap of 1 wei: any real issuance would trip it. The backfill does
        // not, because it is not issuance -- it is stock this ledger had never seen.
        registry.setCreditPolicy(1, type(uint256).max);
        _submit(2, _user(1), 100, 2); // same level in, same level out
        assertEq(registry.totalCreditExposure(), TIER4 - TIER1, "standing limit booked");
        assertEq(registry.totalCreditExposure(), _realExposureAboveFloor(_list(_user(1))));
    }

    // =================================================================
    // LOW-B6 — monotonicity is enforced, not merely documented
    // =================================================================

    function test_TierTableCannotBeMadeNonMonotonic() public {
        // Level 4 below level 3.
        vm.expectRevert(Registry.CreditTiersNotMonotonic.selector);
        registry.setCreditTier(4, TIER3 - 1);
        // Level 3 above level 4.
        vm.expectRevert(Registry.CreditTiersNotMonotonic.selector);
        registry.setCreditTier(3, TIER4 + 1);
        // The floor cannot be raised above the level directly above it.
        vm.expectRevert(Registry.CreditTiersNotMonotonic.selector);
        registry.setCreditTier(1, TIER2 + 1);
        // Equality is allowed -- the invariant is "never LOWERS credit".
        registry.setCreditTier(3, TIER4);
        assertEq(registry.creditTierConfig(3), TIER4);
    }

    /// The property the `initialize` comment claims, checked as a property: walking up the
    /// levels never lowers the limit.
    function test_HigherReputationNeverLowersCredit() public {
        registry.setCreditTier(2, 150 ether);
        registry.setCreditTier(3, 400 ether);
        uint256 previous;
        uint256[6] memory reps = [uint256(0), 13, 34, 89, 233, 610];
        for (uint256 i = 0; i < reps.length; i++) {
            _submit(100 + i, _user(50), reps[i], i + 1);
            uint256 limit = registry.getCreditLimit(_user(50));
            assertGe(limit, previous, "a higher reputation lowered the credit limit");
            previous = limit;
        }
    }

    /// A level beyond the reachable top may be PRICED (that is how a schedule grows: the
    /// price has to exist before the level does), but level 0 and anything past the hard
    /// 21-level ceiling are refused.
    function test_TierLevelBoundsAreEnforced() public {
        registry.setCreditTier(7, 3000 ether); // not reachable yet -- pre-pricing is allowed
        assertEq(registry.creditTierConfig(7), 3000 ether);
        assertEq(registry.getCreditLimit(_user(1)), TIER1, "and it changes nothing until reachable");

        vm.expectRevert(Registry.InvalidParam.selector);
        registry.setCreditTier(0, 1 ether);
        vm.expectRevert(Registry.InvalidParam.selector);
        registry.setCreditTier(22, 1 ether); // 20 thresholds is the cap, so 21 is the top
    }

    /// The other half of LOW-B6: a schedule cannot GROW onto a level whose price is still
    /// zero, which would put the highest-reputation users below the level under them.
    function test_ScheduleCannotGrowOntoAnUnpricedLevel() public {
        uint256[] memory t = new uint256[](6);
        t[0] = 13; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610; t[5] = 1597;
        vm.expectRevert(Registry.CreditTiersNotMonotonic.selector);
        registry.setLevelThresholds(t);

        registry.setCreditTier(7, 3000 ether);
        registry.setLevelThresholds(t);
        assertEq(registry.levelThresholds(5), 1597);
    }

    // =================================================================
    // LOW-L1 / LOW-L2 (round-11) — what the invalidation costs, and what the
    // ceiling guard can actually promise
    // =================================================================

    /// LOW-L1. Growing the schedule is forced to price the new top level FIRST
    /// (`test_ScheduleCannotGrowOntoAnUnpricedLevel`). Round-9 charged that mandatory first
    /// step a full governance outage even though it moves nobody's credit limit.
    function test_PricingAnUnreachableLevelCostsNoOutage() public {
        address a = _user(1);
        _submit(1, a, 200, 1);              // clamped to rep 100 => level 4
        _seed(_list(a));

        uint256 limitBefore = registry.getCreditLimit(a);
        uint256 stockBefore = registry.totalCreditExposure();
        uint256 countedBefore = registry.creditPopulationTotal();
        assertGt(stockBefore, 0, "fixture must have a live stock to lose");
        assertGt(registry.creditPopulationSeededAt(), 0, "path must start open");

        // Level 7 is above the reachable top (5 default thresholds => maxLevel 6).
        registry.setCreditTier(7, 3000 ether);

        assertEq(registry.creditTierConfig(7), 3000 ether, "the price is written");
        assertEq(registry.getCreditLimit(a), limitBefore, "nobody's limit moved");
        assertEq(registry.totalCreditExposure(), stockBefore, "so the stock is still exact");
        assertEq(registry.creditPopulationTotal(), countedBefore, "and nobody was un-counted");
        assertGt(registry.creditPopulationSeededAt(), 0, "the reputation path stays open");

        // Still open in the sense that matters: proposals land and are booked. The
        // reputation clamp is +/-100 per proposal, so reaching level 5 (threshold 233)
        // from rep 100 takes two more.
        _submit(2, a, 300, 2);              // rep 200 -- still level 4
        assertEq(registry.getCreditLimit(a), TIER4);
        _submit(3, a, 300, 3);              // rep 300 => level 5
        assertEq(registry.getCreditLimit(a), TIER5);
        assertEq(registry.totalCreditExposure(), TIER5 - TIER1, "and the ledger followed");
    }

    /// The exemption is bounded by reachability, not by level number: the same call against
    /// a level that IS reachable still discards the ledger.
    function test_PricingAReachableLevelStillCostsTheOutage() public {
        address a = _user(1);
        _submit(1, a, 200, 1);
        _seed(_list(a));
        assertGt(registry.totalCreditExposure(), 0);

        registry.setCreditTier(6, 5000 ether);   // maxLevel is 6 -- reachable

        assertEq(registry.totalCreditExposure(), 0, "stale stock discarded, not kept");
        assertEq(registry.creditPopulationSeededAt(), 0, "and the path is shut");
    }

    /// The exemption cannot be used to smuggle a price in and have it apply un-counted: the
    /// step that makes the level reachable invalidates on its own.
    function test_PrePricedLevelIsInvalidatedWhenItBecomesReachable() public {
        address a = _user(1);
        _submit(1, a, 200, 1);
        _seed(_list(a));

        registry.setCreditTier(7, 3000 ether);
        assertGt(registry.creditPopulationSeededAt(), 0, "not yet reachable, path still open");

        uint256[] memory t = new uint256[](6);
        t[0] = 13; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610; t[5] = 1597;
        registry.setLevelThresholds(t);          // level 7 now reachable

        assertEq(registry.totalCreditExposure(), 0, "the growth discards the ledger");
        assertEq(registry.creditPopulationSeededAt(), 0, "and shuts the path");
    }

    /// LOW-L2. The ceiling guard in `setCreditPolicy` reads `totalCreditExposure`, which is
    /// ZERO inside the invalidation window -- so it cannot refuse a ceiling below what is
    /// really drawable there. This test pins the honest behaviour the NatSpec now states:
    /// the window is fail-closed because the RE-COUNT refuses, not because this line does.
    function test_CeilingGuardIsVacuousInTheWindowAndTheRecountIsNot() public {
        address a = _user(1);
        _submit(1, a, 700, 1);                   // clamped to rep 100 => level 4
        _seed(_list(a));
        assertEq(registry.getCreditLimit(a), TIER4);

        // Seeded: the guard bites, exactly as advertised for the ordinary case.
        vm.expectRevert(
            abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, TIER4 - TIER1, 1)
        );
        registry.setCreditPolicy(type(uint256).max, 1);

        // Re-price a REACHABLE level -> invalidation window. Level 5 is above this user,
        // so their drawable limit does not move: only the ledger's view of it does.
        registry.setCreditTier(5, 1100 ether);
        assertEq(registry.totalCreditExposure(), 0, "ledger discarded");
        assertEq(registry.getCreditLimit(a), TIER4, "while TIER4 is still really drawable");

        // In the window the same rejected call now SUCCEEDS -- the guard is vacuous here,
        // because the number it compares against was just zeroed.
        registry.setCreditPolicy(type(uint256).max, 1);
        assertEq(registry.maxTotalCreditExposure(), 1);
        assertEq(registry.getCreditLimit(a), TIER4, "and the ceiling did not claw it back");

        // The protection that does hold: the re-count refuses to re-open the path.
        vm.expectRevert(
            abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, TIER4 - TIER1, 1)
        );
        registry.seedCreditPopulation(_list(a), 1, true);
        assertEq(registry.creditPopulationSeededAt(), 0, "path stays shut -- fail-closed");

        // Raising the ceiling and re-counting is the way out.
        registry.setCreditPolicy(type(uint256).max, type(uint256).max);
        registry.seedCreditPopulation(_list(a), 1, true);
        assertGt(registry.creditPopulationSeededAt(), 0);
        assertEq(registry.totalCreditExposure(), TIER4 - TIER1);
    }

    /// LOW-L1, stated as the invariant rather than as three examples: for ANY level and
    /// ANY price, if `setCreditTier` left the ledger standing then it must also have left
    /// every real credit limit standing, and the ledger must still equal reality. This is
    /// the property the exemption claims; a fuzz run is what makes the claim a claim about
    /// all levels rather than about the three the examples happen to pick.
    function testFuzz_SkippingTheOutageImpliesNobodyMoved(uint256 level, uint256 limit) public {
        level = bound(level, 1, 21);
        // Stay inside the monotonic band around the target so the call is not rejected for
        // an unrelated reason; the interesting axis here is the level, not the price.
        uint256 lo = level > 1 ? registry.creditTierConfig(level - 1) : 0;
        uint256 hi = level < 6 ? registry.creditTierConfig(level + 1) : type(uint128).max;
        if (hi < lo) return;
        limit = bound(limit, lo, hi);

        address[] memory both = _list(_user(1), _user(2));
        _submit(1, _user(1), 100, 1);   // level 4
        _submit(2, _user(2), 20, 1);    // level 2
        _seed(both);

        uint256[] memory limitsBefore = new uint256[](both.length);
        for (uint256 i = 0; i < both.length; i++) limitsBefore[i] = registry.getCreditLimit(both[i]);
        uint256 stockBefore = registry.totalCreditExposure();
        assertEq(stockBefore, _realExposureAboveFloor(both), "fixture starts exact");

        registry.setCreditTier(level, limit);

        if (registry.creditPopulationSeededAt() != 0) {
            // The outage was skipped. That is only allowed when nothing moved.
            for (uint256 i = 0; i < both.length; i++) {
                assertEq(registry.getCreditLimit(both[i]), limitsBefore[i], "limit moved without an outage");
            }
            assertEq(registry.totalCreditExposure(), stockBefore, "stock changed without an outage");
            assertEq(registry.totalCreditExposure(), _realExposureAboveFloor(both), "ledger drifted from reality");
        } else {
            // The outage happened: the stock is discarded, never left stale.
            assertEq(registry.totalCreditExposure(), 0, "invalidated but stock kept");
        }
    }

    // =================================================================
    // EIP-170 refactor guard — the bootstrap matrix must be byte-identical
    // =================================================================

    /// CC-48 round-9. `initialize` now drives its seven role rows through one call site
    /// instead of seven, which is where the runtime bytes for this round came from. That
    /// is only safe if the rows are unchanged, so they are asserted field by field
    /// against the values the seven original call sites passed.
    function test_RoleBootstrapMatrixUnchanged() public view {
        _assertRole(ROLE_PAYMASTER_AOA, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, 30 days);
        _assertRole(ROLE_PAYMASTER_SUPER, 50 ether, 5 ether, 10, 2, 1, 10, 1000, 2 ether, 30 days);
        _assertRole(ROLE_DVT, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, 30 days);
        _assertRole(ROLE_ANODE, 20 ether, 2 ether, 15, 1, 1, 5, 1000, 1 ether, 30 days);
        _assertRole(ROLE_KMS, 100 ether, 10 ether, 5, 5, 2, 20, 1000, 5 ether, 30 days);
        _assertRole(ROLE_COMMUNITY, 0, 30 ether, 0, 0, 0, 0, 0, 0, 0);
        _assertRole(ROLE_ENDUSER, 0, 0.3 ether, 0, 0, 0, 0, 0, 0, 0);
    }

    function _assertRole(
        bytes32 roleId,
        uint256 min,
        uint256 ticketPrice,
        uint32 thresh,
        uint32 base,
        uint32 inc,
        uint32 max,
        uint16 exitFeePercent,
        uint256 minExitFee,
        uint256 lockDuration
    ) internal view {
        Registry.RoleConfig memory cfg = registry.getRoleConfig(roleId);
        assertEq(cfg.minStake, min, "minStake");
        assertEq(cfg.ticketPrice, ticketPrice, "ticketPrice");
        assertEq(uint256(cfg.slashThreshold), thresh, "slashThreshold");
        assertEq(uint256(cfg.slashBase), base, "slashBase");
        assertEq(uint256(cfg.slashInc), inc, "slashInc");
        assertEq(uint256(cfg.slashMax), max, "slashMax");
        assertEq(uint256(cfg.exitFeePercent), exitFeePercent, "exitFeePercent");
        assertEq(cfg.minExitFee, minExitFee, "minExitFee");
        assertEq(cfg.roleLockDuration, lockDuration, "roleLockDuration");
        assertTrue(cfg.isActive, "isActive");
        assertEq(cfg.owner, address(this), "owner");
    }
}
