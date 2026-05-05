// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/PaymasterBase.sol";

/**
 * @title ConfigureStablecoins
 * @notice Configure stablecoin token prices on a deployed PaymasterV4 instance
 * @dev Usage:
 *   PAYMASTER_V4=0x... USDC_ADDR=0x... USDT_ADDR=0x... \
 *   forge script contracts/script/v4/ConfigureStablecoins.s.sol:ConfigureStablecoins \
 *     --rpc-url $RPC_URL --broadcast --account <keystore>
 *
 *   Set USDC_ADDR or USDT_ADDR to 0x0 to skip that token.
 */
contract ConfigureStablecoins is Script {
    // $1.00 in Chainlink 8-decimal format
    uint256 constant STABLECOIN_PRICE = 1e8;

    function run() external {
        address paymasterAddr = vm.envAddress("PAYMASTER_V4");
        require(paymasterAddr != address(0), "PAYMASTER_V4 not set");

        PaymasterBase paymaster = PaymasterBase(payable(paymasterAddr));

        // Read token addresses from env (0x0 = skip)
        address usdc = vm.envOr("USDC_ADDR", address(0));
        address usdt = vm.envOr("USDT_ADDR", address(0));

        vm.startBroadcast();

        if (usdc != address(0)) {
            paymaster.setTokenPrice(usdc, STABLECOIN_PRICE);
            console.log("USDC configured:", usdc);
            console.log("  price:", STABLECOIN_PRICE);
            console.log("  decimals:", paymaster.tokenDecimals(usdc));
        }

        if (usdt != address(0)) {
            paymaster.setTokenPrice(usdt, STABLECOIN_PRICE);
            console.log("USDT configured:", usdt);
            console.log("  price:", STABLECOIN_PRICE);
            console.log("  decimals:", paymaster.tokenDecimals(usdt));
        }

        // Print all supported tokens
        address[] memory tokens = paymaster.getSupportedTokens();
        console.log("\n--- Supported Tokens (%d) ---", tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("  [%d] %s", i, tokens[i]);
            console.log("       price=%d  dec=%d",
                paymaster.tokenPrices(tokens[i]),
                paymaster.tokenDecimals(tokens[i])
            );
        }

        vm.stopBroadcast();
    }
}
