// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {T4ArtifactReader} from "../../script/v3/DefaultArtifacts.sol";
import {APNTsCapped} from "../../src/tokens/APNTsCapped.sol";

/// @notice Skip only a positively identified non-Cancun compilation, never resolver failures.
abstract contract CancunArtifactGate is Test {
    function _skipNonCancunCompilation() internal {
        (bool known, string memory json) = _liveArtifact();
        if (!known) return;
        string memory evm = vm.parseJsonString(json, ".metadata.settings.evmVersion");
        if (bytes(evm).length != 0 && keccak256(bytes(evm)) != keccak256("cancun")) {
            vm.skip(true, string.concat("non-cancun compilation: evmVersion=", evm));
        }
    }

    /// @dev This run's own artifact. An `--out` outside the project (the executed-inventory
    ///      runner and the fuzz gate write under the evidence dir) is outside fs_permissions
    ///      ("./"), so such a run is "not identified" and the suite runs against the
    ///      profile.default artifacts. Inside the project every read error propagates.
    function _liveArtifact() internal view returns (bool known, string memory json) {
        string memory path = vm.getArtifactPathByCode(type(APNTsCapped).creationCode);
        if (vm.indexOf(path, string.concat(vm.projectRoot(), "/")) != 0) return (false, "");
        return (true, vm.readFile(path));
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

    function envRoot(string calldata name) external view returns (string memory) {
        return _envArtifactOutDir(name);
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
        ArtifactPredicateHarness reader = new ArtifactPredicateHarness();
        (bool known, string memory live) = _liveArtifact();
        string memory evm;
        // Known-valid cancun/500 baseline on every engine, independent of a prior cancun build:
        // this run's own artifact with only evmVersion normalized to cancun. When the run is not
        // identified (artifact outside the project) the resolved profile.default artifact is used.
        string memory base;
        if (known) {
            evm = vm.parseJsonString(live, ".metadata.settings.evmVersion");
            base = vm.replace(live, string.concat('"evmVersion":"', evm, '"'), '"evmVersion":"cancun"');
        } else {
            base = vm.readFile(reader.t4DefaultArtifact("APNTsCapped"));
        }
        assertEq(vm.parseJsonString(base, ".metadata.settings.evmVersion"), "cancun");
        assertEq(vm.parseJsonUint(base, ".metadata.settings.optimizer.runs"), 500);
        assertTrue(reader.isDefaultArtifact("APNTsCapped", base));
        // Two independent single-field mutations of the baseline, each rejected on its own.
        string memory prague = vm.replace(base, '"evmVersion":"cancun"', '"evmVersion":"prague"');
        assertEq(vm.parseJsonString(prague, ".metadata.settings.evmVersion"), "prague");
        assertEq(vm.parseJsonUint(prague, ".metadata.settings.optimizer.runs"), 500);
        assertFalse(reader.isDefaultArtifact("APNTsCapped", prague), "prague artifact must not resolve");
        string memory badRuns = vm.replace(base, '"runs":500', '"runs":200');
        assertEq(vm.parseJsonUint(badRuns, ".metadata.settings.optimizer.runs"), 200);
        assertEq(vm.parseJsonString(badRuns, ".metadata.settings.evmVersion"), "cancun");
        assertFalse(reader.isDefaultArtifact("APNTsCapped", badRuns), "non-default runs must not resolve");
        // This run's own artifact, when identified: a non-cancun compilation never resolves.
        if (!known) {
            emit log_string("live APNTsCapped artifact outside the project: not identified");
            return;
        }
        emit log_string(string.concat("live APNTsCapped evmVersion=", evm));
        if (keccak256(bytes(evm)) == keccak256("cancun")) {
            assertTrue(reader.isDefaultArtifact("APNTsCapped", live));
        } else {
            assertFalse(reader.isDefaultArtifact("APNTsCapped", live), "non-cancun artifact must not resolve");
        }
    }

    function test_envOutputRoot_isReadAndValidated() public {
        ArtifactPredicateHarness reader = new ArtifactPredicateHarness();
        // A name of its own: the process-wide DEFAULT_ARTIFACTS_OUT is read by concurrent suites.
        string memory name = "DEFAULT_ARTIFACTS_OUT_GATE_TEST";
        assertEq(reader.envRoot(name), "out", "unset must default to out");
        vm.setEnv(name, ".ams-out/build");
        assertEq(reader.envRoot(name), ".ams-out/build", "a valid root must be taken from the env");
        vm.setEnv(name, "/abs");
        vm.expectRevert(bytes("DefaultArtifacts: output root must be relative"));
        reader.envRoot(name);
        vm.setEnv(name, "a/../b");
        vm.expectRevert(bytes("DefaultArtifacts: output root contains parent segment"));
        reader.envRoot(name);
    }

    function test_invalidOutputRoots_revert() public {
        ArtifactPredicateHarness reader = new ArtifactPredicateHarness();
        string[8] memory roots = ["/abs", "../x", "out/", "", "out/../x", "a\\..\\x", "C:\\out", "C:/out"];
        string[8] memory reasons = [
            "DefaultArtifacts: output root must be relative",
            "DefaultArtifacts: output root contains parent segment",
            "DefaultArtifacts: output root has trailing slash",
            "DefaultArtifacts: output root is empty",
            "DefaultArtifacts: output root contains parent segment",
            "DefaultArtifacts: output root has a backslash or drive separator",
            "DefaultArtifacts: output root has a backslash or drive separator",
            "DefaultArtifacts: output root has a backslash or drive separator"
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
