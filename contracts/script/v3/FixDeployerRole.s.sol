// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";

// Interfaces
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract FixDeployerRole is Script {
    using stdJson for string;

    // State variables for addresses (loaded from config)
    address internal ADDR_REGISTRY;
    address internal ADDR_GTOKEN;
    address internal ADDR_STAKING;
    address internal ADDR_PM_FACTORY;
    address internal ADDR_XPNTS_FACTORY;
    address internal ADDR_APNTS;
    address internal ADDR_ENTRYPOINT;

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");

    function setUp() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/config.sepolia.json");
        string memory json = vm.readFile(path);

        ADDR_REGISTRY = json.readAddress(".registry");
        ADDR_GTOKEN = json.readAddress(".gToken");
        ADDR_STAKING = json.readAddress(".staking");
        ADDR_PM_FACTORY = json.readAddress(".paymasterFactory");
        ADDR_XPNTS_FACTORY = json.readAddress(".xPNTsFactory");
        ADDR_APNTS = json.readAddress(".aPNTs");
        ADDR_ENTRYPOINT = json.readAddress(".entryPoint");

        console.log("Loaded config from deployments/config.sepolia.json");
        console.log("Registry:", ADDR_REGISTRY);
        console.log("PaymasterFactory:", ADDR_PM_FACTORY);
    }

    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);
        
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
                    ADDR_ENTRYPOINT, // EntryPoint from config
                    deployer, // Owner
                    deployer, // Treasury
                    0x694AA1769357215DE4FAC081bf1f309aDC325306, // PriceFeed (Hardcoded as requested/kept)
                    100, // Markup (Service Fee)
                    1 ether, // MaxGasCostCap
                    0,       // MinTokenBalance
                    ADDR_XPNTS_FACTORY,
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
