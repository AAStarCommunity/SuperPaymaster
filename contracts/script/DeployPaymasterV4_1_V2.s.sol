// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../../src/paymasters/v4/PaymasterV4_1.sol";
import "./ChainlinkFeeds.sol";

/**
 * @title DeployPaymasterV4_1_V2
 * @notice Deployment script for PaymasterV4_1 v4.2 with Chainlink integration
 * @dev Version 4.2 changes:
 *      - Uses Chainlink for ETH/USD price (replaces gasToUSDRate)
 *      - Token prices managed by GasToken contracts (replaces pntPriceUSD)
 *      - Registry address is immutable (set in constructor)
 *
 * @dev Environment Variables Required:
 *      ENTRY_POINT - EntryPoint v0.7 address
 *      OWNER_ADDRESS - Paymaster owner address
 *      TREASURY_ADDRESS - Fee collection address
 *      SERVICE_FEE_RATE - Fee in basis points (200 = 2%)
 *      MAX_GAS_COST_CAP - Maximum gas cost per transaction (wei)
 *      MIN_TOKEN_BALANCE - Minimum token balance required (wei)
 *      REGISTRY_ADDRESS - SuperPaymasterRegistry address (required, immutable)
 *
 * @dev Optional Environment Variables:
 *      CHAINLINK_ETH_USD_FEED - Custom Chainlink feed (auto-detected by chainId if not set)
 *      SBT_ADDRESS - Initial SBT contract address
 *      GAS_TOKEN_ADDRESS - Initial GasToken contract address
 *      NETWORK - Network name for deployment file (default: auto-detect)
 *
 * @dev Usage (Sepolia):
 *   forge script script/DeployPaymasterV4_1_V2.s.sol:DeployPaymasterV4_1_V2 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * @dev Example .env file:
 *   ENTRY_POINT=0x0000000071727De22E5E9d8BAf0edAc6f37da032
 *   OWNER_ADDRESS=0x...
 *   TREASURY_ADDRESS=0x...
 *   SERVICE_FEE_RATE=200
 *   MAX_GAS_COST_CAP=1000000000000000000
 *   MIN_TOKEN_BALANCE=1000000000000000000000
 *   REGISTRY_ADDRESS=0x...
 *   SBT_ADDRESS=0x...
 *   GAS_TOKEN_ADDRESS=0x...
 */
contract DeployPaymasterV4_1_V2 is Script {
    function run() external {
        // Load required environment variables
        address entryPoint = vm.envAddress("ENTRY_POINT");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 serviceFeeRate = vm.envUint("SERVICE_FEE_RATE");
        uint256 maxGasCostCap = vm.envUint("MAX_GAS_COST_CAP");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");

        // Get Chainlink price feed (auto-detect or custom)
        address chainlinkFeed = _getChainlinkFeed();

        // Optional addresses
        address sbtAddress = vm.envOr("SBT_ADDRESS", address(0));
        address gasTokenAddress = vm.envOr("GAS_TOKEN_ADDRESS", address(0));

        // Validate inputs
        require(registryAddress != address(0), "REGISTRY_ADDRESS is required (immutable)");

        _logDeploymentParams(
            entryPoint,
            owner,
            treasury,
            chainlinkFeed,
            serviceFeeRate,
            maxGasCostCap,
            registryAddress,
            sbtAddress,
            gasTokenAddress
        );

        vm.startBroadcast();

        // Deploy PaymasterV4_1
        PaymasterV4_1 paymaster = new PaymasterV4_1(
            entryPoint,
            owner,
            treasury,
            chainlinkFeed,       // NEW: Chainlink ETH/USD feed
            serviceFeeRate,
            maxGasCostCap,
            sbtAddress,          // Initial SBT (optional)
            gasTokenAddress,     // Initial GasToken (optional)
            registryAddress      // NEW: Immutable registry
        );

        console.log("\n=== Deployment Successful ===");
        console.log("PaymasterV4_1:", address(paymaster));
        console.log("Version:", paymaster.version());
        console.log("Registry (immutable):", address(paymaster.registry()));
        console.log("Chainlink Feed:", address(paymaster.ethUsdPriceFeed()));

        // Verify configuration
        _verifyConfiguration(paymaster, sbtAddress, gasTokenAddress);

        vm.stopBroadcast();

        // Save deployment info
        _saveDeploymentInfo(
            paymaster,
            entryPoint,
            owner,
            treasury,
            chainlinkFeed,
            registryAddress,
            sbtAddress,
            gasTokenAddress
        );

        // Print next steps
        _printNextSteps(address(paymaster), registryAddress);
    }

    function _getChainlinkFeed() internal view returns (address) {
        // Try to get custom feed from env
        address customFeed = vm.envOr("CHAINLINK_ETH_USD_FEED", address(0));
        if (customFeed != address(0)) {
            console.log("Using custom Chainlink feed from env:", customFeed);
            return customFeed;
        }

        // Auto-detect based on chainId
        uint256 chainId = block.chainid;

        if (!ChainlinkFeeds.isNetworkSupported(chainId)) {
            revert(
                string.concat(
                    "Unsupported network (chainId: ",
                    vm.toString(chainId),
                    "). Set CHAINLINK_ETH_USD_FEED manually."
                )
            );
        }

        address feed = ChainlinkFeeds.getETHUSDFeed(chainId);
        string memory networkName = ChainlinkFeeds.getNetworkName(chainId);

        console.log("Auto-detected network:", networkName);
        console.log("Using Chainlink feed:", feed);

        return feed;
    }

    function _logDeploymentParams(
        address entryPoint,
        address owner,
        address treasury,
        address chainlinkFeed,
        uint256 serviceFeeRate,
        uint256 maxGasCostCap,
        address registryAddress,
        address sbtAddress,
        address gasTokenAddress
    ) internal view {
        console.log("=== PaymasterV4_1 v4.2 Deployment ===");
        console.log("Network:", ChainlinkFeeds.getNetworkName(block.chainid));
        console.log("Chain ID:", block.chainid);
        console.log("");
        console.log("Core Addresses:");
        console.log("  EntryPoint:", entryPoint);
        console.log("  Owner:", owner);
        console.log("  Treasury:", treasury);
        console.log("");
        console.log("Pricing (NEW):");
        console.log("  Chainlink ETH/USD Feed:", chainlinkFeed);
        console.log("  (Token prices managed by GasToken contracts)");
        console.log("");
        console.log("Parameters:");
        console.log("  ServiceFeeRate:", serviceFeeRate, "bps");
        console.log("  MaxGasCostCap:", maxGasCostCap, "wei");
        console.log("");
        console.log("Registry (Immutable):");
        console.log("  Registry:", registryAddress);
        console.log("");
        if (sbtAddress != address(0) || gasTokenAddress != address(0)) {
            console.log("Initial Resources:");
            if (sbtAddress != address(0)) {
                console.log("  SBT:", sbtAddress);
            }
            if (gasTokenAddress != address(0)) {
                console.log("  GasToken:", gasTokenAddress);
            }
        }
    }

    function _verifyConfiguration(
        PaymasterV4_1 paymaster,
        address sbtAddress,
        address gasTokenAddress
    ) internal view {
        console.log("\n=== Configuration Verification ===");

        // Verify basic state
        console.log("Owner:", paymaster.owner());
        console.log("Treasury:", paymaster.treasury());
        console.log("Service Fee Rate:", paymaster.serviceFeeRate(), "bps");
        console.log("Max Gas Cost Cap:", paymaster.maxGasCostCap(), "wei");

        // Verify immutable addresses
        console.log("Registry (immutable):", address(paymaster.registry()));
        console.log("Chainlink Feed (immutable):", address(paymaster.ethUsdPriceFeed()));

        // Verify registry is set
        bool registrySet = paymaster.isRegistrySet();
        console.log("Registry Set:", registrySet ? "Yes" : "No");

        // Verify initial resources
        if (sbtAddress != address(0)) {
            bool sbtAdded = paymaster.isSBTSupported(sbtAddress);
            console.log("Initial SBT Added:", sbtAdded ? "Yes" : "No");
        }

        if (gasTokenAddress != address(0)) {
            bool tokenAdded = paymaster.isGasTokenSupported(gasTokenAddress);
            console.log("Initial GasToken Added:", tokenAdded ? "Yes" : "No");
        }
    }

    function _saveDeploymentInfo(
        PaymasterV4_1 paymaster,
        address entryPoint,
        address owner,
        address treasury,
        address chainlinkFeed,
        address registryAddress,
        address sbtAddress,
        address gasTokenAddress
    ) internal {
        string memory networkName = ChainlinkFeeds.getNetworkName(block.chainid);
        string memory filename = string.concat(
            "contracts/deployments/paymaster-v4_1-v2-",
            vm.toLowercase(networkName),
            ".json"
        );

        // Build JSON
        string memory json = string.concat(
            "{\n",
            '  "version": "v4.2",\n',
            '  "contract": "PaymasterV4_1",\n',
            '  "network": "', networkName, '",\n',
            '  "chainId": ', vm.toString(block.chainid), ',\n',
            '  "timestamp": ', vm.toString(block.timestamp), ',\n',
            '  "addresses": {\n',
            '    "paymaster": "', vm.toString(address(paymaster)), '",\n',
            '    "entryPoint": "', vm.toString(entryPoint), '",\n',
            '    "owner": "', vm.toString(owner), '",\n',
            '    "treasury": "', vm.toString(treasury), '",\n',
            '    "registry": "', vm.toString(registryAddress), '",\n',
            '    "chainlinkETHUSD": "', vm.toString(chainlinkFeed), '"'
        );

        if (sbtAddress != address(0) || gasTokenAddress != address(0)) {
            json = string.concat(
                json,
                ',\n',
                '    "initialSBT": "', vm.toString(sbtAddress), '",\n',
                '    "initialGasToken": "', vm.toString(gasTokenAddress), '"'
            );
        }

        json = string.concat(
            json,
            '\n  },\n',
            '  "parameters": {\n',
            '    "serviceFeeRate": ', vm.toString(paymaster.serviceFeeRate()), ',\n',
            '    "maxGasCostCap": "', vm.toString(paymaster.maxGasCostCap()), '"\n',
            '  },\n',
            '  "contractVersion": "', paymaster.version(), '"\n',
            "}"
        );

        vm.writeFile(filename, json);
        console.log("\nDeployment info saved to:", filename);
    }

    function _printNextSteps(address paymasterAddress, address registryAddress) internal view {
        console.log("\n=== Next Steps ===");
        console.log("\n1. Fund Paymaster:");
        console.log("   paymaster.addDeposit{value: 1 ether}()");
        console.log("");
        console.log("2. Add Stake (if required by EntryPoint):");
        console.log("   paymaster.addStake{value: 0.1 ether}(86400)");
        console.log("");
        console.log("3. Register to Registry:");
        console.log("   registry.registerPaymaster(");
        console.log("     ", paymasterAddress, ",");
        console.log("     feeRate,  // e.g., 200 (2%)");
        console.log('     "My Paymaster"');
        console.log("   )");
        console.log("");
        console.log("4. Deploy & Configure GasTokens:");
        console.log("   See: contracts/script/DeployGasTokenV2.s.sol");
        console.log("");
        console.log("5. Add SBTs (if needed):");
        console.log("   paymaster.addSBT(sbtAddress)");
        console.log("");
        console.log("6. Verify on Etherscan:");
        console.log("   Contract:", paymasterAddress);
        console.log("   Registry:", registryAddress);
        console.log("");
        console.log("IMPORTANT: Registry address is IMMUTABLE and cannot be changed!");
        console.log("           Chainlink feed is IMMUTABLE and cannot be changed!");
    }
}
