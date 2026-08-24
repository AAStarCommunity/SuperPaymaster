// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GToken} from "src/tokens/GToken.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {Registry} from "src/core/Registry.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";
import {BLSKeyScanLib} from "../../script/checks/BLSKeyScanLib.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract KeyScanDVTStub {
    function markProposalExecuted(uint256) external {}
}

contract KeyScanFraudVerifier {
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/**
 * @title CC48KeyScanPreflight
 * @notice CC-48 round-3 MEDIUM-4: the migration preflight is only a gate if something
 *         runs it. This suite runs `BLSKeyScanLib` — the exact library
 *         `UpgradeRegistryTo570` now calls before emitting a governance batch — against
 *         live aggregators, so a regression in the gate fails CI instead of failing a
 *         mainnet cutover.
 *
 * @dev Real EIP-2537 only: the weak-key check recomputes g1*s on the MSM precompile, and
 *      the library fails CLOSED when those precompiles are absent (a scan that cannot run
 *      must never report "clean"). That fail-closed behaviour is itself asserted below.
 *
 *      Run:
 *        forge test --evm-version prague --match-contract CC48KeyScanPreflight -vv
 */
contract CC48KeyScanPreflight is Test {
    bytes32 internal constant ROLE_DVT = keccak256("DVT");
    uint256 internal constant DVT_STAKE = 30 ether;

    bool internal pragueAvailable;

    GToken internal gtoken;
    GTokenStaking internal staking;
    MySBT internal sbt;
    Registry internal registry;
    KeyScanDVTStub internal dvtSink;

    function setUp() public {
        pragueAvailable = _hasPraguePrecompiles();
        if (!pragueAvailable) return;

        vm.warp(1_800_000_000);
        gtoken = new GToken(21_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(0));
        staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), address(this));
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));
        dvtSink = new KeyScanDVTStub();

        Registry.RoleConfig memory dvtConfig = registry.getRoleConfig(ROLE_DVT);
        dvtConfig.roleLockDuration = 0;
        registry.configureRole(ROLE_DVT, dvtConfig);
    }

    /// A validator set built from the small public scalars — exactly the state the
    /// RepCredit experiment stack was found in — must fail the gate. Nothing about the
    /// key's shape gives this away; only recomputing g1*s does.
    function test_WeakScalarKeysFailTheGate() public {
        _skipWithoutPrague();
        BLSAggregator agg = _freshAggregator();
        _seatValidators(agg, 3, 1); // scalars 1, 2, 3

        vm.expectRevert(abi.encodeWithSelector(BLSKeyScanLib.WeakKeysFound.selector, address(agg), uint256(3)));
        this.callRequireHealthy(address(agg), 3);
    }

    /// An empty (or under-populated) fresh deployment must fail BEFORE it is wired into
    /// Registry. This is the governance-outage case: a 4.7.0 starts with no keys, and
    /// cutting over first means every BLS-gated path reverts until onboarding finishes.
    function test_UnderPopulatedFreshDeploymentFailsTheGate() public {
        _skipWithoutPrague();
        BLSAggregator agg = _freshAggregator();

        vm.expectRevert(
            abi.encodeWithSelector(BLSKeyScanLib.TooFewDistinctKeys.selector, address(agg), uint256(0), uint256(3))
        );
        this.callRequireHealthy(address(agg), 3);

        // Two of the three required signers onboarded: still refused.
        _seatValidators(agg, 2, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(BLSKeyScanLib.TooFewDistinctKeys.selector, address(agg), uint256(2), uint256(3))
        );
        this.callRequireHealthy(address(agg), 3);
    }

    /// The passing case, so the gate is not merely "always reverts": distinct keys well
    /// outside the weak-scan window, quorum reachable.
    /// (Scalars 1000+ are still public test vectors — they are simply not in the range a
    /// scanner can brute-force, which is the property under test here, not secrecy.)
    function test_AHealthySetPassesTheGate() public {
        _skipWithoutPrague();
        BLSAggregator agg = _freshAggregator();
        _seatValidators(agg, 3, 1000);

        BLSKeyScanLib.ScanResult memory result = BLSKeyScanLib.requireHealthy(address(agg), 3);
        assertEq(result.activeSlots, 3);
        assertEq(result.distinctKeys, 3);
        assertEq(result.duplicates, 0);
        assertEq(result.weakKeys, 0);
    }

    /// `maxRequiredThreshold` must read EVERY path's threshold, not just the reputation
    /// one — a set that satisfies the reputation quorum but not slashThresholds[MAJOR]
    /// leaves the slash path silently unusable.
    function test_RequiredThresholdCoversTheSlashPathsToo() public {
        _skipWithoutPrague();
        BLSAggregator agg = _freshAggregator();
        agg.setMinThreshold(2);
        agg.setDefaultThreshold(3);
        agg.setSlashThreshold(2, 9); // MAJOR needs 9 signers

        assertEq(BLSKeyScanLib.maxRequiredThreshold(address(agg)), 9, "the largest threshold wins");
    }

    /// The check that makes "fresh deployment, fresh keys" enforceable: a key that is
    /// publicly known on the OLD aggregator must not reappear on the NEW one, even
    /// though the new contract's own guards are perfectly happy with it.
    function test_TaintedKeyCannotBeCarriedOverToTheNewAggregator() public {
        _skipWithoutPrague();
        BLSAggregator oldAgg = _freshAggregator();
        _seatValidators(oldAgg, 3, 1); // compromised: scalars 1, 2, 3

        BLSAggregator newAgg = _freshAggregator();
        // The operator re-onboards the SAME (publicly known) key on the new deployment.
        address v = address(uint160(0x3000));
        BLS.G1Point memory pk = _publicKey(1);
        newAgg.registerBLSPublicKey(v, pk, 1, _pop(newAgg, v, pk, 1));

        bytes32 keyHash = keccak256(abi.encode(pk.x_a, pk.x_b, pk.y_a, pk.y_b));
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.TaintedKeyCarriedOver.selector, keyHash, address(uint160(0x3000)), v
            )
        );
        this.callRequireNoTaintedKeyCarriedOver(address(oldAgg), address(newAgg));
    }

    /// Cutting over while a case is still pending on the old aggregator silently lifts
    /// the freeze it represents. Enumerable for anyone still holding a slot.
    function test_PendingCaseOnTheOldAggregatorBlocksTheCutover() public {
        _skipWithoutPrague();
        BLSAggregator oldAgg = _freshAggregator();
        _seatValidators(oldAgg, 3, 1000);
        address accusedGuardian = address(uint160(0x3000));

        KeyScanFraudVerifier verifier = new KeyScanFraudVerifier();
        oldAgg.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + oldAgg.VERIFIER_ROTATION_DELAY());
        oldAgg.applyFraudProofVerifier();

        address[] memory accused = new address[](1);
        accused[0] = accusedGuardian;
        oldAgg.queueGuardianSlash(1, accused, hex"01");

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PendingCaseOnOldAggregator.selector,
                address(oldAgg),
                accusedGuardian,
                uint256(1)
            )
        );
        this.callRequireNoPendingCases(address(oldAgg));

        // Once resolved, the cutover is clear.
        oldAgg.executeGuardianSlash(1, accused, hex"01");
        this.callRequireNoPendingCases(address(oldAgg));
    }

    /// Fail CLOSED without EIP-2537. A weak-key scan that cannot run must never be
    /// mistaken for a clean result — which is precisely what the pre-round-3 script
    /// would have done on a non-Prague RPC.
    function test_ScanRefusesToRunWithoutEip2537() public {
        _skipWithoutPrague();
        BLSAggregator agg = _freshAggregator();
        _seatValidators(agg, 3, 1000);

        // Make the G1ADD probe return the wrong shape, i.e. "no EIP-2537 here".
        vm.mockCall(address(0x0b), "", hex"");
        vm.expectRevert(BLSKeyScanLib.EIP2537Unavailable.selector);
        this.callRequireHealthy(address(agg), 3);
        vm.clearMockedCalls();
    }

    // =================================================================
    // External wrappers — `vm.expectRevert` needs a real CALL boundary for a
    // library's internal function to revert across.
    // =================================================================

    function callRequireHealthy(address agg, uint256 minDistinct) external view {
        BLSKeyScanLib.requireHealthy(agg, minDistinct);
    }

    function callRequireNoTaintedKeyCarriedOver(address oldAgg, address newAgg) external view {
        BLSKeyScanLib.requireNoTaintedKeyCarriedOver(oldAgg, newAgg);
    }

    function callRequireNoPendingCases(address agg) external view {
        BLSKeyScanLib.requireNoPendingCases(agg);
    }

    // =================================================================
    // Helpers
    // =================================================================

    function _freshAggregator() internal returns (BLSAggregator agg) {
        agg = new BLSAggregator(address(registry), address(0xBEEF), address(dvtSink));
        agg.setMinThreshold(2);
        agg.setDefaultThreshold(2);
        staking.setAuthorizedSlasher(address(agg), true);
    }

    /// @dev Seats `count` validators holding scalars `firstScalar .. firstScalar+count-1`.
    ///      Addresses are scalar-independent so the same validator set can be re-created
    ///      on a second aggregator with different keys.
    function _seatValidators(BLSAggregator agg, uint256 count, uint256 firstScalar) internal {
        for (uint256 i = 0; i < count; ++i) {
            address validator = address(uint160(0x3000 + i));
            uint256 scalar = firstScalar + i;
            if (!registry.hasRole(ROLE_DVT, validator)) {
                gtoken.mint(validator, 40 ether);
                vm.startPrank(validator);
                gtoken.approve(address(staking), 40 ether);
                registry.registerRole(ROLE_DVT, validator, abi.encode(DVT_STAKE));
                vm.stopPrank();
            }
            BLS.G1Point memory pk = _publicKey(scalar);
            agg.registerBLSPublicKey(validator, pk, uint8(i + 1), _pop(agg, validator, pk, scalar));
        }
    }

    function _pop(BLSAggregator agg, address validator, BLS.G1Point memory pk, uint256 sk)
        internal
        view
        returns (BLS.G2Point memory)
    {
        return _multiplyG2(BLS.hashToG2(abi.encodePacked(agg.popDigest(validator, pk))), sk);
    }

    function _publicKey(uint256 scalar) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory points = new BLS.G1Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = BLSKeyScanLib.g1Generator();
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _multiplyG2(BLS.G2Point memory point, uint256 scalar) internal view returns (BLS.G2Point memory) {
        BLS.G2Point[] memory points = new BLS.G2Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = point;
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _hasPraguePrecompiles() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        return ok && result.length == 128;
    }

    function _skipWithoutPrague() internal {
        if (!pragueAvailable) vm.skip(true);
    }
}
