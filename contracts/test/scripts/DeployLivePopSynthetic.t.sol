// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import "./DeployLiveLocalFixture.s.sol";

/// @notice SYNTHETIC public scalars 1/2/3 only; never deploy-day input.
contract DeployLivePopSyntheticTest is Test {
    function test_WriteSyntheticLocalFixture() public {
        // The full DeployLive suite also runs under Cancun; this control needs Prague.
        (bool available, bytes memory output) = address(0x0c).staticcall(new bytes(160));
        vm.skip(!available || output.length != 128);
        vm.chainId(31337);
        address sender = address(0x123456);
        vm.setNonce(sender, 7);
        vm.createDir("cache/dlpop", true);
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(sender));
        vm.setEnv("DEPLOYLIVE_LOCAL_EVIDENCE", "cache/dlpop");
        new DeployLiveLocalBundle().run();
        // Round-trip anchor: the local bundle's GUARDIANS must equal the committed converter fixture,
        // so the Python converter test needs no cache file from an earlier Prague run.
        assertEq(vm.trim(vm.readFile("cache/dlpop/guardians.txt")),
                 vm.trim(vm.readFile("script/rehearsal/fixtures/dvt-pop/SYNTHETIC.guardians.hex")), "SYNTHETIC GUARDIANS");
        vm.writeFile("cache/dlpop/SYNTHETIC.addresses.json", vm.serializeAddress("synthetic", "Registry", vm.computeCreateAddress(sender, 8)));
        vm.writeFile("cache/dlpop/SYNTHETIC.addresses.json", vm.serializeAddress("synthetic", "BLSAggregator", vm.computeCreateAddress(sender, 36)));
    }
}
