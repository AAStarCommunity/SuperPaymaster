// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import "../src/SuperPaymasterV7.sol";

contract DeployV7Only is Script {
    address constant ENTRY_POINT_V7 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying SuperPaymasterV7...");
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        SuperPaymasterV7 superPaymasterV7 = new SuperPaymasterV7(
            ENTRY_POINT_V7,
            deployer,
            250  // 2.5% router fee rate
        );

        // Deposit some ETH
        uint256 initialDeposit = 0.01 ether;
        superPaymasterV7.deposit{value: initialDeposit}();

        vm.stopBroadcast();

        console.log("\n=== DEPLOYMENT SUCCESSFUL ===");
        console.log("SuperPaymasterV7:", address(superPaymasterV7));
        console.log("Version:", superPaymasterV7.getVersion());
        console.log("Deposit:", superPaymasterV7.getDeposit());
        
        console.log("\n=== UPDATE .env.v3 ===");
        console.log('SUPER_PAYMASTER="%s"', address(superPaymasterV7));
    }
}
