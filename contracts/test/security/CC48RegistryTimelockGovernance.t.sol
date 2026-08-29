// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {GovernanceOwnerGate} from "../../script/checks/GovernanceOwnerGate.sol";
import {RegistryUpgradeBatchLib, IStakingSlasherAuth} from "../../script/checks/RegistryUpgradeBatchLib.sol";
import {IMySBT} from "src/interfaces/v3/IMySBT.sol";

contract TimelockMockSBT is IMySBT {
    function mintForRole(address, bytes32, bytes calldata) external pure returns (uint256, bool) {
        return (1, true);
    }
    function airdropMint(address, bytes32, bytes calldata) external pure returns (uint256, bool) {
        return (1, true);
    }
    function getUserSBT(address) external pure returns (uint256) { return 1; }
    function getSBTData(uint256) external pure returns (SBTData memory) {
        return SBTData(address(0), address(0), 0, 0);
    }
    function verifyCommunityMembership(address, address) external pure returns (bool) { return true; }
    function deactivateMembership(address, address) external pure {}
    function deactivateAllMemberships(address) external pure {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external pure {}
    function burnSBT(address) external pure {}
}

contract TimelockMockBLS {
    function defaultThreshold() external pure returns (uint256) { return 2; }
    function verify(bytes32, uint256, uint256, bytes calldata) external pure returns (bool) { return true; }
}

/**
 * @title CC48RegistryTimelockGovernance
 * @notice CC-48 round-7, from the archived original security checklist:
 *
 *           "proxy 升级新 cap slot 初值为 0：UpgradeRegistryTo580 已把
 *            setCreditPolicy(perProposal,total) 放入同一批计划；round 7
 *            必须补一个真实 Timelock schedule/execute 测试，证明 upgrade + baseline/caps
 *            不存在中间可执行窗口。"
 *           "setCreditPolicy 仍是 immediate onlyOwner ... 若是 Timelock，部署/迁移门禁和
 *            测试必须验证 getMinDelay>0 及 owner 实际等于该 Timelock；不得只打印 calldata。"
 *
 *         Everything here runs against a REAL `TimelockController` (OpenZeppelin v5.0.2)
 *         owning a REAL `ERC1967Proxy` Registry — no mock of the governance path, because
 *         the property being asserted IS the governance path. The previous evidence for
 *         this was `UpgradeRegistryTo580` printing `scheduleBatch` calldata, which proves
 *         nothing about whether the operation can be executed, executed in pieces, or
 *         executed at all.
 *
 *         CC-48 round-8 LOW-5 — WHAT "BINDS TO THE SHIPPED PARAMETERS" NOW MEANS. Round 7
 *         claimed that here while holding its OWN `BATCH_SALT` constant and its OWN
 *         hand-written copy of the batch, so changing the salt in `UpgradeRegistryTo580`
 *         left this test green. That claim was false and is retracted. Salt, predecessor
 *         and every payload now comes from `RegistryUpgradeBatchLib`, which the SCRIPT
 *         also calls — there is one definition in the repository, so an edit to the shipped
 *         batch is an edit to what this test asserts, by construction rather than by
 *         discipline.
 */
contract CC48RegistryTimelockGovernance is Test {
    /// @dev NOT re-declared here: aliased straight to the shipped definition, so there is
    ///      no second value that could drift from the script's.
    bytes32 internal constant BATCH_SALT = RegistryUpgradeBatchLib.BATCH_SALT;
    bytes32 internal constant NO_PREDECESSOR = RegistryUpgradeBatchLib.NO_PREDECESSOR;

    uint256 internal constant MIN_DELAY = 2 days;

    uint256 internal constant PER_PROPOSAL_CAP = 600 ether;
    uint256 internal constant TOTAL_CAP = 200_000 ether;
    /// @dev CC-48 round-9: the batch no longer carries an operator-supplied aPNT baseline.
    ///      It carries the POPULATION, and the contract derives the stock from its own
    ///      `globalReputation` storage. `_seedUsers()` returns that membership list.
    address internal constant SEED_USER_A = address(0xA11CE);
    address internal constant SEED_USER_B = address(0xB0B);

    Registry internal registry;
    TimelockMockStaking internal staking;
    TimelockController internal timelock;
    address internal newAggregator;
    address internal oldAggregator;

    address internal proposer = address(0x9401);
    address internal executor = address(0x9402);
    address internal stranger = address(0xBAD);

    function setUp() public {
        // A non-zero staking address is required, not incidental: step (3) of the batch
        // authorises the new aggregator as a slasher ON GTokenStaking, so a proxy wired to
        // address(0) would produce a batch whose third call goes nowhere.
        staking = new TimelockMockStaking(address(this));
        registry = UUPSDeployHelper.deployRegistryProxy(
            address(this), address(staking), address(new TimelockMockSBT())
        );
        newAggregator = address(new TimelockMockBLS());
        // Every real upgrade rotates AWAY from something, and that predecessor keeps its
        // slasher authorisation unless the batch revokes it. Modelling it as a distinct
        // address is what lets the shape assertions below see the revoke step at all.
        oldAggregator = address(new TimelockMockBLS());

        // Model the state an UPGRADED proxy is actually in. `initialize` seeds
        // `maxTotalCreditExposure`, but `initialize` does not run on an upgrade: a proxy
        // coming from a build that predates these slots reads 0 for both, which is exactly
        // the window step (3) of the batch exists to close. Writing them to 0 through the
        // contract's own setter models that without hard-coding a storage slot index.
        registry.setCreditPolicy(0, 0);
        assertEq(registry.maxTotalCreditExposure(), 0, "pre-batch cap must read 0");

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        // admin = address(0): nobody can bypass the delay by re-granting roles later.
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        registry.transferOwnership(address(timelock));
        // Both subjects answer to ONE principal — the deployment shape `UpgradeRegistryTo580`
        // asserts (`IOwned(staking).owner() == IOwned(proxy).owner()`) before it emits the
        // batch. Steps (3) and (4) are `onlyOwner` on the real GTokenStaking, so without
        // this the operation could not carry them and the atomicity property under test
        // would not be available in the first place.
        staking.transferOwnership(address(timelock));
    }

    // =================================================================
    // The two properties the checklist asks the GATE to assert
    // =================================================================

    /// `Registry.setCreditPolicy` is immediate `onlyOwner`, so "Registry is behind a
    /// Timelock" is only true if the Timelock is BOTH the owner AND actually delaying.
    /// `UpgradeRegistryTo580` now asserts exactly this pair when `TIMELOCK` is set.
    function test_GateAssertsOwnershipAndANonZeroMinDelay() public view {
        assertEq(registry.owner(), address(timelock), "owner is the Timelock");
        assertGt(timelock.getMinDelay(), 0, "and the Timelock actually delays");

        // The shipped gate, run against the real pair — not a restatement of it.
        GovernanceOwnerGate.requireTimelockOwner(
            address(registry), registry.owner(), address(timelock), "Registry"
        );
    }

    /// A Timelock is not an M-of-N owner and the aggregator gate must keep refusing it,
    /// even though Registry may legitimately be owned by one.
    function test_ATimelockIsNotAcceptedWhereMofNIsRequired() public view {
        (bool ok,, string memory why) = GovernanceOwnerGate.readMofN(address(timelock));
        assertFalse(ok, "TimelockController has no getThreshold()");
        assertTrue(bytes(why).length > 0);
    }

    // =================================================================
    // The batch: scheduled once, executed once, every step or none
    // =================================================================

    function test_UpgradeAndCapsLandInOneTransactionWithNoIntermediateWindow() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch();

        // The batch under test IS the shipped shape. Every call addresses the proxy EXCEPT
        // the slasher authorisation, which must target GTokenStaking — a batch reaching any
        // other address would not be the operation `UpgradeRegistryTo580` schedules, and
        // everything below would be asserting about something else. Pinning the exception by
        // index rather than allowing "proxy or staking" anywhere keeps the ordering asserted
        // too: the authorisation has to be step (3), inside the same atomic operation.
        // CC-48 round-10 LOW: the length is a LITERAL here, not `RegistryUpgradeBatchLib.
        // BATCH_LENGTH`. `buildBatch` sizes the array FROM that constant, so asserting the
        // constant is a tautology that no shrink of the batch can fail. Writing six by hand
        // means a batch that loses a step has to be typed twice before it is green.
        assertEq(targets.length, 6, "six calls: five plus the predecessor disarm");
        address stakingTarget = address(registry.GTOKEN_STAKING());
        assertTrue(stakingTarget != address(0), "staking must be wired for the batch to be meaningful");
        for (uint256 i = 0; i < targets.length; ++i) {
            if (i == 2 || i == 3) {
                assertEq(targets[i], stakingTarget, "steps 3 and 4 are the slasher grant and revoke");
            } else {
                assertEq(targets[i], address(registry), "every other call targets the Registry proxy");
            }
            assertEq(values[i], 0, "no ether moves");
        }
        // CC-48 round-10 MEDIUM-1: the loop above pins only the TARGET of steps (3) and
        // (4), and a target cannot tell a grant from a revoke -- both are
        // `setAuthorizedSlasher` on the same GTokenStaking address. Mutating step (4) from
        // (oldAggregator, false) to (oldAggregator, true), or to (newAggregator, false),
        // left the whole suite green. The second of those is exactly the failure the
        // revoke step was written not to cause: disarming, inside the same atomic batch,
        // the aggregator that step (3) armed two calls earlier -- the reason this commit
        // exists at all. Pin the payload by value so both mutations are red.
        //
        // Step (3)'s payload is deliberately NOT restated here: it is an unconditional
        // line in `buildBatch`, so any mutation of it already reddens
        // `test_SameAggregatorIsGrantedAndNotRevoked`, which asserts it by value. Adding a
        // second copy would only make one defect fail two tests.
        assertEq(
            keccak256(payloads[3]),
            keccak256(abi.encodeCall(IStakingSlasherAuth.setAuthorizedSlasher, (oldAggregator, false))),
            "step (4) revokes the PREDECESSOR, not the aggregator step (3) just armed"
        );
        // CC-48 round-8 LOW-5: capture the implementation the proxy points at BEFORE the
        // batch. `assertEq(registry.version(), "Registry-5.8.0")` after execution is a
        // VACUOUS assertion -- `UUPSDeployHelper` already deployed 5.8.0, so it held before
        // the batch too. The implementation SLOT moving is the non-vacuous statement that
        // step (1) actually executed.
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address implBefore = address(uint160(uint256(vm.load(address(registry), implSlot))));

        // ---- schedule ----
        vm.prank(stranger);
        vm.expectRevert(); // AccessControlUnauthorizedAccount: only the proposer may schedule
        timelock.scheduleBatch(targets, values, payloads, NO_PREDECESSOR, BATCH_SALT, MIN_DELAY);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, NO_PREDECESSOR, BATCH_SALT, MIN_DELAY);

        bytes32 opId = timelock.hashOperationBatch(targets, values, payloads, NO_PREDECESSOR, BATCH_SALT);
        assertTrue(timelock.isOperationPending(opId), "scheduled");
        assertFalse(timelock.isOperationReady(opId), "but not ready yet");

        // ---- the delay is real ----
        vm.prank(executor);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, NO_PREDECESSOR, BATCH_SALT);

        // Nothing has moved: this is the window, and it is not executable.
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-5.8.0"));
        assertEq(registry.maxTotalCreditExposure(), 0, "caps still unset while pending");
        assertEq(registry.blsAggregator(), address(0), "aggregator still unwired while pending");

        vm.warp(block.timestamp + MIN_DELAY);
        assertTrue(timelock.isOperationReady(opId), "ready after the delay, not before");

        // ---- THE atomicity property ----
        // A Timelock operation id commits to the WHOLE (targets, values, payloads,
        // predecessor, salt) tuple. Any proper subset — in particular "just the upgrade",
        // which is the step that leaves the cap slot at 0 — hashes to a DIFFERENT id that
        // was never scheduled, so it cannot be executed first. There is no ordering an
        // executor can choose that produces the intermediate state.
        (address[] memory upgradeOnlyT, uint256[] memory upgradeOnlyV, bytes[] memory upgradeOnlyP) =
            _upgradeOnlySubBatch(targets, values, payloads);
        bytes32 subId =
            timelock.hashOperationBatch(upgradeOnlyT, upgradeOnlyV, upgradeOnlyP, NO_PREDECESSOR, BATCH_SALT);
        assertTrue(subId != opId, "a subset is a different operation");
        assertFalse(timelock.isOperation(subId), "and it was never scheduled");
        vm.prank(executor);
        vm.expectRevert();
        timelock.executeBatch(upgradeOnlyT, upgradeOnlyV, upgradeOnlyP, NO_PREDECESSOR, BATCH_SALT);

        // Still untouched after the failed slicing attempt.
        assertEq(registry.maxTotalCreditExposure(), 0);

        // ---- execute: one transaction, every effect ----
        vm.prank(executor);
        timelock.executeBatch(targets, values, payloads, NO_PREDECESSOR, BATCH_SALT);

        assertTrue(timelock.isOperationDone(opId), "executed");
        address implAfter = address(uint160(uint256(vm.load(address(registry), implSlot))));
        assertTrue(implAfter != implBefore, "step (1) actually re-pointed the proxy");
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-5.8.0"), "and to a 5.8.0 impl");
        assertEq(registry.blsAggregator(), newAggregator, "aggregator wired");
        assertEq(registry.maxTotalCreditExposure(), TOTAL_CAP, "protocol ceiling seeded");
        // Round-9: the stock is DERIVED, so what the batch has to prove is that the
        // population landed and the path is open -- not that an operator's number was
        // copied into a slot. Both seeded addresses sit at level 1 here, so the derived
        // above-floor stock is exactly zero, and that zero is a computed fact rather than
        // an unseeded default: `creditPopulationSeededAt` is what distinguishes them.
        assertEq(registry.creditPopulationTotal(), 2, "population counted inside the batch");
        assertGt(registry.creditPopulationSeededAt(), 0, "reputation path opened by the batch");
        assertEq(registry.totalCreditExposure(), 0, "no promoted user in this fixture");
        assertEq(registry.maxAggregateCreditUpliftPerProposal(), PER_PROPOSAL_CAP, "per-proposal cap seeded");
        assertEq(registry.owner(), address(timelock), "ownership unchanged by the batch");
        // Steps (3) and (4) as END STATE, not as calldata: the rotation leaves exactly one
        // armed slasher. Reading it back off a mock that enforces the real `onlyOwner` gate
        // is what makes this evidence that the Timelock could carry both calls, rather than
        // evidence that a permissive stub accepted them.
        assertTrue(staking.authorizedSlashers(newAggregator), "the new aggregator came out armed");
        assertFalse(staking.authorizedSlashers(oldAggregator), "and the predecessor came out disarmed");

        // ---- and it cannot be replayed ----
        vm.prank(executor);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, NO_PREDECESSOR, BATCH_SALT);
    }

    /// The counterfactual, so "atomic" is a measured property and not an assertion about
    /// an outcome that would have been fine either way. Schedule and execute ONLY the
    /// upgrade — a governance operator splitting the batch "to be careful" — and the
    /// protocol-wide credit ceiling is live at 0.
    function test_SplittingTheBatchLeavesTheCreditCeilingAtZero() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch();
        (address[] memory t, uint256[] memory v, bytes[] memory p) =
            _upgradeOnlySubBatch(targets, values, payloads);

        vm.prank(proposer);
        timelock.scheduleBatch(t, v, p, NO_PREDECESSOR, BATCH_SALT, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(executor);
        timelock.executeBatch(t, v, p, NO_PREDECESSOR, BATCH_SALT);

        // The upgrade landed...
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-5.8.0"));
        // ...into a Registry whose protocol-wide ceiling is 0 and whose aggregator is
        // unwired. Fail-closed in the right direction, but it is a governance halt on the
        // reputation path that lasts another full timelock cycle -- which is precisely why
        // step (3) is in the same batch and not scheduled afterwards.
        assertEq(registry.maxTotalCreditExposure(), 0, "every positive-uplift proposal now reverts");
        assertEq(registry.blsAggregator(), address(0), "and ROLE_DVT exits have nothing to consume");
    }

    // =================================================================
    // Helpers
    // =================================================================

    /// A first-ever deployment has no predecessor to disarm, so the batch is one call
    /// shorter and contains no revoke. Asserted separately because the length is now
    /// conditional, and a silently-wrong length would move every later index.
    function test_FirstDeploymentBatchOmitsTheRevokeStep() public {
        Registry newImpl = new Registry();
        (address[] memory targets,, bytes[] memory payloads) = RegistryUpgradeBatchLib.buildBatch(
            address(registry),
            address(newImpl),
            newAggregator,
            address(0), // no predecessor
            address(registry.GTOKEN_STAKING()),
            PER_PROPOSAL_CAP,
            TOTAL_CAP,
            _seedUsers()
        );
        // Literal, not `BATCH_LENGTH_NO_REVOKE`: see the note in the rotation test above.
        assertEq(targets.length, 5, "no predecessor means no revoke call");
        bytes4 setSlasher = IStakingSlasherAuth.setAuthorizedSlasher.selector;
        uint256 slasherCalls;
        for (uint256 i = 0; i < payloads.length; ++i) {
            if (bytes4(payloads[i]) == setSlasher) ++slasherCalls;
        }
        assertEq(slasherCalls, 1, "exactly the grant, and no revoke");
    }

    /// A Registry-only upgrade keeps the SAME aggregator. Revoking it would undo the grant
    /// in the same atomic batch and hand back a silently disarmed slash path — the very
    /// failure the grant exists to prevent — so the revoke must be skipped, not merely
    /// ordered before the grant.
    function test_SameAggregatorIsGrantedAndNotRevoked() public {
        Registry newImpl = new Registry();
        (address[] memory targets,, bytes[] memory payloads) = RegistryUpgradeBatchLib.buildBatch(
            address(registry),
            address(newImpl),
            newAggregator,
            newAggregator, // not rotating: predecessor IS the new aggregator
            address(registry.GTOKEN_STAKING()),
            PER_PROPOSAL_CAP,
            TOTAL_CAP,
            _seedUsers()
        );
        assertEq(targets.length, 5, "no revoke when not rotating");
        bytes memory grant =
            abi.encodeCall(IStakingSlasherAuth.setAuthorizedSlasher, (newAggregator, true));
        bytes memory revoke =
            abi.encodeCall(IStakingSlasherAuth.setAuthorizedSlasher, (newAggregator, false));
        uint256 grants;
        for (uint256 i = 0; i < payloads.length; ++i) {
            assertTrue(keccak256(payloads[i]) != keccak256(revoke), "must never revoke the aggregator it just armed");
            if (keccak256(payloads[i]) == keccak256(grant)) ++grants;
        }
        assertEq(grants, 1, "the grant survives");
    }

    /// The batch exactly as `UpgradeRegistryTo580` emits it — because it is the same call.
    function _batch()
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        Registry newImpl = new Registry();
        return RegistryUpgradeBatchLib.buildBatch(
            address(registry),
            address(newImpl),
            newAggregator,
            oldAggregator,
            address(registry.GTOKEN_STAKING()),
            PER_PROPOSAL_CAP,
            TOTAL_CAP,
            _seedUsers()
        );
    }

    function _seedUsers() internal pure returns (address[] memory users) {
        users = new address[](2);
        users[0] = SEED_USER_A;
        users[1] = SEED_USER_B;
    }

    function _upgradeOnlySubBatch(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory payloads
    ) internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory p) {
        return RegistryUpgradeBatchLib.upgradeOnlySubBatch(targets, values, payloads);
    }
}

/// @dev Stand-in for GTokenStaking, holding only what the batch touches — but holding it
///      with the real contract's ACCESS CONTROL, because this batch is executed, not just
///      built. `setAuthorizedSlasher` is `onlyOwner` on the real GTokenStaking
///      (`GTokenStaking.sol:474`); a mock that accepted it from anyone would let step (3)
///      succeed regardless of who executed the operation, and the assertion that the
///      aggregator came out armed would no longer depend on the property the deployment
///      script requires — that ONE principal owns both Registry and staking, which is why
///      the authorisation can ride inside this operation at all. Ownership is handed to
///      the Timelock in `setUp`, so the batch executes as that single principal.
///      `setRoleExitFee` mirrors `IGTokenStaking`'s (bytes32,uint256,uint256): Registry
///      pushes exit fees in through a fail-open low-level call during `initialize`, and a
///      divergent signature would hash to another selector and miss in silence.
contract TimelockMockStaking {
    address public owner;
    mapping(address => bool) public authorizedSlashers;

    constructor(address _owner) { owner = _owner; }

    function transferOwnership(address to) external {
        require(msg.sender == owner, "GTokenStaking: not owner");
        owner = to;
    }

    function setAuthorizedSlasher(address slasher, bool ok) external {
        require(msg.sender == owner, "GTokenStaking: not owner");
        authorizedSlashers[slasher] = ok;
    }

    function setRoleExitFee(bytes32, uint256, uint256) external {}
    function getLockedStake(address, bytes32) external pure returns (uint256) { return 0; }
}
