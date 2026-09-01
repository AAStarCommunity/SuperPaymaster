// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GovernanceOwnerGate} from "../../script/checks/GovernanceOwnerGate.sol";

/// @notice A Safe-COMPATIBLE M-of-N owner: 2-of-3. This is what the gate accepts, and the
///         only thing it claims to have proven.
contract SafeCompatibleStub {
    uint256 private _threshold;
    address[] private _owners;

    constructor(uint256 threshold_, address[] memory owners_) {
        _threshold = threshold_;
        _owners = owners_;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }
}

/// @notice Round-6's blind spot #1: a contract that owns nothing but a single hot key.
///         `code.length > 0` accepted it and printed "owner is a contract (Safe/Timelock)".
contract OneOfOneForwarderStub {
    address private immutable HOT_KEY;

    constructor(address hotKey) {
        HOT_KEY = hotKey;
    }

    function getThreshold() external pure returns (uint256) {
        return 1;
    }

    function getOwners() external view returns (address[] memory owners) {
        owners = new address[](1);
        owners[0] = HOT_KEY;
    }
}

/// @notice A contract with NO governance surface at all — the shape `code.length > 0`
///         could never tell apart from a Safe.
contract OpaqueContractStub {
    uint256 private _filler = 1;
}

/// @notice Answers both selectors with attacker-chosen RAW bytes, so every malformed
///         encoding the gate must refuse can be produced exactly.
contract RawAnswerStub {
    bytes private _thresholdRet;
    bytes private _ownersRet;
    bool private _revertThreshold;
    bool private _revertOwners;

    function setThreshold(bytes memory ret, bool doRevert) external {
        _thresholdRet = ret;
        _revertThreshold = doRevert;
    }

    function setOwners(bytes memory ret, bool doRevert) external {
        _ownersRet = ret;
        _revertOwners = doRevert;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        bytes4 sel = bytes4(data);
        if (sel == bytes4(keccak256("getThreshold()"))) {
            require(!_revertThreshold, "no");
            return _thresholdRet;
        }
        if (sel == bytes4(keccak256("getOwners()"))) {
            require(!_revertOwners, "no");
            return _ownersRet;
        }
        return "";
    }
}

/// @notice A TimelockController-shaped owner: `getMinDelay()` only, no M-of-N surface.
contract TimelockStub {
    uint256 private immutable MIN_DELAY;

    constructor(uint256 minDelay) {
        MIN_DELAY = minDelay;
    }

    function getMinDelay() external view returns (uint256) {
        return MIN_DELAY;
    }
}

/**
 * @title CC48GovernanceOwnerGate
 * @notice CC-48 round-7 HIGH-1. `emergencyDisarmFraudProofVerifier()` is immediate and
 *         unannounced: an EOA owner can censor every FUTURE guardian-slash accusation by
 *         front-running a watcher's `queueGuardianSlash` out of the mempool, for one
 *         transaction's gas each time. A TimelockController cannot cover that path (a
 *         timelocked emergency stop is not an emergency stop), so an M-of-N owner is the
 *         ONLY governance defence there.
 *
 *         Round 6 enforced `code.length > 0` while its NatSpec, revert strings and the
 *         round-6 document all told downstream consumers that a Safe multisig had been
 *         REQUIRED. Two addresses that are one private key each passed it: an EIP-7702
 *         delegated EOA (23 bytes of code, the key still signs everything) and a 1-of-1
 *         forwarder. The property under test is therefore not "an EOA is refused" — that
 *         already held — but "everything that is functionally one key is refused, and what
 *         the gate PRINTS is exactly what it proved".
 */
contract CC48GovernanceOwnerGate is Test {
    uint256 internal constant ANVIL = 31337;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant OP_MAINNET = 10;
    uint256 internal constant ETH_MAINNET = 1;

    address internal eoaOwner = address(0xE0A);
    address internal delegatedEoa = address(0xDE1E6A7E);
    address internal safe; //     2-of-3, the accepted shape
    address internal oneOfOne; // 1-of-1 forwarder
    address internal opaque; //   a contract with no governance surface
    address internal subject = address(0x5AB1EC7);

    function setUp() public {
        address[] memory owners = new address[](3);
        owners[0] = address(0xA11CE);
        owners[1] = address(0xB0B);
        owners[2] = address(0xCA401);
        safe = address(new SafeCompatibleStub(2, owners));
        oneOfOne = address(new OneOfOneForwarderStub(address(0x407)));
        opaque = address(new OpaqueContractStub());

        // EIP-7702 delegation designator: 0xef0100 || address, exactly 23 bytes. This is
        // what one self-signed SET_CODE transaction gives any EOA on any post-Pectra chain.
        vm.etch(delegatedEoa, abi.encodePacked(hex"ef0100", address(0xDE1E6A7E00)));
        assertEq(delegatedEoa.code.length, 23, "designator must be 23 bytes");
    }

    /// @dev `vm.setEnv` mutates the PROCESS environment, and forge runs `setUp` once per
    ///      contract and then replays an EVM snapshot — so env writes leak forwards between
    ///      tests while EVM state does not. Every test that depends on an acknowledgement
    ///      therefore sets it explicitly rather than trusting a shared default.
    function _ack(bool on) internal {
        vm.setEnv("TESTNET_EOA_OWNER_ACK", on ? "true" : "false");
    }

    function _localAck(bool on) internal {
        vm.setEnv("LOCAL_DEV_GOVERNANCE_ACK", on ? "true" : "false");
    }

    function _declared(address a) internal {
        vm.setEnv("GOVERNANCE_OWNER", vm.toString(a));
    }

    // =================================================================
    // Everything that depends on an ENVIRONMENT VARIABLE lives in ONE test
    // =================================================================

    /// @notice The gate reads `TESTNET_EOA_OWNER_ACK`, `LOCAL_DEV_GOVERNANCE_ACK` and
    ///         `GOVERNANCE_OWNER` from the PROCESS environment, and `forge` runs the test
    ///         functions of a contract IN PARALLEL. `vm.setEnv` is therefore a shared
    ///         mutable global across those threads: split across several test functions,
    ///         these cases fail in a different combination on every run (observed while
    ///         writing them — two consecutive runs, two different failure sets). They are
    ///         one function so the sequence is the sequence, not a race.
    ///
    ///         Every section restates the full environment rather than inheriting it, so
    ///         reordering a section cannot silently change what it proves.
    function test_GateBehaviourAcrossChainsAndOwnerShapes() public {
        // ---------------------------------------------------------------
        // The two shapes round 6 accepted and should not have
        // ---------------------------------------------------------------

        // An EIP-7702 delegated EOA is one private key with 23 bytes of code in front of
        // it. Round 6 read `code.length > 0`, passed it, and logged "owner is a contract
        // (Safe/Timelock)" — on the one path the document calls the ONLY governance
        // defence. Refused here even with the testnet ack sitting in the environment.
        _ack(true);
        _declared(safe);
        vm.chainId(ETH_MAINNET);
        (bool ok, string memory reason) = _tryGate(subject, delegatedEoa, "BLSAggregator");
        assertFalse(ok, "a delegated EOA must never pass on a production chain");
        assertTrue(_contains(reason, "EIP-7702 DELEGATED EOA"), "the failure must name what it found");

        // ...and the migration gate refuses it on a testnet too, where the ack does exist.
        vm.chainId(SEPOLIA);
        (ok, reason) = _tryStrictGate(subject, delegatedEoa, "BLSAggregator");
        assertFalse(ok, "the migration gate has no acknowledgement at all");
        assertTrue(_contains(reason, "EIP-7702 DELEGATED EOA"), "reason names the 7702 designator");

        // A 1-of-1 "multisig" is one hot key wearing a contract's address. It implements
        // the whole Safe interface honestly, which is exactly why an interface check alone
        // is not enough and the THRESHOLD is asserted.
        _ack(true);
        _declared(safe);
        vm.chainId(ETH_MAINNET);
        (ok, reason) = _tryGate(subject, oneOfOne, "BLSAggregator");
        assertFalse(ok, "1-of-1 is one key");
        assertTrue(_contains(reason, "threshold < 2"), "reason names the threshold, not just 'not a Safe'");

        // A contract with no governance surface at all — the exact thing `code.length > 0`
        // could never distinguish from a Safe.
        (ok, reason) = _tryGate(subject, opaque, "BLSAggregator");
        assertFalse(ok, "code alone is not governance");
        assertTrue(_contains(reason, "getThreshold()"), "reason names the missing method");

        // A TimelockController does NOT satisfy this gate, and must not: it cannot cover an
        // immediate disarm. (Registry may still be Timelock-owned; see the Timelock test.)
        address timelock = address(new TimelockStub(2 days));
        (ok, reason) = _tryGate(subject, timelock, "BLSAggregator");
        assertFalse(ok, "a timelocked emergency stop is not an emergency stop");
        assertTrue(_contains(reason, "getThreshold()"), "reason names the missing M-of-N surface");

        // ---------------------------------------------------------------
        // The accepted shape
        // ---------------------------------------------------------------

        // The gate is not "always reverts off anvil": a real 2-of-3 passes.
        _ack(false);
        _declared(safe);
        vm.chainId(ETH_MAINNET);
        (ok,) = _tryGate(subject, safe, "BLSAggregator");
        assertTrue(ok, "a Safe-compatible 2-of-3 is what the gate exists to require");

        // ---------------------------------------------------------------
        // Messages: the gate may not claim more than it proved
        // ---------------------------------------------------------------

        // "not declared" and "declared but the transfer did not land" are different
        // operator mistakes with different fixes, so they get different text.
        _ack(true);
        _declared(address(0));
        vm.chainId(ETH_MAINNET);
        (ok, reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok);
        assertTrue(_contains(reason, "GOVERNANCE_OWNER is NOT SET"), "an undeclared owner says so");

        // Same missing declaration, but the owner is ALREADY a Safe. Reviewing #404,
        // pr-daemon read this state as one where the gate PASSES -- which would make a
        // `declaredGovernanceOwner() != 0` guard around a second gate a real hole. It
        // does not pass: the gate proves "this is the Safe the operator declared", not
        // "this is a Safe", so an undeclared owner is refused whatever shape it has.
        // The existing coverage above only had the EOA case, which is why neither of us
        // could point at this one.
        (ok, reason) = _tryGate(subject, safe, "BLSAggregator");
        assertFalse(ok, "a Safe owner does not excuse a missing declaration");
        assertTrue(_contains(reason, "is NOT SET"), "and the reason names the variable");

        // Declared-and-not-landed reads differently from never-declared. On a PRODUCTION
        // chain an EOA owner is refused for being an EOA first, so this is the hint text,
        // not the round-8 binding check -- the binding check is asserted below, on the one
        // path where the owner would otherwise have been let through.
        _declared(safe);
        (ok, reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok);
        assertTrue(
            _contains(reason, "IS set -- so either the ownership transfer did not land"),
            "a transfer that did not land says so"
        );

        // A 2-of-3 stub is NOT a canonical Gnosis Safe, and no message may say it is.
        _ack(false);
        _declared(safe);
        (ok, reason) = _tryGate(subject, oneOfOne, "BLSAggregator");
        assertFalse(ok);
        assertTrue(_contains(reason, "Safe-compatible M-of-N"), "the requirement is named precisely");
        assertFalse(_contains(reason, "is a Safe multisig"), "no message may assert canonicity");

        // ---------------------------------------------------------------
        // Testnets: allowed, but only via an explicit, named acknowledgement
        // ---------------------------------------------------------------

        _ack(false);
        _declared(safe);
        vm.chainId(SEPOLIA);
        (ok, reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "default on a testnet is still refusal");
        assertTrue(_contains(reason, "TESTNET_EOA_OWNER_ACK=true"), "the failure names the one way to proceed");

        // With the acknowledgement set, the RepCredit / CC-89 E2E stacks can still run.
        // This exception exists so the gate is not simply commented out by the next
        // operator who needs a hot owner for an experiment. Round-8 LOW-2: such a stack
        // declares NO governance owner -- that is the honest statement of what it is -- so
        // the declaration is cleared here rather than inherited from the section above.
        _ack(true);
        _declared(address(0));
        (ok,) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok, "acknowledged experiment deployments may proceed");

        // ...and it covers a 7702 smart-EOA wallet too, but only on a testnet, and only
        // while the log says out loud what it is.
        (ok,) = _tryGate(subject, delegatedEoa, "BLSAggregator");
        assertTrue(ok, "an acknowledged experiment stack may use a smart-EOA wallet");

        // CC-48 round-8 LOW-2 -- THE path where the binding actually bites. Round 7 let
        // this through: GOVERNANCE_OWNER names a Safe, the transfer silently did not land,
        // TESTNET_EOA_OWNER_ACK waves the resulting EOA owner past the gate, and the
        // deployment transcript names a Safe that owns nothing.
        _declared(safe);
        (ok, reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "an acknowledged hot key may not CONTRADICT its own declaration");
        assertTrue(_contains(reason, "round-8 LOW-2"), "the refusal is the declaration binding");
        assertTrue(_contains(reason, "was declared, but"), "and it says what does not match");

        // Declaring nothing is still the honest way to run an experiment stack.
        _declared(address(0));
        (ok,) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok, "an experiment that declares no governance owner is unaffected");

        // The MIGRATION gate is not unlockable by that env var at all.
        _ack(true);
        _declared(safe);
        vm.chainId(SEPOLIA);
        (ok, reason) = _tryStrictGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "the migration gate must not be unlockable by an env var");
        assertTrue(_contains(reason, "Safe-compatible M-of-N"), "reason names the requirement");

        (ok,) = _tryStrictGate(subject, safe, "BLSAggregator");
        assertTrue(ok, "a Safe-owned aggregator migrates normally");

        (ok,) = _tryStrictGate(subject, oneOfOne, "BLSAggregator");
        assertFalse(ok, "and a 1-of-1 does not become acceptable just because it is strict");

        // ---------------------------------------------------------------
        // Local chain: no longer an unconditional no-op (round-7 LOW-4)
        // ---------------------------------------------------------------

        // `anvil --fork-url <mainnet>` reports chainid 31337. Round 6 skipped the gate
        // there unconditionally, so a fork rehearsal of a production chain "passed" a gate
        // that had never executed. The skip now needs a human to type it.
        _localAck(false);
        _ack(false);
        _declared(address(0));
        vm.chainId(ANVIL);
        (ok, reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "31337 must not be a silent no-op");
        assertTrue(_contains(reason, "LOCAL_DEV_GOVERNANCE_ACK=true"), "the failure names the ack");
        assertTrue(_contains(reason, "fork-url"), "and warns about the mainnet-fork case explicitly");

        (ok,) = _tryStrictGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "the strict gate skips on 31337 too, so it needs the same ack");

        _localAck(true);
        (ok,) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok, "acknowledged local development is unchanged");
        (ok,) = _tryStrictGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok, "including the migration gate");

        // ---------------------------------------------------------------
        // CC-48 round-8 LOW-1: the ack alone no longer buys the skip
        // ---------------------------------------------------------------

        // Round 7 required a typed ack, then had `deploy-core anvil` type it for the
        // operator on every run -- so on the one path that matters (`anvil --fork-url` of a
        // live chain, which also reports 31337) nobody acknowledged anything. The gate now
        // carries the POSITIVE half itself: a node whose head block is far above anything a
        // fresh anvil reaches is a FORK, and the local skip does not apply to it no matter
        // who set the ack.
        _localAck(true);
        _ack(false);
        _declared(address(0));
        vm.chainId(ANVIL);
        vm.roll(GovernanceOwnerGate.LOCAL_FRESH_BLOCK_CEILING);
        (ok, reason) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "a fork-shaped 31337 node must not skip the gate even WITH the ack");
        assertTrue(_contains(reason, "round-8 LOW-1"), "the failure names the round-8 rule");
        assertTrue(_contains(reason, "FORK"), "and says what it thinks the node is");

        (ok,) = _tryStrictGate(subject, eoaOwner, "BLSAggregator");
        assertFalse(ok, "the strict gate refuses the same fork-shaped node");

        // One block below the ceiling still skips, so an ordinary local run is unaffected.
        vm.roll(GovernanceOwnerGate.LOCAL_FRESH_BLOCK_CEILING - 1);
        (ok,) = _tryGate(subject, eoaOwner, "BLSAggregator");
        assertTrue(ok, "a fresh local node is still a skip");

        // ---------------------------------------------------------------
        // CC-48 round-8 LOW-2: GOVERNANCE_OWNER is binding, not decorative
        // ---------------------------------------------------------------

        vm.roll(1);
        _ack(false);
        vm.chainId(ETH_MAINNET);

        // Undeclared + an owner that satisfies the interface: round 7 ACCEPTED this, so
        // deployment evidence could name a governance owner nobody ever chose.
        _declared(address(0));
        (ok, reason) = _tryGate(subject, safe, "BLSAggregator");
        assertFalse(ok, "an M-of-N owner may not be accepted while nothing was declared");
        assertTrue(_contains(reason, "is NOT SET"), "the failure says the declaration is missing");
        assertTrue(_contains(reason, "GOVERNANCE_OWNER"), "and names the variable to set");

        // Declared as some OTHER address while the live owner is a valid M-of-N: also
        // refused. This is the shape "the transfer did not land" takes when the address it
        // did not land on is itself a Safe.
        _declared(address(0xDECAF));
        (ok, reason) = _tryGate(subject, safe, "BLSAggregator");
        assertFalse(ok, "a mismatched declaration is refused even when the owner is valid");
        assertTrue(_contains(reason, "was declared, but"), "the failure is the binding check");

        // Declared correctly: accepted, as before.
        _declared(safe);
        (ok,) = _tryGate(subject, safe, "BLSAggregator");
        assertTrue(ok, "a declared, matching, Safe-compatible M-of-N owner is the accepted case");

        // The strict (migration) gate is held to the same binding.
        _declared(address(0));
        (ok, reason) = _tryStrictGate(subject, safe, "BLSAggregator");
        assertFalse(ok, "the migration gate also refuses an undeclared M-of-N owner");
        assertTrue(_contains(reason, "is NOT SET"), "and says why");

        // A NAMED declaration variable is honoured and appears verbatim in the message,
        // so the migration can bind Registry and the aggregator to two different Safes.
        vm.setEnv("REGISTRY_GOVERNANCE_OWNER", vm.toString(safe));
        (ok,) = _tryStrictGateDeclaredAs(subject, safe, "Registry", "REGISTRY_GOVERNANCE_OWNER");
        assertTrue(ok, "a per-subject declaration satisfies the gate for that subject");

        // A wrong per-subject declaration refuses the subject EVEN THOUGH the default
        // `GOVERNANCE_OWNER` is set and correct -- proof that the named variable is what
        // was read, not a silent fallback to the default.
        _declared(safe);
        vm.setEnv("REGISTRY_GOVERNANCE_OWNER", vm.toString(address(0xDECAF)));
        (ok, reason) = _tryStrictGateDeclaredAs(subject, safe, "Registry", "REGISTRY_GOVERNANCE_OWNER");
        assertFalse(ok, "a wrong per-subject declaration refuses the subject");
        assertTrue(_contains(reason, "REGISTRY_GOVERNANCE_OWNER was declared"), "and names that variable");
        assertTrue(_contains(reason, "Registry.owner()"), "and the subject it belongs to");

        // Sanity check that the two variables really are independent: the SAME owner
        // passes under the default variable at the same moment it fails under the named one.
        (ok,) = _tryStrictGate(subject, safe, "BLSAggregator");
        assertTrue(ok, "the default variable is unaffected by the named one being wrong");
        vm.setEnv("REGISTRY_GOVERNANCE_OWNER", "");
    }

    /// CC-48 round-8 MEDIUM-2. The wording rule this repo set for itself is asserted
    /// against the SOURCE FILES, not just against the gate's own revert strings.
    ///
    /// `GovernanceOwnerGate`'s NatSpec says "every message, log line and document in this
    /// repo must say 'Safe-compatible M-of-N', never 'is a Safe'" — and then
    /// `BLSAggregator.sol`, the file `repo:dvt` and `repo:sdk` actually read, kept six
    /// lines asserting the owner "MUST be a Safe multisig" and that the gate "enforces the
    /// multisig". Two consecutive independent reviews had to find that by grepping. The
    /// grep is now a test.
    ///
    /// Scope: the three files that carry the CC-48 governance threat model. Unrelated
    /// operational notes elsewhere ("hand it to the multisig post-deploy") are not claims
    /// about what an on-chain check proves and are deliberately out of scope.
    function test_NoSourceFileClaimsTheGateProvesACanonicalSafe() public view {
        string[3] memory files = [
            "contracts/src/modules/monitoring/BLSAggregator.sol",
            "contracts/script/checks/GovernanceOwnerGate.sol",
            "contracts/script/v3/UpgradeRegistryTo580.s.sol"
        ];
        // Phrases that assert canonicity, or assert that an on-chain check established it.
        string[4] memory banned =
            ["Safe multisig", "enforces the multisig", "is a Safe multisig", "must be a Safe."];

        for (uint256 i = 0; i < files.length; ++i) {
            string memory src = vm.readFile(files[i]);
            for (uint256 j = 0; j < banned.length; ++j) {
                assertFalse(
                    _contains(src, banned[j]),
                    string.concat(files[i], " must not claim canonicity: ", banned[j])
                );
            }
            // ...and each of them must still state the property that IS proven, so the
            // rule cannot be satisfied by deleting the threat model instead of fixing it.
            assertTrue(
                _contains(src, "Safe-compatible M-of-N") || _contains(src, "Safe-COMPATIBLE M-of-N"),
                string.concat(files[i], " must state the property the gate actually proves")
            );
        }
    }

    // =================================================================
    // Env-free properties — safe to run in parallel
    // =================================================================

    /// The classifier itself, stated as a property: 23 bytes starting 0xef0100 is a
    /// delegation designator; anything else of that length is ordinary code.
    function test_OwnerKindClassifiesDelegationDesignatorsExactly() public {
        assertTrue(
            GovernanceOwnerGate.ownerKind(eoaOwner) == GovernanceOwnerGate.OwnerKind.Eoa, "no code -> Eoa"
        );
        assertTrue(
            GovernanceOwnerGate.ownerKind(delegatedEoa) == GovernanceOwnerGate.OwnerKind.Delegated7702,
            "0xef0100 || address -> Delegated7702"
        );
        assertTrue(
            GovernanceOwnerGate.ownerKind(safe) == GovernanceOwnerGate.OwnerKind.Contract, "Safe -> Contract"
        );

        // 23 bytes that are NOT a designator must classify as ordinary code: the check is
        // prefix-AND-length, not length alone.
        //   (An 0xef01-prefixed body cannot be constructed here at all -- forge's `vm.etch`
        //    parses any 0xef01 code as a delegation designator and rejects unknown versions
        //    outright, which is itself evidence that the prefix is reserved.)
        address tiny = address(0x7177);
        vm.etch(tiny, hex"60016000526001601ff360016000526001601ff3601160");
        assertEq(tiny.code.length, 23, "fixture must be exactly designator-length");
        assertTrue(
            GovernanceOwnerGate.ownerKind(tiny) == GovernanceOwnerGate.OwnerKind.Contract,
            "23 bytes without the 0xef0100 prefix is ordinary code"
        );
    }

    /// The configuration the gate reads is the configuration it must log as evidence.
    function test_ReadMofNReportsTheConfigurationItAccepted() public view {
        (bool ok, GovernanceOwnerGate.MofN memory cfg,) = GovernanceOwnerGate.readMofN(safe);
        assertTrue(ok);
        assertEq(cfg.threshold, 2, "threshold is reported, not just checked");
        assertEq(cfg.ownerCount, 3, "owner count is reported, not just checked");
    }

    /// Boundary: threshold == owners.length is a legitimate N-of-N Safe and must pass;
    /// threshold > owners.length is unsatisfiable and must not.
    function test_ThresholdBoundaries() public {
        address[] memory two = new address[](2);
        two[0] = address(0xA11CE);
        two[1] = address(0xB0B);

        (bool ok,,) = GovernanceOwnerGate.readMofN(address(new SafeCompatibleStub(2, two)));
        assertTrue(ok, "2-of-2 is a real multisig");

        string memory why;
        (ok,, why) = GovernanceOwnerGate.readMofN(address(new SafeCompatibleStub(3, two)));
        assertFalse(ok, "3-of-2 can never sign");
        assertTrue(_contains(why, "owners.length < threshold"), "reason names the inconsistency");

        (ok,, why) = GovernanceOwnerGate.readMofN(oneOfOne);
        assertFalse(ok, "1-of-1 is one key");
        assertTrue(_contains(why, "threshold < 2"), "reason names the threshold");
    }

    // =================================================================
    // Malformed / hostile answers: exact decode, fail closed
    // =================================================================

    /// Every one of these is a shape a fake produces. None may be read as a valid M-of-N.
    function test_MalformedAnswersAreAllRefused() public {
        address[] memory three = new address[](3);
        three[0] = address(0xA11CE);
        three[1] = address(0xB0B);
        three[2] = address(0xCA401);
        bytes memory goodOwners = abi.encode(three);
        bytes memory goodThreshold = abi.encode(uint256(2));

        // 1. getThreshold() reverts.
        RawAnswerStub s = new RawAnswerStub();
        s.setThreshold("", true);
        s.setOwners(goodOwners, false);
        _assertRefused(address(s), "getThreshold()", "reverting getThreshold");

        // 2. getThreshold() answers with empty returndata — the shape a call to an EOA has.
        s = new RawAnswerStub();
        s.setThreshold("", false);
        s.setOwners(goodOwners, false);
        _assertRefused(address(s), "getThreshold()", "empty getThreshold");

        // 3. getThreshold() answers WIDE (64 bytes) — a proxy delegating elsewhere.
        s = new RawAnswerStub();
        s.setThreshold(abi.encode(uint256(2), uint256(0)), false);
        s.setOwners(goodOwners, false);
        _assertRefused(address(s), "getThreshold()", "wide getThreshold");

        // 4. getOwners() reverts.
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners("", true);
        _assertRefused(address(s), "getOwners()", "reverting getOwners");

        // 5. getOwners() head offset is non-canonical (0x40 instead of 0x20).
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners(
            abi.encodePacked(uint256(0x40), uint256(0), uint256(3), three[0], three[1], three[2]), false
        );
        _assertRefused(address(s), "getOwners()", "non-canonical offset");

        // 6. getOwners() length claims 3 but only 2 words follow.
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners(abi.encodePacked(uint256(0x20), uint256(3), three[0], three[1]), false);
        _assertRefused(address(s), "getOwners()", "length/returndata mismatch");

        // 7. getOwners() element has dirty upper bits — not an address.
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners(
            abi.encodePacked(
                uint256(0x20), uint256(2), uint256(type(uint256).max), uint256(uint160(three[1]))
            ),
            false
        );
        _assertRefused(address(s), "getOwners()", "dirty address word");

        // 8. getOwners() pads N with duplicates — free N inflation against threshold.
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners(
            abi.encodePacked(
                uint256(0x20), uint256(2), uint256(uint160(three[0])), uint256(uint160(three[0]))
            ),
            false
        );
        _assertRefused(address(s), "getOwners()", "duplicate owners");

        // 9. getOwners() pads N with address(0).
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners(
            abi.encodePacked(uint256(0x20), uint256(2), uint256(uint160(three[0])), uint256(0)), false
        );
        _assertRefused(address(s), "getOwners()", "zero owner");

        // 10. getOwners() is empty.
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners(abi.encodePacked(uint256(0x20), uint256(0)), false);
        _assertRefused(address(s), "getOwners()", "empty owner set");

        // 11. getOwners() returns more owners than the bound — refused, never truncated.
        uint256 n = GovernanceOwnerGate.MAX_GOVERNANCE_OWNERS + 1;
        bytes memory huge = abi.encodePacked(uint256(0x20), n);
        for (uint256 i = 0; i < n; ++i) {
            huge = abi.encodePacked(huge, uint256(uint160(uint256(1000 + i))));
        }
        s = new RawAnswerStub();
        s.setThreshold(goodThreshold, false);
        s.setOwners(huge, false);
        _assertRefused(address(s), "getOwners()", "oversized owner set");
    }

    function _assertRefused(address ownerAddr, string memory expectInReason, string memory what)
        internal
    {
        (bool ok,, string memory why) = GovernanceOwnerGate.readMofN(ownerAddr);
        assertFalse(ok, string.concat("must refuse: ", what));
        assertTrue(_contains(why, expectInReason), string.concat("reason must name the method: ", what));
    }

    // =================================================================
    // Registry may be Timelock-owned; the aggregator may not
    // =================================================================

    /// `Registry.setCreditPolicy` is immediate `onlyOwner`. If the answer to "who owns
    /// Registry" is "a Timelock", the evidence has to show the Timelock imposes a delay AND
    /// is actually the owner — `scheduleBatch` calldata proves neither.
    function test_TimelockGateAssertsBothOwnershipAndANonZeroDelay() public {
        vm.chainId(SEPOLIA);
        address timelock = address(new TimelockStub(2 days));
        address zeroDelay = address(new TimelockStub(0));

        (bool ok,) = _tryTimelockGate(subject, timelock, timelock, "Registry");
        assertTrue(ok, "owner == timelock and getMinDelay() > 0 is the accepted shape");

        string memory reason;
        (ok, reason) = _tryTimelockGate(subject, address(0xE0A), timelock, "Registry");
        assertFalse(ok, "a Timelock that does not own Registry cannot execute the batch");
        assertTrue(_contains(reason, "is a different address"), "reason names the mismatch");

        (ok, reason) = _tryTimelockGate(subject, zeroDelay, zeroDelay, "Registry");
        assertFalse(ok, "a zero-delay Timelock makes setCreditPolicy immediate again");
        assertTrue(_contains(reason, "NON-ZERO delay"), "reason names the delay");

        // A Safe is not a Timelock: no getMinDelay, so declaring TIMELOCK=<safe> fails
        // rather than silently passing on the interface it happens to share.
        (ok, reason) = _tryTimelockGate(subject, safe, safe, "Registry");
        assertFalse(ok, "TIMELOCK must actually be a Timelock");
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

    function _tryTimelockGate(address s, address ownerAddr, address timelock, string memory label)
        internal
        returns (bool ok, string memory reason)
    {
        try this.callTimelockGate(s, ownerAddr, timelock, label) {
            return (true, "");
        } catch Error(string memory r) {
            return (false, r);
        }
    }

    function _tryStrictGateDeclaredAs(
        address s,
        address ownerAddr,
        string memory label,
        string memory declEnv
    ) internal returns (bool ok, string memory reason) {
        try this.callStrictGateDeclaredAs(s, ownerAddr, label, declEnv) {
            return (true, "");
        } catch Error(string memory r) {
            return (false, r);
        }
    }

    function callStrictGateDeclaredAs(
        address s,
        address ownerAddr,
        string memory label,
        string memory declEnv
    ) external view {
        GovernanceOwnerGate.requireGovernanceOwnerStrictDeclaredAs(s, ownerAddr, label, declEnv);
    }

    function callGate(address s, address ownerAddr, string memory label) external view {
        GovernanceOwnerGate.requireGovernanceOwner(s, ownerAddr, label);
    }

    function callStrictGate(address s, address ownerAddr, string memory label) external view {
        GovernanceOwnerGate.requireGovernanceOwnerStrict(s, ownerAddr, label);
    }

    function callTimelockGate(address s, address ownerAddr, address timelock, string memory label)
        external
        view
    {
        GovernanceOwnerGate.requireTimelockOwner(s, ownerAddr, timelock, label);
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
