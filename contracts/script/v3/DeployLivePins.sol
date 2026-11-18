// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {DefaultArtifacts} from "./DefaultArtifacts.sol";
import {TimelockHandoverBootstrap} from "./TimelockHandoverBootstrap.sol";

abstract contract DeployLivePins is DefaultArtifacts {
    function _pinnedNames() internal pure returns (string[24] memory) {
        return ["Registry", "SuperPaymaster", "APNTsCapped", "TimelockController", "ERC1967Proxy",
            "xPNTsFactory", "GTokenAuthorization", "GTokenStaking", "MySBT", "ReputationSystem",
            "DVTValidator", "BLSAggregator", "MicroPaymentChannel", "PaymasterFactory", "Paymaster",
            "X402Facilitator", "PolicyRegistry", "GlobalTierSource", "AOAProtocolRegistry",
            "xPNTsTokenV2Ext", "xPNTsTokenV2", "xPNTsFactoryV2", "SuperPaymasterLens", "xPNTsToken"];
    }
    function _artifactCompileSettings() internal view returns (string memory result) {
        string[24] memory names = _pinnedNames();
        result = "{";
        for (uint256 i; i < names.length; ++i) {
            result = string.concat(result, i == 0 ? "" : ",", '"', names[i], '":', _t4Reader.t4CompileSettings(names[i]));
        }
        return string.concat(result, ',"TimelockHandoverBootstrap":', _t4Reader.t4CompileSettings("TimelockHandoverBootstrap"), '}');
    }

    function _creationCode(string memory name) internal view virtual returns (bytes memory) {
        return vm.getCode(_defaultArtifact(name));
    }
    function _assertCreationPins(string memory path) internal view {
        require(keccak256(bytes(path)) == keccak256(bytes(string.concat(
            "deployments/creation-pins.", vm.toString(block.chainid), ".json"))), "DeployLive: committed creation pins required");
        _assertCreationPinContents(path);
    }
    function _assertCreationPinContents(string memory path) internal view {
        string memory pins = vm.readFile(path);
        string[24] memory names = _pinnedNames();
        for (uint256 i; i < names.length; ++i) {
            bytes memory code = _creationCode(names[i]);
            require(keccak256(code) == vm.parseJsonBytes32(pins, string.concat(".", names[i])),
                string.concat("creation pin mismatch: ", names[i]));
        }
        require(keccak256(type(TimelockHandoverBootstrap).creationCode) == vm.parseJsonBytes32(pins, ".TimelockHandoverBootstrap"),
            "creation pin mismatch: TimelockHandoverBootstrap");
    }
}
