// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {PolicyRegistry} from "src/core/PolicyRegistry.sol";
import {IPolicyRegistry} from "src/interfaces/v3/IPolicyRegistry.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";

/// @title PolicyRegistry tests
/// @notice Covers checkPolicy tri-state, remainingDaily math, recordSpend window-roll,
///         Q5 timelock-gated loosening (schedule→warp→execute), immediate guardian tighten/freeze,
///         Q4 ETH sentinel, consumer gating, and Q3 additive selectors.
contract PolicyRegistryTest is Test {
    event AssetPolicySet(
        address indexed sender, address indexed asset, uint128 dvtTriggerAmount,
        uint128 perTxHardCap, uint256 dailyLimit, uint64 effectiveWindow
    );
    event ContractScopeSet(
        address indexed sender, address indexed target, bool allowed,
        bool requireDVTAlways, uint64 velocityWindow
    );
    event TargetVelocitySet(
        address indexed sender, address indexed target, address indexed asset, uint128 limit
    );
    PolicyRegistry internal reg;
    TimelockController internal timelock;

    uint256 internal constant MIN_DELAY = 2 days;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal consumer = makeAddr("consumer");
    address internal stranger = makeAddr("stranger");

    address internal sender = makeAddr("aaAccount");
    address internal asset = makeAddr("usdc");
    address internal target = makeAddr("dapp");
    bytes4 internal constant SEL = bytes4(0xaabbccdd);

    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 internal salt; // avoid timelock operation-id collisions across schedules
    uint128 internal nextVelocityLimit;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = governor;
        address[] memory executors = new address[](1);
        executors[0] = governor;
        // admin = governor so we can grant CANCELLER_ROLE to guardian (cancellation authority).
        timelock = new TimelockController(MIN_DELAY, proposers, executors, governor);
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        vm.prank(governor);
        timelock.grantRole(cancellerRole, guardian);

        reg = new PolicyRegistry(address(timelock), guardian, consumer);

        // Standard config for `sender` via the timelock loosening path.
        _setAssetPolicy(sender, asset, _ap(100e18, 500e18, 1000e18, 1 days));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScope(sender, target, _cs(true, false, 800e18, 1 hours, sels));
    }

    // ───────────────────────── helpers ─────────────────────────

    function _ap(uint128 trig, uint128 cap, uint256 daily, uint64 win)
        internal
        pure
        returns (IPolicyRegistry.AssetPolicyInput memory)
    {
        return IPolicyRegistry.AssetPolicyInput(trig, cap, daily, win);
    }

    function _cs(bool allowed, bool dvtAlways, uint128 vLimit, uint64 vWin, bytes4[] memory sels)
        internal
        returns (IPolicyRegistry.ContractScopeInput memory)
    {
        nextVelocityLimit = vLimit;
        return IPolicyRegistry.ContractScopeInput(allowed, dvtAlways, vWin, sels);
    }

    /// @dev schedule→warp→execute an arbitrary call on `reg` through the timelock.
    function _viaTimelock(bytes memory data) internal {
        bytes32 s = bytes32(salt++);
        vm.prank(governor);
        timelock.schedule(address(reg), 0, data, bytes32(0), s, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(governor);
        timelock.execute(address(reg), 0, data, bytes32(0), s);
    }

    function _setAssetPolicy(address s, address a, IPolicyRegistry.AssetPolicyInput memory p)
        internal
    {
        _viaTimelock(abi.encodeCall(IPolicyRegistry.setAssetPolicy, (s, a, p)));
    }

    function _setContractScope(address s, address t, IPolicyRegistry.ContractScopeInput memory p)
        internal
    {
        _setContractScopeForAsset(s, t, asset, p);
    }

    function _setContractScopeForAsset(
        address s, address t, address a, IPolicyRegistry.ContractScopeInput memory p
    ) internal {
        _viaTimelock(abi.encodeCall(IPolicyRegistry.setContractScope, (s, t, p)));
        _viaTimelock(
            abi.encodeCall(IPolicyRegistry.setTargetVelocity, (s, t, a, nextVelocityLimit))
        );
    }

    function _check(uint256 amount)
        internal
        view
        returns (IPolicyRegistry.PolicyDecision, uint256)
    {
        return reg.checkPolicy(sender, target, asset, amount, SEL);
    }

    function _record(uint256 amount) internal {
        vm.prank(consumer);
        reg.recordSpend(sender, target, asset, amount, SEL);
    }

    // ───────────────────────── checkPolicy: ALLOW ─────────────────────────

    function testAllow() public view {
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = _check(50e18);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem, 1000e18 - 50e18); // remainingDaily after this amount would post
    }

    // ───────────────────────── checkPolicy: REQUIRE_DVT ─────────────────────────

    function testRequireDVT_byAmount() public view {
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = _check(150e18); // >= trigger 100e18
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));
        assertEq(rem, 1000e18 - 150e18);
    }

    function testRequireDVT_byRequireDVTAlways() public {
        address t2 = makeAddr("alwaysDvtTarget");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScope(sender, t2, _cs(true, true, 800e18, 1 hours, sels));
        (IPolicyRegistry.PolicyDecision d,) = reg.checkPolicy(sender, t2, asset, 1e18, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));
    }

    // ───────────────────────── checkPolicy: REJECT (each path) ─────────────────────────

    function testReject_frozen() public {
        vm.prank(guardian);
        reg.freezeSender(sender);
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = _check(10e18);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
        assertEq(rem, 0);
    }

    function testReject_overHardCap() public view {
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = _check(600e18); // > cap 500e18
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
        assertEq(rem, 0);
    }

    function testReject_selectorNotAllowed() public view {
        (IPolicyRegistry.PolicyDecision d,) =
            reg.checkPolicy(sender, target, asset, 10e18, bytes4(0xdeadbeef));
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function testReject_dailyExhausted() public {
        _record(900e18); // assetSpent = 900
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = _check(200e18); // 900+200 > 1000
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
        assertEq(rem, 0);
    }

    function testReject_velocityExhausted() public {
        // Reconfigure with a velocity limit BELOW the daily limit to isolate the velocity path.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScope(sender, target, _cs(true, false, 300e18, 1 hours, sels));
        _record(250e18); // targetSpent = 250 (and assetSpent = 250, well under daily 1000)
        (IPolicyRegistry.PolicyDecision d,) = _check(100e18); // velocity 250+100 > 300
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function test_C301_TargetVelocityScopesAndCountersAreAssetSpecific() public {
        address assetB = makeAddr("assetB");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScopeForAsset(sender, target, assetB, _cs(true, false, 400e18, 1 hours, sels));

        vm.prank(consumer);
        reg.recordSpend(sender, target, assetB, 301e18, SEL);

        (IPolicyRegistry.PolicyDecision assetADecision,) =
            reg.checkPolicy(sender, target, asset, 500e18, SEL);
        assertEq(uint8(assetADecision), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));

        (IPolicyRegistry.PolicyDecision assetBDecision,) =
            reg.checkPolicy(sender, target, assetB, 100e18, SEL);
        assertEq(uint8(assetBDecision), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function test_C301_TargetRestrictionsCannotBeBypassedWithAnotherAsset() public view {
        address unconfiguredAsset = address(0xBEEF);
        (IPolicyRegistry.PolicyDecision decision,) =
            reg.checkPolicy(sender, target, unconfiguredAsset, 1, SEL);
        assertEq(uint8(decision), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function test_C301_MissingAssetVelocityFailsClosed() public view {
        address unconfiguredAsset = address(0xCAFE);
        (IPolicyRegistry.PolicyDecision decision,) =
            reg.checkPolicy(sender, target, unconfiguredAsset, 0, SEL);
        assertEq(uint8(decision), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function test_C301_TargetVelocityBoundaryIsInclusive() public {
        _setAssetPolicy(sender, asset, _ap(0, 1000e18, 2000e18, 1 days));
        (IPolicyRegistry.PolicyDecision atLimit,) = _check(800e18);
        assertEq(uint8(atLimit), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        (IPolicyRegistry.PolicyDecision overLimit,) = _check(800e18 + 1);
        assertEq(uint8(overLimit), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    // ───────────────────────── opt-in default-ALLOW semantics (#110 owner decision) ─────────────────────────

    /// (a) A sender with NOTHING configured ⇒ ALLOW with unlimited headroom (pure opt-in).
    function testUnconfiguredSenderAllowsWithMaxRemaining() public {
        address s2 = makeAddr("freshSender");
        address t2 = makeAddr("freshTarget");
        address a2 = makeAddr("freshAsset");
        (IPolicyRegistry.PolicyDecision d, uint256 rem) =
            reg.checkPolicy(s2, t2, a2, 1_000_000e18, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem, type(uint256).max);
    }

    function test_POL03_AmountAboveUint128AllowedWhenNoCounterIsConfigured() public {
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = reg.checkPolicy(
            makeAddr("wideSender"), makeAddr("wideTarget"), makeAddr("wideAsset"),
            uint256(type(uint128).max) + 1, SEL
        );
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem, type(uint256).max);
    }

    function test_POL02_UnconfiguredSpendDoesNotPrepopulateDormantCounters() public {
        address s = makeAddr("dormantSender");
        address t = makeAddr("dormantTarget");
        address a = makeAddr("dormantAsset");
        vm.prank(consumer);
        reg.recordSpend(s, t, a, 50, SEL);
        (uint256 spent, uint64 started) = reg.getAssetSpend(s, a);
        assertEq(spent, 0);
        assertEq(started, 0);

        _setAssetPolicy(s, a, _ap(0, 100, 100, 1 days));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScopeForAsset(s, t, a, _cs(true, false, 100, 1 hours, sels));
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = reg.checkPolicy(s, t, a, 100, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem, 0);
    }

    /// (b) Asset configured but target unconfigured ⇒ asset cap/daily enforced, target UNRESTRICTED.
    function testAssetConfiguredTargetUnconfigured() public {
        address t2 = makeAddr("unconfiguredTarget");
        // Target unconfigured ⇒ no allow-list / selector check (deadbeef selector is irrelevant).
        (IPolicyRegistry.PolicyDecision d, uint256 rem) =
            reg.checkPolicy(sender, t2, asset, 10e18, bytes4(0xdeadbeef));
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem, 1000e18 - 10e18); // asset daily still bounds the headroom
        // The configured asset's hard cap is STILL enforced regardless of the target being open.
        (IPolicyRegistry.PolicyDecision d2, uint256 rem2) =
            reg.checkPolicy(sender, t2, asset, 600e18, bytes4(0xdeadbeef));
        assertEq(uint8(d2), uint8(IPolicyRegistry.PolicyDecision.REJECT)); // > cap 500e18
        assertEq(rem2, 0);
    }

    /// (c) Target configured but asset unconfigured ⇒ target scope enforced, asset UNLIMITED.
    function testTargetConfiguredAssetUnconfigured() public {
        address s2 = makeAddr("scopeOnlySender");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        // velocityWindow 0 ⇒ no velocity limit, to isolate the "asset unlimited" behavior.
        _setContractScope(s2, target, _cs(true, false, 0, 0, sels));
        // asset unconfigured ⇒ unlimited headroom; target scope still allows this selector.
        (IPolicyRegistry.PolicyDecision d, uint256 rem) =
            reg.checkPolicy(s2, target, asset, 1_000_000e18, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem, type(uint256).max); // asset side imposes no limit
        // The configured target scope is STILL enforced: a non-allowed selector → REJECT.
        (IPolicyRegistry.PolicyDecision d2,) =
            reg.checkPolicy(s2, target, asset, 1e18, bytes4(0xdeadbeef));
        assertEq(uint8(d2), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    /// (d) `dvtTriggerAmount == 0` ⇒ amount-based DVT trigger DISABLED (ALLOW even for huge amount).
    function testDvtTriggerZeroDisablesAmountTrigger() public {
        // Reconfigure the asset with dvtTriggerAmount == 0, huge cap & daily.
        _setAssetPolicy(sender, asset, _ap(0, 1_000_000e18, 2_000_000e18, 1 days));
        // Unconfigured target isolates the asset amount→DVT path.
        address t2 = makeAddr("freeTarget");
        (IPolicyRegistry.PolicyDecision d, uint256 rem) =
            reg.checkPolicy(sender, t2, asset, 999_999e18, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW)); // 0-trigger ⇒ no DVT
        assertEq(rem, 2_000_000e18 - 999_999e18);
    }

    /// (e) `dvtTriggerAmount > 0` boundary: amount EXACTLY at the trigger still fires REQUIRE_DVT.
    function testDvtTriggerBoundaryStillTriggers() public view {
        // trigger == 100e18 (setUp). Exactly at trigger → REQUIRE_DVT; one wei below → ALLOW.
        (IPolicyRegistry.PolicyDecision d,) = _check(100e18);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));
        (IPolicyRegistry.PolicyDecision d2,) = _check(100e18 - 1);
        assertEq(uint8(d2), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
    }

    /// (f) An explicit freeze ⇒ REJECT even for an otherwise-unconfigured (opt-in) sender.
    function testFrozenRejectsEvenWhenUnconfigured() public {
        address s2 = makeAddr("frozenFreshSender");
        vm.prank(guardian);
        reg.freezeSender(s2);
        address t2 = makeAddr("freshTarget2");
        address a2 = makeAddr("freshAsset2");
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = reg.checkPolicy(s2, t2, a2, 1e18, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
        assertEq(rem, 0);
    }

    /// (g) `requireDVTAlways` on a configured target forces REQUIRE_DVT even with asset UNCONFIGURED.
    function testRequireDVTAlwaysWithUnconfiguredAsset() public {
        address s2 = makeAddr("dvtAlwaysSender");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScope(s2, target, _cs(true, true, 0, 0, sels)); // requireDVTAlways, no velocity
        // asset unconfigured ⇒ unlimited headroom; requireDVTAlways still forces REQUIRE_DVT.
        (IPolicyRegistry.PolicyDecision d, uint256 rem) =
            reg.checkPolicy(s2, target, asset, 1e18, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));
        assertEq(rem, type(uint256).max);
    }

    // ───────────────────────── remainingDaily math + recordSpend ─────────────────────────

    function testRemainingDailyDecreasesAfterSpend() public {
        (, uint256 rem0) = _check(50e18);
        assertEq(rem0, 950e18);
        _record(400e18);
        (IPolicyRegistry.PolicyDecision d, uint256 rem1) = _check(50e18);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem1, 1000e18 - 400e18 - 50e18); // 550e18
    }

    function testRecordSpendAdvancesBothCounters() public {
        _record(120e18);
        (uint256 spent,) = reg.getAssetSpend(sender, asset);
        assertEq(spent, 120e18);
        // target velocity counter advanced too: pushing past 800 now rejects.
        (IPolicyRegistry.PolicyDecision d,) = reg.checkPolicy(sender, target, asset, 700e18, SEL);
        // daily: 120+700=820<1000 ok; velocity: 120+700=820>800 → REJECT.
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function testRecordSpendWindowRolls() public {
        _record(300e18);
        (uint256 s1, uint64 w1) = reg.getAssetSpend(sender, asset);
        assertEq(s1, 300e18);
        // Advance past the 1-day window; next record opens a fresh window.
        vm.warp(block.timestamp + 1 days + 1);
        _record(50e18);
        (uint256 s2, uint64 w2) = reg.getAssetSpend(sender, asset);
        assertEq(s2, 50e18); // rolled, not 350
        assertGt(w2, w1);
    }

    function test_POL03_SequentialBoundaryAllowedSpendAlwaysRecords() public {
        address s = makeAddr("pol03BoundarySender");
        address t = makeAddr("pol03BoundaryTarget");
        address a = makeAddr("pol03BoundaryAsset");
        uint256 max128 = type(uint128).max;
        _setAssetPolicy(s, a, _ap(0, type(uint128).max, max128 + 1, 1 days));

        (IPolicyRegistry.PolicyDecision first,) = reg.checkPolicy(s, t, a, max128, SEL);
        assertEq(uint8(first), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        vm.prank(consumer);
        reg.recordSpend(s, t, a, max128, SEL);

        (IPolicyRegistry.PolicyDecision second,) = reg.checkPolicy(s, t, a, 1, SEL);
        assertEq(uint8(second), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        vm.prank(consumer);
        reg.recordSpend(s, t, a, 1, SEL);

        (uint256 spent,) = reg.getAssetSpend(s, a);
        assertEq(spent, max128 + 1);
    }

    function test_POL03_SameBundleStaleCountersDoNotRevertDuringRecording() public {
        address s = makeAddr("pol03BundleSender");
        address t = makeAddr("pol03BundleTarget");
        address a = makeAddr("pol03BundleAsset");
        uint128 amount = type(uint128).max / 2 + 1;
        _setAssetPolicy(s, a, _ap(0, type(uint128).max, type(uint256).max, 1 days));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScopeForAsset(
            s, t, a, _cs(true, false, type(uint128).max, 1 hours, sels)
        );

        for (uint256 i; i < 3; ++i) {
            (IPolicyRegistry.PolicyDecision decision,) = reg.checkPolicy(s, t, a, amount, SEL);
            assertEq(uint8(decision), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(consumer);
            reg.recordSpend(s, t, a, amount, SEL);
        }

        (uint256 spent,) = reg.getAssetSpend(s, a);
        assertEq(spent, uint256(amount) * 3);
    }

    function testFuzz_POL03_AllowImpliesRecordSpendDoesNotRevert(
        uint128 firstAmount,
        uint128 secondAmount
    ) public {
        vm.assume(uint256(firstAmount) + secondAmount > type(uint128).max);
        address s = makeAddr("pol03FuzzSender");
        address t = makeAddr("pol03FuzzTarget");
        address a = makeAddr("pol03FuzzAsset");
        _setAssetPolicy(s, a, _ap(0, type(uint128).max, type(uint256).max, 1 days));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScopeForAsset(
            s, t, a, _cs(true, false, type(uint128).max, 1 hours, sels)
        );

        (IPolicyRegistry.PolicyDecision first,) =
            reg.checkPolicy(s, t, a, firstAmount, SEL);
        (IPolicyRegistry.PolicyDecision second,) =
            reg.checkPolicy(s, t, a, secondAmount, SEL);
        assertEq(uint8(first), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(uint8(second), uint8(IPolicyRegistry.PolicyDecision.ALLOW));

        vm.startPrank(consumer);
        reg.recordSpend(s, t, a, firstAmount, SEL);
        reg.recordSpend(s, t, a, secondAmount, SEL);
        vm.stopPrank();
    }

    function testCheckPolicyWindowRollsView() public {
        _record(900e18);
        // Same window: a further 200 exceeds daily.
        (IPolicyRegistry.PolicyDecision dHot,) = _check(200e18);
        assertEq(uint8(dHot), uint8(IPolicyRegistry.PolicyDecision.REJECT));
        // After the window elapses, the view computes a fresh (zero) window without writing.
        vm.warp(block.timestamp + 1 days + 1);
        (IPolicyRegistry.PolicyDecision dCold, uint256 rem) = _check(200e18);
        assertEq(uint8(dCold), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT)); // 200>=trigger
        assertEq(rem, 1000e18 - 200e18);
    }

    function test_C305_AssetWindowRollsAtExactBoundary() public {
        _record(900e18);
        (, uint64 windowStart) = reg.getAssetSpend(sender, asset);
        vm.warp(uint256(windowStart) + 1 days);
        (IPolicyRegistry.PolicyDecision d, uint256 rem) = _check(200e18);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));
        assertEq(rem, 800e18);
    }

    function test_C305_AssetPolicyEventReportsEffectiveWindow() public {
        IPolicyRegistry.AssetPolicyInput memory p = _ap(1, 2, 3, 0);
        vm.expectEmit(true, true, false, true, address(reg));
        emit AssetPolicySet(sender, asset, 1, 2, 3, 1 days);
        vm.prank(address(timelock));
        reg.setAssetPolicy(sender, asset, p);

        p.windowSeconds = 7 days;
        vm.expectEmit(true, true, false, true, address(reg));
        emit AssetPolicySet(sender, asset, 1, 2, 3, 7 days);
        vm.prank(address(timelock));
        reg.setAssetPolicy(sender, asset, p);
    }

    // ───────────────────────── Q5 governance: loosening only via timelock ─────────────────────────

    function testLooseningSetterRevertsForNonTimelock() public {
        IPolicyRegistry.AssetPolicyInput memory p = _ap(1, 1, 1, 1 days);
        vm.prank(governor); // governor is a timelock proposer but NOT the timelock itself
        vm.expectRevert(IPolicyRegistry.NotTimelock.selector);
        reg.setAssetPolicy(sender, asset, p);

        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotTimelock.selector);
        reg.setAssetPolicy(sender, asset, p);
    }

    function testLooseningEndToEndViaTimelock() public {
        // Raise the per-tx hard cap from 500 to 2000 through schedule→warp→execute.
        _setAssetPolicy(sender, asset, _ap(100e18, 2000e18, 1000e18, 1 days));
        IPolicyRegistry.AssetPolicy memory ap = reg.getAssetPolicy(sender, asset);
        assertEq(ap.perTxHardCap, 2000e18);
        // 600 now passes the cap (still under daily 1000, >= trigger → REQUIRE_DVT).
        (IPolicyRegistry.PolicyDecision d,) = _check(600e18);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));
    }

    function testUnfreezeOnlyViaTimelock() public {
        vm.prank(guardian);
        reg.freezeSender(sender);
        assertTrue(reg.isFrozen(sender));

        // Guardian cannot unfreeze (loosening).
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotTimelock.selector);
        reg.unfreezeSender(sender);

        // Timelock can.
        _viaTimelock(abi.encodeCall(IPolicyRegistry.unfreezeSender, (sender)));
        assertFalse(reg.isFrozen(sender));
    }

    // ───────────────────────── tightening / freeze: immediate by guardian ─────────────────────────

    function testTightenAssetImmediateByGuardian() public {
        vm.prank(guardian);
        reg.tightenAssetPolicy(sender, asset, _ap(50e18, 200e18, 400e18, 1 days));
        IPolicyRegistry.AssetPolicy memory ap = reg.getAssetPolicy(sender, asset);
        assertEq(ap.perTxHardCap, 200e18);
        assertEq(ap.dvtTriggerAmount, 50e18);
    }

    function testTightenRejectsLoosening() public {
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotStrictlyTighter.selector);
        reg.tightenAssetPolicy(sender, asset, _ap(100e18, 600e18, 1000e18, 1 days)); // cap raised
    }

    function testTightenRevertsForUnauthorized() public {
        vm.prank(stranger);
        vm.expectRevert(IPolicyRegistry.NotGuardianOrTimelock.selector);
        reg.tightenAssetPolicy(sender, asset, _ap(1, 1, 1, 1 days));
    }

    /// @notice GOVERNANCE INVARIANT (Codex PR #285 re-review): dvtTriggerAmount==0 is the
    ///         "DVT disabled" sentinel = LOOSEST value. Tightening a configured non-zero trigger
    ///         to 0 DISABLES DVT — a loosening that must go through the 2-day timelock, never the
    ///         guardian's instant path. The immediate tighten path must reject it.
    function testTightenCannotDisableDvtTriggerViaZero() public {
        // setUp configured dvtTriggerAmount = 100e18. Set it to 0 (disable) holding every other
        // dimension == current, so the ONLY change is the loosening-via-zero. Must revert.
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotStrictlyTighter.selector);
        reg.tightenAssetPolicy(sender, asset, _ap(0, 500e18, 1000e18, 1 days));

        // A genuine tighten — lower NON-zero trigger (DVT fires sooner) — still works.
        vm.prank(guardian);
        reg.tightenAssetPolicy(sender, asset, _ap(50e18, 500e18, 1000e18, 1 days));
    }

    /// @notice The MISSING HALF of the sentinel fix: tightening FROM a DISABLED (0) trigger TO a
    ///         concrete one is a genuine TIGHTEN (DVT now fires) and must SUCCEED. The naive
    ///         `params > cur` ordering wrongly rejected this because `50e18 > 0` looks like a
    ///         loosening; the sentinel map (0 → +∞) fixes it.
    function testTightenCanEnableDvtTriggerFromDisabledZero() public {
        // Move the asset to a DISABLED trigger via the (unconstrained) timelock loosening path.
        _setAssetPolicy(sender, asset, _ap(0, 500e18, 1000e18, 1 days));
        IPolicyRegistry.AssetPolicy memory disabled = reg.getAssetPolicy(sender, asset);
        assertEq(disabled.dvtTriggerAmount, 0);
        // While disabled, even a huge amount stays ALLOW (no amount-based DVT).
        (IPolicyRegistry.PolicyDecision dPre,) = _check(400e18);
        assertEq(uint8(dPre), uint8(IPolicyRegistry.PolicyDecision.ALLOW));

        // Guardian instantly tightens from disabled (0) to a concrete 50e18 trigger — must work.
        vm.prank(guardian);
        reg.tightenAssetPolicy(sender, asset, _ap(50e18, 500e18, 1000e18, 1 days));
        IPolicyRegistry.AssetPolicy memory enabled = reg.getAssetPolicy(sender, asset);
        assertEq(enabled.dvtTriggerAmount, 50e18);

        // checkPolicy now REQUIRE_DVTs at/above 50e18, and ALLOWs just below.
        (IPolicyRegistry.PolicyDecision dAt,) = _check(50e18);
        assertEq(uint8(dAt), uint8(IPolicyRegistry.PolicyDecision.REQUIRE_DVT));
        (IPolicyRegistry.PolicyDecision dBelow,) = _check(50e18 - 1);
        assertEq(uint8(dBelow), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
    }

    /// @notice Normal non-zero ordering still holds: lowering a live trigger tightens, raising it
    ///         loosens (revert). Pinned alongside the sentinel cases to lock the full ordering.
    function testTightenDvtTriggerNonZeroOrderingUnchanged() public {
        // Lower 100e18 → 40e18: genuine tighten, OK.
        vm.prank(guardian);
        reg.tightenAssetPolicy(sender, asset, _ap(40e18, 500e18, 1000e18, 1 days));
        assertEq(reg.getAssetPolicy(sender, asset).dvtTriggerAmount, 40e18);
        // Raise 40e18 → 120e18: loosening (DVT fires later), must revert.
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotStrictlyTighter.selector);
        reg.tightenAssetPolicy(sender, asset, _ap(120e18, 500e18, 1000e18, 1 days));
    }

    /// @notice A no-op tighten (params == cur on every dimension) must NOT revert — including the
    ///         sentinel corner case cur=0 → params=0 (disabled → disabled), where the 0→+∞ map
    ///         yields max == max (not strictly greater).
    function testTightenNoOpDoesNotRevert() public {
        // (1) no-op with a live non-zero trigger.
        vm.prank(guardian);
        reg.tightenAssetPolicy(sender, asset, _ap(100e18, 500e18, 1000e18, 1 days));
        assertEq(reg.getAssetPolicy(sender, asset).dvtTriggerAmount, 100e18);

        // (2) no-op with the DISABLED (0) sentinel: first disable via timelock, then 0→0 tighten.
        _setAssetPolicy(sender, asset, _ap(0, 500e18, 1000e18, 1 days));
        vm.prank(guardian);
        reg.tightenAssetPolicy(sender, asset, _ap(0, 500e18, 1000e18, 1 days));
        assertEq(reg.getAssetPolicy(sender, asset).dvtTriggerAmount, 0);
    }

    /// @notice velocityWindow is a SENTINEL (0 = velocity DISABLED = loosest) but is deliberately
    ///         IMMUTABLE on the instant tighten path: `params.velocityWindow` is IGNORED and the
    ///         stored window is preserved. Passing window=0 cannot disable velocity here.
    function testTightenContractScopeVelocityWindowImmutable() public {
        // setUp: target velocityWindow = 1 hours, velocityLimit = 800e18 (velocity ACTIVE).
        // Attempt to "tighten" while passing velocityWindow = 0 (which, if honored, would DISABLE
        // velocity = a loosening). The field must be ignored; the 1h window must survive.
        bytes4[] memory none = new bytes4[](0);
        vm.expectEmit(true, true, false, true, address(reg));
        emit ContractScopeSet(sender, target, true, false, 1 hours);
        vm.prank(guardian);
        reg.tightenContractScope(sender, target, _cs(true, false, 800e18, 0, none));
        IPolicyRegistry.ContractScope memory cs = reg.getTargetScope(sender, target);
        assertEq(cs.velocityWindow, 1 hours); // preserved, NOT disabled
        (uint128 limit, bool configured) = reg.getTargetVelocity(sender, target, asset);
        assertEq(limit, 800e18);
        assertTrue(configured);

        // Velocity is still enforced: spend up to the limit, then a push over it REJECTs.
        _record(750e18);
        (IPolicyRegistry.PolicyDecision d,) = _check(100e18); // 750+100 > 800 → REJECT
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    /// @notice velocityLimit has NO sentinel (0 = strictest), so lowering it tightens and raising
    ///         it reverts — independent of the (immutable-here) window.
    function testTightenContractScopeVelocityLimitOrdering() public {
        bytes4[] memory none = new bytes4[](0);
        // Lower 800e18 → 300e18: genuine tighten, OK.
        vm.prank(guardian);
        reg.tightenTargetVelocity(sender, target, asset, 300e18);
        (uint128 limit,) = reg.getTargetVelocity(sender, target, asset);
        assertEq(limit, 300e18);
        // Raise 300e18 → 900e18: loosening, must revert.
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotStrictlyTighter.selector);
        reg.tightenTargetVelocity(sender, target, asset, 900e18);
    }

    function testTightenCannotConfigureMissingAssetVelocity() public {
        bytes4[] memory none = new bytes4[](0);
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotStrictlyTighter.selector);
        reg.tightenTargetVelocity(sender, target, makeAddr("missingVelocityAsset"), 1);
    }

    function testTightenContractScopeRemovesSelector() public {
        // Tighten path removes the listed selector (the tighten direction of the additive set).
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        vm.prank(guardian);
        reg.tightenContractScope(sender, target, _cs(true, true, 800e18, 1 hours, sels));
        assertFalse(reg.isSelectorAllowed(sender, target, SEL));
        (IPolicyRegistry.PolicyDecision d,) = _check(10e18);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT)); // selector now removed
    }

    function testTightenSelectorAppliesToEveryAsset() public {
        address assetB = makeAddr("selectorAssetB");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        _setContractScopeForAsset(sender, target, assetB, _cs(true, false, 10, 1 hours, sels));

        vm.prank(guardian);
        reg.tightenContractScope(sender, target, _cs(true, false, 800e18, 1 hours, sels));

        (IPolicyRegistry.PolicyDecision decision,) =
            reg.checkPolicy(sender, target, assetB, 1, SEL);
        assertEq(uint8(decision), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function testTightenContractScopeCannotReallow() public {
        // First disallow the target via tighten.
        bytes4[] memory none = new bytes4[](0);
        vm.prank(guardian);
        reg.tightenContractScope(sender, target, _cs(false, false, 800e18, 1 hours, none));
        // Then attempting to re-allow through the immediate path must revert.
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotStrictlyTighter.selector);
        reg.tightenContractScope(sender, target, _cs(true, false, 800e18, 1 hours, none));
    }

    function testFreezeImmediateByGuardian() public {
        vm.prank(guardian);
        reg.freezeSender(sender);
        assertTrue(reg.isFrozen(sender));
    }

    function testFreezeRevertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(IPolicyRegistry.NotGuardianOrTimelock.selector);
        reg.freezeSender(sender);
    }

    // ───────────────────────── Q4 ETH sentinel ─────────────────────────

    function testEthSentinelAccepted() public {
        _setAssetPolicy(sender, ETH, _ap(1 ether, 10 ether, 50 ether, 1 days));
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL;
        address ethTarget = makeAddr("ethTarget");
        _setContractScopeForAsset(sender, ethTarget, ETH, _cs(true, false, 100 ether, 1 hours, sels));
        (IPolicyRegistry.PolicyDecision d, uint256 rem) =
            reg.checkPolicy(sender, ethTarget, ETH, 0.5 ether, SEL);
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.ALLOW));
        assertEq(rem, 50 ether - 0.5 ether);
    }

    function testZeroAddressAssetRejectedInCheck() public {
        vm.expectRevert(IPolicyRegistry.ZeroAddress.selector);
        reg.checkPolicy(sender, target, address(0), 1e18, SEL);
    }

    function testZeroAddressAssetRejectedInSetter() public {
        // Call the setter directly as the timelock to assert its own ZeroAddress guard.
        vm.prank(address(timelock));
        vm.expectRevert(IPolicyRegistry.ZeroAddress.selector);
        reg.setAssetPolicy(sender, address(0), _ap(1, 1, 1, 1 days));
    }

    // ───────────────────────── recordSpend consumer gating ─────────────────────────

    function testRecordSpendGatedToConsumer() public {
        vm.prank(stranger);
        vm.expectRevert(IPolicyRegistry.NotAuthorizedConsumer.selector);
        reg.recordSpend(sender, target, asset, 1e18, SEL);
    }

    function testConsumerAuthorizationOnlyTimelock() public {
        // stranger not authorized yet.
        assertFalse(reg.isAuthorizedConsumer(stranger));
        // direct call reverts.
        vm.prank(governor);
        vm.expectRevert(IPolicyRegistry.NotTimelock.selector);
        reg.setConsumerAuthorization(stranger, true);
        // via timelock works.
        _viaTimelock(abi.encodeCall(IPolicyRegistry.setConsumerAuthorization, (stranger, true)));
        assertTrue(reg.isAuthorizedConsumer(stranger));
    }

    // ───────────────────────── Q3 additive selectors ─────────────────────────

    function testAdditiveSelectors() public {
        bytes4 selB = bytes4(0x11223344);
        bytes4[] memory more = new bytes4[](1);
        more[0] = selB;
        // Second setContractScope adds selB WITHOUT removing the original SEL.
        _setContractScope(sender, target, _cs(true, false, 800e18, 1 hours, more));
        assertTrue(reg.isSelectorAllowed(sender, target, SEL));  // still allowed (additive)
        assertTrue(reg.isSelectorAllowed(sender, target, selB)); // newly added
    }

    function test_POL01_AssetVelocitySetterCannotChangeTargetGlobalScope() public {
        address assetB = makeAddr("globalIsolationAssetB");
        _viaTimelock(
            abi.encodeCall(IPolicyRegistry.setTargetVelocity, (sender, target, assetB, 123))
        );
        IPolicyRegistry.ContractScope memory scope = reg.getTargetScope(sender, target);
        assertTrue(scope.allowed);
        assertFalse(scope.requireDVTAlways);
        assertEq(scope.velocityWindow, 1 hours);
        (uint128 limit, bool configured) = reg.getTargetVelocity(sender, target, assetB);
        assertEq(limit, 123);
        assertTrue(configured);
    }

    // ───────────────────────── admin: setGuardian ─────────────────────────

    function testSetGuardianOnlyTimelock() public {
        address newG = makeAddr("newGuardian");
        vm.prank(guardian);
        vm.expectRevert(IPolicyRegistry.NotTimelock.selector);
        reg.setGuardian(newG);
        _viaTimelock(abi.encodeCall(IPolicyRegistry.setGuardian, (newG)));
        assertEq(reg.guardian(), newG);
    }

    function testConstructorRejectsZeroTimelockOrGuardian() public {
        vm.expectRevert(IPolicyRegistry.ZeroAddress.selector);
        new PolicyRegistry(address(0), guardian, consumer);
        vm.expectRevert(IPolicyRegistry.ZeroAddress.selector);
        new PolicyRegistry(address(timelock), address(0), consumer);
    }

    function testTimelockAndGuardianViews() public view {
        assertEq(reg.timelock(), address(timelock));
        assertEq(reg.guardian(), guardian);
        assertTrue(reg.isAuthorizedConsumer(consumer));
    }

    // ─────────────── 2.0.0 ABI break: stale consumers must fail loudly ───────────────

    /// @dev Reject both 1.0.0 setters (velocity embedded in the tuple) and the intermediate
    ///      four-argument setters/read introduced on this branch.
    function test_OldAbiScopeCalldataReverts() public {
        string[6] memory oldSigs = [
            "setContractScope(address,address,(bool,bool,uint128,uint64,bytes4[]))",
            "tightenContractScope(address,address,(bool,bool,uint128,uint64,bytes4[]))",
            "setContractScope(address,address,address,(bool,bool,uint128,uint64,bytes4[]))",
            "tightenContractScope(address,address,address,(bool,bool,uint128,uint64,bytes4[]))",
            "getContractScope(address,address,address)",
            // 1.0.0 getter: same calldata as before but a different return tuple, so it is renamed
            // (getTargetScope) and the old selector must revert instead of returning a shorter tuple.
            "getContractScope(address,address)"
        ];
        bytes4[] memory sels = new bytes4[](0);
        bytes memory oldTuple = abi.encode(false, false, uint128(0), uint64(1 hours), sels);
        for (uint256 i; i < oldSigs.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(oldSigs[i])));
            bytes memory data;
            if (i < 2) data = bytes.concat(sel, abi.encode(sender, target), oldTuple);
            else if (i < 4) data = bytes.concat(sel, abi.encode(sender, target, asset), oldTuple);
            else if (i == 4) data = abi.encodeWithSelector(sel, sender, target, asset);
            else data = abi.encodeWithSelector(sel, sender, target);
            assertTrue(sel != IPolicyRegistry.setContractScope.selector);
            assertTrue(sel != IPolicyRegistry.tightenContractScope.selector);
            assertTrue(sel != IPolicyRegistry.getTargetScope.selector);
            vm.prank(address(timelock));
            (bool ok,) = address(reg).call(data);
            assertFalse(ok, oldSigs[i]);
        }
        // The scope configured in setUp is untouched by the rejected calls.
        IPolicyRegistry.ContractScope memory cs = reg.getTargetScope(sender, target);
        assertTrue(cs.allowed);
        (uint128 limit, bool configured) = reg.getTargetVelocity(sender, target, asset);
        assertEq(limit, 800e18);
        assertTrue(configured);
    }
}
