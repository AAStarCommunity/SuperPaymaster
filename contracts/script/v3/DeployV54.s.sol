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

/// @dev Minimal view over the concrete xPNTsFactory: enumerate every community token it minted.
interface IXPNTsFactoryEnum {
    function getAllTokens() external view returns (address[] memory);
}

/// @dev Minimal view/mutate surface over the concrete xPNTsToken for X402Facilitator wiring.
///      Not in IxPNTsToken (those are community-admin entrypoints), so declared locally.
interface IXPNTsWiring {
    function communityOwner() external view returns (address);
    function autoApprovedSpenders(address spender) external view returns (bool);
    function approvedFacilitators(address facilitator) external view returns (bool);
    function addAutoApprovedSpender(address spender) external;        // onlyFactoryOrOwner
    function setSpenderDailyCapFor(address spender, uint256 newCap) external; // onlyCommunityOwner
    function addApprovedFacilitator(address facilitator) external;    // onlyCommunityOwner
}

/**
 * @title DeployV54 (redeploy-bus)
 * @notice v5.4 "god-split + DVT policy" Sepolia rollout. One script that:
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
contract DeployV54 is Script {
    // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant TIMELOCK_MIN_DELAY = 2 days;
    uint256 internal constant FACILITATOR_DAILY_CAP = 10_000 ether;

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
        // 1. X402Facilitator (NEW, non-upgradeable). owner = deployer.
        // ------------------------------------------------------------------
        X402Facilitator facilitator = new X402Facilitator(
            IRegistry(registryProxy),
            IxPNTsFactory(xpntsFactory)
        );
        console.log("");
        console.log("[1] X402Facilitator deployed:", address(facilitator));
        console.log("    version:", facilitator.version());
        console.log("    owner:  ", facilitator.owner());

        // ------------------------------------------------------------------
        // 2. TimelockController (NEW). minDelay = 2 days; governor is sole
        //    proposer + executor + admin for Sepolia bootstrap.
        // ------------------------------------------------------------------
        address[] memory proposers = new address[](1);
        proposers[0] = governor;
        address[] memory executors = new address[](1);
        executors[0] = governor;
        TimelockController timelock = new TimelockController(
            TIMELOCK_MIN_DELAY,
            proposers,
            executors,
            governor // admin (bootstrap); renounce/transfer to multisig post-deploy
        );
        console.log("");
        console.log("[2] TimelockController deployed:", address(timelock));
        console.log("    minDelay (s):", TIMELOCK_MIN_DELAY);
        console.log("    proposer/executor/admin:", governor);

        // ------------------------------------------------------------------
        // 3. PolicyRegistry (NEW, non-upgradeable).
        //    ctor(timelock, guardian, initialConsumer = SuperPaymaster proxy).
        // ------------------------------------------------------------------
        PolicyRegistry policyRegistry = new PolicyRegistry(
            address(timelock),
            guardian,
            spProxy // initialConsumer: SP is the staked consumer that calls recordSpend
        );
        console.log("");
        console.log("[3] PolicyRegistry deployed:", address(policyRegistry));
        console.log("    version: ", policyRegistry.version());
        console.log("    timelock:", policyRegistry.timelock());
        console.log("    guardian:", policyRegistry.guardian());
        console.log("    initialConsumer (SP) authorized:", policyRegistry.isAuthorizedConsumer(spProxy));

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

    /// @dev Best-effort wiring loop. Authorizes `facilitator` on every factory-minted xPNTs
    ///      token the deployer owns. NEVER queues a reverting broadcast transaction:
    ///        - a communityOwner mismatch is skipped+logged;
    ///        - each setter is gated on a low-level staticcall probe of its paired getter,
    ///          so a token whose ON-CHAIN bytecode predates a v5.4 setter (e.g. the Sepolia
    ///          clones still on XPNTs-3.4.0, which lacks setSpenderDailyCapFor) is logged as
    ///          a manual follow-up instead of issuing a doomed tx that fails forge's broadcast
    ///          re-simulation (and would burn gas / a nonce on real broadcast).
    ///      Staticcall probes are view-only and are NOT recorded as broadcast transactions.
    function _wireFacilitator(address xpntsFactory, address facilitator, address deployer) internal {
        address[] memory tokens = IXPNTsFactoryEnum(xpntsFactory).getAllTokens();
        console.log("");
        console.log("[6] Wiring X402Facilitator on", tokens.length, "xPNTs token(s)");

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            IXPNTsWiring t = IXPNTsWiring(token);

            // communityOwner() exists on all xPNTs versions; guard anyway.
            (bool ownerOk, bytes memory ownerRet) =
                token.staticcall(abi.encodeWithSignature("communityOwner()"));
            if (!ownerOk || ownerRet.length < 32) {
                console.log("    SKIP token (no communityOwner getter):", token);
                continue;
            }
            address owner = abi.decode(ownerRet, (address));
            if (owner != deployer) {
                console.log("    SKIP token:", token);
                console.log("      communityOwner is not deployer:", owner);
                console.log("      -> manual wiring required by communityOwner");
                continue;
            }

            bool complete = true;

            // (a) addAutoApprovedSpender — paired getter: autoApprovedSpenders(address).
            (bool b1, bytes memory r1) =
                token.staticcall(abi.encodeWithSignature("autoApprovedSpenders(address)", facilitator));
            if (b1 && r1.length >= 32) {
                if (!abi.decode(r1, (bool))) {
                    t.addAutoApprovedSpender(facilitator);
                }
            } else {
                complete = false;
                console.log("      ! addAutoApprovedSpender unsupported (old bytecode)");
            }

            // (b) setSpenderDailyCapFor — paired getter: spenderDailyCapOverride(address).
            //     Reverts on XPNTs-3.4.0; gate on the getter so we never queue a failing tx.
            (bool b2,) =
                token.staticcall(abi.encodeWithSignature("spenderDailyCapOverride(address)", facilitator));
            if (b2) {
                t.setSpenderDailyCapFor(facilitator, FACILITATOR_DAILY_CAP);
            } else {
                complete = false;
                console.log("      ! setSpenderDailyCapFor unsupported (old bytecode)");
            }

            // (c) addApprovedFacilitator — paired getter: approvedFacilitators(address).
            (bool b3, bytes memory r3) =
                token.staticcall(abi.encodeWithSignature("approvedFacilitators(address)", facilitator));
            if (b3 && r3.length >= 32) {
                if (!abi.decode(r3, (bool))) {
                    t.addApprovedFacilitator(facilitator);
                }
            } else {
                complete = false;
                console.log("      ! addApprovedFacilitator unsupported (old bytecode)");
            }

            if (complete) {
                console.log("    WIRED token:", token);
            } else {
                console.log("    PARTIAL token (redeploy/upgrade xPNTs, then manual wiring):", token);
            }
        }
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    /// @dev Append `\n` only if the file doesn't already end in one. Idempotent.
    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
