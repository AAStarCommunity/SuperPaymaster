// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "src/core/Registry.sol";
import {BLSKeyScanLib} from "../checks/BLSKeyScanLib.sol";
import {GovernanceOwnerGate, IOwned} from "../checks/GovernanceOwnerGate.sol";

interface IAggregatorDomain {
    function REGISTRY() external view returns (address);
    function domainSeparator() external view returns (bytes32);
    function version() external view returns (string memory);
    function DOMAIN_NAME() external view returns (bytes32);
}

interface ITimelockBatch {
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    function getMinDelay() external view returns (uint256);
}

/**
 * @title UpgradeRegistryTo570
 * @notice CC-48 MEDIUM-3: build the ONE governance batch that takes a live Registry
 *         proxy to 5.7.0. All three steps must land in a single transaction.
 *
 *   1. upgradeToAndCall(newImpl, "")
 *   2. setBLSAggregator(BLSAggregator 4.9.0)
 *   3. setCreditPolicy(perProposalCap, totalCap, exposureBaseline, true)
 *
 * Why atomic — each gap is a real, observable outage, not a theoretical one:
 *
 *   - Between (1) and (3) the new `maxTotalCreditExposure` slot reads 0, so EVERY
 *     proposal carrying positive uplift reverts. Fail-closed in the right direction,
 *     but it is a governance halt on the reputation path.
 *   - Between (1) and (2) the still-wired 4.3.x aggregator has no
 *     `consumeGuardianExit`, and BLSAggregator has no fallback, so Registry's call
 *     reverts: every ROLE_DVT `exitRole` fails and DVT stake is temporarily stuck.
 *   - Seeding `exposureBaseline` in the same batch is what stops the protocol-wide
 *     budget from starting at 0 and silently under-counting every pre-upgrade user.
 *
 * CC-48 round-2 migration constraints — read before scheduling:
 *
 *   - BLSAggregator is NOT upgradeable. 4.9.0 is a fresh deployment at a NEW address,
 *     and the domain separator commits to that address, so EVERY in-flight proof
 *     signed against the old aggregator becomes unverifiable the moment step (2)
 *     lands. Drain the proposal queue first; do not schedule the batch while a
 *     reputation or slash proposal is awaiting submission.
 *   - Validator BLS keys do NOT migrate. `blsKeyOwner` and `_blsKeys` are per-contract
 *     state, and a proof-of-possession is now bound to (validator, aggregator, chain),
 *     so every validator must re-file a freshly signed PoP against 4.9.0. Run
 *     contracts/script/checks/ScanDuplicateBLSKeys.s.sol against the OLD aggregator
 *     first: if it reports duplicates, those validators were sharing a key and must
 *     not be re-onboarded with it.
 *   - In-flight guardian-slash cases do NOT migrate either. `guardianSlashCases`,
 *     `pendingGuardianSlashCount` and `guardianExitRequests` all live in the old
 *     contract. Resolve or expire every pending case there before cutting over,
 *     otherwise the freeze it represents is silently lifted. A predecessor that
 *     predates the feature entirely (Sepolia is on `BLSAggregator-4.3.0`, which has
 *     none of those getters) cannot hold a case; the preflight proves that from the
 *     deployed ABI surface and skips ONLY that one check — never the key scan.
 *   - The compromised experiment stack (aggregator 0xc037...1273, slots 1/2/3 holding
 *     the public scalars 1/2/3) must never be a migration source. Its keys are known;
 *     re-registering them anywhere is equivalent to publishing the validator set's
 *     secret. Fresh deployment + fresh randomly generated keys only.
 *
 * The script refuses to emit a non-atomic path: `owner` must be a contract (Safe /
 * TimelockController). That is the CC-48 MEDIUM-1 deployment gate — the fraud-proof
 * verifier now carries an in-contract rotation delay, and the owner of both Registry
 * and BLSAggregator must still sit behind governance, not a hot EOA.
 *
 * CC-48 round-6 HIGH-1: the NEW_BLS_AGGREGATOR's own owner is gated the same way, and
 * for a stronger reason. 4.9.0's `emergencyDisarmFraudProofVerifier()` is immediate and
 * unannounced, so that owner can censor every FUTURE guardian-slash accusation by
 * front-running it in the mempool. A TimelockController cannot cover that path (a
 * timelocked emergency stop is not an emergency stop), which makes the Safe multisig the
 * only governance defence there; the in-contract 4-day delay only governs RE-arming, and
 * already-queued cases are unreachable either way. Both gates are strict outside anvil —
 * a migration rehearsal that runs with an EOA owner rehearses a different system.
 *
 * Env:
 *   REGISTRY_PROXY               live Registry ERC1967 proxy
 *   NEW_BLS_AGGREGATOR           BLSAggregator 4.9.0 (already deployed + wired)
 *   CREDIT_PER_PROPOSAL_CAP      aPNT wei, transaction-level guard
 *   CREDIT_TOTAL_CAP             aPNT wei, protocol-wide outstanding ceiling
 *   CREDIT_EXPOSURE_BASELINE     aPNT wei, sum of existing users' credit limits
 *                                (computed off-chain from GlobalReputationUpdated)
 *   OLD_BLS_AGGREGATOR           predecessor aggregator to preflight. REQUIRED, no
 *                                default, and CHECKED: it must equal
 *                                `Registry.blsAggregator()` as it reads RIGHT NOW.
 *                                0 is accepted only when the live Registry genuinely has
 *                                no aggregator wired — a live migration cannot declare
 *                                itself "first-ever" to make the preflight quiet down
 *                                (CC-48 round-5 HIGH-1).
 *   MIN_DISTINCT_KEYS (optional) override the distinct-active-key floor; defaults to the
 *                                largest threshold the new aggregator itself configures
 *   TIMELOCK (optional)          if set, also print scheduleBatch/executeBatch calldata
 *   ALLOW_EOA_OWNER (optional)   escape hatch, ENFORCED to chainid 31337 only
 *
 * Preflight requires an EIP-2537 (Prague) RPC: the weak-key scan recomputes g1*s and
 * must not be able to report "clean" simply because it could not run.
 */
contract UpgradeRegistryTo570 is Script {
    function run() external {
        address proxy = vm.envAddress("REGISTRY_PROXY");
        address newAggregator = vm.envAddress("NEW_BLS_AGGREGATOR");
        uint256 perProposalCap = vm.envUint("CREDIT_PER_PROPOSAL_CAP");
        uint256 totalCap = vm.envUint("CREDIT_TOTAL_CAP");
        uint256 baseline = vm.envUint("CREDIT_EXPOSURE_BASELINE");

        Registry registry = Registry(proxy);
        address owner = registry.owner();

        console.log("Registry proxy      :", proxy);
        console.log("current version     :", registry.version());
        console.log("current owner       :", owner);

        // ---- governance gate (CC-48 MEDIUM-1 / round-3 MEDIUM-3 / round-6 HIGH-1) ----
        // The escape hatch is chain-bound. Round-2 left it as a comment saying
        // "local/anvil ONLY" with nothing enforcing it, which made the whole
        // "governance owner must be a contract" gate opt-out on ANY chain — including
        // the one it exists to protect. Anvil's 31337 is the only chain that may use it.
        bool allowEoa = vm.envOr("ALLOW_EOA_OWNER", false);
        require(
            !allowEoa || block.chainid == 31337,
            "CC-48: ALLOW_EOA_OWNER is a local-chain (31337) escape hatch only"
        );
        GovernanceOwnerGate.requireGovernanceOwnerStrict(proxy, owner, "Registry");

        // CC-48 round-6 HIGH-1: the aggregator's OWN owner is now a distinct governance
        // question, and until this round nothing checked it. 4.9.0 gave that owner
        // `emergencyDisarmFraudProofVerifier()` — immediate, no notice, and enough to
        // front-run every future `queueGuardianSlash` out of the mempool for one
        // transaction's gas. A Timelock cannot cover an emergency stop, so the Safe
        // multisig is the only governance defence on that path; wiring an EOA-owned
        // aggregator into a live Registry hands one hot key a permanent, silent veto over
        // the entire collusion deterrent. Checked before the batch is emitted, not after.
        GovernanceOwnerGate.requireGovernanceOwnerStrict(
            newAggregator, IOwned(newAggregator).owner(), "BLSAggregator (disarm authority)"
        );

        require(
            totalCap >= baseline,
            "CC-48: totalCap below the seeded baseline would freeze the reputation path on day one"
        );
        require(perProposalCap <= totalCap, "CC-48: per-proposal cap above the protocol ceiling is meaningless");
        require(totalCap > 0, "CC-48: zero protocol ceiling is fail-closed; set a real number");

        // ---- CC-48 round-2: domain wiring gate ----
        // The BLS domain separator commits to BOTH contracts. An aggregator whose
        // immutable REGISTRY is some other address can never agree with this Registry
        // on a pre-image, so wiring it in would halt the reputation path outright.
        // Catch it here, before the batch is scheduled, rather than on-chain after.
        require(
            IAggregatorDomain(newAggregator).REGISTRY() == proxy,
            "CC-48: NEW_BLS_AGGREGATOR is bound to a different Registry; domains can never match"
        );
        require(
            keccak256(bytes(IAggregatorDomain(newAggregator).version())) == keccak256("BLSAggregator-4.9.0"),
            "CC-48: NEW_BLS_AGGREGATOR is not BLSAggregator-4.9.0"
        );

        // Byte-level domain agreement, checked HERE rather than printed for a human to
        // eyeball after the fact. Registry derives its separator independently as
        // keccak256(DOMAIN_NAME, chainid, blsAggregator, address(this)); recompute what
        // it WILL be once step (2) lands and require it to equal the aggregator's own.
        bytes32 expectedRegistrySeparator = keccak256(
            abi.encode(IAggregatorDomain(newAggregator).DOMAIN_NAME(), block.chainid, newAggregator, proxy)
        );
        require(
            expectedRegistrySeparator == IAggregatorDomain(newAggregator).domainSeparator(),
            "CC-48: post-batch Registry domain would not equal the aggregator's; proofs could never verify"
        );

        // ---- CC-48 round-3 MEDIUM-4: validator-set preflight, enforced not suggested ----
        // A fresh 4.9.0 starts with an EMPTY key table. Wiring it in before validators
        // have re-filed their PoPs points every BLS-gated path at an aggregator with no
        // signers — a real governance outage whose fix is another full timelock cycle.
        uint256 requiredKeys = vm.envOr("MIN_DISTINCT_KEYS", BLSKeyScanLib.maxRequiredThreshold(newAggregator));
        BLSKeyScanLib.ScanResult memory newScan = BLSKeyScanLib.requireHealthy(newAggregator, requiredKeys);
        console.log("new aggregator active slots   :", newScan.activeSlots);
        console.log("new aggregator distinct keys  :", newScan.distinctKeys);
        console.log("required distinct keys        :", requiredKeys);

        // ---- CC-48 round-5 HIGH-1: the predecessor is not a free-text parameter ----
        // OLD_BLS_AGGREGATOR must be the aggregator Registry is wired to right now.
        // Registry knows this; asking it is what stops "0" from doubling as both "there
        // is no predecessor" and "make the preflight stop failing". The latter reading is
        // how the tainted-key gate gets switched off by accident, and that gate is the
        // only on-chain thing standing between the experiment stack's publicly-known
        // keys (scalars 1/2/3) and a fresh production aggregator.
        address oldAggregator = vm.envAddress("OLD_BLS_AGGREGATOR");
        BLSKeyScanLib.requireDeclaredPredecessor(proxy, oldAggregator);
        if (oldAggregator != address(0)) {
            // Order matters. The carry-over scan runs FIRST and UNCONDITIONALLY: it is the
            // irreversible one (a publicly-known key re-onboarded onto the new aggregator
            // cannot be un-published), and round-3 had it sitting behind a pending-case
            // check that reverts on a missing selector against every aggregator actually
            // deployed today. It never got to run against a real predecessor.
            BLSKeyScanLib.requireNoTaintedKeyCarriedOver(oldAggregator, newAggregator);
            console.log("old aggregator tainted-key scan: PASSED");

            // Then the pending-case check, which tolerates a predecessor that provably
            // predates the guardian-slash feature (it skips ONLY that check, and says so)
            // and refuses to guess about anything in between.
            BLSKeyScanLib.requireNoPendingCases(oldAggregator);
            console.log("old aggregator checked        :", oldAggregator);
            console.log("  (note: an accused address that no longer holds a slot is not");
            console.log("   enumerable on-chain -- cross-check GuardianSlashQueued events)");
        } else {
            console.log("first-ever deployment: Registry.blsAggregator() is address(0),");
            console.log("so there is no predecessor to scan. Verified against the live");
            console.log("Registry, not taken on the operator's word.");
        }


        vm.startBroadcast();
        Registry newImpl = new Registry();
        vm.stopBroadcast();
        console.log("new Registry impl   :", address(newImpl));
        require(
            keccak256(bytes(newImpl.version())) == keccak256("Registry-5.7.0"),
            "CC-48: freshly built impl is not Registry-5.7.0"
        );

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);

        targets[0] = proxy;
        payloads[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes(""));
        targets[1] = proxy;
        payloads[1] = abi.encodeCall(Registry.setBLSAggregator, (newAggregator));
        targets[2] = proxy;
        payloads[2] = abi.encodeCall(Registry.setCreditPolicy, (perProposalCap, totalCap, baseline, true));

        console.log("--- atomic governance batch (execute as ONE transaction) ---");
        for (uint256 i = 0; i < 3; i++) {
            console.log("target", i, targets[i]);
            console.logBytes(payloads[i]);
        }

        address timelock = vm.envOr("TIMELOCK", address(0));
        if (timelock != address(0)) {
            uint256 delay = ITimelockBatch(timelock).getMinDelay();
            console.log("--- TimelockController.scheduleBatch calldata (delay:", delay, ") ---");
            console.logBytes(
                abi.encodeCall(
                    ITimelockBatch.scheduleBatch,
                    (targets, values, payloads, bytes32(0), bytes32(uint256(0x5600)), delay)
                )
            );
            console.log("--- TimelockController.executeBatch calldata ---");
            console.logBytes(
                abi.encodeCall(
                    ITimelockBatch.executeBatch,
                    (targets, values, payloads, bytes32(0), bytes32(uint256(0x5600)))
                )
            );
        }

        console.log("--- post-execution assertions to run before declaring success ---");
        console.log("  registry.version()                       == Registry-5.7.0");
        console.log("  registry.blsAggregator()                 ==", newAggregator);
        console.log("  registry.maxTotalCreditExposure()        ==", totalCap);
        console.log("  registry.totalCreditExposure()           ==", baseline);
        console.log("  registry.owner()                         ==", owner);
        console.log("  registry.blsDomainSeparator()            == aggregator.domainSeparator()");
        console.log("     (pre-checked above by recomputing the post-batch value)");
        console.log("     value:");
        console.logBytes32(IAggregatorDomain(newAggregator).domainSeparator());
        console.log("  every validator has re-filed a PoP against the new aggregator");
        console.log("  no guardian-slash case is left pending on the OLD aggregator");
    }
}
