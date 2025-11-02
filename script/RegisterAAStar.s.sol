// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Registry} from "../src/paymasters/v2/core/Registry.sol";

/**
 * @title RegisterAAStar
 * @notice Register AAStar community to Registry v2.1.3 (v0.2.10)
 */
contract RegisterAAStar is Script {
    // v0.2.10 Contract Addresses
    Registry public constant REGISTRY = Registry(0xb6286F53d8ff25eF99e6a43b2907B8e6BD0f019A);
    address public constant MYSBT = 0x73E635Fc9eD362b7061495372B6eDFF511D9E18F;
    address public constant APNTS = 0xBD0710596010a157B88cd141d797E8Ad4bb2306b;
    address public constant SUPER_PAYMASTER_V2 = 0x95B20d8FdF173a1190ff71e41024991B2c5e58eF;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Register AAStar Community ===");
        console.log("Deployer:", deployer);
        console.log("Registry:", address(REGISTRY));
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        // Prepare supportedSBTs array
        address[] memory supportedSBTs = new address[](1);
        supportedSBTs[0] = MYSBT;

        // Create CommunityProfile
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "AAStar",
            ensName: "aastar.eth",
            xPNTsToken: APNTS,
            supportedSBTs: supportedSBTs,
            nodeType: Registry.NodeType.PAYMASTER_SUPER, // 1
            paymasterAddress: SUPER_PAYMASTER_V2,
            community: address(0), // Will be set to msg.sender
            registeredAt: 0, // Will be set by contract
            lastUpdatedAt: 0, // Will be set by contract
            isActive: false // Will be set by contract
        });

        // Register with 0 stGToken (use existing locked stake)
        try REGISTRY.registerCommunity(profile, 0) {
            console.log("Successfully registered AAStar community!");
        } catch Error(string memory reason) {
            console.log("Registration failed:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Registration failed (low-level error)");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();

        // Verify registration
        try REGISTRY.getCommunity(deployer) returns (
            string memory name,
            string memory ensName,
            address xPNTsToken,
            address[] memory sbts,
            Registry.NodeType nodeType,
            address paymasterAddress,
            address community,
            uint256 registeredAt,
            uint256 lastUpdatedAt,
            bool isActive
        ) {
            console.log();
            console.log("=== Verification ===");
            console.log("Name:", name);
            console.log("ENS:", ensName);
            console.log("xPNTs Token:", xPNTsToken);
            console.log("Supported SBTs:", sbts.length);
            console.log("Is Active:", isActive);
        } catch {
            console.log();
            console.log("Community not found after registration attempt");
        }
    }
}
