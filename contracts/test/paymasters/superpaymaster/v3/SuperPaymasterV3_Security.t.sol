// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "../../../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../../../src/interfaces/v3/IRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {UUPSDeployHelper} from "../../../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../../../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../../../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "../../../../src/tokens/v2/xPNTsTokenV2.sol";


// --- Mocks ---

contract MockRegistrySec {
    mapping(bytes32 => mapping(address => bool)) public roles;


    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
    
    // Allow test to grant roles
    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    mapping(address => uint256) public creditLimits;
    function setCreditLimit(address u, uint256 l) external { creditLimits[u] = l; }
    function getCreditLimit(address u) external view returns (uint256) { return creditLimits[u]; }
}

contract MockEntryPointSec {
    function balanceOf(address) external view returns (uint256) { return 0; }
    function depositTo(address) external payable {}
}

contract MockERC20Sec is ERC20 {
    constructor() ERC20("Mock", "MCK") {
        _mint(msg.sender, 10000 ether);
    }

    // 5.5.0: used only as the aPNTs deposit token; the 3.x debt hooks (recordDebt*,
    // burnFromWithOpHash, getDebt) no longer exist on the SP <-> token surface.
}

contract MockAggregatorV3Sec {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) {
        return 8;
    }
}

// --- Test Suite ---

contract SuperPaymaster_SecurityTest is Test {
    SuperPaymaster paymaster;
    MockRegistrySec registry;
    MockEntryPointSec entryPoint;
    MockERC20Sec token;          // aPNTs deposit token
    xPNTsTokenV2 xtok;           // operator's community gas token (xPNTs v2)
    V2TokenDeployer.Stack stack;
    MockAggregatorV3Sec oracle;
    MockXPNTsFactory mockFactory;

    address owner = address(1);
    address operator; // Changed to be derived from operatorKey
    address user = address(3);
    address treasury = address(4);

    uint256 operatorKey = 0x12345;

    function setUp() public {
        vm.warp(1700000000); // 2023ish, avoids underflow

        registry = new MockRegistrySec();
        entryPoint = new MockEntryPointSec();

        token = new MockERC20Sec();
        oracle = new MockAggregatorV3Sec();

        operator = vm.addr(operatorKey);

        // 1. Deploy Paymaster (UUPS Proxy)
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(oracle),
            owner,
            address(token), // aPNTs
            treasury,
            3600
        );

        // Update Price Cache
        paymaster.updatePrice();

        // 3. Grant roles
        registry.grantRole(keccak256("PAYMASTER_SUPER"), operator);
        registry.grantRole(keccak256("COMMUNITY"), operator);

        // 4. Configure Operator (Deposit & Setup)
        token.transfer(operator, 100 ether);

        vm.prank(owner);
        paymaster.setAPNTsToken(address(token));

        // Deploy mock factory (P1-4 factory binding, must be owner)
        vm.startPrank(owner);
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        vm.stopPrank();

        // 5.5.0: the operator's community token must be xPNTs v2.
        stack = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xtok = V2TokenDeployer.newToken(stack, operator, operator, address(paymaster), 1e18);
        mockFactory.setToken(operator, address(xtok));
        IxPNTsV2Admin(address(xtok)).mint(user, 1000 ether);

        vm.startPrank(operator);
        token.approve(address(paymaster), 100 ether);
        paymaster.deposit(100 ether);
        paymaster.configureOperator(address(xtok), treasury);
        vm.stopPrank();

        // Sync SBT Status for user (Must be called by Registry)
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);

        // 5. User credit tier (unused by balance-mode ops; credit policy defaults OFF)
        registry.setCreditLimit(user, 1000 ether);
    }

    function testSetOperatorLimits() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60); // 1 minute interval

        // Verify storage (Tuple unpacking based on latest V3 structure)
        (,,,,, uint48 minTx,,,) = paymaster.operators(operator);
        assertEq(minTx, 60);
    }

    function testRateLimiting_DenySameBlock() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60);

        PackedUserOperation memory userOp = _createSafeUserOp(user, operatorKey);

        // Tx 1: Time T
        vm.warp(1700001000);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, keccak256("op1"), 100000);
        assertEq(uint160(valData), 0, "First tx valid");

        // Simulate PostOp to update state
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 100000, 100000);

        // Tx 2: Time T (Same Block) - Should Fail (validAfter > timestamp)
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(userOp, keccak256("op2"), 100000);

        // validationData: authorizer [0..159] | validUntil [160..207] | validAfter [208..255]
        uint48 validAfter = uint48(valData >> 208);

        assertGt(validAfter, block.timestamp, "Second tx in same block should be deferred");
    }

    function testRateLimiting_RevertTooSoon() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60);

        PackedUserOperation memory userOp = _createSafeUserOp(user, operatorKey);

        // Tx 1: Time 1000
        vm.warp(1700001000);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd1) = paymaster.validatePaymasterUserOp(userOp, keccak256("op1"), 100000);
        assertEq(uint160(vd1), 0, "First tx valid");

        // Simulate PostOp
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 100000, 100000);

        // Tx 2: Time 1030 (Delta 30 < 60) - Should return validAfter
        vm.warp(1700001030);
        vm.prank(address(entryPoint));
        (, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, keccak256("op2"), 100000);

        uint48 validAfter = uint48(valData >> 208);
        assertGt(validAfter, block.timestamp, "Tx too soon should have future validAfter");
    }

    function testRateLimiting_AllowAfterInterval() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60);

        PackedUserOperation memory userOp = _createSafeUserOp(user, operatorKey);

        // Tx 1: Time 1000
        vm.warp(1700001000);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd1) = paymaster.validatePaymasterUserOp(userOp, keccak256("op1"), 100000);
        assertEq(uint160(vd1), 0, "First tx valid");

        // Simulate PostOp
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 100000, 100000);

        // Tx 2: Time 1061 (Delta 61 > 60) - Pass
        vm.warp(1700001061);
        vm.prank(address(entryPoint));
        (, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, keccak256("op2"), 100000);

        uint48 validAfter = uint48(valData >> 208);
        assertLe(validAfter, block.timestamp, "Tx after interval should be valid immediately");
        assertEq(uint160(valData), 0, "Tx after interval should have valid sig");
    }

    /// @notice A user whose EXECUTION reverted still consumes the rate limit and still pays for
    ///         gas (T-R14-04). Pre-5.5.0 this used PostOpMode.postOpReverted, which EntryPoint
    ///         v0.7 never passes to postOp; opReverted is the mode for a reverted user execution.
    ///         SP 5.5.0 settles identically in both modes.
    function testRateLimiting_UpdatesOnRevert() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60);

        PackedUserOperation memory userOp = _createSafeUserOp(user, operatorKey);

        // Tx 1: Time 1000
        vm.warp(1700001000);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd1) = paymaster.validatePaymasterUserOp(userOp, keccak256("op1"), 100000);
        assertEq(uint160(vd1), 0, "First tx valid");
        uint256 balBefore = xtok.balanceOf(user);

        // Simulate postOp for a reverted user execution
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opReverted, ctx, 100000, 100000);
        assertLt(xtok.balanceOf(user), balBefore, "T-R14-04: reverted execution still pays (xc burned)");
        assertEq(xtok.lockedOf(user), 0, "T-R14-04: escrow cleared");

        // Tx 2: Time 1030 (Delta 30 < 60) - Should return validAfter
        // If timestamp was NOT updated, this would PASS (validAfter=0).
        // Since it IS updated, it should FAIL (validAfter > timestamp).
        vm.warp(1700001030);
        vm.prank(address(entryPoint));
        (, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, keccak256("op2"), 100000);

        uint48 validAfter = uint48(valData >> 208);
        assertGt(validAfter, block.timestamp, "Reverted tx should still consume rate limit");
    }

    function testUpdateBlockedStatus() public {
        address[] memory users = new address[](1);
        users[0] = user;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        // Must be called by Registry
        vm.prank(address(registry));
        paymaster.updateBlockedStatus(operator, users, statuses);

        (, bool isBlocked) = paymaster.userOpState(operator, user);
        assertTrue(isBlocked);
    }

    function testBlocklist_DenyUser() public {
        PackedUserOperation memory userOp = _createSafeUserOp(user, operatorKey);

        // Positive control: the same op validates while the user is NOT blocked, so the
        // rejection below is attributable to the blocklist (not to a malformed op).
        vm.prank(address(entryPoint));
        (, uint256 okData) = paymaster.validatePaymasterUserOp(userOp, keccak256("pre-block"), 100000);
        assertEq(uint160(okData), 0, "control: unblocked user validates");

        // Block user
        vm.prank(address(registry));
        address[] memory users = new address[](1);
        users[0] = user;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        paymaster.updateBlockedStatus(operator, users, statuses);

        uint256 lockedBefore = xtok.lockedOf(user);
        vm.prank(address(entryPoint));
        (, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, keccak256("post-block"), 100000);
        assertTrue(uint160(valData) != 0, "Blocked user should be rejected");
        assertEq(xtok.lockedOf(user), lockedBefore, "rejected op locks nothing");
    }



    // --- Helper ---
    function _createSafeUserOp(address sender, uint256 signerKey) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = 0;
        op.initCode = "";
        op.callData = "";
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(100000), uint128(100000)));
        op.preVerificationGas = 50000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));

        address opAddr = vm.addr(signerKey);

        // 5.5.0 layout: [PM 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
        op.paymasterAndData = V2TokenDeployer.pmd(
            address(paymaster), uint128(0), uint128(200000), opAddr, type(uint256).max, address(xtok), 0
        );

        // No Signature
        op.signature = "0x";
    }
}
