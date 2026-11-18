// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "./DeployLiveRun.t.sol";

contract LocalCommitHarness is DeployLive {
    function configure(address sender) external {
        deployer = sender;
        entryPointAddr = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        priceFeedAddr = address(100); simpleAccountFactory = address(101);
    }
    function _uintInput(string memory) internal pure override returns (uint256) { return 0; }
    function _configPath(string memory) internal pure override returns (string memory) {
        return "cache/dlpop/config.local-commit.json";
    }
}

contract DeployLiveCommitTest is DeployLiveRunTest {
    function test_LocalRunWritesEmptyCommit() public {
        vm.createDir("cache/dlpop", true);
        vm.deal(tx.origin, 10 ether);
        vm.setEnv("LOCAL_DEV_GOVERNANCE_ACK", "true");
        LocalCommitHarness local = new LocalCommitHarness();
        local.configure(tx.origin);
        local.run();
        assertEq(vm.parseJsonString(vm.readFile("cache/dlpop/config.local-commit.json"), ".commit"), "");
    }
}
