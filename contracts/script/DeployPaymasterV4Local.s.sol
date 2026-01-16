// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v4/PaymasterV4.sol";

contract DeployPaymasterV4Local is Script {
    function run() external {
        // Use Anvil default accounts
        address entryPoint = 0x5FbDB2315678afecb367f032d93F642f64180aa3; // MockEntryPoint from V3 deployment
        address owner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Anvil account 0
        address treasury = owner;
        address ethUsdPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Chainlink ETH/USD (mock for local)
        address xpntsFactory = 0x5081a39b8A5f0E35a8D959395a630b68B74Dd30f; // From V3 deployment
        
        // Default parameters for local testing
        uint256 serviceFeeRate = 1000; // 10% (1000 bps)
        uint256 maxGasCostCap = 1 ether; // 1 ETH max gas cost
        
        vm.startBroadcast();
        
        PaymasterV4 paymaster = new PaymasterV4(
            entryPoint,
            owner,
            treasury,
            ethUsdPriceFeed,
            serviceFeeRate,
            maxGasCostCap,
            xpntsFactory
        );
        
        console.log("PaymasterV4 deployed to:", address(paymaster));
        console.log("Owner:", paymaster.owner());
        console.log("EntryPoint:", address(paymaster.entryPoint()));
        
        vm.stopBroadcast();
    }
}
