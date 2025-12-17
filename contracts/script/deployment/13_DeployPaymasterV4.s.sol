// SPDX-License-Identifier: MIT
// 13_DeployPaymasterV4.s.sol
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

contract Deploy13_PaymasterV4 is Script {
    function run(
        address factoryAddr, // PaymasterFactory
        address feeTokenAddr, // bPNTs
        address sbtAddr,      // MySBT
        address registryAddr  // Registry
    ) external {
        uint256 anniPrivateKey = vm.envUint("PRIVATE_KEY_ANNI");
        address deployer = vm.addr(anniPrivateKey);
        console.log("Deploying Paymaster Instance with account (Anni):", deployer);

        vm.startBroadcast(anniPrivateKey);

        // --- Config ---
        address entryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        address treasury = deployer; 
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
        uint256 serviceFeeRate = 200; 
        uint256 maxGasCostCap = 5000000;
        uint256 minTokenBalance = 0;
        
        // FIX: Provide valid xPNTsFactory address (from user's previous output)
        address xpntsFactory = 0x62b1b3B2A95c766FF7b1c633F83d3DeebBe6323b; 

        address initialSBT = sbtAddr;
        address initialGasToken = feeTokenAddr; 

        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256,address,address,address,address)",
            entryPoint,
            deployer, 
            treasury,
            ethUsdPriceFeed,
            serviceFeeRate,
            maxGasCostCap,
            minTokenBalance,
            xpntsFactory,
            initialSBT,
            initialGasToken,
            registryAddr
        );

        // Deploy
        address pm = PaymasterFactory(factoryAddr).deployPaymaster("v4.1", initData);
        console.log("Paymaster V4 Instance deployed to:", pm);

        vm.stopBroadcast();
    }
}
