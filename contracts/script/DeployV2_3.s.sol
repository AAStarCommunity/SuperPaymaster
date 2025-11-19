// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/SuperPaymasterV2_3.sol";

/**
 * @title Deploy SuperPaymasterV2_3
 * @notice Deployment script for SuperPaymasterV2.3 with gas optimizations
 * @dev Optimizations:
 *      - Removed supportedSBTs array → immutable DEFAULT_SBT (~10.8k gas saved)
 *      - Added updateXPNTsToken function for flexible token updates
 */
contract DeployV2_3 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Sepolia addresses
        address gtoken = 0x36b699a921fc792119D84f1429e2c00a38c09f7f;
        address gtokenStaking = 0x83f9554641b2Eb8984C4dD03D27f1f75EC537d36;
        address registry = 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F;
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD
        address defaultSBT = 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C; // MySBT

        vm.startBroadcast(deployerPrivateKey);

        SuperPaymasterV2_3 paymaster = new SuperPaymasterV2_3(
            gtoken,
            gtokenStaking,
            registry,
            ethUsdPriceFeed,
            defaultSBT
        );

        console.log("SuperPaymasterV2_3 deployed at:", address(paymaster));
        console.log("DEFAULT_SBT:", paymaster.DEFAULT_SBT());
        console.log("VERSION:", paymaster.VERSION());

        vm.stopBroadcast();
    }
}
