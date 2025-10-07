// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/SuperPaymasterRegistry_v1_2.sol";

contract DeployRegistry is Script {
    function run() external {
        // Load deployment parameters from environment
        address owner = vm.envAddress("OWNER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 minStakeAmount = vm.envUint("MIN_STAKE_AMOUNT");
        uint256 routerFeeRate = vm.envUint("ROUTER_FEE_RATE");
        uint256 slashPercentage = vm.envUint("SLASH_PERCENTAGE");

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy SuperPaymasterRegistry
        SuperPaymasterRegistry registry = new SuperPaymasterRegistry(
            owner,
            treasury,
            minStakeAmount,
            routerFeeRate,
            slashPercentage
        );

        console.log("SuperPaymasterRegistry v1.2 deployed at:", address(registry));
        console.log("Owner:", owner);
        console.log("Treasury:", treasury);
        console.log("Min Stake Amount:", minStakeAmount);
        console.log("Router Fee Rate:", routerFeeRate, "bps");
        console.log("Slash Percentage:", slashPercentage, "bps");

        vm.stopBroadcast();
    }
}
