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
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying Paymaster Instance with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // --- Config ---
        address entryPoint = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        address treasury = deployer; 
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
        uint256 serviceFeeRate = 200; 
        uint256 maxGasCostCap = 5000000;
        uint256 minTokenBalance = 0;
        
        // Correct xPNTsFactory address
        address xpntsFactory = 0x673928F507D791B57F06BC3f487229D9D6d5d33D; 

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

        // --- Post-Deployment Initialization (Auto-Fix) ---
        // 1. Add Stake (0.1 ETH, 1 day)
        (bool s,) = pm.call{value: 0.1 ether}(abi.encodeWithSignature("addStake(uint32)", 86400));
        require(s, "Stake failed");
        console.log("Staked 0.1 ETH");

        // 2. Add Deposit (0.1 ETH)
        (bool d,) = pm.call{value: 0.1 ether}(abi.encodeWithSignature("addDeposit()"));
        require(d, "Deposit failed");
        console.log("Deposited 0.1 ETH");

        // 3. Update Price (Initialize Oracle Cache)
        (bool u,) = pm.call(abi.encodeWithSignature("updatePrice()"));
        if(u) console.log("Price Cache Initialized");
        else console.log("Price Init Skipped (or failed)");

        // 4. Set Token Price (Default $1.00 for initial token)
        if (initialGasToken != address(0)) {
            // Price: 100000000 (1e8 = $1.00)
            (bool t,) = pm.call(abi.encodeWithSignature("setTokenPrice(address,uint256)", initialGasToken, 100000000));
            require(t, "SetTokenPrice failed");
            console.log("Set Token Price to $1.00 for", initialGasToken);
        }

        vm.stopBroadcast();
    }
}
