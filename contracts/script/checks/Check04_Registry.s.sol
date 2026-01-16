// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/core/Registry.sol";

contract Check04_Registry is Script {
    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        string memory json = vm.readFile(path);
        address registryAddr = vm.parseJsonAddress(json, ".registry");

        Registry registry = Registry(registryAddr);
        console.log("--- Registry V3.1 Check ---");
        console.log("Address:", registryAddr);
        console.log("Version:", registry.version());
        console.log("Staking:", address(registry.GTOKEN_STAKING()));
        console.log("MySBT:", address(registry.MYSBT()));
        console.log("Owner:", registry.owner());
        
        console.log("Credit Limit Level 1:", registry.creditTierConfig(1) / 1e18, "aPNTs");
        console.log("Credit Limit Level 2:", registry.creditTierConfig(2) / 1e18, "aPNTs");
        
        console.log("Owner is Reputation Source:", registry.isReputationSource(registry.owner()));
        console.log("--------------------------");
    }
}
