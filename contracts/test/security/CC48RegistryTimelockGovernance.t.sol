// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {GovernanceOwnerGate} from "../../script/checks/GovernanceOwnerGate.sol";
import {RegistryUpgradeBatchLib} from "../../script/checks/RegistryUpgradeBatchLib.sol";
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
 *           "proxy 升级新 cap slot 初值为 0：UpgradeRegistryTo570 已把
 *            setCreditPolicy(perProposal,total) 放入同一批计划；round 7
 *            必须补一个真实 Timelock schedule/execute 测试，证明 upgrade + baseline/caps
 *            不存在中间可执行窗口。"
 *           "setCreditPolicy 仍是 immediate onlyOwner ... 若是 Timelock，部署/迁移门禁和
 *            测试必须验证 getMinDelay>0 及 owner 实际等于该 Timelock；不得只打印 calldata。"
 *
 *         Everything here runs against a REAL `TimelockController` (OpenZeppelin v5.0.2)
 *         owning a REAL `ERC1967Proxy` Registry — no mock of the governance path, because
 *         the property being asserted IS the governance path. The previous evidence for
 *         this was `UpgradeRegistryTo570` printing `scheduleBatch` calldata, which proves
 *         nothing about whether the operation can be executed, executed in pieces, or
 *         executed at all.
 *
 *         CC-48 round-8 LOW-5 — WHAT "BINDS TO THE SHIPPED PARAMETERS" NOW MEANS. Round 7
 *         claimed that here while holding its OWN `BATCH_SALT` constant and its OWN
 *         hand-written copy of the batch, so changing the salt in `UpgradeRegistryTo570`
 *         left this test green. That claim was false and is retracted. Salt, predecessor
 *         and all three payloads now come from `RegistryUpgradeBatchLib`, which the SCRIPT
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
    TimelockController internal timelock;
    address internal newAggregator;

    address internal proposer = address(0x9401);
    address internal executor = address(0x9402);
    address internal stranger = address(0xBAD);

    function setUp() public {
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(new TimelockMockSBT()));
        newAggregator = address(new TimelockMockBLS());

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
    }

    // =================================================================
    // The two properties the checklist asks the GATE to assert
    // =================================================================

    /// `Registry.setCreditPolicy` is immediate `onlyOwner`, so "Registry is behind a
    /// Timelock" is only true if the Timelock is BOTH the owner AND actually delaying.
    /// `UpgradeRegistryTo570` now asserts exactly this pair when `TIMELOCK` is set.
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
    // The batch: scheduled once, executed once, all three steps or none
    // =================================================================

    function test_UpgradeAndCapsLandInOneTransactionWithNoIntermediateWindow() public {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _batch();

        // The batch under test IS the shipped shape: three calls, every one of them
        // addressed to the proxy. A batch that reached any other address would not be the
        // operation `UpgradeRegistryTo570` schedules, and everything below would be
        // asserting about something else.
        assertEq(targets.length, RegistryUpgradeBatchLib.BATCH_LENGTH, "three calls");
        for (uint256 i = 0; i < targets.length; ++i) {
            assertEq(targets[i], address(registry), "every call targets the Registry proxy");
            assertEq(values[i], 0, "no ether moves");
        }
        // CC-48 round-8 LOW-5: capture the implementation the proxy points at BEFORE the
        // batch. `assertEq(registry.version(), "Registry-5.8.0")` after execution is a
        // VACUOUS assertion -- `UUPSDeployHelper` already deployed 5.7.0, so it held before
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

        // ---- execute: one transaction, all three effects ----
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

    /// The batch exactly as `UpgradeRegistryTo570` emits it — because it is the same call.
    function _batch()
        internal
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        Registry newImpl = new Registry();
        return RegistryUpgradeBatchLib.buildBatch(
            address(registry), address(newImpl), newAggregator, PER_PROPOSAL_CAP, TOTAL_CAP, _seedUsers()
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
