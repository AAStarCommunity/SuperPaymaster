// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import { APNTsCapped } from "src/tokens/APNTsCapped.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";

import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { V55Registry, V55PriceFeed, IV2Ext } from "../helpers/V55TestFixtures.sol";

/**
 * @title APNTsCappedSPIntegrationTest — the REAL SuperPaymaster 5.5.0 proxy initialised with
 *        APNTsCapped as APNTS_TOKEN, on the CANONICAL EntryPoint v0.7 runtime bytecode (same
 *        fixture approach as SuperPaymasterV55Gas.t.sol).
 */
contract APNTsCappedSPIntegrationTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    uint256 constant OWNER_PK = 0xA0A0;
    uint256 constant CAP = 10_000_000 ether;

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    address accountOwner;
    address beneficiary = address(0xBEEF);

    SuperPaymaster sp;
    APNTsCapped apnts;
    xPNTsTokenV2 token;
    V55Registry registry;
    address owner = address(0x0A11);
    address operator = address(0x0BE);
    address treasury = address(0x7EA);
    address minter = makeAddr("minter");
    address funder = makeAddr("funder");
    address user;

    /// @dev The APNTsCapped artifact whose own metadata says runs == 500 (profile.default), never
    ///      chosen by file name alone (forge's suffix scheme depends on which profiles built it).
    function _defaultApntsArtifact() internal view returns (string memory) {
        string[2] memory c = ["out/APNTsCapped.sol/APNTsCapped.json", "out/APNTsCapped.sol/APNTsCapped.default.json"];
        for (uint256 i; i < c.length; ++i) {
            try vm.readFile(string.concat(vm.projectRoot(), "/", c[i])) returns (string memory j) {
                if (vm.parseJsonUint(j, ".metadata.settings.optimizer.runs") == 500
                    && vm.keyExistsJson(j, "$.metadata.settings.compilationTarget['contracts/src/tokens/APNTsCapped.sol']")) {
                    return c[i];
                }
            } catch { }
        }
        revert("no runs=500 APNTsCapped artifact");
    }

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountOwner = vm.addr(OWNER_PK);
        accountFactory = new SimpleAccountFactory(entryPoint);
        user = address(accountFactory.createAccount(accountOwner, 1));

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        // NOT `new APNTsCapped(...)`: this file imports Registry.sol (via UUPSDeployHelper), so its
        // whole closure is compiled under the runs=200 "registry-size" profile. Deploy the token
        // from its profile.default (runs 500) artifact instead — the build the deploy script ships.
        apnts = APNTsCapped(vm.deployCode(_defaultApntsArtifact(), abi.encode("AAStar PNTs", "aPNTs", CAP, owner, minter, owner)));
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint, IRegistry(address(registry)), address(new V55PriceFeed()), owner, address(apnts), treasury, 3600
        );
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
        sp.deposit{value: 5 ether}();
        vm.stopPrank();

        vm.prank(minter);
        apnts.mint(operator, 1_000_000 ether);
        vm.prank(minter);
        apnts.mint(funder, 1_000 ether);

        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        IV2Ext(address(token)).mint(user, 10_000 ether);
        sp.configureOperator(address(token), treasury);
        sp.setOperatorLimits(60);
        vm.stopPrank();
    }

    function _opBal() internal view returns (uint256 b) {
        uint128 x;
        (x,,,,,,,,) = sp.operators(operator);
        b = x;
    }

    /// @dev SP's aPNTs holdings are exactly its tracked liabilities (operators + revenue).
    function _assertBacked(string memory tag) internal view {
        assertEq(apnts.balanceOf(address(sp)), sp.totalTrackedBalance(), string.concat(tag, ": SP aPNTs == totalTrackedBalance"));
        assertEq(sp.totalTrackedBalance(), _opBal() + sp.protocolRevenue(), string.concat(tag, ": tracked == operator + revenue"));
        assertLe(apnts.totalSupply(), apnts.cap(), string.concat(tag, ": supply <= cap"));
    }

    function test_SP_initialised_with_APNTsCapped() public view {
        assertEq(sp.APNTS_TOKEN(), address(apnts), "SP.APNTS_TOKEN == APNTsCapped");
    }

    function test_SP_deposit_approve_pull() public {
        vm.startPrank(operator);
        apnts.approve(address(sp), 100 ether);
        sp.deposit(100 ether);
        vm.stopPrank();
        assertEq(_opBal(), 100 ether, "deposit (approve + transferFrom) credits the operator");
        assertEq(apnts.balanceOf(operator), 1_000_000 ether - 100 ether);
        _assertBacked("deposit");
    }

    function test_SP_deposit_transferAndCall_push() public {
        vm.prank(operator);
        assertTrue(apnts.transferAndCall(address(sp), 250 ether));
        assertEq(_opBal(), 250 ether, "transferAndCall -> onTransferReceived credits the operator");
        _assertBacked("push");

        // a non-operator push is rejected by SP and the revert is bubbled through the token
        vm.prank(funder);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        apnts.transferAndCall(address(sp), 1 ether);
        assertEq(apnts.balanceOf(funder), 1_000 ether);

        // onTransferReceived only honours the configured APNTS_TOKEN
        vm.prank(funder);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.onTransferReceived(funder, operator, 1 ether, "");
    }

    function test_SP_depositFor() public {
        vm.startPrank(funder);
        apnts.approve(address(sp), 40 ether);
        sp.depositFor(operator, 40 ether);
        vm.stopPrank();
        assertEq(_opBal(), 40 ether, "depositFor credits the target operator");
        assertEq(apnts.balanceOf(funder), 960 ether);
        _assertBacked("depositFor");
    }

    function test_SP_withdraw() public {
        vm.startPrank(operator);
        apnts.approve(address(sp), 100 ether);
        sp.deposit(100 ether);
        sp.withdraw(30 ether);
        vm.stopPrank();
        assertEq(_opBal(), 70 ether, "withdraw debits the operator");
        assertEq(apnts.balanceOf(operator), 1_000_000 ether - 70 ether);
        _assertBacked("withdraw");
    }

    function _signedOp(uint256 nonce) internal view returns (PackedUserOperation memory op) {
        op.sender = user;
        op.nonce = nonce;
        op.callData = "";
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(0)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(700_000), uint128(200_000), operator, type(uint256).max, address(token), uint8(0)
        );
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _runOp(uint256 nonce) internal returns (bool success) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _signedOp(nonce);
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 ev = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == EP && logs[i].topics[0] == ev) {
                (, success, , ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                n++;
            }
        }
        assertEq(n, 1, "one UserOperationEvent");
    }

    function test_SP_gasless_balance_mode_op_conservation() public {
        vm.startPrank(operator);
        apnts.approve(address(sp), type(uint256).max);
        sp.deposit(100_000 ether);
        vm.stopPrank();

        uint256 op0 = _opBal();
        uint256 rev0 = sp.protocolRevenue();
        uint256 xSupply0 = token.totalSupply();
        uint256 xUser0 = token.balanceOf(user);
        uint256 spA0 = apnts.balanceOf(address(sp));
        uint256 aSupply0 = apnts.totalSupply();

        assertTrue(_runOp(0), "gasless op succeeded");

        uint256 opDelta = op0 - _opBal();
        uint256 revDelta = sp.protocolRevenue() - rev0;
        uint256 burned = xSupply0 - token.totalSupply();
        assertGt(revDelta, 0, "op settled (non-zero charge)");
        assertEq(opDelta, revDelta, "conservation: operator aPNTs delta == protocolRevenue delta");
        assertEq(burned, revDelta, "conservation: xPNTs burned == charge (rate 1:1)");
        assertEq(xUser0 - token.balanceOf(user), burned, "the user paid exactly the burn");
        assertEq(apnts.balanceOf(address(sp)), spA0, "aPNTs do not move during an op (internal accounting)");
        assertEq(apnts.totalSupply(), aSupply0, "no aPNTs minted or burned by an op");
        _assertBacked("op");
    }

    function test_SP_withdrawProtocolRevenue_after_ops() public {
        vm.startPrank(operator);
        apnts.approve(address(sp), type(uint256).max);
        sp.deposit(100_000 ether);
        vm.stopPrank();
        assertTrue(_runOp(0), "op 0");
        vm.warp(vm.getBlockTimestamp() + 61); // setOperatorLimits(60): per-user min interval
        assertTrue(_runOp(1), "op 1");
        uint256 rev = sp.protocolRevenue();
        assertGt(rev, 0.1 ether, "precondition: revenue above the 0.1 aPNTs buffer");
        uint256 amt = rev - 0.1 ether;

        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InsufficientRevenue.selector);
        sp.withdrawProtocolRevenue(treasury, amt + 1);

        uint256 t0 = apnts.balanceOf(treasury);
        vm.prank(owner);
        sp.withdrawProtocolRevenue(treasury, amt);
        assertEq(apnts.balanceOf(treasury) - t0, amt, "withdrawProtocolRevenue pays the treasury in APNTsCapped");
        assertEq(sp.protocolRevenue(), 0.1 ether, "buffer remains");
        _assertBacked("revenue");
    }
}
