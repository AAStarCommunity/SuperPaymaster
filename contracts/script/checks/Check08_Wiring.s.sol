// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/tokens/xPNTsFactory.sol";
import "../../src/tokens/xPNTsToken.sol";
import "../../src/tokens/MySBT.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/core/Registry.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

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
        
        // 3. Immutable Bindings Check
        require(address(SuperPaymaster(superPaymaster).REGISTRY()) == registry, "Check08: SP -> Registry Immutable Failed");

        // 4. Business Callback Check
        require(xPNTsFactory(xpntsFactory).SUPERPAYMASTER() == superPaymaster, "Check08: Factory -> SP Failed");
        require(SuperPaymaster(payable(superPaymaster)).xpntsFactory() == xpntsFactory, "Check08: SP -> Factory Failed");

        // 5. BLS Infrastructure Check
        address blsAggregator = stdJson.readAddress(json, ".blsAggregator");
        address blsValidator = stdJson.readAddress(json, ".blsValidator");
        
        // Note: Registry uses camelCase getters for these public variables
        require(Registry(registry).blsAggregator() == blsAggregator, "Check08: Registry -> BLS Aggregator Failed");
        require(address(Registry(registry).blsValidator()) == blsValidator, "Check08: Registry -> BLS Validator Failed");

        console.log("All Core & BLS Wiring Paths Verified Successfully!");
    }
}
