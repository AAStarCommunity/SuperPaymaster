// SPDX-License-Identifier: MIT
// 03_DeployMySBT.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/MySBT.sol";

contract Deploy03_MySBT is Script {
    function run(address gTokenAddr, address gTokenStakingAddr) external {
        require(gTokenAddr != address(0), "GToken address cannot be zero.");
        require(gTokenStakingAddr != address(0), "GTokenStaking address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying MySBT with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        MySBT mySBT = new MySBT(gTokenAddr, gTokenStakingAddr, address(0), deployer);

        vm.stopBroadcast();

        console.log("MySBT deployed to:", address(mySBT));
    }
}
