// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/mocks/MockAgentIdentityRegistry.sol";
import "src/mocks/MockAgentReputationRegistry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

/**
 * @title DeployAgentRegistries
 * @notice Deploy mock ERC-8004 Agent Identity + Reputation registries on Sepolia,
 *         then call setAgentRegistries() on SuperPaymaster to activate Agent Sponsorship.
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/DeployAgentRegistries.s.sol:DeployAgentRegistries \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast -vvvv
 */
contract DeployAgentRegistries is Script {
    function run() external {
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.sepolia.json");
        string memory config = vm.readFile(configPath);

        address spProxy = vm.parseJsonAddress(config, ".superPaymaster");

        console.log("=== Deploy ERC-8004 Agent Registries ===");
        console.log("  SuperPaymaster Proxy:", spProxy);

        // Verify current version
        string memory version = SuperPaymaster(payable(spProxy)).version();
        console.log("  Current version:", version);

        vm.startBroadcast();

        // 1. Deploy MockAgentIdentityRegistry
        MockAgentIdentityRegistry identity = new MockAgentIdentityRegistry();
        console.log("  AgentIdentityRegistry:", address(identity));

        // 2. Deploy MockAgentReputationRegistry
        MockAgentReputationRegistry reputation = new MockAgentReputationRegistry();
        console.log("  AgentReputationRegistry:", address(reputation));

        // 3. Activate Agent Sponsorship on SuperPaymaster
        SuperPaymaster sp = SuperPaymaster(payable(spProxy));
        sp.setAgentRegistries(address(identity), address(reputation));
        console.log("  setAgentRegistries() called");

        // 4. Verify activation
        address storedIdentity = sp.agentIdentityRegistry();
        address storedReputation = sp.agentReputationRegistry();
        console.log("  Stored identity registry:", storedIdentity);
        console.log("  Stored reputation registry:", storedReputation);

        vm.stopBroadcast();

        require(storedIdentity == address(identity), "Identity registry mismatch");
        require(storedReputation == address(reputation), "Reputation registry mismatch");

        console.log("=== Agent Registries deployed and activated! ===");
        console.log("  Add to config.sepolia.json:");
        console.log("    agentIdentityRegistry:", address(identity));
        console.log("    agentReputationRegistry:", address(reputation));
    }
}
