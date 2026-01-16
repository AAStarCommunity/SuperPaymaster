// SPDX-License-Identifier: MIT
// 04_DeployRegistry.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";

contract Deploy04_Registry is Script {
    function run(address gTokenAddr, address gTokenStakingAddr, address mySBTAddr) external {
        require(gTokenAddr != address(0), "GToken address cannot be zero.");
        require(gTokenStakingAddr != address(0), "GTokenStaking address cannot be zero.");
        require(mySBTAddr != address(0), "MySBT address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying Registry with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        Registry registry = new Registry(gTokenAddr, gTokenStakingAddr, mySBTAddr);

        vm.stopBroadcast();

        console.log("Registry deployed to:", address(registry));
    }
}
