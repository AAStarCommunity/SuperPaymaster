// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core Imports
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";

// Paymaster Imports
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

// Module Imports
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/validators/BLSValidator.sol";

// External Interfaces
import {EntryPoint} from "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DeployLive
 * @notice Full Infrastructure Deployment (Steps 1-5 AAStar + Step 6 Mycelium Community)
 */
contract DeployLive is Script {
    using Clones for address;


    address deployer;
    address entryPointAddr;
    address priceFeedAddr;
    address simpleAccountFactory;

    GToken gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    Registry registry;
    xPNTsToken apnts;
    SuperPaymaster superPaymaster;
    ReputationSystem repSystem;
    BLSAggregator aggregator;
    DVTValidator dvt;
    address blsValidator;
    xPNTsFactory xpntsFactory;
    PaymasterFactory pmFactory;
    Paymaster pmV4Impl;
    address pntsAddr; // Mycelium Community PNTs

    function setUp() public {
        // System / External Infrastructure (Remains in ENV)
        entryPointAddr = vm.envAddress("ENTRY_POINT");
        priceFeedAddr = vm.envAddress("ETH_USD_FEED");
        simpleAccountFactory = vm.envAddress("SIMPLE_ACCOUNT_FACTORY");
        
        // Resolve Deployer Address
        // 1. Try DEPLOYER_ADDRESS (if set by wrapper script)
        // 2. Fallback to msg.sender (only for Anvil/Private Key mode)
        if (vm.envOr("DEPLOYER_ADDRESS", address(0)) != address(0)) {
            deployer = vm.envAddress("DEPLOYER_ADDRESS");
        } else {
            deployer = msg.sender;
        }
    }

    function run() external {
        // Use the configured account from CLI (--account or --private-key)
        vm.startBroadcast();
        
        console.log("Deployer:", deployer);

        console.log("=== Step 1: Deploy Foundation (Scheme B - UUPS Proxy) ===");
        gtoken = new GToken(21_000_000 * 1e18);

        // Deploy Registry as UUPS proxy first (placeholder initialize)
        Registry regImpl = new Registry();
        bytes memory regInit = abi.encodeCall(Registry.initialize, (deployer, address(0), address(0)));
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = Registry(address(regProxy));

        // Deploy Staking and MySBT with immutable Registry reference
        staking = new GTokenStaking(address(gtoken), deployer, address(registry));
        mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);

        // Wire staking and MySBT into Registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));
        // Sync exit fees for ALL operator roles (minStake > 0).
        // ⚠ When adding new operator roles in Registry.initialize(), add them here too.
        bytes32[] memory exitFeeRoles = new bytes32[](5);
        exitFeeRoles[0] = registry.ROLE_PAYMASTER_AOA();
        exitFeeRoles[1] = registry.ROLE_PAYMASTER_SUPER();
        exitFeeRoles[2] = registry.ROLE_DVT();
        exitFeeRoles[3] = registry.ROLE_ANODE();
        exitFeeRoles[4] = registry.ROLE_KMS();
        registry.syncExitFees(exitFeeRoles);

        console.log("=== Step 2: Deploy Core (UUPS Proxy) ===");
        xpntsFactory = new xPNTsFactory(address(0), address(registry));
        SuperPaymaster spImpl = new SuperPaymaster(IEntryPoint(entryPointAddr), registry, priceFeedAddr);
        bytes memory spInit = abi.encodeCall(SuperPaymaster.initialize, (deployer, address(0), deployer, 4200));
        ERC1967Proxy spProxy = new ERC1967Proxy(address(spImpl), spInit);
        superPaymaster = SuperPaymaster(payable(address(spProxy)));

        console.log("=== Step 3: Deploy Modules ===");
        repSystem = new ReputationSystem(address(registry));
        aggregator = new BLSAggregator(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidator(address(registry));
        
        blsValidator = address(new BLSValidator());
        pmFactory = new PaymasterFactory();
        pmV4Impl = new Paymaster(address(registry));

        console.log("=== Step 4: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 5: Role Orchestration (Jason / AAStar) ===");
        _orchestrateRolesJason();

        console.log("=== Step 6: Mycelium Community (Anni) ===");
        _setupMyceliumCommunity();

        vm.stopBroadcast();
        _generateConfig();
    }

    function _executeWiring() internal {
        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(repSystem), true);
        registry.setBLSAggregator(address(aggregator));
        registry.setBLSValidator(blsValidator);
        aggregator.setDVTValidator(address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        xpntsFactory.setSuperPaymasterAddress(address(superPaymaster));
        
        // Authorize BLSAggregator as slasher for Tier 2 (GToken governance slash)
        staking.setAuthorizedSlasher(address(aggregator), true);

        // Oracle Init
        try AggregatorV3Interface(priceFeedAddr).latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            try superPaymaster.updatePriceDVT(price, block.timestamp, "") {
                console.log("  Cache Price Force-Initialized");
            } catch {
                superPaymaster.updatePrice();
            }
        } catch {}

        // Step 24 & 25: 0.1 ETH
        superPaymaster.deposit{value: 0.1 ether}();
        superPaymaster.addStake{value: 0.1 ether}(1 days);
    }

    function _orchestrateRolesJason() internal {
        gtoken.mint(deployer, 2000 ether); // Increased to 2000 to cover sub-sequent roles and Anni funding
        gtoken.approve(address(staking), 2000 ether);
        
        // Step 28: Register AAStar
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            website: "https://aastar.io",
            description: "Empower Community, Unleash Humanity\xF0\x9F\x8D\x84",
            logoURI: "ipfs://bafkreihqmsnyn4s5rt6nnyrxbwaufzmrsr2xfbj4yeqgi6qdr35umzxiay",
            stakeAmount: 30 ether
        });
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, abi.encode(aaStarData));
        
        // Step 29: aPNTs
        address apntsAddr = xpntsFactory.deployxPNTsToken("AAStar PNTs", "aPNTs", "AAStar", "aastar.eth", 1e18, address(0));
        apnts = xPNTsToken(apntsAddr);
        console.log("  aPNTs Deployed at:", apntsAddr);
        
        // Factory handles auto-wiring of SuperPaymaster firewall if set beforehand
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "Deploy: aPNTs Factory auto-wiring failed!");
        
        superPaymaster.setAPNTsToken(apntsAddr);
        console.log("  aPNTs Firewall auto-wired via Factory to SP:", address(superPaymaster));

        // Step 31-36: AOA Paymaster
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256)",
            entryPointAddr, deployer, deployer, priceFeedAddr, 100, 1 ether, 4200
        );
        address pmProxy = pmFactory.deployPaymaster("v4.2", init);
        Paymaster(payable(pmProxy)).addStake{value: 0.1 ether}(86400); // Increased to 0.1 ETH as requested
        Paymaster(payable(pmProxy)).updatePrice();
        // Step 34: $0.02
        Paymaster(payable(pmProxy)).setTokenPrice(address(apnts), 2_000_000); 

        gtoken.approve(address(staking), 33 ether);
        registry.registerRole(registry.ROLE_PAYMASTER_AOA(), deployer, abi.encode(uint256(30 ether)));
        
        // Step 37: 0.05 ETH
        IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxy);
        
        // Step 38: Mint 20,000 aPNTs
        apnts.mint(deployer, 20_000 ether);
    }

    function _setupMyceliumCommunity() internal {
        uint256 anniPK = vm.envUint("PRIVATE_KEY_ANNI");
        address anni = vm.addr(anniPK);
        console.log("  Anni (Mycelium Admin):", anni);

        // --- Deployer prepares Anni (safeMintForRole = deployer pays stake) ---
        gtoken.approve(address(staking), 100 ether);

        // 6a. Register Mycelium as COMMUNITY (deployer pays 30 stake + 3 burn)
        Registry.CommunityRoleData memory mycData = Registry.CommunityRoleData({
            name: "Mycelium Community",
            ensName: "mushroom.box",
            website: "https://mushroom.box",
            description: "Protocols and Networks",
            logoURI: "ipfs://bafybeiait3ds2fn42kmnu3ofp73ycujgppks3ma3zzvxnedthunpsrvn7e",
            stakeAmount: 30 ether
        });
        registry.safeMintForRole(registry.ROLE_COMMUNITY(), anni, abi.encode(mycData));
        console.log("  Mycelium Community Registered");

        // 6b. Register as PAYMASTER_SUPER (deployer pays 50 stake + 5 burn)
        registry.safeMintForRole(registry.ROLE_PAYMASTER_SUPER(), anni, "");
        console.log("  Mycelium PAYMASTER_SUPER Registered");

        // 6c. Fund Anni with aPNTs for SuperPaymaster deposit
        apnts.transfer(anni, 1000 ether);

        // --- Switch to Anni broadcast for operator-specific calls ---
        vm.stopBroadcast();
        vm.startBroadcast(anniPK);

        // 6d. Deploy PNTs (Mycelium community token — special token name)
        pntsAddr = xpntsFactory.deployxPNTsToken(
            "Mycelium PNTs", "PNTs", "Mycelium Community", "mushroom.box", 1e18, address(0)
        );
        console.log("  PNTs Deployed at:", pntsAddr);

        // 6e. Configure Anni as SuperPaymaster operator
        superPaymaster.configureOperator(pntsAddr, anni, 1e18);
        console.log("  Operator Configured (PNTs -> SuperPaymaster)");

        // 6f. Deposit aPNTs into SuperPaymaster (gasless sponsorship fund)
        apnts.approve(address(superPaymaster), 1000 ether);
        superPaymaster.deposit(1000 ether);
        console.log("  1000 aPNTs Deposited to SuperPaymaster");

        // 6g. Mint PNTs for test users
        xPNTsToken(pntsAddr).mint(anni, 500 ether);
        console.log("  500 PNTs Minted to Anni");

        // --- Switch back to deployer ---
        vm.stopBroadcast();
        vm.startBroadcast();
    }

    function _generateConfig() internal {
        string memory network = vm.envString("ENV");
        string memory finalPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory jsonObj = "json";
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "gToken", address(gtoken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "superPaymaster", address(superPaymaster));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(pmFactory)); 
        vm.serializeAddress(jsonObj, "aPNTs", address(apnts));
        vm.serializeAddress(jsonObj, "sbt", address(mysbt));
        vm.serializeAddress(jsonObj, "reputationSystem", address(repSystem));
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvt));
        vm.serializeAddress(jsonObj, "blsAggregator", address(aggregator));
        vm.serializeAddress(jsonObj, "blsValidator", blsValidator);
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        vm.serializeAddress(jsonObj, "simpleAccountFactory", simpleAccountFactory);
        vm.serializeAddress(jsonObj, "pnts", pntsAddr);
        vm.serializeString(jsonObj, "srcHash", vm.envOr("SRC_HASH", string("")));
        vm.serializeString(jsonObj, "updateTime", vm.envOr("DEPLOY_TIME", string("N/A")));
        vm.serializeAddress(jsonObj, "priceFeed", priceFeedAddr);
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Live Phase 1 Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}
