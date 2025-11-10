// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Registry} from "src/paymasters/v2/core/Registry.sol";

/**
 * @title DeployRegistry v2.2.0
 * @notice Deployment script for Registry v2.2.0 with auto-stake functionality
 *
 * Usage:
 *   forge script script/DeployRegistry.s.sol:DeployRegistry \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 */
contract DeployRegistry is Script {
    // Sepolia addresses
    address constant GTOKEN_SEPOLIA = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
    address constant GTOKEN_STAKING_SEPOLIA = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("================================================================================");
        console2.log("Deploying Registry v2.2.0");
        console2.log("================================================================================");
        console2.log("Deployer:", deployer);
        console2.log("GToken:", GTOKEN_SEPOLIA);
        console2.log("GTokenStaking:", GTOKEN_STAKING_SEPOLIA);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Registry v2.2.0
        Registry registry = new Registry(
            GTOKEN_SEPOLIA,
            GTOKEN_STAKING_SEPOLIA
        );

        console2.log("Registry v2.2.0 deployed at:", address(registry));
        console2.log("Version:", registry.VERSION());
        console2.log("Version Code:", registry.VERSION_CODE());

        vm.stopBroadcast();

        console2.log("");
        console2.log("================================================================================");
        console2.log("Deployment Complete!");
        console2.log("================================================================================");
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Verify contract on Etherscan");
        console2.log("2. Configure node types (A/B/C nodes, SuperPaymaster)");
        console2.log("3. Set oracle address");
        console2.log("4. Update frontend to use new Registry address");
        console2.log("5. Test registerCommunityWithAutoStake function");
        console2.log("");
        console2.log("Etherscan verification:");
        console2.log("  forge verify-contract", address(registry));
        console2.log("    --chain-id 11155111 \\");
        console2.log("    --constructor-args $(cast abi-encode 'constructor(address,address)'", GTOKEN_SEPOLIA, GTOKEN_STAKING_SEPOLIA, ")");
    }
}
