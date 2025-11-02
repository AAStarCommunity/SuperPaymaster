// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/PaymasterFactory.sol";
import "../src/paymasters/v4/PaymasterV4_1i.sol";

/**
 * @title TestPaymasterV4_1i_Factory
 * @notice Test script for deploying PaymasterV4_1i through PaymasterFactory
 * @dev Validates the complete factory deployment flow
 *
 * @dev Usage (Sepolia):
 *   forge script script/TestPaymasterV4_1i_Factory.s.sol:TestPaymasterV4_1i_Factory \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 *
 * @dev Required Environment Variables:
 *   - PAYMASTER_FACTORY: PaymasterFactory contract address
 *   - ENTRY_POINT: EntryPoint v0.7 address
 *   - OWNER_ADDRESS: Initial owner address (will be msg.sender if not set)
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
 */
contract TestPaymasterV4_1i_Factory is Script {
    function run() external {
        // Factory address
        address factoryAddress = vm.envAddress("PAYMASTER_FACTORY");
        PaymasterFactory factory = PaymasterFactory(factoryAddress);

        // Required parameters
        address entryPoint = vm.envAddress("ENTRY_POINT");
        address owner = vm.envOr("OWNER_ADDRESS", msg.sender);
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address ethUsdPriceFeed = vm.envAddress("ETH_USD_PRICE_FEED");
        uint256 serviceFeeRate = vm.envUint("SERVICE_FEE_RATE");
        uint256 maxGasCostCap = vm.envUint("MAX_GAS_COST_CAP");
        address xpntsFactory = vm.envAddress("XPNTS_FACTORY_ADDRESS");
        address registryAddress = vm.envAddress("REGISTRY_ADDRESS");

        // Optional parameters
        address sbtAddress = vm.envOr("SBT_ADDRESS", address(0));
        address gasTokenAddress = vm.envOr("GAS_TOKEN_ADDRESS", address(0));

        console.log("\n=== PaymasterV4_1i Factory Deployment Test ===");
        console.log("Factory:", factoryAddress);
        console.log("Deployer:", msg.sender);
        console.log("Owner:", owner);

        // Check if v4.1i implementation is registered
        address implementation = factory.implementations("v4.1i");
        console.log("\nImplementation (v4.1i):", implementation);
        require(implementation != address(0), "v4.1i not registered in factory");

        // Prepare initialize data
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256,address,address,address,address)",
            entryPoint,
            owner,
            treasury,
            ethUsdPriceFeed,
            serviceFeeRate,
            maxGasCostCap,
            0, // minTokenBalance (for compatibility)
            xpntsFactory,
            sbtAddress,
            gasTokenAddress,
            registryAddress
        );

        vm.startBroadcast();

        // Deploy through factory
        console.log("\nDeploying paymaster through factory...");
        address payable paymasterAddress = payable(factory.deployPaymaster("v4.1i", initData));

        vm.stopBroadcast();

        // Verify deployment
        PaymasterV4_1i paymaster = PaymasterV4_1i(paymasterAddress);

        console.log("\n=== Deployment Successful ===");
        console.log("Paymaster Address:", paymasterAddress);
        console.log("Version:", paymaster.version());
        console.log("Owner:", paymaster.owner());
        console.log("EntryPoint:", address(paymaster.entryPoint()));
        console.log("Treasury:", paymaster.treasury());
        console.log("Service Fee Rate:", paymaster.serviceFeeRate(), "bps");
        console.log("Max Gas Cost Cap:", paymaster.maxGasCostCap(), "wei");
        console.log("Registry Set:", paymaster.isRegistrySet());
        console.log("Paused:", paymaster.paused());

        // Verify ownership
        require(paymaster.owner() == owner, "Owner mismatch");
        require(address(paymaster.entryPoint()) == entryPoint, "EntryPoint mismatch");
        require(paymaster.treasury() == treasury, "Treasury mismatch");

        console.log("\n=== All Verifications Passed ===");

        _printNextSteps(paymasterAddress, registryAddress);
    }

    function _printNextSteps(address paymaster, address registry) internal view {
        console.log("\n=== Next Steps ===");
        console.log("1. Fund Paymaster with ETH for gas sponsorship");
        console.log("   cast send", paymaster, "--value 0.1ether");
        console.log("\n2. Deposit to EntryPoint (required for v0.7)");
        console.log("   paymaster.depositToEntryPoint()");
        console.log("\n3. Add SBTs for user verification");
        console.log("   paymaster.addSBT(<sbt_address>)");
        console.log("\n4. Add GasTokens for payment");
        console.log("   paymaster.addGasToken(<token_address>)");
        console.log("\n5. Register in Registry (if needed)");
        console.log("   registry.registerPaymaster(", paymaster, ")");
    }
}
