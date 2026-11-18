// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import {DeployLivePins} from "../../script/v3/DeployLivePins.sol";
import {TimelockHandoverBootstrap} from "../../script/v3/TimelockHandoverBootstrap.sol";

contract PinsHarness is DeployLivePins {
    string injectedArtifact;
    function injectArtifact(string memory path) external { injectedArtifact = path; }
    function _creationCode(string memory name) internal view override returns (bytes memory) {
        if (bytes(injectedArtifact).length > 0 && keccak256(bytes(name)) == keccak256("TimelockController")) return vm.getCode(injectedArtifact);
        return super._creationCode(name);
    }
    function makePins(string memory path) external {
        string[24] memory names = _pinnedNames();
        string memory object = "pins-test";
        for (uint256 i; i < names.length; ++i) vm.serializeBytes32(object, names[i], keccak256(vm.getCode(_defaultArtifact(names[i]))));
        vm.writeFile(path, vm.serializeBytes32(object, "TimelockHandoverBootstrap", keccak256(type(TimelockHandoverBootstrap).creationCode)));
    }
    function check(string memory path) external view { _assertCreationPins(path); }
    function checkContents(string memory path) external view { _assertCreationPinContents(path); }
    function artifact(string memory name) external view returns (string memory) { return _defaultArtifact(name); }
}
contract DeployLivePinsTest is Test {
    function test_Round7MissingProductionPinsRejected() public {
        vm.chainId(987654); PinsHarness h = new PinsHarness();
        vm.expectRevert(); h.check("deployments/creation-pins.987654.json");
    }
    function test_Round7LocalProductionRejectsRehearsalPins() public {
        vm.chainId(31337); PinsHarness h = new PinsHarness();
        vm.expectRevert("DeployLive: committed creation pins required");
        h.check("deployments/creation-pins.rehearsal.json");
    }
    function test_Round7ProductionRejectsRehearsalPins() public {
        vm.chainId(10); PinsHarness h = new PinsHarness();
        vm.expectRevert("DeployLive: committed creation pins required");
        h.check("deployments/creation-pins.rehearsal.json");
    }
    function test_TamperedPinAndArtifactRejectedWithoutNonceConsumption() public {
        PinsHarness h = new PinsHarness();
        vm.createDir("cache/deploylive-tests", true);
        string memory pin = "cache/deploylive-tests/test-pins.json";
        vm.writeFile(pin, vm.readFile("contracts/test/fixtures/deploylive/test-pins.json"));
        h.checkContents(pin);
        uint64 nonce = vm.getNonce(tx.origin);
        string memory original = vm.readFile(pin);
        vm.writeJson(vm.toString(bytes32(uint256(1))), pin, ".TimelockController");
        vm.expectRevert("creation pin mismatch: TimelockController"); h.checkContents(pin);
        vm.writeFile(pin, original);
        string memory artifact = "contracts/test/fixtures/deploylive/tampered-timelock.json";
        h.injectArtifact(artifact);
        vm.expectRevert("creation pin mismatch: TimelockController"); h.checkContents(pin);
        assertEq(vm.getNonce(tx.origin), nonce);
    }
}
