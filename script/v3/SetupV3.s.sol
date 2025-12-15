// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/paymasters/v4/PaymasterV4_1i.sol";
import "src/paymasters/v2/core/PaymasterFactory.sol";
import {IEntryPoint} from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

// Minimal Mock Price Feed
contract MockV3Aggregator {
    int256 public constant price = 3000 * 1e8; // $3000 ETH
    uint8 public constant decimals = 8;
    
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

import {EntryPoint} from "@account-abstraction-v7/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract SetupV3 is Script {
    // Configuration
    // on Sepolia: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
    address public entryPointAddress = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant DAO_MULTISIG = 0x1234567890123456789012345678901234567890; 

    // Deployed Addresses
    GToken public gToken;
    GTokenStaking public staking;
    Registry public registry;
    MySBT public sbt;
    SuperPaymasterV3 public superPaymaster;
    xPNTsFactory public xpntsFactory;
    PaymasterFactory public paymasterFactory;
    PaymasterV4_1i public paymasterV4Impl;
    MockV3Aggregator public priceFeed;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address treasury = vm.envOr("TREASURY_ADDRESS", deployer);
        address dao = vm.envOr("DAO_MULTISIG", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 0. Environment Setup (Local vs Testnet)
        address priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
        if (block.chainid == 31337) { // Anvil
             // Deploy Mock Price Feed
             priceFeed = new MockV3Aggregator();
             priceFeedAddr = address(priceFeed);
             
             // Deploy EntryPoint locally
             if (entryPointAddress.code.length == 0) {
                 EntryPoint ep = new EntryPoint();
                 entryPointAddress = address(ep);
             }
        }

        // 2. Deploy GToken & Staking
        gToken = new GToken(1_000_000_000 ether); // 1 Billion cap
        staking = new GTokenStaking(address(gToken), treasury);

        // 4. Deploy MySBT (Circular Dependency: MySBT needs Registry, Registry needs MySBT)
        // Workaround: Deploy MySBT with temporary Registry (deployer), then update.
        // MySBT constructor: (gtoken, staking, registry, dao)
        // We use 'deployer' as temp registry because it must be non-zero.
        sbt = new MySBT(address(gToken), address(staking), deployer, dao);

        // 3. Deploy Registry
        // Registry constructor: (gtoken, staking, mysbt)
        registry = new Registry(address(gToken), address(staking), address(sbt));

        // Wiring: Update MySBT with real Registry
        sbt.setRegistry(address(registry));
        
        // Staking needs Registry
        staking.setRegistry(address(registry));

        // Initialize aPNTs configuration
        address aPNTsAddr = 0x462037Cf25dBCD414EcEe8f93475fE6cdD8b23c2; // Default for Sepolia
        if (block.chainid == 31337) {
            // Deploy a mock xPNTs token for testing
            xPNTsToken t = new xPNTsToken("Anvil PNTs", "aPNTs", deployer, "Anvil DAO", "anvil.eth", 1 ether);
            aPNTsAddr = address(t);
        }
        string memory aPNTs = vm.toString(aPNTsAddr);

        // 5. Deploy V3 SuperPaymaster
        // Constructor: (entryPoint, owner, registry, aPNTs, aggregator, treasury)
        superPaymaster = new SuperPaymasterV3(IEntryPoint(entryPointAddress), deployer, IRegistryV3(address(registry)), aPNTsAddr, priceFeedAddr, treasury);

        // 6. Deploy Token Factory (for xPNTs)
        // xPNTsFactory constructor: (superpaymaster, registry)
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));

        // 7. Deploy PaymasterFactory & V4 Implementation
        paymasterFactory = new PaymasterFactory();
        paymasterV4Impl = new PaymasterV4_1i();
        
        // Register Implementation
        paymasterFactory.addImplementation("v4.1i", address(paymasterV4Impl));
        paymasterFactory.setDefaultVersion("v4.1i");

        // Deploy a Proxy Instance for Testing
        address proxyAddr = paymasterFactory.deployPaymasterDefault("");
        PaymasterV4_1i paymasterV4Proxy = PaymasterV4_1i(payable(proxyAddr));

        vm.stopBroadcast();

        // Output JSON
        string memory json = "json";
        vm.serializeAddress(json, "gToken", address(gToken));
        vm.serializeAddress(json, "staking", address(staking));
        vm.serializeAddress(json, "registry", address(registry));
        vm.serializeAddress(json, "sbt", address(sbt));
        vm.serializeAddress(json, "superPaymaster", address(superPaymaster));
        // aPNTs is string, convert to address logic? 
        // Or just use Setup logic correctly.
        // vm.serializeAddress(json, "aPNTs", aPNTs); // aPNTs is string type in local var?
        // Let's use vm.serializeString for aPNTs
        vm.serializeString(json, "aPNTs", aPNTs);
        
        vm.serializeAddress(json, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(json, "paymasterFactory", address(paymasterFactory));
        vm.serializeAddress(json, "paymasterV4Impl", address(paymasterV4Impl));
        vm.serializeAddress(json, "paymasterV4Proxy", address(paymasterV4Proxy));
        string memory finalJson = vm.serializeAddress(json, "entryPoint", entryPointAddress);

        vm.writeFile("script/v3/config.json", finalJson);
    }
}
