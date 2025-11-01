// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/core/Registry.sol";

/**
 * @title RegisterCommunities
 * @notice Register AAStar and BuilderDAO communities in Registry
 */
contract RegisterCommunities is Script {
    function run() external {
        address registry = vm.envAddress("REGISTRY");
        address aPNTs = vm.envAddress("APNTS_ADDRESS");
        address bPNTs = vm.envAddress("BPNTS_ADDRESS");
        uint256 deployer1PrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 deployer2PrivateKey = vm.envUint("PRIVATE_KEY_DEPLOYER2");

        Registry registryContract = Registry(registry);

        console.log("=== Registering Communities ===");
        console.log("Registry:", registry);
        console.log();

        // Register AAStar Community (deployer1)
        console.log("Registering AAStar Community...");
        vm.startBroadcast(deployer1PrivateKey);

        address[] memory supportedSBTs = new address[](0);

        Registry.CommunityProfile memory aastarProfile = Registry.CommunityProfile({
            name: "AAStar",
            ensName: "aastar.eth",
            xPNTsToken: aPNTs,
            supportedSBTs: supportedSBTs,
            nodeType: Registry.NodeType.PAYMASTER_SUPER,
            paymasterAddress: address(0),  // use SuperPaymaster
            community: address(0),          // will be set to msg.sender
            registeredAt: 0,                // will be set by function
            lastUpdatedAt: 0,               // will be set by function
            isActive: true,
            allowPermissionlessMint: true
        });

        registryContract.registerCommunity(aastarProfile, 50 ether);

        vm.stopBroadcast();
        console.log("AAStar registered by:", vm.addr(deployer1PrivateKey));
        console.log();

        // Register BuilderDAO Community (deployer2)
        console.log("Registering BuilderDAO Community...");
        vm.startBroadcast(deployer2PrivateKey);

        Registry.CommunityProfile memory builderDaoProfile = Registry.CommunityProfile({
            name: "BuilderDAO",
            ensName: "builderdao.eth",
            xPNTsToken: bPNTs,
            supportedSBTs: supportedSBTs,
            nodeType: Registry.NodeType.PAYMASTER_SUPER,
            paymasterAddress: address(0),  // use SuperPaymaster
            community: address(0),          // will be set to msg.sender
            registeredAt: 0,                // will be set by function
            lastUpdatedAt: 0,               // will be set by function
            isActive: true,
            allowPermissionlessMint: true
        });

        registryContract.registerCommunity(builderDaoProfile, 50 ether);

        vm.stopBroadcast();
        console.log("BuilderDAO registered by:", vm.addr(deployer2PrivateKey));
        console.log();

        console.log("=== Registration Complete ===");
    }
}
