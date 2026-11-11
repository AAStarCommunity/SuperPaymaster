// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {SuperPaymasterV55PostOpBoundTest} from "../v2/SuperPaymasterV55PostOpBound.t.sol";
import {SuperPaymasterStorage} from "src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol";
import {SuperPaymaster} from "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import {PackedUserOperation} from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {SelectedGasFixtures as GasFixture} from "../helpers/SelectedGasFixtures.sol";
import {MockAirAccount} from "../bundler/BLayerAccounts.sol";
import {IPBTok} from "../v2/SuperPaymasterV55PostOpBound.t.sol";
import {Vm} from "forge-std/Vm.sol";

using SuperPaymasterAdminCalls for SuperPaymaster;

contract AmsterdamHandleOpsFloorTest is SuperPaymasterV55PostOpBoundTest {
    error HandleOpsProbe(bool settled);

    // Each sample reverts its entire validation/execution/settlement transaction frame,
    // including transient state. First debt and lastTimestamp writes remain fresh.
    function probeHandleOps(uint128 limit, bool credit) external {
        address u = _freshUser(777, credit);
        PackedUserOperation memory op;
        op.sender = u;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(CALL_GAS)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(GasFixture.PM_VERIFICATION),
            limit, operator, type(uint256).max, address(token), uint8(0));
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        uint256 bal = token.balanceOf(u);
        vm.recordLogs();
        try entryPoint.handleOps(ops, payable(beneficiary)) {} catch { revert HandleOpsProbe(false); }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool success;
        bool reverted;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != EP || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)")) reverted = true;
            if (logs[i].topics[0] == keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")) {
                (, success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
            }
        }
        bool settled = success && !reverted && token.usedOpHashes(h)
            && token.lockedOf(u) == 0 && token.creditReservedOf(u) == 0
            && (credit ? token.debts(u) > 0 : token.balanceOf(u) < bal);
        revert HandleOpsProbe(settled);
    }

    function _completes(uint128 limit, bool credit) internal returns (bool settled) {
        (bool ok, bytes memory ret) = address(this).call(abi.encodeCall(this.probeHandleOps, (limit, credit)));
        assertFalse(ok, "sample rolls back");
        assertEq(bytes4(ret), HandleOpsProbe.selector, "sample classified");
        assembly ("memory-safe") { settled := mload(add(ret, 36)) }
    }

    function _realFloor(bool credit) internal {
        vm.prank(owner);
        sp.queueGasParams(500_000, 450_000, 5_000, 450_000);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        vm.prank(owner);
        sp.executeGasParams();
        sp.updatePrice();
        (SuperPaymaster.GasParams memory g,) = sp.gasParams();
        bool atFloor = _completes(g.minPostOpGas, credit);
        uint128 lo = g.minPostOpGas - 1;
        uint128 hi = 800_000;
        assertFalse(_completes(lo, credit), "below admission floor fails");
        assertTrue(_completes(hi, credit), "upper bracket settles");
        while (hi - lo > 1) {
            uint128 mid = (hi + lo) / 2;
            if (_completes(mid, credit)) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("active minPost", g.minPostOpGas);
        emit log_named_uint("completes at active floor", atFloor ? 1 : 0);
        emit log_named_uint("minimum real handleOps limit", hi);
        emit log_named_int("margin", int256(uint256(g.minPostOpGas)) - int256(uint256(hi)));
        assertTrue(_completes(hi, credit), "bisected minimum settles");
        assertFalse(_completes(hi - 1, credit), "adjacent lower limit fails");
        assertTrue(atFloor, "active minPost must settle real handleOps");
    }

    // Discover the actual governance minimum so reverting the production rule also
    // exercises handleOps at the unsafe old minimum in the mutation control.
    function probeQueue(uint32 minimum, uint32 settle) external {
        vm.prank(owner);
        sp.queueGasParams(minimum, settle, 5_000, 450_000);
        revert HandleOpsProbe(true);
    }

    function _queueAccepts(uint32 minimum, uint32 settle) internal returns (bool) {
        (, bytes memory ret) = address(this).call(abi.encodeCall(this.probeQueue, (minimum, settle)));
        return bytes4(ret) == HandleOpsProbe.selector;
    }

    function _scaledFloor(uint32 settle, bool credit) internal {
        uint32 spacing = settle + settle / 63 + 20_000;
        uint32 expected = spacing > 500_000 ? spacing : 500_000;
        uint32 low;
        uint32 minimum = 2_000_000;
        while (minimum - low > 1) {
            uint32 mid = (minimum + low) / 2;
            if (_queueAccepts(mid, settle)) minimum = mid;
            else low = mid;
        }
        vm.prank(owner);
        sp.queueGasParams(minimum, settle, 5_000, 450_000);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        vm.prank(owner);
        sp.executeGasParams();
        sp.updatePrice();
        assertTrue(_completes(minimum, credit), "exact governance minimum must settle real handleOps");
        assertEq(minimum, expected, "governance minimum matches scaled rule");
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
        sp.queueGasParams(spacing - 1, settle, 5_000, 450_000);

        // Remove only admission's lower limit for measurement, retaining SETTLE,
        // C_WRAP and C_POSTOP. This is not the exact-minimum acceptance control above.
        bytes32 slot = bytes32(uint256(38));
        bytes32 original = vm.load(address(sp), slot);
        vm.store(address(sp), slot, bytes32(uint256(original) & ~uint256(type(uint32).max) | 1));
        uint128 lo = settle;
        uint128 hi = 2_000_000;
        assertFalse(_completes(lo, credit), "guard crossing lower bracket fails");
        assertTrue(_completes(hi, credit), "guard crossing upper bracket settles");
        while (hi - lo > 1) {
            uint128 mid = (hi + lo) / 2;
            if (_completes(mid, credit)) hi = mid;
            else lo = mid;
        }
        assertTrue(_completes(hi, credit), "guard crossing settles");
        assertFalse(_completes(hi - 1, credit), "below guard crossing fails");
        vm.store(address(sp), slot, original);
        emit log_named_uint("SETTLE", settle);
        emit log_named_uint("CREDIT", credit ? 1 : 0);
        emit log_named_uint("scaled minimum minPost", minimum);
        emit log_named_uint("real guard crossing", hi);
        emit log_named_int("scaled margin", int256(uint256(minimum)) - int256(uint256(hi)));
        assertGe(minimum, hi, "scaled rule covers real guard crossing");
    }

    function test_handleOps_scaled_450k_balance() public { _scaledFloor(450_000, false); }
    function test_handleOps_scaled_450k_credit() public { _scaledFloor(450_000, true); }
    function test_handleOps_scaled_600k_balance() public { _scaledFloor(600_000, false); }
    function test_handleOps_scaled_600k_credit() public { _scaledFloor(600_000, true); }
    function test_handleOps_scaled_1M_balance() public { _scaledFloor(1_000_000, false); }
    function test_handleOps_scaled_1M_credit() public { _scaledFloor(1_000_000, true); }

    // Entire samples roll back, including transient storage and all three settlements.
    function probeVariance(uint128 limit, uint8 position, uint8 variant) external {
        uint256 count = variant == 0 ? 3 : 1;
        PackedUserOperation[] memory ops = new PackedUserOperation[](count);
        bytes32[] memory hashes = new bytes32[](count);
        uint256[] memory balances = new uint256[](count);
        for (uint256 i; i < count; i++) {
            uint256 identity = variant == 0 ? (i + 3 - position) % 3 : i;
            bool credit = variant == 0 && identity == 1;
            address u;
            if (variant == 2) {
                MockAirAccount account = new MockAirAccount(EP);
                account.initialize(vm.addr(OWNER_PK), address(token), address(sp));
                u = address(account);
                vm.prank(address(registry));
                sp.updateSBTStatus(u, true);
                vm.prank(operator);
                IPBTok(address(token)).mint(u, 10_000 ether);
            } else u = _freshUser(900 + identity, credit);
            PackedUserOperation memory op;
            op.sender = u;
            // Both account fixtures execute a real call. The EOA target accepts the 8 KB payload.
            op.callData = abi.encodeWithSignature("execute(address,uint256,bytes)",
                address(0x1234), 0, new bytes(variant == 1 ? 8192 : 0));
            op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(CALL_GAS)));
            op.preVerificationGas = 100_000;
            op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
            (SuperPaymaster.GasParams memory g,) = sp.gasParams();
            uint128 floor = uint128(g.settleGasBound + g.settleGasBound / 63 + 20_000);
            if (floor < 500_000) floor = 500_000;
            op.paymasterAndData = abi.encodePacked(address(sp), uint128(GasFixture.PM_VERIFICATION),
                i == position ? limit : floor,
                operator, type(uint256).max, address(token), uint8(0));
            hashes[i] = entryPoint.getUserOpHash(op);
            (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(OWNER_PK, MessageHashUtils.toEthSignedMessageHash(hashes[i]));
            op.signature = abi.encodePacked(r, sigS, v);
            ops[i] = op;
            balances[i] = token.balanceOf(u);
        }
        vm.recordLogs();
        try entryPoint.handleOps(ops, payable(beneficiary)) {} catch { revert HandleOpsProbe(false); }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 successes;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != EP || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)")) revert HandleOpsProbe(false);
            if (logs[i].topics[0] == keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")) {
                (, bool success,,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                if (success) successes++;
            }
        }
        bool settled = successes == count;
        for (uint256 i; i < count; i++) {
            address u = ops[i].sender;
            settled = settled && token.usedOpHashes(hashes[i]) && token.lockedOf(u) == 0
                && token.creditReservedOf(u) == 0
                && (variant == 0 && (i + 3 - position) % 3 == 1 ? token.debts(u) > 0 : token.balanceOf(u) < balances[i]);
        }
        revert HandleOpsProbe(settled);
    }

    function _varianceCompletes(uint128 limit, uint8 position, uint8 variant) internal returns (bool settled) {
        (bool ok, bytes memory ret) = address(this).call(abi.encodeCall(this.probeVariance, (limit, position, variant)));
        assertFalse(ok, "variance sample rolls back");
        assertEq(bytes4(ret), HandleOpsProbe.selector, "variance sample classified");
        assembly ("memory-safe") { settled := mload(add(ret, 36)) }
    }

    function _variance(uint32 settle, uint8 position, uint8 variant) internal {
        uint32 minimum = settle == 450_000 ? 500_000 : settle + settle / 63 + 20_000;
        vm.prank(owner);
        sp.queueGasParams(minimum, settle, 5_000, 450_000);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        vm.prank(owner);
        sp.executeGasParams();
        sp.updatePrice();
        assertTrue(_varianceCompletes(minimum, position, variant), "all ops settle at exact MIN");
        bytes32 slot = bytes32(uint256(38));
        bytes32 original = vm.load(address(sp), slot);
        vm.store(address(sp), slot, bytes32(uint256(original) & ~uint256(type(uint32).max) | 1));
        uint128 lo = settle;
        uint128 hi = minimum;
        assertFalse(_varianceCompletes(lo, position, variant), "lower variance bracket fails");
        while (hi - lo > 1) {
            uint128 mid = (hi + lo) / 2;
            if (_varianceCompletes(mid, position, variant)) hi = mid;
            else lo = mid;
        }
        assertTrue(_varianceCompletes(hi, position, variant), "variance crossing settles all ops");
        assertFalse(_varianceCompletes(hi - 1, position, variant), "adjacent variance crossing fails");
        vm.store(address(sp), slot, original);
        emit log_named_uint("variance SETTLE", settle);
        emit log_named_uint("variance variant", variant);
        emit log_named_uint("variance position", position);
        emit log_named_uint("variance minimum", minimum);
        emit log_named_uint("variance crossing", hi);
    }

    function test_variance_450000_bundle_0() public { _variance(450000, 0, 0); }
    function test_variance_450000_bundle_1() public { _variance(450000, 1, 0); }
    function test_variance_450000_bundle_2() public { _variance(450000, 2, 0); }
    function test_variance_450000_large_0() public { _variance(450000, 0, 1); }
    function test_variance_450000_account_0() public { _variance(450000, 0, 2); }
    function test_variance_600000_bundle_0() public { _variance(600000, 0, 0); }
    function test_variance_600000_bundle_1() public { _variance(600000, 1, 0); }
    function test_variance_600000_bundle_2() public { _variance(600000, 2, 0); }
    function test_variance_600000_large_0() public { _variance(600000, 0, 1); }
    function test_variance_600000_account_0() public { _variance(600000, 0, 2); }

    function test_old_floor_rejected_at_queue() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
        sp.queueGasParams(375_000, 355_000, 5_000, 370_000);
    }

    function test_handleOps_floor_balance() public { _realFloor(false); }
    function test_handleOps_floor_credit() public { _realFloor(true); }
    function test_handleOps_release_balance() public { _realFloor(false); }
    function test_handleOps_release_credit() public { _realFloor(true); }
}
