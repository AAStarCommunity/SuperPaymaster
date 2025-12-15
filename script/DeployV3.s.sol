// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/interfaces/v3/IRegistryV3.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";

/**
 * @title DeploySuperPaymasterV3
 * @notice Deploy standard V3 suite: GTokenStaking, Registry, MySBT, SuperPaymaster
 */
contract DeploySuperPaymasterV3 is Script {
    // Default addresses (can be overridden by env vars)
    // Sepolia Defaults
    address constant SEP_GTOKEN = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
    address constant SEP_DAO = 0x5CE2B92c395837c97C7992716883f0146fbe5887;
    address constant SEP_TREASURY = 0x5CE2B92c395837c97C7992716883f0146fbe5887; 
    address constant SEP_CHAINLINK_ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_JASON");
        address deployer = vm.addr(deployerPrivateKey);

        // Load config from env or use defaults
        address gtoken = vm.envOr("GTOKEN_ADDRESS", SEP_GTOKEN);
        address dao = vm.envOr("DAO_MULTISIG", SEP_DAO);
        address treasury = vm.envOr("TREASURY_ADDRESS", SEP_TREASURY);
        address ethUsdPriceFeed = vm.envOr("CHAINLINK_ETH_USD", SEP_CHAINLINK_ETH_USD);

        console.log("========================================");
        console.log("Deploying SuperPaymaster V3 Suite");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("GToken:", gtoken);
        console.log("DAO:", dao);
        console.log("Treasury:", treasury);
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy GTokenStaking
        console.log("Deploying GTokenStaking...");
        GTokenStaking staking = new GTokenStaking(gtoken, treasury);
        console.log("GTokenStaking deployed at:", address(staking));

        // 2. Deploy MySBT with temp registry
        // We use deployer as temp registry to pass non-zero check if needed
        console.log("Deploying MySBT...");
        MySBT sbt = new MySBT(gtoken, address(staking), deployer, dao); 
        console.log("MySBT (Temp Registry) deployed at:", address(sbt));

        // 3. Deploy Registry
        console.log("Deploying Registry...");
        Registry registry = new Registry(gtoken, address(staking), address(sbt));
        console.log("Registry deployed at:", address(registry));

        // 4. Configure MySBT with real Registry (Note: requires DAO permission if set to DAO)
        if (dao == deployer) {
            console.log("Configuring MySBT registry...");
            sbt.setRegistry(address(registry));
        } else {
            console.log("WARNING: DAO is not deployer. Please manually call MySBT.setRegistry(", address(registry), ")");
        }

        // 5. Configure GTokenStaking
        console.log("Configuring GTokenStaking registry...");
        staking.setRegistry(address(registry));

        // 6. Initialize Roles
        console.log("Initializing Roles...");
        
        // Community Role
        IRegistryV3.RoleConfig memory communityConfig = IRegistryV3.RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            isActive: true,
            description: "Community"
        });
        registry.configureRole(keccak256("COMMUNITY"), communityConfig);

        // EndUser Role
        IRegistryV3.RoleConfig memory userConfig = IRegistryV3.RoleConfig({
            minStake: 0.3 ether,
            entryBurn: 0.1 ether, // Mint fee
            slashThreshold: 0,
            slashBase: 0,
            slashIncrement: 0,
            slashMax: 0,
            isActive: true, // Auto-active for self-register
            description: "EndUser"
        });
        registry.configureRole(keccak256("ENDUSER"), userConfig);

        // 7. Deploy SuperPaymaster V3
        console.log("Deploying SuperPaymaster V3 (Core)...");
        // gToken as placeholder for aPNTs token if not defined
        address apntsToken = gtoken; 
        
        SuperPaymasterV3 superPaymaster = new SuperPaymasterV3(
            IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032), // EntryPoint 0.7
            deployer,
            registry,
            apntsToken,
            ethUsdPriceFeed
        );
        console.log("SuperPaymaster V3 deployed at:", address(superPaymaster));

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Deployment Complete!");
        console.log("GTokenStaking:", address(staking));
        console.log("Registry:", address(registry));
        console.log("MySBT:", address(sbt));
        console.log("SuperPaymaster V3:", address(superPaymaster));
        console.log("========================================");
        
        // Write to .env file for processing
        string memory envContent = string.concat(
            "REGISTRY_V3_ADDRESS=", vm.toString(address(registry)), "\n",
            "GTOKEN_STAKING_V3_ADDRESS=", vm.toString(address(staking)), "\n",
            "MYSBT_V3_ADDRESS=", vm.toString(address(sbt)), "\n",
            "SUPER_PAYMASTER_V3_ADDRESS=", vm.toString(address(superPaymaster))
        );
        vm.writeFile("deployment_v3.env", envContent);
    }
}
