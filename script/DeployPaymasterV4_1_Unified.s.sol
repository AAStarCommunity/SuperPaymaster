// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/paymasters/v4/PaymasterV4_1.sol";

/**
 * @title DeployPaymasterV4_1_Unified
 * @notice Deployment script for PaymasterV4_1 with unified xPNTs architecture
 * @dev Uses xPNTsFactory for aPNTs price instead of hardcoded pntPriceUSD
 *
 * @dev Usage (Sepolia with verification):
 *   forge script script/DeployPaymasterV4_1_Unified.s.sol:DeployPaymasterV4_1_Unified \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * @dev Required Environment Variables:
 *   - ENTRY_POINT: EntryPoint v0.7 address
 *   - OWNER_ADDRESS: Initial owner address
 *   - TREASURY_ADDRESS: Treasury for fee collection
 *   - ETH_USD_PRICE_FEED: Chainlink ETH/USD price feed address
 *   - SERVICE_FEE_RATE: Service fee in basis points (e.g., 500 = 5%)
 *   - MAX_GAS_COST_CAP: Maximum gas cost cap in wei
 *   - XPNTS_FACTORY_ADDRESS: xPNTs Factory contract address
 *   - REGISTRY_ADDRESS: SuperPaymasterRegistry address
 *
 * @dev Optional Environment Variables:
 *   - SBT_ADDRESS: Initial SBT contract (default: address(0))
 *   - GAS_TOKEN_ADDRESS: Initial GasToken (xPNTs) contract (default: address(0))
 *   - NETWORK: Network name for deployment file (default: "sepolia")
 */
contract DeployPaymasterV4_1_Unified is Script {
    function run() external {
        // Required parameters
        address entryPoint = vm.envAddress("ENTRY_POINT");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address ethUsdPriceFeed = vm.envAddress("ETH_USD_PRICE_FEED");
        uint256 serviceFeeRate = vm.envUint("SERVICE_FEE_RATE");
        uint256 maxGasCostCap = vm.envUint("MAX_GAS_COST_CAP");
        address xpntsFactory = vm.envAddress("XPNTS_FACTORY_ADDRESS");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");

        // Optional parameters
        address sbtAddress = vm.envOr("SBT_ADDRESS", address(0));
        address gasTokenAddress = vm.envOr("GAS_TOKEN_ADDRESS", address(0));

        _logDeploymentParams(
            entryPoint,
            owner,
            treasury,
            ethUsdPriceFeed,
            serviceFeeRate,
            maxGasCostCap,
            xpntsFactory,
            registryAddress,
            sbtAddress,
            gasTokenAddress
        );

        vm.startBroadcast();

        // Deploy PaymasterV4_1 with unified architecture
        PaymasterV4_1 paymaster = new PaymasterV4_1(
            entryPoint,
            owner,
            treasury,
            ethUsdPriceFeed,
            serviceFeeRate,
            maxGasCostCap,
            xpntsFactory,     // NEW: xPNTsFactory for dynamic aPNTs pricing
            sbtAddress,       // Initial SBT (optional)
            gasTokenAddress,  // Initial GasToken (optional)
            registryAddress   // Registry (required)
        );

        console.log("\n=== Deployment Successful ===");
        console.log("PaymasterV4_1:", address(paymaster));
        console.log("Version:", paymaster.version());

        vm.stopBroadcast();

        // Save deployment info
        _saveDeploymentInfo(
            paymaster,
            entryPoint,
            owner,
            treasury,
            ethUsdPriceFeed,
            xpntsFactory,
            registryAddress,
            sbtAddress,
            gasTokenAddress
        );

        // Print next steps
        _printNextSteps(address(paymaster), registryAddress);
    }

    function _logDeploymentParams(
        address entryPoint,
        address owner,
        address treasury,
        address ethUsdPriceFeed,
        uint256 serviceFeeRate,
        uint256 maxGasCostCap,
        address xpntsFactory,
        address registryAddress,
        address sbtAddress,
        address gasTokenAddress
    ) internal view {
        console.log("=== PaymasterV4_1 Unified Deployment ===");
        console.log("EntryPoint:", entryPoint);
        console.log("Owner:", owner);
        console.log("Treasury:", treasury);
        console.log("ETH/USD Price Feed:", ethUsdPriceFeed);
        console.log("Service Fee Rate:", serviceFeeRate, "bps");
        console.log("Max Gas Cost Cap:", maxGasCostCap);
        console.log("xPNTs Factory:", xpntsFactory, "(for aPNTs price)");
        console.log("Registry:", registryAddress);
        if (sbtAddress != address(0)) {
            console.log("Initial SBT:", sbtAddress);
        }
        if (gasTokenAddress != address(0)) {
            console.log("Initial GasToken:", gasTokenAddress);
        }
    }

    function _saveDeploymentInfo(
        PaymasterV4_1 paymaster,
        address entryPoint,
        address owner,
        address treasury,
        address ethUsdPriceFeed,
        address xpntsFactory,
        address registryAddress,
        address sbtAddress,
        address gasTokenAddress
    ) internal {
        string memory network = vm.envOr("NETWORK", string("sepolia"));
        string memory filename = string.concat("deployments/paymaster-v4_1-unified-", network, ".json");

        // Build JSON
        string memory part1 = string.concat(
            "{\n",
            '  "contract": "PaymasterV4_1",\n',
            '  "architecture": "unified-xpnts",\n',
            '  "paymaster": "', vm.toString(address(paymaster)), '",\n',
            '  "entryPoint": "', vm.toString(entryPoint), '",\n',
            '  "owner": "', vm.toString(owner), '",\n'
        );

        string memory part2 = string.concat(
            '  "treasury": "', vm.toString(treasury), '",\n',
            '  "ethUsdPriceFeed": "', vm.toString(ethUsdPriceFeed), '",\n',
            '  "xpntsFactory": "', vm.toString(xpntsFactory), '",\n',
            '  "registry": "', vm.toString(registryAddress), '",\n'
        );

        string memory part3 = string.concat(
            '  "initialSBT": "', vm.toString(sbtAddress), '",\n',
            '  "initialGasToken": "', vm.toString(gasTokenAddress), '",\n',
            '  "version": "', paymaster.version(), '",\n',
            '  "timestamp": ', vm.toString(block.timestamp), '\n',
            "}"
        );

        string memory deploymentInfo = string.concat(part1, part2, part3);

        vm.writeFile(filename, deploymentInfo);
        console.log("\nDeployment info saved to:", filename);
    }

    function _printNextSteps(address paymasterAddress, address registryAddress) internal view {
        console.log("\n=== Next Steps ===");
        console.log("1. Deposit ETH to EntryPoint:");
        console.log("   PaymasterV4_1(", paymasterAddress, ").addDeposit{value: X}()");
        console.log("");
        console.log("2. Add stake to EntryPoint:");
        console.log("   PaymasterV4_1(", paymasterAddress, ").addStake{value: X}(unstakeDelay)");
        console.log("");
        console.log("3. Register to SuperPaymasterRegistry:");
        console.log("   Registry(", registryAddress, ").registerPaymaster()");
        console.log("");
        console.log("4. Deploy xPNTs tokens:");
        console.log("   - Via frontend: /get-xpnts");
        console.log("   - Via script: xpntsFactory.deployxPNTsToken(...)");
        console.log("");
        console.log("5. Add xPNTs tokens to Paymaster:");
        console.log("   PaymasterV4_1(", paymasterAddress, ").addGasToken(xpntsTokenAddr)");
        console.log("");
        console.log("=== Unified Architecture Notes ===");
        console.log("- aPNTs price is fetched from xPNTsFactory.getAPNTsPrice()");
        console.log("- exchangeRate is fetched from xPNTsToken.exchangeRate()");
        console.log("- Calculation: gasCostUSD -> aPNTs -> xPNTs (two-step)");
    }
}
