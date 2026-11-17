// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GToken} from "src/tokens/GToken.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {Registry} from "src/core/Registry.sol";
import {DVTValidator} from "src/modules/monitoring/DVTValidator.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";
import {IRegistry} from "src/interfaces/v3/IRegistry.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract ReentrySuperPaymasterStub {
    function queueSlash(address) external {}
    function executeSlashWithBLS(address, uint8, bytes calldata) external {}
}

/// @notice Daybreak 053117cc M-01 regression. Before the fix, a guardian that completed the exit
///         procedure regained (i) proposer power and (ii) quorum weight just by re-registering
///         ROLE_DVT, with no new PoP and no owner approval (both reproduced on 053117cc). A
///         completed exit now suspends the guardian and retires its key. Real keys, Prague.
contract GuardianExitReentryPrague is Test {
    bytes32 private constant ROLE_DVT = keccak256("DVT");
    uint256 private constant N = 4;

    address[N] private validators = [address(0x201), address(0x202), address(0x203), address(0x204)];
    uint256[N] private sk = [uint256(11), 12, 13, 14];

    bool private prague;
    GToken private token;
    GTokenStaking private staking;
    Registry private registry;
    DVTValidator private dvt;
    BLSAggregator private bls;

    function setUp() public {
        prague = _hasPrague();
        if (!prague) return;
        token = new GToken(21_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(0));
        staking = new GTokenStaking(address(token), address(this), address(registry));
        MySBT sbt = new MySBT(address(token), address(staking), address(registry), address(this));
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(ROLE_DVT);
        cfg.roleLockDuration = 0;
        registry.configureRole(ROLE_DVT, cfg);

        dvt = new DVTValidator(address(registry), 1, new bytes32[](0), new address[](0));
        bls = new BLSAggregator(address(registry), address(new ReentrySuperPaymasterStub()), address(dvt));
        dvt.setBLSAggregator(address(bls));
        registry.setBLSAggregator(address(bls));
        registry.setReputationSource(address(bls), true);
        bls.setMinThreshold(2);
        bls.setDefaultThreshold(2);

        for (uint256 i; i < N; ++i) {
            _stakeDvt(validators[i]);
            dvt.addValidator(validators[i]);
            BLS.G1Point memory pk = _publicKey(sk[i]);
            dvt.registerBLSPublicKey(validators[i], pk, uint8(i + 1), _pop(validators[i], pk, sk[i]));
        }
    }

    function _stakeDvt(address v) internal {
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(ROLE_DVT);
        uint256 amount = cfg.minStake + cfg.ticketPrice;
        token.mint(v, amount);
        vm.startPrank(v);
        token.approve(address(staking), amount);
        registry.registerRole(ROLE_DVT, v, abi.encode(cfg.minStake));
        vm.stopPrank();
    }

    /// Completes the exit procedure for `v` and has it re-register ROLE_DVT with fresh stake.
    function _exitAndReregister(address v) internal {
        vm.prank(v);
        bls.requestGuardianExit();
        (uint64 readyAt,) = bls.guardianExitRequests(v);
        vm.warp(uint256(readyAt) + bls.GUARDIAN_FRAUD_CHALLENGE());
        vm.prank(v);
        registry.exitRole(ROLE_DVT);
        assertFalse(registry.hasRole(ROLE_DVT, v), "precondition: exit completed");
        _stakeDvt(v);
        assertTrue(registry.hasRole(ROLE_DVT, v), "precondition: role re-acquired");
    }

    /// (ii) quorum weight: slot 4 signs with slot 1 for a 2-of-N reputation proof.
    function test_Prague_M01_ExitedGuardianKeyNoLongerCountsAfterRoleReentry() public {
        if (!prague) { vm.skip(true); return; }
        address v = validators[3];
        _exitAndReregister(v);
        (, uint8 slot, bool active) = bls.getBLSPublicKey(v);
        slot;

        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = address(0xCAFE);
        scores[0] = 30;
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(address(0), 0, "quorum with exited key", bytes32(0));
        bytes32 h = bls.reputationMessageHash(id, users, scores, 1);
        bytes memory proof = _proof(h, 0x9); // slots 1 and 4: the second signer is the re-entered key
        assertFalse(active, "completed exit retired the key");
        vm.prank(validators[0]);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnknownValidatorSlot.selector, uint8(4)));
        dvt.executeWithProof(id, users, scores, 1, "", proof);
        assertEq(registry.globalReputation(users[0]), 0, "the exited key no longer counts");
    }

    /// Re-admission is an owner decision plus a fresh PoP; after it the key counts again.
    function test_Prague_M01_ReadmissionNeedsOwnerAndFreshPoP() public {
        if (!prague) { vm.skip(true); return; }
        address v = validators[3];
        _exitAndReregister(v);
        assertTrue(bls.suspended(v), "exit leaves the guardian suspended");
        bls.setSuspended(v, false);
        BLS.G1Point memory pk = _publicKey(sk[3]);
        dvt.registerBLSPublicKey(v, pk, 4, _pop(v, pk, sk[3]));

        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = address(0xBEEF);
        scores[0] = 20;
        vm.prank(v);
        uint256 id = dvt.createProposal(address(0), 0, "re-admitted", bytes32(0));
        bytes memory proof = _proof(bls.reputationMessageHash(id, users, scores, 1), 0x9);
        vm.prank(v);
        dvt.executeWithProof(id, users, scores, 1, "", proof);
        assertEq(registry.globalReputation(users[0]), 20);
    }

    /// (i) proposer power: the re-entered address opens a DVT proposal.
    function test_Prague_M01_ExitedGuardianCannotProposeAfterRoleReentry() public {
        if (!prague) { vm.skip(true); return; }
        address v = validators[3];
        _exitAndReregister(v);
        assertTrue(bls.suspended(v), "completed exit suspended the guardian");
        vm.prank(v);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ValidatorSuspended.selector, v));
        dvt.createProposal(address(0), 0, "after exit", bytes32(0));
    }

    function _completeExit(address v) internal returns (uint256 balanceBefore) {
        balanceBefore = token.balanceOf(v);
        vm.prank(v);
        bls.requestGuardianExit();
        (uint64 readyAt,) = bls.guardianExitRequests(v);
        vm.warp(uint256(readyAt) + bls.GUARDIAN_FRAUD_CHALLENGE());
        vm.prank(v);
        registry.exitRole(ROLE_DVT);
        assertFalse(registry.hasRole(ROLE_DVT, v), "exit completed");
        assertEq(staking.getLockedStake(v, ROLE_DVT), 0, "stake unlocked");
    }

    /// T1: the two new lines must not block an exit whose target state already holds.
    function test_Prague_M01_ExitSucceedsWhenAlreadySuspended() public {
        if (!prague) { vm.skip(true); return; }
        address v = validators[3];
        vm.prank(v);
        bls.requestGuardianExit();
        bls.setSuspended(v, true); // suspended after filing, before completion
        (uint64 readyAt,) = bls.guardianExitRequests(v);
        vm.warp(uint256(readyAt) + bls.GUARDIAN_FRAUD_CHALLENGE());
        uint256 before = token.balanceOf(v);
        vm.prank(v);
        registry.exitRole(ROLE_DVT);
        assertGt(token.balanceOf(v), before, "stake returned to the guardian");
        assertTrue(bls.suspended(v));
    }

    function test_Prague_M01_ExitSucceedsWhenKeyAlreadyRevoked() public {
        if (!prague) { vm.skip(true); return; }
        address v = validators[3];
        vm.prank(v);
        bls.requestGuardianExit();
        bls.revokeBLSPublicKey(v); // owner revokes the key before completion
        (uint64 readyAt,) = bls.guardianExitRequests(v);
        vm.warp(uint256(readyAt) + bls.GUARDIAN_FRAUD_CHALLENGE());
        uint256 before = token.balanceOf(v);
        vm.prank(v);
        registry.exitRole(ROLE_DVT);
        assertGt(token.balanceOf(v), before, "stake returned to the guardian");
        (,, bool active) = bls.getBLSPublicKey(v);
        assertFalse(active);
    }

    function test_Prague_M01_ExitSucceedsForGuardianWithoutKey() public {
        if (!prague) { vm.skip(true); return; }
        address v = address(0x2FF);
        _stakeDvt(v); // ROLE_DVT holder that never registered a BLS key
        uint256 before = _completeExit(v);
        assertGt(token.balanceOf(v), before, "stake returned to the guardian");
    }

    /// T2: a suspended (exited) address cannot put its key back by itself.
    function test_Prague_M01_ExitedGuardianCannotSelfRegisterWhilePermissionless() public {
        if (!prague) { vm.skip(true); return; }
        address v = validators[3];
        _exitAndReregister(v);
        bls.setPermissionlessBLSRegistration(true);
        BLS.G1Point memory pk = _publicKey(sk[3]);
        BLS.G2Point memory pop = _pop(v, pk, sk[3]);
        vm.prank(v);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ValidatorSuspended.selector, v));
        dvt.registerBLSPublicKey(v, pk, 4, pop);
    }

    /// T3: with thresholds min 2 / default 2 / slash (2,3,3), exits stop at the largest
    ///     configured threshold. From 4 live guardians one exit leaves 3 (still runs);
    ///     the next exit request is refused by name, not by arithmetic, and the
    ///     remaining 3 keep producing proofs.
    function test_Prague_M01_ExitStopsAtTheLargestThreshold() public {
        if (!prague) { vm.skip(true); return; }
        _completeExit(validators[3]);
        vm.prank(validators[2]);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(2), uint256(3)));
        bls.requestGuardianExit();

        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = address(0xD00D);
        scores[0] = 10;
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(address(0), 0, "three left", bytes32(0));
        bytes memory proof = _proof(bls.reputationMessageHash(id, users, scores, 1), 0x3); // slots 1,2
        vm.prank(validators[0]);
        dvt.executeWithProof(id, users, scores, 1, "", proof);
        assertEq(registry.globalReputation(users[0]), 10);
    }

    function _proof(bytes32 h, uint256 mask) internal view returns (bytes memory) {
        BLS.G2Point memory m = BLS.hashToG2(abi.encodePacked(h));
        BLS.G2Point memory sig;
        bool first = true;
        for (uint256 i; i < N; ++i) {
            if (mask & (1 << i) == 0) continue;
            BLS.G2Point memory part = _mulG2(m, sk[i]);
            sig = first ? part : BLS.add(sig, part);
            first = false;
        }
        return abi.encode(mask, abi.encode(sig));
    }

    function _pop(address v, BLS.G1Point memory pk, uint256 s) internal view returns (BLS.G2Point memory) {
        return _mulG2(BLS.hashToG2(abi.encodePacked(bls.popDigest(v, pk))), s);
    }

    function _publicKey(uint256 s) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory p = new BLS.G1Point[](1);
        bytes32[] memory k = new bytes32[](1);
        p[0].x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        p[0].x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        p[0].y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        p[0].y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
        k[0] = bytes32(s);
        return BLS.msm(p, k);
    }

    function _mulG2(BLS.G2Point memory point, uint256 s) internal view returns (BLS.G2Point memory) {
        BLS.G2Point[] memory p = new BLS.G2Point[](1);
        bytes32[] memory k = new bytes32[](1);
        p[0] = point;
        k[0] = bytes32(s);
        return BLS.msm(p, k);
    }

    function _hasPrague() internal view returns (bool) {
        (bool ok, bytes memory r) = address(0x0B).staticcall(new bytes(256));
        return ok && r.length == 128;
    }
}
