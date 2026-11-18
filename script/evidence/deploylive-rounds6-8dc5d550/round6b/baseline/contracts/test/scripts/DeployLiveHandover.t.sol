// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import {Ownable2StepNamespaced} from "src/utils/Ownable2StepNamespaced.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {TimelockHandoverBootstrap, TimelockHandover} from "../../script/v3/TimelockHandoverBootstrap.sol";
import {DeployLiveInputs} from "../../script/v3/DeployLiveInputs.sol";

contract HandoverFixture is Ownable2StepNamespaced {
    constructor() Ownable(msg.sender) {}
}
contract SafeInputFixture {
    function getThreshold() external pure returns (uint256) { return 2; }
    function getOwners() external pure returns (address[] memory a) {
        a = new address[](2); a[0] = address(91); a[1] = address(92);
    }
}
contract InputsHarness is DeployLiveInputs {
    mapping(string => string) strings;
    mapping(string => bool) present;
    function _inputSet(string memory k) internal view override returns (bool) { return present[k]; }
    function putString(string memory k, string memory v) external { strings[k] = v; present[k] = true; }
    function _stringInput(string memory k) internal view override returns (string memory) { return strings[k]; }
    mapping(string => address) addresses;
    mapping(string => uint256) numbers;
    bytes encoded;
    function putAddress(string memory k, address v) external { addresses[k] = v; }
    function putUint(string memory k, uint256 v) external { numbers[k] = v; }
    function putGuardians(bytes memory b) external { encoded = b; }
    function _addressInput(string memory k) internal view override returns (address) { return addresses[k]; }
    function _uintInput(string memory k) internal view override returns (uint256) { return numbers[k]; }
    function _guardiansInput() internal view override returns (bytes memory) { return encoded; }
    function load(address sender) external { _loadProductionInputs(sender); }
    function stopRequested() external view returns (bool) { return _stopBeforeBootstrap(); }
    function infrastructure(address ep, address feed, address factory) external view { _validateInfrastructure(ep, feed, factory); }
    function count() external view returns (uint256) { return guardiansInput.length; }
}
contract DeployLiveHandoverTest is Test {
    function setUp() public { vm.warp(100); }
    address safe = address(0xCAFE);
    address deployer = address(0xD00D);
    function assertFinal(TimelockController t, address[] memory owned, address h) external view {
        address[] memory subjects = new address[](3);
        subjects[0] = deployer; subjects[1] = h;
        TimelockHandover.assertFinal(t, owned, safe, subjects);
    }
    function setupHandover() internal returns (TimelockController t, address[] memory owned, address h) {
        owned = new address[](3);
        for (uint256 i; i < 3; ++i) owned[i] = address(new HandoverFixture());
        h = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address[] memory principals = new address[](1);
        principals[0] = h;
        t = new TimelockController(0, principals, principals, address(0));
        for (uint256 i; i < 3; ++i) HandoverFixture(owned[i]).transferOwnership(address(t));
    }
    function test_StopFlagOnlyOnExplicitLocalProductionRehearsal() public {
        InputsHarness inputs = new InputsHarness();
        inputs.putUint("DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP", 1);
        inputs.putUint("DEPLOYLIVE_REHEARSAL", 1);
        vm.chainId(31337);
        assertTrue(inputs.stopRequested());
        inputs.putUint("DEPLOYLIVE_REHEARSAL", 0);
        vm.expectRevert("stop: rehearsal chain only");
        inputs.stopRequested();
        inputs.putUint("DEPLOYLIVE_REHEARSAL", 1);
        vm.chainId(10);
        vm.expectRevert("stop: rehearsal chain only");
        inputs.stopRequested();
        vm.chainId(11155111);
        vm.expectRevert("stop: rehearsal chain only");
        inputs.stopRequested();
        inputs.putUint("DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP", 0);
        assertFalse(inputs.stopRequested());
    }

    function test_SafeHasNoBootstrapAuthority() public {
        (TimelockController t, address[] memory owned, address h) = setupHandover();
        assertFalse(t.hasRole(t.PROPOSER_ROLE(), safe));
        assertFalse(t.hasRole(t.EXECUTOR_ROLE(), safe));
        assertFalse(t.hasRole(t.CANCELLER_ROLE(), safe));
        (address[] memory targets, uint256[] memory values, bytes[] memory data) = TimelockHandover.batch(t, owned, h, safe);
        vm.prank(safe); vm.expectRevert();
        t.scheduleBatch(targets, values, data, 0, 0, 0);
    }

    function test_BootstrapCompletesOwnershipAndRemovesAllRoles() public {
        (TimelockController t, address[] memory owned, address h) = setupHandover();
        assertEq(address(new TimelockHandoverBootstrap(t, owned, safe)), h);
        this.assertFinal(t, owned, h);
        assertEq(h.code, type(TimelockHandoverBootstrap).runtimeCode);
        emit log_named_uint("H runtime bytes", h.code.length);
    }
    function test_MissingProposerNamedError() public { missingRole(true); }
    function test_MissingExecutorNamedError() public { missingRole(false); }
    function missingRole(bool proposer) internal {
        address h = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address[] memory present = new address[](1); present[0] = h;
        TimelockController t = new TimelockController(0, proposer ? new address[](0) : present,
            proposer ? present : new address[](0), address(0));
        vm.expectRevert(TimelockHandoverBootstrap.BootstrapRolesMissing.selector);
        new TimelockHandoverBootstrap(t, new address[](0), safe);
    }
    function test_MissingProposerRevokeFailsReadback() public { mutation(0); }
    function test_MissingExecutorRevokeFailsReadback() public { mutation(1); }
    function test_MissingCancellerRevokeFailsReadback() public { mutation(2); }
    function test_MissingDelayUpdateFailsReadback() public { mutation(3); }
    function mutation(uint256 missing) internal {
        (TimelockController t, address[] memory owned, address h) = setupHandover();
        (address[] memory targets, uint256[] memory values, bytes[] memory data) = TimelockHandover.batch(t, owned, h, safe);
        // Replace the omitted operation with a harmless timelock self-call.
        data[owned.length + 3 + missing] = abi.encodeCall(t.getMinDelay, ());
        vm.startPrank(h);
        t.scheduleBatch(targets, values, data, 0, 0, 0);
        t.executeBatch(targets, values, data, 0, 0);
        vm.stopPrank();
        vm.expectRevert(bytes(missing == 3 ? "handover: delay" : "handover: unexpected role"));
        this.assertFinal(t, owned, h);
    }
    function test_EachOwnershipAcceptanceIsRequired() public {
        for (uint256 missing; missing < 3; ++missing) {
            (TimelockController t, address[] memory owned, address h) = setupHandover();
            (address[] memory targets, uint256[] memory values, bytes[] memory data) = TimelockHandover.batch(t, owned, h, safe);
            targets[missing] = address(t); data[missing] = abi.encodeCall(t.getMinDelay, ());
            vm.startPrank(h);
            t.scheduleBatch(targets, values, data, 0, 0, 0); t.executeBatch(targets, values, data, 0, 0);
            vm.stopPrank(); vm.expectRevert("handover: owner"); this.assertFinal(t, owned, h);
        }
    }
    function test_FailedHLeavesSafeWithoutAuthority() public {
        (TimelockController t, address[] memory owned, address h) = setupHandover();
        HandoverFixture(owned[1]).transferOwnership(address(123));
        vm.expectRevert(); new TimelockHandoverBootstrap(t, owned, safe);
        assertEq(h.code.length, 0);
        assertEq(t.getMinDelay(), 0);
        assertEq(HandoverFixture(owned[0]).owner(), address(this));
        assertFalse(t.hasRole(t.PROPOSER_ROLE(), safe));
        assertFalse(t.hasRole(t.EXECUTOR_ROLE(), safe));
    }
    function assertSubjects(TimelockController t, address[] memory owned, address[] memory subjects) external view {
        TimelockHandover.assertFinal(t, owned, safe, subjects);
    }
    function test_EverySubjectAndEveryRoleRejected() public {
        (TimelockController t, address[] memory owned, address h) = setupHandover();
        new TimelockHandoverBootstrap(t, owned, safe);
        address[] memory subjects = new address[](9);
        subjects[0] = deployer; subjects[1] = h;
        for (uint256 i = 2; i < 8; ++i) subjects[i] = address(uint160(1000 + i));
        bytes32[4] memory roles = [t.DEFAULT_ADMIN_ROLE(), t.PROPOSER_ROLE(), t.EXECUTOR_ROLE(), t.CANCELLER_ROLE()];
        for (uint256 i; i < subjects.length; ++i) for (uint256 j; j < 4; ++j) {
            vm.prank(address(t)); t.grantRole(roles[j], subjects[i]);
            vm.expectRevert(); this.assertSubjects(t, owned, subjects);
            vm.prank(address(t)); t.revokeRole(roles[j], subjects[i]);
        }
        subjects[2] = safe; this.assertSubjects(t, owned, subjects);
    }
    function inputs() internal returns (InputsHarness h) {
        h = new InputsHarness();
        h.putString("SLASH_POLICY_ADMIN", "timelock"); h.putString("X402_OWNER", "safe");
        h.putString("REPUTATION_OWNER", "timelock"); h.putString("MPC_OWNER", "timelock");
        h.putString("PAYMASTER_FACTORY_OWNER", "timelock"); h.putString("DEPLOYER_GTOKEN_RECIPIENT", "safe");
        string[5] memory addrKeys = ["GOVERNANCE_OWNER", "GOVERNOR_ADDRESS", "GUARDIAN_ADDRESS", "SP_GUARDIAN", "GENESIS_AASTAR_OPERATOR"];
        for (uint256 i; i < addrKeys.length; ++i) h.putAddress(addrKeys[i], i < 2 ? safe : address(uint160(200 + i)));
        vm.etch(safe, type(SafeInputFixture).runtimeCode);
        string[7] memory uintKeys = ["APNTS_CAP", "GUARDIAN_N", "GUARDIAN_MIN_THRESHOLD", "GUARDIAN_DEFAULT_THRESHOLD", "GUARDIAN_SLASH_THRESHOLD_0", "GUARDIAN_SLASH_THRESHOLD_1", "GUARDIAN_SLASH_THRESHOLD_2"];
        for (uint256 i; i < uintKeys.length; ++i) h.putUint(uintKeys[i], 2);
        DeployLiveInputs.GuardianInput[] memory gs = new DeployLiveInputs.GuardianInput[](2);
        gs[0].account = address(10); gs[1].account = address(11);
        h.putGuardians(abi.encode(gs));
    }
    function test_EveryRequiredPrincipalPairRejectsCollision() public {
        vm.chainId(10);
        string[4] memory keys = ["GOVERNANCE_OWNER", "SP_GUARDIAN", "GUARDIAN_ADDRESS", "GENESIS_AASTAR_OPERATOR"];
        address[7] memory accounts = [safe, address(203), address(202), address(204), deployer, address(10), address(11)];
        for (uint256 i; i < accounts.length; ++i) for (uint256 j; j < i; ++j) {
            InputsHarness h = inputs();
            if (i < 4) h.putAddress(keys[i], accounts[j]);
            else if (i == 4) h.putAddress(keys[j], deployer);
            else {
                DeployLiveInputs.GuardianInput[] memory gs = new DeployLiveInputs.GuardianInput[](2);
                gs[0].account = address(10); gs[1].account = address(11);
                gs[i - 5].account = accounts[j]; h.putGuardians(abi.encode(gs));
            }
            vm.expectRevert(); h.load(deployer);
        }
    }
    function test_SafeRejectsEOADelegationAndBadThreshold() public {
        vm.chainId(10);
        InputsHarness h = inputs();
        vm.etch(safe, hex""); vm.expectRevert("DeployLive: Safe code"); h.load(deployer);
        vm.etch(safe, hex"ef01000000000000000000000000000000000000000001");
        vm.expectRevert("DeployLive: Safe code"); h.load(deployer);
        vm.etch(safe, type(SafeInputFixture).runtimeCode);
        vm.mockCall(safe, abi.encodeWithSignature("getThreshold()"), abi.encode(uint256(1)));
        vm.expectRevert("DeployLive: Safe threshold/owners"); h.load(deployer);
    }
    function test_UnknownChainRequiresProductionInputs() public {
        vm.chainId(987654); InputsHarness h = new InputsHarness();
        vm.expectRevert("DeployLive: GOVERNANCE_OWNER"); h.load(deployer);
    }
    function test_AllRequiredAddressesRejectUnsetZeroAndDeployerOnBothChains() public {
        string[4] memory keys = ["GOVERNANCE_OWNER", "GUARDIAN_ADDRESS", "SP_GUARDIAN", "GENESIS_AASTAR_OPERATOR"];
        for (uint256 chain; chain < 2; ++chain) {
            vm.chainId(chain == 0 ? 10 : 11155111);
            for (uint256 i; i < keys.length; ++i) for (uint256 bad; bad < 2; ++bad) {
                InputsHarness h = inputs(); h.putAddress(keys[i], bad == 0 ? address(0) : deployer);
                vm.expectRevert(bytes(string.concat("DeployLive: ", keys[i]))); h.load(deployer);
            }
        }
    }
    function test_AllRequiredNumbersRejectUnsetAndZeroOnBothChains() public {
        string[7] memory keys = ["APNTS_CAP", "GUARDIAN_N", "GUARDIAN_MIN_THRESHOLD", "GUARDIAN_DEFAULT_THRESHOLD", "GUARDIAN_SLASH_THRESHOLD_0", "GUARDIAN_SLASH_THRESHOLD_1", "GUARDIAN_SLASH_THRESHOLD_2"];
        for (uint256 chain; chain < 2; ++chain) {
            vm.chainId(chain == 0 ? 10 : 11155111);
            for (uint256 i; i < keys.length; ++i) {
                InputsHarness h = inputs(); h.putUint(keys[i], 0);
                vm.expectRevert(bytes(string.concat("DeployLive: ", keys[i]))); h.load(deployer);
            }
        }
    }
    function test_LocalDefaultsDoNotRequireProductionInputs() public {
        vm.chainId(31337); InputsHarness h = new InputsHarness(); h.load(deployer); assertEq(h.count(), 0);
    }
    function test_Round6EveryOwnerChoiceRejectsMissingInvalidAndEOA() public {
        vm.chainId(10);
        string[5] memory keys = ["SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER"];
        string[5] memory bad = ["", "unknown", "0x0000000000000000000000000000000000000000", vm.toString(deployer), vm.toString(address(777))];
        for (uint256 i; i < keys.length; ++i) for (uint256 j; j < bad.length; ++j) {
            InputsHarness h = inputs(); h.putString(keys[i], bad[j]);
            vm.expectRevert(); h.load(deployer);
        }
    }
    function test_Round6EveryOwnerChoiceAcceptsContractAddress() public {
        vm.chainId(10);
        string[5] memory keys = ["SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER"];
        for (uint256 i; i < keys.length; ++i) {
            InputsHarness h = inputs(); h.putString(keys[i], vm.toString(safe)); h.load(deployer);
        }
    }
    function test_Round6RecipientRequiredAndNotDeployer() public {
        vm.chainId(10);
        string[4] memory bad = ["", "unknown", "0x0000000000000000000000000000000000000000", vm.toString(deployer)];
        for (uint256 i; i < bad.length; ++i) {
            InputsHarness h = inputs(); h.putString("DEPLOYER_GTOKEN_RECIPIENT", bad[i]); vm.expectRevert(); h.load(deployer);
        }
    }
    function test_Round6GovernorRejected() public {
        vm.chainId(10); InputsHarness h = inputs();
        h.putString("GOVERNOR_ADDRESS", "0x000000000000000000000000000000000000CAFE");
        vm.expectRevert("DeployLive: GOVERNOR_ADDRESS deleted; use X402_OWNER"); h.load(deployer);

    }
    function test_Round6MissingOwnerInputRejected() public {
        vm.chainId(10); InputsHarness h = inputs();
        h.putString("SLASH_POLICY_ADMIN", "");
        vm.expectRevert("DeployLive: SLASH_POLICY_ADMIN"); h.load(deployer);
    }
    function test_ProductionInputsAccepted() public {
        vm.chainId(10); InputsHarness h = inputs(); h.load(deployer); assertEq(h.count(), 2);
    }
    function test_InvalidThresholdRelationsRevert() public {
        vm.chainId(10);
        string[4] memory keys = ["GUARDIAN_N", "GUARDIAN_MIN_THRESHOLD", "GUARDIAN_DEFAULT_THRESHOLD", "GUARDIAN_SLASH_THRESHOLD_0"];
        uint256[4] memory values = [uint256(65), 1, 3, 1];
        for (uint256 i; i < keys.length; ++i) {
            InputsHarness h = inputs(); h.putUint(keys[i], values[i]);
            vm.expectRevert(bytes(i == 3 ? "DeployLive: slash threshold" : "DeployLive: guardian thresholds"));
            h.load(deployer);
        }
    }
    function test_GuardianCountMismatchReverts() public {
        vm.chainId(10); InputsHarness h = inputs(); h.putUint("GUARDIAN_N", 3);
        vm.expectRevert(bytes("DeployLive: GUARDIAN_N mismatch")); h.load(deployer);
    }
    function test_ZeroDeployerAndDuplicateGuardiansRevert() public {
        vm.chainId(10);
        for (uint256 i; i < 3; ++i) {
            InputsHarness h = inputs();
            DeployLiveInputs.GuardianInput[] memory gs = new DeployLiveInputs.GuardianInput[](2);
            gs[0].account = address(10);
            gs[1].account = i == 0 ? address(0) : i == 1 ? deployer : address(10);
            h.putGuardians(abi.encode(gs));
            vm.expectRevert(bytes(i == 2 ? "DeployLive: duplicate guardian" : "DeployLive: guardian account"));
            h.load(deployer);
        }
    }
    function test_MissingGuardiansReverts() public {
        vm.chainId(10); InputsHarness h = inputs(); h.putGuardians("");
        vm.expectRevert(bytes("DeployLive: GUARDIANS")); h.load(deployer);
    }
}
