// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v3/core/Registry.sol";
import "src/paymasters/v3/core/GTokenStaking.sol";
import "src/paymasters/v3/tokens/MySBT.sol";
import "src/paymasters/v3/interfaces/IRegistryV3.sol";

/**
 * @title DeploySuperPaymasterV3
 * @notice Deploy standard V3 suite: GTokenStaking, Registry, MySBT
 */
contract DeploySuperPaymasterV3 is Script {
    // Default addresses (can be overridden by env vars)
    // Sepolia Defaults
    address constant SEP_GTOKEN = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
    address constant SEP_DAO = 0x5CE2B92c395837c97C7992716883f0146fbe5887;
    address constant SEP_TREASURY = 0x5CE2B92c395837c97C7992716883f0146fbe5887; // Default to DAO if not set

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load config from env or use defaults
        address gtoken = vm.envOr("GTOKEN_ADDRESS", SEP_GTOKEN);
        address dao = vm.envOr("DAO_MULTISIG", SEP_DAO);
        address treasury = vm.envOr("TREASURY_ADDRESS", SEP_TREASURY);

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
        // Since we deployed MySBT with DAO=dao, only DAO can call setRegistry?
        // Let's check MySBT.setRegistry access control.
        // It uses `onlyDAO`. So if DAO != deployer, we cannot set it here!
        // Solution: PASS DEPLOYER AS TEMP DAO, THEN TRANSFER TO REAL DAO
        
        // Wait, let's redeploy MySBT with correct logic if DAO is external.
        // Or assume we are testing/deploying where deployer has control.
        // If DAO is external, we can't complete setup in one script.
        
        // BETTER STRATEGY: Deploy with DAO = deployer, then transfer ownership later if needed.
        // But sbt constructor sets `daoMultisig`.
        
        // Let's check user's instructions. Usually deployer is initial owner/DAO for non-prod.
        // For prod, we need to generate a proposal?
        // Assuming deployer is authorized for now. We will try to setRegistry.
        
        // If dao != deployer, we can't call setRegistry.
        // But for initial deployment, maybe we set dao to deployer first?
        
        // Let's check if we can simulate it or if we should just warn.
        if (dao == deployer) {
            console.log("Configuring MySBT registry...");
            sbt.setRegistry(address(registry));
        } else {
            console.log("WARNING: DAO is not deployer. Please manually call MySBT.setRegistry(", address(registry), ")");
            // We can deploy a fresh MySBT with deployer as DAO, then transfer?
            // User provided DAO address.
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

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Deployment Complete!");
        console.log("GTokenStaking:", address(staking));
        console.log("Registry:", address(registry));
        console.log("MySBT:", address(sbt));
        console.log("========================================");
        
        // Write to .env file for processing
        string memory envContent = string.concat(
            "REGISTRY_V3_ADDRESS=", vm.toString(address(registry)), "\n",
            "GTOKEN_STAKING_V3_ADDRESS=", vm.toString(address(staking)), "\n",
            "MYSBT_V3_ADDRESS=", vm.toString(address(sbt))
        );
        vm.writeFile("deployment_v3.env", envContent);
    }
}
