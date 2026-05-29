// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeLive
 * @notice Generic version-agnostic UUPS upgrade for SuperPaymaster + Registry.
 *
 * Policy (from v5.3.3-beta onwards):
 *   Any change to SuperPaymaster or Registry on a live network MUST go through
 *   this script (not DeployLive). DeployLive deploys new proxies and loses all
 *   state (communities, stake, SBT, etc.).
 *
 * What this script does:
 *   1. Reads existing proxy addresses from config.<env>.json
 *   2. Deploys a new Registry implementation (no constructor args)
 *   3. Deploys a new SuperPaymaster implementation (entryPoint, registry, priceFeed)
 *   4. Calls upgradeToAndCall() on each proxy  → state preserved, logic updated
 *   5. Patches config: registryImpl, spImpl, srcHash, updateTime
 *
 * Scope: SP + Registry only (UUPS contracts). Other contracts (GToken, Staking,
 * MySBT, ReputationSystem, etc.) are NOT touched; use dedicated scripts for those.
 *
 * Idempotent: safe to re-run if a previous run was interrupted.
 *
 * Run:
 *   source .env.sepolia
 *   forge script contracts/script/v3/UpgradeLive.s.sol:UpgradeLive \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast --slow -vvvv
 *
 * Or via deploy-core (auto-selected when config already has proxy addresses):
 *   ./deploy-core sepolia
 *   ./deploy-core sepolia --force     # bypass hash check, still UUPS (not fresh)
 */
contract UpgradeLive is Script {

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address spProxy       = vm.parseJsonAddress(config, ".superPaymaster");
        address entryPoint    = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed     = vm.parseJsonAddress(config, ".priceFeed");
        address mcProxy       = vm.parseJsonAddress(config, ".microPaymentChannel");
        address deployer      = msg.sender;

        require(registryProxy != address(0), "UpgradeLive: registry proxy not in config");
        require(spProxy       != address(0), "UpgradeLive: superPaymaster proxy not in config");
        require(entryPoint    != address(0), "UpgradeLive: entryPoint not in config");
        require(priceFeed     != address(0), "UpgradeLive: priceFeed not in config");

        console.log("=== UUPS Upgrade: SuperPaymaster + Registry ===");
        console.log("  Network:        ", network);
        console.log("  Registry proxy: ", registryProxy);
        console.log("  SP proxy:       ", spProxy);
        console.log("");

        string memory regBefore = Registry(registryProxy).version();
        string memory spBefore  = SuperPaymaster(payable(spProxy)).version();
        console.log("  Registry before:", regBefore);
        console.log("  SP before:      ", spBefore);

        vm.startBroadcast();

        // --- Deploy new implementations ---
        Registry newRegImpl = new Registry();
        SuperPaymaster newSPImpl = new SuperPaymaster(
            IEntryPoint(entryPoint),
            IRegistry(registryProxy),
            priceFeed
        );

        console.log("  New Registry impl:", address(newRegImpl));
        console.log("  New SP impl:      ", address(newSPImpl));

        // --- Upgrade proxies (state preserved) ---
        UUPSUpgradeable(registryProxy).upgradeToAndCall(address(newRegImpl), "");
        console.log("  Registry upgraded");

        UUPSUpgradeable(spProxy).upgradeToAndCall(address(newSPImpl), "");
        console.log("  SuperPaymaster upgraded");

        // --- Deploy MicroPaymentChannel if not yet deployed (idempotent) ---
        if (mcProxy == address(0)) {
            MicroPaymentChannel newMC = new MicroPaymentChannel(deployer);
            mcProxy = address(newMC);
            console.log("  MicroPaymentChannel deployed:", mcProxy);
        } else {
            console.log("  MicroPaymentChannel (existing):", mcProxy);
        }

        vm.stopBroadcast();

        // --- Verify ---
        string memory regAfter = Registry(registryProxy).version();
        string memory spAfter  = SuperPaymaster(payable(spProxy)).version();
        console.log("  Registry after: ", regAfter);
        console.log("  SP after:       ", spAfter);

        // --- Patch config (keep all existing keys, only update changed fields) ---
        string memory srcHash    = vm.envOr("SRC_HASH",    vm.parseJsonString(config, ".srcHash"));
        string memory updateTime = vm.envOr("DEPLOY_TIME", string("N/A"));

        vm.writeJson(vm.toString(address(newRegImpl)), configPath, ".registryImpl");
        vm.writeJson(vm.toString(address(newSPImpl)),  configPath, ".spImpl");
        vm.writeJson(vm.toString(mcProxy),             configPath, ".microPaymentChannel");
        vm.writeJson(srcHash,                          configPath, ".srcHash");
        vm.writeJson(updateTime,                       configPath, ".updateTime");

        _ensureTrailingNewline(configPath);

        console.log("");
        console.log("  Config patched:", configPath);
        console.log("    registryImpl        =", address(newRegImpl));
        console.log("    spImpl              =", address(newSPImpl));
        console.log("    microPaymentChannel =", mcProxy);
        console.log("    srcHash             =", srcHash);
        console.log("=== Upgrade successful! ===");
    }

    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
