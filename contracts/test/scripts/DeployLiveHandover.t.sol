// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-v5.0.2/contracts/access/Ownable2Step.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {TimelockHandoverBootstrap, TimelockHandover} from "../../script/v3/TimelockHandoverBootstrap.sol";
import {DeployLiveInputs} from "../../script/v3/DeployLiveInputs.sol";

contract HandoverFixture is Ownable2Step {
    constructor() Ownable(msg.sender) {}
}
contract InputsHarness is DeployLiveInputs {
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
    function count() external view returns (uint256) { return guardiansInput.length; }
}
contract DeployLiveHandoverTest is Test {
    function setUp() public { vm.warp(100); }
    address safe = address(0xCAFE);
    address deployer = address(0xD00D);
    function assertFinal(TimelockController t, address[] memory owned, address h) external view {
        TimelockHandover.assertFinal(t, owned, safe, deployer, h);
    }
    function setupHandover() internal returns (TimelockController t, address[] memory owned, address h) {
        owned = new address[](3);
        for (uint256 i; i < 3; ++i) owned[i] = address(new HandoverFixture());
        h = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address[] memory principals = new address[](2);
        principals[0] = safe; principals[1] = h;
        t = new TimelockController(0, principals, principals, address(0));
        for (uint256 i; i < 3; ++i) HandoverFixture(owned[i]).transferOwnership(address(t));
    }
    function test_BootstrapCompletesOwnershipAndRemovesAllRoles() public {
        (TimelockController t, address[] memory owned, address h) = setupHandover();
        assertEq(address(new TimelockHandoverBootstrap(t, owned)), h);
        this.assertFinal(t, owned, h);
        assertEq(h.code, type(TimelockHandoverBootstrap).runtimeCode);
        emit log_named_uint("H runtime bytes", h.code.length);
        (bool callable,) = h.call(abi.encodeWithSignature("run()"));
        assertFalse(callable);
    }
    function test_MissingProposerNamedError() public { missingRole(true); }
    function test_MissingExecutorNamedError() public { missingRole(false); }
    function missingRole(bool proposer) internal {
        address h = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address[] memory present = new address[](1); present[0] = h;
        TimelockController t = new TimelockController(0, proposer ? new address[](0) : present,
            proposer ? present : new address[](0), address(0));
        vm.expectRevert(TimelockHandoverBootstrap.BootstrapRolesMissing.selector);
        new TimelockHandoverBootstrap(t, new address[](0));
    }
    function test_MissingProposerRevokeFailsReadback() public { mutation(0); }
    function test_MissingExecutorRevokeFailsReadback() public { mutation(1); }
    function test_MissingCancellerRevokeFailsReadback() public { mutation(2); }
    function test_MissingDelayUpdateFailsReadback() public { mutation(3); }
    function mutation(uint256 missing) internal {
        (TimelockController t, address[] memory owned, address h) = setupHandover();
        (address[] memory targets, uint256[] memory values, bytes[] memory data) = TimelockHandover.batch(t, owned, h);
        // Replace the omitted operation with a harmless timelock self-call.
        data[owned.length + missing] = abi.encodeCall(t.getMinDelay, ());
        vm.startPrank(safe);
        t.scheduleBatch(targets, values, data, 0, 0, 0);
        t.executeBatch(targets, values, data, 0, 0);
        vm.stopPrank();
        vm.expectRevert(bytes(missing == 3 ? "handover: delay" : "handover: bootstrap role"));
        this.assertFinal(t, owned, h);
    }
    function inputs() internal returns (InputsHarness h) {
        h = new InputsHarness();
        string[5] memory addrKeys = ["GOVERNANCE_OWNER", "GOVERNOR_ADDRESS", "GUARDIAN_ADDRESS", "SP_GUARDIAN", "GENESIS_AASTAR_OPERATOR"];
        for (uint256 i; i < addrKeys.length; ++i) h.putAddress(addrKeys[i], safe);
        string[7] memory uintKeys = ["APNTS_CAP", "GUARDIAN_N", "GUARDIAN_MIN_THRESHOLD", "GUARDIAN_DEFAULT_THRESHOLD", "GUARDIAN_SLASH_THRESHOLD_0", "GUARDIAN_SLASH_THRESHOLD_1", "GUARDIAN_SLASH_THRESHOLD_2"];
        for (uint256 i; i < uintKeys.length; ++i) h.putUint(uintKeys[i], 2);
        DeployLiveInputs.GuardianInput[] memory gs = new DeployLiveInputs.GuardianInput[](2);
        gs[0].account = address(10); gs[1].account = address(11);
        h.putGuardians(abi.encode(gs));
    }
    function test_AllRequiredAddressesRejectUnsetZeroAndDeployerOnBothChains() public {
        string[5] memory keys = ["GOVERNANCE_OWNER", "GOVERNOR_ADDRESS", "GUARDIAN_ADDRESS", "SP_GUARDIAN", "GENESIS_AASTAR_OPERATOR"];
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
