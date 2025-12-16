// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/paymasters/v4/PaymasterV4_1i.sol";

contract DeployPaymasterFactoryV4 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("--- V4 Paymaster Factory Deployment ---");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("-------------------------------------");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy the implementation contract first
        PaymasterV4_1i implementation = new PaymasterV4_1i();
        console.log("PaymasterV4_1i (Implementation) deployed to:", address(implementation));

        // 2. Deploy the factory
        PaymasterFactory factory = new PaymasterFactory();
        console.log("PaymasterFactory deployed to:", address(factory));

        // 3. Register the implementation in the factory
        string memory version = "4.1i";
        factory.addImplementation(version, address(implementation));
        console.log("Implementation '", version, "' registered in the factory.");

        // 4. Set this version as the default
        factory.setDefaultVersion(version);
        console.log("Version '", version, "' set as default.");

        vm.stopBroadcast();

        console.log("--- V4 Factory Setup Complete ---");
    }
}
