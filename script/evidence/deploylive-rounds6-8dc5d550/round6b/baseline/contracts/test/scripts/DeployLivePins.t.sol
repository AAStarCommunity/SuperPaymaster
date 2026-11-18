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
    function artifact(string memory name) external view returns (string memory) { return _defaultArtifact(name); }
}
contract DeployLivePinsTest is Test {
    function test_TamperedPinAndArtifactRejectedWithoutNonceConsumption() public {
        PinsHarness h = new PinsHarness();
        string memory pin = "script/rehearsal/evidence/round6/test-pins.json";
        h.makePins(pin); h.check(pin);
        uint64 nonce = vm.getNonce(tx.origin);
        string memory original = vm.readFile(pin);
        vm.writeJson(vm.toString(bytes32(uint256(1))), pin, ".TimelockController");
        vm.expectRevert("creation pin mismatch: TimelockController"); h.check(pin);
        vm.writeFile(pin, original);
        string memory artifact = "script/rehearsal/evidence/round6/tampered-timelock.json";
        vm.writeFile(artifact, vm.readFile(h.artifact("TimelockController")));
        h.injectArtifact(artifact);
        vm.writeJson('"0x00"', artifact, ".bytecode.object");
        vm.expectRevert("creation pin mismatch: TimelockController"); h.check(pin);
        vm.removeFile(artifact);
        assertEq(vm.getNonce(tx.origin), nonce);
    }
}
