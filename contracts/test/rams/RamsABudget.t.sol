// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import {xPNTsToken} from "src/tokens/xPNTsToken.sol";
import "./RamsAHelpers.sol";

/// @notice Offline regression coverage for the budget calculations used by the fork fixture.
contract RamsABudgetTest is Test {
    address constant PAYMASTER = address(0x1234);
    address constant OPERATOR = address(0x5678);

    function _depositWithRate(uint256 rate) internal {
        xPNTsToken token = xPNTsToken(Clones.clone(address(new xPNTsToken())));
        token.initialize("RAMS", "RAMS", address(this), "RAMS", "", rate);
        token.setSuperPaymasterAddress(PAYMASTER);
        uint256 amount = 100_000 ether + 1; // Exercises the last partial chunk too.
        deal(address(token), OPERATOR, amount, true);
        // The registered SP-to-SP path is exempt from the non-SP daily cap.
        token.setSpenderDailyCap(1);
        vm.startPrank(PAYMASTER);
        vm.expectRevert(xPNTsToken.SingleTxLimitExceeded.selector);
        token.transferFrom(OPERATOR, PAYMASTER, amount);
        uint256 chunk = RamsBudget.depositChunk(token.maxSingleTxLimit(), token.exchangeRate());
        uint256 remaining = amount;
        while (remaining != 0) {
            uint256 next = Math.min(chunk, remaining);
            assertTrue(token.transferFrom(OPERATOR, PAYMASTER, next));
            remaining -= next;
        }
        vm.stopPrank();
        assertEq(token.balanceOf(PAYMASTER), amount);
        assertEq(token.balanceOf(OPERATOR), 0);
    }

    function test_DepositChunks_realV1Token_unitRate() public {
        _depositWithRate(1 ether);
    }

    function test_DepositChunks_realV1Token_fractionalRate() public {
        _depositWithRate(0.7 ether + 3);
    }

    function test_DepositChunks_realV1Token_highRate() public {
        _depositWithRate(3 ether);
    }

    function quoteChunk(uint256 limit, uint256 rate) external pure returns (uint256) {
        return RamsBudget.depositChunk(limit, rate);
    }

    function test_DepositImpossible_failsExplicitly() public {
        assertEq(this.quoteChunk(1, 0.7 ether), 1, "token's floor admits a one-wei transfer");
        vm.expectRevert(bytes("RAMS: zero deposit limit/rate"));
        this.quoteChunk(0, 1 ether);
        vm.expectRevert(bytes("RAMS: zero deposit limit/rate"));
        this.quoteChunk(1 ether, 0);
        vm.expectRevert(bytes("RAMS: deposit limit cannot fund one token wei"));
        this.quoteChunk(1, 0.5 ether);
    }

    function test_AmsterdamPrefundAndReservation() public pure {
        PackedUserOperation memory op;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(600_000), uint128(300_000)));
        op.preVerificationGas = 60_000;
        // maxFee, not priority fee, determines prefund.
        op.gasFees = bytes32(abi.encodePacked(uint128(0.1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(PAYMASTER, uint128(1_150_000), uint128(440_000));
        assertEq(RamsBudget.requiredGas(op), 2_550_000);
        assertEq(RamsBudget.maxCost(op), 0.00255 ether);
        assertEq(RamsBudget.reservation(RamsBudget.maxCost(op), 2000e8, 8, 0.02 ether, 1000), 306 ether);
        op.paymasterAndData = ""; // Unsponsored admin operation has no paymaster prefund.
        assertEq(RamsBudget.maxCost(op), 0.00096 ether);
    }

    function test_Reservation_roundsUpAtBothStages() public pure {
        // Raw price conversion is 1/3 token wei; first ceil = 1, fee+buffer ceil = 2.
        assertEq(RamsBudget.reservation(1, 1, 0, 3 ether, 1000), 2);
    }
}
