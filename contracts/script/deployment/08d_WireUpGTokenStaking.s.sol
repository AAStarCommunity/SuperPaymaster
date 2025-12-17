// SPDX-License-Identifier: MIT
// 08d_WireUpGTokenStaking.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/GTokenStaking.sol";

contract Deploy08d_WireUpGTokenStaking is Script {
    function run(address gTokenStakingAddr, address registryAddr) external {
        require(gTokenStakingAddr != address(0), "GTokenStaking address cannot be zero.");
        require(registryAddr != address(0), "Registry address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking(gTokenStakingAddr).setRegistry(registryAddr);

        vm.stopBroadcast();
        console.log("GTokenStaking at", gTokenStakingAddr, "is now wired with Registry at", registryAddr);
    }
}
