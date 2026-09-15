// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import { Ownable2StepNamespaced } from "src/utils/Ownable2StepNamespaced.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccount.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
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
 * @title SuperPaymasterD5bUpgradeRaceTest — spec 03 §10.7b C2 for D5b (D5b-design §2 item 6)
 * @notice Mid-bundle UUPS upgrades in BOTH directions between the previous release and D5b, with
 *         the attacker / guardian ops executing EXTENSION functions inside the bundle.
 *           previous release : creation-bytecode fixture `superpaymaster-5.5.0-c30854f9-impl.creation.hex`
 *                              (feat/aoa-balance-mode-5.5.0 @ c30854f9; provenance and source keccaks in
 *                              contracts/test/fixtures/d5b-previous-release.provenance.json)
 *           D5b              : the current core + SuperPaymasterAdmin.
 *         SP's owner is a real OZ TimelockController with an OPEN executor. EntryPoint v0.7 validates
 *         EVERY op of the bundle first and executes afterwards, so the victims are admitted by the
 *         implementation in place BEFORE the bundle and settled by the one in place AFTER the attacker op.
 *
 *           forward : c30854f9 → D5b. Attacker op executes ONE matured timelock batch
 *                     [upgradeToAndCall(D5b), executeGasParams() (an extension function, reached through
 *                     the NEW core's fallback), setGuardian(guardianAccount)]; the guardian account's op
 *                     then pauses sponsorship globally and the victims' operator. Victims must settle, at
 *                     the VALIDATION-time gas snapshot, while paused.
 *           rollback: D5b → c30854f9. Guardian op pauses (extension), attacker op executes a matured batch
 *                     [executeGasParams() (extension), upgradeToAndCall(c30854f9)]. Victims admitted by D5b
 *                     (384-byte contexts) must settle under c30854f9 with exact conservation.
 *         Implementations are told apart by the ERC-1967 slot and codehash (both report
 *         "SuperPaymaster-5.5.0"; release identity = commit + codehash, spec §6).
 */
contract SuperPaymasterD5bUpgradeRaceTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");
    bytes32 constant T_LOCK_SETTLED = keccak256("LockSettled(address,bytes32,uint256,uint256)");
    string constant PREV_FIXTURE = "contracts/test/fixtures/superpaymaster-5.5.0-c30854f9-impl.creation.hex";
    uint256 constant GOV2_SLOT = 40;

    // gas parameters executed MID-BUNDLE (all within the hard bounds, far from the defaults)
    uint32 constant NEW_MIN = 400_000;
    uint32 constant NEW_SETTLE = 300_000;
    uint32 constant NEW_CWRAP = 50_000;
    uint32 constant NEW_CPOSTOP = 400_000;

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    address oldImpl;
    address newImpl;
    TimelockController timelock;
    xPNTsTokenV2 token;
    V55Registry registry;
    V55FuzzTarget target;
    address owner = address(0x0A11);
    address multisig = address(0x5AFE);
    address operator = address(0x0BE);
    address beneficiary = address(0xBEEF);
    uint256[4] pk = [uint256(0xC001), 0xC0DE, 0xC002, 0xC003]; // attacker, guardian account, victim 1, victim 2
    address[4] acct;

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountFactory = new SimpleAccountFactory(entryPoint);
        target = new V55FuzzTarget();
    }

    function _boot(bool startOnNew) internal {
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
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
        assertTrue(oldImpl.codehash != newImpl.codehash, "precondition: previous release and D5b differ");
        assertEq(oldImpl.code.length, 23_568, "precondition: the c30854f9 runtime (23,568 B)");
        sp = SuperPaymaster(payable(address(new ERC1967Proxy(
            startOnNew ? newImpl : oldImpl, abi.encodeCall(SuperPaymaster.initialize, (owner, address(apnts), owner, 3600))
        ))));
        assertEq(address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))), startOnNew ? newImpl : oldImpl, "precondition: starting implementation");

        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
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
        vm.stopPrank();

        for (uint256 i; i < 4; i++) acct[i] = address(accountFactory.createAccount(vm.addr(pk[i]), 0));
        if (startOnNew) {
            vm.prank(owner);
            sp.setGuardian(acct[1]); // D5b: the guardian is a 4337 account (can act inside a bundle)
        }

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // OPEN executor
        timelock = new TimelockController(1 days, proposers, executors, address(0));
        vm.prank(owner);
        sp.transferOwnership(address(timelock));
        if (sp.owner() != address(timelock)) { // D5b: two-step
            vm.prank(address(timelock));
            sp.acceptOwnership();
        }
        assertEq(sp.owner(), address(timelock), "timelock owns SP");

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), owner);
        sp.deposit(100_000 ether);
        vm.stopPrank();
        for (uint256 i = 2; i < 4; i++) {
            vm.prank(address(registry));
            sp.updateSBTStatus(acct[i], true);
            vm.prank(operator);
            IV2Ext(address(token)).mint(acct[i], 10_000 ether);
        }
        vm.deal(address(this), 2 ether);
        entryPoint.depositTo{value: 1 ether}(acct[0]); // attacker pays its own gas
        entryPoint.depositTo{value: 1 ether}(acct[1]); // so does the guardian account
    }

    // ------------------------------------------------------------------ helpers

    function _viaTimelock(bytes memory data) internal {
        vm.prank(multisig);
        timelock.schedule(address(sp), 0, data, bytes32(0), keccak256(data), 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        timelock.execute(address(sp), 0, data, bytes32(0), keccak256(data));
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

    /// @dev the guardian account's op: stop all sponsorship + pause the victims' operator (extension functions)
    function _guardianPauseOp() internal view returns (PackedUserOperation memory) {
        address[] memory dest = new address[](2);
        dest[0] = address(sp);
        dest[1] = address(sp);
        uint256[] memory value = new uint256[](2);
        bytes[] memory func = new bytes[](2);
        func[0] = abi.encodeCall(SuperPaymasterAdmin.setGlobalPaused, (true));
        func[1] = abi.encodeCall(SuperPaymasterAdmin.setOperatorPaused, (operator, true));
        return _op(1, abi.encodeCall(SimpleAccount.executeBatch, (dest, value, func)), false);
    }

    function _batchExecOp(address[] memory t, bytes[] memory p, bytes32 salt) internal view returns (PackedUserOperation memory) {
        uint256[] memory v = new uint256[](t.length);
        bytes memory exec = abi.encodeCall(TimelockController.executeBatch, (t, v, p, bytes32(0), salt));
        return _op(0, abi.encodeCall(SimpleAccount.execute, (address(timelock), 0, exec)), false);
    }

    function _scheduleBatch(address[] memory t, bytes[] memory p, bytes32 salt) internal {
        uint256[] memory v = new uint256[](t.length);
        vm.prank(multisig);
        timelock.scheduleBatch(t, v, p, bytes32(0), salt, 1 days);
    }

    struct Res {
        uint256 nPostRevert;
        uint256 nFailedOps;
        uint256[4] G;
        uint256[4] aGas;
        uint256[4] charge;
        uint256 nTS;
        uint256 xBurned;
    }

    function _run(PackedUserOperation[] memory ops) internal returns (bytes32[] memory h, Res memory r) {
        h = new bytes32[](ops.length);
        for (uint256 i; i < ops.length; i++) h[i] = entryPoint.getUserOpHash(ops[i]);
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (logs[i].emitter == EP && t0 == T_POSTOP_REVERT) r.nPostRevert++;
            if (logs[i].emitter == EP && t0 == T_USEROP) {
                (, bool success, uint256 cost, ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                if (!success) r.nFailedOps++;
                for (uint256 k; k < 4; k++) if (logs[i].topics[2] == bytes32(uint256(uint160(acct[k])))) r.G[k] = cost;
            } else if (logs[i].emitter == address(sp) && t0 == T_TX_SPONSORED) {
                address u = address(uint160(uint256(logs[i].topics[2])));
                for (uint256 k; k < 4; k++) if (u == acct[k]) (r.aGas[k], r.charge[k]) = abi.decode(logs[i].data, (uint256, uint256));
                r.nTS++;
            } else if (logs[i].emitter == address(token) && t0 == T_LOCK_SETTLED) {
                (uint256 xb, ) = abi.decode(logs[i].data, (uint256, uint256));
                r.xBurned += xb;
            }
        }
    }

    /// @dev Victims 2,3 settled at the VALIDATION-time snapshot = the defaults (C_POSTOP 175k,
    ///      C_WRAP 5k), NOT at the parameters executed mid-bundle (C_POSTOP 400k, C_WRAP 50k).
    function _assertVictimsSettledAtSnapshot(Res memory r, string memory dir) internal view {
        assertEq(r.nPostRevert, 0, string.concat(dir, ": no victim postOp fails"));
        assertEq(r.nFailedOps, 0, string.concat(dir, ": every op of the bundle succeeded"));
        assertEq(r.nTS, 2, string.concat(dir, ": both victims sponsored"));
        assertEq(target.hits(keccak256("v1")), 1, "victim 1 execution kept");
        assertEq(target.hits(keccak256("v2")), 1, "victim 2 execution kept");
        uint256 bufSnap = (175_000 + 5_000 + Math.ceilDiv(uint256(300_000 + 200_000) * 10, 100)) * 1 gwei;
        uint256 bufNew = (uint256(NEW_CPOSTOP) + NEW_CWRAP + Math.ceilDiv(uint256(300_000 + 200_000) * 10, 100)) * 1 gwei;
        assertGt(bufNew, bufSnap + 200_000 gwei, "precondition: the mid-bundle params would move the charge");
        for (uint256 k = 2; k < 4; k++) {
            uint256 W = r.aGas[k] / 1e5; // ETH 2000 / aPNTs 0.02 -> exact
            assertGe(W + 1, r.G[k], "charge covers the op's cost");
            assertLe(W, r.G[k] + bufSnap + 1, string.concat(dir, ": charged at the validation-time snapshot, not the mid-bundle params"));
            // G (UserOperationEvent) exceeds postOp's actualGasCost by at most postOp gas + the 10% penalty
            assertGe(W + 1, r.G[k] + bufSnap - 250_000 gwei, string.concat(dir, ": the snapshot buffer was applied"));
        }
    }

    // =====================================================================

    function test_d5b_forward_mid_bundle_upgrade_with_extension_calls() public {
        _boot(false);
        // on the PREVIOUS release: queue the new gas params through the timelock (48 h internal queue)
        _viaTimelock(abi.encodeCall(SuperPaymasterAdmin.queueGasParams, (NEW_MIN, NEW_SETTLE, NEW_CWRAP, NEW_CPOSTOP)));
        address[] memory t = new address[](3);
        t[0] = address(sp); t[1] = address(sp); t[2] = address(sp);
        bytes[] memory p = new bytes[](3);
        p[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
        p[1] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ()); // extension function of the NEW core
        p[2] = abi.encodeCall(SuperPaymasterAdmin.setGuardian, (acct[1]));
        bytes32 salt = keccak256("forward");
        _scheduleBatch(t, p, salt);
        vm.warp(vm.getBlockTimestamp() + 48 hours); // both the timelock delay and the GP_TIMELOCK matured
        sp.updatePrice();

        PackedUserOperation[] memory ops = new PackedUserOperation[](4);
        ops[0] = _batchExecOp(t, p, salt);   // attacker: upgrade + extension call, mid-bundle
        ops[1] = _guardianPauseOp();         // guardian account: global + operator pause (extension)
        ops[2] = _victimOp(2, "v1");         // admitted by the PREVIOUS release
        ops[3] = _victimOp(3, "v2");
        (uint128 opBal0, , , , , , , , ) = sp.operators(operator);
        uint256 rev0 = sp.protocolRevenue();
        uint256 supply0 = token.totalSupply();
        (bytes32[] memory h, Res memory r) = _run(ops);

        assertEq(address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))), newImpl, "precondition: upgraded mid-bundle");
        assertEq(sp.guardian(), acct[1], "precondition: guardian set mid-bundle");
        assertTrue(sp.paused(), "precondition: sponsorship paused mid-bundle");
        (, , bool opPaused, , , , , , ) = sp.operators(operator);
        assertTrue(opPaused, "precondition: operator paused mid-bundle");
        (SuperPaymasterStorage.GasParams memory cur, ) = sp.gasParams();
        assertEq(cur.cPostop, NEW_CPOSTOP, "precondition: gas params changed mid-bundle");
        _assertVictimsSettledAtSnapshot(r, "forward");
        for (uint256 k = 2; k < 4; k++) {
            assertTrue(token.usedOpHashes(h[k]), "victim settled by D5b while paused");
            (address f, ) = sp.inflightOf(h[k]);
            assertEq(f, address(0), "in-flight cleared");
            assertEq(token.lockedOf(acct[k]), 0, "forward: no residual lock");
        }
        // conservation across the forward upgrade (same deltas as the rollback direction)
        uint256 sumC = r.charge[2] + r.charge[3];
        assertGt(sumC, 0, "positive control: the victims were charged");
        (uint128 opBal1, , , , , , , , ) = sp.operators(operator);
        assertEq(uint256(opBal0) - opBal1, sumC, "forward conservation: operator paid exactly the two charges");
        assertEq(sp.protocolRevenue() - rev0, sumC, "forward conservation: revenue == sum(charge)");
        assertEq(supply0 - token.totalSupply(), r.xBurned, "forward conservation: burned == LockSettled.xBurned");
        assertEq(r.xBurned, sumC, "forward conservation: rate 1:1 -> burned xPNTs == charges");
    }

    function test_d5b_rollback_mid_bundle_with_extension_calls() public {
        _boot(true);
        // positive control: D5b emits 384-byte contexts (snapshot word) for the victims
        uint256 snap = vm.snapshot();
        PackedUserOperation memory probe = _victimOp(2, "probe");
        vm.prank(EP);
        (bytes memory ctx, ) = sp.validatePaymasterUserOp(probe, keccak256("probe"), 1e16);
        uint256 ctxLen = ctx.length;
        vm.revertTo(snap);

        _viaTimelock(abi.encodeCall(SuperPaymasterAdmin.queueGasParams, (NEW_MIN, NEW_SETTLE, NEW_CWRAP, NEW_CPOSTOP)));
        address[] memory t = new address[](2);
        t[0] = address(sp); t[1] = address(sp);
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ()); // extension function, then …
        p[1] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", oldImpl, bytes("")); // … rollback
        bytes32 salt = keccak256("rollback");
        _scheduleBatch(t, p, salt);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        sp.updatePrice();

        (uint128 opBal0, , , , , , , , ) = sp.operators(operator);
        uint256 rev0 = sp.protocolRevenue();
        uint256 supply0 = token.totalSupply();

        PackedUserOperation[] memory ops = new PackedUserOperation[](4);
        ops[0] = _guardianPauseOp();         // guardian account: pause through D5b's extension
        ops[1] = _batchExecOp(t, p, salt);   // attacker: extension call + rollback, mid-bundle
        ops[2] = _victimOp(2, "v1");         // admitted by D5b
        ops[3] = _victimOp(3, "v2");
        (bytes32[] memory h, Res memory r) = _run(ops);

        assertEq(address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))), oldImpl, "precondition: rolled back mid-bundle");
        assertEq(vm.load(address(sp), bytes32(GOV2_SLOT)), bytes32(uint256(uint160(acct[1])) | (uint256(1) << 160)),
            "precondition: the guardian's pause landed before the rollback (slot kept, ignored by the previous release)");
        (SuperPaymasterStorage.GasParams memory cur, ) = sp.gasParams(); // served by the previous release's core
        assertEq(cur.cPostop, NEW_CPOSTOP, "precondition: gas params changed mid-bundle");
        _assertVictimsSettledAtSnapshot(r, "rollback");
        assertEq(ctxLen, 384, "the victims' contexts were D5b's 11 + 1 words");

        uint256 sumC = r.charge[2] + r.charge[3];
        (uint128 opBal1, , , , , , , , ) = sp.operators(operator);
        assertEq(uint256(opBal0) - opBal1, sumC, "rollback conservation: operator paid exactly the two charges");
        assertEq(sp.protocolRevenue() - rev0, sumC, "rollback conservation: revenue == sum(charge)");
        assertEq(supply0 - token.totalSupply(), r.xBurned, "rollback conservation: burned == LockSettled.xBurned");
        assertEq(r.xBurned, sumC, "rollback conservation: rate 1:1 -> burned xPNTs == charges");
        for (uint256 k = 2; k < 4; k++) {
            assertTrue(token.usedOpHashes(h[k]), "victim settled by the previous release");
            (address f, ) = sp.inflightOf(h[k]);
            assertEq(f, address(0), "rollback: in-flight cleared");
            assertEq(token.lockedOf(acct[k]), 0, "rollback: no residual lock");
        }
    }
}
