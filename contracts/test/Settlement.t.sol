// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v4/Settlement.sol";
import "../src/interfaces/ISettlement.sol";
import "../src/SuperPaymasterRegistry_v1_2.sol";
import "../test/mocks/MockPNT.sol";

/**
 * @title SettlementTest
 * @notice Unit tests for Settlement contract
 */
contract SettlementTest is Test {
    Settlement public settlement;
    MockPNT public pnt;
    SuperPaymasterRegistry public registry;

    address public owner = address(0x1);
    address public paymaster1 = address(0x2);
    address public paymaster2 = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    address public treasury = address(0x6);

    uint256 constant THRESHOLD = 100 ether;
    uint256 constant GAS_FEE = 0.5 ether;

    event FeeRecorded(
        bytes32 indexed recordKey,
        address indexed paymaster,
        address indexed user,
        address token,
        uint256 amount,
        bytes32 userOpHash
    );

    event FeeSettled(
        bytes32 indexed recordKey,
        address indexed user,
        address indexed token,
        uint256 amount,
        bytes32 settlementHash
    );

    event BatchSettled(
        uint256 recordCount,
        uint256 totalAmount,
        bytes32 indexed settlementHash
    );

    function setUp() public {
        // Deploy mocks
        pnt = new MockPNT();

        // Deploy SuperPaymasterRegistry v1.2
        vm.prank(owner);
        registry = new SuperPaymasterRegistry(
            owner,           // owner
            treasury,        // treasury
            0.01 ether,      // minStakeAmount
            50,              // routerFeeRate (0.5%)
            500              // slashPercentage (5%)
        );

        // Deploy Settlement
        vm.prank(owner);
        settlement = new Settlement(owner, address(registry), THRESHOLD);

        // Register paymasters with stake
        vm.deal(paymaster1, 1 ether);
        vm.prank(paymaster1);
        registry.registerPaymaster{value: 0.01 ether}("Paymaster 1", 100);

        vm.deal(paymaster2, 1 ether);
        vm.prank(paymaster2);
        registry.registerPaymaster{value: 0.01 ether}("Paymaster 2", 150);

        // Mint tokens to users
        pnt.mint(user1, 1000 ether);
        pnt.mint(user2, 1000 ether);

        // Approve Settlement to spend user tokens
        vm.prank(user1);
        pnt.approve(address(settlement), type(uint256).max);
        vm.prank(user2);
        pnt.approve(address(settlement), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          RECORD GAS FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RecordGasFee_Success() public {
        bytes32 userOpHash = keccak256("userOp1");
        bytes32 expectedKey = keccak256(abi.encodePacked(paymaster1, userOpHash));

        vm.expectEmit(true, true, true, true);
        emit FeeRecorded(expectedKey, paymaster1, user1, address(pnt), GAS_FEE, userOpHash);

        vm.prank(paymaster1);
        bytes32 recordKey = settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash);

        assertEq(recordKey, expectedKey);

        // Verify record
        ISettlement.FeeRecord memory record = settlement.getFeeRecord(recordKey);
        assertEq(record.paymaster, paymaster1);
        assertEq(record.user, user1);
        assertEq(record.token, address(pnt));
        assertEq(record.amount, GAS_FEE);
        assertEq(uint256(record.status), uint256(ISettlement.FeeStatus.Pending));
        assertEq(record.userOpHash, userOpHash);
        // settlementHash field removed in gas optimization

        // Verify pending amounts
        assertEq(settlement.getPendingBalance(user1, address(pnt)), GAS_FEE);
        assertEq(settlement.getTotalPending(address(pnt)), GAS_FEE);

        // getUserRecordKeys removed in gas optimization - use off-chain indexing
    }

    function test_RecordGasFee_RevertIf_NotRegisteredPaymaster() public {
        address unregisteredPaymaster = address(0x999);
        bytes32 userOpHash = keccak256("userOp1");

        vm.prank(unregisteredPaymaster);
        vm.expectRevert("Settlement: paymaster not registered");
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash);
    }

    function test_RecordGasFee_RevertIf_DuplicateRecord() public {
        bytes32 userOpHash = keccak256("userOp1");

        // First record succeeds
        vm.prank(paymaster1);
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash);

        // Second record with same paymaster + userOpHash fails
        vm.prank(paymaster1);
        vm.expectRevert("Settlement: duplicate record");
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash);
    }

    function test_RecordGasFee_RevertIf_ZeroUser() public {
        bytes32 userOpHash = keccak256("userOp1");

        vm.prank(paymaster1);
        vm.expectRevert("Settlement: zero user");
        settlement.recordGasFee(address(0), address(pnt), GAS_FEE, userOpHash);
    }

    function test_RecordGasFee_RevertIf_ZeroToken() public {
        bytes32 userOpHash = keccak256("userOp1");

        vm.prank(paymaster1);
        vm.expectRevert("Settlement: zero token");
        settlement.recordGasFee(user1, address(0), GAS_FEE, userOpHash);
    }

    function test_RecordGasFee_RevertIf_ZeroAmount() public {
        bytes32 userOpHash = keccak256("userOp1");

        vm.prank(paymaster1);
        vm.expectRevert("Settlement: zero amount");
        settlement.recordGasFee(user1, address(pnt), 0, userOpHash);
    }

    function test_RecordGasFee_RevertIf_ZeroHash() public {
        vm.prank(paymaster1);
        vm.expectRevert("Settlement: zero hash");
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, bytes32(0));
    }

    function test_RecordGasFee_MultipleRecords() public {
        bytes32 userOpHash1 = keccak256("userOp1");
        bytes32 userOpHash2 = keccak256("userOp2");
        bytes32 userOpHash3 = keccak256("userOp3");

        // Record from paymaster1
        vm.prank(paymaster1);
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash1);

        vm.prank(paymaster1);
        settlement.recordGasFee(user1, address(pnt), GAS_FEE * 2, userOpHash2);

        // Record from paymaster2 (different paymaster, same userOpHash is OK)
        vm.prank(paymaster2);
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash1);

        // Verify totals
        assertEq(settlement.getPendingBalance(user1, address(pnt)), GAS_FEE * 4);
        assertEq(settlement.getTotalPending(address(pnt)), GAS_FEE * 4);

        // getUserRecordKeys removed in gas optimization - use off-chain indexing
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLE FEES TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SettleFees_Success() public {
        // Create records
        bytes32 userOpHash1 = keccak256("userOp1");
        bytes32 userOpHash2 = keccak256("userOp2");

        vm.prank(paymaster1);
        bytes32 key1 = settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash1);

        vm.prank(paymaster1);
        bytes32 key2 = settlement.recordGasFee(user1, address(pnt), GAS_FEE * 2, userOpHash2);

        // Settle
        bytes32 settlementHash = keccak256("settlement1");
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = key1;
        keys[1] = key2;

        vm.expectEmit(true, true, true, true);
        emit BatchSettled(2, GAS_FEE * 3, settlementHash);

        vm.prank(owner);
        settlement.settleFees(keys, settlementHash);

        // Verify records updated
        ISettlement.FeeRecord memory record1 = settlement.getFeeRecord(key1);
        assertEq(uint256(record1.status), uint256(ISettlement.FeeStatus.Settled));
        // settlementHash field removed in gas optimization

        ISettlement.FeeRecord memory record2 = settlement.getFeeRecord(key2);
        assertEq(uint256(record2.status), uint256(ISettlement.FeeStatus.Settled));
        // settlementHash field removed in gas optimization

        // Verify pending amounts cleared
        assertEq(settlement.getPendingBalance(user1, address(pnt)), 0);
        assertEq(settlement.getTotalPending(address(pnt)), 0);
    }

    function test_SettleFees_RevertIf_NotOwner() public {
        bytes32 userOpHash = keccak256("userOp1");

        vm.prank(paymaster1);
        bytes32 key = settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash);

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;

        vm.prank(user1);
        vm.expectRevert();
        settlement.settleFees(keys, bytes32(0));
    }

    function test_SettleFees_RevertIf_EmptyRecords() public {
        bytes32[] memory keys = new bytes32[](0);

        vm.prank(owner);
        vm.expectRevert("Settlement: empty records");
        settlement.settleFees(keys, bytes32(0));
    }

    function test_SettleFees_RevertIf_RecordNotFound() public {
        bytes32 fakeKey = keccak256("fake");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = fakeKey;

        vm.prank(owner);
        vm.expectRevert("Settlement: record not found");
        settlement.settleFees(keys, bytes32(0));
    }

    function test_SettleFees_RevertIf_NotPending() public {
        bytes32 userOpHash = keccak256("userOp1");

        vm.prank(paymaster1);
        bytes32 key = settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash);

        // Settle once
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;

        vm.prank(owner);
        settlement.settleFees(keys, bytes32(0));

        // Try to settle again
        vm.prank(owner);
        vm.expectRevert("Settlement: not pending");
        settlement.settleFees(keys, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLE FEES BY USERS TESTS
    //////////////////////////////////////////////////////////////*/

    // REMOVED: test_SettleFeesByUsers_* - Function deleted in gas optimization
    // Use settleFees() with off-chain indexed keys instead

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetRecordByUserOp() public {
        bytes32 userOpHash = keccak256("userOp1");

        vm.prank(paymaster1);
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, userOpHash);

        ISettlement.FeeRecord memory record = settlement.getRecordByUserOp(paymaster1, userOpHash);
        assertEq(record.paymaster, paymaster1);
        assertEq(record.user, user1);
        assertEq(record.amount, GAS_FEE);
    }

    // REMOVED: test_GetUserPendingRecords - Function deleted in gas optimization
    // Use getPendingBalance() + off-chain indexing instead

    function test_CalculateRecordKey() public {
        bytes32 userOpHash = keccak256("userOp1");
        bytes32 expectedKey = keccak256(abi.encodePacked(paymaster1, userOpHash));
        bytes32 calculatedKey = settlement.calculateRecordKey(paymaster1, userOpHash);
        assertEq(calculatedKey, expectedKey);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetSettlementThreshold() public {
        uint256 newThreshold = 200 ether;

        vm.prank(owner);
        settlement.setSettlementThreshold(newThreshold);

        assertEq(settlement.settlementThreshold(), newThreshold);
    }

    function test_Pause_Unpause() public {
        vm.prank(owner);
        settlement.pause();

        assertTrue(settlement.paused());

        // Recording should fail when paused
        vm.prank(paymaster1);
        vm.expectRevert("Settlement: paused");
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, keccak256("userOp1"));

        vm.prank(owner);
        settlement.unpause();

        assertFalse(settlement.paused());

        // Should work after unpause
        vm.prank(paymaster1);
        settlement.recordGasFee(user1, address(pnt), GAS_FEE, keccak256("userOp1"));
    }
}
