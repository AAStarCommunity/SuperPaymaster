// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {SuperPaymasterV55PostOpBoundTest} from "../v2/SuperPaymasterV55PostOpBound.t.sol";
import {SuperPaymasterStorage} from "src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol";
import {SuperPaymaster} from "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import {PackedUserOperation} from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {SelectedGasFixtures as GasFixture} from "../helpers/SelectedGasFixtures.sol";
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
