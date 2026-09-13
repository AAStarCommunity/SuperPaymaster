// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { V55Registry, V55PriceFeed, V55APNTs, IV2Ext } from "../helpers/V55TestFixtures.sol";

/**
 * @title SuperPaymasterV55GasDeltaTest — exp/params measurement probe
 * @notice Gas of one validatePaymasterUserOp and one postOp (BALANCE, first-time user, cold
 *         rate-limit write), called from the EntryPoint address in one transaction through the
 *         proxy. Deliberately independent of the exp/params ABI so the SAME file measures the
 *         constant-based build (exp/buffer) and the storage-parameter build (exp/params).
 */
contract SuperPaymasterV55GasDeltaTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    SuperPaymaster sp;
    xPNTsTokenV2 token;
    V55Registry registry;
    address owner = address(0x0A11);
    address operator = address(0x0BE);
    address user = address(0xA11CE);

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(EP), IRegistry(address(registry)), address(new V55PriceFeed()), owner, address(apnts), owner, 3600
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
        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();
        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), owner);
        sp.deposit(100_000 ether);
        sp.setOperatorLimits(60);
        IV2Ext(address(token)).mint(user, 10_000 ether);
        vm.stopPrank();
        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);
    }

    function test_report_validation_and_postOp_gas() public {
        PackedUserOperation memory op;
        op.sender = user;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(700_000), uint128(200_000), operator, type(uint256).max, address(token), uint8(0)
        );
        bytes memory vcd = abi.encodeCall(IPaymaster.validatePaymasterUserOp, (op, keccak256("delta"), 1e16));
        vm.prank(EP);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = address(sp).call(vcd);
        uint256 gValidate = g0 - gasleft();
        require(ok, "validate");
        (bytes memory ctx, uint256 vd) = abi.decode(ret, (bytes, uint256));
        require(vd & 1 == 0, "validated");
        bytes memory pcd = abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei));
        vm.prank(EP);
        g0 = gasleft();
        (ok, ) = address(sp).call{gas: 1_000_000}(pcd);
        uint256 gPostOp = g0 - gasleft();
        require(ok, "postOp");
        console.log("validatePaymasterUserOp gas (first-time user, cold SP slots)", gValidate);
        console.log("postOp gas (same tx, BALANCE, cold lastTimestamp)", gPostOp);
        console.log("SP version", sp.version());
    }
}
