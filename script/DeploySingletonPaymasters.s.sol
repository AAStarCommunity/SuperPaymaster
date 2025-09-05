// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import "../singleton-paymaster/src/SingletonPaymasterV6.sol";
import "../singleton-paymaster/src/SingletonPaymasterV7.sol";
import "../singleton-paymaster/src/SingletonPaymasterV8.sol";

contract DeploySingletonPaymasters is Script {
    // Sepolia EntryPoint addresses
    address constant ENTRY_POINT_V6 = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address constant ENTRY_POINT_V7 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ENTRY_POINT_V8 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("SEPOLIA_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying Singleton Paymaster contracts...");
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Create signers array with deployer as default signer
        address[] memory signers = new address[](1);
        signers[0] = deployer;

        // Deploy SingletonPaymasterV6
        SingletonPaymasterV6 singletonPaymasterV6 = new SingletonPaymasterV6(
            ENTRY_POINT_V6,
            deployer,      // owner
            deployer,      // manager (can be same as owner)
            signers        // authorized signers
        );

        // Deploy SingletonPaymasterV7
        SingletonPaymasterV7 singletonPaymasterV7 = new SingletonPaymasterV7(
            ENTRY_POINT_V7,
            deployer,      // owner
            deployer,      // manager
            signers        // authorized signers
        );

        // Deploy SingletonPaymasterV8
        SingletonPaymasterV8 singletonPaymasterV8 = new SingletonPaymasterV8(
            ENTRY_POINT_V8,
            deployer,      // owner
            deployer,      // manager
            signers        // authorized signers
        );

        // Deposit some ETH to each paymaster for operations
        uint256 initialDeposit = 0.1 ether;
        
        singletonPaymasterV6.deposit{value: initialDeposit}();
        singletonPaymasterV7.deposit{value: initialDeposit}();
        singletonPaymasterV8.deposit{value: initialDeposit}();

        vm.stopBroadcast();

        // Log deployment addresses
        console.log("\n=== DEPLOYMENT SUCCESSFUL ===");
        console.log("SingletonPaymasterV6:", address(singletonPaymasterV6));
        console.log("SingletonPaymasterV7:", address(singletonPaymasterV7));
        console.log("SingletonPaymasterV8:", address(singletonPaymasterV8));
        console.log("Initial deposit per contract:", initialDeposit);
        
        // Output environment variables format
        console.log("\n=== UPDATE .env.local ===");
        console.log('NEXT_PUBLIC_SINGLETON_PAYMASTER_V6="%s"', address(singletonPaymasterV6));
        console.log('NEXT_PUBLIC_SINGLETON_PAYMASTER_V7="%s"', address(singletonPaymasterV7));
        console.log('NEXT_PUBLIC_SINGLETON_PAYMASTER_V8="%s"', address(singletonPaymasterV8));
        
        // Verify deposits
        console.log("\n=== CONTRACT BALANCES ===");
        console.log("V6 Balance:", singletonPaymasterV6.getDeposit());
        console.log("V7 Balance:", singletonPaymasterV7.getDeposit());
        console.log("V8 Balance:", singletonPaymasterV8.getDeposit());
    }
}