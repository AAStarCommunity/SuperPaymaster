// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Interfaces
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract FixDeployerRole is Script {
    // Sepolia Addresses
    address constant ADDR_REGISTRY = 0x2D7d16EAaa85Fa88D05B296E9951f730BDaA0A7D;
    address constant ADDR_GTOKEN = 0xccB0cA1Ec9F8e51bEdBD4038BB9980B071bD81cB;
    address constant ADDR_STAKING = 0xF50D6ade7C150A8Ac7cF5cDD47C43Fa8d44747eD;
    address constant ADDR_PM_V4_PROXY = 0xe4551c950b35DcF80e61CEa730743CEec127db88; // Wait, this is PM FACTORY? Check config.
    // Config: "paymasterFactory": "0xe45...", "paymasterV4Impl": "0x4E3..."
    // Where is the Proxy? 
    // DeployLive.s.sol logic: "addr_pmV4Proxy = existingProxy;" or "deployPaymaster(...)".
    // I need to FIND the proxy. 
    // Option 1: It was saved in config? No, config only has factory and impl. 
    // Option 2: Check Factory for operator's proxy? 
    // User said: "register paymaster v4 for jason...". 
    // Actually, let's look up the proxy dynamically in the script.

    address constant ADDR_PM_FACTORY = 0xe4551c950b35DcF80e61CEa730743CEec127db88;

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");

    address constant ADDR_APNTS = 0x7A56b5B9f4aC457B5d080468Dd002222D1Df4c50;

    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);
        address xpntsFactory = 0x0F815454ea941224dE582554D1DeF4B67ffBE38c;
        
        vm.startBroadcast(deployerPK);

        Registry registry = Registry(ADDR_REGISTRY);
        GTokenStaking staking = GTokenStaking(ADDR_STAKING);
        GToken gtoken = GToken(ADDR_GTOKEN);

        console.log("=== FixDeployerRole: Migrating %s ===", deployer);

        // 1. Bypass Lock (If Owner)
        if (registry.owner() == deployer) {
            console.log("Deployer is Registry Owner. Resetting Lock Duration...");
            try registry.setRoleLockDuration(ROLE_PAYMASTER_SUPER, 0) {} catch { console.log("SetLock Failed"); }
        }

        // 2. Exit SuperPaymaster Role
        if (registry.hasRole(ROLE_PAYMASTER_SUPER, deployer)) {
            console.log("Exiting ROLE_PAYMASTER_SUPER...");
            try registry.exitRole(ROLE_PAYMASTER_SUPER) {
                console.log("Exited SUPER_PAYMASTER.");
            } catch Error(string memory r) {
                console.log("Exit Failed:", r);
            } catch {
                console.log("Exit Failed (Unknown)");
            }
        }

        // 3. Register PAYMASTER_AOA
        if (!registry.hasRole(ROLE_PAYMASTER_AOA, deployer)) {
            console.log("Registering ROLE_PAYMASTER_AOA...");
            
            // 3.1 Find Paymaster Proxy
            (bool s, bytes memory r) = ADDR_PM_FACTORY.staticcall(abi.encodeWithSignature("getPaymasterByOperator(address)", deployer));
            address pmProxy = address(0);
            if (s && r.length == 32) {
                pmProxy = abi.decode(r, (address));
            }

            if (pmProxy == address(0)) {
                console.log("Paymaster Proxy not found. Deploying new...");
                
                 // Correct Signature: initialize(address,address,address,address,uint256,uint256,uint256,address,address,uint256)
                 bytes memory init = abi.encodeWithSignature(
                    "initialize(address,address,address,address,uint256,uint256,uint256,address,address,uint256)",
                    0x0000000071727De22E5E9d8BAf0edAc6f37da032, // EntryPoint
                    deployer, // Owner
                    deployer, // Treasury
                    0x694AA1769357215DE4FAC081bf1f309aDC325306, // PriceFeed
                    100, // Markup (Service Fee)
                    1 ether, // MaxGasCostCap
                    0,       // MinTokenBalance
                    xpntsFactory,
                    ADDR_APNTS, // Initial Gas Token (aPNTs)
                    3600        // Price Staleness
                 );
                 
                 (bool s2, bytes memory r2) = ADDR_PM_FACTORY.call(abi.encodeWithSignature("deployPaymaster(string,bytes)", "v4.2", init));
                 require(s2, "Deploy Paymaster Failed");
                 pmProxy = abi.decode(r2, (address));
            }
            console.log("Using Paymaster Proxy:", pmProxy);

            // 3.2 Prepare Data
            Registry.PaymasterRoleData memory data = Registry.PaymasterRoleData({
                paymasterContract: pmProxy,
                name: "Jason V4 Paymaster",
                apiEndpoint: "https://rpc.aastar.io/paymaster/v4", 
                stakeAmount: 30 ether
            });

            // 3.3 Approve Staking (Stake 30 + Burn 3 = 33 ether)
            gtoken.approve(ADDR_STAKING, 33 ether);
            
            registry.registerRole(ROLE_PAYMASTER_AOA, deployer, abi.encode(data));
            console.log("Registered PAYMASTER_AOA.");
        } else {
            console.log("Already has ROLE_PAYMASTER_AOA.");
        }

        vm.stopBroadcast();
        console.log("=== Migration Complete ===");
    }
}
