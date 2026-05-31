// PoC_C04 — postOpReverted accounting
// VULNERABILITY: postOpReverted returns without restoring the optimistic operator debit or protocolRevenue credit.
// TEST PASSES = vulnerability exists on current code
// TEST SHOULD FAIL/REVERT after fix
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/tokens/xPNTsToken.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

contract C04Registry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function setRole(bytes32 role, address account, bool value) external {
        roles[role][account] = value;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function getCreditLimit(address) external pure returns (uint256) {
        return 1_000_000 ether;
    }
}

contract C04EntryPoint {}

contract C04PriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract C04APNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoC_C04_PostOpReverted_Test is Test {
    using Clones for address;

    SuperPaymaster public paymaster;
    C04Registry public registry;
    C04APNTs public apnts;
    xPNTsToken public xpnts;

    address public owner = address(0xC0401);
    address public treasury = address(0xC0402);
    address public operator = address(0xC0403);
    address public user = address(0xC0404);

    bytes32 public constant C04_ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant C04_ROLE_COMMUNITY = keccak256("COMMUNITY");
    uint256 public constant MAX_COST = 1_000;

    function setUp() public {
        vm.startPrank(owner);

        registry = new C04Registry();
        C04EntryPoint entryPoint = new C04EntryPoint();
        C04PriceFeed priceFeed = new C04PriceFeed();
        apnts = new C04APNTs();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        address xImpl = address(new xPNTsToken());
        xpnts = xPNTsToken(xImpl.clone());
        xpnts.initialize("Community Points", "xPNT", owner, "Community", "community.eth", 1e18);
        xpnts.setSuperPaymasterAddress(address(paymaster));

        MockXPNTsFactory mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator, address(xpnts));

        registry.setRole(C04_ROLE_PAYMASTER_SUPER, operator, true);
        registry.setRole(C04_ROLE_COMMUNITY, operator, true);
        apnts.mint(operator, 10_000 ether);

        vm.stopPrank();

        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);

        vm.startPrank(operator);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), treasury);
        paymaster.deposit(1_000 ether);
        vm.stopPrank();
    }

    function test_PoC_postOpRevertedLeavesOptimisticDebitAndRevenue() public {
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint256(MAX_COST), operator, type(uint256).max);

        uint128 operatorBefore = _operatorBalance();
        uint256 revenueBefore = paymaster.protocolRevenue();

        vm.prank(address(paymaster.entryPoint()));
        (bytes memory context, uint256 validationData) =
            paymaster.validatePaymasterUserOp(op, bytes32(uint256(0xC04)), MAX_COST);
        assertEq(uint160(validationData), 0, "validate must pass");

        (,, uint256 initialAPNTs,,) = abi.decode(context, (address, address, uint256, bytes32, address));
        uint128 operatorAfterValidate = _operatorBalance();
        assertEq(operatorBefore - operatorAfterValidate, initialAPNTs, "validate optimistically deducts operator");

        vm.prank(address(paymaster.entryPoint()));
        paymaster.postOp(IPaymaster.PostOpMode.postOpReverted, context, MAX_COST, 0);

        assertEq(_operatorBalance(), operatorAfterValidate, "operator debit was not restored");
        assertEq(paymaster.protocolRevenue() - revenueBefore, initialAPNTs, "protocolRevenue still contains full initialAPNTs");
        assertEq(xpnts.getDebt(user), 0, "postOpReverted records no debt");
        assertEq(xpnts.balanceOf(user), 0, "postOpReverted burns no xPNTs");
    }

    function _operatorBalance() internal view returns (uint128 balance) {
        (balance,,,,,,,,) = paymaster.operators(operator);
    }
}
