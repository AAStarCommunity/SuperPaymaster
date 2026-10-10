// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
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
 * @title SuperPaymasterRc1Rc2MidBundleTest — spec 03 §6 "rc1 gate fork-rehearsal scope" item 5 / §10.7b C2
 * @notice rc(n) → rc(n+1) bundle-mid-flight tests in BOTH directions between the two tagged release
 *         candidates, each deployed from a creation-bytecode fixture built from its tag (provenance:
 *         contracts/test/fixtures/sp-5.5.0-rc1-rc2.PROVENANCE.md):
 *           rc.1 : v5.5.0-rc.1 → 7ae5b340 (voided by the rc.2 attestation, but the last tagged rc before rc.2)
 *           rc.2 : v5.5.0-rc.2 → 1ac0e1c5 (creation keccak == docs/release/v5.5.0-rc.2-attestation.json)
 *         Neither implementation is compiled from the working tree, so these tests keep meaning
 *         "rc.1 ↔ rc.2" after contracts/src moves on.
 *
 *         SP's owner is a real OZ TimelockController with an OPEN executor. EntryPoint v0.7 validates
 *         every op of the bundle first and executes afterwards, so the victim ops are admitted by the
 *         implementation in place BEFORE the bundle and settled (postOp) by the one in place AFTER the
 *         attacker op. The attacker op executes ONE matured timelock batch that, besides the upgrade,
 *         changes everything a postOp could be sensitive to: the GOV-5 gas parameters (an extension
 *         function, 48 h internal queue already matured) and the protocol fee (the only settlement rule
 *         that differs between rc.1 and rc.2: rc.2 snapshots the fee into bits 128-255 of word 12).
 *
 *           forward : rc.1 → rc.2. Victims carry rc.1 contexts (384 B, fee bits 0). rc.2 must settle
 *                     them at the VALIDATION-time gas snapshot and, having no fee snapshot, at the LIVE
 *                     fee — i.e. exactly what rc.1 itself would have charged (control: rc.1 → rc.1).
 *           rollback: rc.2 → rc.1. Victims carry rc.2 contexts (384 B, fee bits = fee + 1). rc.1 reads
 *                     only uint32 slices below bit 128 of word 12, so it settles them at the gas snapshot
 *                     and the LIVE fee (control: rc.2 → rc.2 charges the snapshotted fee instead).
 *         Every direction asserts: all ops succeed, no PostOpRevertReason, both victims sponsored, their
 *         executions kept, xPNTs lock fully settled (lockedOf == 0, usedOpHashes set), SP in-flight
 *         reservation cleared, and exact aPNTs / xPNTs conservation.
 */
contract SuperPaymasterRc1Rc2MidBundleTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");
    bytes32 constant T_LOCK_SETTLED = keccak256("LockSettled(address,bytes32,uint256,uint256)");

    // ---- release identity (see the PROVENANCE file; creation keccak of forge's bytecode.object)
    string constant RC1_FIXTURE = "contracts/test/fixtures/superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex";
    string constant RC2_FIXTURE = "contracts/test/fixtures/superpaymaster-5.5.0-rc.2-1ac0e1c5-impl.creation.hex";
    bytes32 constant RC1_CREATION_KECCAK = 0x7afad5dab61cff8ea1ac99d45527fff386fab4156e9f62d8fd579745262483cc;
    bytes32 constant RC2_CREATION_KECCAK = 0x4edff578ddfb3875aa057f690fb68b85df24332aa0023a115aadad07107a0e4e; // attestation
    uint256 constant RC1_CORE_RUNTIME = 13_571;
    uint256 constant RC1_EXT_RUNTIME = 19_208;
    uint256 constant RC2_CORE_RUNTIME = 13_744; // attestation runtimeBytes (immutables do not change length)
    uint256 constant RC2_EXT_RUNTIME = 19_214;  // attestation runtimeBytes, SuperPaymasterAdmin

    uint256 constant BPS = 10_000;
    uint256 constant FEE0 = 1000;     // protocolFeeBPS default = the validation-time fee
    uint256 constant FEE_NEW = 2000;  // MAX_PROTOCOL_FEE, executed mid-bundle
    // gas parameters executed MID-BUNDLE (all within the GOV-5 hard bounds, far from the defaults)
    uint32 constant NEW_MIN = 400_000;
    uint32 constant NEW_SETTLE = 300_000;
    uint32 constant NEW_CWRAP = 50_000;
    uint32 constant NEW_CPOSTOP = 400_000;

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    address rc1;
    address rc2;
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

    function _deployFixture(string memory path, bytes32 expectedKeccak, address feed) internal returns (address impl) {
        bytes memory creation = vm.parseBytes(vm.readFile(path));
        assertEq(keccak256(creation), expectedKeccak, string.concat("fixture identity: ", path));
        bytes memory init = abi.encodePacked(creation, abi.encode(EP, address(registry), feed));
        assembly { impl := create(0, add(init, 32), mload(init)) }
        require(impl != address(0), "fixture impl deploy");
    }

    function _boot(bool startOnRc2) internal {
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        address feed = address(new V55PriceFeed());
        rc1 = _deployFixture(RC1_FIXTURE, RC1_CREATION_KECCAK, feed);
        rc2 = _deployFixture(RC2_FIXTURE, RC2_CREATION_KECCAK, feed);
        assertEq(rc1.code.length, RC1_CORE_RUNTIME, "rc.1 core runtime size");
        assertEq(rc2.code.length, RC2_CORE_RUNTIME, "rc.2 core runtime size");
        assertEq(SuperPaymaster(payable(rc1)).EXTENSION().code.length, RC1_EXT_RUNTIME, "rc.1 extension runtime size");
        assertEq(SuperPaymaster(payable(rc2)).EXTENSION().code.length, RC2_EXT_RUNTIME, "rc.2 extension runtime size");
        assertTrue(rc1.codehash != rc2.codehash, "precondition: rc.1 and rc.2 cores differ");
        assertTrue(SuperPaymaster(payable(rc1)).EXTENSION().codehash != SuperPaymaster(payable(rc2)).EXTENSION().codehash,
            "precondition: rc.1 and rc.2 extensions differ");
        sp = SuperPaymaster(payable(address(new ERC1967Proxy(
            startOnRc2 ? rc2 : rc1, abi.encodeCall(SuperPaymaster.initialize, (owner, address(apnts), owner, 3600))
        ))));
        assertTrue(_implIs(startOnRc2 ? rc2 : rc1), "precondition: starting implementation");

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
        vm.prank(owner);
        sp.setGuardian(acct[1]); // both rcs have GOV-2: the guardian is a 4337 account (acts inside a bundle)

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // OPEN executor
        timelock = new TimelockController(1 days, proposers, executors, address(0));
        vm.prank(owner);
        sp.transferOwnership(address(timelock));
        vm.prank(address(timelock));
        sp.acceptOwnership(); // GOV-2 two-step on both rcs
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

    function _implIs(address impl) internal view returns (bool) {
        return address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))) == impl;
    }

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

    /// @dev Schedule `p` (all targeting SP) as ONE timelock batch; mature both the timelock delay and
    ///      SP's internal 48 h gas-parameter queue (queued beforehand on the starting implementation).
    function _prepareBatch(bytes[] memory p, bytes32 salt) internal returns (address[] memory t) {
        _viaTimelock(abi.encodeCall(SuperPaymasterAdmin.queueGasParams, (NEW_MIN, NEW_SETTLE, NEW_CWRAP, NEW_CPOSTOP)));
        t = new address[](p.length);
        for (uint256 i; i < p.length; i++) t[i] = address(sp);
        uint256[] memory v = new uint256[](p.length);
        vm.prank(multisig);
        timelock.scheduleBatch(t, v, p, bytes32(0), salt, 1 days);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        sp.updatePrice();
    }

    /// @dev Context the CURRENT implementation would emit for a victim (state rolled back afterwards).
    function _probeContext() internal returns (bytes memory ctx) {
        uint256 s = vm.snapshot();
        PackedUserOperation memory probe = _victimOp(2, "probe");
        vm.prank(EP);
        (ctx, ) = sp.validatePaymasterUserOp(probe, keccak256("probe"), 1e16);
        vm.revertTo(s);
    }

    function _word12(bytes memory ctx) internal pure returns (uint256 w) {
        assembly { w := mload(add(ctx, 384)) } // data at +32, word 12 at byte 352
    }

    struct Res {
        uint256 nPostRevert;
        uint256 nFailedOps;
        uint256 nUserOpEvents;
        uint256[4] G;
        uint256[4] aGas;
        uint256[4] charge;
        uint256 nTS;
        uint256 nLockSettled;
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
                r.nUserOpEvents++;
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
                r.nLockSettled++;
            }
        }
    }

    function _chargeAt(uint256 aGas, uint256 feeBps) internal pure returns (uint256) {
        return Math.mulDiv(aGas, BPS + feeBps, BPS, Math.Rounding.Ceil);
    }

    /// @dev The full per-victim + bundle-level expectation shared by every direction.
    function _assertSettled(
        bytes32[] memory h, Res memory r, uint256 expectFee, uint256 otherFee,
        uint128 opBal0, uint256 rev0, uint256 supply0, string memory dir
    ) internal view {
        assertEq(r.nUserOpEvents, 4, string.concat(dir, ": 4 UserOperationEvents"));
        assertEq(r.nFailedOps, 0, string.concat(dir, ": every op of the bundle succeeded"));
        assertEq(r.nPostRevert, 0, string.concat(dir, ": no victim postOp fails"));
        assertEq(r.nTS, 2, string.concat(dir, ": both victims sponsored (TransactionSponsored x2)"));
        assertEq(r.nLockSettled, 2, string.concat(dir, ": both xPNTs locks settled (LockSettled x2)"));
        assertEq(target.hits(keccak256("v1")), 1, string.concat(dir, ": victim 1 execution kept"));
        assertEq(target.hits(keccak256("v2")), 1, string.concat(dir, ": victim 2 execution kept"));

        // gas: settled at the VALIDATION-time snapshot (defaults C_POSTOP 175k, C_WRAP 5k), not at the
        // parameters executed mid-bundle (C_POSTOP 400k, C_WRAP 50k)
        uint256 bufSnap = (175_000 + 5_000 + Math.ceilDiv(uint256(300_000 + 200_000) * 10, 100)) * 1 gwei;
        uint256 bufNew = (uint256(NEW_CPOSTOP) + NEW_CWRAP + Math.ceilDiv(uint256(300_000 + 200_000) * 10, 100)) * 1 gwei;
        assertGt(bufNew, bufSnap + 200_000 gwei, "precondition: the mid-bundle params would move the charge");
        for (uint256 k = 2; k < 4; k++) {
            uint256 W = r.aGas[k] / 1e5; // ETH 2000 / aPNTs 0.02 -> exact
            assertGt(r.aGas[k], 0, "positive control: aGas > 0");
            assertGe(W + 1, r.G[k], "charge covers the op's cost");
            assertLe(W, r.G[k] + bufSnap + 1, string.concat(dir, ": gas at the validation-time snapshot, not the mid-bundle params"));
            assertGe(W + 1, r.G[k] + bufSnap - 250_000 gwei, string.concat(dir, ": the snapshot buffer was applied"));
            // fee
            assertTrue(_chargeAt(r.aGas[k], expectFee) != _chargeAt(r.aGas[k], otherFee), "precondition: the two fees are distinguishable");
            assertEq(r.charge[k], _chargeAt(r.aGas[k], expectFee), string.concat(dir, ": charged at the expected protocol fee"));
            // no stuck reservation / lock
            assertTrue(token.usedOpHashes(h[k]), string.concat(dir, ": victim settled (usedOpHashes)"));
            (address f, uint256 a0) = sp.inflightOf(h[k]);
            assertEq(f, address(0), string.concat(dir, ": SP in-flight operator cleared"));
            assertEq(a0, 0, string.concat(dir, ": SP in-flight a0 cleared"));
            assertEq(token.lockedOf(acct[k]), 0, string.concat(dir, ": no residual xPNTs lock"));
        }
        // conservation
        uint256 sumC = r.charge[2] + r.charge[3];
        assertGt(sumC, 0, "positive control: the victims were charged");
        (uint128 opBal1, , , , , , , , ) = sp.operators(operator);
        assertEq(uint256(opBal0) - opBal1, sumC, string.concat(dir, " conservation: operator paid exactly the two charges"));
        assertEq(sp.protocolRevenue() - rev0, sumC, string.concat(dir, " conservation: revenue == sum(charge)"));
        assertEq(supply0 - token.totalSupply(), r.xBurned, string.concat(dir, " conservation: burned == LockSettled.xBurned"));
        assertEq(r.xBurned, sumC, string.concat(dir, " conservation: rate 1:1 -> burned xPNTs == charges"));
    }

    /// @dev Runs the bundle [p0, p1, victim1, victim2] and checks the end state.
    function _bundle(PackedUserOperation memory p0, PackedUserOperation memory p1)
        internal returns (bytes32[] memory h, Res memory r, uint128 opBal0, uint256 rev0, uint256 supply0)
    {
        (opBal0, , , , , , , , ) = sp.operators(operator);
        rev0 = sp.protocolRevenue();
        supply0 = token.totalSupply();
        PackedUserOperation[] memory ops = new PackedUserOperation[](4);
        ops[0] = p0;
        ops[1] = p1;
        ops[2] = _victimOp(2, "v1");
        ops[3] = _victimOp(3, "v2");
        (h, r) = _run(ops);
    }

    function _assertMidBundleState() internal view {
        assertTrue(sp.paused(), "precondition: sponsorship paused mid-bundle");
        (, , bool opPaused, , , , , , ) = sp.operators(operator);
        assertTrue(opPaused, "precondition: operator paused mid-bundle");
        (SuperPaymasterStorage.GasParams memory cur, ) = sp.gasParams();
        assertEq(cur.cPostop, NEW_CPOSTOP, "precondition: gas params changed mid-bundle");
        assertEq(sp.protocolFeeBPS(), FEE_NEW, "precondition: protocol fee changed mid-bundle");
    }

    // ===================================================================== forward rc.1 → rc.2

    function test_rc1_to_rc2_forward_mid_bundle() public {
        _boot(false);
        bytes memory ctx = _probeContext();
        assertEq(ctx.length, 384, "rc.1 emits a 384-byte context");
        assertEq(_word12(ctx) >> 128, 0, "rc.1 context carries no fee snapshot (bits 128-255 == 0)");

        bytes[] memory p = new bytes[](3);
        p[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", rc2, bytes(""));
        p[1] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ()); // extension of the NEW core
        p[2] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (FEE_NEW)); // extension of the NEW core
        bytes32 salt = keccak256("rc1->rc2");
        address[] memory t = _prepareBatch(p, salt);

        (bytes32[] memory h, Res memory r, uint128 b0, uint256 rv0, uint256 s0) =
            _bundle(_batchExecOp(t, p, salt), _guardianPauseOp());

        assertTrue(_implIs(rc2), "precondition: upgraded to rc.2 mid-bundle");
        _assertMidBundleState();
        // rc.2 legacy rule for a 384-B context with zero fee bits: the LIVE fee (what rc.1 charges)
        _assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "forward rc.1->rc.2");
    }

    // ===================================================================== rollback rc.2 → rc.1

    function test_rc2_to_rc1_rollback_mid_bundle() public {
        _boot(true);
        bytes memory ctx = _probeContext();
        assertEq(ctx.length, 384, "rc.2 emits a 384-byte context");
        assertEq(_word12(ctx) >> 128, FEE0 + 1, "rc.2 context snapshots the fee (fee + 1) in bits 128-255");

        bytes[] memory p = new bytes[](3);
        p[0] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ()); // extension of rc.2, then …
        p[1] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (FEE_NEW));
        p[2] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", rc1, bytes("")); // … rollback
        bytes32 salt = keccak256("rc2->rc1");
        address[] memory t = _prepareBatch(p, salt);

        // guardian pauses through rc.2 first, then the attacker rolls back
        (bytes32[] memory h, Res memory r, uint128 b0, uint256 rv0, uint256 s0) =
            _bundle(_guardianPauseOp(), _batchExecOp(t, p, salt));

        assertTrue(_implIs(rc1), "precondition: rolled back to rc.1 mid-bundle");
        _assertMidBundleState();
        // rc.1 ignores bits >= 128 of word 12: gas snapshot honoured, fee = LIVE fee
        _assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "rollback rc.2->rc.1");
    }

    // ===================================================================== controls (no upgrade)

    /// @dev Same bundle without the upgrade, staying on rc.2: the fee snapshot applies (FEE0), which
    ///      shows the fee assertion above discriminates and that the rollback outcome is rc.1's rule.
    function test_control_rc2_stays_chargesSnapshotFee() public {
        _boot(true);
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ());
        p[1] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (FEE_NEW));
        bytes32 salt = keccak256("rc2 stays");
        address[] memory t = _prepareBatch(p, salt);
        (bytes32[] memory h, Res memory r, uint128 b0, uint256 rv0, uint256 s0) =
            _bundle(_guardianPauseOp(), _batchExecOp(t, p, salt));
        assertTrue(_implIs(rc2), "precondition: still rc.2");
        _assertMidBundleState();
        _assertSettled(h, r, FEE0, FEE_NEW, b0, rv0, s0, "control rc.2->rc.2");
    }

    /// @dev Same bundle without the upgrade, staying on rc.1: live fee. The forward direction must
    ///      reproduce exactly this rule (rc.2 settles rc.1 contexts as rc.1 would).
    function test_control_rc1_stays_chargesLiveFee() public {
        _boot(false);
        bytes[] memory p = new bytes[](2);
        p[0] = abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ());
        p[1] = abi.encodeCall(SuperPaymasterAdmin.setProtocolFee, (FEE_NEW));
        bytes32 salt = keccak256("rc1 stays");
        address[] memory t = _prepareBatch(p, salt);
        (bytes32[] memory h, Res memory r, uint128 b0, uint256 rv0, uint256 s0) =
            _bundle(_guardianPauseOp(), _batchExecOp(t, p, salt));
        assertTrue(_implIs(rc1), "precondition: still rc.1");
        _assertMidBundleState();
        _assertSettled(h, r, FEE_NEW, FEE0, b0, rv0, s0, "control rc.1->rc.1");
    }
}
