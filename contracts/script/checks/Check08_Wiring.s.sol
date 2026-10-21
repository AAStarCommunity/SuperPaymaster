// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/tokens/xPNTsFactory.sol";
import "../../src/tokens/xPNTsToken.sol";
import "../../src/tokens/MySBT.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/core/Registry.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SPReleaseVersion } from "../v3/SPReleaseVersion.sol";

interface IFactoryV2Check {
    function SUPERPAYMASTER() external view returns (address);
    function REGISTRY() external view returns (address);
    function implementation() external view returns (address);
    function defaultTierSource() external view returns (address);
}

interface ITemplateV2Check {
    function PROTOCOL_REGISTRY() external view returns (address);
    function BALANCE_MODE_VERSION() external view returns (uint16);
}

interface IAOARegCheck {
    function sealed_() external view returns (bool);
    function isApprovedSP(address sp) external view returns (bool);
    function isApprovedImpl(uint8 kind, address target) external view returns (bool);
}

/**
 * @title Check08_Wiring
 * @notice Interconnection audit script
 * @dev Verifies that all core components have correct bidirectional trust established
 */
contract Check08_Wiring is Script {
    function run() external view {
        // Get config file path from env
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        
        string memory json = vm.readFile(path);
        
        address registry = stdJson.readAddress(json, ".registry");
        address superPaymaster = stdJson.readAddress(json, ".superPaymaster");
        address aPNTs = stdJson.readAddress(json, ".aPNTs");
        address sbt = stdJson.readAddress(json, ".sbt");
        address staking = stdJson.readAddress(json, ".staking");
        address xpntsFactory = stdJson.readAddress(json, ".xPNTsFactory");

        console.log("Auditing Wiring Matrix for:", configFile);

        // 1. Security Wiring Check (Deep Diagnostic)
        require(GTokenStaking(staking).REGISTRY() == registry, "Check08: Staking -> Registry Failed");
        require(MySBT(sbt).REGISTRY() == registry, "Check08: MySBT -> Registry Failed");
        
        address actualSPInToken = xPNTsToken(aPNTs).SUPERPAYMASTER_ADDRESS();
        address actualFactoryInToken = xPNTsToken(aPNTs).FACTORY();
        address actualOwnerInToken = xPNTsToken(aPNTs).communityOwner();

        console.log("  aPNTs Context Audit:");
        console.log("    - Factory:         ", actualFactoryInToken);
        console.log("    - Community Owner: ", actualOwnerInToken);
        console.log("    - SuperPaymaster: ", actualSPInToken);

        if (actualSPInToken != superPaymaster) {
            console.log("Error: aPNTs SP Mismatch!");
            console.log("  Expected: ", superPaymaster);
            console.log("  Actual:   ", actualSPInToken);
        }
        
        require(actualSPInToken == superPaymaster, "Check08: aPNTs -> SP Failed");
        require(actualFactoryInToken != address(0), "Check08: aPNTs Factory not initialized");
        require(actualOwnerInToken != address(0), "Check08: aPNTs Owner not initialized");

        // 2. Risk Control Wiring Check
        require(Registry(registry).SUPER_PAYMASTER() == superPaymaster, "Check08: Registry -> SP Failed");
        require(address(Registry(registry).GTOKEN_STAKING()) == staking, "Check08: Registry -> Staking Failed");
        require(address(Registry(registry).MYSBT()) == sbt, "Check08: Registry -> MySBT Failed");
        
        // 3. Immutable Bindings Check
        require(address(SuperPaymaster(superPaymaster).REGISTRY()) == registry, "Check08: SP -> Registry Immutable Failed");

        // 4. Business Callback Check
        // The 3.x factory is still wired to SP (it deploys the protocol aPNTs and backs
        // GTokenAuthorization / X402Facilitator), so its two bindings are still required.
        require(xPNTsFactory(xpntsFactory).SUPERPAYMASTER() == superPaymaster, "Check08: Factory -> SP Failed");
        require(xPNTsFactory(xpntsFactory).REGISTRY() == registry, "Check08: Factory -> Registry Failed");
        // SP 5.5.0 binds operators to tokens from xPNTsFactoryV2 (runbook step 6), so on 5.5.0
        // SP.xpntsFactory must be the v2 factory; before 5.5.0 it is the 3.x factory.
        address spFactory = SuperPaymaster(payable(superPaymaster)).xpntsFactory();
        if (keccak256(bytes(SuperPaymaster(payable(superPaymaster)).version())) == keccak256(bytes(SPReleaseVersion.SP))) {
            require(vm.keyExistsJson(json, ".xPNTsFactoryV2"), "Check08: SP is 5.5.0 but config has no xPNTsFactoryV2");
            address factoryV2 = stdJson.readAddress(json, ".xPNTsFactoryV2");
            require(spFactory == factoryV2, "Check08: SP -> FactoryV2 Failed");
            require(IFactoryV2Check(factoryV2).SUPERPAYMASTER() == superPaymaster, "Check08: FactoryV2 -> SP Failed");
            require(IFactoryV2Check(factoryV2).REGISTRY() == registry, "Check08: FactoryV2 -> Registry Failed");
            address impl = IFactoryV2Check(factoryV2).implementation();
            require(IFactoryV2Check(factoryV2).defaultTierSource() != address(0), "Check08: FactoryV2 default tier source unset");
            IAOARegCheck aoa = IAOARegCheck(ITemplateV2Check(impl).PROTOCOL_REGISTRY());
            require(aoa.sealed_(), "Check08: AOAProtocolRegistry not sealed");
            require(aoa.isApprovedSP(superPaymaster), "Check08: SP not approved in AOAProtocolRegistry");
            require(
                aoa.isApprovedImpl(2, IFactoryV2Check(factoryV2).defaultTierSource()),
                "Check08: default tier source not approved in AOAProtocolRegistry"
            );
            require(ITemplateV2Check(impl).BALANCE_MODE_VERSION() == 1, "Check08: v2 template BALANCE_MODE_VERSION");
            console.log("  SP 5.5.0 -> xPNTsFactoryV2:", factoryV2);
        } else {
            require(spFactory == xpntsFactory, "Check08: SP -> Factory Failed");
        }

        // 5. BLS Infrastructure Check
        // P0-1: standalone BLSValidator was deleted; only the aggregator is wired now.
        address blsAggregator = stdJson.readAddress(json, ".blsAggregator");

        // Note: Registry uses camelCase getters for these public variables
        require(Registry(registry).blsAggregator() == blsAggregator, "Check08: Registry -> BLS Aggregator Failed");

        // 6. Agent Registry Check (non-blocking warning — required for Agent Sponsorship)
        address agentIdentity = SuperPaymaster(payable(superPaymaster)).agentIdentityRegistry();
        address agentReputation = SuperPaymaster(payable(superPaymaster)).agentReputationRegistry();
        if (agentIdentity == address(0) || agentReputation == address(0)) {
            console.log("WARN Check08: agentRegistries not set - Agent Sponsorship disabled");
            console.log("  Fix: cast send $SP 'setAgentRegistries(address,address)' $IDENTITY $REPUTATION");
            console.log("  (Deploy AgentRegistry via AirAccount team first, then wire here)");
        } else {
            console.log("  agentIdentityRegistry: ", agentIdentity);
            console.log("  agentReputationRegistry:", agentReputation);
        }

        console.log("All Core & BLS Wiring Paths Verified Successfully!");
    }
}
