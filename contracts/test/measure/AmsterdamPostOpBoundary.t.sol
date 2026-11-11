// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {RR5GuardBase} from "../v2/SuperPaymasterRR5GuardFail.t.sol";
import {SuperPaymasterStorage} from "src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol";
import {SuperPaymaster} from "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SelectedGasFixtures as GasFixture} from "../helpers/SelectedGasFixtures.sol";
import {PackedUserOperation} from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {IPaymaster} from "@account-abstraction-v7/interfaces/IPaymaster.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";

using SuperPaymasterAdminCalls for SuperPaymaster;

abstract contract AmsterdamPostOpBoundaryMeasure is RR5GuardBase {
    error ProbeResult(uint8 kind);
    uint256 private probeNonce;

    function _freshAdmission(uint256 nonce, bool lowerGuard) private returns (bytes memory ctx) {
        PackedUserOperation memory op;
        op.sender = user;
        op.nonce = nonce << 64;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(GasFixture.PM_VERIFICATION), uint128(GasFixture.MIN_POST()),
            operator, type(uint256).max, address(token), uint8(0)
        );
        vm.prank(EP);
        uint256 vd;
        (ctx, vd) = sp.validatePaymasterUserOp(op, keccak256(abi.encode("measure", nonce)), 1e16);
        assertEq(vd & 1, 0);
        if (lowerGuard) {
            uint256 snap;
            assembly ("memory-safe") { snap := mload(add(ctx, 384)) }
            snap = (snap & ~(uint256(type(uint32).max) << 32)) | (uint256(155_000) << 32);
            assembly ("memory-safe") { mstore(add(ctx, 384), snap) }
        }
    }

    function _invokeContext(bytes memory ctx, uint256 gasBudget) private returns (bool, bytes memory) {
        bytes memory data = abi.encodeCall(
            IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei)
        );
        vm.prank(EP);
        return address(sp).call{gas: gasBudget}(data);
    }

    /// @dev The deliberate outer revert restores both persistent and transient state after a
    /// successful postOp. vm.snapshot/revertTo does not restore EIP-1153 transient slots.
    function probeAndRollback(uint256 gasBudget, uint256 nonce, bool lowerGuard) external {
        storedContext = _freshAdmission(nonce, lowerGuard);
        (bool ok, bytes memory ret) = invoke(gasBudget);
        if (ok) revert ProbeResult(2);
        if (keccak256(ret) == keccak256(abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector))) {
            revert ProbeResult(0);
        }
        revert ProbeResult(1);
    }

    function probeBundleAndRollback(uint256 gasBudget, uint256 nonce, uint8 targetIndex) external {
        bytes memory first = _freshAdmission(nonce, true);
        bytes memory last = _freshAdmission(nonce + 1, true);
        bool ok;
        bytes memory ret;
        if (targetIndex == 0) {
            (ok, ret) = _invokeContext(first, gasBudget);
        } else {
            (ok,) = _invokeContext(first, GasFixture.MIN_POST());
            assertTrue(ok, "bundle prefix completes");
            (ok, ret) = _invokeContext(last, gasBudget);
        }
        if (ok) revert ProbeResult(2);
        if (keccak256(ret) == keccak256(abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector))) {
            revert ProbeResult(0);
        }
        revert ProbeResult(1);
    }

    function _classify(uint256 gasBudget, bool lowerGuard) internal returns (uint8 kind) {
        ++probeNonce;
        (bool outerOk, bytes memory result) = address(this).call(
            abi.encodeCall(this.probeAndRollback, (gasBudget, probeNonce, lowerGuard))
        );
        assertFalse(outerOk);
        assertEq(bytes4(result), ProbeResult.selector);
        assembly ("memory-safe") { kind := mload(add(result, 36)) }
    }

    function _firstAtLeast(uint8 wanted, bool lowerGuard) internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 800_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_classify(mid, lowerGuard) >= wanted) hi = mid;
            else lo = mid;
        }
    }

    function _classifyBundle(uint256 gasBudget, uint8 targetIndex) internal returns (uint8 kind) {
        probeNonce += 2;
        (bool outerOk, bytes memory result) = address(this).call(
            abi.encodeCall(this.probeBundleAndRollback, (gasBudget, probeNonce, targetIndex))
        );
        assertFalse(outerOk);
        assertEq(bytes4(result), ProbeResult.selector);
        assembly ("memory-safe") { kind := mload(add(result, 36)) }
    }

    function _firstBundleComplete(uint8 targetIndex) internal returns (uint256 hi) {
        uint256 lo = 100_000;
        hi = 800_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_classifyBundle(mid, targetIndex) >= 2) hi = mid;
            else lo = mid;
        }
    }

    function _measureBoundaries() internal {
        release();
        uint256 firstAdmitted = _firstAtLeast(1, false);
        uint256 firstComplete = _firstAtLeast(2, false);
        uint256 workloadAdmission = _firstAtLeast(1, true);
        uint256 workloadComplete = _firstAtLeast(2, true);
        uint256 bundleFirstComplete = _firstBundleComplete(0);
        uint256 bundleLastComplete = _firstBundleComplete(1);
        emit log_named_uint("MEASURE first guard-admitted call gas", firstAdmitted);
        emit log_named_uint("MEASURE first completing call gas", firstComplete);
        emit log_named_uint("MEASURE lowered-guard admission", workloadAdmission);
        emit log_named_uint("MEASURE actual workload completion", workloadComplete);
        emit log_named_uint("MEASURE two-op first completion", bundleFirstComplete);
        emit log_named_uint("MEASURE two-op last completion", bundleLastComplete);
        emit log_named_uint("MEASURE OOG band width", firstComplete - firstAdmitted);
        assertEq(_classify(firstAdmitted - 1, false), 0);
        assertEq(_classify(firstAdmitted, false), 2);
        assertEq(_classify(workloadAdmission - 1, true), 0);
        uint8 belowWorkloadCompletion = _classify(workloadComplete - 1, true);
        if (vm.envOr("PROFILE_AMSTERDAM", false)) {
            assertEq(belowWorkloadCompletion, 1, "Amsterdam exposes the lowered-guard OOG band");
        } else {
            assertLt(belowWorkloadCompletion, 2, "pre-completion sample does not complete");
        }
        assertEq(_classify(workloadComplete, true), 2);
    }

    function _measureFloorTupleBand() internal {
        release();
        vm.prank(owner);
        sp.queueGasParams(375_000, 355_000, 5_000, 370_000);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        vm.prank(owner);
        sp.executeGasParams();
        sp.updatePrice();
        uint256 firstAdmitted = _firstAtLeast(1, false);
        uint256 firstComplete = _firstAtLeast(2, false);
        emit log_named_uint("MEASURE floor first admitted", firstAdmitted);
        emit log_named_uint("MEASURE floor first complete", firstComplete);
        emit log_named_uint("MEASURE floor OOG band width", firstComplete - firstAdmitted);
        assertEq(_classify(firstAdmitted - 1, false), 0);
        assertEq(firstComplete, firstAdmitted, "new governance floor admits no OOG band");
        assertEq(_classify(firstComplete, false), 2);
    }
}

contract AmsterdamPostOpBoundaryBalanceMeasure is AmsterdamPostOpBoundaryMeasure {
    function creditMode() internal pure override returns (bool) { return false; }

    function test_measure_amsterdam_boundary() public {
        _measureBoundaries();
    }
}

contract AmsterdamPostOpBoundaryCreditMeasure is AmsterdamPostOpBoundaryMeasure {
    function creditMode() internal pure override returns (bool) { return true; }

    function test_measure_amsterdam_boundary() public {
        _measureBoundaries();
    }

    function test_measure_amsterdam_floor_tuple_band() public {
        _measureFloorTupleBand();
    }
}
