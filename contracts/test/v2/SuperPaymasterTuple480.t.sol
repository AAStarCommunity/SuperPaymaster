// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "./SuperPaymasterPostOpGasProfile.t.sol";

/// @dev Each runner sample starts a new process/deployment. setUp is the prior transaction.
contract Tuple480AdmissionTest is PostOpProfileFixture {
    using SuperPaymasterAdminCalls for SuperPaymaster;
    function creditMode() internal pure override returns (bool) { return false; }
    function setUp() public override {
        super.setUp();
        uint32 settle = uint32(vm.envOr("T480_SETTLE", uint256(450000)));
        vm.startPrank(owner);
        // Keep the historical probe, but only activate governance-valid release parameters.
        uint32 minPost = settle + 30000 < 500000 ? 500000 : settle + 30000;
        sp.queueGasParams(minPost, settle, 5000, 450000);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        sp.executeGasParams();
        vm.stopPrank();
        sp.updatePrice();
        if (vm.envOr("T480_CREDIT", false)) {
            uint256 balance = token.balanceOf(user);
            vm.prank(user);
            token.transfer(stranger, balance);
            registry.setCreditLimit(user, 50000 ether);
            vm.prank(operator);
            IV2Ext(address(token)).queueCreditPolicy(2);
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            IV2Ext(address(token)).executeCreditPolicy();
            sp.updatePrice();
            vm.prank(user);
            IV2Ext(address(token)).requestCredit(50000 ether);
        }
        if (vm.envOr("T480_NONFRESH", false)) {
            (bool ok,) = settleOne(keccak256("prior transaction"), 1000000, false);
            assertTrue(ok, "prior operation settled");
            vm.warp(vm.getBlockTimestamp() + 61);
        }
    }
    function settleOne(bytes32 hash, uint256 budget, bool legacy) internal returns (bool ok, bytes memory ret) {
        (SuperPaymasterStorage.GasParams memory g,) = sp.gasParams();
        PackedUserOperation memory op;
        op.sender = user;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400000), uint128(300000)));
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(GasFixture.PM_VERIFICATION), uint128(g.minPostOpGas), operator, type(uint256).max, address(token), uint8(0));
        vm.prank(EP);
        (bytes memory context, uint256 vd) = sp.validatePaymasterUserOp(op, hash, 1e16);
        assertEq(vd & 1, 0);
        assertEq(context.length, 384);
        assertEq(abi.decode(context, (SuperPaymaster.OpCtx)).mode, vm.envOr("T480_CREDIT", false) ? 2 : 1);
        if (legacy) { assembly ("memory-safe") { mstore(context, 352) } }
        vm.prank(EP);
        (ok, ret) = address(sp).call{gas: budget}(abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, context, 1e14, 1 gwei)));
    }
    function test_old_tuple480_rejected() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
        sp.queueGasParams(480000, 450000, 5000, 450000);
    }
    function test_tuple480_sample() public {
        uint256 budget = vm.envOr("T480_BUDGET", uint256(600000));
        (bool ok, bytes memory ret) = settleOne(keccak256("new operation"), budget, vm.envOr("T480_LEGACY", false));
        bool guard = keccak256(ret) == keccak256(abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector));
        if (guard) assertEq(ret, abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector));
        emit log_named_uint("admission accepted", guard ? 0 : 1);
        emit log_named_uint("settlement completed", ok ? 1 : 0);
        emit log_named_uint("sample gas", budget);
    }
}
