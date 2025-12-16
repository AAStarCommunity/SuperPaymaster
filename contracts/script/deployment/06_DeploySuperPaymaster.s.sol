// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import {IEntryPoint} from "account-abstraction-v7/interfaces/IEntryPoint.sol";

contract Deploy06_SuperPaymaster is Script {
    // !!! PASTE ADDRESSES HERE !!!
    address constant REGISTRY_ADDR = 0x420046054375Ed73D9f8Fc5eb3F3FeEd67a8F3BA;
    address constant APNTS_ADDR = 0xDF58096a3854153deF74ea07Ac461aD48014fb6E;

    function run() external {
        require(REGISTRY_ADDR != address(0), "Registry address cannot be zero.");
        require(APNTS_ADDR != address(0), "aPNTs address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying SuperPaymasterV3 with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        IEntryPoint entryPoint = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD

        SuperPaymasterV3 superPaymaster = new SuperPaymasterV3(
            entryPoint,
            deployer, // owner
            Registry(registryAddr), // registry
            aPNTsAddr, // aPNTs token
            ethUsdPriceFeed, // price feed
            deployer  // protocol treasury
        );

        vm.stopBroadcast();

        console.log("✅ SuperPaymasterV3 deployed to:", address(superPaymaster));
    }
}
