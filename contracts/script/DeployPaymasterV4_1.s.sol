// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/v3/PaymasterV4_1.sol";

/**
 * @title DeployPaymasterV4_1
 * @notice Deployment script for PaymasterV4_1 with Registry management
 * @dev Usage (with verification):
 *   forge script script/DeployPaymasterV4_1.s.sol:DeployPaymasterV4_1 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * @dev For mainnet or other networks, adjust --rpc-url and --etherscan-api-key
 */
contract DeployPaymasterV4_1 is Script {
    function run() external {
        // Load environment variables
        address entryPoint = vm.envAddress("ENTRY_POINT");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 gasToUSDRate = vm.envUint("GAS_TO_USD_RATE");
        uint256 pntPriceUSD = vm.envUint("PNT_PRICE_USD");
        uint256 serviceFeeRate = vm.envUint("SERVICE_FEE_RATE");
        uint256 maxGasCostCap = vm.envUint("MAX_GAS_COST_CAP");
        uint256 minTokenBalance = vm.envUint("MIN_TOKEN_BALANCE");

        // Optional addresses
        address registryAddress = vm.envOr("REGISTRY_ADDRESS", address(0));
        address sbtAddress = vm.envOr("SBT_ADDRESS", address(0));
        address gasTokenAddress = vm.envOr("GAS_TOKEN_ADDRESS", address(0));

        _logDeploymentParams(
            entryPoint,
            owner,
            treasury,
            gasToUSDRate,
            pntPriceUSD,
            serviceFeeRate,
            maxGasCostCap,
            minTokenBalance,
            registryAddress
        );

        vm.startBroadcast();

        // Deploy PaymasterV4_1
        PaymasterV4_1 paymaster = new PaymasterV4_1(
            entryPoint,
            owner,
            treasury,
            gasToUSDRate,
            pntPriceUSD,
            serviceFeeRate,
            maxGasCostCap,
            minTokenBalance
        );

        console.log("\n=== Deployment Successful ===");
        console.log("PaymasterV4_1:", address(paymaster));
        console.log("Version:", paymaster.version());

        // Configure paymaster
        _configurePaymaster(paymaster, registryAddress, sbtAddress, gasTokenAddress);

        vm.stopBroadcast();

        // Save deployment info
        _saveDeploymentInfo(paymaster, entryPoint, owner, treasury, registryAddress);

        // Print next steps
        _printNextSteps(registryAddress);
    }

    function _logDeploymentParams(
        address entryPoint,
        address owner,
        address treasury,
        uint256 gasToUSDRate,
        uint256 pntPriceUSD,
        uint256 serviceFeeRate,
        uint256 maxGasCostCap,
        uint256 minTokenBalance,
        address registryAddress
    ) internal view {
        console.log("=== PaymasterV4_1 Deployment ===");
        console.log("EntryPoint:", entryPoint);
        console.log("Owner:", owner);
        console.log("Treasury:", treasury);
        console.log("GasToUSDRate:", gasToUSDRate);
        console.log("PntPriceUSD:", pntPriceUSD);
        console.log("ServiceFeeRate:", serviceFeeRate, "bps");
        console.log("MaxGasCostCap:", maxGasCostCap);
        console.log("MinTokenBalance:", minTokenBalance);
        if (registryAddress != address(0)) {
            console.log("Registry (to be set):", registryAddress);
        }
    }

    function _configurePaymaster(
        PaymasterV4_1 paymaster,
        address registryAddress,
        address sbtAddress,
        address gasTokenAddress
    ) internal {
        // Note: Configuration functions require owner privileges
        // If owner is different from deployer, these must be called separately

        // Check if we are the owner (deployer == owner)
        address deployer = msg.sender;
        address owner = paymaster.owner();

        if (deployer != owner) {
            console.log("\nNote: Deployer is not owner. Post-deployment configuration required:");
            if (registryAddress != address(0)) {
                console.log("- Owner must call: setRegistry(", registryAddress, ")");
            }
            if (sbtAddress != address(0)) {
                console.log("- Owner must call: addSBT(", sbtAddress, ")");
            }
            if (gasTokenAddress != address(0)) {
                console.log("- Owner must call: addGasToken(", gasTokenAddress, ")");
            }
            return;
        }

        // If we are the owner, configure directly
        if (registryAddress != address(0)) {
            paymaster.setRegistry(registryAddress);
            console.log("Registry configured:", registryAddress);
        }

        if (sbtAddress != address(0)) {
            paymaster.addSBT(sbtAddress);
            console.log("Added SBT:", sbtAddress);
        }

        if (gasTokenAddress != address(0)) {
            paymaster.addGasToken(gasTokenAddress);
            console.log("Added GasToken:", gasTokenAddress);
        }
    }

    function _saveDeploymentInfo(
        PaymasterV4_1 paymaster,
        address entryPoint,
        address owner,
        address treasury,
        address registryAddress
    ) internal {
        string memory network = vm.envOr("NETWORK", string("sepolia"));
        string memory filename = string.concat("contracts/deployments/paymaster-v4_1-", network, ".json");

        // Build JSON in parts to avoid stack too deep
        string memory part1 = string.concat(
            "{\n",
            '  "paymaster": "', vm.toString(address(paymaster)), '",\n',
            '  "entryPoint": "', vm.toString(entryPoint), '",\n',
            '  "owner": "', vm.toString(owner), '",\n'
        );

        string memory part2 = string.concat(
            '  "treasury": "', vm.toString(treasury), '",\n',
            '  "registry": "', vm.toString(registryAddress), '",\n',
            '  "registrySet": ', registryAddress != address(0) ? "true" : "false", ',\n'
        );

        string memory part3 = string.concat(
            '  "version": "', paymaster.version(), '",\n',
            '  "timestamp": ', vm.toString(block.timestamp), '\n',
            "}"
        );

        string memory deploymentInfo = string.concat(part1, part2, part3);

        vm.writeFile(filename, deploymentInfo);
        console.log("\nDeployment info saved to:", filename);
    }

    function _printNextSteps(address registryAddress) internal view {
        console.log("\n=== Next Steps ===");
        console.log("1. Deposit ETH: paymaster.addDeposit{value: X}()");
        console.log("2. Add stake: paymaster.addStake{value: X}(unstakeDelay)");
        if (registryAddress != address(0)) {
            console.log("3. Register to Registry");
        } else {
            console.log("3. Set Registry: paymaster.setRegistry(addr)");
            console.log("4. Register to Registry");
        }
    }
}
