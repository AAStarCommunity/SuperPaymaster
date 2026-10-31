// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./SuperPaymasterPostOpGasProfile.t.sol";

/// @dev Fresh deployment per process. No snapshots, instrumentation, or altered production code.
contract PostOpMultiOpTest is PostOpProfileFixture {
    using SuperPaymasterAdminCalls for SuperPaymaster;
    address[] actors;
    uint256 count;
    uint256 pattern;
    bool distinct;

    function creditMode() internal pure override returns (bool) {
        return true;
    }

    function isCredit(uint256 i) internal view returns (bool) {
        return pattern == 1 || (pattern == 2 && i % 2 == 1) || (pattern == 3 && i % 2 == 0);
    }

    function setUp() public override {
        count = vm.envOr("MULTI_N", uint256(2));
        pattern = vm.envOr("MULTI_PATTERN", uint256(0));
        distinct = vm.envOr("MULTI_DISTINCT", false);
        require((count == 2 || count == 3 || count == 5) && pattern < 4);
        fresh(true, false);
        target = new V55FuzzTarget();
        SimpleAccountFactory factory = new SimpleAccountFactory(ep);
        for (uint256 i; i < (distinct ? count : 1); i++) {
            address a = address(factory.createAccount(vm.addr(0xC001 + i), 0));
            actors.push(a);
            vm.prank(address(registry));
            sp.updateSBTStatus(a, true);
            registry.setCreditLimit(a, 50_000 ether);
            vm.prank(a);
            IV2Ext(address(token)).requestCredit(50_000 ether);
            uint256 funding = pattern == 0 ? 10_000 ether : pattern == 1 ? 0 : 1000 ether;
            if (funding != 0) {
                vm.prank(operator);
                IV2Ext(address(token)).mint(a, funding);
            }
        }
        vm.deal(address(this), 10 ether);
        ep.depositTo{value: 10 ether}(address(sp));
        assertEq(sp.protocolRevenue(), 0);
        assertEq(EP.codehash, 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58);
    }

    function test_bundle() public {
        uint256 budget = vm.envOr("PROFILE_BUDGET", uint256(440000));
        PackedUserOperation[] memory ops = new PackedUserOperation[](count);
        bytes32[] memory hashes = new bytes32[](count);
        for (uint256 i; i < count; i++) {
            uint256 u = distinct ? i : 0;
            PackedUserOperation memory op;
            op.sender = actors[u];
            op.nonce = distinct ? 0 : i;
            op.callData =
                abi.encodeCall(SimpleAccount.execute, (address(target), 0, abi.encodeCall(V55FuzzTarget.hit, (HASH))));
            op.accountGasLimits = bytes32(abi.encodePacked(uint128(400000), uint128(300000)));
            op.preVerificationGas = 50000;
            uint128 fee = pattern >= 2 && isCredit(i) ? 10 gwei : 1 gwei;
            op.gasFees = bytes32(abi.encodePacked(fee, fee));
            op.paymasterAndData = abi.encodePacked(
                address(sp),
                uint128(GasFixture.PM_VERIFICATION),
                uint128(budget),
                operator,
                type(uint256).max,
                address(token),
                uint8(0)
            );
            hashes[i] = ep.getUserOpHash(op);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xC001 + u, MessageHashUtils.toEthSignedMessageHash(hashes[i]));
            op.signature = abi.encodePacked(r, s, v);
            ops[i] = op;
        }
        vm.recordLogs();
        try ep.handleOps(ops, payable(stranger)) {}
        catch (bytes memory reason) {
            assertLt(budget, 440000, "unexpected validation rejection");
            assertEq(reason, abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA34 signature error"));
            emit log_named_uint("admission rejected", budget);
            return;
        }
        assertGe(budget, 440000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 completed;
        uint256 settled;
        for (uint256 j; j < logs.length; j++) {
            Vm.Log memory e = logs[j];
            if (e.emitter == EP && e.topics[0] == keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)")) {
                assertTrue(false, "postOp reverted");
            }
            if (
                e.emitter == EP
                    && e.topics[0]
                        == keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")
            ) {
                (, bool success,,) = abi.decode(e.data, (uint256, bool, uint256, uint256));
                assertTrue(success);
                assertEq(e.topics[1], hashes[completed]);
                completed++;
            }
            if (
                e.emitter == address(token)
                    && (e.topics[0] == keccak256("CreditSettled(address,bytes32,uint256)")
                        || e.topics[0] == keccak256("LockSettled(address,bytes32,uint256,uint256)"))
            ) {
                assertEq(
                    e.topics[0],
                    isCredit(settled)
                        ? keccak256("CreditSettled(address,bytes32,uint256)")
                        : keccak256("LockSettled(address,bytes32,uint256,uint256)"),
                    "per-op mode"
                );
                assertEq(e.topics[2], hashes[settled], "settlement order");
                settled++;
            }
        }
        assertEq(completed, count);
        assertEq(settled, count);
        assertEq(target.hits(HASH), count);
        for (uint256 i; i < count; i++) {
            assertTrue(token.usedOpHashes(hashes[i]));
        }
        for (uint256 i; i < actors.length; i++) {
            assertEq(token.lockedOf(actors[i]), 0);
            assertEq(token.creditReservedOf(actors[i]), 0);
        }
        emit log_named_uint("completed operations", completed);
    }
}
