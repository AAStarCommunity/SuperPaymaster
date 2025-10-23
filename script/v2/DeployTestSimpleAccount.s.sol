// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface ISimpleAccountFactory {
    function createAccount(address owner, uint256 salt) external returns (address);
    function getAddress(address owner, uint256 salt) external view returns (address);
}

contract DeployTestSimpleAccount is Script {
    function run() public {
        address factory = vm.envAddress("SIMPLE_ACCOUNT_FACTORY_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");

        console.log("=== Deploy Test SimpleAccount ===");
        console.log("Factory:", factory);
        console.log("Owner:", owner);

        ISimpleAccountFactory factoryContract = ISimpleAccountFactory(factory);

        // Get predicted address
        address predicted = factoryContract.getAddress(owner, 0);
        console.log("Predicted address:", predicted);

        // Deploy
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address account = factoryContract.createAccount(owner, 0);
        console.log("Deployed SimpleAccount:", account);
        vm.stopBroadcast();

        require(account == predicted, "Address mismatch");
        console.log("\n[SUCCESS] SimpleAccount deployed!");
    }
}
