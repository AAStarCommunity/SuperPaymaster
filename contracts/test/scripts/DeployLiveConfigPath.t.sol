// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import "../../script/v3/DeployLive.s.sol";

contract DeployLivePathHarness is DeployLive {
    function path() external view returns (string memory) { return _configPath("sepolia"); }
    function _uintInput(string memory) internal pure override returns (uint256) { return 0; }
}

contract DeployLiveConfigPathTest is Test {
    function test_ProductionConfigIgnoredDirectory() public {
        vm.chainId(11155111);
        assertEq(new DeployLivePathHarness().path(), string.concat(vm.projectRoot(), "/deployments/live/config.sepolia.json"));
    }
    function test_LocalConfigUnchanged() public {
        vm.chainId(31337);
        assertEq(new DeployLivePathHarness().path(), string.concat(vm.projectRoot(), "/deployments/config.sepolia.json"));
    }
}
