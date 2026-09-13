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
 *         are unchanged. The preflight is a BOUNDED known-account check (OZ AccessControl is not
 *         enumerable): `test_preflight_is_bounded_unlisted_admin_passes` shows an admin that the manifest
 *         does not name passes it — that case is caught by script/governance/check-timelock-roles.mjs
 *         (event-history enumeration), whose anvil self-test is scripts/d5b-timelock-roles-selftest.sh.
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

    /// @dev The committed-manifest shape (M1 policy); mustHoldNothing = deployer (= old owner) + a known EOA.
    function _manifest(TimelockController tl) internal view returns (UpgradeViaTimelock.RoleManifest memory m) {
        m.timelock = address(tl);
        m.admins = _one(address(tl));
        m.proposers = _one(safe);
        m.cancellers = _one(safe);
        m.executors = _one(safe);
        m.mustHoldNothing = _two(deployer, eoa);
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
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, _manifest(tl));
        assertFalse(tl.isOperation(_batchId(tl)), "nothing scheduled");
        assertEq(sp.owner(), deployer, "SP owner unchanged");
        assertEq(reg.owner(), deployer, "Registry owner unchanged");
        assertEq(sp.pendingOwner(), address(tl), "SP nomination unchanged");
        assertEq(reg.pendingOwner(), address(tl), "Registry nomination unchanged");
    }

    // ------------------------------------------------------------------ positive

    function test_preflight_correct_timelock_passes_and_M1_completes() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        script.m1Preflight(tl, _manifest(tl));
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, _manifest(tl));
        assertTrue(tl.isOperationPending(id), "scheduled");
        vm.warp(block.timestamp + 48 hours);
        script.executeAcceptWith(_cfg(tl), safe, SALT, safe, _manifest(tl));
        assertEq(sp.owner(), address(tl));
        assertEq(reg.owner(), address(tl));
        assertEq(sp.guardian(), safe);
    }

    /// @notice A non-Safe caller never broadcasts: it only gets the Safe's calldata.
    function test_non_safe_caller_does_not_schedule() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, eoa, _manifest(tl));
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
        _assertRejectedBeforeSchedule(tl, "M1 preflight: a listed account holds DEFAULT_ADMIN_ROLE");
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
        _assertRejectedBeforeSchedule(tl, "M1 preflight: a listed account holds a timelock role");
    }

    /// @notice The preflight also runs immediately before the acceptance broadcast: a role granted
    ///         AFTER scheduling (here an extra executor) stops the execute, owners unchanged.
    function test_preflight_reruns_before_execute() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, _manifest(tl));
        vm.startPrank(address(tl));
        tl.grantRole(tl.EXECUTOR_ROLE(), eoa);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(bytes("M1 preflight: a listed account holds a timelock role"));
        script.executeAcceptWith(_cfg(tl), safe, SALT, safe, _manifest(tl));
        assertTrue(tl.isOperationReady(id), "batch still ready, not executed");
        assertEq(sp.owner(), deployer, "SP owner unchanged");
        assertEq(reg.owner(), deployer, "Registry owner unchanged");
    }

    // ------------------------------------------------------------------ manifest binding and the bound

    function test_preflight_rejects_manifest_for_another_timelock() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl);
        m.timelock = address(0xBEEF);
        vm.expectRevert(bytes("M1 preflight: manifest timelock != timelock"));
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m);
        assertFalse(tl.isOperation(_batchId(tl)), "nothing scheduled");
    }

    function test_preflight_rejects_manifest_not_m1_policy() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl);
        m.executors = _two(safe, eoa);
        vm.expectRevert(bytes("M1 preflight: manifest is not the M1 policy (admin=[timelock], P=C=E=[Safe])"));
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m);
    }

    function test_preflight_manifest_file_missing_reverts() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), address(0));
        // ENV unset -> "anvil"; no deployments/timelock-roles.anvil.json is committed (only the example schema)
        assertFalse(vm.isFile("deployments/timelock-roles.anvil.json"), "precondition: no anvil manifest committed");
        vm.expectRevert(bytes("M1 preflight: manifest deployments/timelock-roles.<ENV>.json missing"));
        script.manifestOf(_cfg(tl));
    }

    /// @notice DOCUMENTED BOUND: an admin the manifest does not name is invisible to the forge preflight
    ///         (AccessControl cannot enumerate holders). The preflight PASSES here; the event-history
    ///         checker (check-timelock-roles.mjs) is what catches it — see its anvil self-test.
    function test_preflight_is_bounded_unlisted_admin_passes() public {
        address unlisted = address(0xAD1);
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), unlisted);
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), unlisted), "precondition: an unlisted external admin exists");
        script.m1Preflight(tl, _manifest(tl)); // passes: bounded known-account check
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, _manifest(tl));
        assertTrue(tl.isOperationPending(id), "bounded: the forge preflight alone lets this timelock through");
    }
}
