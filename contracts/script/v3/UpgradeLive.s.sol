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
 *   1. BEFORE broadcast: simulate-deploy both impls locally to capture their
 *      bytecode. Compare codehashes with the current on-chain impls.
 *   2. Only broadcast impl deploys + upgradeToAndCall() for contracts whose
 *      bytecode actually changed. If nothing changed: return early, zero txns.
 *   3. foundry.toml sets bytecode_hash = "none" so codehash reflects only
 *      logic changes, not CBOR metadata.
 *
 * Cost model:
 *   - Nothing changed: 0 broadcast txns, ~0 gas
 *   - Only SP changed: 1 deploy + 1 upgradeToAndCall = ~2M gas
 *   - Both changed:    2 deploys + 2 upgrades = ~4M gas
 *
 * Scope: SP + Registry (UUPS). MicroPaymentChannel is idempotently deployed
 * if absent. Other contracts (GToken, Staking, MySBT, etc.) are NOT touched.
 *
 * Run:
 *   source .env.sepolia
 *   forge script contracts/script/v3/UpgradeLive.s.sol:UpgradeLive \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast --slow -vvvv
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

        // --- Pre-broadcast simulation: get compiled bytecodes, no gas spent ---
        // new Contract() outside startBroadcast() is a local EVM simulation.
        // The codehash equals what would be deployed on-chain (bytecode_hash="none").
        Registry       simReg = new Registry();
        SuperPaymaster simSP  = new SuperPaymaster(
            IEntryPoint(entryPoint),
            IRegistry(registryProxy),
            priceFeed
        );

        address curRegImpl = _currentImpl(registryProxy);
        address curSPImpl  = _currentImpl(spProxy);
        bool needReg = curRegImpl.codehash != address(simReg).codehash;
        bool needSP  = curSPImpl.codehash  != address(simSP).codehash;
        bool needMC  = (mcProxy == address(0));

        console.log("=== UUPS Selective Upgrade: SuperPaymaster + Registry ===");
        console.log("  Network:              ", network);
        console.log("  Registry proxy:       ", registryProxy);
        console.log("  Registry current impl:", curRegImpl);
        console.log("  SP proxy:             ", spProxy);
        console.log("  SP current impl:      ", curSPImpl);
        console.log("  Registry version:     ", Registry(registryProxy).version());
        console.log("  SP version:           ", SuperPaymaster(payable(spProxy)).version());
        console.log("");
        console.log("  Pre-flight check:");
        console.log("    Registry:       ", needReg  ? "WILL UPGRADE (codehash changed)"    : "SKIP (bytecode unchanged)");
        console.log("    SuperPaymaster: ", needSP   ? "WILL UPGRADE (codehash changed)"    : "SKIP (bytecode unchanged)");
        console.log("    MicroPayChan:   ", needMC   ? "WILL DEPLOY (first time)"           : "SKIP (already deployed)");

        if (!needReg && !needSP && !needMC) {
            console.log("");
            console.log("  Nothing to do -- all contracts are at latest bytecode.");
            return;
        }

        // --- Broadcast only the transactions that are actually needed ---
        vm.startBroadcast();

        Registry       newRegImpl;
        SuperPaymaster newSPImpl;

        if (needReg) {
            newRegImpl = new Registry();
            UUPSUpgradeable(registryProxy).upgradeToAndCall(address(newRegImpl), "");
            console.log("  Registry: upgraded to   ", address(newRegImpl));
        }
        if (needSP) {
            newSPImpl = new SuperPaymaster(
                IEntryPoint(entryPoint),
                IRegistry(registryProxy),
                priceFeed
            );
            UUPSUpgradeable(spProxy).upgradeToAndCall(address(newSPImpl), "");
            console.log("  SuperPaymaster: upgraded to", address(newSPImpl));
        }
        if (needMC) {
            MicroPaymentChannel newMC = new MicroPaymentChannel(deployer);
            mcProxy = address(newMC);
            console.log("  MicroPaymentChannel deployed:", mcProxy);
        }

        vm.stopBroadcast();

        // --- Post-upgrade verification ---
        console.log("");
        console.log("  Registry version after:     ", Registry(registryProxy).version());
        console.log("  SuperPaymaster version after:", SuperPaymaster(payable(spProxy)).version());

        // --- Patch config only for contracts that were actually changed ---
        string memory srcHash    = vm.envOr("SRC_HASH",    vm.parseJsonString(config, ".srcHash"));
        string memory updateTime = vm.envOr("DEPLOY_TIME", string("N/A"));

        if (needReg) vm.writeJson(vm.toString(address(newRegImpl)), configPath, ".registryImpl");
        if (needSP)  vm.writeJson(vm.toString(address(newSPImpl)),  configPath, ".spImpl");
        if (needMC || needReg || needSP) {
            vm.writeJson(vm.toString(mcProxy), configPath, ".microPaymentChannel");
            vm.writeJson(srcHash,              configPath, ".srcHash");
            vm.writeJson(updateTime,           configPath, ".updateTime");
        }

        _ensureTrailingNewline(configPath);

        console.log("");
        console.log("  Config patched:", configPath);
        if (needReg) console.log("    registryImpl        =", address(newRegImpl));
        if (needSP)  console.log("    spImpl              =", address(newSPImpl));
        if (needMC)  console.log("    microPaymentChannel =", mcProxy);
        console.log("=== Upgrade complete ===");
    }

    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
