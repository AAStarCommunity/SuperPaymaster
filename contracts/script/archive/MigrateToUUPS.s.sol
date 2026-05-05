// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
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

// External Interfaces
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title MigrateToUUPS
 * @notice One-time Sepolia migration: upgrades Registry & SuperPaymaster to UUPS proxies (v4.0.0)
 *
 * REUSED (not redeployed):
 *   GToken, GTokenStaking, MySBT, BLSValidator
 *
 * NEWLY DEPLOYED:
 *   Registry impl + ERC1967Proxy, SuperPaymaster impl + ERC1967Proxy,
 *   xPNTsFactory, ReputationSystem, BLSAggregator, DVTValidator,
 *   PaymasterFactory, PaymasterV4 Impl
 *
 * ETH required: ~0.5 ETH (0.1 SP deposit + 0.1 SP stake + 0.1 V4 stake + 0.05 V4 deposit + gas)
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/MigrateToUUPS.s.sol:MigrateToUUPS \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast -vvvv
 */
contract MigrateToUUPS is Script {
    // ===== Reused Sepolia Contracts (no immutable REGISTRY dependency) =====
    address constant GTOKEN         = 0x8d6Fe002dDacCcFBD377F684EC1825f2E1ab7ef6;
    address constant STAKING        = 0x7A1216C2d814D2389698C64eD23AA1aA9Eb6343E;
    address constant MYSBT          = 0x28eBFc5fc03B1d7648254AbF1C7B39DbFdef1a94;
    address constant BLS_VALIDATOR  = 0xA88ADec5A8dc422B57488272d5aD5913d728942A;

    // ===== Sepolia Infrastructure =====
    address constant ENTRY_POINT    = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ETH_USD_FEED   = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant SA_FACTORY     = 0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985;

    // ===== Newly Deployed (set in run()) =====
    Registry registry;
    SuperPaymaster superPaymaster;
    xPNTsFactory xpntsFactory;
    ReputationSystem repSystem;
    BLSAggregator aggregator;
    DVTValidator dvt;
    PaymasterFactory pmFactory;
    Paymaster pmV4Impl;
    xPNTsToken apnts;

    address deployer;

    function setUp() public {
        if (vm.envOr("DEPLOYER_ADDRESS", address(0)) != address(0)) {
            deployer = vm.envAddress("DEPLOYER_ADDRESS");
        } else {
            deployer = msg.sender;
        }
    }

    function run() external {
        vm.startBroadcast();

        console.log("=== UUPS Migration to v4.0.0 ===");
        console.log("Deployer:", deployer);

        // ── Phase 0: Clear Legacy Role Locks ────────────────────────────
        // Deployer has existing role locks in GTokenStaking from pre-UUPS deployment.
        // Temporarily set deployer as "registry" so we can call onlyRegistry functions
        // to unlock the old stakes before pointing staking at the new Registry proxy.
        console.log("\n--- Phase 0: Clear Legacy Locks ---");
        _clearLegacyLocks();

        // ── Step 1: Deploy Registry UUPS Proxy ──────────────────────────
        console.log("\n--- Step 1: Registry (UUPS Proxy) ---");
        Registry regImpl = new Registry();
        console.log("  Registry impl:", address(regImpl));

        bytes memory regInit = abi.encodeCall(
            Registry.initialize,
            (deployer, STAKING, MYSBT)
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = Registry(address(regProxy));
        console.log("  Registry proxy:", address(registry));

        // ── Step 2: Deploy SuperPaymaster UUPS Proxy ────────────────────
        console.log("\n--- Step 2: SuperPaymaster (UUPS Proxy) ---");
        SuperPaymaster spImpl = new SuperPaymaster(
            IEntryPoint(ENTRY_POINT), registry, ETH_USD_FEED
        );
        console.log("  SuperPaymaster impl:", address(spImpl));

        // aPNTs = address(0) initially; set after role orchestration deploys aPNTs
        bytes memory spInit = abi.encodeCall(
            SuperPaymaster.initialize,
            (deployer, address(0), deployer, 4200)
        );
        ERC1967Proxy spProxy = new ERC1967Proxy(address(spImpl), spInit);
        superPaymaster = SuperPaymaster(payable(address(spProxy)));
        console.log("  SuperPaymaster proxy:", address(superPaymaster));

        // ── Step 3: Redeploy Tool Contracts (immutable REGISTRY refs) ───
        console.log("\n--- Step 3: Tool Contracts ---");

        xpntsFactory = new xPNTsFactory(address(0), address(registry));
        console.log("  xPNTsFactory:", address(xpntsFactory));

        repSystem = new ReputationSystem(address(registry));
        console.log("  ReputationSystem:", address(repSystem));

        aggregator = new BLSAggregator(
            address(registry), address(superPaymaster), address(0)
        );
        console.log("  BLSAggregator:", address(aggregator));

        dvt = new DVTValidator(address(registry));
        console.log("  DVTValidator:", address(dvt));

        pmFactory = new PaymasterFactory();
        console.log("  PaymasterFactory:", address(pmFactory));

        pmV4Impl = new Paymaster(address(registry));
        console.log("  PaymasterV4 Impl:", address(pmV4Impl));

        // ── Step 4: Wiring ──────────────────────────────────────────────
        console.log("\n--- Step 4: Wiring ---");
        _executeWiring();

        // ── Step 5: Role Orchestration ──────────────────────────────────
        console.log("\n--- Step 5: Role Orchestration ---");
        _orchestrateRoles();

        vm.stopBroadcast();

        // ── Step 6: Config Output ───────────────────────────────────────
        _generateConfig();
        _printSummary();
    }

    // ─── Phase 0: Legacy Lock Cleanup ───────────────────────────────────

    function _clearLegacyLocks() internal {
        GTokenStaking staking = GTokenStaking(STAKING);

        // Temporarily make deployer the "registry" to call onlyRegistry functions
        staking.setRegistry(deployer);

        // Unlock ROLE_COMMUNITY if locked
        bytes32 roleCommunity = keccak256("COMMUNITY");
        if (staking.hasRoleLock(deployer, roleCommunity)) {
            staking.unlockAndTransfer(deployer, roleCommunity);
            console.log("  Unlocked legacy COMMUNITY role lock");
        }

        // Unlock ROLE_PAYMASTER_AOA if locked
        bytes32 rolePmAOA = keccak256("PAYMASTER_AOA");
        if (staking.hasRoleLock(deployer, rolePmAOA)) {
            staking.unlockAndTransfer(deployer, rolePmAOA);
            console.log("  Unlocked legacy PAYMASTER_AOA role lock");
        }

        console.log("  Legacy locks cleared");
        // NOTE: staking.setRegistry will be set to the new proxy in _executeWiring()
    }

    // ─── Wiring ─────────────────────────────────────────────────────────

    function _executeWiring() internal {
        // Point existing contracts to new Registry proxy
        GTokenStaking(STAKING).setRegistry(address(registry));
        console.log("  staking.setRegistry -> done");

        MySBT(MYSBT).setRegistry(address(registry));
        console.log("  mysbt.setRegistry -> done");

        // Configure new Registry
        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(repSystem), true);
        registry.setBLSAggregator(address(aggregator));
        registry.setBLSValidator(BLS_VALIDATOR);
        console.log("  Registry configured (SP, Rep, BLS Agg, BLS Val)");

        // Cross-link monitoring modules
        aggregator.setDVTValidator(address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        superPaymaster.setBLSAggregator(address(aggregator));
        console.log("  Aggregator <-> DVT <-> SP linked");

        // Authorize BLSAggregator as slasher for two-tier slash
        GTokenStaking(STAKING).setAuthorizedSlasher(address(aggregator), true);
        console.log("  staking.setAuthorizedSlasher(aggregator) -> done");

        // PaymasterFactory: register V4 impl
        pmFactory.addImplementation("v4.3", address(pmV4Impl));
        console.log("  pmFactory.addImplementation('v4.3') -> done");

        // xPNTs <-> SuperPaymaster cross-link
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        xpntsFactory.setSuperPaymasterAddress(address(superPaymaster));
        console.log("  xPNTsFactory <-> SuperPaymaster linked");

        // Oracle price initialization (best-effort)
        try AggregatorV3Interface(ETH_USD_FEED).latestRoundData()
            returns (uint80, int256 price, uint256, uint256, uint80)
        {
            try superPaymaster.updatePriceDVT(price, block.timestamp, "") {
                console.log("  Oracle price force-initialized");
            } catch {
                superPaymaster.updatePrice();
                console.log("  Oracle price updated via updatePrice()");
            }
        } catch {
            console.log("  [WARN] Oracle price init skipped (feed unavailable)");
        }

        // ETH deposit + stake on EntryPoint for SuperPaymaster
        superPaymaster.deposit{value: 0.1 ether}();
        superPaymaster.addStake{value: 0.1 ether}(1 days);
        console.log("  SuperPaymaster: 0.1 ETH deposited + 0.1 ETH staked");
    }

    // ─── Role Orchestration ─────────────────────────────────────────────

    function _orchestrateRoles() internal {
        // Mint GToken for staking (community 30 + paymaster 30 + buffer)
        GToken(GTOKEN).mint(deployer, 100 ether);
        GToken(GTOKEN).approve(STAKING, 100 ether);
        console.log("  Minted 100 GToken for role registration");

        // Register AAStar community
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            website: "https://aastar.io",
            description: "AAStar - Empower Community!",
            logoURI: "ipfs://bafkreihqmsnyn4s5rt6nnyrxbwaufzmrsr2xfbj4yeqgi6qdr35umzxiay",
            stakeAmount: 30 ether
        });
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, abi.encode(aaStarData));
        console.log("  AAStar COMMUNITY registered");

        // Deploy aPNTs via factory
        address apntsAddr = xpntsFactory.deployxPNTsToken(
            "AAStar PNTs", "aPNTs", "AAStar", "aastar.eth", 1e18, address(0)
        );
        apnts = xPNTsToken(apntsAddr);
        console.log("  aPNTs deployed:", apntsAddr);

        // Verify auto-wiring
        require(
            apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster),
            "Migrate: aPNTs Factory auto-wiring to SP failed!"
        );

        // Set aPNTs in SuperPaymaster
        superPaymaster.setAPNTsToken(apntsAddr);
        console.log("  SuperPaymaster.setAPNTsToken -> done");

        // Deploy AOA Paymaster V4 instance via factory
        bytes memory pmInit = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256)",
            ENTRY_POINT, deployer, deployer, ETH_USD_FEED, 100, 1 ether, 4200
        );
        address pmProxy = pmFactory.deployPaymaster("v4.3", pmInit);
        console.log("  AOA PaymasterV4 deployed:", pmProxy);

        // Fund and configure V4 paymaster
        Paymaster(payable(pmProxy)).addStake{value: 0.1 ether}(86400);
        Paymaster(payable(pmProxy)).updatePrice();
        Paymaster(payable(pmProxy)).setTokenPrice(address(apnts), 2_000_000); // $0.02

        // Register PAYMASTER_AOA role
        Registry.PaymasterRoleData memory pmData = Registry.PaymasterRoleData({
            paymasterContract: pmProxy,
            name: "Jason V4 PM",
            apiEndpoint: "https://rpc.aastar.io/pm",
            stakeAmount: 30 ether
        });
        GToken(GTOKEN).approve(STAKING, 33 ether);
        registry.registerRole(keccak256("PAYMASTER_AOA"), deployer, abi.encode(pmData));
        console.log("  PAYMASTER_AOA role registered");

        // Fund V4 PM deposit on EntryPoint
        IEntryPoint(ENTRY_POINT).depositTo{value: 0.05 ether}(pmProxy);
        console.log("  V4 PM: 0.1 ETH staked + 0.05 ETH deposited");

        // Mint initial aPNTs
        apnts.mint(deployer, 20_000 ether);
        console.log("  Minted 20,000 aPNTs to deployer");
    }

    // ─── Config Generation ──────────────────────────────────────────────

    function _generateConfig() internal {
        string memory finalPath = string.concat(
            vm.projectRoot(), "/deployments/config.sepolia.json"
        );

        string memory j = "json";

        // Reused addresses (unchanged)
        vm.serializeAddress(j, "gToken", GTOKEN);
        vm.serializeAddress(j, "staking", STAKING);
        vm.serializeAddress(j, "sbt", MYSBT);
        vm.serializeAddress(j, "blsValidator", BLS_VALIDATOR);
        vm.serializeAddress(j, "paymasterFactory", address(pmFactory));
        vm.serializeAddress(j, "simpleAccountFactory", SA_FACTORY);
        vm.serializeAddress(j, "entryPoint", ENTRY_POINT);
        vm.serializeAddress(j, "priceFeed", ETH_USD_FEED);

        // New UUPS proxy addresses
        vm.serializeAddress(j, "registry", address(registry));
        vm.serializeAddress(j, "superPaymaster", address(superPaymaster));

        // Redeployed tool contracts
        vm.serializeAddress(j, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(j, "reputationSystem", address(repSystem));
        vm.serializeAddress(j, "blsAggregator", address(aggregator));
        vm.serializeAddress(j, "dvtValidator", address(dvt));
        vm.serializeAddress(j, "paymasterV4Impl", address(pmV4Impl));

        // New aPNTs from fresh factory
        vm.serializeAddress(j, "aPNTs", address(apnts));

        vm.serializeString(j, "srcHash", vm.envOr("SRC_HASH", string("")));
        string memory finalJson = vm.serializeString(
            j, "updateTime", vm.envOr("DEPLOY_TIME", string("N/A"))
        );

        vm.writeFile(finalPath, finalJson);
        console.log("\nConfig saved to:", finalPath);
    }

    // ─── Verification Summary ───────────────────────────────────────────

    function _printSummary() internal view {
        console.log("\n============================================");
        console.log("  UUPS Migration Complete (v4.0.0)");
        console.log("============================================");
        console.log("  [UUPS] Registry proxy:       ", address(registry));
        console.log("  [UUPS] SuperPaymaster proxy: ", address(superPaymaster));
        console.log("  [NEW]  xPNTsFactory:         ", address(xpntsFactory));
        console.log("  [NEW]  ReputationSystem:     ", address(repSystem));
        console.log("  [NEW]  BLSAggregator:        ", address(aggregator));
        console.log("  [NEW]  DVTValidator:         ", address(dvt));
        console.log("  [NEW]  PaymasterFactory:     ", address(pmFactory));
        console.log("  [NEW]  PaymasterV4 Impl:     ", address(pmV4Impl));
        console.log("  [NEW]  aPNTs:                ", address(apnts));
        console.log("--------------------------------------------");
        console.log("  [OK]   GToken:               ", GTOKEN);
        console.log("  [OK]   GTokenStaking:        ", STAKING);
        console.log("  [OK]   MySBT:                ", MYSBT);
        console.log("  [OK]   BLSValidator:         ", BLS_VALIDATOR);
        console.log("============================================");
        console.log("");
        console.log("  Verify UUPS with:");
        console.log("    cast call <registry> 'version()(string)'");
        console.log("    cast call <sp> 'version()(string)'");
        console.log("    cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc");
        console.log("");
        console.log("  Next upgrade (no redeploy needed):");
        console.log("    forge create RegistryV2 --constructor-args ...");
        console.log("    cast send <proxy> 'upgradeToAndCall(address,bytes)' <newImpl> 0x");
        console.log("============================================");
    }
}
