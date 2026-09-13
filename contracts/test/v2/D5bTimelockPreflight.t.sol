// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { TimelockController } from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { V55Registry, V55PriceFeed } from "../helpers/V55TestFixtures.sol";
import { UpgradeViaTimelock } from "../../script/v3/UpgradeViaTimelock.s.sol";

/**
 * @title D5bTimelockPreflightTest — Codex D5b closing review (Medium)
 * @notice UpgradeViaTimelock.m1Preflight must reject a mis-configured GOV-1 timelock BEFORE any
 *         schedule / execute is broadcast, so an ownership hand-over can never complete on a wrong
 *         timelock and only then fail a post-condition. One positive path and one negative control per
 *         condition; each negative asserts the M1 batch was never scheduled and the owners / nominations
 *         are unchanged.
 */
contract D5bTimelockPreflightTest is Test {
    UpgradeViaTimelock script;
    SuperPaymaster sp;
    Registry reg;
    address deployer = address(0xDE9);   // the EOA that deployed / owns the proxies before M1
    address safe = address(0x51eD);      // governance Safe (anvil: pranked)
    address eoa = address(0xE0A);
    bytes32 constant SALT = keccak256("m1");

    function setUp() public {
        script = new UpgradeViaTimelock();
        V55Registry r = new V55Registry();
        vm.startPrank(deployer);
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032), IRegistry(address(r)), address(new V55PriceFeed()),
            deployer, address(0), deployer, 3600
        );
        reg = UUPSDeployHelper.deployRegistryProxy(deployer, address(0x5701), address(0x5B7));
        vm.stopPrank();
    }

    function _tl(uint256 delay, address[] memory proposers, address[] memory executors, address admin)
        internal returns (TimelockController tl)
    {
        tl = new TimelockController(delay, proposers, executors, admin);
        vm.startPrank(deployer); // M1 step ①: nominate the timelock on both proxies
        sp.transferOwnership(address(tl));
        reg.transferOwnership(address(tl));
        vm.stopPrank();
    }

    function _one(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory x) {
        x = new address[](2);
        x[0] = a;
        x[1] = b;
    }

    function _cfg(TimelockController tl) internal view returns (UpgradeViaTimelock.Cfg memory c) {
        c.sp = address(sp);
        c.registry = address(reg);
        c.timelock = address(tl);
    }

    function _forbidden() internal view returns (address[] memory) {
        return _two(deployer, eoa); // the deployer EOA (= old owner) and an extra known EOA
    }

    function _batchId(TimelockController tl) internal view returns (bytes32) {
        address[] memory t = new address[](3);
        t[0] = address(sp); t[1] = address(reg); t[2] = address(sp);
        uint256[] memory v = new uint256[](3);
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encodeWithSignature("acceptOwnership()");
        p[1] = abi.encodeWithSignature("acceptOwnership()");
        p[2] = abi.encodeWithSignature("setGuardian(address)", safe);
        return tl.hashOperationBatch(t, v, p, bytes32(0), SALT);
    }

    /// @dev The negative-control shape: the preflight reverts with `reason` inside scheduleAcceptWith,
    ///      nothing was scheduled, ownership / nominations untouched.
    function _assertRejectedBeforeSchedule(TimelockController tl, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, _forbidden());
        assertFalse(tl.isOperation(_batchId(tl)), "nothing scheduled");
        assertEq(sp.owner(), deployer, "SP owner unchanged");
        assertEq(reg.owner(), deployer, "Registry owner unchanged");
        assertEq(sp.pendingOwner(), address(tl), "SP nomination unchanged");
        assertEq(reg.pendingOwner(), address(tl), "Registry nomination unchanged");
    }

    // ------------------------------------------------------------------ positive

    function test_preflight_correct_timelock_passes_and_M1_completes() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        script.m1Preflight(tl, safe, _forbidden());
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, _forbidden());
        assertTrue(tl.isOperationPending(id), "scheduled");
        vm.warp(block.timestamp + 48 hours);
        script.executeAcceptWith(_cfg(tl), safe, SALT, safe, _forbidden());
        assertEq(sp.owner(), address(tl));
        assertEq(reg.owner(), address(tl));
        assertEq(sp.guardian(), safe);
    }

    /// @notice A non-Safe caller never broadcasts: it only gets the Safe's calldata.
    function test_non_safe_caller_does_not_schedule() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, eoa, _forbidden());
        assertFalse(tl.isOperation(_batchId(tl)), "no schedule from a non-Safe caller");
    }

    // ------------------------------------------------------------------ one negative control per condition

    function test_preflight_rejects_72h_delay() public {
        TimelockController tl = _tl(72 hours, _one(safe), _one(safe), address(0));
        _assertRejectedBeforeSchedule(tl, "M1 preflight: minDelay != 172800");
    }

    function test_preflight_rejects_open_executor() public {
        TimelockController tl = _tl(48 hours, _one(safe), _two(safe, address(0)), address(0));
        _assertRejectedBeforeSchedule(tl, "M1 preflight: executor role is OPEN (address(0))");
    }

    function test_preflight_rejects_deployer_still_admin() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), deployer);
        _assertRejectedBeforeSchedule(tl, "M1 preflight: external account holds DEFAULT_ADMIN_ROLE");
    }

    function test_preflight_rejects_safe_missing_canceller() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        vm.startPrank(address(tl)); // only the timelock administers its own roles (admin = none)
        tl.revokeRole(tl.CANCELLER_ROLE(), safe);
        vm.stopPrank();
        _assertRejectedBeforeSchedule(tl, "M1 preflight: Safe must hold PROPOSER, CANCELLER and EXECUTOR");
    }

    function test_preflight_rejects_extra_eoa_proposer() public {
        TimelockController tl = _tl(48 hours, _two(safe, eoa), _one(safe), address(0));
        _assertRejectedBeforeSchedule(tl, "M1 preflight: a forbidden account holds a timelock role");
    }

    /// @notice The preflight also runs immediately before the acceptance broadcast: a role granted
    ///         AFTER scheduling (here an extra executor) stops the execute, owners unchanged.
    function test_preflight_reruns_before_execute() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, _forbidden());
        vm.startPrank(address(tl));
        tl.grantRole(tl.EXECUTOR_ROLE(), eoa);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(bytes("M1 preflight: a forbidden account holds a timelock role"));
        script.executeAcceptWith(_cfg(tl), safe, SALT, safe, _forbidden());
        assertTrue(tl.isOperationReady(id), "batch still ready, not executed");
        assertEq(sp.owner(), deployer, "SP owner unchanged");
        assertEq(reg.owner(), deployer, "Registry owner unchanged");
    }
}
