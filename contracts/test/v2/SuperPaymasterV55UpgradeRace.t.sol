// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
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
 * @title SuperPaymasterV55UpgradeRaceTest — exp/params, Codex round 2 (OpCtx = upgrade surface)
 * @notice The SP proxy runs the CURRENT 5.5.0 implementation (creation bytecode fixture
 *         `superpaymaster-5.5.0-impl.creation.hex`, built from feat/aoa-balance-mode-5.5.0,
 *         source keccak 0xab8309da…, runtime 22,915 B). Its owner is a real OZ TimelockController
 *         with an OPEN executor. A matured `upgradeToAndCall(experimentImpl, "")` is executed by a
 *         self-funded attacker op INSIDE a bundle, after the later victim ops were VALIDATED by the
 *         5.5.0 implementation. Their postOps run on the experiment implementation and must still
 *         settle: the context layout is unchanged (11 words) and a 5.5.0 context (no gas snapshot)
 *         is settled with the 5.5.0 formula (postOpGasLimit + 10% + 30k, SETTLE 160k).
 */
contract SuperPaymasterV55UpgradeRaceTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");
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

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        address feed = address(new V55PriceFeed());
        // the CURRENT 5.5.0 implementation, from its creation bytecode
        bytes memory init = abi.encodePacked(
            vm.parseBytes(vm.readFile("contracts/test/fixtures/superpaymaster-5.5.0-impl.creation.hex")),
            abi.encode(EP, address(registry), feed)
        );
        address impl;
        assembly { impl := create(0, add(init, 32), mload(init)) }
        require(impl != address(0), "5.5.0 impl deploy");
        oldImpl = impl;
        sp = SuperPaymaster(payable(address(new ERC1967Proxy(
            oldImpl, abi.encodeCall(SuperPaymaster.initialize, (owner, address(apnts), owner, 3600))
        ))));
        assertEq(sp.version(), "SuperPaymaster-5.5.0", "precondition: proxy runs the 5.5.0 implementation");
        newImpl = address(new SuperPaymaster(entryPoint, IRegistry(address(registry)), feed));

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

    function _upgradeData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
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

    function test_mid_bundle_upgrade_from_5_5_0_settles_contexts_of_the_old_impl() public {
        vm.prank(multisig);
        timelock.schedule(address(sp), 0, _upgradeData(), bytes32(0), SALT, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        sp.updatePrice();
        vm.deal(address(this), 1 ether);
        entryPoint.depositTo{value: 1 ether}(acct[0]); // the attacker pays its own gas

        bytes memory exec = abi.encodeCall(TimelockController.execute, (address(sp), 0, _upgradeData(), bytes32(0), SALT));
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        ops[0] = _op(0, abi.encodeWithSignature("execute(address,uint256,bytes)", address(timelock), 0, exec), false);
        ops[1] = _op(1, abi.encodeWithSignature("execute(address,uint256,bytes)", address(target), 0,
            abi.encodeCall(V55FuzzTarget.hit, (keccak256("v1")))), true);
        ops[2] = _op(2, abi.encodeWithSignature("execute(address,uint256,bytes)", address(target), 0,
            abi.encodeCall(V55FuzzTarget.hit, (keccak256("v2")))), true);
        bytes32[3] memory h = [entryPoint.getUserOpHash(ops[0]), entryPoint.getUserOpHash(ops[1]), entryPoint.getUserOpHash(ops[2])];

        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(sp.version(), "SuperPaymaster-5.5.1-exp", "precondition: the attacker's op upgraded SP mid-bundle");
        assertEq(address(uint160(uint256(vm.load(address(sp), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))), newImpl);

        uint256 nPostRevert;
        uint256[3] memory G;
        uint256[3] memory aGas;
        uint256 kt = 1;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == EP && logs[i].topics[0] == T_POSTOP_REVERT) nPostRevert++;
            if (logs[i].emitter == EP && logs[i].topics[0] == T_USEROP) {
                for (uint256 k; k < 3; k++) {
                    if (logs[i].topics[1] == h[k]) (, , G[k], ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                }
            } else if (logs[i].emitter == address(sp) && logs[i].topics[0] == T_TX_SPONSORED) {
                (aGas[kt++], ) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(nPostRevert, 0, "round 2: no victim postOp fails (no out-of-bounds context read) after a mid-bundle upgrade");
        assertEq(kt, 3, "both victims sponsored");
        for (uint256 k = 1; k < 3; k++) {
            assertTrue(token.usedOpHashes(h[k]), "victim settled by the new implementation");
        }
        assertEq(target.hits(keccak256("v1")), 1, "victim 1 execution kept");
        assertEq(target.hits(keccak256("v2")), 1, "victim 2 execution kept");
        // charged under the VALIDATION-time (5.5.0) formula: postOpGasLimit 200k + 10% + C_WRAP 30k
        uint256 bufOld = (200_000 + Math.ceilDiv(uint256(300_000 + 200_000) * 10, 100) + 30_000) * 1 gwei;
        for (uint256 k = 1; k < 3; k++) {
            uint256 W = aGas[k] / 1e5; // ETH 2000 / aPNTs 0.02 -> exact
            assertGe(W + 1, G[k], "charge covers the op's cost");
            assertLe(W, G[k] + bufOld + 1, "charged within the validation-time (5.5.0) bound");
            assertGe(W + 1, G[k] + bufOld - (200_000 + 30_000 + 50_000) * 1 gwei,
                "5.5.0 context is charged with the 5.5.0 formula (not the snapshot-less zero buffer)");
        }
    }
}
