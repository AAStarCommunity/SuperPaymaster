// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/X402Facilitator.sol";
import "src/core/PolicyRegistry.sol";

import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {IRegistry} from "src/interfaces/v3/IRegistry.sol";
import {IxPNTsFactory} from "src/interfaces/IxPNTsFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {V54Bootstrap} from "./V54Bootstrap.sol";

/**
 * @title DeployV54 (redeploy-bus)
 * @notice v5.4 "god-split + DVT policy" Sepolia rollout. One script that:
 *
 * @dev NOTE (2026-06): DeployLive and UpgradeLive are now v5.4-aware — the canonical
 *      `./deploy-core <env>` path deploys X402Facilitator + TimelockController +
 *      PolicyRegistry and wires the facilitator automatically. This standalone bus is
 *      retained as the PROVEN Sepolia one-shot; it shares its deploy + wiring logic with
 *      the routed scripts via the V54Bootstrap base, so the two cannot drift.
 *
 *   NEW standalone (non-upgradeable) contracts:
 *     1. X402Facilitator   — x402 settlement lifted out of SuperPaymaster.
 *                            ctor(IRegistry registry, IxPNTsFactory factory). owner = deployer.
 *     2. TimelockController — OZ governance for PolicyRegistry. minDelay = 2 days.
 *                            proposers/executors/admin = governor (deployer for Sepolia bootstrap).
 *     3. PolicyRegistry     — sender-keyed DVT spend policy.
 *                            ctor(timelock, guardian, initialConsumer = SuperPaymaster proxy).
 *
 *   UUPS impl upgrades (existing proxies, storage preserved):
 *     4. SuperPaymaster new impl (god-split) -> upgradeToAndCall(newImpl, "").
 *     5. Registry        new impl (#211 L-C fix) -> upgradeToAndCall(newImpl, "").
 *
 *   Wiring (best-effort, per xPNTs token):
 *     - addAutoApprovedSpender(X402Facilitator)
 *     - setSpenderDailyCapFor(X402Facilitator, 10_000 ether)
 *     - addApprovedFacilitator(X402Facilitator)
 *     Each gated on communityOwner == deployer; a mismatch is LOGGED as a manual
 *     follow-up rather than reverting the whole run.
 *
 * @dev SuperPaymaster impl does NOT yet call PolicyRegistry — layer-1 enforcement is
 *      consumed post-deploy by #110 / AirAccount via POLICY_REGISTRY_ADDRESS. SP is
 *      already authorized as initialConsumer at PolicyRegistry construction, so no
 *      SP -> PolicyRegistry wiring is performed here.
 *
 * @dev NOT broadcast by this comment — caller decides. Invoke (broadcast):
 *   source .env.sepolia && forge script contracts/script/v3/DeployV54.s.sol:DeployV54 \
 *     --private-key $PRIVATE_KEY --rpc-url $RPC_URL --broadcast -vvvv
 *
 * Fork simulation (no broadcast):
 *   source .env.sepolia && forge script contracts/script/v3/DeployV54.s.sol:DeployV54 \
 *     --rpc-url $RPC_URL -vvv
 */
contract DeployV54 is V54Bootstrap {
    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath =
            string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        // ---- Read existing proxy / token addresses from config ----
        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address spProxy        = vm.parseJsonAddress(config, ".superPaymaster");
        address entryPoint     = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed      = vm.parseJsonAddress(config, ".priceFeed");
        address xpntsFactory   = vm.parseJsonAddress(config, ".xPNTsFactory");

        // ---- Resolve deployer + governance principals ----
        // PRIVATE_KEY is sourced from .env.sepolia. Driving the broadcast from the env key
        // keeps the simulated/broadcast sender identical to the real deployer, so the
        // communityOwner==deployer wiring gate reflects live Sepolia authority.
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer = pk != 0 ? vm.addr(pk) : msg.sender;

        // Sepolia bootstrap: governor (timelock proposer/executor/admin) and guardian both
        // default to the deployer. Override with GOVERNOR_ADDRESS / GUARDIAN_ADDRESS to point
        // at the real 2-of-3 multisig. Transferred to multisig as a post-deploy manual step.
        address governor = vm.envOr("GOVERNOR_ADDRESS", deployer);
        address guardian = vm.envOr("GUARDIAN_ADDRESS", deployer);

        console.log("============================================================");
        console.log("=== v5.4 redeploy-bus (god-split + DVT policy) ===");
        console.log("============================================================");
        console.log("  Network:          ", network);
        console.log("  Deployer:         ", deployer);
        console.log("  Governor:         ", governor);
        console.log("  Guardian:         ", guardian);
        console.log("  Registry proxy:   ", registryProxy);
        console.log("  SuperPaymaster px:", spProxy);
        console.log("  EntryPoint:       ", entryPoint);
        console.log("  Price feed:       ", priceFeed);
        console.log("  xPNTsFactory:     ", xpntsFactory);
        console.log("  SP version before:    ", SuperPaymaster(payable(spProxy)).version());
        console.log("  Registry version before:", Registry(registryProxy).version());

        address oldSpImpl       = _implOf(spProxy);
        address oldRegistryImpl = _implOf(registryProxy);
        console.log("  SP impl before:       ", oldSpImpl);
        console.log("  Registry impl before: ", oldRegistryImpl);

        // Begin on-chain effects.
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
        }

        // ------------------------------------------------------------------
        // 1-3. Deploy the three NEW v5.4 contracts via the shared bootstrap base
        //      (X402Facilitator, TimelockController, PolicyRegistry). Same code the
        //      deploy-core-routed scripts use, so the bus and the GA path cannot drift.
        // ------------------------------------------------------------------
        console.log("");
        V54Addresses memory v54 =
            _deployV54Contracts(registryProxy, spProxy, xpntsFactory, governor, guardian, address(0));
        X402Facilitator facilitator = X402Facilitator(v54.facilitator);
        TimelockController timelock  = TimelockController(payable(v54.timelock));
        PolicyRegistry policyRegistry = PolicyRegistry(v54.policyRegistry);

        // ------------------------------------------------------------------
        // 4. SuperPaymaster new impl (god-split) + UUPS upgrade.
        //    Reproduce the proxy's immutable ctor args (entryPoint, registry, priceFeed).
        // ------------------------------------------------------------------
        SuperPaymaster newSpImpl = new SuperPaymaster(
            IEntryPoint(entryPoint),
            Registry(registryProxy),
            priceFeed
        );
        UUPSUpgradeable(spProxy).upgradeToAndCall(address(newSpImpl), "");
        console.log("");
        console.log("[4] SuperPaymaster upgraded.");
        console.log("    new impl:", address(newSpImpl));

        // ------------------------------------------------------------------
        // 5. Registry new impl (#211 L-C fix) + UUPS upgrade. ctor() takes no args.
        // ------------------------------------------------------------------
        Registry newRegistryImpl = new Registry();
        UUPSUpgradeable(registryProxy).upgradeToAndCall(address(newRegistryImpl), "");
        console.log("");
        console.log("[5] Registry upgraded.");
        console.log("    new impl:", address(newRegistryImpl));

        // ------------------------------------------------------------------
        // 6. Wiring: authorize X402Facilitator on each community xPNTs token.
        //    Skip+log any token whose communityOwner != deployer.
        // ------------------------------------------------------------------
        _wireFacilitator(xpntsFactory, address(facilitator), deployer);

        vm.stopBroadcast();

        // ---- Post-upgrade verification ----
        address newSpImplOnChain       = _implOf(spProxy);
        address newRegistryImplOnChain = _implOf(registryProxy);
        require(newSpImplOnChain == address(newSpImpl), "SP impl slot mismatch after upgrade");
        require(
            newRegistryImplOnChain == address(newRegistryImpl),
            "Registry impl slot mismatch after upgrade"
        );
        console.log("");
        console.log("  SP version after:       ", SuperPaymaster(payable(spProxy)).version());
        console.log("  Registry version after: ", Registry(registryProxy).version());
        console.log("  SP impl after:          ", newSpImplOnChain);
        console.log("  Registry impl after:    ", newRegistryImplOnChain);

        // ---- Patch config in place (preserve all other fields) ----
        string memory srcHash    = vm.envOr("SRC_HASH",    vm.parseJsonString(config, ".srcHash"));
        string memory updateTime = vm.envOr("DEPLOY_TIME", vm.parseJsonString(config, ".updateTime"));

        vm.writeJson(vm.toString(address(facilitator)),     configPath, ".x402Facilitator");
        vm.writeJson(vm.toString(address(timelock)),        configPath, ".timelockController");
        vm.writeJson(vm.toString(address(policyRegistry)),  configPath, ".policyRegistry");
        vm.writeJson(vm.toString(address(newSpImpl)),       configPath, ".spImpl");
        vm.writeJson(vm.toString(address(newRegistryImpl)), configPath, ".registryImpl");
        vm.writeJson(srcHash,                               configPath, ".srcHash");
        vm.writeJson(updateTime,                            configPath, ".updateTime");
        _ensureTrailingNewline(configPath);

        console.log("");
        console.log("  Config patched:", configPath);
        console.log("    x402Facilitator   =", address(facilitator));
        console.log("    timelockController =", address(timelock));
        console.log("    policyRegistry     =", address(policyRegistry));
        console.log("    spImpl             =", address(newSpImpl));
        console.log("    registryImpl       =", address(newRegistryImpl));

        // ---- Manual post-deploy follow-ups ----
        console.log("");
        console.log("=== POST-DEPLOY MANUAL STEPS (NOT done by this script) ===");
        console.log("  1. Transfer X402Facilitator owner -> multisig:");
        console.log("       X402Facilitator(%s).transferOwnership(<multisig>)", address(facilitator));
        console.log("  2. Move PolicyRegistry guardian -> 2-of-3 multisig (via timelock):");
        console.log("       PolicyRegistry.setGuardian(<multisig>)  [onlyTimelock]");
        console.log("  3. Hand TimelockController PROPOSER/EXECUTOR/admin roles to multisig,");
        console.log("       then renounce deployer's TIMELOCK_ADMIN_ROLE.");
        console.log("  4. Hand POLICY_REGISTRY_ADDRESS=%s to #110 / AirAccount so the", address(policyRegistry));
        console.log("       layer-1 consumer begins calling checkPolicy/recordSpend.");
        console.log("  5. For any xPNTs token logged as SKIPPED below, the real communityOwner");
        console.log("       must run addAutoApprovedSpender + setSpenderDailyCapFor + addApprovedFacilitator.");
        console.log("=== v5.4 deploy complete ===");
    }
}
