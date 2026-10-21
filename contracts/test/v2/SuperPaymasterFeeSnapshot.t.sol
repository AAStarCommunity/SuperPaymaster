// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccount.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { V55Registry, V55PriceFeed, V55APNTs, IV2Ext } from "../helpers/V55TestFixtures.sol";
import { V55FuzzTarget } from "../helpers/V55FuzzFixtures.sol";

using SuperPaymasterAdminCalls for SuperPaymaster;

/**
 * @title SuperPaymasterFeeSnapshotTest — protocolFeeBPS is snapshotted into context word 12
 * @notice validatePaymasterUserOp quotes a0 at protocolFeeBPS; postOp must charge at THAT fee, not at
 *         whatever setProtocolFee left in storage by the time the op settles. The fee travels as
 *         (fee + 1) << 128 in word 12 of the 384-byte context (bits 0-127 stay the GasParams snapshot).
 *         Legacy contexts (352 B, or 384 B with zero fee bits, i.e. emitted before this change) keep the
 *         live-fee rule. Mid-bundle cases use the canonical EntryPoint v0.7: it validates every op first
 *         and executes afterwards, so an op that changes the fee (or the implementation) runs between the
 *         victims' validation and their postOp. The previous release is the c30854f9 C2 fixture.
 */
contract SuperPaymasterFeeSnapshotTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");
    string constant PREV_FIXTURE = "contracts/test/fixtures/superpaymaster-5.5.0-c30854f9-impl.creation.hex";
    uint256 constant BPS = 10_000;
    uint256 constant MAX_FEE = 2000; // SuperPaymasterStorage.MAX_PROTOCOL_FEE

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    address oldImpl;
    address newImpl;
    xPNTsTokenV2 token;
    V55Registry registry;
    V55FuzzTarget target;
    address deployer = address(0x0A11);
    address operator = address(0x0BE);
    address beneficiary = address(0xBEEF);
    uint256[3] pk = [uint256(0xC001), 0xC002, 0xC003]; // owner account, victim 1, victim 2
    address[3] acct;

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountFactory = new SimpleAccountFactory(entryPoint);
        target = new V55FuzzTarget();
        for (uint256 i; i < 3; i++) acct[i] = address(accountFactory.createAccount(vm.addr(pk[i]), 0));
    }

    /// @dev SP behind a proxy on `startOnNew ? current : c30854f9`; owned by the 4337 account acct[0]
    ///      so fee / upgrade calls can run INSIDE a bundle.
    function _boot(bool startOnNew) internal {
        vm.deal(deployer, 10 ether);
        vm.startPrank(deployer);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        address feed = address(new V55PriceFeed());
        bytes memory init = abi.encodePacked(vm.parseBytes(vm.readFile(PREV_FIXTURE)), abi.encode(EP, address(registry), feed));
        address impl;
        assembly { impl := create(0, add(init, 32), mload(init)) }
        require(impl != address(0), "previous-release impl deploy");
        oldImpl = impl;
        newImpl = address(new SuperPaymaster(entryPoint, IRegistry(address(registry)), feed));
        assertEq(oldImpl.code.length, 23_568, "precondition: the c30854f9 runtime (23,568 B)");
        sp = SuperPaymaster(payable(address(new ERC1967Proxy(
            startOnNew ? newImpl : oldImpl, abi.encodeCall(SuperPaymaster.initialize, (deployer, address(apnts), deployer, 3600))
        ))));

        AOAProtocolRegistry aoa = new AOAProtocolRegistry(deployer);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(address(sp), address(registry), address(new xPNTsTokenV2(address(aoa), address(ext))), address(tier));
        sp.setXPNTsFactory(address(factory));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 5 ether}();
        apnts.mint(operator, 1_000_000 ether);
        sp.transferOwnership(acct[0]);
        vm.stopPrank();
        if (sp.owner() != acct[0]) {
            vm.prank(acct[0]);
            sp.acceptOwnership();
        }
        assertEq(sp.owner(), acct[0], "owner account owns SP");

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), deployer);
        sp.deposit(100_000 ether);
        vm.stopPrank();
        for (uint256 i = 1; i < 3; i++) {
            vm.prank(address(registry));
            sp.updateSBTStatus(acct[i], true);
            vm.prank(operator);
            IV2Ext(address(token)).mint(acct[i], 10_000 ether);
        }
        vm.deal(address(this), 1 ether);
        entryPoint.depositTo{value: 1 ether}(acct[0]);
    }

    function _op(uint256 i, bytes memory callData, bool sponsored) internal view returns (PackedUserOperation memory op) {
        op.sender = acct[i];
        op.nonce = 1 << 64;
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(300_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        if (sponsored) {
            op.paymasterAndData = abi.encodePacked(
                address(sp), uint128(700_000), uint128(200_000), operator, type(uint256).max, address(token), uint8(0)
            );
        }
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk[i], MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _victimOp(uint256 i, string memory tag) internal view returns (PackedUserOperation memory) {
        return _op(i, abi.encodeCall(SimpleAccount.execute, (address(target), 0, abi.encodeCall(V55FuzzTarget.hit, (keccak256(bytes(tag)))))), true);
    }

    /// @dev the owner account's op: execute `calls` on SP in order (unsponsored, pays its own gas)
    function _ownerOp(bytes[] memory calls) internal view returns (PackedUserOperation memory) {
        address[] memory dest = new address[](calls.length);
        uint256[] memory value = new uint256[](calls.length);
        for (uint256 i; i < calls.length; i++) dest[i] = address(sp);
        return _op(0, abi.encodeCall(SimpleAccount.executeBatch, (dest, value, calls)), false);
    }

    struct Res {
        uint256 nPostRevert;
        uint256 nFailedOps;
        uint256[3] aGas;
        uint256[3] charge;
        uint256 nTS;
    }

    function _run(PackedUserOperation[] memory ops) internal returns (Res memory r) {
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (logs[i].emitter == EP && t0 == T_POSTOP_REVERT) r.nPostRevert++;
            if (logs[i].emitter == EP && t0 == T_USEROP) {
                (, bool success, , ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                if (!success) r.nFailedOps++;
            } else if (logs[i].emitter == address(sp) && t0 == T_TX_SPONSORED) {
                address u = address(uint160(uint256(logs[i].topics[2])));
                for (uint256 k; k < 3; k++) if (u == acct[k]) (r.aGas[k], r.charge[k]) = abi.decode(logs[i].data, (uint256, uint256));
                r.nTS++;
            }
        }
    }

    function _chargeAt(uint256 aGas, uint256 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(aGas, BPS + feeBps, BPS, Math.Rounding.Ceil);
    }

    /// @dev Both victims were sponsored, settled cleanly, and charged at exactly `feeBps` (and NOT at
    ///      `otherFeeBps`, so the assertion can tell the two fees apart for these aGas values).
    function _assertChargedAt(Res memory r, uint256 feeBps, uint256 otherFeeBps, string memory tag) internal pure {
        assertEq(r.nPostRevert, 0, string.concat(tag, ": no victim postOp fails"));
        assertEq(r.nFailedOps, 0, string.concat(tag, ": every op of the bundle succeeded"));
        assertEq(r.nTS, 2, string.concat(tag, ": both victims sponsored"));
        for (uint256 k = 1; k < 3; k++) {
            assertGt(r.aGas[k], 0, "positive control: aGas > 0");
            assertTrue(_chargeAt(r.aGas[k], feeBps) != _chargeAt(r.aGas[k], otherFeeBps), "precondition: the two fees give different charges");
            assertEq(r.charge[k], _chargeAt(r.aGas[k], feeBps), string.concat(tag, ": charged at the expected fee"));
        }
    }

    function _implIs(address impl) internal view returns (bool) {
        return address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))) == impl;
    }

    // ============================================================ mid-bundle fee change (current impl)

    function test_feeSnapshot_feeRaisedMidBundle_chargesValidationFee() public {
        _boot(true);
        assertEq(sp.protocolFeeBPS(), 1000, "precondition: validation-time fee 10%");
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (MAX_FEE));
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _ownerOp(calls);
        ops[1] = _victimOp(1, "v1");
        ops[2] = _victimOp(2, "v2");
        Res memory r = _run(ops);
        assertEq(sp.protocolFeeBPS(), MAX_FEE, "precondition: fee raised mid-bundle");
        _assertChargedAt(r, 1000, MAX_FEE, "raise");
    }

    function test_feeSnapshot_feeLoweredMidBundle_chargesValidationFee() public {
        _boot(true);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (0));
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _ownerOp(calls);
        ops[1] = _victimOp(1, "v1");
        ops[2] = _victimOp(2, "v2");
        Res memory r = _run(ops);
        assertEq(sp.protocolFeeBPS(), 0, "precondition: fee lowered mid-bundle");
        _assertChargedAt(r, 1000, 0, "lower");
    }

    // ============================================================ forward: c30854f9 contexts (fee bits 0)

    /// @dev Victims admitted by c30854f9 carry a 384-B context with bits 128-255 = 0. After a mid-bundle
    ///      upgrade to the current impl AND a fee change, they settle under the legacy rule: live fee.
    function test_feeSnapshot_forward_prevReleaseContext_usesLiveFee() public {
        _boot(false);
        assertTrue(_implIs(oldImpl), "precondition: starting on c30854f9");
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
        calls[1] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (MAX_FEE)); // extension of the NEW core
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _ownerOp(calls);
        ops[1] = _victimOp(1, "v1");
        ops[2] = _victimOp(2, "v2");
        Res memory r = _run(ops);
        assertTrue(_implIs(newImpl), "precondition: upgraded mid-bundle");
        assertEq(sp.protocolFeeBPS(), MAX_FEE, "precondition: fee changed mid-bundle");
        _assertChargedAt(r, MAX_FEE, 1000, "forward/legacy");
    }

    // ============================================================ rollback: current → c30854f9

    /// @dev Victims admitted by the current impl (fee bits set) are settled by c30854f9 after a
    ///      mid-bundle rollback: the previous release reads only uint32 slices below bit 128, so it
    ///      settles them exactly as it always did (live fee), with no revert and exact conservation.
    function test_feeSnapshot_rollback_prevReleaseSettlesNewContext() public {
        _boot(true);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (MAX_FEE)); // extension, before …
        calls[1] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", oldImpl, bytes("")); // … rollback
        (uint128 opBal0, , , , , , , , ) = sp.operators(operator);
        uint256 rev0 = sp.protocolRevenue();
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _ownerOp(calls);
        ops[1] = _victimOp(1, "v1");
        ops[2] = _victimOp(2, "v2");
        Res memory r = _run(ops);
        assertTrue(_implIs(oldImpl), "precondition: rolled back mid-bundle");
        _assertChargedAt(r, MAX_FEE, 1000, "rollback");
        uint256 sumC = r.charge[1] + r.charge[2];
        (uint128 opBal1, , , , , , , , ) = sp.operators(operator);
        assertEq(uint256(opBal0) - opBal1, sumC, "rollback conservation: operator paid exactly the charges");
        assertEq(sp.protocolRevenue() - rev0, sumC, "rollback conservation: revenue == sum(charge)");
    }

    // ============================================================ direct context shapes + boundaries

    /// @dev Validation through the EntryPoint address; returns the real 384-B context (a live lock).
    function _validate(uint256 i, string memory tag, bytes32 opHash) internal returns (bytes memory ctx) {
        PackedUserOperation memory op = _victimOp(i, tag);
        vm.prank(EP);
        (ctx, ) = sp.validatePaymasterUserOp(op, opHash, 1e16);
        assertEq(ctx.length, 384, "validation emits a 384-byte context");
    }

    function _postOp(bytes memory ctx) internal returns (uint256 aGas, uint256 charge) {
        vm.recordLogs();
        vm.prank(EP);
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 j; j < logs.length; j++) {
            if (logs[j].emitter == address(sp) && logs[j].topics[0] == T_TX_SPONSORED) {
                (aGas, charge) = abi.decode(logs[j].data, (uint256, uint256));
                n++;
            }
        }
        assertEq(n, 1, "exactly one TransactionSponsored");
        assertGt(aGas, 0, "positive control: aGas > 0");
    }

    function _word12(bytes memory ctx) internal pure returns (uint256 w) {
        assembly { w := mload(add(ctx, 384)) } // data starts at +32; word 12 at byte 352 → +384
    }

    function _setFee(uint256 f) internal {
        vm.prank(acct[0]);
        sp.setProtocolFee(f);
        assertEq(sp.protocolFeeBPS(), f, "fee set");
    }

    function test_feeSnapshot_boundary_feeZero_roundTrips() public {
        _boot(true);
        _setFee(0);
        bytes memory ctx = _validate(1, "z", keccak256("z"));
        assertEq(_word12(ctx) >> 128, 1, "fee 0 encodes as 1 (0 is reserved for no-snapshot)");
        (SuperPaymasterStorage.GasParams memory gp, ) = sp.gasParams();
        uint256 cPostop = gp.cPostop == 0 ? 175_000 : gp.cPostop; // unset slot → _gpRaw default C_POSTOP
        assertEq(uint32(_word12(ctx) >> 96), cPostop, "gas snapshot bits untouched by the fee bits");
        _setFee(1000); // live fee differs from the snapshot
        (uint256 aGas, uint256 charge) = _postOp(ctx);
        assertTrue(_chargeAt(aGas, 0) != _chargeAt(aGas, 1000), "precondition: fees distinguishable");
        assertEq(charge, _chargeAt(aGas, 0), "fee 0 snapshot: charged at 0, not the live 1000");
    }

    function test_feeSnapshot_boundary_feeMax_roundTrips() public {
        _boot(true);
        _setFee(MAX_FEE);
        bytes memory ctx = _validate(1, "m", keccak256("m"));
        assertEq(_word12(ctx) >> 128, MAX_FEE + 1, "fee MAX encodes as MAX + 1");
        _setFee(0);
        (uint256 aGas, uint256 charge) = _postOp(ctx);
        assertEq(charge, _chargeAt(aGas, MAX_FEE), "fee MAX snapshot: charged at MAX, not the live 0");
    }

    /// @dev A 384-B context with bits 128-255 cleared (what c30854f9 emits) → live fee.
    function test_feeSnapshot_legacy384_zeroFeeBits_usesLiveFee() public {
        _boot(true);
        bytes memory ctx = _validate(1, "l384", keccak256("l384"));
        uint256 w = _word12(ctx);
        uint256 cleared = w & type(uint128).max;
        assembly { mstore(add(ctx, 384), cleared) }
        assertEq(_word12(ctx) >> 128, 0, "precondition: fee bits cleared");
        _setFee(MAX_FEE);
        (uint256 aGas, uint256 charge) = _postOp(ctx);
        assertEq(charge, _chargeAt(aGas, MAX_FEE), "no fee snapshot: charged at the live fee");
    }

    /// @dev A 352-B context (the original 5.5.0 shape, no word 12) → live fee.
    function test_feeSnapshot_legacy352_usesLiveFee() public {
        _boot(true);
        bytes memory ctx = _validate(1, "l352", keccak256("l352"));
        assembly { mstore(ctx, 352) } // truncate to the 11 OpCtx words
        assertEq(ctx.length, 352, "precondition: 352-byte context");
        _setFee(MAX_FEE);
        (uint256 aGas, uint256 charge) = _postOp(ctx);
        assertEq(charge, _chargeAt(aGas, MAX_FEE), "352-byte context: charged at the live fee");
    }
}
