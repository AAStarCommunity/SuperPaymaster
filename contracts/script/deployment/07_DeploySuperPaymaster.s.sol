// SPDX-License-Identifier: MIT
// 07_DeploySuperPaymaster.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import {IEntryPoint} from "account-abstraction-v7/interfaces/IEntryPoint.sol";

contract Deploy07_SuperPaymaster is Script {
    function run(address registryAddr, address apntsTokenAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");
        require(apntsTokenAddr != address(0), "aPNTs token address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying SuperPaymasterV3 with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        IEntryPoint entryPoint = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD

        SuperPaymasterV3 superPaymaster = new SuperPaymasterV3(
            entryPoint,
            deployer, // owner
            IRegistryV3(registryAddr),
            apntsTokenAddr,
            ethUsdPriceFeed,
            deployer  // protocol treasury
        );

        vm.stopBroadcast();

        console.log("SuperPaymasterV3 deployed to:", address(superPaymaster));
    }
}
