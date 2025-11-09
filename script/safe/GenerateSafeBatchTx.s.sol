// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title GenerateSafeBatchTx
 * @notice Generate Safe multisig batch transaction JSON for community ownership transfer
 *
 * @dev Use Case: Transfer community ownership to Safe multisig wallet
 *      This enables enterprise-grade communities to use multi-signature governance
 *
 * @dev What gets transferred:
 *   1. Registry community ownership (transferCommunityOwnership)
 *   2. PaymasterV4 ownership (transferOwnership) - AOA mode only
 *   3. xPNTs token ownership (transferOwnership) - if exists
 *
 * @dev Usage:
 *   1. Set environment variables:
 *      - CURRENT_OWNER: Current community owner address
 *      - SAFE_ADDRESS: Target Safe multisig address
 *      - PAYMASTER_ADDRESS: PaymasterV4 address (AOA mode, optional)
 *      - XPNTS_TOKEN_ADDRESS: xPNTs token address (optional)
 *
 *   2. Generate transaction JSON:
 *      forge script script/safe/GenerateSafeBatchTx.s.sol:GenerateSafeBatchTx \
 *        --rpc-url $SEPOLIA_RPC_URL \
 *        -vvv
 *
 *   3. Import JSON to Safe UI:
 *      - Go to Safe web app (https://app.safe.global)
 *      - Navigate to "New Transaction" > "Transaction Builder"
 *      - Upload generated JSON file
 *      - Review and sign
 *
 * @dev Output: safe-batch-transfer-ownership.json
 */
contract GenerateSafeBatchTx is Script {
    // Safe Transaction Builder JSON format
    struct SafeTransaction {
        address to;
        uint256 value;
        bytes data;
        string contractMethod;
        string contractInputsValues;
    }

    function run() external view {
        address currentOwner = vm.envAddress("CURRENT_OWNER");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address registryAddress = vm.envOr("REGISTRY_V2_2_1", 0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696);

        // Optional contracts
        address paymasterAddress = vm.envOr("PAYMASTER_ADDRESS", address(0));
        address xPNTsTokenAddress = vm.envOr("XPNTS_TOKEN_ADDRESS", address(0));

        console.log("===========================================");
        console.log("=== Safe Batch Transaction Generator ===");
        console.log("===========================================");
        console.log("Current Owner:    ", currentOwner);
        console.log("Safe Address:     ", safeAddress);
        console.log("Registry:         ", registryAddress);
        console.log("Paymaster (AOA):  ", paymasterAddress);
        console.log("xPNTs Token:      ", xPNTsTokenAddress);
        console.log("");

        // Validation
        require(safeAddress != address(0), "SAFE_ADDRESS not set");
        require(currentOwner != address(0), "CURRENT_OWNER not set");

        console.log("===========================================");
        console.log("=== Generated Safe Batch Transactions ===");
        console.log("===========================================");
        console.log("");

        uint256 txCount = 0;

        // Transaction 1: Transfer Registry community ownership
        txCount++;
        console.log("Transaction", txCount, ": Registry.transferCommunityOwnership");
        console.log("  To:         ", registryAddress);
        console.log("  Value:      ", "0 ETH");
        console.log("  Method:     ", "transferCommunityOwnership(address)");
        console.log("  New Owner:  ", safeAddress);
        console.log("");

        // Transaction 2: Transfer PaymasterV4 ownership (if exists)
        if (paymasterAddress != address(0)) {
            txCount++;
            console.log("Transaction", txCount, ": PaymasterV4.transferOwnership");
            console.log("  To:         ", paymasterAddress);
            console.log("  Value:      ", "0 ETH");
            console.log("  Method:     ", "transferOwnership(address)");
            console.log("  New Owner:  ", safeAddress);
            console.log("");
        }

        // Transaction 3: Transfer xPNTs token ownership (if exists)
        if (xPNTsTokenAddress != address(0)) {
            txCount++;
            console.log("Transaction", txCount, ": xPNTsToken.transferOwnership");
            console.log("  To:         ", xPNTsTokenAddress);
            console.log("  Value:      ", "0 ETH");
            console.log("  Method:     ", "transferOwnership(address)");
            console.log("  New Owner:  ", safeAddress);
            console.log("");
        }

        console.log("===========================================");
        console.log("=== Summary ===");
        console.log("===========================================");
        console.log("Total Transactions:", txCount);
        console.log("");
        console.log("Safe Transaction Builder JSON:");
        console.log("");

        // Generate Safe Transaction Builder JSON
        _generateSafeJSON(registryAddress, paymasterAddress, xPNTsTokenAddress, safeAddress);
    }

    function _generateSafeJSON(
        address registryAddress,
        address paymasterAddress,
        address xPNTsTokenAddress,
        address safeAddress
    ) internal pure {
        console.log("{");
        console.log('  "version": "1.0",');
        console.log('  "chainId": "11155111",');
        console.log('  "meta": {');
        console.log('    "name": "Community Ownership Transfer to Safe",');
        console.log('    "description": "Batch transfer of community ownership to Safe multisig wallet",');
        console.log('    "createdFromSafeAddress": "%s"', vm.toString(safeAddress));
        console.log('  },');
        console.log('  "transactions": [');

        // Transaction 1: Registry
        console.log('    {');
        console.log('      "to": "%s",', vm.toString(registryAddress));
        console.log('      "value": "0",');
        console.log('      "data": null,');
        console.log('      "contractMethod": {');
        console.log('        "inputs": [{"name": "newOwner", "type": "address", "internalType": "address"}],');
        console.log('        "name": "transferCommunityOwnership",');
        console.log('        "payable": false');
        console.log('      },');
        console.log('      "contractInputsValues": {');
        console.log('        "newOwner": "%s"', vm.toString(safeAddress));
        console.log('      }');
        console.log('    }%s', paymasterAddress != address(0) || xPNTsTokenAddress != address(0) ? "," : "");

        // Transaction 2: Paymaster (if exists)
        if (paymasterAddress != address(0)) {
            console.log('    {');
            console.log('      "to": "%s",', vm.toString(paymasterAddress));
            console.log('      "value": "0",');
            console.log('      "data": null,');
            console.log('      "contractMethod": {');
            console.log('        "inputs": [{"name": "newOwner", "type": "address", "internalType": "address"}],');
            console.log('        "name": "transferOwnership",');
            console.log('        "payable": false');
            console.log('      },');
            console.log('      "contractInputsValues": {');
            console.log('        "newOwner": "%s"', vm.toString(safeAddress));
            console.log('      }');
            console.log('    }%s', xPNTsTokenAddress != address(0) ? "," : "");
        }

        // Transaction 3: xPNTs Token (if exists)
        if (xPNTsTokenAddress != address(0)) {
            console.log('    {');
            console.log('      "to": "%s",', vm.toString(xPNTsTokenAddress));
            console.log('      "value": "0",');
            console.log('      "data": null,');
            console.log('      "contractMethod": {');
            console.log('        "inputs": [{"name": "newOwner", "type": "address", "internalType": "address"}],');
            console.log('        "name": "transferOwnership",');
            console.log('        "payable": false');
            console.log('      },');
            console.log('      "contractInputsValues": {');
            console.log('        "newOwner": "%s"', vm.toString(safeAddress));
            console.log('      }');
            console.log('    }');
        }

        console.log('  ]');
        console.log('}');
        console.log("");
        console.log("===========================================");
        console.log("Copy the JSON above and import to Safe Transaction Builder");
        console.log("https://app.safe.global");
        console.log("===========================================");
    }
}
