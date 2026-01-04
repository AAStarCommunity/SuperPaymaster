// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/core/GTokenStaking.sol";

contract Check02_GTokenStaking is Script {
    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        string memory json = vm.readFile(path);
        address stakingAddr = vm.parseJsonAddress(json, ".staking");

        GTokenStaking staking = GTokenStaking(stakingAddr);
        console.log("--- GTokenStaking Check ---");
        console.log("Address:", stakingAddr);
        console.log("GToken Address (Immutable):", address(staking.GTOKEN()));
        console.log("Registry Address:", staking.REGISTRY());
        console.log("Owner:", staking.owner());
        console.log("Total Staked:", staking.totalStaked() / 1e18);
        console.log("Version:", staking.version());
        console.log("---------------------------");
    }
}
