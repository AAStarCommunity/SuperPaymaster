// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GovernanceOwnerGate} from "../../script/checks/GovernanceOwnerGate.sol";

/// @notice Stands in for a Safe / TimelockController: any address with code satisfies the
///         gate, because "is a contract" is the only thing a script can check on-chain.
contract SafeStub {
    // deliberately empty — the gate tests `code.length`, nothing more
    uint256 private _filler = 1;
}

/**
 * @title CC48GovernanceOwnerGate
 * @notice CC-48 round-6 HIGH-1. `emergencyDisarmFraudProofVerifier()` is immediate and
 *         unannounced: an EOA owner can censor every FUTURE guardian-slash accusation by
 *         front-running a watcher's `queueGuardianSlash` out of the mempool, for one
 *         transaction's gas each time. A TimelockController cannot cover that path (a
 *         timelocked emergency stop is not an emergency stop), so the Safe multisig is the
 *         ONLY governance defence there.
 *
 *         Before this round nothing enforced it: `BLSAggregator`'s constructor sets
 *         `owner = msg.sender` and every deploy script left the deployer EOA in place. The
 *         property under test is therefore not "the NatSpec says multisig" but "a deploy or
 *         migration that would leave a hot EOA owning the disarm authority cannot finish".
 */
contract CC48GovernanceOwnerGate is Test {
    uint256 internal constant ANVIL = 31337;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant OP_MAINNET = 10;
    uint256 internal constant ETH_MAINNET = 1;

    address internal eoaOwner = address(0xE0A);
    address internal safe;
    address internal subject = address(0x5AB1EC7);

    function setUp() public {
        safe = address(new SafeStub());
    }

    /// @dev `vm.setEnv` mutates the PROCESS environment, and forge runs `setUp` once per
    ///      contract and then replays an EVM snapshot — so env writes leak forwards between
    ///      tests while EVM state does not. Every test that depends on the acknowledgement
    ///      therefore sets it explicitly rather than trusting a shared default.
    function _ack(bool on) internal {
        vm.setEnv("TESTNET_EOA_OWNER_ACK", on ? "true" : "false");
    }

    // =================================================================
    // Production chains: no escape hatch of any kind
    // =================================================================

    /// The core gate. On a production chain an EOA owner is refused outright, and the
    /// acknowledgement that unblocks a testnet does NOT unblock this.
    function test_ProductionChainRefusesAnEoaOwnerEvenWithTheTestnetAck() public {
        _ack(true);

        for (uint256 i = 0; i < 2; ++i) {
            vm.chainId(i == 0 ? ETH_MAINNET : OP_MAINNET);
            (bool ok, string memory reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
            assertFalse(ok, "an EOA owner must never pass on a production chain");
            assertTrue(
                _contains(reason, "must be a Safe multisig on a production chain"),
                "the failure must name the actual requirement"
            );
        }
    }

    /// ...and a Safe passes, so the gate is not merely "always reverts off anvil".
    function test_ProductionChainAcceptsAContractOwner() public {
        _ack(false);
        vm.chainId(ETH_MAINNET);
        (bool ok,) = _tryGate(subject, safe, "BLSAggregator");
        assertTrue(ok, "a contract owner is what the gate exists to require");
    }

    // =================================================================
    // Testnets: allowed, but only via an explicit, named acknowledgement
    // =================================================================

    /// An experiment stack may keep a hot owner — silently is exactly what it may not do.
    function test_TestnetRefusesAnEoaOwnerWithoutTheExplicitAck() public {
        _ack(false);
        vm.chainId(SEPOLIA);
        (bool ok, string memory reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "default on a testnet is still refusal");
        assertTrue(
            _contains(reason, "TESTNET_EOA_OWNER_ACK=true"),
            "the failure must name the one way to proceed"
        );
    }

    /// With the acknowledgement set, the RepCredit / CC-89 E2E stacks can still run. This
    /// exception exists so the gate is not simply commented out by the next operator who
    /// needs a hot owner for an experiment.
    function test_TestnetAllowsAnEoaOwnerWithTheExplicitAck() public {
        vm.chainId(SEPOLIA);
        _ack(true);
        (bool ok,) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok, "acknowledged experiment deployments may proceed");
    }

    // =================================================================
    // Local
    // =================================================================

    /// Anvil is the one chain where a hot EOA owner is the entire point.
    function test_AnvilIsUnaffected() public {
        _ack(false);
        vm.chainId(ANVIL);
        (bool ok,) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok, "local development must not need an acknowledgement");
    }

    // =================================================================
    // The strict variant used by the migration entry point
    // =================================================================

    /// `UpgradeRegistryTo570` uses the strict gate: a migration rehearsal whose ownership
    /// model differs from production rehearses a different system, so the testnet
    /// acknowledgement is not available to it at all.
    function test_StrictGateHasNoTestnetAcknowledgement() public {
        vm.chainId(SEPOLIA);
        _ack(true);

        (bool ok, string memory reason) = _tryStrictGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "the migration gate must not be unlockable by an env var");
        assertTrue(_contains(reason, "must be a Safe multisig"), "reason names the requirement");

        (ok,) = _tryStrictGate(subject, safe, "BLSAggregator");
        assertTrue(ok, "a Safe-owned aggregator migrates normally");
    }

    /// The strict gate still steps aside on anvil, so local end-to-end runs are unchanged.
    function test_StrictGateIsStillANoOpOnAnvil() public {
        _ack(false);
        vm.chainId(ANVIL);
        (bool ok,) = _tryStrictGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok);
    }

    // =================================================================
    // Helpers — the gate is an internal library function, so it needs a CALL boundary
    // for its revert to be catchable.
    // =================================================================

    function _tryGate(address s, address ownerAddr, string memory label)
        internal
        returns (bool ok, string memory reason)
    {
        try this.callGate(s, ownerAddr, label) {
            return (true, "");
        } catch Error(string memory r) {
            return (false, r);
        }
    }

    function _tryStrictGate(address s, address ownerAddr, string memory label)
        internal
        returns (bool ok, string memory reason)
    {
        try this.callStrictGate(s, ownerAddr, label) {
            return (true, "");
        } catch Error(string memory r) {
            return (false, r);
        }
    }

    function callGate(address s, address ownerAddr, string memory label) external view {
        GovernanceOwnerGate.requireGovernanceOwner(s, ownerAddr, label);
    }

    function callStrictGate(address s, address ownerAddr, string memory label) external view {
        GovernanceOwnerGate.requireGovernanceOwnerStrict(s, ownerAddr, label);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
