// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import {UUPSDeployHelper} from "../../../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../../../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../../../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";

import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

/// @notice Operator refund accounting, migrated to SP 5.5.0 (spec 03 §10.3, R10-M1b, R10-M3):
///         validation debits the FULL-maxCost reservation a0 from the operator and holds it in
///         flight; postOp books the charge as revenue and refunds (a0 - charge) to the operator
///         in full (no clamp against protocolRevenue). The user pays the charge in xPNTs v2.
contract SuperPaymasterRefundTest is Test {
    SuperPaymaster paymaster;
    Registry registry;
    MockERC20 aPNTs;
    xPNTsTokenV2 xPNTs;
    V2TokenDeployer.Stack stack;
    MockXPNTsFactory mockFactory;

    address owner = address(1);
    address operator = address(2);
    address user = address(3);
    address entryPoint = address(4); // Mock EP

    uint256 constant DEPOSIT = 1000000 ether;

    function setUp() public {
        vm.startPrank(owner);
        aPNTs = new MockERC20("aPNTs", "APNT", 18);

        // Mock Registry/PriceFeed
        MockPriceFeed priceFeed = new MockPriceFeed();
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0x1), address(0x2));

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(IEntryPoint(entryPoint), IRegistry(address(registry)), address(priceFeed), owner, address(aPNTs), owner, 3600);

        // Setup Protocol Fee 10%
        paymaster.setProtocolFee(1000);

        // Mock Roles using cheatcodes
        vm.mockCall(
            address(registry),
            abi.encodeWithSignature("hasRole(bytes32,address)"),
            abi.encode(true)
        );
         vm.mockCall(
            address(registry),
            abi.encodeWithSignature("getCreditLimit(address)"),
            abi.encode(1000000 ether) // High limit
        );

        // Deploy mock factory and register operator token (must be called as owner)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        vm.stopPrank();

        // Operator's community token: xPNTs v2, rate 1:1
        stack = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xPNTs = V2TokenDeployer.newToken(stack, operator, operator, address(paymaster), 1e18);
        mockFactory.setToken(operator, address(xPNTs));
        IxPNTsV2Admin(address(xPNTs)).mint(user, 10000 ether);

        // Setup Operator
        vm.startPrank(operator);
        aPNTs.mint(operator, DEPOSIT); // 1M tokens
        aPNTs.approve(address(paymaster), DEPOSIT);
        paymaster.configureOperator(address(xPNTs), operator); // 1:1 Rate
        paymaster.deposit(DEPOSIT);

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();
        vm.stopPrank();

        // Sync SBT Status for user (Separate prank)
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);
    }

    function testRefundLogic() public {
        // Price: $2000 ETH, $0.02 aPNTs -> 1 ETH = 100,000 aPNTs.
        // maxCost 0.03 ETH ($60) -> 3,000 aPNTs; a0 = 3,000 * (1 + 10% fee + 10% buffer) = 3,600.
        // (The pre-5.5.0 0.5 ETH maxCost reserves 60,000 aPNTs, beyond the v2 token's 5,000
        //  single-tx / default SP allowance caps, so it would now be — correctly — rejected.)
        uint256 maxCost = 0.03 ether;
        uint256 actualCost = 0.01 ether; // $20 -> 1,000 aPNTs

        // 1. Validate (Pre-Charge Max)
        PackedUserOperation memory userOp = _mockUserOp();
        bytes32 opHash = keccak256("op");

        vm.prank(entryPoint);
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, opHash, maxCost);

        assertEq(uint160(validationData), 0, "Validation should pass");
        assertTrue(context.length > 0, "Context should be returned");
        uint256 a0 = abi.decode(context, (SuperPaymaster.OpCtx)).a0;
        assertEq(a0, 3600 ether, "a0 = full maxCost + fee + validation buffer");

        // Operator balance decreased by the full reservation; nothing is revenue yet.
        (uint128 balanceAfterValidate,,,,,,,,) = paymaster.operators(operator);
        assertEq(uint256(balanceAfterValidate), DEPOSIT - a0, "pre-charge = a0");
        assertEq(paymaster.protocolRevenue(), 0, "a0 in flight, not revenue");

        // 2. PostOp (Refund). actualUserOpFeePerGas = 0 -> no gas buffer term.
        uint256 userBefore = xPNTs.balanceOf(user);
        vm.prank(entryPoint);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 0);

        (uint128 balanceFinal,,,,,,,,) = paymaster.operators(operator);
        uint256 revenue = paymaster.protocolRevenue();

        // Expected: actual 0.01 ETH = 1,000 aPNTs; +10% fee = 1,100 aPNTs charge.
        uint256 expectedCharge = 1100 ether;
        assertEq(revenue, expectedCharge, "revenue == charge");
        assertEq(uint256(balanceFinal), DEPOSIT - expectedCharge, "operator refunded a0 - charge in full");
        assertEq(userBefore - xPNTs.balanceOf(user), expectedCharge, "user burned the charge (rate 1:1)");
        assertEq(xPNTs.lockedOf(user), 0, "escrow released");
        (address f, uint256 inflight) = paymaster.inflightOf(opHash);
        assertEq(f, address(0));
        assertEq(inflight, 0, "nothing left in flight");
    }

    function _mockUserOp() internal view returns (PackedUserOperation memory op) {
        op.sender = user;
        op.paymasterAndData = V2TokenDeployer.pmd(address(paymaster), 0, 200000, operator, type(uint256).max, address(xPNTs), 0);
    }
}

/// @dev Plain ERC20 used as the aPNTs deposit token (the 3.x debt hooks are gone in 5.5.0).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1); // $2000
    }
    function decimals() external pure returns (uint8) { return 8; }
}
