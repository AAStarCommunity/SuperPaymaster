// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/SuperPaymasterV2.sol";

/**
 * @title DeploySuperPaymasterV2_0_1
 * @notice Deploy SuperPaymasterV2 v2.1.0 with registerOperatorWithAutoStake
 *
 * @dev Updates in v2.1.0:
 *   - Added registerOperatorWithAutoStake (one-step registration)
 *   - v2.0.1: Added Chainlink oracle answeredInRound validation
 *   - Industry-standard oracle security (Aave V3, Compound V3 pattern)
 *
 * @dev Required Environment Variables:
 *   - GTOKEN: GToken ERC20 contract address
 *   - GTOKEN_STAKING: GTokenStaking contract address
 *   - REGISTRY: Registry contract address
 *   - ETH_USD_PRICE_FEED: Chainlink ETH/USD price feed address
 *   - ENTRYPOINT_V07: EntryPoint v0.7 address
 *   - PRIVATE_KEY: Deployer private key
 *
 * @dev Usage:
 *   forge script script/DeploySuperPaymasterV2_0_1.s.sol:DeploySuperPaymasterV2_0_1 \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeploySuperPaymasterV2_0_1 is Script {
    function run() external {
        // Load environment variables (try both naming conventions)
        address gtoken;
        address gtokenStaking;
        address registry;

        // Try GTOKEN first, fallback to GTOKEN_ADDRESS
        try vm.envAddress("GTOKEN") returns (address addr) {
            gtoken = addr;
        } catch {
            gtoken = vm.envAddress("GTOKEN_ADDRESS");
        }

        // Try GTOKEN_STAKING first, fallback to GTOKEN_STAKING_ADDRESS
        try vm.envAddress("GTOKEN_STAKING") returns (address addr) {
            gtokenStaking = addr;
        } catch {
            gtokenStaking = vm.envAddress("GTOKEN_STAKING_ADDRESS");
        }

        // Try REGISTRY first, fallback to REGISTRY_ADDRESS
        try vm.envAddress("REGISTRY") returns (address addr) {
            registry = addr;
        } catch {
            registry = vm.envAddress("REGISTRY_ADDRESS");
        }

        address ethUsdPriceFeed = vm.envAddress("ETH_USD_PRICE_FEED");
        address entrypoint = vm.envAddress("ENTRYPOINT_V07");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("================================================================================");
        console.log("=== Deploying SuperPaymasterV2 v2.1.0 (Auto-Stake Registration) ===");
        console.log("================================================================================");
        console.log("GToken:            ", gtoken);
        console.log("GTokenStaking:     ", gtokenStaking);
        console.log("Registry:          ", registry);
        console.log("ETH/USD Price Feed:", ethUsdPriceFeed);
        console.log("EntryPoint v0.7:   ", entrypoint);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SuperPaymasterV2
        SuperPaymasterV2 superPaymaster = new SuperPaymasterV2(
            gtoken,
            gtokenStaking,
            registry,
            ethUsdPriceFeed
        );

        console.log("SuperPaymasterV2 deployed:", address(superPaymaster));
        console.log("VERSION:         ", superPaymaster.VERSION());
        console.log("VERSION_CODE:    ", superPaymaster.VERSION_CODE());
        console.log("");

        // Configure EntryPoint
        superPaymaster.setEntryPoint(entrypoint);
        console.log("EntryPoint configured:", entrypoint);

        vm.stopBroadcast();

        console.log("");
        console.log("================================================================================");
        console.log("=== Deployment Complete ===");
        console.log("================================================================================");
        console.log("Contract Address:  ", address(superPaymaster));
        console.log("Owner:             ", superPaymaster.owner());
        console.log("Version:           ", superPaymaster.VERSION());
        console.log("GTokenStaking:     ", superPaymaster.GTOKEN_STAKING());
        console.log("Registry:          ", superPaymaster.REGISTRY());
        console.log("EntryPoint:        ", superPaymaster.ENTRY_POINT());
        console.log("");
        console.log("=== Security Features (v2.0.1) ===");
        console.log("- Chainlink Oracle Validation:");
        console.log("  1. answeredInRound >= roundId (consensus validation)");
        console.log("  2. Staleness check (1 hour timeout)");
        console.log("  3. Price bounds ($100 - $100,000)");
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Save contract address to shared-config repository");
        console.log("2. Verify contract on block explorer (if not auto-verified)");
        console.log("3. Test oracle validation with real Chainlink feeds");
        console.log("4. Monitor for 48 hours before production use");
        console.log("================================================================================");

        // Save deployment info to JSON file
        _saveDeploymentInfo(superPaymaster, ethUsdPriceFeed);
    }

    function _saveDeploymentInfo(SuperPaymasterV2 sp, address priceFeed) internal {
        string memory json1 = string(abi.encodePacked(
            '{\n',
            '  "contractName": "SuperPaymasterV2",\n',
            '  "version": "', sp.VERSION(), '",\n',
            '  "versionCode": ', vm.toString(sp.VERSION_CODE()), ',\n',
            '  "address": "', vm.toString(address(sp)), '",\n'
        ));

        string memory json2 = string(abi.encodePacked(
            '  "owner": "', vm.toString(sp.owner()), '",\n',
            '  "gtokenStaking": "', vm.toString(sp.GTOKEN_STAKING()), '",\n',
            '  "registry": "', vm.toString(sp.REGISTRY()), '",\n',
            '  "entryPoint": "', vm.toString(sp.ENTRY_POINT()), '",\n'
        ));

        string memory json3 = string(abi.encodePacked(
            '  "ethUsdPriceFeed": "', vm.toString(priceFeed), '",\n',
            '  "deployedAt": ', vm.toString(block.timestamp), ',\n',
            '  "network": "', getChainName(), '"\n',
            '}'
        ));

        string memory json = string(abi.encodePacked(json1, json2, json3));
        string memory filename = string(abi.encodePacked(
            "contracts/deployments/superpaymaster-v2.0.1-",
            getChainName(),
            ".json"
        ));

        vm.writeFile(filename, json);
        console.log("Deployment info saved to:", filename);
    }

    function getChainName() internal view returns (string memory) {
        uint256 chainId = block.chainid;
        if (chainId == 1) return "mainnet";
        if (chainId == 11155111) return "sepolia";
        if (chainId == 137) return "polygon";
        if (chainId == 42161) return "arbitrum";
        if (chainId == 10) return "optimism";
        return vm.toString(chainId);
    }
}
