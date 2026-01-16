// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

contract Deploy13a_PaymasterV4Multi is Script {
    function run(
        address factoryAddr, 
        address feeTokenAddr, 
        address sbtAddr,      
        address registryAddr,
        string memory privateKeyEnv
    ) external {
        uint256 pk = vm.envUint(privateKeyEnv);
        address deployer = vm.addr(pk);
        console.log("Deploying Paymaster V4.1 Instance with account:", deployer);

        vm.startBroadcast(pk);

        address entryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        address treasury = deployer; 
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
        uint256 serviceFeeRate = 200; 
        uint256 maxGasCostCap = 5000000 ether; // High cap for testing
        uint256 minTokenBalance = 0;
        address xpntsFactory = 0x52cC246cc4f4c49e2BAE98b59241b30947bA6013; // V3.1.1 Factory

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
            sbtAddr,
            feeTokenAddr,
            registryAddr
        );

        address pm = PaymasterFactory(factoryAddr).deployPaymaster("v4.1", initData);
        console.log("NEW Paymaster V4 (V3.1.1 Ready) deployed to:", pm);

        vm.stopBroadcast();
    }
}
