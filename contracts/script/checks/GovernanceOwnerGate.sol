// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

interface IOwned {
    function owner() external view returns (address);
}

/**
 * @title GovernanceOwnerGate
 * @notice CC-48 round-6 HIGH-1: "owner should be a Safe multisig" turned into a gate that
 *         fails closed on every deploy and migration entry point that can produce or
 *         re-point a `BLSAggregator` owner.
 *
 * @dev WHY THIS EXISTS NOW, and not as another line of NatSpec. 4.9.0 gave `owner` a NEW
 *      power: `emergencyDisarmFraudProofVerifier()` clears the fraud-proof verifier in the
 *      SAME BLOCK, with no delay and no public notice. Concretely, a colluding or
 *      compromised owner can front-run an honest watcher's `queueGuardianSlash` out of the
 *      mempool for the price of one transaction, and repeat it indefinitely. That trade is
 *      accepted deliberately — a compromised verifier can slash 100% of every accused
 *      guardian's lock inside one block, so a four-day remedy was not a remedy — but the
 *      thing carrying the residual risk is the owner being a multisig, and NOTHING ELSE:
 *
 *        • A TimelockController does NOT cover the disarm path. A timelocked emergency
 *          stop is not an emergency stop; the two are semantically exclusive. For that one
 *          path the multisig is the ONLY governance defence, not defence in depth.
 *        • The in-contract `VERIFIER_ROTATION_DELAY` still governs RE-ARMING (there is no
 *          counterpart that sets a non-zero verifier), so disarm is not a fast path to a
 *          verifier of the owner's choosing.
 *        • Already-queued cases are out of reach either way — execution reads the verdict
 *          frozen at queue time and never reads `fraudProofVerifier`.
 *
 *      So: on any chain that is not local anvil, an EOA owner is refused. The only
 *      exception is a KNOWN TESTNET with an explicit, named acknowledgement
 *      (`TESTNET_EOA_OWNER_ACK=true`) — the RepCredit evidence stack and the CC-89 E2E
 *      aggregator genuinely need a hot owner to drive an experiment, and pretending
 *      otherwise would just get the gate commented out. There is NO acknowledgement that
 *      works on a production chain: the require has no escape hatch there at all.
 *
 *      Scope, stated plainly: this gate covers the OWNER OF THE DISARM AUTHORITY —
 *      `BLSAggregator` — plus the `Registry` owner that the 5.7.0 migration already
 *      gated. It does NOT re-own the rest of the stack; handing GToken / SuperPaymaster /
 *      staking ownership to governance is a separate change with its own blast radius.
 */
library GovernanceOwnerGate {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev anvil. The one chain where a hot EOA owner is the whole point.
    uint256 internal constant LOCAL_CHAIN_ID = 31337;

    /// @notice Refuse to leave `subject` owned by an EOA anywhere it matters.
    /// @param subject   the contract whose ownership is being gated (for the log line)
    /// @param ownerAddr the owner as it reads RIGHT NOW — pass `IOwned(x).owner()`, never
    ///                  the address the script *intended* to set
    /// @param label     contract name, so a failure names what is mis-owned
    function requireGovernanceOwner(address subject, address ownerAddr, string memory label) internal view {
        if (block.chainid == LOCAL_CHAIN_ID) return;

        if (ownerAddr.code.length > 0) {
            console.log(string.concat("  [gov-gate] ", label, " owner is a contract (Safe/Timelock):"), ownerAddr);
            return;
        }

        // Non-local chain, EOA owner. Production: no escape hatch of any kind.
        require(
            _isKnownTestnet(block.chainid),
            string.concat(
                "CC-48 round-6 HIGH-1: ",
                label,
                " owner must be a Safe multisig on a production chain. An EOA owner holds an",
                " immediate, zero-notice emergencyDisarmFraudProofVerifier() -- i.e. the power to",
                " censor every future guardian-slash accusation by front-running it. Set",
                " GOVERNANCE_OWNER to the Safe and re-run."
            )
        );
        require(
            vm.envOr("TESTNET_EOA_OWNER_ACK", false),
            string.concat(
                "CC-48 round-6 HIGH-1: ",
                label,
                " owner is an EOA on a testnet. That is allowed ONLY for experiment stacks and",
                " ONLY with TESTNET_EOA_OWNER_ACK=true, which acknowledges that this deployment",
                " has no governance defence against an immediate verifier disarm. Production",
                " chains cannot set it."
            )
        );
        console.log(string.concat("  [gov-gate] WARNING: ", label, " owner is an EOA on testnet:"), ownerAddr);
        console.log("  [gov-gate] acknowledged via TESTNET_EOA_OWNER_ACK. This deployment has NO");
        console.log("  [gov-gate] governance defence against an immediate, zero-notice verifier");
        console.log("  [gov-gate] disarm. Never use this configuration for anything but experiments.");
        console.log("  [gov-gate] subject:", subject);
    }

    /// @notice Convenience: read the owner off-chain and gate it in one call.
    function requireGovernanceOwner(address subject, string memory label) internal view {
        requireGovernanceOwner(subject, IOwned(subject).owner(), label);
    }

    /// @notice The same gate with NO testnet acknowledgement path: outside anvil the owner
    ///         must be a contract, full stop.
    /// @dev    Used by the 5.7.0 migration entry point. A governance batch that upgrades a
    ///         live Registry and re-points its aggregator is a production operation even
    ///         when it is rehearsed on Sepolia — a rehearsal whose ownership model differs
    ///         from production rehearses the wrong thing. Experiment DEPLOY scripts use the
    ///         acknowledged variant above; MIGRATION does not get one.
    function requireGovernanceOwnerStrict(address subject, address ownerAddr, string memory label)
        internal
        view
    {
        if (block.chainid == LOCAL_CHAIN_ID) return;
        require(
            ownerAddr.code.length > 0,
            string.concat(
                "CC-48 round-6 HIGH-1: ",
                label,
                " owner must be a Safe multisig (or Timelock), not an EOA. For BLSAggregator this is",
                " the ONLY governance defence against an immediate, zero-notice",
                " emergencyDisarmFraudProofVerifier(); a Timelock cannot cover that path."
            )
        );
        console.log(string.concat("  [gov-gate] ", label, " owner is a contract (Safe/Timelock):"), ownerAddr);
        console.log("  [gov-gate] subject:", subject);
    }

    /// @notice The Safe to hand ownership to, or address(0) if the operator did not name
    ///         one. Deploy scripts transfer ownership to it as their LAST owner-gated
    ///         action, then call `requireGovernanceOwner` on the result.
    /// @dev    Deliberately optional: unset + local chain is the normal development path,
    ///         and unset + production chain is caught by the gate rather than by silently
    ///         defaulting to some address baked into a script.
    function declaredGovernanceOwner() internal view returns (address) {
        return vm.envOr("GOVERNANCE_OWNER", address(0));
    }

    /// @dev The same testnet list `DeployLive` uses for its ERC-8004 constants:
    ///      Sepolia, OP Sepolia, Base Sepolia, Arbitrum Sepolia, Polygon Amoy.
    function _isKnownTestnet(uint256 chainId) private pure returns (bool) {
        return chainId == 11155111 || chainId == 11155420 || chainId == 84532 || chainId == 421614
            || chainId == 80002;
    }
}
