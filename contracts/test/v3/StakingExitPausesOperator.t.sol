// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import {V55PriceFeed} from "../helpers/V55TestFixtures.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {SuperPaymasterLens} from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";

using SuperPaymasterAdminCalls for SuperPaymaster;

/// @dev Minimal factory/token boundary for configuring an operator through the public API.
contract ExitTokenFactory {
    function getTokenAddress(address) external view returns (address) { return address(this); }
    function BALANCE_MODE_VERSION() external pure returns (uint16) { return 1; }
}

contract GasBurningExitPaymaster {
    fallback() external { while (true) {} }
}

contract StakingExitPausesOperatorTest is Test {
    Registry registry;
    GTokenStaking staking;
    GToken gtoken;
    SuperPaymaster sp;
    V55PriceFeed oracle;
    address owner = address(0x101);
    address operator = address(0x104);
    address random = address(0x105);
    bytes32 constant SUPER_ROLE = keccak256("PAYMASTER_SUPER");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(owner);
        gtoken = new GToken(21_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        staking = new GTokenStaking(address(gtoken), owner, address(registry));
        MySBT sbt = new MySBT(address(gtoken), address(staking), address(registry), owner);
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

        oracle = new V55PriceFeed();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(0x123)), registry, address(oracle), owner, address(gtoken), owner, 4200
        );

        sp.setXPNTsFactory(address(new ExitTokenFactory()));
        sp.updatePrice();
        sp.updateReputation(operator, 100);
        gtoken.mint(operator, 10_000 ether);
        gtoken.mint(random, 10_000 ether);
        vm.stopPrank();
        _register(operator);
        vm.startPrank(operator);
        sp.configureOperator(sp.xpntsFactory(), operator);
        gtoken.approve(address(sp), 1000 ether);
        sp.depositFor(operator, 1000 ether);
        vm.stopPrank();
    }

    function _register(address user) internal {
        vm.startPrank(user);
        gtoken.approve(address(staking), type(uint256).max);
        registry.registerRole(keccak256("COMMUNITY"), user, abi.encode(
            Registry.CommunityRoleData({name: string(abi.encodePacked("Community", user)), ensName: "", stakeAmount: 30 ether})
        ));
        registry.registerRole(SUPER_ROLE, user, abi.encode(uint256(50 ether)));
        vm.stopPrank();
    }

    function _wire() internal {
        vm.prank(owner);
        registry.setSuperPaymaster(address(sp));
    }

    function _exit(address user, bytes32 role) internal {
        vm.warp(block.timestamp + 365 days);
        uint256 beforeBalance = gtoken.balanceOf(user);
        (, uint256 netAmount) = staking.previewExitFee(user, role);
        vm.prank(user);
        registry.exitRole(role);
        assertEq(gtoken.balanceOf(user), beforeBalance + netAmount);
        assertEq(staking.getLockedStake(user, role), 0);
    }

    function _op() internal view returns (PackedUserOperation memory op) {
        op.sender = operator;
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(350_000), uint128(200_000), operator);
    }

    /// The minimal op is rejected by validation even for an unpaused operator (no SBT, no lock),
    /// so the paused state is pinned through the lens reason, which checks the operator's pause
    /// flag before user eligibility. Positive control: before the pause the reason is not
    /// OPERATOR_PAUSED.
    function _lensReason() internal returns (bytes32 reason) {
        SuperPaymasterLens lens = new SuperPaymasterLens();
        (, reason) = lens.dryRunValidation(address(sp), _op(), 0);
    }

    function _assertPausedAndRejected() internal {
        (,, bool isPaused,,,,,,) = sp.operators(operator);
        assertTrue(isPaused);
        assertEq(_lensReason(), bytes32("OPERATOR_PAUSED"), "rejection is the operator pause");
        PackedUserOperation memory op;
        op.sender = operator;
        // Same operator encoding as SuperPaymasterV55Test._opFor.
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(350_000), uint128(200_000), operator);
        vm.prank(address(sp.entryPoint()));
        (bytes memory context, uint256 validationData) = sp.validatePaymasterUserOp(op, bytes32(0), 0);
        assertEq(context.length, 0);
        assertEq(uint160(validationData), 1, "SIG_VALIDATION_FAILED");
    }

    function test_ExitPausesBeforeReturningAndRejectsValidation() public {
        _wire();
        assertTrue(_lensReason() != bytes32("OPERATOR_PAUSED"), "control: not paused before exit");
        vm.expectCall(address(sp), abi.encodeWithSignature("pauseUnderstakedOperator(address)", operator), 1);
        vm.recordLogs();
        _exit(operator, SUPER_ROLE);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != GTokenStaking.OperatorPauseHookSkipped.selector, "no skip event on success");
        }
        // The successful real pause proves _hasEffectiveSuperStake was already false:
        // otherwise OperatorMeetsMinimumStake would revert and isPaused would stay false.
        assertFalse(registry.hasRole(SUPER_ROLE, operator));
        assertEq(registry.getEffectiveStake(operator, SUPER_ROLE), 0);
        _assertPausedAndRejected();
    }

    function test_ExitWithUnsetSuperPaymasterReturnsStake() public {
        assertEq(registry.SUPER_PAYMASTER(), address(0));
        vm.expectEmit(true, true, false, true, address(staking));
        emit GTokenStaking.OperatorPauseHookSkipped(operator, SUPER_ROLE, 1);
        _exit(operator, SUPER_ROLE);
    }

    function test_ExitWithCodelessSuperPaymasterReturnsStake() public {
        address codeless = makeAddr("codelessSuperPaymaster");
        assertEq(codeless.code.length, 0);
        vm.prank(owner);
        registry.setSuperPaymaster(codeless);
        vm.expectEmit(true, true, false, true, address(staking));
        emit GTokenStaking.OperatorPauseHookSkipped(operator, SUPER_ROLE, 2);
        _exit(operator, SUPER_ROLE);
    }

    function test_ExitWithUnconfiguredOperatorReturnsStake() public {
        _wire();
        _register(random);
        vm.expectCall(address(sp), abi.encodeWithSignature("pauseUnderstakedOperator(address)", random), 1);
        vm.expectEmit(true, true, false, true, address(staking));
        emit GTokenStaking.OperatorPauseHookSkipped(random, SUPER_ROLE, 3);
        _exit(random, SUPER_ROLE);
        (,, bool isPaused,,,,,,) = sp.operators(random);
        assertFalse(isPaused);
    }

    /// A paymaster that burns all gas it is given cannot block the exit, and the 40k cap bounds
    /// what the exit costs. Without the cap the call still leaves 1/64 of the gas, enough to finish,
    /// but the burner consumes ~63/64 of the 1M limit; the gasUsed bound pins the cap. Measured with
    /// the cap: ~228k (Cancun), ~340k (Amsterdam), so the bound holds on both engines.
    function test_GasExhaustingHookCannotBlockExit() public {
        address burner = address(new GasBurningExitPaymaster());
        vm.prank(owner);
        registry.setSuperPaymaster(burner);
        vm.warp(block.timestamp + 365 days);
        uint256 beforeBalance = gtoken.balanceOf(operator);
        vm.prank(operator);
        uint256 g0 = gasleft();
        (bool ok,) = address(registry).call{gas: 1_000_000}(abi.encodeCall(Registry.exitRole, (SUPER_ROLE)));
        uint256 used = g0 - gasleft();
        assertTrue(ok, "exit completes within a realistic gas limit");
        assertLt(used, 500_000, "the hook's gas cap bounds the exit cost");
        assertGt(gtoken.balanceOf(operator), beforeBalance, "stake returned");
    }

    /// Property check, not evidence for the guard: at every gas limit the exit either reverts
    /// (InsufficientGasForPauseHook or OOG) or completes with the operator paused. The 2k step over
    /// warm storage passes with or without the guard; test_GasGuardRevertsByName pins the guard.
    function test_TightGasCannotSkipThePause() public {
        _wire();
        vm.warp(block.timestamp + 365 days);
        uint256 completed;
        // Upper end covers Amsterdam, where the exit costs ~110k more than on Cancun.
        for (uint256 g = 90_000; g <= 600_000; g += 2_000) {
            uint256 snap = vm.snapshot();
            vm.prank(operator);
            (bool ok,) = address(registry).call{gas: g}(abi.encodeCall(Registry.exitRole, (SUPER_ROLE)));
            if (ok) {
                ++completed;
                (,, bool isPaused,,,,,,) = sp.operators(operator);
                assertTrue(isPaused, "a completed exit always paused the operator");
            }
            vm.revertTo(snap);
        }
        assertGt(completed, 0, "control: some gas limit in range completes the exit");
    }

    /// The guard itself: with too little gas left at the hook, unlockAndTransfer reverts by name
    /// instead of letting the capped pause call starve. (With today's code the starvation is not
    /// reachable through exitRole -- test_TightGasCannotSkipThePause -- so the guard is defence in
    /// depth; this test is what pins it.)
    function test_GasGuardRevertsByName() public {
        _wire();
        vm.warp(block.timestamp + 365 days);
        // unlockAndTransfer is called directly as the Registry, so the Registry still records the
        // SUPER role here; the guard only depends on the staking lock and the gas left.
        vm.prank(operator);
        registry.exitRole(keccak256("COMMUNITY")); // no-op for the SUPER lock; keeps setup realistic
        bool sawGuard;
        for (uint256 g = 40_000; g <= 200_000 && !sawGuard; g += 1_000) {
            uint256 snap = vm.snapshot();
            vm.prank(address(registry));
            (bool ok, bytes memory ret) =
                address(staking).call{gas: g}(abi.encodeCall(GTokenStaking.unlockAndTransfer, (operator, SUPER_ROLE)));
            if (!ok && ret.length >= 4 && bytes4(ret) == GTokenStaking.InsufficientGasForPauseHook.selector) sawGuard = true;
            vm.revertTo(snap);
        }
        assertTrue(sawGuard, "some gas limit reaches the hook with less than PAUSE_HOOK_MIN_GAS left");
    }

    /// A staked role other than PAYMASTER_SUPER reaches unlockAndTransfer but not the hook.
    /// (COMMUNITY has minStake 0, so its exit never reaches unlockAndTransfer at all.)
    function test_OtherRoleExitDoesNotCallPause() public {
        _wire();
        bytes32 aoa = keccak256("PAYMASTER_AOA");
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(aoa);
        vm.prank(operator);
        registry.registerRole(aoa, operator, abi.encode(cfg.minStake));
        assertGt(staking.getLockedStake(operator, aoa), 0, "precondition: AOA exit unlocks stake");
        vm.expectCall(address(sp), abi.encodeWithSignature("pauseUnderstakedOperator(address)", operator), 0);
        _exit(operator, aoa);
    }

    function test_RaisedMinimumPermissionlessPauseRejectsValidation() public {
        assertTrue(_lensReason() != bytes32("OPERATOR_PAUSED"), "control: not paused before");
        IRegistry.RoleConfig memory config = registry.getRoleConfig(SUPER_ROLE);
        config.minStake = 100 ether;
        vm.prank(owner);
        registry.configureRole(SUPER_ROLE, config);
        assertTrue(registry.hasRole(SUPER_ROLE, operator));
        vm.prank(random);
        sp.pauseUnderstakedOperator(operator);
        _assertPausedAndRejected();
    }

    function test_ExitedOperatorCannotDepositOrConfigure() public {
        _wire();
        _exit(operator, SUPER_ROLE);
        address token = sp.xpntsFactory();
        vm.startPrank(operator);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.deposit(1);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.depositFor(operator, 1);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.configureOperator(token, operator);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setOperatorLimits(1);
        vm.stopPrank();
    }
}
