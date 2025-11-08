// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/tokens/xPNTsFactory.sol";
import "src/paymasters/v2/tokens/xPNTsToken.sol";

/**
 * @title DeployAAStarPNTs
 * @notice Deploy AAStar community xPNTs token (aPNTs)
 *
 * @dev AAStar Points (aPNTs):
 *   - Base community token for AAStar ecosystem
 *   - 1:1 exchange rate with system aPNTs
 *   - Sold as recharge cards in Shops (100 points @ 97% = 1.94 USD)
 *
 * @dev Usage:
 *   XPNTS_FACTORY_ADDRESS=0x... \
 *   AASTAR_OWNER=0x... \
 *   forge script script/DeployAAStarPNTs.s.sol:DeployAAStarPNTs \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     -vvv
 */
contract DeployAAStarPNTs is Script {
    function run() external {
        // Load configuration
        address factoryAddress = vm.envAddress("XPNTS_FACTORY_ADDRESS");
        address aastarOwner = vm.envOr("AASTAR_OWNER", msg.sender);

        console.log("=== Deploying AAStar Points (aPNTs) ===");
        console.log("Factory:", factoryAddress);
        console.log("Owner:", aastarOwner);
        console.log("");

        xPNTsFactory factory = xPNTsFactory(factoryAddress);

        // Token parameters
        string memory name = "AAStar Points";
        string memory symbol = "aPNT";
        string memory communityName = "AAStar";
        string memory communityENS = "aastar.eth";
        uint256 exchangeRate = 1 ether; // 1:1 with system aPNTs

        vm.startBroadcast();

        // Deploy through factory (6-parameter deployment)
        address tokenAddress = factory.deployxPNTsToken(
            name,
            symbol,
            communityName,
            communityENS,
            exchangeRate,
            address(0) // paymasterAOA (optional, can be address(0))
        );

        xPNTsToken token = xPNTsToken(tokenAddress);

        console.log("====================================");
        console.log("Deployment Successful!");
        console.log("====================================");
        console.log("AAStar aPNT Token:", address(token));
        console.log("");

        // Verify configuration
        console.log("Token Configuration:");
        console.log("  Name:", token.name());
        console.log("  Symbol:", token.symbol());
        console.log("  Owner:", token.communityOwner());
        console.log("  Community:", token.communityName());
        console.log("  ENS:", token.communityENS());
        console.log("  Exchange Rate:", token.exchangeRate() / 1e18, ":1 (aPNT:xPNT)");
        console.log("");

        vm.stopBroadcast();

        console.log("====================================");
        console.log("Next Steps:");
        console.log("====================================");
        console.log("1. Update .env:");
        console.log("   AASTAR_APNT_TOKEN=", address(token));
        console.log("");
        console.log("2. Mint initial supply (if needed):");
        console.log("   token.mint(recipient, amount)");
        console.log("");
        console.log("3. Integration with Shops:");
        console.log("   - Recharge card: 100 aPNT");
        console.log("   - Price: 0.97 * 100 * 0.02 USD = 1.94 USD");
        console.log("   - Users can deposit aPNT -> system aPNTs (1:1)");
        console.log("");
        console.log("4. Register AAStar community in Registry (optional):");
        console.log("   registry.registerCommunity(...)");
    }
}
