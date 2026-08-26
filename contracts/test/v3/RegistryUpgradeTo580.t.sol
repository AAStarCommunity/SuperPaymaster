// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IMySBT.sol";
import {RegistryUpgradeBatchLib} from "../../script/checks/RegistryUpgradeBatchLib.sol";

/// @notice CC-48 MEDIUM-3 — the 5.6.0 migration must be executed as ONE governance
///         batch. These tests pin down what actually breaks in each gap, so the
///         runbook is backed by executable evidence rather than a warning.

contract UpgradeMockSBT is IMySBT {
    function mintForRole(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function airdropMint(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
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

contract UpgradeMockBLS {
    function defaultThreshold() external pure returns (uint256) { return 2; }
    function verify(bytes32, uint256, uint256, bytes calldata) external pure returns (bool) { return true; }
}

/// @notice Stand-in for the deployed BLSAggregator 4.3.x: same surface MINUS
///         consumeGuardianExit, and — like the real contract — no fallback.
contract LegacyAggregatorNoExitGate {
    function defaultThreshold() external pure returns (uint256) { return 2; }
    function verify(bytes32, uint256, uint256, bytes calldata) external pure returns (bool) { return true; }
}

/// @notice Minimal governance stand-in: a contract owner, i.e. what the deployment
///         gate demands. Executes an arbitrary batch in ONE transaction.
contract BatchOwner {
    error BatchStepFailed(uint256 index, bytes reason);

    function executeBatch(address[] calldata targets, bytes[] calldata payloads) external {
        for (uint256 i = 0; i < targets.length; i++) {
            (bool ok, bytes memory reason) = targets[i].call(payloads[i]);
            if (!ok) revert BatchStepFailed(i, reason);
        }
    }

    function callOne(address target, bytes calldata payload) external {
        (bool ok, bytes memory reason) = target.call(payload);
        if (!ok) revert BatchStepFailed(0, reason);
    }
}

contract RegistryUpgradeTo580Test is Test {
    BatchOwner governance;
    Registry registry;
    UpgradeMockBLS newAggregator;
    address source = address(0x5150);

    function _user(uint256 i) internal pure returns (address) {
        return address(uint160(0xB000 + i));
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(uint256(3), bytes(""));
    }

    function _submit(uint256 id, address user, uint256 score, uint256 epoch) internal {
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = user;
        scores[0] = score;
        vm.prank(source);
        registry.batchUpdateGlobalReputation(id, users, scores, epoch, _proof());
    }


    // ---- CC-48 round-9: what a PRE-5.8.0 proxy actually looks like ----
    // 5.8.0 appends four slots (27..30). On a live proxy that was initialized by an older
    // implementation, every one of them reads zero — including `creditPopulationSeededAt`,
    // which is the slot that shuts the reputation path until governance has counted the
    // users. A fixture that deploys 5.8.0 and calls `initialize` does NOT reproduce that
    // state (initialize seeds it, correctly, because a fresh Registry provably has no
    // users), so the migration tests below zero the slots by hand rather than testing a
    // world the migration will never meet.
    uint256 internal constant SLOT_TOTAL_CREDIT_EXPOSURE = 25;
    uint256 internal constant SLOT_MAX_TOTAL_CREDIT_EXPOSURE = 26;
    uint256 internal constant SLOT_CREDIT_POPULATION_TOTAL = 27;
    uint256 internal constant SLOT_CREDIT_POPULATION_EPOCH = 29;
    uint256 internal constant SLOT_CREDIT_POPULATION_SEEDED_AT = 30;

    function _makeProxyLookPre580() internal {
        _forgetPopulationMarkers(_twoSeedUsers());
        vm.store(address(registry), bytes32(SLOT_TOTAL_CREDIT_EXPOSURE), bytes32(0));
        vm.store(address(registry), bytes32(SLOT_MAX_TOTAL_CREDIT_EXPOSURE), bytes32(0));
        vm.store(address(registry), bytes32(SLOT_CREDIT_POPULATION_TOTAL), bytes32(0));
        vm.store(address(registry), bytes32(SLOT_CREDIT_POPULATION_EPOCH), bytes32(0));
        vm.store(address(registry), bytes32(SLOT_CREDIT_POPULATION_SEEDED_AT), bytes32(0));
    }

    /// A pre-5.8.0 proxy has never written a population marker for anyone; the fixture's
    /// own proposals (run against the new implementation) did, so clear them too.
    function _forgetPopulationMarkers(address[] memory users) internal {
        for (uint256 i = 0; i < users.length; i++) {
            vm.store(
                address(registry),
                keccak256(abi.encode(users[i], uint256(28))), // creditPopulationEpochOf
                bytes32(0)
            );
        }
    }

    function _twoSeedUsers() internal pure returns (address[] memory users) {
        users = new address[](2);
        users[0] = _user(1);
        users[1] = _user(2);
    }

    function setUp() public {
        governance = new BatchOwner();
        UpgradeMockSBT sbt = new UpgradeMockSBT();
        Registry impl = new Registry();
        registry = Registry(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(Registry.initialize, (address(governance), address(0), address(sbt)))
                )
            )
        );
        newAggregator = new UpgradeMockBLS();

        // Pre-upgrade world: users already carry reputation, and the protocol-wide
        // budget does not exist yet (slot reads 0 on a freshly upgraded proxy).
        governance.callOne(
            address(registry), abi.encodeCall(Registry.setBLSAggregator, (address(newAggregator)))
        );
        governance.callOne(address(registry), abi.encodeCall(Registry.setReputationSource, (source, true)));
        governance.callOne(address(registry), abi.encodeCall(Registry.setCreditTier, (1, 0)));
        governance.callOne(
            address(registry),
            abi.encodeCall(Registry.setCreditPolicy, (type(uint256).max, type(uint256).max))
        );
        _submit(1, _user(1), 100, 1);
        _submit(2, _user(2), 100, 1);
    }

    /// Gap 1: impl upgraded, nothing configured yet → the new ceiling reads 0 AND the
    /// population is unseeded. Both halt issuance; the second one is what round-9 added,
    /// and it is the half that cannot be satisfied by an operator typing a number.
    function test_UpgradedProxyWithoutPolicyHaltsIssuance() public {
        _makeProxyLookPre580();

        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(3);
        scores[0] = 100;

        // Unseeded population is checked BEFORE anything else about the credit maths, so
        // this is the error a real migration hits first.
        vm.prank(source);
        vm.expectRevert(Registry.CreditPopulationNotSeeded.selector);
        registry.batchUpdateGlobalReputation(3, users, scores, 1, _proof());

        // Seeding alone does not open the gate either — and it does not even land: the
        // ceiling still reads 0, and finalizing a count checks the DERIVED stock against
        // it. This is why the shipped batch orders `setCreditPolicy` before
        // `seedCreditPopulation`; the wrong order fails atomically instead of going live.
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchOwner.BatchStepFailed.selector,
                uint256(0),
                abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, 1200 ether, 0)
            )
        );
        governance.callOne(
            address(registry),
            abi.encodeCall(Registry.seedCreditPopulation, (_twoSeedUsers(), 2, true))
        );

        // Caps first, then the count: now the path opens, and the stock the contract
        // derived for itself is what every later proposal is measured against.
        governance.callOne(
            address(registry), abi.encodeCall(Registry.setCreditPolicy, (600 ether, 5_000 ether))
        );
        governance.callOne(
            address(registry),
            abi.encodeCall(Registry.seedCreditPopulation, (_twoSeedUsers(), 2, true))
        );
        assertEq(registry.totalCreditExposure(), 1200 ether, "derived, not declared");
        _submit(3, _user(3), 100, 1);
        assertEq(registry.totalCreditExposure(), 1800 ether);
    }

    /// CC-48 round-9 MEDIUM-HIGH-B3: a ceiling BELOW the exposure that already exists is
    /// refused outright, instead of being accepted and wedging the reputation path on the
    /// next proposal. Round-8 accepted it (and the migration script only checked the
    /// operator's own baseline number against it, so a wrong baseline passed the check).
    function test_CeilingBelowLiveExposureIsRefused() public {
        assertEq(registry.totalCreditExposure(), 1200 ether, "fixture carries live exposure");
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchOwner.BatchStepFailed.selector,
                uint256(0),
                abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, 1200 ether, 600 ether)
            )
        );
        governance.callOne(
            address(registry), abi.encodeCall(Registry.setCreditPolicy, (600 ether, 600 ether))
        );
    }

    /// Gap 2: aggregator not swapped in the same batch → the legacy 4.3.x aggregator
    /// has no consumeGuardianExit and no fallback, so ROLE_DVT exits revert outright.
    /// This is fail-closed (good) but it strands DVT stake for the whole gap.
    function test_LegacyAggregatorMakesDvtExitRevert() public {
        GToken gtoken = new GToken(1_000_000 ether);
        GTokenStaking staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        governance.callOne(address(registry), abi.encodeCall(Registry.setStaking, (address(staking))));

        IRegistry.RoleConfig memory dvtConfig = registry.getRoleConfig(ROLE_DVT);
        dvtConfig.roleLockDuration = 0;
        governance.callOne(address(registry), abi.encodeCall(Registry.configureRole, (ROLE_DVT, dvtConfig)));

        address guardian = address(0x6001);
        gtoken.mint(guardian, 100 ether);
        vm.prank(guardian);
        gtoken.approve(address(staking), 100 ether);
        vm.prank(guardian);
        registry.registerRole(ROLE_DVT, guardian, abi.encode(uint256(30 ether)));

        LegacyAggregatorNoExitGate legacy = new LegacyAggregatorNoExitGate();
        governance.callOne(address(registry), abi.encodeCall(Registry.setBLSAggregator, (address(legacy))));

        vm.prank(guardian);
        vm.expectRevert();
        registry.exitRole(ROLE_DVT);
    }

    /// The batch as the runbook prescribes it: upgrade + rewire + caps + POPULATION in ONE
    /// transaction, against a proxy that really does read zero in the 5.8.0 slots.
    ///
    /// CC-48 round-9 MEDIUM-HIGH-B3: the number 1200 below is never typed into the batch.
    /// Round-8 passed it in as `CREDIT_EXPOSURE_BASELINE`, an operator-computed aPNT total
    /// whose documented derivation (sum `GlobalReputationUpdated`) structurally omitted
    /// every address still holding the `initialize` tier-1 default. Here the batch passes
    /// only the two ADDRESSES, and the contract reads their reputation out of its own
    /// storage to arrive at 1200 by itself. Getting the membership list wrong is still
    /// possible; getting the arithmetic wrong is not, and an unseeded proxy issues nothing.
    function test_AtomicBatchUpgradesRewiresAndDerivesTheBaseline() public {
        Registry newImpl = new Registry();
        UpgradeMockBLS rotatedAggregator = new UpgradeMockBLS();
        _makeProxyLookPre580();

        uint256 totalCap = 1800 ether;

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            RegistryUpgradeBatchLib.buildBatch(
                address(registry), address(newImpl), address(rotatedAggregator),
                address(0), address(registry.GTOKEN_STAKING()), 600 ether, totalCap, _twoSeedUsers()
            );
        values; // the batch carries no value; silence the unused-return warning
        governance.executeBatch(targets, payloads);

        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-5.8.0"));
        assertEq(registry.blsAggregator(), address(rotatedAggregator));
        assertEq(
            registry.totalCreditExposure(),
            1200 ether,
            "exposure DERIVED from the two users' on-chain reputation, not supplied"
        );
        assertEq(registry.creditPopulationTotal(), 2, "population counted");
        assertGt(registry.creditPopulationSeededAt(), 0, "reputation path opened");
        assertEq(registry.maxTotalCreditExposure(), totalCap);
        // Pre-upgrade state survived the implementation swap.
        assertEq(registry.globalReputation(_user(1)), 100);
        assertEq(registry.getCreditLimit(_user(2)), 600 ether);

        // Exactly one more user fits inside the ceiling...
        _submit(3, _user(3), 100, 1);
        assertEq(registry.totalCreditExposure(), totalCap, "budget consumed to the ceiling");

        // ...and the next one is refused, counted against the DERIVED stock rather than
        // against a total that started at zero.
        vm.prank(source);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, 2400 ether, totalCap)
        );
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(4);
        scores[0] = 100;
        registry.batchUpdateGlobalReputation(4, users, scores, 1, _proof());
    }

    /// CC-48 round-9 MEDIUM-HIGH-B3: the migration's remaining trusted input is the
    /// MEMBERSHIP list, and a member left out of it is not lost silently — the first
    /// proposal that touches them books their whole standing above-floor limit.
    function test_SeedMissingAUserSelfHealsOnNextTouch() public {
        Registry newImpl = new Registry();
        _makeProxyLookPre580();

        address[] memory partialList = new address[](1);
        partialList[0] = _user(1); // _user(2) is MISSED, and also carries 600 aPNT
        (address[] memory targets, , bytes[] memory payloads) = RegistryUpgradeBatchLib.buildBatch(
            address(registry), address(newImpl), address(newAggregator),
            address(0), address(registry.GTOKEN_STAKING()), 600 ether, 5_000 ether, partialList
        );
        governance.executeBatch(targets, payloads);

        assertEq(registry.totalCreditExposure(), 600 ether, "under-counted, as the operator asked");

        // Touching the missed user books the stock the seed never saw: 600 backfill, and
        // this proposal itself issues nothing (same level in, same level out).
        _submit(9, _user(2), 100, 2);
        assertEq(
            registry.totalCreditExposure(),
            1200 ether,
            "the missed user's standing limit is booked on first touch, not lost"
        );
    }

    /// Rollback: re-pointing the proxy at the previous implementation must not lose
    /// or reinterpret any storage the batch wrote.
    function test_RollbackPreservesStorage() public {
        address implBefore = address(uint160(uint256(
            vm.load(address(registry), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
        )));

        Registry newImpl = new Registry();
        governance.callOne(
            address(registry),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes(""))
        );
        governance.callOne(
            address(registry), abi.encodeCall(Registry.setCreditPolicy, (600 ether, 5000 ether))
        );
        assertEq(registry.totalCreditExposure(), 1200 ether);

        governance.callOne(
            address(registry),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implBefore, bytes(""))
        );

        assertEq(registry.totalCreditExposure(), 1200 ether, "exposure survived rollback");
        assertEq(registry.maxTotalCreditExposure(), 5000 ether);
        assertEq(registry.globalReputation(_user(1)), 100);
        assertEq(registry.owner(), address(governance));
    }

    /// CC-48 MEDIUM-1 deployment gate: the credit policy and the aggregator pointer
    /// are only reachable through the contract owner. An EOA holding those keys is
    /// exactly the configuration the upgrade script refuses to emit a batch for.
    function test_PolicyAndAggregatorAreOwnerOnly() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        registry.setCreditPolicy(1, 1);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        registry.setBLSAggregator(address(0xDEAD));

        assertGt(registry.owner().code.length, 0, "owner must be a Safe/Timelock contract");
    }
}
