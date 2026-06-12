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
 * @notice Selective UUPS upgrade for SuperPaymaster and/or Registry.
 *
 * Policy (from v5.3.3-beta onwards):
 *   Any change to SuperPaymaster or Registry on a live network MUST go through
 *   this script (not DeployLive). DeployLive deploys new proxies and loses all
 *   state (communities, stake, SBT, etc.).
 *
 * Selective upgrade logic:
 *   Each contract is only upgraded when its compiled bytecode actually differs
 *   from what is currently deployed. The script reads each proxy's current
 *   implementation address via the ERC-1967 storage slot, deploys the new
 *   implementation, and compares codehashes. If they match the proxy is left
 *   untouched and a "skipped -- already up to date" message is logged.
 *
 * What this script does:
 *   1. Reads existing proxy addresses from config.<env>.json
 *   2. Reads current impl addresses from ERC-1967 slots (no RPC call needed)
 *   3. Deploys new Registry and SuperPaymaster implementations
 *   4. For each contract: calls upgradeToAndCall() ONLY if codehash differs
 *   5. Patches config for any contract that was actually upgraded
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

    // ERC-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _currentImpl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address spProxy       = vm.parseJsonAddress(config, ".superPaymaster");
        address entryPoint    = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed     = vm.parseJsonAddress(config, ".priceFeed");
        address mcProxy;
        try vm.parseJsonAddress(config, ".microPaymentChannel") returns (address mc) {
            mcProxy = mc;
        } catch {
            mcProxy = address(0);
        }
        address deployer = msg.sender;

        require(registryProxy != address(0), "UpgradeLive: registry proxy not in config");
        require(spProxy       != address(0), "UpgradeLive: superPaymaster proxy not in config");
        require(entryPoint    != address(0), "UpgradeLive: entryPoint not in config");
        require(priceFeed     != address(0), "UpgradeLive: priceFeed not in config");

        // --- Read current impl addresses before any broadcast ---
        address curRegImpl = _currentImpl(registryProxy);
        address curSPImpl  = _currentImpl(spProxy);

        console.log("=== UUPS Selective Upgrade: SuperPaymaster + Registry ===");
        console.log("  Network:             ", network);
        console.log("  Registry proxy:      ", registryProxy);
        console.log("  Registry current impl:", curRegImpl);
        console.log("  SP proxy:            ", spProxy);
        console.log("  SP current impl:     ", curSPImpl);
        console.log("  Registry version:    ", Registry(registryProxy).version());
        console.log("  SP version:          ", SuperPaymaster(payable(spProxy)).version());
        console.log("");

        vm.startBroadcast();

        // --- Deploy new implementations (always compiled fresh) ---
        Registry newRegImpl = new Registry();
        SuperPaymaster newSPImpl = new SuperPaymaster(
            IEntryPoint(entryPoint),
            IRegistry(registryProxy),
            priceFeed
        );

        console.log("  New Registry impl:   ", address(newRegImpl));
        console.log("  New SP impl:         ", address(newSPImpl));

        // --- Selective upgrade: only call upgradeToAndCall if bytecode changed ---
        bool regUpgraded;
        bool spUpgraded;

        if (curRegImpl.codehash != address(newRegImpl).codehash) {
            UUPSUpgradeable(registryProxy).upgradeToAndCall(address(newRegImpl), "");
            regUpgraded = true;
            console.log("  Registry: upgraded -- codehash changed");
        } else {
            console.log("  Registry: skipped -- bytecode unchanged, proxy already up to date");
        }

        if (curSPImpl.codehash != address(newSPImpl).codehash) {
            UUPSUpgradeable(spProxy).upgradeToAndCall(address(newSPImpl), "");
            spUpgraded = true;
            console.log("  SuperPaymaster: upgraded -- codehash changed");
        } else {
            console.log("  SuperPaymaster: skipped -- bytecode unchanged, proxy already up to date");
        }

        // --- Deploy MicroPaymentChannel if not yet deployed (idempotent) ---
        if (mcProxy == address(0)) {
            MicroPaymentChannel newMC = new MicroPaymentChannel(deployer);
            mcProxy = address(newMC);
            console.log("  MicroPaymentChannel deployed:", mcProxy);
        } else {
            console.log("  MicroPaymentChannel (existing):", mcProxy);
        }

        vm.stopBroadcast();

        // --- Post-upgrade verification ---
        console.log("  Registry version after: ", Registry(registryProxy).version());
        console.log("  SP version after:       ", SuperPaymaster(payable(spProxy)).version());

        if (!regUpgraded && !spUpgraded) {
            console.log("");
            console.log("  Nothing to upgrade -- both contracts are already at the latest bytecode.");
            console.log("  Config NOT patched (no changes).");
            return;
        }

        // --- Patch config only for upgraded contracts ---
        string memory srcHash    = vm.envOr("SRC_HASH",    vm.parseJsonString(config, ".srcHash"));
        string memory updateTime = vm.envOr("DEPLOY_TIME", string("N/A"));

        if (regUpgraded) vm.writeJson(vm.toString(address(newRegImpl)), configPath, ".registryImpl");
        if (spUpgraded)  vm.writeJson(vm.toString(address(newSPImpl)),  configPath, ".spImpl");
        vm.writeJson(vm.toString(mcProxy), configPath, ".microPaymentChannel");
        vm.writeJson(srcHash,              configPath, ".srcHash");
        vm.writeJson(updateTime,           configPath, ".updateTime");

        _ensureTrailingNewline(configPath);

        console.log("");
        console.log("  Config patched:", configPath);
        if (regUpgraded) console.log("    registryImpl        =", address(newRegImpl));
        if (spUpgraded)  console.log("    spImpl              =", address(newSPImpl));
        console.log("    microPaymentChannel =", mcProxy);
        console.log("=== Upgrade complete ===");
    }

    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
