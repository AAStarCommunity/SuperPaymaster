// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/core/Registry.sol";

contract Check04_Registry is Script {
    function run(address registryAddr) external view {
        Registry registry = Registry(registryAddr);
        console.log("--- Registry V3.1 Check ---");
        console.log("Address:", registryAddr);
        console.log("Staking (Immutable):", address(registry.GTOKEN_STAKING()));
        console.log("MySBT (Immutable):", address(registry.MYSBT()));
        console.log("Owner:", registry.owner());
        
        // V3.1 Specific: Credit Tier Config
        // Access mapping directly since there might not be a level getter
        console.log("Credit Limit Level 1:", registry.creditTierConfig(1) / 1e18, "Unit");
        console.log("Credit Limit Level 2:", registry.creditTierConfig(2) / 1e18, "Unit");
        console.log("Credit Limit Level 3:", registry.creditTierConfig(3) / 1e18, "Unit");
        
        // V3.1 Specific: Reputation Source check
        console.log("Owner is Reputation Source:", registry.isReputationSource(registry.owner()));
        
        console.log("--------------------------");
    }
}
