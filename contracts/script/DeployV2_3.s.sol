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

        // Sepolia addresses (from @aastar/shared-config v0.3.4)
        address gtoken = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
        address gtokenStaking = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0;
        address registry = 0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696;
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
