// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

contract CheckGTokenBalance is Script {
    function run() external {
        // Sepolia testnet GToken contract address from shared-config
        address GTOKEN_ADDRESS = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
        address TARGET_ADDRESS = 0x2E9A5648F9dd7E8d70e3CBdA0C8b6Ada71Da4Ec9;
        
        console.log("=== GToken Balance Check ===");
        console.log("Network: Sepolia Testnet");
        console.log("GToken Contract:");
        console.logAddress(GTOKEN_ADDRESS);
        console.log("Target Address:");
        console.logAddress(TARGET_ADDRESS);
        console.log("");
        
        // Create contract instance
        IERC20 gtoken = IERC20(GTOKEN_ADDRESS);
        
        // Get token info
        string memory symbol = gtoken.symbol();
        uint8 decimals = gtoken.decimals();
        console.log("Contract found");
        console.log("Token Symbol:", symbol);
        console.log("Token Decimals:");
        console.logUint(uint256(decimals));
        
        // Get balance
        uint256 balance = gtoken.balanceOf(TARGET_ADDRESS);
        
        console.log("");
        console.log("=== Balance Results ===");
        console.log("Raw Balance:");
        console.logUint(balance);
        
        if (balance == 0) {
            console.log("Balance is 0 - This could mean:");
            console.log("   1. Address has no GToken");
            console.log("   2. Wrong contract address");
            console.log("   3. Mint transaction failed");
            console.log("   4. Network mismatch");
        } else {
            console.log("Balance found:");
            console.logUint(balance);
        }
    }
}