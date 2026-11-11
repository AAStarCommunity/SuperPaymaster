// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {T4ArtifactReader} from "../../script/v3/DefaultArtifacts.sol";
import {APNTsCapped} from "../../src/tokens/APNTsCapped.sol";

/// @notice Skip only a positively identified non-Cancun compilation, never resolver failures.
abstract contract CancunArtifactGate is Test {
    function _skipNonCancunCompilation() internal {
        string memory json = vm.readFile(vm.getArtifactPathByCode(type(APNTsCapped).creationCode));
        string memory evm = vm.parseJsonString(json, ".metadata.settings.evmVersion");
        if (bytes(evm).length != 0 && keccak256(bytes(evm)) != keccak256("cancun")) {
            vm.skip(true, string.concat("non-cancun compilation: evmVersion=", evm));
        }
    }
}

contract ArtifactPredicateHarness is T4ArtifactReader {
    // Per-instance root keeps negative controls independent of concurrent suites' process env.
    string private outputRoot;

    constructor() {
        outputRoot = vm.envOr("DEFAULT_ARTIFACTS_OUT", string("out"));
    }

    function setOutputRoot(string memory root) external {
        outputRoot = root;
    }

    function _artifactOutDir() internal view override returns (string memory) {
        return _validateArtifactOutDir(outputRoot);
    }

    function isDefaultArtifact(string memory name, string memory json) external view returns (bool) {
        string memory src = _sourceOf(name);
        return _isDefaultBuild(json, src, keccak256(bytes(vm.readFile(src))), _expectedRuns(name));
    }
}

/// @dev Always runs, including when the suites skip. The live artifact is accepted only when it is
///      cancun profile.default; prague evmVersion and non-default optimizer runs are rejected.
contract NonCancunArtifactControlTest is CancunArtifactGate {
    function test_nonCancunProfileDefault_doesNotResolve() public {
        string memory json = vm.readFile(vm.getArtifactPathByCode(type(APNTsCapped).creationCode));
        string memory evm = vm.parseJsonString(json, ".metadata.settings.evmVersion");
        emit log_string(string.concat("live APNTsCapped evmVersion=", evm));
        ArtifactPredicateHarness reader = new ArtifactPredicateHarness();
        if (keccak256(bytes(evm)) == keccak256("cancun")) {
            assertTrue(reader.isDefaultArtifact("APNTsCapped", json));
            string memory prague = vm.replace(json, '"evmVersion":"cancun"', '"evmVersion":"prague"');
            assertEq(vm.parseJsonString(prague, ".metadata.settings.evmVersion"), "prague");
            assertFalse(reader.isDefaultArtifact("APNTsCapped", prague), "prague artifact must not resolve");
            string memory badRuns = vm.replace(json, '"runs":500', '"runs":200');
            assertEq(vm.parseJsonUint(badRuns, ".metadata.settings.optimizer.runs"), 200);
            assertFalse(reader.isDefaultArtifact("APNTsCapped", badRuns), "non-default runs must not resolve");
        } else {
            assertFalse(reader.isDefaultArtifact("APNTsCapped", json), "non-cancun artifact must not resolve");
        }
    }
    function test_invalidOutputRoots_revert() public {
        ArtifactPredicateHarness reader = new ArtifactPredicateHarness();
        string[5] memory roots = ["/abs", "../x", "out/", "", "out/../x"];
        string[5] memory reasons = [
            "DefaultArtifacts: output root must be relative",
            "DefaultArtifacts: output root contains parent segment",
            "DefaultArtifacts: output root has trailing slash",
            "DefaultArtifacts: output root is empty",
            "DefaultArtifacts: output root contains parent segment"
        ];
        for (uint256 i; i < roots.length; ++i) {
            reader.setOutputRoot(roots[i]);
            vm.expectRevert(bytes(reasons[i]));
            reader.t4DefaultArtifact("APNTsCapped");
        }
    }

    function test_cancunResolverFailure_revertsInsteadOfSkipping() public {
        _skipNonCancunCompilation();
        ArtifactPredicateHarness reader = new ArtifactPredicateHarness();
        reader.setOutputRoot(".grok-work/deliberately-missing-artifacts");
        vm.expectRevert(bytes("DefaultArtifacts: no profile.default build of APNTsCapped from contracts/src/tokens/APNTsCapped.sol (run a plain `forge build`)"));
        reader.t4DefaultArtifact("APNTsCapped");
    }

}
