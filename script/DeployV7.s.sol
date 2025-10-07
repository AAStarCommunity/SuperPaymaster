// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/SuperPaymasterV7.sol";

contract DeployV7 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address entryPoint = vm.envAddress("ENTRY_POINT");
        address owner = vm.envAddress("SuperPaymaster_Owner");
        uint256 routerFeeRate = 250; // 2.5%

        vm.startBroadcast(deployerPrivateKey);

        SuperPaymasterV7 registry = new SuperPaymasterV7(
            entryPoint,
            owner,
            routerFeeRate
        );

        console.log("SuperPaymasterV7 deployed at:", address(registry));

        vm.stopBroadcast();

        // Save deployment address
        string memory deploymentInfo = string.concat(
            '{\n',
            '  "SuperPaymasterV7": "', vm.toString(address(registry)), '",\n',
            '  "EntryPoint": "', vm.toString(entryPoint), '",\n',
            '  "Owner": "', vm.toString(owner), '",\n',
            '  "RouterFeeRate": "250"\n',
            '}'
        );

        vm.writeFile("deployments/v7-sepolia-latest.json", deploymentInfo);
    }
}
