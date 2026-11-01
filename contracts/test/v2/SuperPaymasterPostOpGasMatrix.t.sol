// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {SelectedGasFixtures} from "../helpers/SelectedGasFixtures.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {AOAProtocolRegistry} from "src/tokens/v2/AOAProtocolRegistry.sol";
import {GlobalTierSource} from "src/tokens/v2/GlobalTierSource.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {xPNTsTokenV2Ext} from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import {xPNTsFactoryV2} from "src/tokens/v2/xPNTsFactoryV2.sol";
import {IxPNTsTokenV2} from "src/tokens/v2/IxPNTsTokenV2.sol";
import {V55Registry, V55APNTs} from "../helpers/V55TestFixtures.sol";
import {V55MutablePriceFeed, V55FuzzTarget, V55OwnerRelay} from "../helpers/V55FuzzFixtures.sol";

import {SimpleAccount} from "@account-abstraction-v7/samples/SimpleAccount.sol";

interface IMatrixToken {
    function mint(address to, uint256 amount) external;
    function updateExchangeRate(uint256 newRate) external;
    function queueCreditPolicy(uint8 p) external;
    function executeCreditPolicy() external;
    function requestCredit(uint256 maxCap) external;
    function approveCredit(address user, uint256 cap) external;
    function setAutoAllowance(address spender, uint256 capAPNTs) external;
    function setUserTotalCap(uint256 capAPNTs) external;
    function disableSpenderForSelf(address spender) external;
    function enableSpenderForSelf(address spender) external;
    function emergencyRevokePaymaster() external;
    function unsetEmergencyDisabled() external;
}

/// @notice Diagnostic only: canonical EntryPoint, real validation and settlement, original tuple.
/// @dev Measure proxy postOp frames in -vvvv traces, not handleOps gas or refunded transaction gas.
///      First/repeat means two operations in ONE bundle for the same user/operator. Validation
///      warms real slots in both cases; "first" does not mean artificially cooling validation.
///      No C_POSTOP bound assertion: the uniform proposal margin is frozen at 15%.
contract SuperPaymasterPostOpGasMatrixTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    uint256 constant BIG_CAP = 50_000 ether;
    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    V55Registry registry;
    V55APNTs apnts;
    V55MutablePriceFeed feed;
    V55FuzzTarget target;
    V55OwnerRelay relay;
    xPNTsTokenV2[2] tok;
    address[2] opr = [address(0x0BE), address(0x0BF)];
    address[3] usr;
    uint256[3] pk = [uint256(0xA001), 0xA002, 0xA003];

    address owner = address(0x0A11);
    address treasury = address(0x7EA);
    address beneficiary = address(0xBEEF);
    address sink = address(0x5111C);

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountFactory = new SimpleAccountFactory(entryPoint);
        target = new V55FuzzTarget();
        relay = new V55OwnerRelay();

        vm.deal(owner, 200 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        apnts = new V55APNTs();
        feed = new V55MutablePriceFeed();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint, IRegistry(address(registry)), address(feed), owner, address(apnts), treasury, 3600
        );
        SelectedGasFixtures.configure(sp);
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsTokenV2 impl = new xPNTsTokenV2(address(aoa), address(ext));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(address(sp), address(registry), address(impl), address(tier));
        sp.setXPNTsFactory(address(factory));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 100 ether}();
        sp.transferOwnership(address(relay)); // owner actions from now on go through the relay
        vm.stopPrank();
        vm.prank(address(relay)); // D5b GOV-2: two-step — the nominee accepts
        sp.acceptOwnership();

        for (uint256 t; t < 2; t++) {
            registry.setRole(keccak256("PAYMASTER_SUPER"), opr[t], true);
            registry.setRole(keccak256("COMMUNITY"), opr[t], true);
            apnts.mint(opr[t], 2_000_000 ether);
            vm.startPrank(opr[t]);
            tok[t] = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
            apnts.approve(address(sp), type(uint256).max);
            sp.configureOperator(address(tok[t]), treasury);
            sp.deposit(1_000_000 ether);
            sp.setOperatorLimits(60); // worst postOp path: fresh lastTimestamp write every bundle
            IMatrixToken(address(tok[t])).queueCreditPolicy(2);
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        for (uint256 t; t < 2; t++) {
            IMatrixToken(address(tok[t])).executeCreditPolicy();
        }
        sp.updatePrice();

        for (uint256 u; u < 3; u++) {
            usr[u] = address(accountFactory.createAccount(vm.addr(pk[u]), 0));
            vm.prank(address(registry));
            sp.updateSBTStatus(usr[u], true);
            registry.setCreditLimit(usr[u], BIG_CAP);
            for (uint256 t; t < 2; t++) {
                vm.startPrank(usr[u]);
                IMatrixToken(address(tok[t])).setAutoAllowance(address(sp), BIG_CAP);
                IMatrixToken(address(tok[t])).setUserTotalCap(BIG_CAP);
                IMatrixToken(address(tok[t])).requestCredit(BIG_CAP);
                vm.stopPrank();
            }
        }
    }

    function _matrixOp(uint256 n, bool revertUser, uint256 u, uint256 t)
        internal
        returns (PackedUserOperation memory op)
    {
        op.sender = usr[u];
        op.nonce = n << 64;
        bytes32 id = keccak256(abi.encode("matrix", n, u, t));
        bytes memory action =
            revertUser ? abi.encodeCall(V55FuzzTarget.hitRevert, (id)) : abi.encodeCall(V55FuzzTarget.hit, (id));
        op.callData = abi.encodeCall(SimpleAccount.execute, (address(target), 0, action));
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(300_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp),
            uint128(SelectedGasFixtures.PM_VERIFICATION),
            uint128(SelectedGasFixtures.MIN_POST()),
            opr[t],
            type(uint256).max,
            address(tok[t]),
            uint8(0)
        );
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk[u], MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _matrix(bool credit, bool revertUser, bool combined) internal {
        (SuperPaymaster.GasParams memory params,) = sp.gasParams();
        assertEq(params.minPostOpGas, 440_000, "deployment MIN_POST");
        assertEq(params.settleGasBound, 420_000, "deployment SETTLE");
        assertEq(params.cWrap, 5_000, "deployment C_WRAP");
        assertEq(params.cPostop, 340_000, "deployment C_POSTOP");
        if (!credit) {
            vm.prank(opr[0]);
            IMatrixToken(address(tok[0])).mint(usr[0], 10_000 ether);
        }
        uint256 count = combined ? 4 : 2;
        PackedUserOperation[] memory ops = new PackedUserOperation[](count);
        for (uint256 i; i < count; ++i) {
            // Combined: both operators, fresh user/operator timestamps, then repeat each pair;
            // all CREDIT, user revert, first debts/revenue/counters and unique settlement guards.
            uint256 t = combined ? i % 2 : 0;
            ops[i] = _matrixOp(i + 1, revertUser, 0, t);
        }
        console.log("MATRIX credit / userRevert", credit, revertUser);
        console.log("MATRIX combined / operations", combined, count);
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory events = vm.getRecordedLogs();
        uint256 settled;
        uint256 modeSettled;
        uint256 completed;
        for (uint256 i; i < events.length; ++i) {
            if (
                events[i].topics[0]
                    == (credit
                            ? keccak256("CreditSettled(address,bytes32,uint256)")
                            : keccak256("LockSettled(address,bytes32,uint256,uint256)"))
            ) ++modeSettled;
            if (events[i].topics[0] == keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)")) {
                assertTrue(false, "diagnostic operation failed settlement");
            }
            if (events[i].topics[0] == keccak256("TransactionSponsored(address,address,uint256,uint256)")) ++settled;
            if (
                events[i].topics[0]
                    == keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")
            ) {
                (, bool success,,) = abi.decode(events[i].data, (uint256, bool, uint256, uint256));
                assertEq(success, !revertUser, "real execution outcome");
                ++completed;
            }
        }
        assertEq(modeSettled, count, "expected settlement mode");
        assertEq(settled, count, "all real postOps settled");
        assertEq(completed, count, "all operations completed");
        for (uint256 i; i < count; ++i) {
            uint256 t = combined ? i % 2 : 0;
            assertTrue(tok[t].usedOpHashes(entryPoint.getUserOpHash(ops[i])), "settlement consumed operation");
        }
    }

    /// forge-config: default.isolate = true
    function test_matrix_balance_success() public {
        _matrix(false, false, false);
    }

    /// forge-config: default.isolate = true
    function test_matrix_balance_revert() public {
        _matrix(false, true, false);
    }

    /// forge-config: default.isolate = true
    function test_matrix_credit_success() public {
        _matrix(true, false, false);
    }

    /// forge-config: default.isolate = true
    function test_matrix_credit_revert() public {
        _matrix(true, true, false);
    }

    /// forge-config: default.isolate = true
    function test_matrix_combined() public {
        _matrix(true, true, true);
    }
}
