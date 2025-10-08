// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GasTokenFactoryV2} from "../src/GasTokenFactoryV2.sol";
import {GasTokenV2} from "../src/GasTokenV2.sol";

/**
 * @title DeployGasTokenV2
 * @notice Deploy GasTokenFactoryV2 and create PNTv2 token
 * @dev Run: forge script script/DeployGasTokenV2.s.sol:DeployGasTokenV2 --rpc-url sepolia --broadcast --verify -vvvv
 */
contract DeployGasTokenV2 is Script {
    // PaymasterV4 address
    address constant PAYMASTER_V4 = 0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445;

    // Token parameters
    string constant TOKEN_NAME = "Points Token V2";
    string constant TOKEN_SYMBOL = "PNTv2";
    uint256 constant EXCHANGE_RATE = 1e18; // 1:1 with base PNT

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== GasTokenV2 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("PaymasterV4:", PAYMASTER_V4);
        console.log("Token Name:", TOKEN_NAME);
        console.log("Token Symbol:", TOKEN_SYMBOL);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy GasTokenFactoryV2
        console.log("Step 1: Deploying GasTokenFactoryV2...");
        GasTokenFactoryV2 factory = new GasTokenFactoryV2();
        console.log("  Factory:", address(factory));
        console.log("");

        // Step 2: Create GasTokenV2 via Factory
        console.log("Step 2: Creating GasTokenV2...");
        address tokenAddress = factory.createToken(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            PAYMASTER_V4,
            EXCHANGE_RATE
        );
        console.log("  Token:", tokenAddress);
        console.log("");

        // Step 3: Verify deployment
        console.log("Step 3: Verifying deployment...");
        GasTokenV2 token = GasTokenV2(tokenAddress);
        console.log("  Name:", token.name());
        console.log("  Symbol:", token.symbol());
        console.log("  Owner:", token.owner());
        console.log("  Paymaster:", token.paymaster());
        console.log("");

        // Step 4: Mint initial tokens (1000 PNTv2)
        console.log("Step 4: Minting initial tokens...");
        uint256 mintAmount = 1000e18;
        token.mint(deployer, mintAmount);
        console.log("  Minted:", mintAmount / 1e18, TOKEN_SYMBOL);
        console.log("  Balance:", token.balanceOf(deployer) / 1e18, TOKEN_SYMBOL);
        console.log("  Allowance to Paymaster:", token.allowance(deployer, PAYMASTER_V4) == type(uint256).max ? "MAX" : "ERROR");
        console.log("");

        vm.stopBroadcast();

        // Summary
        console.log("=== Deployment Summary ===");
        console.log("GasTokenFactoryV2:", address(factory));
        console.log("GasTokenV2 (PNTv2):", tokenAddress);
        console.log("Initial Paymaster:", PAYMASTER_V4);
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Register token to PaymasterV4:");
        console.log("   cast send", PAYMASTER_V4);
        console.log("     'addSupportedGasToken(address)'", tokenAddress);
        console.log("     --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL");
        console.log("");
        console.log("2. Update faucet-app with new token address");
        console.log("3. Update documentation");
    }
}
