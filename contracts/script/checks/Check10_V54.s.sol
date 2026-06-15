// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/superpaymaster/v3/X402Facilitator.sol";
import "../../src/core/PolicyRegistry.sol";

/**
 * @title Check10_V54
 * @notice Post-deploy verification of the v5.4 god-split + DVT policy stack.
 * @dev Asserts the canonical `./deploy-core <env>` path produced a COMPLETE v5.4
 *      deployment (not the partial one the pre-fix routed scripts produced):
 *        1. X402Facilitator deployed (bytecode + REGISTRY wired to the proxy)
 *        2. PolicyRegistry deployed and authorizes SuperPaymaster as a consumer
 *        3. PolicyRegistry.timelock() == config.timelockController (governance wired)
 *      Run by audit-core Dimension A alongside Check01–Check09 / VerifyV3_1_1.
 */
contract Check10_V54 is Script {
    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        string memory json = vm.readFile(path);

        address registry        = stdJson.readAddress(json, ".registry");
        address superPaymaster   = stdJson.readAddress(json, ".superPaymaster");
        address facilitator      = stdJson.readAddress(json, ".x402Facilitator");
        address policyRegistry   = stdJson.readAddress(json, ".policyRegistry");
        address timelock         = stdJson.readAddress(json, ".timelockController");

        console.log("Auditing v5.4 god-split stack for:", configFile);
        console.log("  x402Facilitator:   ", facilitator);
        console.log("  policyRegistry:    ", policyRegistry);
        console.log("  timelockController:", timelock);

        // 1. X402Facilitator deployed + wired to the live Registry proxy.
        require(facilitator != address(0), "Check10: x402Facilitator missing from config (incomplete v5.4 deploy)");
        require(facilitator.code.length > 0, "Check10: x402Facilitator has no bytecode");
        require(
            address(X402Facilitator(facilitator).REGISTRY()) == registry,
            "Check10: X402Facilitator.REGISTRY != registry proxy"
        );
        console.log("  X402Facilitator version:", X402Facilitator(facilitator).version());

        // 2. PolicyRegistry deployed + authorizes SuperPaymaster as consumer.
        require(policyRegistry != address(0), "Check10: policyRegistry missing from config (incomplete v5.4 deploy)");
        require(policyRegistry.code.length > 0, "Check10: policyRegistry has no bytecode");
        require(
            PolicyRegistry(policyRegistry).isAuthorizedConsumer(superPaymaster),
            "Check10: SuperPaymaster not authorized as PolicyRegistry consumer"
        );
        console.log("  PolicyRegistry version:", PolicyRegistry(policyRegistry).version());

        // 3. Governance wiring: PolicyRegistry.timelock() matches the deployed timelock.
        require(timelock != address(0), "Check10: timelockController missing from config (incomplete v5.4 deploy)");
        require(timelock.code.length > 0, "Check10: timelockController has no bytecode");
        require(
            PolicyRegistry(policyRegistry).timelock() == timelock,
            "Check10: PolicyRegistry.timelock != config.timelockController"
        );

        console.log("v5.4 god-split stack verified: X402Facilitator + PolicyRegistry(SP consumer) + Timelock wired!");
    }
}
