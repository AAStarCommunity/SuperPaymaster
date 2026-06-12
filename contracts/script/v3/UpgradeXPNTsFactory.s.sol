// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

/**
 * @title UpgradeXPNTsFactory
 * @notice Redeploys xPNTsFactory (EIP-1167 clones cannot be upgraded in-place)
 *         and wires the new factory into SuperPaymaster.
 *
 * Why needed: xPNTsToken H-2 fix (transferFrom emergencyDisabled bypass) lives in
 * the clone implementation. Since EIP-1167 clones have the impl address baked into
 * their bytecode, all new community tokens must be created from the new factory.
 * Existing tokens keep the old bytecode; they should be re-created via prepare-test.
 *
 * What this script does:
 *   1. Deploys a new xPNTsFactory (new impl = H-2-fixed xPNTsToken)
 *   2. Calls SP.setXPNTsFactory(newFactory)
 *   3. Patches config.sepolia.json: xPNTsFactory, previousXPNTsFactory
 *
 * After running this, run: ./prepare-test sepolia
 * That will re-create community tokens via the new factory and reconfigure operators.
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeXPNTsFactory.s.sol:UpgradeXPNTsFactory \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --slow -vvv
 */
contract UpgradeXPNTsFactory is Script {

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address spProxy          = vm.parseJsonAddress(config, ".superPaymaster");
        address registryProxy    = vm.parseJsonAddress(config, ".registry");
        address oldFactory       = vm.parseJsonAddress(config, ".xPNTsFactory");

        require(spProxy     != address(0), "SP proxy not in config");
        require(oldFactory  != address(0), "xPNTsFactory not in config");

        SuperPaymaster sp = SuperPaymaster(payable(spProxy));

        console.log("=== xPNTsFactory Upgrade (H-2 fix) ===");
        console.log("  Network:       ", network);
        console.log("  SP proxy:      ", spProxy);
        console.log("  Old factory:   ", oldFactory);
        console.log("  SP owner:      ", sp.owner());
        console.log("  Caller:        ", msg.sender);
        require(sp.owner() == msg.sender, "Caller is not SP owner");

        vm.startBroadcast();

        // Step 1: deploy new factory (constructor deploys fresh xPNTsToken implementation)
        xPNTsFactory newFactory = new xPNTsFactory(spProxy, registryProxy);
        console.log("  New factory:   ", address(newFactory));
        console.log("  New impl:      ", newFactory.implementation());

        // Step 2: wire into SuperPaymaster
        sp.setXPNTsFactory(address(newFactory));
        console.log("  SP.setXPNTsFactory done");

        vm.stopBroadcast();

        // Verify
        address wiredFactory = sp.xpntsFactory();
        require(wiredFactory == address(newFactory), "Factory not wired correctly");
        console.log("  Verified SP.xpntsFactory() ==", wiredFactory);

        // Step 3: patch config
        vm.writeJson(vm.toString(address(newFactory)),  configPath, ".xPNTsFactory");
        vm.writeJson(vm.toString(oldFactory),           configPath, ".previousXPNTsFactory");

        console.log("");
        console.log("  Config patched:", configPath);
        console.log("    xPNTsFactory         =", address(newFactory));
        console.log("    previousXPNTsFactory  =", oldFactory);
        console.log("");
        console.log("  NEXT STEP: run ./prepare-test sepolia");
        console.log("  (re-creates community tokens via new factory + reconfigures operators)");
        console.log("=== xPNTsFactory upgrade successful! ===");
    }
}
