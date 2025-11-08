// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/SuperPaymasterV2.sol";

/**
 * @title DeploySuperPaymasterV2
 * @notice Deploy SuperPaymasterV2 v2.0.0 with VERSION interface
 */
contract DeploySuperPaymasterV2 is Script {
    function run() external {
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        address registry = vm.envAddress("REGISTRY");
        address ethUsdPriceFeed = vm.envAddress("ETH_USD_PRICE_FEED");
        address entrypoint = vm.envAddress("ENTRYPOINT_V07");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying SuperPaymasterV2 v2.0.0 ===");
        console.log("GTokenStaking:", gtokenStaking);
        console.log("Registry:", registry);
        console.log("ETH/USD Price Feed:", ethUsdPriceFeed);
        console.log("EntryPoint v0.7:", entrypoint);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        SuperPaymasterV2 superPaymaster = new SuperPaymasterV2(
            gtokenStaking,
            registry,
            ethUsdPriceFeed
        );

        console.log("SuperPaymasterV2 deployed:", address(superPaymaster));
        console.log("VERSION:", superPaymaster.VERSION());
        console.log("VERSION_CODE:", superPaymaster.VERSION_CODE());

        // Configure EntryPoint
        superPaymaster.setEntryPoint(entrypoint);
        console.log("EntryPoint configured:", entrypoint);

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("Address:", address(superPaymaster));
        console.log("Owner:", superPaymaster.owner());
    }
}
