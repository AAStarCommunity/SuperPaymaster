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
 *        • `LOCAL_DEV_GOVERNANCE_ACK=true` — chainid 31337 only, AND only on a node that
 *          passes a POSITIVE freshness judgement (`block.number < LOCAL_FRESH_BLOCK_CEILING`).
 *          Round 6 made 31337 an unconditional no-op and `anvil --fork-url <mainnet>`
 *          reports 31337, so a mainnet-fork rehearsal passed the gate silently. Round 7
 *          made the skip require a typed ack — but `deploy-core anvil` then set that ack
 *          for the operator unconditionally, so on a fork rehearsal driven through this
 *          repo's own tooling NOBODY typed it and the skip was automatic again (round-8
 *          LOW-1). Both halves are now real: the shell entry points only pre-set the ack
 *          after PROBING the node (chain id 31337 and a low head block), and the gate
 *          itself refuses a 31337 node whose head block is above the ceiling no matter
 *          who set the ack.
 *
 * @dev GOVERNANCE_OWNER IS A BINDING DECLARATION, NOT A HINT (CC-48 round-8 LOW-2). Round 7
 *      read `GOVERNANCE_OWNER` only to choose between two failure MESSAGES: unset passed,
 *      and set-to-the-wrong-address passed as long as the actual owner happened to satisfy
 *      the gate. It is now checked:
 *        • declared and NOT equal to the live owner  -> REFUSED on every chain. This is the
 *          "the transfer did not land" case, and it is the one that silently produced an
 *          EOA-owned aggregator on a testnet under `TESTNET_EOA_OWNER_ACK`.
 *        • an owner ACCEPTED as Safe-compatible M-of-N while `GOVERNANCE_OWNER` is unset
 *          -> REFUSED. Deployment evidence has to be reconcilable against a declared
 *          intent; "whatever address ended up owning it satisfied the interface" is not a
 *          governance decision anyone made.
 *      The EOA / 7702 acknowledgement paths still work with no declaration, because those
 *      deployments are declaring the opposite — that there is no governance owner.
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

    /// @dev CC-48 round-8 LOW-1. The POSITIVE half of "this really is a local node".
    ///      `anvil --fork-url <chain>` reports chain id 31337 but inherits the forked
    ///      chain's HEAD BLOCK NUMBER, and every chain this repo targets is far past this
    ///      height (Ethereum ~23M, Sepolia ~9M, OP ~1.4e8). A fresh `anvil` starts at 0 and
    ///      a full `deploy-core anvil` run mines a few hundred blocks, so the gap is four
    ///      orders of magnitude — this is a discriminator, not a coin flip.
    ///
    ///      STATED LIMITATION, because the last three rounds were lost to overstated
    ///      absence proofs: this is a HEURISTIC, not a proof. Forking a chain whose head is
    ///      below the ceiling would still pass, and nothing on-chain can prove a node is
    ///      not a fork. What it does buy is that the realistic mistake — rehearsing against
    ///      a fork of a LIVE chain — can no longer skip the gate, whoever set the ack.
    uint256 internal constant LOCAL_FRESH_BLOCK_CEILING = 1_000_000;

    /// @dev The env var carrying the operator's DECLARED governance owner. Named once so
    ///      the failure text and the binding check can never drift apart.
    string internal constant GOVERNANCE_OWNER_ENV = "GOVERNANCE_OWNER";

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
        _gate(subject, ownerAddr, label, false, GOVERNANCE_OWNER_ENV);
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
        _gate(subject, ownerAddr, label, true, GOVERNANCE_OWNER_ENV);
    }

    /// @notice The strict gate, bound to a NAMED declaration env var rather than the
    ///         default `GOVERNANCE_OWNER`.
    /// @dev    CC-48 round-8 LOW-2. The 5.7.0 migration gates TWO subjects with two
    ///         independent owners — the live `Registry` and the freshly deployed
    ///         `BLSAggregator` — and there is no reason they must be the same Safe. One
    ///         global env var could only bind one of them, so the migration names each
    ///         one's declaration separately and both are checked. `declEnv` appears
    ///         verbatim in every failure message, so an operator is told which variable to
    ///         set, not just that something is undeclared.
    function requireGovernanceOwnerStrictDeclaredAs(
        address subject,
        address ownerAddr,
        string memory label,
        string memory declEnv
    ) internal view {
        _gate(subject, ownerAddr, label, true, declEnv);
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
    /// @dev    Deliberately optional at READ time so local development needs no env var,
    ///         and so a deploy script can tell "hand it to the Safe" from "leave it with
    ///         the deployer". It is NOT optional at GATE time any more (CC-48 round-8
    ///         LOW-2): `_gate` refuses a declared-but-mismatched owner on every path, and
    ///         refuses to ACCEPT an M-of-N owner that was never declared at all.
    function declaredGovernanceOwner() internal view returns (address) {
        return vm.envOr(GOVERNANCE_OWNER_ENV, address(0));
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _gate(
        address subject,
        address ownerAddr,
        string memory label,
        bool strict,
        string memory declEnv
    ) private view {
        if (block.chainid == LOCAL_CHAIN_ID) {
            // CC-48 round-7 LOW-4. `anvil --fork-url <mainnet>` also reports 31337, so an
            // unconditional no-op here let a mainnet-fork rehearsal "pass" a gate that had
            // never run. The distinction is made by a human typing the ack — and it is
            // printed, so a transcript shows the gate was skipped rather than satisfied.
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
            // CC-48 round-8 LOW-1. The ack alone is not enough, because the shell entry
            // points can set it for the operator. This is the POSITIVE half: a fork of a
            // live chain inherits that chain's head block, so it cannot pass here no
            // matter who typed the ack. See LOCAL_FRESH_BLOCK_CEILING for what this
            // heuristic does and does not buy.
            require(
                block.number < LOCAL_FRESH_BLOCK_CEILING,
                string.concat(
                    "CC-48 round-8 LOW-1: chainid is 31337 and LOCAL_DEV_GOVERNANCE_ACK is set,",
                    " but this node's head block is far above anything a fresh anvil reaches --",
                    " it is a FORK of a live chain. The local-development skip does not apply to a",
                    " fork rehearsal: the gate you would be skipping for ",
                    label,
                    " is the one you came to rehearse. Run against a fresh anvil, or point the",
                    " rehearsal at the real chain and satisfy the gate."
                )
            );
            console.log(string.concat("  [gov-gate] SKIPPED on local chain 31337 for ", label), ownerAddr);
            console.log("  [gov-gate] acknowledged via LOCAL_DEV_GOVERNANCE_ACK, and the node's head");
            console.log("  [gov-gate] block is below the fresh-node ceiling. block.number:", block.number);
            console.log("  [gov-gate] Nothing about the owner was verified. This is a HEURISTIC, not");
            console.log("  [gov-gate] a proof that the node is not a fork.");
            return;
        }

        // CC-48 round-8 LOW-2: the declaration is BINDING on every path below, including
        // the acknowledged testnet ones. Read here, ENFORCED at the end of each path —
        // deliberately not up front, so a wrong declaration never masks the more specific
        // diagnosis ("this owner is an EIP-7702 delegated EOA", "threshold < 2"), which is
        // the thing the operator actually has to fix first.
        address declared = vm.envOr(declEnv, address(0));

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
                    " zero-notice emergencyDisarmFraudProofVerifier(). Set ",
                    declEnv,
                    " to the Safe and re-run."
                )
            );
            // CC-48 round-8 LOW-2, both halves, checked before the owner is ACCEPTED.
            _requireDeclarationMatches(declared, ownerAddr, label, declEnv);
            require(
                declared != address(0),
                string.concat(
                    "CC-48 round-8 LOW-2: ",
                    label,
                    " owner satisfies the Safe-compatible M-of-N interface, but ",
                    declEnv,
                    " is NOT SET, so no governance owner was ever declared for this deployment.",
                    " An owner that merely happens to answer getThreshold()/getOwners() is not a",
                    " governance decision anyone made. Set ",
                    declEnv,
                    " to the address you intend to own this contract and re-run."
                )
            );
            _logAccepted(subject, ownerAddr, label, cfg, declEnv);
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
                _declarationHint(declEnv)
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
                _declarationHint(declEnv)
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
                _declarationHint(declEnv)
            )
        );
        // CC-48 round-8 LOW-2: an acknowledged hot-key deployment still may not CONTRADICT
        // its own declaration. "GOVERNANCE_OWNER names the Safe, the transfer did not land,
        // TESTNET_EOA_OWNER_ACK waves the EOA through" is exactly how a stack ends up
        // EOA-owned while its transcript names a Safe. Checked last so the ack messages
        // above still explain the primary problem.
        _requireDeclarationMatches(declared, ownerAddr, label, declEnv);

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
    function _logAccepted(
        address subject,
        address ownerAddr,
        string memory label,
        MofN memory cfg,
        string memory declEnv
    ) private view {
        console.log(string.concat("  [gov-gate] ", label, " owner is Safe-compatible M-of-N:"), ownerAddr);
        console.log("  [gov-gate]   getThreshold()     :", cfg.threshold);
        console.log("  [gov-gate]   getOwners().length :", cfg.ownerCount);
        console.log("  [gov-gate]   criterion          : code, not 0xef0100, threshold>=2, owners>=threshold, distinct");
        // CC-48 round-8 LOW-2: the transcript records that the owner was DECLARED, and
        // under which variable, so the evidence can be reconciled against intent rather
        // than merely against the interface.
        console.log(string.concat("  [gov-gate]   declared via       : ", declEnv, " (checked == owner)"));
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

    /// @dev CC-48 round-8 LOW-2. A declared governance owner that is NOT the live owner is
    ///      a stop condition on every path: either the ownership transfer did not land or
    ///      the declaration is wrong, and in both cases the deployment evidence would name
    ///      an address that does not hold the keys. Round 7 read `GOVERNANCE_OWNER` only to
    ///      choose between two failure MESSAGES, so this case passed whenever the live
    ///      owner happened to satisfy the gate on its own.
    function _requireDeclarationMatches(
        address declared,
        address ownerAddr,
        string memory label,
        string memory declEnv
    ) private pure {
        require(
            declared == address(0) || declared == ownerAddr,
            string.concat(
                "CC-48 round-8 LOW-2: ",
                declEnv,
                " was declared, but ",
                label,
                ".owner() is a DIFFERENT address. Either the ownership transfer did not land or",
                " the declaration is wrong; both are stop conditions, because the deployment",
                " evidence would name an owner that does not hold the keys."
            )
        );
    }

    /// @dev "not declared" and "declared and wrong" used to be indistinguishable — both
    ///      simply landed on the gate. They are different operator mistakes with different
    ///      fixes, so they get different text.
    /// @dev CC-48 round-8 LOW-2 keeps this as the TEXT half only, and makes it accurate in
    ///      all three states. The BINDING half is `_requireDeclarationMatches`, which runs
    ///      at the end of each path so that the owner-shape diagnosis above is never masked
    ///      by a declaration problem the operator would have to fix second.
    function _declarationHint(string memory declEnv) private view returns (string memory) {
        address declared = vm.envOr(declEnv, address(0));
        if (declared == address(0)) {
            return string.concat(
                " ",
                declEnv,
                " is NOT SET: this deployment never named a governance owner at all. Set it to"
                " the Safe before deploying, not after."
            );
        }
        return string.concat(
            " ",
            declEnv,
            " IS set -- so either the ownership transfer did not land, or it landed on an"
            " address that is not the one declared. Compare the two before re-running; a"
            " mismatch is refused outright once the owner-shape problem above is fixed."
        );
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
