// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Core Imports
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
// Named import: avoid leaking GTokenAuthorization's transitive EIP712 symbol into
// this file's scope (it would clash with MicroPaymentChannel's EIP712 — both inherit
// a differently-pathed EIP712, causing "Identifier already declared").
import {GTokenAuthorization} from "src/tokens/GTokenAuthorization.sol";
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
import {MicroPaymentChannel} from "src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol";
// BLSValidator standalone contract removed in P0-1 — Registry now verifies via BLSAggregator.

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
    address spImplAddr;          // SuperPaymaster implementation (UUPS)
    address registryImplAddr;    // Registry implementation (UUPS) — needed by audit-core ERC-1967 check
    address erc8004Validation;   // ERC-8004 ValidationRegistry (stored for config; SP doesn't wire it yet)
    MicroPaymentChannel microPaymentCh; // Deployed in Step 4

    GTokenAuthorization gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    Registry registry;
    xPNTsToken apnts;
    SuperPaymaster superPaymaster;
    ReputationSystem repSystem;
    BLSAggregator aggregator;
    DVTValidator dvt;
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

        // Deploy Registry as UUPS proxy first (no deps)
        Registry regImpl = new Registry();
        registryImplAddr = address(regImpl); // capture for config write (UUPS upgrade support)
        bytes memory regInit = abi.encodeCall(Registry.initialize, (deployer, address(0), address(0)));
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        registry = Registry(address(regProxy));

        // Deploy xPNTsFactory early — GTokenAuthorization needs factory address (immutable)
        xpntsFactory = new xPNTsFactory(address(0), address(registry)); // SP not deployed yet

        // Deploy GTokenAuthorization (replaces plain GToken)
        gtoken = new GTokenAuthorization(21_000_000 * 1e18, address(xpntsFactory));

        // Deploy Staking and MySBT with immutable Registry + GToken references
        staking = new GTokenStaking(address(gtoken), deployer, address(registry));
        mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);

        // Wire staking and MySBT into Registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));
        // Wire MySBT into GTokenAuthorization (one-time, locks RC-2 SBT path)
        gtoken.setMySBT(address(mysbt));
        // Sync exit fees for ALL operator roles (minStake > 0).
        // ⚠ When adding new operator roles in Registry.initialize(), add them here too.
        bytes32[] memory exitFeeRoles = new bytes32[](5);
        exitFeeRoles[0] = ROLE_PAYMASTER_AOA;
        exitFeeRoles[1] = ROLE_PAYMASTER_SUPER;
        exitFeeRoles[2] = ROLE_DVT;
        exitFeeRoles[3] = ROLE_ANODE;
        exitFeeRoles[4] = ROLE_KMS;
        registry.syncExitFees(exitFeeRoles);

        // CRITICAL: Must register COMMUNITY and deploy aPNTs BEFORE SuperPaymaster
        // so aPNTs address can be passed to initialize() — avoids 7-day setAPNTsToken timelock.
        console.log("=== Step 2: Pre-register AAStar COMMUNITY + Deploy aPNTs ===");
        gtoken.mint(deployer, 2000 ether);
        gtoken.approve(address(staking), 2000 ether);
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            stakeAmount: 30 ether
        });
        registry.registerRole(ROLE_COMMUNITY, deployer, abi.encode(aaStarData));

        // xPNTsFactory already deployed in Step 1
        address apntsAddr = xpntsFactory.deployxPNTsToken("AAStar PNTs", "aPNTs", "AAStar", "aastar.eth", 1e18, address(0));
        apnts = xPNTsToken(apntsAddr);
        console.log("  aPNTs Deployed at:", apntsAddr);

        console.log("=== Step 3: Deploy SuperPaymaster (UUPS Proxy) ===");
        SuperPaymaster spImpl = new SuperPaymaster(IEntryPoint(entryPointAddr), registry, priceFeedAddr);
        spImplAddr = address(spImpl); // capture for config write
        bytes memory spInit = abi.encodeCall(SuperPaymaster.initialize, (deployer, address(apnts), deployer, 4200));
        ERC1967Proxy spProxy = new ERC1967Proxy(address(spImpl), spInit);
        superPaymaster = SuperPaymaster(payable(address(spProxy)));

        console.log("=== Step 4: Deploy Modules ===");
        repSystem = new ReputationSystem(address(registry));
        dvt = new DVTValidator(address(registry));
        aggregator = new BLSAggregator(address(registry), address(superPaymaster), address(dvt));
        microPaymentCh = new MicroPaymentChannel(deployer);

        pmFactory = new PaymasterFactory();
        pmV4Impl = new Paymaster(address(registry));

        console.log("=== Step 5: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 6: Role Orchestration (Jason / AAStar) ===");
        _orchestrateRolesJason();

        console.log("=== Step 7: Mycelium Community (Anni) ===");
        _setupMyceliumCommunity();

        vm.stopBroadcast();
        _generateConfig();
    }

    function _executeWiring() internal {
        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(repSystem), true);
        registry.setBLSAggregator(address(aggregator));
        aggregator.setDVTValidator(address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        xpntsFactory.setSuperPaymasterAddress(address(superPaymaster));
        // Wire aPNTs (deployed before SP in Step 2, so SP address must be set retroactively).
        // setSuperPaymasterAddress also sets autoApprovedSpenders[SP] = true.
        apnts.setSuperPaymasterAddress(address(superPaymaster));

        // Authorize BLSAggregator as slasher for Tier 2 (GToken governance slash)
        staking.setAuthorizedSlasher(address(aggregator), true);

        // AUDIT D-H4: assert critical wiring took effect. Setters can silently
        // no-op or run out of order, and the post-deploy Check scripts are
        // non-blocking (|| true), so a broken wire would otherwise surface only
        // AFTER config is written. Fail the deploy here instead, before config.
        require(address(registry.GTOKEN_STAKING()) == address(staking), "wire: setStaking");
        require(address(registry.MYSBT()) == address(mysbt), "wire: setMySBT");
        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "wire: setSuperPaymaster");
        require(registry.blsAggregator() == address(aggregator), "wire: setBLSAggregator");
        require(staking.authorizedSlashers(address(aggregator)), "wire: setAuthorizedSlasher");

        // ERC-8004 official agent registry addresses (CREATE2, deterministic across all EVM chains).
        // Mainnet chains: Ethereum, OP, Base, Arbitrum, Polygon, etc.
        // Testnet chains:  Sepolia, OP Sepolia, Base Sepolia, Arbitrum Sepolia, Polygon Amoy.
        // Override via AGENT_IDENTITY_REGISTRY / AGENT_REPUTATION_REGISTRY env vars if needed.
        address erc8004Identity;
        address erc8004Reputation;
        uint256 cid = block.chainid;
        bool isMainnet = (cid==1||cid==10||cid==137||cid==8453||cid==42161||cid==43114||cid==56||cid==534352);
        bool isTestnet = (cid==11155111||cid==11155420||cid==84532||cid==421614||cid==80002);
        if (isMainnet) {
            erc8004Identity   = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
            erc8004Reputation = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;
            erc8004Validation = 0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58;
        } else if (isTestnet) {
            erc8004Identity   = 0x8004A818BFB912233c491871b3d84c89A494BD9e;
            erc8004Reputation = 0x8004B663056A597Dffe9eCcC1965A193B7388713;
            erc8004Validation = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;
        }
        // Allow env override
        erc8004Identity   = vm.envOr("AGENT_IDENTITY_REGISTRY",   erc8004Identity);
        erc8004Reputation = vm.envOr("AGENT_REPUTATION_REGISTRY", erc8004Reputation);
        erc8004Validation = vm.envOr("AGENT_VALIDATION_REGISTRY", erc8004Validation);
        if (erc8004Identity != address(0) && erc8004Reputation != address(0)) {
            superPaymaster.setAgentRegistries(erc8004Identity, erc8004Reputation);
            console.log("  Agent registries wired (ERC-8004 official)");
            console.log("    identity:   ", erc8004Identity);
            console.log("    reputation: ", erc8004Reputation);
            console.log("    validation: ", erc8004Validation, " (recorded, not wired to SP yet)");
        } else {
            console.log("  WARN: Agent registries not wired (unsupported chain or no override set)");
        }

        // Oracle Init
        try AggregatorV3Interface(priceFeedAddr).latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            try superPaymaster.updatePriceDVT(price, block.timestamp, "", 0) {
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
        // COMMUNITY registration and aPNTs deployment already done in Step 2 of run().
        // aPNTs is wired to SuperPaymaster in _executeWiring().
        console.log("  aPNTs:", address(apnts), "SP:", address(superPaymaster));
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "Deploy: aPNTs SP wiring failed!");

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
        registry.registerRole(ROLE_PAYMASTER_AOA, deployer, abi.encode(uint256(30 ether)));
        
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

        // 6a. Register Mycelium as COMMUNITY (deployer pays 30 stake + burn)
        if (!registry.hasRole(ROLE_COMMUNITY, anni)) {
            gtoken.approve(address(staking), 34 ether);
            Registry.CommunityRoleData memory mycData = Registry.CommunityRoleData({
                name: "Mycelium Community",
                ensName: "mushroom.box",
                stakeAmount: 30 ether
            });
            registry.safeMintForRole(ROLE_COMMUNITY, anni, abi.encode(mycData));
            console.log("  Mycelium Community Registered");
        } else {
            console.log("  Mycelium Community (skip - already registered)");
        }

        // 6b. Register as PAYMASTER_SUPER (deployer pays 50 stake + burn)
        if (!registry.hasRole(ROLE_PAYMASTER_SUPER, anni)) {
            gtoken.approve(address(staking), 56 ether);
            registry.safeMintForRole(ROLE_PAYMASTER_SUPER, anni, "");
            console.log("  Mycelium PAYMASTER_SUPER Registered");
        } else {
            console.log("  Mycelium PAYMASTER_SUPER (skip - already registered)");
        }

        // 6c. Fund Anni with aPNTs for SuperPaymaster deposit
        if (apnts.balanceOf(anni) < 1000 ether) {
            apnts.transfer(anni, 1000 ether);
            console.log("  1000 aPNTs transferred to Anni");
        } else {
            console.log("  Anni aPNTs (skip - sufficient balance)");
        }

        // --- Switch to Anni broadcast for operator-specific calls ---
        vm.stopBroadcast();
        vm.startBroadcast(anniPK);

        // 6d. Deploy PNTs (Mycelium community token — special token name)
        pntsAddr = xpntsFactory.getTokenAddress(anni);
        if (pntsAddr == address(0)) {
            pntsAddr = xpntsFactory.deployxPNTsToken(
                "Mycelium PNTs", "PNTs", "Mycelium Community", "mushroom.box", 1e18, address(0)
            );
            console.log("  PNTs Deployed at:", pntsAddr);
        } else {
            console.log("  PNTs (skip - already deployed):", pntsAddr);
        }

        // 6e. Configure Anni as SuperPaymaster operator
        (, bool isCfg,,,,,,,) = superPaymaster.operators(anni);
        if (!isCfg) {
            superPaymaster.configureOperator(pntsAddr, anni);
            console.log("  Operator Configured (PNTs -> SuperPaymaster)");
        } else {
            console.log("  Operator (skip - already configured)");
        }

        // 6f. Deposit aPNTs into SuperPaymaster (gasless sponsorship fund)
        (uint128 bal,,,,,,,,) = superPaymaster.operators(anni);
        if (bal < 100 ether) {
            apnts.approve(address(superPaymaster), 1000 ether);
            superPaymaster.deposit(1000 ether);
            console.log("  1000 aPNTs Deposited to SuperPaymaster");
        } else {
            console.log("  SuperPaymaster deposit (skip - sufficient balance)");
        }

        // 6g. Mint PNTs for test users
        if (xPNTsToken(pntsAddr).balanceOf(anni) < 500 ether) {
            xPNTsToken(pntsAddr).mint(anni, 500 ether);
            console.log("  500 PNTs Minted to Anni");
        } else {
            console.log("  Anni PNTs (skip - sufficient balance)");
        }

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
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        vm.serializeAddress(jsonObj, "simpleAccountFactory", simpleAccountFactory);
        vm.serializeAddress(jsonObj, "pnts", pntsAddr);
        // ERC-8004 agent registry addresses (official CREATE2 constants per chain).
        // identity + reputation are wired into SuperPaymaster; validation is recorded for future use.
        vm.serializeAddress(jsonObj, "agentIdentityRegistry", SuperPaymaster(payable(address(superPaymaster))).agentIdentityRegistry());
        vm.serializeAddress(jsonObj, "agentReputationRegistry", SuperPaymaster(payable(address(superPaymaster))).agentReputationRegistry());
        vm.serializeAddress(jsonObj, "agentValidationRegistry", erc8004Validation);
        // UUPS implementation addresses — required for future upgrades via upgradeToAndCall()
        // and for audit-core's ERC-1967 implementation-slot verification.
        vm.serializeAddress(jsonObj, "spImpl", spImplAddr);
        vm.serializeAddress(jsonObj, "registryImpl", registryImplAddr);
        // MicroPaymentChannel — deployed in Step 4
        vm.serializeAddress(jsonObj, "microPaymentChannel", address(microPaymentCh));
        vm.serializeString(jsonObj, "srcHash", vm.envOr("SRC_HASH", string("")));
        vm.serializeString(jsonObj, "updateTime", vm.envOr("DEPLOY_TIME", string("N/A")));
        vm.serializeAddress(jsonObj, "priceFeed", priceFeedAddr);
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Live Phase 1 Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}
