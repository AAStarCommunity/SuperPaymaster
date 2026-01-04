// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/tokens/xPNTsFactory.sol";
import "../../src/tokens/xPNTsToken.sol";
import "../../src/tokens/MySBT.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/core/Registry.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";

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
        
        address registry = vm.parseJsonAddress(json, ".registry");
        address superPaymaster = vm.parseJsonAddress(json, ".superPaymaster");
        address aPNTs = vm.parseJsonAddress(json, ".aPNTs");
        address sbt = vm.parseJsonAddress(json, ".sbt");
        address staking = vm.parseJsonAddress(json, ".staking");
        address xpntsFactory = vm.parseJsonAddress(json, ".xPNTsFactory");

        console.log("Auditing Wiring Matrix for:", configFile);

        // 1. Security Wiring Check
        require(GTokenStaking(staking).REGISTRY() == registry, "Check08: Staking -> Registry Failed");
        require(MySBT(sbt).REGISTRY() == registry, "Check08: MySBT -> Registry Failed");
        require(xPNTsToken(aPNTs).SUPERPAYMASTER_ADDRESS() == superPaymaster, "Check08: aPNTs -> SP Failed");

        // 2. Risk Control Wiring Check
        require(Registry(registry).SUPER_PAYMASTER() == superPaymaster, "Check08: Registry -> SP Failed");
        
        // 3. Immutable Bindings Check
        require(address(SuperPaymasterV3(superPaymaster).REGISTRY()) == registry, "Check08: SP -> Registry Immutable Failed");

        // 4. Business Callback Check
        require(MySBT(sbt).SUPER_PAYMASTER() == superPaymaster, "Check08: MySBT -> SP Callback Failed");
        require(xPNTsFactory(xpntsFactory).SUPERPAYMASTER() == superPaymaster, "Check08: Factory -> SP Failed");
        require(SuperPaymasterV3(payable(superPaymaster)).xpntsFactory() == xpntsFactory, "Check08: SP -> Factory Failed");

        // 5. BLS Infrastructure Check
        address blsAggregator = vm.parseJsonAddress(json, ".blsAggregator");
        address blsValidator = vm.parseJsonAddress(json, ".blsValidator");
        
        // Note: Registry uses camelCase getters for these public variables
        require(Registry(registry).blsAggregator() == blsAggregator, "Check08: Registry -> BLS Aggregator Failed");
        require(address(Registry(registry).blsValidator()) == blsValidator, "Check08: Registry -> BLS Validator Failed");

        console.log("All Core & BLS Wiring Paths Verified Successfully!");
    }
}
