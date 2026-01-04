// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/PaymasterV4_1i.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/monitoring/BLSAggregator.sol";
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
import {SimpleAccountFactory} from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";

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
    SuperPaymaster public superPaymaster;
    xPNTsFactory public xpntsFactory;

    // Paymaster Factory
    PaymasterFactory public paymasterFactory;
    PaymasterV4_1i public paymasterV4Impl;
    SimpleAccountFactory public simpleAccountFactory;

    // Reputation & Monitoring
    ReputationSystem public reputationSystem;
    DVTValidator public dvtValidator;
    BLSAggregator public blsAggregator;

    MockV3Aggregator public priceFeed;

    function run() external {
        // Load Config
        entryPointAddress = vm.envOr("ENTRYPOINT_ADDRESS_V07", address(0));

        // Get Private Key first to determine deployer
        uint256 privateKey = vm.envUint("PRIVATE_KEY_JASON");
        address broadcaster = vm.addr(privateKey);

        address deployer;
        address treasury;
        address dao;

        // For Anvil, use broadcaster as deployer to ensure tokens are minted correctly
        if (block.chainid == 31337) {
            deployer = broadcaster;
            treasury = broadcaster;
            dao = broadcaster; // For local testing, DAO can also be the broadcaster
        } else {
            deployer = vm.envAddress("ADDRESS_JASON_EOA");
            treasury = vm.envOr("TREASURY_ADDRESS", deployer);
            dao = vm.envOr("DAO_MULTISIG", deployer);
        }

        // Start Broadcasting
        vm.startBroadcast(privateKey);

        // 0. Environment Setup (Local vs Testnet)
        address priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        if (block.chainid == 31337) {
            // Anvil
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

        // Mint initial supply to deployer (for testing)
        gToken.mint(deployer, 100_000_000 ether); // 100 Million tokens

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
        xPNTsToken t;
        if (block.chainid == 31337) {
            // Deploy a mock xPNTs token for testing
            t = new xPNTsToken("Anvil PNTs", "aPNTs", deployer, "Anvil DAO", "anvil.eth", 1 ether);
            aPNTsAddr = address(t);
            // Mint 10,000 aPNTs to deployer for gas payments
            t.mint(deployer, 10000 ether);
        }
        string memory aPNTs = vm.toString(aPNTsAddr);

        // 5. Deploy V3 SuperPaymaster
        // Constructor: (entryPoint, owner, registry, aPNTs, aggregator, treasury)
        superPaymaster = new SuperPaymaster(
            IEntryPoint(entryPointAddress), deployer, IRegistry(address(registry)), aPNTsAddr, priceFeedAddr, treasury
        );

        // 6. Deploy Token Factory (for xPNTs)
        // xPNTsFactory constructor: (superpaymaster, registry)
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));

        // 6.1 Register Deployer as Community (for local testing)
        if (block.chainid == 31337) {
            // Simplified role data to avoid memory issues (triggers Registry.sol local bypass)
            // Need to approve GToken for staking first
            gToken.approve(address(staking), type(uint256).max);
            registry.registerRole(registry.ROLE_COMMUNITY(), deployer, "");
        }

        // 7. Deploy PaymasterFactory & V4 Implementation
        paymasterFactory = new PaymasterFactory();
        paymasterV4Impl = new PaymasterV4_1i();

        // Register Implementation
        paymasterFactory.addImplementation("v4.1i", address(paymasterV4Impl));
        paymasterFactory.setDefaultVersion("v4.1i");

        // Deploy a Proxy Instance for Testing with proper initialization
        bytes memory initData = abi.encodeWithSelector(
            PaymasterV4_1i.initialize.selector,
            entryPointAddress,
            deployer,
            treasury,
            priceFeedAddr,
            100,              // _serviceFeeRate: 1%
            10000000000000000,// _maxGasCostCap: 0.01 ETH
            0,                // _minTokenBalance (unused)
            address(superPaymaster),
            address(0),       // _initialSBT
            address(0),       // _initialGasToken
            address(registry)
        );
        address proxyAddr = paymasterFactory.deployPaymaster("v4.1i", initData);

        PaymasterV4_1i paymasterV4Proxy = PaymasterV4_1i(payable(proxyAddr));

        // 8. Deploy SimpleAccountFactory (for Test Users)
        simpleAccountFactory = new SimpleAccountFactory(IEntryPoint(entryPointAddress));

        // 9. Deploy Reputation & Monitoring Contracts
        reputationSystem = new ReputationSystem(address(registry));
        dvtValidator = new DVTValidator(address(registry));
        blsAggregator = new BLSAggregator(address(registry), address(superPaymaster), address(dvtValidator));
        
        // Wire DVT Validator to BLS Aggregator
        dvtValidator.setBLSAggregator(address(blsAggregator));

        // V3.2: Set BLS Threshold to 3 (as required) and wire to Registry
        blsAggregator.setThreshold(3);
        registry.setBLSAggregator(address(blsAggregator));

        vm.stopBroadcast();

        // Output JSON
        string memory jsonObj = "json";
        vm.serializeAddress(jsonObj, "gToken", address(gToken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "sbt", address(sbt));
        vm.serializeAddress(jsonObj, "superPaymaster", address(superPaymaster));
        vm.serializeString(jsonObj, "aPNTs", aPNTs);

        vm.serializeAddress(jsonObj, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(paymasterFactory));
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(paymasterV4Impl));
        vm.serializeAddress(jsonObj, "paymasterV4Proxy", address(paymasterV4Proxy));
        vm.serializeAddress(jsonObj, "simpleAccountFactory", address(simpleAccountFactory));
        vm.serializeAddress(jsonObj, "reputationSystem", address(reputationSystem));
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvtValidator));
        vm.serializeAddress(jsonObj, "blsAggregator", address(blsAggregator));
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddress);

        vm.writeFile("script/v3/config.json", finalJson);
    }
}
