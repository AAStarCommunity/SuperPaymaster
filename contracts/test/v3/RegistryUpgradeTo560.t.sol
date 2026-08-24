// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IMySBT.sol";

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

contract RegistryUpgradeTo560Test is Test {
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
            abi.encodeCall(Registry.setCreditPolicy, (type(uint256).max, type(uint256).max, 0, true))
        );
        _submit(1, _user(1), 100, 1);
        _submit(2, _user(2), 100, 1);
    }

    /// Gap 1: impl upgraded, policy not yet set → the new ceiling reads 0 and every
    /// positive-uplift proposal reverts. Fail-closed, but a governance halt.
    function test_UpgradedProxyWithoutPolicyHaltsIssuance() public {
        governance.callOne(
            address(registry),
            abi.encodeCall(Registry.setCreditPolicy, (type(uint256).max, 0, 0, true))
        );

        vm.prank(source);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, 600 ether, 0)
        );
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(3);
        scores[0] = 100;
        registry.batchUpdateGlobalReputation(3, users, scores, 1, _proof());
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

    /// The batch as the runbook prescribes it: upgrade + rewire + seed policy in ONE
    /// transaction. Storage survives, the baseline is honoured, and the protocol-wide
    /// bound is live from the first block after the batch.
    function test_AtomicBatchUpgradesRewiresAndSeedsBaseline() public {
        Registry newImpl = new Registry();
        UpgradeMockBLS rotatedAggregator = new UpgradeMockBLS();

        // Off-chain accounting: two users at L1 => 1200 aPNT already outstanding.
        uint256 baseline = 1200 ether;
        uint256 totalCap = 1800 ether;

        address[] memory targets = new address[](3);
        bytes[] memory payloads = new bytes[](3);
        targets[0] = address(registry);
        payloads[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes(""));
        targets[1] = address(registry);
        payloads[1] = abi.encodeCall(Registry.setBLSAggregator, (address(rotatedAggregator)));
        targets[2] = address(registry);
        payloads[2] = abi.encodeCall(Registry.setCreditPolicy, (600 ether, totalCap, baseline, true));

        governance.executeBatch(targets, payloads);

        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-5.6.0"));
        assertEq(registry.blsAggregator(), address(rotatedAggregator));
        assertEq(registry.totalCreditExposure(), baseline, "baseline seeded, not 0");
        assertEq(registry.maxTotalCreditExposure(), totalCap);
        // Pre-upgrade state survived the implementation swap.
        assertEq(registry.globalReputation(_user(1)), 100);
        assertEq(registry.getCreditLimit(_user(2)), 600 ether);

        // Exactly one more user fits inside the ceiling...
        _submit(3, _user(3), 100, 1);
        assertEq(registry.totalCreditExposure(), totalCap, "budget consumed to the ceiling");

        // ...and the next one is refused, counted against the SEEDED baseline rather
        // than against a total that started at zero.
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
            address(registry), abi.encodeCall(Registry.setCreditPolicy, (600 ether, 5000 ether, 1200 ether, true))
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
        registry.setCreditPolicy(1, 1, 0, true);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        registry.setBLSAggregator(address(0xDEAD));

        assertGt(registry.owner().code.length, 0, "owner must be a Safe/Timelock contract");
    }
}
