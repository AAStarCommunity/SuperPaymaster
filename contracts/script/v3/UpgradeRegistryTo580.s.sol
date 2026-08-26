// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "src/core/Registry.sol";
import {BLSKeyScanLib} from "../checks/BLSKeyScanLib.sol";
import {GovernanceOwnerGate, IOwned} from "../checks/GovernanceOwnerGate.sol";
import {RegistryUpgradeBatchLib} from "../checks/RegistryUpgradeBatchLib.sol";

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
 * @title UpgradeRegistryTo580
 * @notice CC-48 MEDIUM-3: build the ONE governance batch that takes a live Registry
 *         proxy to 5.8.0. All four steps must land in a single transaction.
 *
 *   1. upgradeToAndCall(newImpl, "")
 *   2. setBLSAggregator(BLSAggregator 4.11.0)
 *   3. setCreditPolicy(perProposalCap, totalCap)
 *   4. seedCreditPopulation(users, users.length, true)
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
 *   - BLSAggregator is NOT upgradeable. 4.11.0 is a fresh deployment at a NEW address,
 *     and the domain separator commits to that address, so EVERY in-flight proof
 *     signed against the old aggregator becomes unverifiable the moment step (2)
 *     lands. Drain the proposal queue first; do not schedule the batch while a
 *     reputation or slash proposal is awaiting submission.
 *   - Validator BLS keys do NOT migrate. `blsKeyOwner` and `_blsKeys` are per-contract
 *     state, and a proof-of-possession is now bound to (validator, aggregator, chain),
 *     so every validator must re-file a freshly signed PoP against 4.11.0. Run
 *     contracts/script/checks/ScanDuplicateBLSKeys.s.sol against the OLD aggregator
 *     first: if it reports duplicates, those validators were sharing a key and must
 *     not be re-onboarded with it.
 *   - ⚠️ `GuardianSlashQueued` HAS TWO TOPICS, ONE PER AGGREGATOR VERSION. 4.11.0 added a
 *     `guiltyGuardians` array, so <=4.10.0 emits
 *     0xbd29882a64fb25d3f96a8c3b657df25c01d1cf84f77df08564dbea8fc988fd82 and >=4.11.0 emits
 *     0xcf5c0505e0bff287d5bb2aaf75cb5409c172bdfa5972505e4431b3e76672958c. Do NOT globally
 *     "switch the watcher to the new topic": this preflight scans the OLD aggregator, so it
 *     must use the topic THAT contract emits. Scanning the old aggregator with the new topic
 *     returns zero events, does not error, and reports a still-open case as clean. During the
 *     migration window scan BOTH addresses, each with its own topic.
 *     Why it is load-bearing: `requireNoPendingCases` enumerates guardians via
 *     `validatorAtSlot`, so an accused address whose key was revoked holds no slot and is
 *     invisible on-chain; this event scan is the documented compensating control for that
 *     blind spot (docs/security/CC48-round3-changes.md 1.5). An empty scan is NOT evidence on
 *     its own — the procedure for establishing that lands in a follow-up PR; until then treat
 *     a bare "no cases found" as UNRESOLVED. See runbook section 5b.
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
 * The script refuses to emit a non-atomic path, and it refuses to run at all unless both
 * owners are actually behind governance. CC-48 round-7 makes that check mean what it says:
 *
 *   - BLSAggregator's owner must be a SAFE-COMPATIBLE M-of-N owner — code, not an EIP-7702
 *     delegation designator, `getThreshold() >= 2`, `getOwners()` a canonical array of
 *     distinct non-zero owners of at least that length. A TimelockController does NOT
 *     qualify and must not: a timelocked emergency stop is not an emergency stop, so the
 *     M-of-N owner is the only defence on the disarm path.
 *   - Registry's owner may be EITHER a Safe-compatible M-of-N owner OR a
 *     TimelockController, and the script requires you to say which. Set `TIMELOCK` and it
 *     asserts `Registry.owner() == TIMELOCK` AND `TIMELOCK.getMinDelay() > 0`; leave it
 *     unset and Registry is held to the same M-of-N bar as the aggregator. This matters
 *     because `Registry.setCreditPolicy` is `immediate onlyOwner` — a zero-delay Timelock
 *     owning Registry restores exactly the property the batch below exists to remove.
 *
 * Neither check proves the owner is a CANONICAL Gnosis Safe; see `GovernanceOwnerGate`.
 *
 * CC-48 round-6 HIGH-1: the NEW_BLS_AGGREGATOR's own owner is gated the same way, and
 * for a stronger reason. 4.11.0's `emergencyDisarmFraudProofVerifier()` is immediate and
 * unannounced, so that owner can censor every FUTURE guardian-slash accusation by
 * front-running it in the mempool. A TimelockController cannot cover that path (a
 * timelocked emergency stop is not an emergency stop), which makes the Safe-compatible
 * M-of-N owner — an interface-and-threshold property, NOT a proof of canonicity — the
 * only governance defence there; the in-contract 4-day delay only governs RE-arming, and
 * already-queued cases are unreachable either way. Both gates are strict outside anvil —
 * a migration rehearsal that runs with an EOA owner rehearses a different system.
 *
 * Env:
 *   REGISTRY_PROXY               live Registry ERC1967 proxy
 *   NEW_BLS_AGGREGATOR           BLSAggregator 4.11.0 (already deployed + wired)
 *   CREDIT_PER_PROPOSAL_CAP      aPNT wei, transaction-level guard
 *   CREDIT_TOTAL_CAP             aPNT wei, protocol-wide outstanding ceiling
 *   CREDIT_POPULATION_USERS      comma-separated addresses: every address that has EVER
 *                                been the subject of a reputation proposal on the live
 *                                Registry (i.e. every `GlobalReputationUpdated` subject,
 *                                de-duplicated). REPLACES the old CREDIT_EXPOSURE_BASELINE
 *                                aPNT number, which round-9 review found to be wrong BY
 *                                CONSTRUCTION: its documented derivation summed only the
 *                                event stream, so every address still holding the
 *                                `initialize` tier-1 default was omitted from a figure the
 *                                protocol-wide cap was then measured against.
 *                                What replaces it is not a better number, it is NO number:
 *                                governance declares MEMBERSHIP and the contract reads each
 *                                member's level out of its own `globalReputation` storage.
 *                                This script re-reads it too, over RPC, and refuses to emit
 *                                a batch whose derived stock does not fit under the cap.
 *                                Omitted addresses are not silently lost either: an
 *                                unseeded proxy cannot run ANY proposal, and a member the
 *                                list missed is booked at its full standing limit by the
 *                                first proposal that touches it.
 *   CREDIT_POPULATION_EXPECTED   (optional) headcount cross-check. Defaults to the length
 *                                of CREDIT_POPULATION_USERS; set it to the number your
 *                                own event scan produced and a truncated env var is caught
 *                                here rather than on-chain.
 *   OLD_BLS_AGGREGATOR           predecessor aggregator to preflight. REQUIRED, no
 *                                default, and CHECKED: it must equal
 *                                `Registry.blsAggregator()` as it reads RIGHT NOW.
 *                                0 is accepted only when the live Registry genuinely has
 *                                no aggregator wired — a live migration cannot declare
 *                                itself "first-ever" to make the preflight quiet down
 *                                (CC-48 round-5 HIGH-1).
 *   MIN_DISTINCT_KEYS (optional) override the distinct-active-key floor; defaults to the
 *                                largest threshold the new aggregator itself configures
 *   GOVERNANCE_OWNER             REQUIRED whenever NEW_BLS_AGGREGATOR's owner is gated as
 *                                Safe-compatible M-of-N. Must EQUAL the live
 *                                `NEW_BLS_AGGREGATOR.owner()`; a mismatch is refused, and
 *                                so is acceptance with nothing declared (round-8 LOW-2).
 *   REGISTRY_GOVERNANCE_OWNER    the same, for `Registry` — but only on the branch where
 *                                `TIMELOCK` is unset. Registry and the aggregator are two
 *                                independent governance questions and need not be the same
 *                                Safe, so they carry two declarations.
 *   TIMELOCK (optional)          the TimelockController that owns Registry. If set, the
 *                                script ASSERTS Registry.owner() == TIMELOCK and
 *                                TIMELOCK.getMinDelay() > 0 (not merely prints calldata),
 *                                then emits scheduleBatch/executeBatch calldata. If unset,
 *                                Registry's owner is held to the Safe-compatible M-of-N bar.
 *   ALLOW_EOA_OWNER (optional)   escape hatch, ENFORCED to chainid 31337 only
 *
 * Preflight requires an EIP-2537 (Prague) RPC: the weak-key scan recomputes g1*s and
 * must not be able to report "clean" simply because it could not run.
 */
contract UpgradeRegistryTo580 is Script {
    function run() external {
        address proxy = vm.envAddress("REGISTRY_PROXY");
        address newAggregator = vm.envAddress("NEW_BLS_AGGREGATOR");
        uint256 perProposalCap = vm.envUint("CREDIT_PER_PROPOSAL_CAP");
        uint256 totalCap = vm.envUint("CREDIT_TOTAL_CAP");
        address[] memory seedUsers = vm.envAddress("CREDIT_POPULATION_USERS", ",");

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
        // CC-48 round-7 (archived original checklist): Registry governance is a DIFFERENT
        // question from BLSAggregator governance, and the script now makes the operator
        // answer it instead of accepting "any contract" for both. `setCreditPolicy` is
        // immediate `onlyOwner`, so if Registry sits behind a Timelock, the evidence has to
        // show that the Timelock actually imposes a delay AND is actually the owner --
        // printing scheduleBatch calldata proves neither.
        address timelock = vm.envOr("TIMELOCK", address(0));
        // CC-48 round-8 LOW-2: each subject binds to its OWN declaration. `TIMELOCK` is
        // already an explicit declaration checked against the live owner; the M-of-N branch
        // gets `REGISTRY_GOVERNANCE_OWNER` so it is held to the same standard rather than
        // accepting whatever contract happens to answer the interface.
        if (timelock != address(0)) {
            GovernanceOwnerGate.requireTimelockOwner(proxy, owner, timelock, "Registry");
        } else {
            GovernanceOwnerGate.requireGovernanceOwnerStrictDeclaredAs(
                proxy, owner, "Registry", "REGISTRY_GOVERNANCE_OWNER"
            );
        }

        // CC-48 round-6 HIGH-1: the aggregator's OWN owner is now a distinct governance
        // question, and until this round nothing checked it. The aggregator gives that owner
        // `emergencyDisarmFraudProofVerifier()` — immediate, no notice, and enough to
        // front-run every future `queueGuardianSlash` out of the mempool for one
        // transaction's gas. A Timelock cannot cover an emergency stop, so the
        // Safe-compatible M-of-N owner is the only governance defence on that path (an
        // interface-and-threshold property, not a proof of canonicity); wiring an EOA-owned
        // aggregator into a live Registry hands one hot key a permanent, silent veto over
        // the entire collusion deterrent. Checked before the batch is emitted, not after.
        // Round-7: a Timelock is deliberately NOT accepted here even though it is accepted
        // for Registry above -- it cannot cover an immediate disarm.
        GovernanceOwnerGate.requireGovernanceOwnerStrict(
            newAggregator, IOwned(newAggregator).owner(), "BLSAggregator (disarm authority)"
        );

        require(perProposalCap <= totalCap, "CC-48: per-proposal cap above the protocol ceiling is meaningless");
        require(totalCap > 0, "CC-48: zero protocol ceiling is fail-closed; set a real number");

        // ---- CC-48 round-9 MEDIUM-HIGH-B3: the baseline is DERIVED here, not declared ----
        // Round-8 shipped `CREDIT_EXPOSURE_BASELINE`, an aPNT number nothing on-chain could
        // check and whose documented derivation (sum the GlobalReputationUpdated stream)
        // structurally under-counts a live deployment. This block computes the same
        // quantity the CONTRACT will compute, from the SAME source the contract will read --
        // live `globalReputation` over RPC -- and refuses the migration if it does not fit.
        // Nothing here is taken on the operator's word except which addresses to look at,
        // and that one input is cross-checked against a declared headcount.
        uint256 declaredPopulation = vm.envOr("CREDIT_POPULATION_EXPECTED", seedUsers.length);
        require(
            declaredPopulation == seedUsers.length,
            "CC-48: CREDIT_POPULATION_USERS length disagrees with CREDIT_POPULATION_EXPECTED"
        );
        uint256 floorLimit = registry.creditTierConfig(1);
        uint256 derivedExposure;
        uint256 promoted;
        for (uint256 i = 0; i < seedUsers.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                require(seedUsers[i] != seedUsers[j], "CC-48: duplicate address in CREDIT_POPULATION_USERS");
            }
            uint256 limit = registry.getCreditLimit(seedUsers[i]);
            if (limit > floorLimit) {
                derivedExposure += limit - floorLimit;
                promoted++;
            }
        }
        console.log("credit population declared    :", seedUsers.length);
        console.log("  of which above the tier-1 floor:", promoted);
        console.log("derived exposure (aPNT wei)   :", derivedExposure);
        console.log("declared protocol ceiling     :", totalCap);
        require(
            totalCap >= derivedExposure,
            "CC-48: ceiling is below the exposure this deployment already carries; raise it or the batch reverts"
        );
        // Level-1 is the permissionless floor every address holds, so it is deliberately
        // NOT in the number above -- see Registry.totalCreditExposure. Print it so the
        // operator sees the budget that this cap does not govern.
        console.log("tier-1 floor per address (NOT bounded by the cap):", floorLimit);

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
            keccak256(bytes(IAggregatorDomain(newAggregator).version())) == keccak256("BLSAggregator-4.11.0"),
            "CC-48: NEW_BLS_AGGREGATOR is not BLSAggregator-4.11.0"
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
        // A fresh 4.11.0 starts with an EMPTY key table. Wiring it in before validators
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
            keccak256(bytes(newImpl.version())) == keccak256("Registry-5.8.0"),
            "CC-48: freshly built impl is not Registry-5.8.0"
        );

        // CC-48 round-8 LOW-5: the batch shape, its salt and its predecessor live in
        // `RegistryUpgradeBatchLib` so `CC48RegistryTimelockGovernance` asserts against THIS
        // definition instead of a copy of it. Editing the batch here without editing the
        // test is no longer possible; there is only one definition to edit.
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = RegistryUpgradeBatchLib
            .buildBatch(proxy, address(newImpl), newAggregator, perProposalCap, totalCap, seedUsers);

        console.log("--- atomic governance batch (execute as ONE transaction) ---");
        for (uint256 i = 0; i < RegistryUpgradeBatchLib.BATCH_LENGTH; i++) {
            console.log("target", i, targets[i]);
            console.logBytes(payloads[i]);
        }

        if (timelock != address(0)) {
            uint256 delay = ITimelockBatch(timelock).getMinDelay();
            console.log("--- TimelockController.scheduleBatch calldata (delay:", delay, ") ---");
            console.logBytes(
                abi.encodeCall(
                    ITimelockBatch.scheduleBatch,
                    (
                        targets,
                        values,
                        payloads,
                        RegistryUpgradeBatchLib.NO_PREDECESSOR,
                        RegistryUpgradeBatchLib.BATCH_SALT,
                        delay
                    )
                )
            );
            console.log("--- TimelockController.executeBatch calldata ---");
            console.logBytes(
                abi.encodeCall(
                    ITimelockBatch.executeBatch,
                    (
                        targets,
                        values,
                        payloads,
                        RegistryUpgradeBatchLib.NO_PREDECESSOR,
                        RegistryUpgradeBatchLib.BATCH_SALT
                    )
                )
            );
        }

        console.log("--- post-execution assertions to run before declaring success ---");
        console.log("  registry.version()                       == Registry-5.8.0");
        console.log("  registry.blsAggregator()                 ==", newAggregator);
        console.log("  registry.maxTotalCreditExposure()        ==", totalCap);
        console.log("  registry.totalCreditExposure()           ==", derivedExposure);
        console.log("  registry.creditPopulationTotal()          ==", seedUsers.length);
        console.log("  registry.creditPopulationSeededAt()        > 0  (reputation path open)");
        console.log("  registry.owner()                         ==", owner);
        console.log("  registry.blsDomainSeparator()            == aggregator.domainSeparator()");
        console.log("     (pre-checked above by recomputing the post-batch value)");
        console.log("     value:");
        console.logBytes32(IAggregatorDomain(newAggregator).domainSeparator());
        console.log("  every validator has re-filed a PoP against the new aggregator");
        console.log("  no guardian-slash case is left pending on the OLD aggregator");
    }
}
