// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol";
import "src/paymasters/superpaymaster/v3/X402Facilitator.sol";
import "src/core/PolicyRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {IxPNTsFactory} from "src/interfaces/IxPNTsFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {V54Bootstrap} from "./V54Bootstrap.sol";
import {SPReleaseVersion} from "./SPReleaseVersion.sol";

/**
 * @title UpgradeLive
 * @notice Selective UUPS upgrade for SuperPaymaster and/or Registry, plus idempotent
 *         deploy-if-absent of the v5.4 god-split stack (X402Facilitator +
 *         TimelockController + PolicyRegistry). This makes `./deploy-core <env>`
 *         (sepolia / op-sepolia / optimism) v5.4-complete without a manual DeployV54.
 *
 * Policy (from v5.3.3-beta onwards):
 *   Any change to SuperPaymaster or Registry on a live network MUST go through
 *   this script (not DeployLive). DeployLive deploys new proxies and loses all
 *   state (communities, stake, SBT, etc.).
 *
 * Selective upgrade logic (T-4, "tested == deployed"):
 *   1. "Changed?" is decided against the profile.default ARTIFACT, not against a
 *      `new` instance: a `new` in this file compiles under the runs=200 registry-size
 *      profile (this file imports Registry.sol), so the old codehash comparison asked
 *      "does the chain run the registry-size build?" and would redeploy/keep the wrong
 *      bytes. An impl is current iff its runtime == the default artifact (immutables
 *      masked) AND its immutable bindings are the expected ones (SP: REGISTRY,
 *      entryPoint, ETH_USD_PRICE_FEED from config).
 *   2. Only broadcast impl deploys + upgradeToAndCall() for contracts that changed.
 *      Every deploy goes through DefaultArtifacts._deployDefault (explicit artifact
 *      path + runtime assertion); after broadcast the proxies are re-checked with
 *      _requireDefaultProxy. If nothing changed: return early, zero txns.
 *   3. SuperPaymaster 5.4.x -> 5.5.0 is REFUSED here: that upgrade needs runbook
 *      steps 4-7c (UpgradeToV5_5_0.s.sol), not a bare impl swap.
 *   4. GOV-1 (spec 03 §10.7b, GOV-2 v3 part C): once the owner is the timelock, this
 *      script must become deploy -> timelock schedule -> wait -> execute. Not yet.
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
contract UpgradeLive is V54Bootstrap {

    function _currentImpl(address proxy) internal view returns (address) {
        return _implOf(proxy);
    }

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address spProxy       = vm.parseJsonAddress(config, ".superPaymaster");
        address entryPoint    = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed     = vm.parseJsonAddress(config, ".priceFeed");
        address xpntsFactory  = vm.parseJsonAddress(config, ".xPNTsFactory");
        address mcProxy       = _optAddr(config, ".microPaymentChannel");
        // v5.4 god-split contracts (absent on pre-v5.4 deployments)
        address facCfg = _optAddr(config, ".x402Facilitator");
        address tlCfg  = _optAddr(config, ".timelockController");
        address polCfg = _optAddr(config, ".policyRegistry");
        address deployer = msg.sender;

        require(registryProxy != address(0), "UpgradeLive: registry proxy not in config");
        require(spProxy       != address(0), "UpgradeLive: superPaymaster proxy not in config");
        require(entryPoint    != address(0), "UpgradeLive: entryPoint not in config");
        require(priceFeed     != address(0), "UpgradeLive: priceFeed not in config");
        require(xpntsFactory  != address(0), "UpgradeLive: xPNTsFactory not in config");

        // --- "Changed?" against the profile.default artifact (T-4) ---
        address curRegImpl = _currentImpl(registryProxy);
        address curSPImpl  = _currentImpl(spProxy);
        bool needReg = !_codeEqArtifact(curRegImpl, _defaultArtifact("Registry"));
        bool needSP  = !_codeEqArtifact(curSPImpl, _defaultArtifact("SuperPaymaster"))
            || address(SuperPaymaster(payable(curSPImpl)).REGISTRY()) != registryProxy
            || address(SuperPaymaster(payable(curSPImpl)).entryPoint()) != entryPoint
            || address(SuperPaymaster(payable(curSPImpl)).ETH_USD_PRICE_FEED()) != priceFeed;
        if (needSP) {
            // Refuse the 5.4.x -> 5.5.0 jump: it is a migration (runbook 03 §6 steps 4-7c).
            string memory curV = SuperPaymaster(payable(spProxy)).version();
            require(
                keccak256(bytes(curV)) == keccak256(bytes(SPReleaseVersion.SP)),
                "UpgradeLive: SP is not 5.5.0 - use UpgradeToV5_5_0.s.sol (runbook steps 4-7c), not a bare impl swap"
            );
        }
        bool needMC  = (mcProxy == address(0));
        // v5.4 god-split: deploy-if-absent, each gated on its own config key.
        bool needTl  = (tlCfg  == address(0));
        bool needFac = (facCfg == address(0));
        bool needPol = (polCfg == address(0));

        console.log("=== UUPS Selective Upgrade: SuperPaymaster + Registry + v5.4 god-split ===");
        console.log("  Network:              ", network);
        console.log("  Registry proxy:       ", registryProxy);
        console.log("  Registry current impl:", curRegImpl);
        console.log("  SP proxy:             ", spProxy);
        console.log("  SP current impl:      ", curSPImpl);
        console.log("  Registry version:     ", Registry(registryProxy).version());
        console.log("  SP version:           ", SuperPaymaster(payable(spProxy)).version());
        console.log("");
        console.log("  Pre-flight check:");
        console.log("    Registry:        ", needReg  ? "WILL UPGRADE (codehash changed)"    : "SKIP (bytecode unchanged)");
        console.log("    SuperPaymaster:  ", needSP   ? "WILL UPGRADE (codehash changed)"    : "SKIP (bytecode unchanged)");
        console.log("    MicroPayChan:    ", needMC   ? "WILL DEPLOY (first time)"           : "SKIP (already deployed)");
        console.log("    TimelockCtrl:    ", needTl   ? "WILL DEPLOY (first time)"           : "SKIP (already deployed)");
        console.log("    X402Facilitator: ", needFac  ? "WILL DEPLOY (first time)"           : "SKIP (already deployed)");
        console.log("    PolicyRegistry:  ", needPol  ? "WILL DEPLOY (first time)"           : "SKIP (already deployed)");

        if (!needReg && !needSP && !needMC && !needTl && !needFac && !needPol) {
            console.log("");
            console.log("  Nothing to do -- all contracts are at latest bytecode + v5.4 stack present.");
            return;
        }

        (address governor, address guardian) = _resolveGovernance(deployer);

        // --- Broadcast only the transactions that are actually needed ---
        vm.startBroadcast();

        Registry       newRegImpl;
        SuperPaymaster newSPImpl;

        if (needReg) {
            newRegImpl = Registry(_deployDefault("Registry", ""));
            UUPSUpgradeable(registryProxy).upgradeToAndCall(address(newRegImpl), "");
            console.log("  Registry: upgraded to   ", address(newRegImpl));
        }
        if (needSP) {
            newSPImpl = SuperPaymaster(payable(_deployDefault(
                "SuperPaymaster", abi.encode(entryPoint, registryProxy, priceFeed)
            )));
            UUPSUpgradeable(spProxy).upgradeToAndCall(address(newSPImpl), "");
            console.log("  SuperPaymaster: upgraded to", address(newSPImpl));
        }
        if (needMC) {
            MicroPaymentChannel newMC = MicroPaymentChannel(_deployDefault("MicroPaymentChannel", abi.encode(deployer)));
            mcProxy = address(newMC);
            console.log("  MicroPaymentChannel deployed:", mcProxy);
        }

        // --- v5.4 god-split deploy-if-absent (ctor args mirror V54Bootstrap) ---
        if (needTl) {
            address[] memory proposers = new address[](1);
            proposers[0] = governor;
            address[] memory executors = new address[](1);
            executors[0] = governor;
            TimelockController newTl = TimelockController(payable(_deployDefault(
                "TimelockController", abi.encode(TIMELOCK_MIN_DELAY, proposers, executors, governor)
            )));
            tlCfg = address(newTl);
            console.log("  TimelockController deployed:", tlCfg);
        }
        if (needFac) {
            X402Facilitator newFac = X402Facilitator(_deployDefault(
                "X402Facilitator", abi.encode(registryProxy, xpntsFactory)
            ));
            facCfg = address(newFac);
            console.log("  X402Facilitator deployed:", facCfg);
            console.log("    version:", newFac.version());
            // Atomically hand ownership to the resolved governor (multisig) when
            // GOVERNOR_ADDRESS is set, so a mainnet first-deploy never leaves the
            // facilitator on the deployer EOA. Bootstrap (governor == deployer) is a no-op.
            _transferFacilitatorOwnership(facCfg, governor);
        }
        if (needPol) {
            // initialConsumer = SP proxy (staked consumer that calls recordSpend)
            PolicyRegistry newPol = PolicyRegistry(_deployDefault("PolicyRegistry", abi.encode(tlCfg, guardian, spProxy)));
            polCfg = address(newPol);
            console.log("  PolicyRegistry deployed:", polCfg);
            console.log("    SP authorized:", newPol.isAuthorizedConsumer(spProxy));
        }
        // Wire X402Facilitator only when freshly deployed. On an existing v5.4 deploy
        // the wiring is already in place; the loop is idempotent + staticcall-gated
        // (old XPNTs-3.4.0 clones are logged as manual follow-ups, never reverted).
        if (needFac) {
            _wireFacilitator(xpntsFactory, facCfg, deployer);
        }

        vm.stopBroadcast();

        // --- Post-upgrade verification (T-4): proxies + impls == profile.default ---
        _requireDefaultProxy(registryProxy, "Registry");
        address spImplNow = _requireDefaultProxy(spProxy, "SuperPaymaster");
        require(address(SuperPaymaster(payable(spImplNow)).REGISTRY()) == registryProxy, "UpgradeLive: SP impl REGISTRY binding");
        require(address(SuperPaymaster(payable(spImplNow)).entryPoint()) == entryPoint, "UpgradeLive: SP impl entryPoint binding");
        require(address(SuperPaymaster(payable(spImplNow)).ETH_USD_PRICE_FEED()) == priceFeed, "UpgradeLive: SP impl price-feed binding");
        console.log("");
        console.log("  Registry version after:     ", Registry(registryProxy).version());
        console.log("  SuperPaymaster version after:", SuperPaymaster(payable(spProxy)).version());

        // --- Patch config only for contracts that were actually changed ---
        // srcHash intentionally written as "" — deploy-core is the sole authority for committing
        // the real hash AFTER audit-core passes (see "Commit srcHash" block in deploy-core).
        // Writing "" here prevents a failed audit from leaving a valid-looking srcHash in config
        // that would cause the next run to skip both the upgrade and the audit.
        string memory updateTime = vm.envOr("DEPLOY_TIME", string("N/A"));

        if (needReg) vm.writeJson(vm.toString(address(newRegImpl)), configPath, ".registryImpl");
        if (needSP)  vm.writeJson(vm.toString(address(newSPImpl)),  configPath, ".spImpl");
        if (needMC)  vm.writeJson(vm.toString(mcProxy),             configPath, ".microPaymentChannel");
        // v5.4 god-split keys. vm.writeJson creates the key if absent (verified by the
        // Sepolia DeployV54 bus, which first introduced these keys into config).
        if (needTl)  vm.writeJson(vm.toString(tlCfg),  configPath, ".timelockController");
        if (needFac) vm.writeJson(vm.toString(facCfg), configPath, ".x402Facilitator");
        if (needPol) vm.writeJson(vm.toString(polCfg), configPath, ".policyRegistry");
        if (needMC || needReg || needSP || needTl || needFac || needPol) {
            vm.writeJson(string(""),  configPath, ".srcHash");
            vm.writeJson(updateTime, configPath, ".updateTime");
        }

        _ensureTrailingNewline(configPath);

        console.log("");
        console.log("  Config patched:", configPath);
        if (needReg) console.log("    registryImpl        =", address(newRegImpl));
        if (needSP)  console.log("    spImpl              =", address(newSPImpl));
        if (needMC)  console.log("    microPaymentChannel =", mcProxy);
        if (needTl)  console.log("    timelockController  =", tlCfg);
        if (needFac) console.log("    x402Facilitator     =", facCfg);
        if (needPol) console.log("    policyRegistry      =", polCfg);
        if (needFac || needPol || needTl) {
            console.log("");
            console.log("  v5.4 POST-DEPLOY MANUAL STEPS (see docs/deployment/v5.4-launch-operations.md):");
            if (needFac && governor != deployer) {
                console.log("    - X402Facilitator owner   -> ALREADY transferred to governor at deploy (done)");
            } else {
                console.log("    - X402Facilitator owner   -> multisig (transferOwnership) [STILL ON DEPLOYER - DO THIS]");
            }
            console.log("    - PolicyRegistry guardian -> multisig (setGuardian, via timelock)");
            console.log("    - Timelock roles          -> multisig, then renounce deployer admin");
            console.log("    - Hand POLICY_REGISTRY_ADDRESS to airaccount-contract#110");
        }
        console.log("=== Upgrade complete ===");
    }
}
