// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/vendor/account-abstraction/contracts/accounts/SimpleAccountFactory.sol";
import "../src/vendor/account-abstraction/contracts/accounts/SimpleAccount.sol";
import "../src/vendor/account-abstraction/contracts/interfaces/IEntryPoint.sol";

/**
 * @title DeploySimpleAccountFactory
 * @notice Deploy official SimpleAccountFactory for EntryPoint v0.7
 * @dev Used for E2E testing with PaymasterV3
 */
contract DeploySimpleAccountFactory is Script {
    // EntryPoint v0.7 on Sepolia
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Deploying SimpleAccountFactory ===");
        console.log("Deployer:", deployer);
        console.log("EntryPoint v0.7:", ENTRYPOINT_V07);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SimpleAccountFactory
        SimpleAccountFactory factory = new SimpleAccountFactory(IEntryPoint(ENTRYPOINT_V07));

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("SimpleAccountFactory:", address(factory));
        console.log("Account Implementation:", address(factory.accountImplementation()));

        // Test address calculation
        address testOwner = deployer; // Use deployer as test owner
        uint256 testSalt = 0;
        address predictedAccount = factory.getAddress(testOwner, testSalt);

        console.log("\n=== Address Calculation Test ===");
        console.log("Owner:", testOwner);
        console.log("Salt:", testSalt);
        console.log("Predicted Account Address:", predictedAccount);

        // Verify it's not the factory address
        require(predictedAccount != address(factory), "Address calculation failed");
        console.log("Address calculation working correctly");

        console.log("\n=== Copy to .env.v3 ===");
        console.log("SIMPLE_ACCOUNT_FACTORY=", address(factory));
    }
}
