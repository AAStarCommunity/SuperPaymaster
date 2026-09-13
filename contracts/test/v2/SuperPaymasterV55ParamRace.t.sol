// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { TimelockController } from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { V55Registry, V55PriceFeed, V55APNTs, IV2Ext } from "../helpers/V55TestFixtures.sol";
import { V55FuzzTarget } from "../helpers/V55FuzzFixtures.sol";

/**
 * @title SuperPaymasterV55ParamRaceTest — exp/params, Codex B-HIGH-1
 * @notice SP owned by a REAL OpenZeppelin TimelockController whose EXECUTOR role is OPEN
 *         (executors = [address(0)]). A matured `executeGasParams` (SETTLE_GAS_BOUND -> 1M,
 *         MIN -> 1.1M, C_POSTOP -> 1M, C_WRAP -> 50k) is triggered by an attacker's user op
 *         (self-paid, not sponsored by SP, so nothing of SP can roll it back) INSIDE a bundle, i.e. after every validation of the bundle and before the later ops'
 *         postOps. Without the OpCtx snapshot, the later, already-admitted ops (postOpGasLimit
 *         200k) would hit `gasleft() < 1M` → PostOpGasTooLow → execution rolled back, their gas
 *         taken from SP's EntryPoint deposit (griefing), and their charges would be computed with
 *         the new C_POSTOP. With the snapshot they settle under the parameters they validated with.
 */
contract SuperPaymasterV55ParamRaceTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    TimelockController timelock;
    xPNTsTokenV2 token;
    V55Registry registry;
    V55FuzzTarget target;
    address owner = address(0x0A11);
    address multisig = address(0x5AFE);
    address operator = address(0x0BE);
    address beneficiary = address(0xBEEF);
    uint256[3] pk = [uint256(0xB001), 0xB002, 0xB003]; // attacker, victim 1, victim 2
    address[3] acct;

    bytes32 constant SALT_QUEUE = keccak256("queue");
    bytes32 constant SALT_EXEC = keccak256("exec");

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
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint, IRegistry(address(registry)), address(new V55PriceFeed()), owner, address(apnts), owner, 3600
        );
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

        // owner = TimelockController, proposer = multisig, EXECUTOR OPEN (address(0)), self-admin
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(1 days, proposers, executors, address(0));
        sp.transferOwnership(address(timelock));
        vm.stopPrank();
        vm.prank(address(timelock)); // D5b GOV-2: two-step — the nominee accepts
        sp.acceptOwnership();

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

    function _execData() internal pure returns (bytes memory) {
        return abi.encodeCall(SuperPaymasterAdmin.executeGasParams, ());
    }

    /// @dev Governance: queue (1M settle) through the timelock, wait SP's 48 h, schedule the SP
    ///      execute through the timelock and let it mature — READY but NOT executed.
    function _matureParamIncrease() internal {
        bytes memory q = abi.encodeCall(SuperPaymasterAdmin.queueGasParams, (1_100_000, 1_000_000, 50_000, 1_000_000));
        vm.prank(multisig);
        timelock.schedule(address(sp), 0, q, bytes32(0), SALT_QUEUE, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        timelock.execute(address(sp), 0, q, bytes32(0), SALT_QUEUE); // open executor
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(multisig);
        timelock.schedule(address(sp), 0, _execData(), bytes32(0), SALT_EXEC, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertTrue(timelock.isOperationReady(timelock.hashOperation(address(sp), 0, _execData(), bytes32(0), SALT_EXEC)),
            "precondition: SP executeGasParams is READY in the timelock");
        sp.updatePrice();
    }

    function _op(uint256 i, uint256 nonceKey, bytes memory inner) internal view returns (PackedUserOperation memory op) {
        op.sender = acct[i];
        op.nonce = nonceKey << 64;
        op.callData = abi.encodeWithSignature("execute(address,uint256,bytes)",
            i == 0 ? address(timelock) : address(target), 0, inner);
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(300_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        if (i != 0) {
            op.paymasterAndData = abi.encodePacked(
                address(sp), uint128(700_000), uint128(200_000), operator, type(uint256).max, address(token), uint8(0)
            );
        }
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk[i], MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function test_open_executor_param_change_mid_bundle_does_not_harm_admitted_ops() public {
        _matureParamIncrease();
        vm.deal(address(this), 1 ether);
        entryPoint.depositTo{value: 1 ether}(acct[0]); // the attacker pays its own gas
        PackedUserOperation[] memory ops = new PackedUserOperation[](3);
        // op0: attacker executes the matured change through the OPEN executor, mid-bundle
        ops[0] = _op(0, 1, abi.encodeCall(TimelockController.execute, (address(sp), 0, _execData(), bytes32(0), SALT_EXEC)));
        ops[1] = _op(1, 1, abi.encodeCall(V55FuzzTarget.hit, (keccak256("v1"))));
        ops[2] = _op(2, 1, abi.encodeCall(V55FuzzTarget.hit, (keccak256("v2"))));
        bytes32[3] memory h = [entryPoint.getUserOpHash(ops[0]), entryPoint.getUserOpHash(ops[1]), entryPoint.getUserOpHash(ops[2])];

        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (SuperPaymaster.GasParams memory g, ) = sp.gasParams();
        assertEq(g.settleGasBound, 1_000_000, "precondition: the attacker's op really executed the change mid-bundle");
        assertEq(g.cPostop, 1_000_000, "precondition: C_POSTOP changed mid-bundle too");

        uint256 nPostRevert;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == EP && logs[i].topics[0] == T_POSTOP_REVERT) nPostRevert++;
        }
        assertEq(nPostRevert, 0, "B-HIGH-1: no admitted op's postOp fails after a mid-bundle parameter change");
        for (uint256 k = 1; k < 3; k++) {
            assertTrue(token.usedOpHashes(h[k]), "every SP-sponsored admitted op settled");
        }
        assertEq(target.hits(keccak256("v1")), 1, "victim 1 execution kept");
        assertEq(target.hits(keccak256("v2")), 1, "victim 2 execution kept");

        // the victims were charged under the VALIDATION-time buffer (175k + 10% + 5k), not the new
        // one (1M + 10% + 50k): aGas at snapshot prices lies in [G, G + bufWei_snapshot]
        uint256[3] memory G;
        uint256[3] memory aGas;
        uint256 kt = 1;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == EP && logs[i].topics[0] == T_USEROP) {
                for (uint256 k; k < 3; k++) {
                    if (logs[i].topics[1] == h[k]) (, , G[k], ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                }
            } else if (logs[i].emitter == address(sp) && logs[i].topics[0] == T_TX_SPONSORED) {
                (aGas[kt++], ) = abi.decode(logs[i].data, (uint256, uint256)); // victims, in bundle order
            }
        }
        assertEq(kt, 3, "two SP sponsorships (the victims)");
        uint256 bufSnap = (175_000 + Math.ceilDiv(uint256(300_000 + 200_000) * 10, 100) + 5_000) * 1 gwei;
        for (uint256 k = 1; k < 3; k++) {
            uint256 W = aGas[k] / 1e5; // ETH 2000 / aPNTs 0.02 -> 1e5 aPNTs-wei per wei, exact
            assertGe(W + 1, G[k], "charge covers the op's cost");
            assertLe(W, G[k] + bufSnap + 1, "B-HIGH-1: charged with the VALIDATION-time C_POSTOP / C_WRAP");
        }

        // control: the change is real — a NEW op with a 200k postOp limit is now below MIN (1.1M)
        PackedUserOperation[] memory late = new PackedUserOperation[](1);
        late[0] = _op(1, 2, abi.encodeCall(V55FuzzTarget.hit, (keccak256("late"))));
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA34 signature error"));
        entryPoint.handleOps(late, payable(beneficiary));
    }
}
