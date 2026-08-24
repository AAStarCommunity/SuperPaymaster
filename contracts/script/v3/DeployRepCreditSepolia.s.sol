// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import {GTokenAuthorization} from "src/tokens/GTokenAuthorization.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import {GovernanceOwnerGate} from "../checks/GovernanceOwnerGate.sol";
import "src/mocks/MockAgentIdentityRegistry.sol";
import "src/mocks/MockAgentReputationRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/// @notice Minimal, fresh RepCredit stack for isolated Sepolia evidence.
/// @dev Deliberately excludes production communities, AOA PaymasterV4, x402,
///      timelock, policy, and micropayment modules: none is on the causal path
///      measured by the RepCredit paper.
contract DeployRepCreditSepolia is Script {
    uint256 private deployerPk;
    address private deployer;
    address private entryPoint;
    address private priceFeed;
    string private outputPath;

    Registry private registry;
    GTokenAuthorization private gtoken;
    GTokenStaking private staking;
    MySBT private mysbt;
    xPNTsFactory private xpntsFactory;
    xPNTsToken private apnts;
    SuperPaymaster private superPaymaster;
    ReputationSystem private reputationSystem;
    DVTValidator private dvtValidator;
    BLSAggregator private blsAggregator;
    MockAgentIdentityRegistry private agentIdentityRegistry;
    MockAgentReputationRegistry private agentReputationRegistry;

    function setUp() public {
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        entryPoint = vm.envAddress("ENTRY_POINT");
        priceFeed = vm.envAddress("ETH_USD_FEED");
        outputPath = vm.envString("REPCREDIT_SEPOLIA_CONFIG");
    }

    function run() external {
        require(block.chainid == 11155111, "RepCredit Sepolia only");
        require(entryPoint.code.length > 0, "EntryPoint has no code");
        require(priceFeed.code.length > 0, "price feed has no code");

        vm.startBroadcast(deployerPk);

        Registry registryImpl = new Registry();
        bytes memory registryInit = abi.encodeCall(Registry.initialize, (deployer, address(0), address(0)));
        registry = Registry(address(new ERC1967Proxy(address(registryImpl), registryInit)));

        xpntsFactory = new xPNTsFactory(address(0), address(registry));
        gtoken = new GTokenAuthorization(21_000_000 ether, address(xpntsFactory));
        staking = new GTokenStaking(address(gtoken), deployer, address(registry));
        mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);

        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));
        gtoken.setMySBT(address(mysbt));
        bytes32[] memory exitFeeRoles = new bytes32[](5);
        exitFeeRoles[0] = ROLE_PAYMASTER_AOA;
        exitFeeRoles[1] = ROLE_PAYMASTER_SUPER;
        exitFeeRoles[2] = ROLE_DVT;
        exitFeeRoles[3] = ROLE_ANODE;
        exitFeeRoles[4] = ROLE_KMS;
        registry.syncExitFees(exitFeeRoles);

        gtoken.mint(deployer, 5_000 ether);
        gtoken.approve(address(staking), 5_000 ether);
        Registry.CommunityRoleData memory community = Registry.CommunityRoleData({
            name: "RepCredit E2E 20260824",
            ensName: "repcredit-e2e-20260824.invalid",
            stakeAmount: 30 ether
        });
        registry.registerRole(ROLE_COMMUNITY, deployer, abi.encode(community));
        apnts = xPNTsToken(
            xpntsFactory.deployxPNTsToken(
                "RepCredit E2E aPNT", "rcAPNT", "RepCredit E2E 20260824",
                "repcredit-e2e-20260824.invalid", 1 ether, address(0)
            )
        );
        apnts.mint(deployer, 5_000 ether);

        SuperPaymaster superPaymasterImpl = new SuperPaymaster(IEntryPoint(entryPoint), registry, priceFeed);
        bytes memory spInit = abi.encodeCall(
            SuperPaymaster.initialize,
            (deployer, address(apnts), deployer, 4_200)
        );
        superPaymaster = SuperPaymaster(payable(address(new ERC1967Proxy(address(superPaymasterImpl), spInit))));

        reputationSystem = new ReputationSystem(address(registry));
        dvtValidator = new DVTValidator(address(registry));
        blsAggregator = new BLSAggregator(address(registry), address(superPaymaster), address(dvtValidator));
        agentIdentityRegistry = new MockAgentIdentityRegistry();
        agentReputationRegistry = new MockAgentReputationRegistry();

        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(reputationSystem), true);
        registry.setReputationSource(address(blsAggregator), true);
        registry.setBLSAggregator(address(blsAggregator));
        blsAggregator.setDVTValidator(address(dvtValidator));
        dvtValidator.setBLSAggregator(address(blsAggregator));
        xpntsFactory.setSuperPaymasterAddress(address(superPaymaster));
        apnts.setSuperPaymasterAddress(address(superPaymaster));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        superPaymaster.initBLSAggregator(address(blsAggregator));
        staking.setAuthorizedSlasher(address(blsAggregator), true);
        superPaymaster.setAgentRegistries(address(agentIdentityRegistry), address(agentReputationRegistry));

        // Evidence fixture: make the same operation fail before contribution,
        // and require a genuine three-signer proof to unlock it.
        registry.setCreditTier(1, 0);
        registry.setCreditPolicy(600 ether, 3_000 ether, 0, true);
        blsAggregator.setDefaultThreshold(3);
        registry.registerRole(ROLE_PAYMASTER_SUPER, deployer, "");
        superPaymaster.configureOperator(address(apnts), deployer);
        apnts.mint(deployer, 2_000 ether);
        superPaymaster.depositFor(deployer, 2_000 ether);
        superPaymaster.updatePrice();

        uint256 entryPointDeposit = vm.envOr("REPCREDIT_ENTRYPOINT_DEPOSIT_WEI", uint256(0.003 ether));
        require(entryPointDeposit > 0, "EntryPoint deposit must be positive");
        superPaymaster.deposit{value: entryPointDeposit}();

        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "Registry/SP wiring");
        require(registry.isReputationSource(address(blsAggregator)), "BLS reputation source");
        require(registry.blsAggregator() == address(blsAggregator), "Registry/BLS wiring");
        // CC-48 round-3: hard-check the build and the domain on a FRESH deploy, not just
        // the wiring. A wrong build or a Registry/aggregator pair whose separators cannot
        // agree produces a stack that looks wired and verifies nothing.
        require(
            keccak256(bytes(blsAggregator.version())) == keccak256("BLSAggregator-4.10.0"),
            "BLSAggregator is not 4.9.0"
        );
        require(blsAggregator.REGISTRY() == address(registry), "aggregator bound to another Registry");
        require(
            blsAggregator.domainSeparator() == registry.blsDomainSeparator(),
            "domain separators disagree; no proof could ever verify"
        );
        require(
            blsAggregator.domainSeparator()
                == keccak256(
                    abi.encode(
                        blsAggregator.DOMAIN_NAME(), block.chainid, address(blsAggregator), address(registry)
                    )
                ),
            "domain separator does not match the published schema"
        );
        require(blsAggregator.fraudProofVerifier() == address(0), "verifier must start dormant");
        require(blsAggregator.DVT_VALIDATOR() == address(dvtValidator), "BLS/DVT wiring");
        require(dvtValidator.BLS_AGGREGATOR() == address(blsAggregator), "DVT/BLS wiring");
        require(blsAggregator.defaultThreshold() == 3, "threshold != 3");
        require(IEntryPoint(entryPoint).balanceOf(address(superPaymaster)) == entryPointDeposit, "deposit mismatch");

        // CC-48 round-6 HIGH-1: the aggregator owner holds an immediate, unannounced
        // `emergencyDisarmFraudProofVerifier()`. This is an EXPERIMENT stack that needs a
        // hot owner to drive the RepCredit runs, so it may keep one — but only behind the
        // explicit, testnet-bound TESTNET_EOA_OWNER_ACK acknowledgement that this
        // deployment has no governance defence on that path. Set GOVERNANCE_OWNER instead
        // to hand it to the Safe.
        address gov = GovernanceOwnerGate.declaredGovernanceOwner();
        if (gov != address(0)) blsAggregator.transferOwnership(gov);

        vm.stopBroadcast();

        GovernanceOwnerGate.requireGovernanceOwner(
            address(blsAggregator), blsAggregator.owner(), "BLSAggregator"
        );
        _writeConfig(entryPointDeposit);
    }

    function _writeConfig(uint256 entryPointDeposit) private {
        string memory root = "repcredit-sepolia";
        vm.serializeUint(root, "schemaVersion", 1);
        vm.serializeString(root, "experimentLabel", "repcredit-e2e-20260824");
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "deployer", deployer);
        vm.serializeAddress(root, "entryPoint", entryPoint);
        vm.serializeAddress(root, "priceFeed", priceFeed);
        vm.serializeAddress(root, "registry", address(registry));
        vm.serializeAddress(root, "gToken", address(gtoken));
        vm.serializeAddress(root, "staking", address(staking));
        vm.serializeAddress(root, "sbt", address(mysbt));
        vm.serializeAddress(root, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(root, "aPNTs", address(apnts));
        vm.serializeAddress(root, "superPaymaster", address(superPaymaster));
        vm.serializeAddress(root, "reputationSystem", address(reputationSystem));
        vm.serializeAddress(root, "dvtValidator", address(dvtValidator));
        vm.serializeAddress(root, "blsAggregator", address(blsAggregator));
        vm.serializeAddress(root, "agentIdentityRegistry", address(agentIdentityRegistry));
        vm.serializeAddress(root, "agentReputationRegistry", address(agentReputationRegistry));
        string memory json = vm.serializeUint(root, "entryPointDepositWei", entryPointDeposit);
        vm.writeJson(json, outputPath);
        console.log("RepCredit Sepolia deployment written to", outputPath);
    }
}
