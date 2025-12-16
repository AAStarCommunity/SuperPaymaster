// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/MySBT.sol";
import "src/core/GTokenStaking.sol";

contract Deploy07_WireUpContracts is Script {
    function run(address mySBTAddr, address gTokenStakingAddr, address registryAddr) external {
        require(mySBTAddr != address(0), "MySBT address cannot be zero.");
        require(gTokenStakingAddr != address(0), "GTokenStaking address cannot be zero.");
        require(registryAddr != address(0), "Registry address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Wiring contracts with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        MySBT(mySBTAddr).setRegistry(registryAddr);
        GTokenStaking(gTokenStakingAddr).setRegistry(registryAddr);

        vm.stopBroadcast();

        console.log("Contracts wired up successfully.");
    }
}