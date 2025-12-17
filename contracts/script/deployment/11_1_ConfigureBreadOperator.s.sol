// SPDX-License-Identifier: MIT
// 11_1_ConfigureBreadOperator.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";

contract Deploy11_1_ConfigureBreadOperator is Script {
    function run(address superPaymasterAddr, address bPNTsTokenAddr) external {
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");
        require(bPNTsTokenAddr != address(0), "bPNTs token address cannot be zero.");

        // Anni is the Community Owner, so she must configure the Operator logic for her community.
        // Or if the Paymaster checks msg.sender == Community Owner?
        // Usually configureOperator is called by the Community Admin to set up their Gas Token.
        // So we need Anni's key here.
        uint256 anniPrivateKey = vm.envUint("PRIVATE_KEY_ANNI");
        address anniAddr = vm.addr(anniPrivateKey);
        
        console.log("Configuring Bread Operator in SuperPaymaster with account:", anniAddr);

        vm.startBroadcast(anniPrivateKey);

        // Anni (Bread Community) configures her Operator settings
        // Token: bPNTs
        // Treasury: Anni
        // Exchange Rate: 1:1
        SuperPaymasterV3(superPaymasterAddr).configureOperator(
            bPNTsTokenAddr, 
            anniAddr,       
            1e18            
        );

        vm.stopBroadcast();

        console.log("Successfully configured BreadCommunity Operator (Anni) in SuperPaymaster.");
    }
}
