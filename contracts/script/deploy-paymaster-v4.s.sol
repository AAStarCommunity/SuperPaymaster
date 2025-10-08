// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/v3/PaymasterV4.sol";

contract DeployPaymasterV4 is Script {
    function run() external {
        // Environment variables
        address entryPoint = vm.envAddress("ENTRY_POINT");
        address owner = vm.envAddress("OWNER_ADDRESS");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        uint256 gasToUSDRate = vm.envUint("GAS_TO_USD_RATE");
        uint256 pntPriceUSD = vm.envUint("PNT_PRICE_USD");
        uint256 serviceFeeRate = vm.envUint("SERVICE_FEE_RATE");
        uint256 maxGasCostCap = vm.envUint("MAX_GAS_COST_CAP");
        uint256 minTokenBalance = vm.envUint("MIN_TOKEN_BALANCE");

        // Optional: SBT and GasToken addresses for initial setup
        address sbtAddress = vm.envOr("SBT_ADDRESS", address(0));
        address gasTokenAddress = vm.envOr("GAS_TOKEN_ADDRESS", address(0));

        console.log("=== PaymasterV4 Deployment ===");
        console.log("EntryPoint:", entryPoint);
        console.log("Owner:", owner);
        console.log("Treasury:", treasury);
        console.log("GasToUSDRate:", gasToUSDRate);
        console.log("PntPriceUSD:", pntPriceUSD);
        console.log("ServiceFeeRate:", serviceFeeRate, "bps");
        console.log("MaxGasCostCap:", maxGasCostCap);
        console.log("MinTokenBalance:", minTokenBalance);

        vm.startBroadcast();

        // Deploy PaymasterV4
        PaymasterV4 paymaster = new PaymasterV4(
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
        console.log("PaymasterV4:", address(paymaster));

        // Add initial SBT if provided
        if (sbtAddress != address(0)) {
            paymaster.addSBT(sbtAddress);
            console.log("Added SBT:", sbtAddress);
        }

        // Add initial GasToken if provided
        if (gasTokenAddress != address(0)) {
            paymaster.addGasToken(gasTokenAddress);
            console.log("Added GasToken:", gasTokenAddress);
        }

        vm.stopBroadcast();

        // Write deployment info to file
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "paymaster": "', vm.toString(address(paymaster)), '",\n',
            '  "entryPoint": "', vm.toString(entryPoint), '",\n',
            '  "owner": "', vm.toString(owner), '",\n',
            '  "treasury": "', vm.toString(treasury), '",\n',
            '  "gasToUSDRate": "', vm.toString(gasToUSDRate), '",\n',
            '  "pntPriceUSD": "', vm.toString(pntPriceUSD), '",\n',
            '  "serviceFeeRate": ', vm.toString(serviceFeeRate), ',\n',
            '  "maxGasCostCap": "', vm.toString(maxGasCostCap), '",\n',
            '  "minTokenBalance": "', vm.toString(minTokenBalance), '",\n',
            '  "version": "PaymasterV4-Direct-v1.0.0"\n',
            "}"
        );

        vm.writeFile("deployments/paymaster-v4-sepolia.json", deploymentInfo);
        console.log("\nDeployment info saved to: deployments/paymaster-v4-sepolia.json");
    }
}
