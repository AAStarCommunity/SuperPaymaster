// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/PaymasterV4_1.sol";

contract Deploy13b_PaymasterV4_Direct is Script {
    function run(
        address xpntsFactory,
        address feeTokenAddr, // bPNTs
        address sbtAddr,      // MySBT
        address registryAddr  // Registry
    ) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying Paymaster V4 (Direct) with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Config
        address entryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        address treasury = deployer; 
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
        uint256 serviceFeeRate = 200; 
        uint256 maxGasCostCap = 5000000;
        
        // Direct deployment (V4.1 is constructor-based)
        PaymasterV4_1 pm = new PaymasterV4_1(
            entryPoint,
            deployer, 
            treasury,
            ethUsdPriceFeed,
            serviceFeeRate,
            maxGasCostCap,
            xpntsFactory,
            sbtAddr,
            feeTokenAddr,
            registryAddr
        );

        vm.stopBroadcast();

        console.log("Paymaster V4 Instance (Direct) deployed to:", address(pm));
    }
}
