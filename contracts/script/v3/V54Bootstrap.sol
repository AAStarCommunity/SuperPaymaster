// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/superpaymaster/v3/X402Facilitator.sol";
import "src/core/PolicyRegistry.sol";

import {IRegistry} from "src/interfaces/v3/IRegistry.sol";
import {IxPNTsFactory} from "src/interfaces/IxPNTsFactory.sol";
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
 * @title V54Bootstrap
 * @notice Shared v5.4 "god-split + DVT policy" deploy + wiring helpers.
 *
 *  Single source of truth for the three NEW standalone (non-upgradeable) v5.4
 *  contracts and the per-xPNTs X402Facilitator wiring loop. Inherited by every
 *  deploy path so they cannot drift:
 *    - DeployAnvil  (local / CI / run_full_regression)
 *    - DeployLive   (fresh GA deploy)
 *    - UpgradeLive  (standard `./deploy-core <env>` upgrade path — idempotent)
 *    - DeployV54    (the proven Sepolia one-shot redeploy-bus; now thin wrapper)
 *
 *  The three contracts:
 *    1. X402Facilitator   — x402 settlement lifted out of SuperPaymaster.
 *                           ctor(IRegistry registry, IxPNTsFactory factory). owner = deployer.
 *    2. TimelockController — OZ governance for PolicyRegistry. minDelay = 2 days.
 *                           proposers/executors/admin = governor (deployer for bootstrap).
 *    3. PolicyRegistry     — sender-keyed DVT spend policy.
 *                           ctor(timelock, guardian, initialConsumer = SuperPaymaster proxy).
 *
 *  SuperPaymaster does NOT call PolicyRegistry yet — layer-1 enforcement is consumed
 *  post-deploy by airaccount-contract#110 via POLICY_REGISTRY_ADDRESS. SP is already
 *  authorized as initialConsumer at PolicyRegistry construction, so no SP -> PolicyRegistry
 *  wiring is performed here.
 */
abstract contract V54Bootstrap is Script {
    // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant V54_IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal constant TIMELOCK_MIN_DELAY = 2 days;
    uint256 internal constant FACILITATOR_DAILY_CAP = 10_000 ether;

    struct V54Addresses {
        address facilitator;
        address timelock;
        address policyRegistry;
    }

    /// @dev Resolve governance principals. Bootstrap defaults both to the deployer;
    ///      override with GOVERNOR_ADDRESS / GUARDIAN_ADDRESS to point at the real
    ///      2-of-3 multisig. Transferred to multisig as a post-deploy manual step
    ///      (see docs/deployment/v5.4-launch-operations.md).
    function _resolveGovernance(address deployer)
        internal
        view
        returns (address governor, address guardian)
    {
        governor = vm.envOr("GOVERNOR_ADDRESS", deployer);
        guardian = vm.envOr("GUARDIAN_ADDRESS", deployer);
    }

    /// @dev Deploy the three NEW v5.4 contracts. MUST be called inside an active broadcast.
    ///      `existingTimelock` lets UpgradeLive reuse an already-deployed timelock when only
    ///      PolicyRegistry/Facilitator are missing; pass address(0) to deploy a fresh one.
    function _deployV54Contracts(
        address registryProxy,
        address spProxy,
        address xpntsFactory,
        address governor,
        address guardian,
        address existingTimelock
    ) internal returns (V54Addresses memory a) {
        // --- 1. X402Facilitator (NEW, non-upgradeable). owner = broadcaster. ---
        X402Facilitator facilitator = new X402Facilitator(
            IRegistry(registryProxy),
            IxPNTsFactory(xpntsFactory)
        );
        a.facilitator = address(facilitator);
        console.log("  [v5.4] X402Facilitator:", a.facilitator);
        console.log("         version:", facilitator.version());
        console.log("         owner:  ", facilitator.owner());

        // Hand ownership to the resolved governor ATOMICALLY at deploy time when
        // governance-at-deploy is configured. Leaving X402Facilitator owned by a single
        // deployer EOA on mainnet is a security hole; this closes it for the
        // GOVERNOR_ADDRESS path. Bootstrap (governor == deployer) is a no-op.
        _transferFacilitatorOwnership(a.facilitator, governor);

        // --- 2. TimelockController (NEW unless reusing existing). minDelay = 2 days. ---
        if (existingTimelock != address(0)) {
            a.timelock = existingTimelock;
            console.log("  [v5.4] TimelockController (reused):", a.timelock);
        } else {
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
            a.timelock = address(timelock);
            console.log("  [v5.4] TimelockController:", a.timelock);
            console.log("         minDelay (s):", TIMELOCK_MIN_DELAY);
            console.log("         proposer/executor/admin:", governor);
        }

        // --- 3. PolicyRegistry (NEW, non-upgradeable). SP = initialConsumer. ---
        PolicyRegistry policyRegistry = new PolicyRegistry(
            a.timelock,
            guardian,
            spProxy
        );
        a.policyRegistry = address(policyRegistry);
        console.log("  [v5.4] PolicyRegistry:", a.policyRegistry);
        console.log("         version: ", policyRegistry.version());
        console.log("         timelock:", policyRegistry.timelock());
        console.log("         guardian:", policyRegistry.guardian());
        console.log("         SP authorized:", policyRegistry.isAuthorizedConsumer(spProxy));
    }

    /// @dev Transfer X402Facilitator ownership to `governor` when governance-at-deploy is
    ///      configured (governor set AND != the current owner / deployer). MUST run inside the
    ///      active broadcast by the current owner. On bootstrap (governor == deployer, i.e.
    ///      GOVERNOR_ADDRESS unset) it is a no-op and ownership stays on the deployer, to be
    ///      handed to the multisig post-deploy per docs/deployment/v5.4-launch-operations.md.
    ///      Shared by every deploy path (DeployLive / DeployAnvil / DeployV54 via
    ///      _deployV54Contracts, and UpgradeLive's first-deploy needFac branch) so they cannot
    ///      drift and a mainnet deploy never leaves the facilitator on a single deployer EOA.
    function _transferFacilitatorOwnership(address facilitator, address governor) internal {
        address current = X402Facilitator(facilitator).owner();
        if (governor != address(0) && governor != current) {
            X402Facilitator(facilitator).transferOwnership(governor);
            console.log("  [v5.4] X402Facilitator owner -> governor (atomic at deploy):", governor);
        } else {
            console.log("  [v5.4] X402Facilitator owner kept on deployer (no GOVERNOR_ADDRESS):", current);
        }
    }

    /// @dev Best-effort wiring loop. Authorizes `facilitator` on every factory-minted xPNTs
    ///      token the broadcaster (`deployer`) owns. NEVER queues a reverting broadcast tx:
    ///        - a communityOwner mismatch is skipped+logged;
    ///        - each setter is gated on a low-level staticcall probe of its paired getter,
    ///          so a token whose ON-CHAIN bytecode predates a v5.4 setter (e.g. clones still
    ///          on XPNTs-3.4.0, which lacks setSpenderDailyCapFor) is logged as a manual
    ///          follow-up instead of issuing a doomed tx that fails forge's broadcast
    ///          re-simulation (and would burn gas / a nonce on real broadcast).
    ///      Staticcall probes are view-only and are NOT recorded as broadcast transactions.
    ///      On a FRESH deploy the factory-cloned xPNTs are new-bytecode, so wiring succeeds.
    function _wireFacilitator(address xpntsFactory, address facilitator, address deployer) internal {
        address[] memory tokens = IXPNTsFactoryEnum(xpntsFactory).getAllTokens();
        console.log("");
        console.log("  [v5.4] Wiring X402Facilitator on", tokens.length, "xPNTs token(s)");

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

    /// @dev Wire X402Facilitator on a SINGLE freshly-created token. Used by TestAccountPrepare,
    ///      where the broadcaster is the token's communityOwner. Idempotent + staticcall-gated.
    ///      Returns true when all three authorizations are in place (fresh-bytecode tokens).
    function _wireFacilitatorForToken(address token, address facilitator) internal returns (bool complete) {
        IXPNTsWiring t = IXPNTsWiring(token);
        complete = true;

        (bool b1, bytes memory r1) =
            token.staticcall(abi.encodeWithSignature("autoApprovedSpenders(address)", facilitator));
        if (b1 && r1.length >= 32) {
            if (!abi.decode(r1, (bool))) t.addAutoApprovedSpender(facilitator);
        } else {
            complete = false;
        }

        (bool b2,) =
            token.staticcall(abi.encodeWithSignature("spenderDailyCapOverride(address)", facilitator));
        if (b2) {
            t.setSpenderDailyCapFor(facilitator, FACILITATOR_DAILY_CAP);
        } else {
            complete = false;
        }

        (bool b3, bytes memory r3) =
            token.staticcall(abi.encodeWithSignature("approvedFacilitators(address)", facilitator));
        if (b3 && r3.length >= 32) {
            if (!abi.decode(r3, (bool))) t.addApprovedFacilitator(facilitator);
        } else {
            complete = false;
        }
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, V54_IMPL_SLOT))));
    }

    /// @dev Append `\n` only if the file doesn't already end in one. Idempotent.
    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }

    /// @dev Parse an optional address key from a config JSON; returns address(0) if absent.
    function _optAddr(string memory config, string memory key) internal view returns (address) {
        try vm.parseJsonAddress(config, key) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }
}
