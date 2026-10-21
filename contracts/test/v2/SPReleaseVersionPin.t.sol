// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterLens } from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { SPReleaseVersion } from "../../script/v3/SPReleaseVersion.sol";

/// @notice Codex B-MEDIUM-3: the version string the release scripts read back (UpgradeToV5_5_0
///         step-5 read-back, V55Bootstrap lens read-back, Check08/09, InitializeAAStar) must be the
///         one SuperPaymaster and the lens actually report — otherwise the upgrade aborts.
contract SPReleaseVersionPinTest is Test {
    function test_scripts_version_matches_SP_and_lens() public {
        SuperPaymaster impl = new SuperPaymaster(
            IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032), IRegistry(address(1)), address(2)
        );
        SuperPaymasterLens lens = new SuperPaymasterLens();
        assertEq(impl.version(), SPReleaseVersion.SP, "SP.version() == script SP_V55_VERSION (step-5 read-back)");
        assertEq(lens.version(), SPReleaseVersion.LENS, "lens.version() == script LENS_VERSION");
        assertEq(lens.EXPECTED_SP_VERSION(), keccak256(bytes(SPReleaseVersion.SP)), "lens pinned to the script's SP version");
    }
}
