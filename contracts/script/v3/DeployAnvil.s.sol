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
// this file's scope. Once V54Bootstrap (X402Facilitator / PolicyRegistry) is also
// in the closure, a plain import collides with MicroPaymentChannel's EIP712
// ("Identifier already declared"). Mirrors DeployLive.s.sol.
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
// Named import (same EIP712-collision reason as GTokenAuthorization above).
import {MicroPaymentChannel} from "src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol";
// MockBLSValidator removed in P0-1 — Registry verifies via BLSAggregator only.

// Agent Registry Mocks (Anvil/local only — production uses AgentRegistry deployed by AirAccount)
import "src/mocks/MockAgentIdentityRegistry.sol";
import "src/mocks/MockAgentReputationRegistry.sol";

// External Interfaces
import {EntryPoint} from "@account-abstraction-v7/core/EntryPoint.sol";
import {SimpleAccountFactory} from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

// v5.4 god-split + DVT policy (X402Facilitator + TimelockController + PolicyRegistry + wiring)
import {V54Bootstrap} from "./V54Bootstrap.sol";

contract MockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

/**
 * @title DeployAnvil
 * @notice Standardized Local Deployment Script with Atomic Initialization
 */
contract DeployAnvil is V54Bootstrap {
    using Clones for address;
    uint256 deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;

    // v5.4 god-split addresses (deployed in Step 10, written to config)
    address x402FacilitatorAddr;
    address policyRegistryAddr;
    address timelockControllerAddr;

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
    SimpleAccountFactory accountFactory;
    MockAgentIdentityRegistry mockAgentIdentity;
    MockAgentReputationRegistry mockAgentReputation;
    MicroPaymentChannel microPaymentCh;

    function setUp() public {
        deployer = vm.addr(deployerPK); 
    }

    function run() external {
        vm.warp(86400); 
        vm.startBroadcast(deployerPK);
        
        priceFeedAddr = address(new MockPriceFeed());
        entryPointAddr = address(new EntryPoint());

        console.log("=== Step 1: Deploy Foundation (Scheme B) ===");

        // Deploy Registry as UUPS proxy first (no deps)
        Registry regImpl = new Registry();
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

        console.log("=== Step 2: (xPNTsFactory already deployed in Step 1) ===");

        console.log("=== Step 3: Pre-register Deployer as COMMUNITY ===");
        // CRITICAL: Must register COMMUNITY role BEFORE deploying xPNTs via factory
        gtoken.mint(deployer, 2000 ether);
        gtoken.approve(address(staking), 2000 ether);
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            stakeAmount: 30 ether
        });
        registry.registerRole(ROLE_COMMUNITY, deployer, abi.encode(aaStarData));
        
        console.log("=== Step 4: Deploy aPNTs via Factory ===");
        // Use factory to deploy aPNTs (ensures factory binding consistency)
        xpntsFactory.deployxPNTsToken(
            "AAStar PNTs",
            "aPNTs", 
            "GlobalHub",
            "local.eth",
            1e18,
            address(0) // No AOA paymaster
        );
        apnts = xPNTsToken(xpntsFactory.getTokenAddress(deployer));
        
        // CRITICAL: Mint initial supply to Deployer so he can fund others (Anni) and himself
        apnts.mint(deployer, 2000 ether);

        console.log("=== Step 5: Deploy Core (UUPS Proxy) ===");
        SuperPaymaster spImpl = new SuperPaymaster(IEntryPoint(entryPointAddr), registry, priceFeedAddr);
        bytes memory spInit = abi.encodeCall(SuperPaymaster.initialize, (deployer, address(apnts), deployer, 4200));
        ERC1967Proxy spProxy = new ERC1967Proxy(address(spImpl), spInit);
        superPaymaster = SuperPaymaster(payable(address(spProxy)));

        console.log("=== Step 6: Deploy Other Modules ===");
        repSystem = new ReputationSystem(address(registry));
        // DVTValidator must be deployed before BLSAggregator (constructor rejects address(0))
        dvt = new DVTValidator(address(registry));
        aggregator = new BLSAggregator(address(registry), address(superPaymaster), address(dvt));
        pmFactory = new PaymasterFactory();
        pmV4Impl = new Paymaster(address(registry));
        microPaymentCh = new MicroPaymentChannel(deployer);
        accountFactory = new SimpleAccountFactory(IEntryPoint(entryPointAddr));
        // Agent Registries (mock for local dev; production uses ERC-8004 official contracts on live networks)
        mockAgentIdentity = new MockAgentIdentityRegistry();
        mockAgentReputation = new MockAgentReputationRegistry();

        console.log("=== Step 7: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 8: Register Deployer as SuperPaymaster ===");
        registry.registerRole(ROLE_PAYMASTER_SUPER, deployer, "");
        superPaymaster.configureOperator(address(apnts), deployer);
        
        apnts.mint(deployer, 1000 ether);        // Initial Refill (SuperPaymaster is already auto-approved in xPNTsToken via setSuperPaymasterAddress)
        superPaymaster.depositFor(deployer, 1000 ether);

        // 2. 初始化 DemoCommunity (Anni)
        // Use PRIVATE_KEY_ANNI env if set; fall back to Anvil account #1 default.
        // Honors env override so .env.anvil + DeployAnvil agree on which key is "Anni",
        // avoiding the RoleNotGranted(COMMUNITY) failure when TestAccountPrepare reads
        // a different key than what DeployAnvil registered.
        uint256 anniPK = vm.envOr(
            "PRIVATE_KEY_ANNI",
            uint256(0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d)
        );
        address anni = vm.addr(anniPK);
        Registry.CommunityRoleData memory demoData = Registry.CommunityRoleData({
            name: "DemoCommunity",
            ensName: "demo.eth",
            stakeAmount: 30 ether
        });

        // Jason 代付 Anni 的质押并注册社区
        registry.safeMintForRole(ROLE_COMMUNITY, anni, abi.encode(demoData));
        
        // 关键：Anni 在 Anvil 下也需要点钱进行 Paymaster 注册
        gtoken.mint(anni, 100 ether);
        registry.safeMintForRole(ROLE_PAYMASTER_SUPER, anni, "");
        
        // 补全 DemoCommunity 的 Operator 配置
        // 为 DemoCommunity 注入资金
        // 1. Anni 需要 aPNTs 来质押到 SuperPaymaster (Protocol Requirement)
        vm.stopBroadcast();
        vm.startBroadcast(deployerPK);
        apnts.transfer(anni, 1000 ether); // Deployer funds Anni with aPNTs
        vm.stopBroadcast();
        
        vm.startBroadcast(anniPK);
        address dPNTs = xpntsFactory.deployxPNTsToken("DemoPoints", "dPNTs", "DemoCommunity", "demo.eth", 1e18, address(0));
        superPaymaster.configureOperator(dPNTs, anni);
        
        // 2. Anni 存入 aPNTs -> SuperPaymaster
        apnts.approve(address(superPaymaster), 1000 ether);
        superPaymaster.deposit(1000 ether);

        // 3. Anni 为她的用户准备 dPNTs (可选，如果她想给自己发一点)
        xPNTsToken(dPNTs).mint(anni, 500 ether);
        vm.stopBroadcast();

        // 切换回 Deployer 继续后续操作
        vm.startBroadcast(deployerPK);
        
        console.log("=== Step 9: Final Verification ===");
        _verifyWiring();

        console.log("=== Step 10: v5.4 god-split (X402Facilitator + Timelock + PolicyRegistry) ===");
        // Deployer is governor + guardian on anvil (envOr defaults). Exercises the
        // god-split x402 + DVT policy stack locally so run_full_regression / CI cover it.
        {
            (address governor, address guardian) = _resolveGovernance(deployer);
            V54Addresses memory v54 = _deployV54Contracts(
                address(registry),
                address(superPaymaster),
                address(xpntsFactory),
                governor,
                guardian,
                address(0) // fresh timelock
            );
            x402FacilitatorAddr    = v54.facilitator;
            policyRegistryAddr     = v54.policyRegistry;
            timelockControllerAddr = v54.timelock;
            _wireFacilitator(address(xpntsFactory), x402FacilitatorAddr, deployer);
        }

        vm.stopBroadcast();
        _generateConfig();
    }

    function _executeWiring() internal {
        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(repSystem), true);
        registry.setBLSAggregator(address(aggregator));
        aggregator.setDVTValidator(address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        
        // CRITICAL: Update factory's SuperPaymaster address
        xpntsFactory.setSuperPaymasterAddress(address(superPaymaster));

        // Authorize BLSAggregator as slasher for Tier 2 (GToken governance slash)
        staking.setAuthorizedSlasher(address(aggregator), true);
        
        // Configure auto-approval for aPNTs (already deployed via factory)
        apnts.setSuperPaymasterAddress(address(superPaymaster));
        
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        superPaymaster.updatePrice();
        // HIGH-2: wire BLS_AGGREGATOR into SuperPaymaster so executeSlashWithBLS is callable.
        // Anvil: queue + warp past 24h timelock + apply in one script run.
        superPaymaster.queueBLSAggregator(address(aggregator));
        vm.warp(block.timestamp + 24 hours + 1);
        superPaymaster.applyBLSAggregator();
        // Wire Agent Registries (enables Agent Sponsorship path in isEligibleForSponsorship)
        superPaymaster.setAgentRegistries(address(mockAgentIdentity), address(mockAgentReputation));
    }

    function _verifyWiring() internal view {
        require(address(staking.GTOKEN()) == address(gtoken), "Staking GTOKEN Wiring Failed");
        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "Registry SP Wiring Failed");
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "aPNTs Firewall Failed");
        require(address(superPaymaster.REGISTRY()) == address(registry), "Paymaster Registry Immutable Failed");
        require(superPaymaster.BLS_AGGREGATOR() == address(aggregator), "SP BLS_AGGREGATOR Wiring Failed");
        console.log("All Wiring Assertions Passed!");
    }

    function _generateConfig() internal {
        string memory finalPath = string.concat(vm.projectRoot(), "/deployments/config.anvil.json");
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
        vm.serializeAddress(jsonObj, "simpleAccountFactory", address(accountFactory));
        vm.serializeAddress(jsonObj, "agentIdentityRegistry", address(mockAgentIdentity));
        vm.serializeAddress(jsonObj, "agentReputationRegistry", address(mockAgentReputation));
        vm.serializeAddress(jsonObj, "agentValidationRegistry", address(0)); // no mock for Anvil; ERC-8004 validation is TEE-based
        vm.serializeAddress(jsonObj, "microPaymentChannel", address(microPaymentCh));
        // v5.4 god-split contracts — deployed in Step 10
        vm.serializeAddress(jsonObj, "x402Facilitator", x402FacilitatorAddr);
        vm.serializeAddress(jsonObj, "policyRegistry", policyRegistryAddr);
        vm.serializeAddress(jsonObj, "timelockController", timelockControllerAddr);
        vm.serializeString(jsonObj, "srcHash", vm.envOr("SRC_HASH", string("")));
        vm.serializeString(jsonObj, "updateTime", vm.envOr("DEPLOY_TIME", string("N/A")));
        vm.serializeAddress(jsonObj, "priceFeed", priceFeedAddr);
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Anvil Deployment Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}