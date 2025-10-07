// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import "../src/SuperPaymasterV6.sol";
import "../src/SuperPaymasterV7.sol";
import "../src/SuperPaymasterV8.sol";

contract DeploySuperpaymaster is Script {
    // Sepolia EntryPoint addresses
    address constant ENTRY_POINT_V6 = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address constant ENTRY_POINT_V7 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ENTRY_POINT_V8 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying SuperPaymaster contracts for all EntryPoint versions...");
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SuperPaymasterV6
        SuperPaymasterV6 superPaymasterV6 = new SuperPaymasterV6(
            ENTRY_POINT_V6,
            deployer,      // owner
            250           // 2.5% router fee rate
        );

        // Deploy SuperPaymasterV7
        SuperPaymasterV7 superPaymasterV7 = new SuperPaymasterV7(
            ENTRY_POINT_V7,
            deployer,      // owner
            250           // 2.5% router fee rate
        );

        // Deploy SuperPaymasterV8
        SuperPaymasterV8 superPaymasterV8 = new SuperPaymasterV8(
            ENTRY_POINT_V8,
            deployer,      // owner
            250           // 2.5% router fee rate
        );

        // Deposit some ETH to each SuperPaymaster for operations
        uint256 initialDeposit = 0.05 ether; // 0.05 ETH per contract
        superPaymasterV6.deposit{value: initialDeposit}();
        superPaymasterV7.deposit{value: initialDeposit}();
        superPaymasterV8.deposit{value: initialDeposit}();

        vm.stopBroadcast();

        // Log deployment addresses
        console.log("\n=== DEPLOYMENT SUCCESSFUL ===");
        console.log("SuperPaymasterV6:", address(superPaymasterV6));
        console.log("SuperPaymasterV7:", address(superPaymasterV7));
        console.log("SuperPaymasterV8:", address(superPaymasterV8));
        console.log("Initial deposit per contract:", initialDeposit);
        
        // Output environment variables format
        console.log("\n=== UPDATE .env.local ===");
        console.log('NEXT_PUBLIC_SUPER_PAYMASTER_V6="%s"', address(superPaymasterV6));
        console.log('NEXT_PUBLIC_SUPER_PAYMASTER_V7="%s"', address(superPaymasterV7));
        console.log('NEXT_PUBLIC_SUPER_PAYMASTER_V8="%s"', address(superPaymasterV8));
        
        // Verify deployed versions
        console.log("\n=== CONTRACT VERSIONS ===");
        console.log("V6 Version:", superPaymasterV6.getVersion());
        console.log("V7 Version:", superPaymasterV7.getVersion());
        console.log("V8 Version:", superPaymasterV8.getVersion());
        
        // Verify deposits
        console.log("\n=== CONTRACT BALANCES ===");
        console.log("V6 Balance:", superPaymasterV6.getDeposit());
        console.log("V7 Balance:", superPaymasterV7.getDeposit());
        console.log("V8 Balance:", superPaymasterV8.getDeposit());
        
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Copy the addresses above to your frontend .env.local");
        console.log("2. Restart your frontend application");
        console.log("3. Paymaster operators can now register their paymasters");
        console.log("4. Test the deployment with the management dashboard");
    }
}