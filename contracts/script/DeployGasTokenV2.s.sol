// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../../src/tokens/GasTokenV2.sol";

/**
 * @title DeployGasTokenV2
 * @notice Deployment script for GasTokenV2 with price management
 * @dev Version 4.2 changes:
 *      - Added basePriceToken for derived tokens
 *      - Added priceUSD for base token pricing
 *      - Constructor now requires 6 parameters (was 4)
 *
 * @dev Environment Variables Required:
 *      TOKEN_NAME - Token name (e.g., "Alpha Points")
 *      TOKEN_SYMBOL - Token symbol (e.g., "aPNT")
 *      PAYMASTER_ADDRESS - PaymasterV4_1 address
 *      EXCHANGE_RATE - Exchange rate in 18 decimals (1e18 for 1:1)
 *
 * @dev For Base Tokens:
 *      BASE_PRICE_TOKEN - Set to "0x0" or omit
 *      PRICE_USD - USD price in 18 decimals (e.g., 0.02e18 = $0.02)
 *
 * @dev For Derived Tokens:
 *      BASE_PRICE_TOKEN - Address of base token (e.g., aPNT address)
 *      PRICE_USD - Ignored (can be 0)
 *      EXCHANGE_RATE - Multiplier (e.g., 4e18 = 1 derived = 4 base)
 */
contract DeployGasTokenV2 is Script {
    function run() external {
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");
        address paymasterAddress = vm.envAddress("PAYMASTER_ADDRESS");
        address basePriceToken = vm.envOr("BASE_PRICE_TOKEN", address(0));
        uint256 exchangeRate = vm.envUint("EXCHANGE_RATE");
        uint256 priceUSD = vm.envOr("PRICE_USD", uint256(0));

        require(paymasterAddress != address(0), "PAYMASTER_ADDRESS required");
        require(exchangeRate > 0, "EXCHANGE_RATE must be > 0");

        if (basePriceToken == address(0) && priceUSD == 0) {
            priceUSD = 0.02e18;
        }

        console.log("Deploying GasTokenV2:", tokenSymbol);
        console.log("  Paymaster:", paymasterAddress);
        console.log("  Exchange Rate:", exchangeRate);

        vm.startBroadcast();

        GasTokenV2 token = new GasTokenV2(
            tokenName,
            tokenSymbol,
            paymasterAddress,
            basePriceToken,
            exchangeRate,
            priceUSD
        );

        console.log("GasTokenV2 deployed:", address(token));
        console.log("Effective Price:", token.getEffectivePrice());

        vm.stopBroadcast();
    }
}
