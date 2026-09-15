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
 * @title D5bTimelockPreflightTest — M1 preflight + roles-attestation check of UpgradeViaTimelock
 * @dev   These test an OPERATOR PREFLIGHT, not an enforcement boundary (Codex re-check of 626b6ea8):
 *        it binds only the script run; the attestation is unsigned; the Safe can submit calldata without it.
 *        `test_hand_made_pass_attestation_omitting_a_holder_is_accepted` states that limit as a test.
 * @notice UpgradeViaTimelock.m1Preflight stops the operator's script run on a mis-configured GOV-1
 *         timelock BEFORE it broadcasts (or prints) a schedule / execute. One positive path and one
 *         negative control per condition; each negative asserts the M1 batch was not scheduled by the
 *         script and the owners / nominations are unchanged. The preflight is a BOUNDED known-account
 *         check (OZ AccessControl is not enumerable): an admin the manifest does not name passes it
 *         (`test_bounded_preflight_passes_unlisted_admin_genuine_attestation_stops_the_operator`); the
 *         event-history checker (script/governance/check-timelock-roles.mjs, self-test
 *         scripts/d5b-timelock-roles-selftest.sh) sees it, as an operator check.
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

    // ------------------------------------------------------------------ manifest + attestation helpers

    bytes32 constant MANIFEST_KECCAK = keccak256("d5b-test-manifest-v1"); // stands in for the file bytes
    string constant ATT_DIR = "cache/d5b-attestations/";

    function _addrs(address[] memory a) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < a.length; ++i) out = string.concat(out, i == 0 ? "" : ",", "\"", vm.toString(a[i]), "\"");
        out = string.concat(out, "]");
    }

    struct Att {
        string schema;
        bytes32 headHash; // 0 = omit the field
        string result;
        uint256 chainId;
        address timelock;
        bytes32 manifestKeccak;
        uint256 head;
        address[] admins;
        address[] proposers;
        uint256 manifestChainId; // attested manifest values (the checker writes them as decimal strings)
        uint256 deploymentBlock;
        address[] mustHoldNothing;
        string[] labels;
    }

    function _goodAtt(TimelockController tl) internal view returns (Att memory a) {
        a.schema = "d5b-timelock-roles-attestation/2";
        a.headHash = keccak256("head block hash (unverifiable at the current block)");
        a.result = "PASS";
        a.chainId = block.chainid;
        a.timelock = address(tl);
        a.manifestKeccak = MANIFEST_KECCAK;
        a.head = block.number;
        a.admins = _one(address(tl));
        a.proposers = _one(safe);
        a.manifestChainId = block.chainid;
        a.deploymentBlock = block.number;
        a.mustHoldNothing = _two(deployer, eoa);
        a.labels = new string[](2);
        a.labels[0] = "deployer / old owner";
        a.labels[1] = "ops EOA";
    }

    function _strs(string[] memory a) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < a.length; ++i) out = string.concat(out, i == 0 ? "" : ",", "\"", a[i], "\"");
        out = string.concat(out, "]");
    }

    /// @dev Same shape as check-timelock-roles.mjs --attest (only the fields the preflight reads).
    function _writeAtt(string memory name, Att memory a) internal returns (string memory path) {
        path = string.concat(ATT_DIR, name, ".json");
        string memory j = string.concat(
            "{\"schema\":\"", a.schema, "\",\"result\":\"", a.result,
            "\",\"chainId\":", vm.toString(a.chainId),
            ",\"timelock\":\"", vm.toString(a.timelock),
            "\",\"manifestKeccak256\":\"", vm.toString(a.manifestKeccak),
            "\",\"headBlock\":", vm.toString(a.head),
            a.headHash == bytes32(0) ? "" : string.concat(",\"headBlockHash\":\"", vm.toString(a.headHash), "\"")
        );
        j = string.concat(j,
            ",\"roles\":{\"DEFAULT_ADMIN_ROLE\":", _addrs(a.admins),
            ",\"PROPOSER_ROLE\":", _addrs(a.proposers),
            ",\"CANCELLER_ROLE\":", _addrs(_one(safe)),
            ",\"EXECUTOR_ROLE\":", _addrs(_one(safe)), "}"
        );
        j = string.concat(j,
            ",\"manifestChainId\":\"", vm.toString(a.manifestChainId), "\",\"deploymentBlock\":\"", vm.toString(a.deploymentBlock),
            "\",\"mustHoldNothing\":", _addrs(a.mustHoldNothing), ",\"mustHoldNothingLabels\":", _strs(a.labels), "}"
        );
        vm.createDir(ATT_DIR, true);
        vm.writeFile(path, j);
    }

    /// @dev The committed-manifest shape (M1 policy) + a valid attestation written under a unique name.
    function _manifest(TimelockController tl, string memory name)
        internal returns (UpgradeViaTimelock.RoleManifest memory m)
    {
        m.chainId = block.chainid;
        m.timelock = address(tl);
        m.deploymentBlock = block.number;
        m.admins = _one(address(tl));
        m.proposers = _one(safe);
        m.cancellers = _one(safe);
        m.executors = _one(safe);
        m.mustHoldNothing = _two(deployer, eoa);
        m.mustHoldNothingLabels = new string[](2);
        m.mustHoldNothingLabels[0] = "deployer / old owner";
        m.mustHoldNothingLabels[1] = "ops EOA";
        m.fileKeccak = MANIFEST_KECCAK;
        m.attestation = _writeAtt(name, _goodAtt(tl));
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

    /// @dev The negative-control shape: the preflight reverts with `reason` inside scheduleAcceptWith, nothing
    ///      was scheduled, ownership / nominations untouched.
    function _assertRejected(TimelockController tl, UpgradeViaTimelock.RoleManifest memory m, string memory reason) internal {
        vm.expectRevert(bytes(reason));
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m);
        assertFalse(tl.isOperation(_batchId(tl)), "nothing scheduled");
        assertEq(sp.owner(), deployer, "SP owner unchanged");
        assertEq(reg.owner(), deployer, "Registry owner unchanged");
        assertEq(sp.pendingOwner(), address(tl), "SP nomination unchanged");
        assertEq(reg.pendingOwner(), address(tl), "Registry nomination unchanged");
    }

    function _correctTl() internal returns (TimelockController) {
        return _tl(48 hours, _one(safe), _one(safe), address(0));
    }

    // ------------------------------------------------------------------ positive

    function test_preflight_correct_timelock_passes_and_M1_completes() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "positive");
        script.operatorPreflight(tl, m);
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m);
        assertTrue(tl.isOperationPending(id), "scheduled");
        vm.warp(block.timestamp + 48 hours);
        script.executeAcceptWith(_cfg(tl), safe, SALT, safe, m);
        assertEq(sp.owner(), address(tl));
        assertEq(reg.owner(), address(tl));
        assertEq(sp.guardian(), safe);
    }

    /// @notice A non-Safe caller never broadcasts: it only gets the Safe's calldata.
    function test_non_safe_caller_does_not_schedule() public {
        TimelockController tl = _correctTl();
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, eoa, _manifest(tl, "nonsafe"));
        assertFalse(tl.isOperation(_batchId(tl)), "no schedule from a non-Safe caller");
    }

    // ------------------------------------------------------------------ preflight: one negative per condition

    function test_preflight_rejects_72h_delay() public {
        TimelockController tl = _tl(72 hours, _one(safe), _one(safe), address(0));
        _assertRejected(tl, _manifest(tl, "d72"), "M1 preflight: minDelay != 172800");
    }

    function test_preflight_rejects_open_executor() public {
        TimelockController tl = _tl(48 hours, _one(safe), _two(safe, address(0)), address(0));
        _assertRejected(tl, _manifest(tl, "open"), "M1 preflight: executor role is OPEN (address(0))");
    }

    function test_preflight_rejects_deployer_still_admin() public {
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), deployer);
        _assertRejected(tl, _manifest(tl, "depadmin"), "M1 preflight: a listed account holds DEFAULT_ADMIN_ROLE");
    }

    function test_preflight_rejects_safe_missing_canceller() public {
        TimelockController tl = _correctTl();
        vm.startPrank(address(tl)); // only the timelock administers its own roles (admin = none)
        tl.revokeRole(tl.CANCELLER_ROLE(), safe);
        vm.stopPrank();
        _assertRejected(tl, _manifest(tl, "nocancel"), "M1 preflight: Safe must hold PROPOSER, CANCELLER and EXECUTOR");
    }

    function test_preflight_rejects_extra_eoa_proposer() public {
        TimelockController tl = _tl(48 hours, _two(safe, eoa), _one(safe), address(0));
        _assertRejected(tl, _manifest(tl, "eoaprop"), "M1 preflight: a listed account holds a timelock role");
    }

    /// @notice The preflight also runs immediately before the acceptance broadcast: a role granted AFTER
    ///         scheduling (here an extra executor) stops the execute, owners unchanged.
    function test_preflight_reruns_before_execute() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "rerun");
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m);
        vm.startPrank(address(tl));
        tl.grantRole(tl.EXECUTOR_ROLE(), eoa);
        vm.stopPrank();
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(bytes("M1 preflight: a listed account holds a timelock role"));
        script.executeAcceptWith(_cfg(tl), safe, SALT, safe, m);
        assertTrue(tl.isOperationReady(id), "batch still ready, not executed");
        assertEq(sp.owner(), deployer, "SP owner unchanged");
        assertEq(reg.owner(), deployer, "Registry owner unchanged");
    }

    function test_preflight_rejects_manifest_for_another_timelock() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "othertl");
        m.timelock = address(0xBEEF);
        _assertRejected(tl, m, "M1 preflight: manifest timelock != timelock");
    }

    function test_preflight_rejects_manifest_not_m1_policy() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "notm1");
        m.executors = _two(safe, eoa);
        _assertRejected(tl, m, "M1 preflight: manifest is not the M1 policy (admin=[timelock], P=C=E=[Safe])");
    }

    function test_preflight_manifest_file_missing_reverts() public {
        TimelockController tl = _correctTl();
        // ENV unset -> "anvil"; no deployments/timelock-roles.anvil.json is committed (only the example schema)
        assertFalse(vm.isFile("deployments/timelock-roles.anvil.json"), "precondition: no anvil manifest committed");
        vm.expectRevert(bytes("M1 preflight: manifest deployments/timelock-roles.<ENV>.json missing"));
        script.manifestOf(_cfg(tl));
    }

    // ------------------------------------------------------------------ the bounds of the preflight, stated as tests

    /// @notice BOUND 1: an admin the manifest does not name is invisible to the forge preflight
    ///         (AccessControl cannot enumerate holders): m1Preflight PASSES. A genuine checker attestation
    ///         for this timelock is FAIL (anvil self-test step 2) and stops the operator; a PASS that lists
    ///         the admin is stopped because the attested set != the manifest.
    function test_bounded_preflight_passes_unlisted_admin_genuine_attestation_stops_the_operator() public {
        address unlisted = address(0xAD1);
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), unlisted);
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), unlisted), "precondition: an unlisted external admin exists");
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "unlisted");
        script.m1Preflight(tl, m); // passes: bounded known-account check
        Att memory a = _goodAtt(tl);
        a.result = "FAIL"; // what the checker writes for this timelock ...
        a.admins = _two(address(tl), unlisted); // ... with the admin it found in the event history
        m.attestation = _writeAtt("unlisted-fail", a);
        _assertRejected(tl, m, "roles attestation: result != PASS");
        a.result = "PASS"; // a PASS that still lists the admin
        m.attestation = _writeAtt("unlisted-listed", a);
        _assertRejected(tl, m, "roles attestation: attested DEFAULT_ADMIN_ROLE holders != manifest");
    }

    /// @notice BOUND 2 (Codex re-check of 626b6ea8, H2): the attestation is UNSIGNED. A hand-made PASS
    ///         that simply omits the unlisted admin satisfies every check — the preflight lets the operator
    ///         schedule while an unlisted admin exists. This is why the preflight is not a security
    ///         boundary; the on-chain basis is the timelock's self-administration + monitoring (§6.3d).
    function test_hand_made_pass_attestation_omitting_a_holder_is_accepted() public {
        address unlisted = address(0xAD1);
        TimelockController tl = _tl(48 hours, _one(safe), _one(safe), unlisted);
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "handmade"); // PASS, admins == [timelock]
        script.operatorPreflight(tl, m);
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m);
        assertTrue(tl.isOperationPending(id), "scheduled despite the unlisted admin");
        assertTrue(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), unlisted), "the unlisted admin still holds DEFAULT_ADMIN_ROLE");
    }

    // ------------------------------------------------------------------ attestation check: one negative per condition

    function test_attestation_missing_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "missing");
        m.attestation = "";
        _assertRejected(tl, m, "roles attestation: missing (set TL_ROLES_ATTESTATION to the check-timelock-roles.mjs output)");
    }

    function test_attestation_wrong_chainid_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "chainid");
        Att memory a = _goodAtt(tl);
        a.chainId = 11155111;
        m.attestation = _writeAtt("chainid-bad", a);
        _assertRejected(tl, m, "roles attestation: chainId != this chain");
    }

    function test_attestation_wrong_timelock_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "tlmis");
        Att memory a = _goodAtt(tl);
        a.timelock = address(0xBEEF);
        m.attestation = _writeAtt("tlmis-bad", a);
        _assertRejected(tl, m, "roles attestation: timelock mismatch");
    }

    function test_attestation_stale_head_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "stale"); // head = current block
        vm.roll(block.number + 301);
        _assertRejected(tl, m, "roles attestation: stale");
    }

    function test_attestation_manifest_changed_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "mchanged");
        m.fileKeccak = keccak256("d5b-test-manifest-v2"); // the manifest file was edited after attesting
        _assertRejected(tl, m, "roles attestation: manifest changed after the attestation");
    }

    function test_attestation_result_fail_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "failres");
        Att memory a = _goodAtt(tl);
        a.result = "FAIL";
        m.attestation = _writeAtt("failres-bad", a);
        _assertRejected(tl, m, "roles attestation: result != PASS");
    }

    function test_attestation_holder_set_not_manifest_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "holders");
        Att memory a = _goodAtt(tl);
        a.proposers = _two(safe, eoa);
        m.attestation = _writeAtt("holders-bad", a);
        _assertRejected(tl, m, "roles attestation: attested PROPOSER_ROLE holders != manifest");
    }

    function test_attestation_opt_out_rejected_on_live_chain() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "optout-live");
        m.attestation = "";
        m.optOut = true;
        vm.chainId(10); // OP mainnet
        m.chainId = 10; // a correct OP-mainnet manifest: only the opt-out is wrong
        _assertRejected(tl, m, "roles attestation: opt-out is impossible on a live chain");
    }

    function test_attestation_opt_out_allowed_on_local_chain_only() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "optout-local");
        m.attestation = "";
        m.optOut = true;
        assertEq(block.chainid, 31337, "precondition: local chain id");
        bytes32 id = script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m); // loudly logged, proceeds
        assertTrue(tl.isOperationPending(id), "opt-out works on a local chain");
    }

    // ------------------------------------------------------------------ Codex re-check M1 / M3: manifest chainId + completeness

    function test_manifest_chainid_mismatch_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "mchain");
        m.chainId = 11155111; // a Sepolia manifest used against this chain
        _assertRejected(tl, m, "M1 manifest: chainId != this chain");
    }

    /// @notice Every way a manifest can be vacuous is rejected before anything is scheduled.
    function test_manifest_vacuous_fields_each_rejected() public {
        TimelockController tl = _correctTl();
        string[12] memory reasons = [
            "M1 manifest: chainId != this chain",           // 0 chainId missing (0)
            "M1 manifest: zero timelock",                   // 1 timelock missing (0)
            "M1 manifest: deploymentBlock unset",           // 2
            "M1 manifest: empty role set",                  // 3 DEFAULT_ADMIN_ROLE []
            "M1 manifest: empty role set",                  // 4 PROPOSER_ROLE []
            "M1 manifest: empty role set",                  // 5 CANCELLER_ROLE []
            "M1 manifest: empty role set",                  // 6 EXECUTOR_ROLE []
            "M1 manifest: mustHoldNothing is empty",        // 7
            "M1 manifest: one label per mustHoldNothing account", // 8 labels missing
            "M1 manifest: empty mustHoldNothing label",     // 9
            "M1 manifest: zero address in mustHoldNothing", // 10
            "M1 manifest: duplicate in mustHoldNothing"     // 11
        ];
        for (uint256 k; k < reasons.length; ++k) {
            UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, string.concat("vac", vm.toString(k)));
            if (k == 0) m.chainId = 0;
            if (k == 1) m.timelock = address(0);
            if (k == 2) m.deploymentBlock = 0;
            if (k == 3) m.admins = new address[](0);
            if (k == 4) m.proposers = new address[](0);
            if (k == 5) m.cancellers = new address[](0);
            if (k == 6) m.executors = new address[](0);
            if (k == 7) { m.mustHoldNothing = new address[](0); m.mustHoldNothingLabels = new string[](0); }
            if (k == 8) m.mustHoldNothingLabels = new string[](0);
            if (k == 9) m.mustHoldNothingLabels[1] = "";
            if (k == 10) m.mustHoldNothing[1] = address(0);
            if (k == 11) m.mustHoldNothing[1] = deployer;
            _assertRejected(tl, m, reasons[k]);
        }
    }

    /// @dev The committed file shape, optionally without field `omit` (10 = complete). Field order:
    ///      0 network, 1 chainId, 2 timelock, 3 deploymentBlock, 4-7 roles.*, 8 mustHoldNothing, 9 labels.
    function _body(TimelockController tl, uint256 omit) internal view returns (string memory j) {
        return _bodyWith(tl, omit, false);
    }

    function _bodyWith(TimelockController tl, uint256 omit, bool extraRole) internal view returns (string memory j) {
        return _bodyRaw(tl, omit, extraRole, string.concat("\"", vm.toString(block.chainid), "\""), "\"1\"");
    }

    /// @dev `chainRaw` / `blockRaw` are the raw JSON values of chainId / deploymentBlock (canonical: "\"123\"").
    function _bodyRaw(TimelockController tl, uint256 omit, bool extraRole, string memory chainRaw, string memory blockRaw)
        internal view returns (string memory j)
    {
        string[10] memory k = ["network", "chainId", "timelock", "deploymentBlock", "DEFAULT_ADMIN_ROLE",
            "PROPOSER_ROLE", "CANCELLER_ROLE", "EXECUTOR_ROLE", "mustHoldNothing", "mustHoldNothingLabels"];
        string[10] memory v = [
            "\"n\"", chainRaw, string.concat("\"", vm.toString(address(tl)), "\""),
            blockRaw, _addrs(_one(address(tl))), _addrs(_one(safe)), _addrs(_one(safe)), _addrs(_one(safe)),
            _addrs(_two(deployer, eoa)), "[\"deployer\",\"ops\"]"
        ];
        string memory top;
        string memory roles;
        for (uint256 i; i < 10; ++i) {
            if (i == omit) continue;
            string memory kv = string.concat("\"", k[i], "\":", v[i]);
            if (i >= 4 && i <= 7) roles = string.concat(roles, bytes(roles).length == 0 ? "" : ",", kv);
            else top = string.concat(top, bytes(top).length == 0 ? "" : ",", kv);
        }
        if (extraRole) roles = string.concat(roles, ",\"GUARDIAN_ROLE\":", _addrs(_one(eoa)));
        j = string.concat("{", top, ",\"roles\":{", roles, "}}");
    }

    /// @notice The committed file must carry every schema field: omitting any one is a named revert, not
    ///         an empty (vacuously satisfied) set. Positive control: the complete body parses and validates.
    function test_manifest_file_missing_field_each_rejected() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory ok = script.parseManifest(_body(tl, 10));
        script.validateManifest(ok);
        assertEq(ok.mustHoldNothingLabels.length, 2, "positive control: labels parsed");
        assertEq(ok.chainId, block.chainid, "positive control: chainId parsed");
        assertEq(ok.timelock, address(tl), "positive control: timelock parsed");
        string[10] memory paths = [".network", ".chainId", ".timelock", ".deploymentBlock", ".roles.DEFAULT_ADMIN_ROLE",
            ".roles.PROPOSER_ROLE", ".roles.CANCELLER_ROLE", ".roles.EXECUTOR_ROLE", ".mustHoldNothing", ".mustHoldNothingLabels"];
        for (uint256 i; i < 10; ++i) {
            vm.expectRevert(bytes(string.concat("M1 manifest: missing field ", paths[i])));
            script.parseManifest(_body(tl, i));
        }
    }

    /// @notice The committed example (FAKE placeholder addresses) can never be used as a network manifest.
    function test_manifest_example_placeholder_refused() public {
        string memory j = vm.readFile("deployments/timelock-roles.example.json");
        vm.expectRevert(bytes("M1 manifest: placeholder (the example schema with FAKE addresses) - not a network manifest"));
        script.parseManifest(j);
    }

    // ------------------------------------------------------------------ Codex re-check L1: governed non-upgrade calls

    function _m1Done(string memory name) internal returns (TimelockController tl, UpgradeViaTimelock.RoleManifest memory m) {
        tl = _correctTl();
        m = _manifest(tl, name);
        script.scheduleAcceptWith(_cfg(tl), safe, SALT, safe, m);
        vm.warp(block.timestamp + 48 hours);
        script.executeAcceptWith(_cfg(tl), safe, SALT, safe, m);
    }

    /// @notice The runbook M2 unpause runs the same operator preflight: guardian pauses, the Safe schedules
    ///         the unpause via scheduleCallWith, 48h, executeCallWith; without an attestation the script stops.
    function test_governed_call_unpause_runs_operator_preflight() public {
        (TimelockController tl, UpgradeViaTimelock.RoleManifest memory m) = _m1Done("m2");
        vm.prank(safe);
        SuperPaymasterAdmin(address(sp)).setGlobalPaused(true);
        assertTrue(sp.paused(), "guardian paused");
        bytes memory unpause = abi.encodeWithSignature("setGlobalPaused(bool)", false);
        bytes32 id = tl.hashOperation(address(sp), 0, unpause, bytes32(0), SALT);
        string memory att = m.attestation;
        m.attestation = "";
        vm.expectRevert(bytes("roles attestation: missing (set TL_ROLES_ATTESTATION to the check-timelock-roles.mjs output)"));
        script.scheduleCallWith(_cfg(tl), true, unpause, SALT, safe, m);
        assertFalse(tl.isOperation(id), "nothing scheduled without the attestation");
        m.attestation = att;
        script.scheduleCallWith(_cfg(tl), true, unpause, SALT, safe, m);
        assertTrue(tl.isOperationPending(id), "unpause scheduled after the preflight");
        vm.warp(block.timestamp + 48 hours);
        script.executeCallWith(_cfg(tl), true, unpause, SALT, safe, m);
        assertFalse(sp.paused(), "timelock unpaused");
    }

    function test_governed_call_refuses_upgrade() public {
        (TimelockController tl, UpgradeViaTimelock.RoleManifest memory m) = _m1Done("noupg");
        bytes memory upg = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0x1234), bytes(""));
        vm.expectRevert(bytes("governed call: use schedule-upgrade for upgrades"));
        script.scheduleCallWith(_cfg(tl), true, upg, SALT, safe, m);
        assertFalse(tl.isOperation(tl.hashOperation(address(sp), 0, upg, bytes32(0), SALT)), "nothing scheduled");
    }

    // ------------------------------------------------------------------ Codex re-check of 626b6ea8 (Medium / operator safety)

    function test_attestation_wrong_schema_reverts() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "schema");
        Att memory a = _goodAtt(tl);
        a.schema = "d5b-timelock-roles-attestation/1"; // the pre-626b6ea8 format
        m.attestation = _writeAtt("schema-bad", a);
        _assertRejected(tl, m, "roles attestation: schema != d5b-timelock-roles-attestation/2");
    }

    /// @notice Labels are trimmed like the checker's String.trim(): whitespace-only is empty.
    function test_manifest_whitespace_only_label_rejected() public {
        TimelockController tl = _correctTl();
        string[6] memory blanks = [" ", "\t\n \r", "\u00a0", "\u3000 ", "\ufeff", "\u2003\u205f"];
        for (uint256 k; k < blanks.length; ++k) {
            UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, string.concat("blank", vm.toString(k)));
            m.mustHoldNothingLabels[1] = blanks[k];
            _assertRejected(tl, m, "M1 manifest: empty mustHoldNothing label");
        }
        UpgradeViaTimelock.RoleManifest memory ok = _manifest(tl, "blank-ok");
        ok.mustHoldNothingLabels[1] = " \u00a0x "; // positive control: surrounding blanks, real content
        script.validateManifest(ok);
    }

    function test_manifest_extra_role_key_rejected() public {
        TimelockController tl = _correctTl();
        script.parseManifest(_bodyWith(tl, 10, false)); // positive control
        vm.expectRevert(bytes("M1 manifest: unknown role key in .roles"));
        script.parseManifest(_bodyWith(tl, 10, true));
    }

    /// @notice headBlockHash is compared with blockhash() while the EVM still serves it (<= 256 blocks).
    function test_attestation_head_block_hash_checked_when_available() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "hash");
        Att memory a = _goodAtt(tl);
        a.head = block.number;
        a.headHash = keccak256("the attested head block");
        m.attestation = _writeAtt("hash-att", a);
        vm.roll(block.number + 10);
        vm.setBlockhash(a.head, keccak256("a same-chain-id fork's block"));
        _assertRejected(tl, m, "roles attestation: headBlockHash != this chain's block (fork / reorg)");
        vm.setBlockhash(a.head, a.headHash); // positive control: the attested hash is this chain's block
        script.operatorPreflight(tl, m);
        a.headHash = bytes32(0); // field absent
        m.attestation = _writeAtt("hash-missing", a);
        _assertRejected(tl, m, "roles attestation: headBlockHash missing");
    }

    /// @notice TL_ATTEST_MAX_AGE may lower the 256-block default anywhere, raise it only on a local chain.
    function test_attest_max_age_raise_is_local_only() public {
        assertEq(script.attestMaxAge(1000), 1000, "local chain: may raise");
        vm.chainId(10);
        assertEq(script.attestMaxAge(256), 256, "live chain: the default (the blockhash window)");
        assertEq(script.attestMaxAge(50), 50, "live chain: may lower");
        vm.expectRevert(bytes("roles attestation: TL_ATTEST_MAX_AGE above 256 is local-only"));
        script.attestMaxAge(257);
    }

    // ------------------------------------------------------------------ Codex re-check of 7ca43549 (M2, L1)

    /// @notice LIVE chain ids fail closed on headBlockHash: an attestation of the current block (no
    ///         blockhash yet), a zero blockhash, a mismatching one, and one older than the 256-block window
    ///         are all refused; a matching blockhash 1..256 blocks back passes.
    function test_live_chain_head_block_hash_fail_closed() public {
        TimelockController tl = _correctTl();
        vm.chainId(10);
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "live-current"); // head == block.number
        _assertRejected(tl, m, "roles attestation: live chain: head must be 1..256 blocks older than block.number");

        Att memory a = _goodAtt(tl);
        a.head = block.number;
        a.headHash = keccak256("the live head block");
        m.attestation = _writeAtt("live-hash", a);
        vm.roll(block.number + 10);
        vm.setBlockhash(a.head, a.headHash);
        script.operatorPreflight(tl, m); // positive control: matching hash 10 blocks back
        vm.setBlockhash(a.head, keccak256("a same-chain-id fork's block"));
        _assertRejected(tl, m, "roles attestation: headBlockHash != this chain's block (fork / reorg)");
        vm.setBlockhash(a.head, bytes32(0));
        _assertRejected(tl, m, "roles attestation: live chain: blockhash(head) unavailable");

        a.head = block.number;
        m.attestation = _writeAtt("live-old", a);
        vm.roll(block.number + 257);
        _assertRejected(tl, m, "roles attestation: stale"); // 257 > the live maximum of 256
    }

    // ------------------------------------------------------------------ Codex re-check of 48cba3bd: canonical form, transitively

    /// @notice The canonical byte form is enforced by the checker only; forge carries it over by requiring
    ///         the manifest values it read to equal the attested ones (the attestation binds the exact
    ///         bytes through manifestKeccak256 — test_attestation_manifest_changed_reverts). Each attested
    ///         value that differs from forge's reading stops the script.
    function test_attested_values_must_equal_the_manifest_forge_read() public {
        TimelockController tl = _correctTl();
        UpgradeViaTimelock.RoleManifest memory m = _manifest(tl, "vals");
        script.operatorPreflight(tl, m); // positive control
        Att memory a = _goodAtt(tl);
        a.manifestChainId = 11155111;
        m.attestation = _writeAtt("vals-chain", a);
        _assertRejected(tl, m, "roles attestation: attested manifest chainId != manifest");
        a = _goodAtt(tl);
        a.deploymentBlock = block.number + 1;
        m.attestation = _writeAtt("vals-block", a);
        _assertRejected(tl, m, "roles attestation: attested deploymentBlock != manifest");
        a = _goodAtt(tl);
        a.mustHoldNothing = _two(eoa, deployer); // same set, different order: not the same manifest
        m.attestation = _writeAtt("vals-mhn", a);
        _assertRejected(tl, m, "roles attestation: attested mustHoldNothing != manifest");
        a = _goodAtt(tl);
        a.labels[1] = "ops EOA (edited)";
        m.attestation = _writeAtt("vals-labels", a);
        _assertRejected(tl, m, "roles attestation: attested labels != manifest");
    }
}
