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
        pure
        returns (IPolicyRegistry.ContractScopeInput memory)
    {
        return IPolicyRegistry.ContractScopeInput(allowed, dvtAlways, vLimit, vWin, sels);
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
        _viaTimelock(abi.encodeCall(IPolicyRegistry.setContractScope, (s, t, p)));
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
        (uint128 spent,) = reg.getAssetSpend(sender, asset);
        assertEq(spent, 120e18);
        // target velocity counter advanced too: pushing past 800 now rejects.
        (IPolicyRegistry.PolicyDecision d,) = reg.checkPolicy(sender, target, asset, 700e18, SEL);
        // daily: 120+700=820<1000 ok; velocity: 120+700=820>800 → REJECT.
        assertEq(uint8(d), uint8(IPolicyRegistry.PolicyDecision.REJECT));
    }

    function testRecordSpendWindowRolls() public {
        _record(300e18);
        (uint128 s1, uint64 w1) = reg.getAssetSpend(sender, asset);
        assertEq(s1, 300e18);
        // Advance past the 1-day window; next record opens a fresh window.
        vm.warp(block.timestamp + 1 days + 1);
        _record(50e18);
        (uint128 s2, uint64 w2) = reg.getAssetSpend(sender, asset);
        assertEq(s2, 50e18); // rolled, not 350
        assertGt(w2, w1);
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
        _setContractScope(sender, ethTarget, _cs(true, false, 100 ether, 1 hours, sels));
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
}
