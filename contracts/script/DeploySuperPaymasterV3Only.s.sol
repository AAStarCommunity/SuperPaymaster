// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/tokens/xPNTsToken.sol";



contract DeploySuperPaymasterV3Only is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY"); // Using default PRIVATE_KEY (Supplier/Relayer/Jason)
        address deployer = vm.addr(deployerPrivateKey);

        console.log("--- SuperPaymaster V3 Deployment (Only) ---");
        console.log("Deployer:", deployer);
        
        // Load Env Vars
        address registryAddr = vm.envAddress("REGISTRY_ADDRESS");
        address aPNTsAddr = vm.envAddress("APNTS_ADDRESS"); // This is actually the xPNTs/aPNTs token
        address entryPointAddr = vm.envAddress("ENTRY_POINT_V07");
        address priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD
        address protocolTreasury = deployer; // Use deployer as treasury for now

        console.log("Registry:", registryAddr);
        console.log("Token:", aPNTsAddr);
        console.log("EntryPoint:", entryPointAddr);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy SuperPaymasterV3
        SuperPaymasterV3 paymaster = new SuperPaymasterV3(
            IEntryPoint(entryPointAddr),
            deployer, // owner
            IRegistryV3(registryAddr),
            aPNTsAddr,
            priceFeedAddr,
            protocolTreasury
        );
        console.log("SuperPaymasterV3 Deployed to:", address(paymaster));

        // 2. Wire up xPNTsToken (if possible)
        // Check if deployer is owner of token
        try xPNTsToken(aPNTsAddr).communityOwner() returns (address tokenOwner) {
            if (tokenOwner == deployer) {
                console.log("Deployer is Token Owner. Configuring token...");
                xPNTsToken(aPNTsAddr).setSuperPaymasterAddress(address(paymaster));
                console.log("Updated xPNTsToken.SUPERPAYMASTER_ADDRESS");
            } else {
                console.log("WARNING: Deployer is NOT Token Owner. Token Owner is:", tokenOwner);
                console.log("You MUST manually call setSuperPaymasterAddress on the token contract.");
            }
        } catch {
             console.log("WARNING: Content at aPNTsAddr is not a compatible xPNTsToken.");
        }
        
        // 3. Deposit ETH for gas (Paymaster needs ETH/native token to pay EntryPoint)
        // Fund it with 0.05 ETH
        console.log("Funding Paymaster with 0.05 ETH...");
        (bool success, ) = address(paymaster).call{value: 0.05 ether}("");
        require(success, "Failed to fund paymaster");
        
        vm.stopBroadcast();
        
        console.log("--- Deployment Complete ---");
        console.log("New SuperPaymaster Address:", address(paymaster));
    }
}
