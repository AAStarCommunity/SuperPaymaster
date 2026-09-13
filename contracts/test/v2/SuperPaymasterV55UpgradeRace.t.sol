// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
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

/**
 * @title SuperPaymasterV55UpgradeRaceTest — exp/params, Codex rounds 2-3 (OpCtx = upgrade surface)
 * @notice Mid-bundle UUPS upgrades in BOTH directions between the CURRENT 5.5.0 implementation
 *         (creation-bytecode fixture `superpaymaster-5.5.0-impl.creation.hex`, built from
 *         feat/aoa-balance-mode-5.5.0, source keccak 0xab8309da…fe4, runtime 22,915 B) and the
 *         experiment implementation. SP's owner is a real OZ TimelockController with an OPEN
 *         executor; a self-funded attacker op executes the matured `upgradeToAndCall` INSIDE the
 *         bundle, after the victim ops were validated by the OTHER implementation.
 *           forward : validated by 5.5.0 (352-byte context) → settled by the experiment impl, which
 *                     must not read past byte 352 and applies the 5.5.0 rules (SETTLE 160k,
 *                     buffer postOpGasLimit + 10% + 30k);
 *           rollback: validated by the experiment impl (384-byte context: the 11 ABI-canonical 5.5.0
 *                     words + 1 snapshot word) → settled by 5.5.0, whose `abi.decode(context,
 *                     (OpCtx))` must accept it (trailing word ignored, word 9 a clean uint8).
 */
contract SuperPaymasterV55UpgradeRaceTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");
    bytes32 constant T_LOCK_SETTLED = keccak256("LockSettled(address,bytes32,uint256,uint256)");
    bytes32 constant SALT = keccak256("upgrade");

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
    uint256[3] pk = [uint256(0xC001), 0xC002, 0xC003]; // attacker, victim 1, victim 2
    address[3] acct;

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountFactory = new SimpleAccountFactory(entryPoint);
        target = new V55FuzzTarget();
    }

    /// @param startOnNew true: the proxy starts on the experiment impl (rollback test)
    function _boot(bool startOnNew) internal {
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        address feed = address(new V55PriceFeed());
        bytes memory init = abi.encodePacked(
            vm.parseBytes(vm.readFile("contracts/test/fixtures/superpaymaster-5.5.0-impl.creation.hex")),
            abi.encode(EP, address(registry), feed)
        );
        address impl;
        assembly { impl := create(0, add(init, 32), mload(init)) }
        require(impl != address(0), "5.5.0 impl deploy");
        oldImpl = impl;
        newImpl = address(new SuperPaymaster(entryPoint, IRegistry(address(registry)), feed));
        sp = SuperPaymaster(payable(address(new ERC1967Proxy(
            startOnNew ? newImpl : oldImpl, abi.encodeCall(SuperPaymaster.initialize, (owner, address(apnts), owner, 3600))
        ))));
        assertEq(sp.version(), startOnNew ? "SuperPaymaster-5.5.1-exp" : "SuperPaymaster-5.5.0", "precondition: starting implementation");

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

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // OPEN executor
        timelock = new TimelockController(1 days, proposers, executors, address(0));
        sp.transferOwnership(address(timelock));
        vm.stopPrank();

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), owner);
        sp.deposit(100_000 ether);
        vm.stopPrank();
        for (uint256 i; i < 3; i++) {
            acct[i] = address(accountFactory.createAccount(vm.addr(pk[i]), 0));
            vm.prank(address(registry));
            sp.updateSBTStatus(acct[i], true);
            vm.prank(operator);
            IV2Ext(address(token)).mint(acct[i], 10_000 ether);
        }
    }

    function _upgradeData(address to) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("upgradeToAndCall(address,bytes)", to, bytes(""));
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

    struct Res {
        uint256 nPostRevert;
        uint256[3] G;
        uint256[3] charge;
        uint256[3] aGas;
        uint256 nTS;
        uint256 xBurned;
    }

    /// @dev Schedules the upgrade to `to`, runs [attacker upgrade op, victim 1, victim 2].
    function _runUpgradeBundle(address to) internal returns (bytes32[3] memory h, Res memory r) {
        vm.prank(multisig);
        timelock.schedule(address(sp), 0, _upgradeData(to), bytes32(0), SALT, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        sp.updatePrice();
        vm.deal(address(this), 1 ether);
        entryPoint.depositTo{value: 1 ether}(acct[0]); // the attacker pays its own gas

        bytes memory exec = abi.encodeCall(TimelockController.execute, (address(sp), 0, _upgradeData(to), bytes32(0), SALT));
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _op(0, abi.encodeWithSignature("execute(address,uint256,bytes)", address(timelock), 0, exec), false);
        ops[1] = _op(1, abi.encodeWithSignature("execute(address,uint256,bytes)", address(target), 0,
            abi.encodeCall(V55FuzzTarget.hit, (keccak256("v1")))), true);
        ops[2] = _op(2, abi.encodeWithSignature("execute(address,uint256,bytes)", address(target), 0,
            abi.encodeCall(V55FuzzTarget.hit, (keccak256("v2")))), true);
        h = [entryPoint.getUserOpHash(ops[0]), entryPoint.getUserOpHash(ops[1]), entryPoint.getUserOpHash(ops[2])];

        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        r.nTS = 1;
        for (uint256 i; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (logs[i].emitter == EP && t0 == T_POSTOP_REVERT) r.nPostRevert++;
            if (logs[i].emitter == EP && t0 == T_USEROP) {
                for (uint256 k; k < 3; k++) {
                    if (logs[i].topics[1] == h[k]) (, , r.G[k], ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                }
            } else if (logs[i].emitter == address(sp) && t0 == T_TX_SPONSORED && r.nTS < 3) {
                (r.aGas[r.nTS], r.charge[r.nTS]) = abi.decode(logs[i].data, (uint256, uint256));
                r.nTS++;
            } else if (logs[i].emitter == address(token) && t0 == T_LOCK_SETTLED) {
                (uint256 xb, ) = abi.decode(logs[i].data, (uint256, uint256));
                r.xBurned += xb;
            }
        }
    }

    function _assertVictimsSettled(bytes32[3] memory h, Res memory r, string memory dir) internal view {
        assertEq(r.nPostRevert, 0, string.concat(dir, ": no victim postOp fails after a mid-bundle upgrade"));
        assertEq(r.nTS, 3, "both victims sponsored");
        for (uint256 k = 1; k < 3; k++) {
            assertTrue(token.usedOpHashes(h[k]), "victim settled by the implementation after the switch");
        }
        assertEq(target.hits(keccak256("v1")), 1, "victim 1 execution kept");
        assertEq(target.hits(keccak256("v2")), 1, "victim 2 execution kept");
    }

    /// @dev The victims are charged with the 5.5.0 formula in BOTH directions (forward: the new impl's
    ///      legacy rule for a 352-byte context; rollback: 5.5.0 itself).
    function _assertChargedWith550Formula(Res memory r) internal pure {
        uint256 bufOld = (200_000 + Math.ceilDiv(uint256(300_000 + 200_000) * 10, 100) + 30_000) * 1 gwei;
        for (uint256 k = 1; k < 3; k++) {
            uint256 W = r.aGas[k] / 1e5; // ETH 2000 / aPNTs 0.02 -> exact
            assertGe(W + 1, r.G[k], "charge covers the op's cost");
            assertLe(W, r.G[k] + bufOld + 1, "charged within the 5.5.0 (validation-time) bound");
            assertGe(W + 1, r.G[k] + bufOld - (200_000 + 30_000 + 50_000) * 1 gwei,
                "charged with the 5.5.0 formula (not a zero / snapshot buffer)");
        }
    }

    function test_mid_bundle_upgrade_from_5_5_0_settles_contexts_of_the_old_impl() public {
        _boot(false);
        (bytes32[3] memory h, Res memory r) = _runUpgradeBundle(newImpl);
        assertEq(sp.version(), "SuperPaymaster-5.5.1-exp", "precondition: the attacker's op upgraded SP mid-bundle");
        assertEq(address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))), newImpl);
        _assertVictimsSettled(h, r, "forward");
        _assertChargedWith550Formula(r);
    }

    /// @notice Codex round 3: rollback (experiment → 5.5.0) mid-bundle. 5.5.0 must settle the
    ///         384-byte contexts the experiment implementation produced, with correct conservation.
    function test_mid_bundle_rollback_to_5_5_0_settles_contexts_of_the_new_impl() public {
        _boot(true);
        // positive control, probed before the bundle and asserted AFTER the settlement assertions
        // (so a wrong format surfaces as the named settlement failure first)
        uint256 snap = vm.snapshot();
        PackedUserOperation memory probe = _op(1, "", true);
        vm.prank(EP);
        (bytes memory ctx, ) = sp.validatePaymasterUserOp(probe, keccak256("probe"), 1e16);
        uint256 w9;
        assembly { w9 := mload(add(ctx, 320)) }
        uint256 ctxLen = ctx.length;
        vm.revertTo(snap);

        (uint128 opBal0, , , , , , , , ) = sp.operators(operator);
        uint256 rev0 = sp.protocolRevenue();
        uint256 supply0 = token.totalSupply();

        (bytes32[3] memory h, Res memory r) = _runUpgradeBundle(oldImpl);
        assertEq(sp.version(), "SuperPaymaster-5.5.0", "precondition: the attacker's op rolled SP back mid-bundle");
        assertEq(address(uint160(uint256(vm.load(address(sp), IMPL_SLOT)))), oldImpl);
        _assertVictimsSettled(h, r, "rollback");
        _assertChargedWith550Formula(r);
        assertEq(ctxLen, 384, "the victims' contexts were the experiment format (11 + 1 words)");
        assertEq(w9, 8, "word 9 is an ABI-canonical uint8 decimals (no packed bits)");

        // conservation across the rollback
        uint256 sumC = r.charge[1] + r.charge[2];
        (uint128 opBal1, , , , , , , , ) = sp.operators(operator);
        assertEq(uint256(opBal0) - opBal1, sumC, "rollback conservation: operator paid exactly the two charges");
        assertEq(sp.protocolRevenue() - rev0, sumC, "rollback conservation: revenue == sum(charge)");
        assertEq(supply0 - token.totalSupply(), r.xBurned, "rollback conservation: burned == LockSettled.xBurned");
        assertEq(r.xBurned, sumC, "rollback conservation: rate 1:1 -> burned xPNTs == charges");
        for (uint256 k = 1; k < 3; k++) {
            (address f, ) = sp.inflightOf(h[k]);
            assertEq(f, address(0), "rollback: in-flight cleared");
            assertEq(token.lockedOf(acct[k]), 0, "rollback: no residual lock");
        }
    }
}
