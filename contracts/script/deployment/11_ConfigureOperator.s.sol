// SPDX-License-Identifier: MIT
// 11_ConfigureOperator.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

contract Deploy11_ConfigureOperator is Script {
    function run(address superPaymasterAddr, address apntsTokenAddr) external {
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");
        require(apntsTokenAddr != address(0), "aPNTs token address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Configuring Operator in SuperPaymaster with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // As the deployer (who is now a registered community),
        // we configure our operator settings in the SuperPaymaster.
        // This links our community identity to the token we will use for gas payments.
        SuperPaymaster(superPaymasterAddr).configureOperator(
            apntsTokenAddr, // The token users will be charged in
            deployer,       // The treasury to receive fees (can be the deployer itself)
            1e18            // The exchange rate (1:1)
        );

        vm.stopBroadcast();

        console.log("Successfully configured deployer as an operator in SuperPaymaster.");
        console.log("System is now fully initialized and ready to use.");
    }
}
