// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

interface IOwned {
    function owner() external view returns (address);
}

/// @notice The two Safe methods this gate actually calls. Declared here rather than
///         imported so the gate depends on an INTERFACE SHAPE, not on a Safe release.
interface ISafeCompatibleMofN {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/**
 * @title GovernanceOwnerGate
 * @notice CC-48 round-7 HIGH-1: the gate now enforces the property it names.
 *
 * @dev WHAT THIS GATE PROVES, STATED EXACTLY. It proves that the owner address
 *      (a) holds code, (b) is NOT an EIP-7702 delegation designator, and (c) answers
 *      `getThreshold()` and `getOwners()` with a Safe-COMPATIBLE M-of-N configuration —
 *      `threshold >= 2`, `owners.length >= threshold`, owners distinct, non-zero and
 *      exactly ABI-encoded. That is an INTERFACE-AND-THRESHOLD assertion.
 *
 *      IT DOES NOT PROVE THE OWNER IS A CANONICAL GNOSIS SAFE. A contract can implement
 *      both methods and return whatever it likes while a single key still controls
 *      execution. Proving canonicity needs something this gate deliberately does not
 *      have: an audited runtime-codehash or proxy-factory allowlist per chain. Until that
 *      exists, every message, log line and document in this repo must say
 *      "Safe-compatible M-of-N", never "is a Safe". Round 6 got this backwards — it
 *      checked `code.length > 0` and printed "owner is a contract (Safe/Timelock)", so an
 *      EIP-7702 delegated EOA (code length 23, private key still signs everything) and a
 *      1-of-1 forwarder both passed while the NatSpec told downstream consumers that a
 *      multisig had been enforced.
 *
 * @dev WHY THE OWNER MATTERS AT ALL. 4.9.0 gave `owner` a new power:
 *      `emergencyDisarmFraudProofVerifier()` clears the fraud-proof verifier in the SAME
 *      block, with no delay and no public notice. A colluding or compromised owner can
 *      front-run an honest watcher's `queueGuardianSlash` out of the mempool for the price
 *      of one transaction, and repeat it indefinitely. That trade is accepted deliberately
 *      — a compromised verifier can slash 100% of every accused guardian's lock inside one
 *      block, so a four-day remedy was not a remedy — but the thing carrying the residual
 *      risk is the owner's M-of-N configuration, and NOTHING ELSE:
 *
 *        • A TimelockController does NOT cover the disarm path. A timelocked emergency
 *          stop is not an emergency stop; the two are semantically exclusive. For that one
 *          path the M-of-N owner is the ONLY governance defence, not defence in depth.
 *        • The in-contract `VERIFIER_ROTATION_DELAY` still governs RE-ARMING (there is no
 *          counterpart that sets a non-zero verifier), so disarm is not a fast path to a
 *          verifier of the owner's choosing.
 *        • Already-queued cases are out of reach either way — execution reads the verdict
 *          frozen at queue time and never reads `fraudProofVerifier`.
 *
 *      A `TimelockController` does NOT satisfy this gate (it has no `getThreshold`), and
 *      that is intentional for `BLSAggregator`. `Registry` may legitimately be owned by a
 *      Timelock instead; see `requireTimelockOwner`, which asserts the Timelock-shaped
 *      property (`getMinDelay() > 0` and `owner == that Timelock`) rather than pretending
 *      one shape fits both.
 *
 * @dev ESCAPE HATCHES, ALL EXPLICIT AND ALL NAMED IN THE LOG.
 *        • `TESTNET_EOA_OWNER_ACK=true` — known testnets only, non-strict variant only.
 *          The RepCredit evidence stack and the CC-89 E2E aggregator genuinely need a hot
 *          owner to drive an experiment; pretending otherwise just gets the gate commented
 *          out. There is NO acknowledgement that works on a production chain.
 *        • `LOCAL_DEV_GOVERNANCE_ACK=true` — chainid 31337 only. Round 6 made 31337 an
 *          unconditional no-op, and `anvil --fork-url <mainnet>` reports 31337, so a
 *          mainnet-fork rehearsal passed the gate silently and gave false assurance. The
 *          ack is now typed by a human, and it is printed.
 *
 *      Scope, stated plainly: this gate covers the OWNER OF THE DISARM AUTHORITY —
 *      `BLSAggregator` — plus the `Registry` owner that the 5.7.0 migration already gated.
 *      It does NOT re-own the rest of the stack; handing GToken / SuperPaymaster / staking
 *      ownership to governance is a separate change with its own blast radius.
 */
library GovernanceOwnerGate {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev anvil. Still needs `LOCAL_DEV_GOVERNANCE_ACK`; see LOW-4 above.
    uint256 internal constant LOCAL_CHAIN_ID = 31337;

    /// @dev EIP-7702 delegation designator prefix. A delegated EOA's code is exactly
    ///      `0xef0100 ‖ address` (23 bytes) and its private key still signs everything, so
    ///      it is an EOA for every purpose this gate cares about. Both Sepolia and Ethereum
    ///      mainnet are past Pectra and mainstream "smart EOA" wallets delegate by default,
    ///      so this is the common case, not the exotic one.
    bytes3 internal constant EIP7702_PREFIX = 0xef0100;
    uint256 internal constant EIP7702_CODE_LENGTH = 23;

    /// @dev Upper bound on `getOwners()` length. A real Safe is far below this; the bound
    ///      exists so a hostile owner cannot return a multi-megabyte array and turn the
    ///      distinctness scan into a denial of service. Over the bound is REFUSED, not
    ///      truncated.
    uint256 internal constant MAX_GOVERNANCE_OWNERS = 64;

    /// @notice How an owner address classifies before any interface call is made.
    enum OwnerKind {
        Eoa, //           no code
        Delegated7702, // 0xef0100 ‖ address
        Contract //       anything else
    }

    /// @notice The M-of-N configuration read off a Safe-compatible owner.
    struct MofN {
        uint256 threshold;
        uint256 ownerCount;
    }

    // =====================================================================
    // Classification
    // =====================================================================

    /// @notice Classify `addr` without trusting `code.length` alone.
    function ownerKind(address addr) internal view returns (OwnerKind) {
        bytes memory code = addr.code;
        if (code.length == 0) return OwnerKind.Eoa;
        if (code.length == EIP7702_CODE_LENGTH && bytes3(code) == EIP7702_PREFIX) {
            return OwnerKind.Delegated7702;
        }
        return OwnerKind.Contract;
    }

    /// @notice Read a Safe-compatible M-of-N configuration, fail-closed on ANY deviation.
    /// @dev    Every step is exact: `getThreshold()` must return EXACTLY 32 bytes;
    ///         `getOwners()` must be a canonically-encoded `address[]` (head offset == 32,
    ///         `length` matching the returndata to the byte, every element with a clean
    ///         upper 96 bits). A revert, empty returndata, a wide proxy answer, a
    ///         non-canonical offset and a dirty address word are all REFUSED — those are
    ///         exactly the shapes a fake produces.
    /// @return ok  the owner answered both methods with a decodable, self-consistent M-of-N
    /// @return cfg the configuration; meaningless when `ok` is false
    /// @return why a short reason, for the failure message
    function readMofN(address ownerAddr)
        internal
        view
        returns (bool ok, MofN memory cfg, string memory why)
    {
        (bool tOk, uint256 threshold) =
            _staticUint(ownerAddr, abi.encodeCall(ISafeCompatibleMofN.getThreshold, ()));
        if (!tOk) return (false, cfg, "getThreshold() did not answer with exactly one uint256");

        (bool oOk, uint256 ownerCount) =
            _staticAddressArray(ownerAddr, abi.encodeCall(ISafeCompatibleMofN.getOwners, ()));
        if (!oOk) {
            return (false, cfg, "getOwners() did not answer with a canonical, distinct address[]");
        }

        cfg = MofN({threshold: threshold, ownerCount: ownerCount});
        if (threshold < 2) return (false, cfg, "threshold < 2 (a 1-of-N owner is one key)");
        if (ownerCount < threshold) return (false, cfg, "owners.length < threshold (unsatisfiable)");
        return (true, cfg, "");
    }

    // =====================================================================
    // The gates
    // =====================================================================

    /// @notice Refuse to leave `subject` owned by anything that is not a Safe-compatible
    ///         M-of-N owner, with a named testnet acknowledgement as the only exception.
    /// @param subject   the contract whose ownership is being gated
    /// @param ownerAddr the owner as it reads RIGHT NOW — pass `IOwned(x).owner()`, never
    ///                  the address the script *intended* to set
    /// @param label     contract name, so a failure names what is mis-owned
    function requireGovernanceOwner(address subject, address ownerAddr, string memory label) internal view {
        _gate(subject, ownerAddr, label, false);
    }

    /// @notice Convenience: read the owner off-chain and gate it in one call.
    function requireGovernanceOwner(address subject, string memory label) internal view {
        requireGovernanceOwner(subject, IOwned(subject).owner(), label);
    }

    /// @notice The same gate with NO testnet acknowledgement path.
    /// @dev    Used by the 5.7.0 migration entry point. A governance batch that upgrades a
    ///         live Registry and re-points its aggregator is a production operation even
    ///         when it is rehearsed on Sepolia — a rehearsal whose ownership model differs
    ///         from production rehearses the wrong thing. Experiment DEPLOY scripts use the
    ///         acknowledged variant above; MIGRATION does not get one.
    function requireGovernanceOwnerStrict(address subject, address ownerAddr, string memory label)
        internal
        view
    {
        _gate(subject, ownerAddr, label, true);
    }

    /// @notice Assert that `ownerAddr` is the TimelockController at `timelock`, and that
    ///         the Timelock actually imposes a delay.
    /// @dev    CC-48 round-7, from the archived original checklist: `Registry` governance
    ///         is a different question from `BLSAggregator` governance.
    ///         `Registry.setCreditPolicy` is `immediate onlyOwner`, so if the answer to
    ///         "who owns Registry" is "a Timelock", the deployment evidence has to show
    ///         `getMinDelay() > 0` and `Registry.owner() == that Timelock` — printing
    ///         `scheduleBatch` calldata proves neither. If the answer is "a Safe", use
    ///         `requireGovernanceOwnerStrict` instead; both are accepted, guessing is not.
    function requireTimelockOwner(address subject, address ownerAddr, address timelock, string memory label)
        internal
        view
    {
        require(
            ownerAddr == timelock,
            string.concat(
                "CC-48 round-7: TIMELOCK is set but ",
                label,
                ".owner() is a different address. The batch below would be scheduled into a",
                " Timelock that cannot execute it."
            )
        );
        require(
            ownerKind(timelock) == OwnerKind.Contract,
            string.concat("CC-48 round-7: TIMELOCK ", label, " is not a contract (or is a 7702 delegation)")
        );
        (bool ok, uint256 minDelay) = _staticUint(timelock, abi.encodeWithSignature("getMinDelay()"));
        require(
            ok && minDelay > 0,
            string.concat(
                "CC-48 round-7: TIMELOCK must answer getMinDelay() with a NON-ZERO delay. A",
                " zero-delay Timelock owning ",
                label,
                " makes setCreditPolicy immediate again, which is the property this batch exists",
                " to remove."
            )
        );
        console.log(string.concat("  [gov-gate] ", label, " owner is a Timelock:"), timelock);
        console.log("  [gov-gate]   getMinDelay()      :", minDelay);
        console.log("  [gov-gate]   criterion          : owner == TIMELOCK && getMinDelay() > 0");
        console.log("  [gov-gate]   NOT proven         : that this Timelock's proposers are themselves M-of-N");
        console.log("  [gov-gate] subject:", subject);
    }

    /// @notice The Safe to hand ownership to, or address(0) if the operator did not name
    ///         one. Deploy scripts transfer ownership to it as their LAST owner-gated
    ///         action, then call `requireGovernanceOwner` on the result.
    /// @dev    Deliberately optional at READ time so local development needs no env var;
    ///         "not declared" and "declared wrong" are told apart inside `_gate`, which
    ///         emits a different message for each.
    function declaredGovernanceOwner() internal view returns (address) {
        return vm.envOr("GOVERNANCE_OWNER", address(0));
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _gate(address subject, address ownerAddr, string memory label, bool strict) private view {
        if (block.chainid == LOCAL_CHAIN_ID) {
            // CC-48 round-7 LOW-4. `anvil --fork-url <mainnet>` also reports 31337, so an
            // unconditional no-op here let a mainnet-fork rehearsal "pass" a gate that had
            // never run. Nothing on-chain distinguishes a fork from a fresh local node, so
            // the distinction is made by a human typing the ack — and it is printed, so a
            // transcript shows the gate was skipped rather than satisfied.
            require(
                vm.envOr("LOCAL_DEV_GOVERNANCE_ACK", false),
                string.concat(
                    "CC-48 round-7 LOW-4: chainid 31337 skips the governance gate for ",
                    label,
                    ", so it must be acknowledged with LOCAL_DEV_GOVERNANCE_ACK=true. Note that",
                    " `anvil --fork-url <mainnet>` ALSO reports 31337: if this is a fork rehearsal",
                    " of a production chain, the gate you are about to skip is the one you came to",
                    " rehearse."
                )
            );
            console.log(string.concat("  [gov-gate] SKIPPED on local chain 31337 for ", label), ownerAddr);
            console.log("  [gov-gate] acknowledged via LOCAL_DEV_GOVERNANCE_ACK. Nothing about the");
            console.log("  [gov-gate] owner was verified. If this was an --fork-url rehearsal, it");
            console.log("  [gov-gate] rehearsed a system with no governance gate.");
            return;
        }

        OwnerKind kind = ownerKind(ownerAddr);

        if (kind == OwnerKind.Contract) {
            (bool ok, MofN memory cfg, string memory why) = readMofN(ownerAddr);
            require(
                ok,
                string.concat(
                    "CC-48 round-7 HIGH-1: ",
                    label,
                    " owner holds code but is NOT a Safe-compatible M-of-N owner -- ",
                    why,
                    ". Required: getThreshold() >= 2 and getOwners() a canonical address[] of",
                    " distinct non-zero owners with length >= threshold. A 1-of-1 forwarder is one",
                    " hot key wearing a contract's address, and this owner holds an immediate,",
                    " zero-notice emergencyDisarmFraudProofVerifier(). Set GOVERNANCE_OWNER to the",
                    " Safe and re-run."
                )
            );
            _logAccepted(subject, ownerAddr, label, cfg);
            return;
        }

        // EOA or 7702-delegated EOA from here down.
        string memory kindPhrase = kind == OwnerKind.Delegated7702
            ? " owner is an EIP-7702 DELEGATED EOA (code is 0xef0100 || address, 23 bytes). Its"
                " private key still signs everything, so it is an EOA for governance purposes --"
                " round 6's code.length > 0 check accepted exactly this and printed 'owner is a"
                " contract'."
            : " owner is an EOA.";

        require(
            _isKnownTestnet(block.chainid),
            string.concat(
                "CC-48 round-7 HIGH-1: ",
                label,
                kindPhrase,
                " A production chain requires a Safe-compatible M-of-N owner: an EOA owner holds",
                " an immediate, zero-notice emergencyDisarmFraudProofVerifier() -- i.e. the power",
                " to censor every future guardian-slash accusation by front-running it.",
                _declarationHint()
            )
        );
        require(
            !strict,
            string.concat(
                "CC-48 round-7 HIGH-1: ",
                label,
                kindPhrase,
                " The MIGRATION gate requires a Safe-compatible M-of-N owner and has no testnet",
                " acknowledgement: a migration rehearsal whose ownership model differs from",
                " production rehearses a different system.",
                _declarationHint()
            )
        );
        require(
            vm.envOr("TESTNET_EOA_OWNER_ACK", false),
            string.concat(
                "CC-48 round-7 HIGH-1: ",
                label,
                kindPhrase,
                " That is allowed ONLY for experiment stacks and ONLY with",
                " TESTNET_EOA_OWNER_ACK=true, which acknowledges that this deployment has no",
                " governance defence against an immediate verifier disarm. Production chains",
                " cannot set it.",
                _declarationHint()
            )
        );
        console.log(string.concat("  [gov-gate] WARNING: ", label, " owner is a hot key on testnet:"), ownerAddr);
        console.log("  [gov-gate]   kind               :", kind == OwnerKind.Delegated7702 ? "EIP-7702 delegated EOA" : "EOA");
        console.log("  [gov-gate] acknowledged via TESTNET_EOA_OWNER_ACK. This deployment has NO");
        console.log("  [gov-gate] governance defence against an immediate, zero-notice verifier");
        console.log("  [gov-gate] disarm. Never use this configuration for anything but experiments.");
        console.log("  [gov-gate] subject:", subject);
    }

    /// @dev Deployment evidence (round-7, required by the reviewer): the transcript must
    ///      carry the owner, the threshold, the owner count AND the criterion that was
    ///      applied — including what the criterion does NOT prove, so a downstream reader
    ///      cannot upgrade "Safe-compatible" into "canonical Safe" on their own.
    function _logAccepted(address subject, address ownerAddr, string memory label, MofN memory cfg)
        private
        view
    {
        console.log(string.concat("  [gov-gate] ", label, " owner is Safe-compatible M-of-N:"), ownerAddr);
        console.log("  [gov-gate]   getThreshold()     :", cfg.threshold);
        console.log("  [gov-gate]   getOwners().length :", cfg.ownerCount);
        console.log("  [gov-gate]   criterion          : code, not 0xef0100, threshold>=2, owners>=threshold, distinct");
        console.log("  [gov-gate]   NOT proven         : that this is a canonical Gnosis Safe (no");
        console.log("  [gov-gate]                        runtime-codehash / factory allowlist exists yet)");
        _logOwners(ownerAddr, cfg.ownerCount);
        console.log("  [gov-gate] subject:", subject);
    }

    function _logOwners(address ownerAddr, uint256 ownerCount) private view {
        (bool ok, bytes memory ret) = ownerAddr.staticcall(abi.encodeCall(ISafeCompatibleMofN.getOwners, ()));
        if (!ok) return; // unreachable: readMofN already decoded it
        address[] memory owners = abi.decode(ret, (address[]));
        for (uint256 i = 0; i < ownerCount && i < owners.length; ++i) {
            console.log("  [gov-gate]   owner:", owners[i]);
        }
    }

    /// @dev "GOVERNANCE_OWNER was never declared" and "GOVERNANCE_OWNER was declared and is
    ///      wrong" used to be indistinguishable — both simply landed on the gate. They are
    ///      different operator mistakes with different fixes, so they get different text.
    function _declarationHint() private view returns (string memory) {
        address declared = declaredGovernanceOwner();
        if (declared == address(0)) {
            return " GOVERNANCE_OWNER is NOT SET: this deployment never named a governance owner"
                " at all. Set it to the Safe before deploying, not after.";
        }
        return " GOVERNANCE_OWNER is set, but the owner above is not it (or the transfer did not"
            " land) -- compare the two before re-running.";
    }

    /// @dev staticcall returning EXACTLY one uint256 word. Anything else is a refusal, not
    ///      a value: a revert, empty returndata (the shape a call to an EOA produces) and a
    ///      wide proxy answer are all "this address did not answer the question asked".
    function _staticUint(address target, bytes memory callData)
        private
        view
        returns (bool ok, uint256 value)
    {
        (bool s, bytes memory ret) = target.staticcall(callData);
        if (!s || ret.length != 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev staticcall returning a CANONICALLY encoded, distinct, non-zero `address[]`.
    ///      Hand-decoded rather than `abi.decode`d because the failure modes are the point:
    ///      a non-canonical head offset, a length that does not match the returndata, a
    ///      dirty upper-96-bits word and a duplicate owner all have to be REFUSALS, and
    ///      `abi.decode` accepts or reverts unhelpfully on several of them.
    function _staticAddressArray(address target, bytes memory callData)
        private
        view
        returns (bool ok, uint256 count)
    {
        (bool s, bytes memory ret) = target.staticcall(callData);
        if (!s || ret.length < 64) return (false, 0);

        uint256 offset;
        uint256 n;
        assembly {
            offset := mload(add(ret, 32))
            n := mload(add(ret, 64))
        }
        if (offset != 32) return (false, 0); // non-canonical head
        if (n == 0 || n > MAX_GOVERNANCE_OWNERS) return (false, 0);
        if (ret.length != 64 + 32 * n) return (false, 0); // exact width, no padding games

        address[] memory owners = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 word;
            assembly {
                word := mload(add(ret, add(96, mul(32, i))))
            }
            if (word >> 160 != 0) return (false, 0); // dirty address word
            if (word == 0) return (false, 0); // address(0) is not an owner
            address o = address(uint160(word));
            for (uint256 j = 0; j < i; ++j) {
                if (owners[j] == o) return (false, 0); // duplicate inflates N for free
            }
            owners[i] = o;
        }
        return (true, n);
    }

    /// @dev The same testnet list `DeployLive` uses for its ERC-8004 constants:
    ///      Sepolia, OP Sepolia, Base Sepolia, Arbitrum Sepolia, Polygon Amoy.
    function _isKnownTestnet(uint256 chainId) private pure returns (bool) {
        return chainId == 11155111 || chainId == 11155420 || chainId == 84532 || chainId == 421614
            || chainId == 80002;
    }
}
