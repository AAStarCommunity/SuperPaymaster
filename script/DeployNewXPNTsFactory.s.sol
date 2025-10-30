// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/tokens/xPNTsFactory.sol";

/**
 * @title DeployNewXPNTsFactory
 * @notice 部署统一架构的xPNTsFactory（支持6参数和aPNTs价格管理）
 *
 * @dev Usage:
 *   forge script script/DeployNewXPNTsFactory.s.sol:DeployNewXPNTsFactory \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvv
 *
 * @dev Required Environment Variables:
 *   - SUPER_PAYMASTER_V2_ADDRESS: SuperPaymaster V2 contract address
 *   - REGISTRY_ADDRESS: Registry contract address
 *   - DEPLOYER_ADDRESS: Deployer/owner address
 */
contract DeployNewXPNTsFactory is Script {
    function run() external {
        // Load configuration
        address superPaymaster = vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS");
        address registry = vm.envAddress("REGISTRY_ADDRESS");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("=== Deploying New xPNTsFactory (Unified Architecture) ===");
        console.log("SuperPaymaster V2:", superPaymaster);
        console.log("Registry:", registry);
        console.log("Owner:", deployer);
        console.log("");

        vm.startBroadcast();

        // Deploy new xPNTsFactory with unified architecture
        xPNTsFactory factory = new xPNTsFactory(
            superPaymaster,  // SuperPaymaster V2 address
            registry         // Registry address
        );

        console.log("====================================");
        console.log("Deployment Successful!");
        console.log("====================================");
        console.log("New xPNTsFactory:", address(factory));
        console.log("");

        // Verify initial state
        console.log("Initial Configuration:");
        console.log("  aPNTs Price USD:", factory.getAPNTsPrice());
        console.log("  Expected: 20000000000000000 (0.02 USD)");
        console.log("  Owner:", factory.owner());
        console.log("");

        // Deployment info logged to console (writeFile disabled for broadcast compatibility)
        console.log("Deployment JSON:");
        console.log("  Contract: xPNTsFactory");
        console.log("  Architecture: unified");
        console.log("  Address:", address(factory));
        console.log("  Timestamp:", block.timestamp);

        vm.stopBroadcast();

        console.log("====================================");
        console.log("Next Steps:");
        console.log("====================================");
        console.log("1. Update .env with new factory address:");
        console.log("   XPNTS_FACTORY_ADDRESS=", address(factory));
        console.log("");
        console.log("2. Update frontend .env:");
        console.log("   VITE_XPNTS_FACTORY_ADDRESS=", address(factory));
        console.log("");
        console.log("3. Test xPNTs deployment:");
        console.log("   - Open frontend: http://localhost:3000/get-xpnts");
        console.log("   - Deploy a test token");
        console.log("   - Verify 6-parameter deployment works");
        console.log("");
        console.log("4. Verify on Etherscan:");
        console.log("   https://sepolia.etherscan.io/address/", address(factory));
    }
}
