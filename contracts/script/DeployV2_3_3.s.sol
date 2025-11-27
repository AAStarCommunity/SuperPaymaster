// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/SuperPaymasterV2_3_3.sol";

contract DeployV2_3_3 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Sepolia addresses (from @aastar/shared-config v0.3.4)
        address entryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032; // EntryPoint v0.7
        address gtoken = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
        address gtokenStaking = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0;
        address registry = 0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696;
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        address defaultSBT = 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C;

        vm.startBroadcast(deployerPrivateKey);

        SuperPaymasterV2_3_3 paymaster = new SuperPaymasterV2_3_3(
            entryPoint,
            gtoken,
            gtokenStaking,
            registry,
            ethUsdPriceFeed,
            defaultSBT
        );

        console.log("SuperPaymasterV2_3_3 deployed at:", address(paymaster));
        console.log("EntryPoint:", address(paymaster.entryPoint()));
        console.log("DEFAULT_SBT:", paymaster.DEFAULT_SBT());
        console.log("VERSION:", paymaster.VERSION());
        console.log("VERSION_CODE:", paymaster.VERSION_CODE());
        console.log("");
        console.log("V2.3.3 Improvements:");
        console.log("  - COMPLIANCE: PostOp payment (xPNTs transfer after validation)");
        console.log("  - SECURITY: No state changes in validation phase");
        console.log("  - GAS: Optimized xPNTs handling");

        vm.stopBroadcast();
    }
}
