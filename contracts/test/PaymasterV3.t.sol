// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/paymasters/v3/PaymasterV3.sol";
import "../test/mocks/MockSBT.sol";
import "../test/mocks/MockPNT.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

contract PaymasterV3Test is Test {
    PaymasterV3 public paymaster;
    MockSBT public sbt;
    MockPNT public pnt;
    MockEntryPoint public mockEntryPoint;
    MockSettlement public mockSettlement;
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    uint256 public constant MIN_TOKEN_BALANCE = 1e18;
    uint256 public constant INITIAL_BALANCE = 100e18;

    event GasSponsored(address indexed user, uint256 amount, address indexed token);
    event GasRecorded(address indexed user, uint256 amount, address indexed token);
    event SBTContractUpdated(address indexed oldSBT, address indexed newSBT);
    event GasTokenUpdated(address indexed oldToken, address indexed newToken);
    event SettlementContractUpdated(address indexed oldSettlement, address indexed newSettlement);
    event MinTokenBalanceUpdated(uint256 oldBalance, uint256 newBalance);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    function setUp() public {
        mockEntryPoint = new MockEntryPoint();
        mockSettlement = new MockSettlement();
        sbt = new MockSBT();
        pnt = new MockPNT();

        paymaster = new PaymasterV3(
            address(mockEntryPoint), owner, address(sbt), address(pnt), address(mockSettlement), MIN_TOKEN_BALANCE
        );

        sbt.safeMint(user1);
        pnt.mint(user1, INITIAL_BALANCE);
    }

    // ============ Constructor Tests ============
    function test_Constructor_RevertIf_ZeroEntryPoint() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        new PaymasterV3(address(0), owner, address(sbt), address(pnt), address(mockSettlement), MIN_TOKEN_BALANCE);
    }

    function test_Constructor_RevertIf_ZeroOwner() public {
        vm.expectRevert(); // OwnableInvalidOwner from OpenZeppelin
        new PaymasterV3(address(mockEntryPoint), address(0), address(sbt), address(pnt), address(mockSettlement), MIN_TOKEN_BALANCE);
    }

    function test_Constructor_RevertIf_ZeroSBT() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        new PaymasterV3(address(mockEntryPoint), owner, address(0), address(pnt), address(mockSettlement), MIN_TOKEN_BALANCE);
    }

    function test_Constructor_RevertIf_ZeroGasToken() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        new PaymasterV3(address(mockEntryPoint), owner, address(sbt), address(0), address(mockSettlement), MIN_TOKEN_BALANCE);
    }

    function test_Constructor_RevertIf_ZeroSettlement() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        new PaymasterV3(address(mockEntryPoint), owner, address(sbt), address(pnt), address(0), MIN_TOKEN_BALANCE);
    }

    function test_Constructor_RevertIf_ZeroMinBalance() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__InvalidTokenBalance.selector);
        new PaymasterV3(address(mockEntryPoint), owner, address(sbt), address(pnt), address(mockSettlement), 0);
    }

    // ============ Validation Tests ============
    function test_ValidatePaymasterUserOp_Success() public {
        PackedUserOperation memory userOp = _createUserOp(user1);
        bytes32 userOpHash = keccak256("test");
        uint256 maxCost = 1 ether;

        vm.expectEmit(true, false, false, true);
        emit GasSponsored(user1, maxCost, address(pnt));

        vm.prank(address(mockEntryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, userOpHash, maxCost);

        assertEq(validationData, 0);
        (address decodedUser, uint256 decodedMaxCost, bytes32 decodedHash) = abi.decode(context, (address, uint256, bytes32));
        assertEq(decodedUser, user1);
        assertEq(decodedMaxCost, maxCost);
        assertEq(decodedHash, userOpHash);
    }

    function test_ValidatePaymasterUserOp_RevertIf_NoSBT() public {
        address userNoSBT = address(0x999);
        pnt.mint(userNoSBT, INITIAL_BALANCE);
        PackedUserOperation memory userOp = _createUserOp(userNoSBT);

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(PaymasterV3.PaymasterV3__NoSBT.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_ValidatePaymasterUserOp_RevertIf_InsufficientPNT() public {
        address userLowBalance = address(0x888);
        sbt.safeMint(userLowBalance);
        pnt.mint(userLowBalance, MIN_TOKEN_BALANCE - 1);

        PackedUserOperation memory userOp = _createUserOp(userLowBalance);
        vm.prank(address(mockEntryPoint));
        vm.expectRevert(PaymasterV3.PaymasterV3__InsufficientPNT.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_ValidatePaymasterUserOp_RevertIf_NotEntryPoint() public {
        PackedUserOperation memory userOp = _createUserOp(user1);
        vm.prank(user1);
        vm.expectRevert(PaymasterV3.PaymasterV3__OnlyEntryPoint.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_ValidatePaymasterUserOp_RevertIf_Paused() public {
        paymaster.pause();
        PackedUserOperation memory userOp = _createUserOp(user1);
        vm.prank(address(mockEntryPoint));
        vm.expectRevert(PaymasterV3.PaymasterV3__Paused.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_ValidatePaymasterUserOp_RevertIf_InvalidPaymasterData() public {
        PackedUserOperation memory userOp = _createUserOp(user1);
        userOp.paymasterAndData = abi.encodePacked(address(0)); // Too short

        vm.prank(address(mockEntryPoint));
        vm.expectRevert(PaymasterV3.PaymasterV3__InvalidPaymasterData.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    // ============ PostOp Tests ============
    function test_PostOp_CallsSettlement() public {
        uint256 actualGasCost = 0.001 ether;
        bytes32 userOpHash = keccak256("test-userop");
        bytes memory context = abi.encode(user1, 1 ether, userOpHash);

        vm.expectEmit(true, false, false, true);
        emit GasRecorded(user1, actualGasCost, address(pnt));

        vm.prank(address(mockEntryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, context, actualGasCost, 1 gwei);

        // Verify Settlement receives gasGwei (wei / 1e9)
        MockSettlement settlement = mockSettlement;
        assertEq(settlement.lastUser(), user1);
        assertEq(settlement.lastAmount(), actualGasCost / 1e9); // Expect Gwei, not wei
    }

    function test_PostOp_RevertIf_NotEntryPoint() public {
        bytes memory context = abi.encode(user1, 0, bytes32(0));
        vm.prank(user1);
        vm.expectRevert(PaymasterV3.PaymasterV3__OnlyEntryPoint.selector);
        paymaster.postOp(PostOpMode.opSucceeded, context, 0, 0);
    }

    // ============ Admin Function Tests ============
    function test_SetSBTContract() public {
        MockSBT newSBT = new MockSBT();

        vm.expectEmit(true, true, false, false);
        emit SBTContractUpdated(address(sbt), address(newSBT));

        paymaster.setSBTContract(address(newSBT));
        assertEq(paymaster.sbtContract(), address(newSBT));
    }

    function test_SetSBTContract_RevertIf_ZeroAddress() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        paymaster.setSBTContract(address(0));
    }

    function test_SetGasToken() public {
        MockPNT newToken = new MockPNT();

        vm.expectEmit(true, true, false, false);
        emit GasTokenUpdated(address(pnt), address(newToken));

        paymaster.setGasToken(address(newToken));
        assertEq(paymaster.gasToken(), address(newToken));
    }

    function test_SetGasToken_RevertIf_ZeroAddress() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        paymaster.setGasToken(address(0));
    }

    function test_SetSettlementContract() public {
        address newSettlement = address(new MockSettlement());

        vm.expectEmit(true, true, false, false);
        emit SettlementContractUpdated(address(mockSettlement), newSettlement);

        paymaster.setSettlementContract(newSettlement);
        assertEq(paymaster.settlementContract(), newSettlement);
    }

    function test_SetSettlementContract_RevertIf_ZeroAddress() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        paymaster.setSettlementContract(address(0));
    }

    function test_SetMinTokenBalance() public {
        uint256 newBalance = 10e18;

        vm.expectEmit(false, false, false, true);
        emit MinTokenBalanceUpdated(MIN_TOKEN_BALANCE, newBalance);

        paymaster.setMinTokenBalance(newBalance);
        assertEq(paymaster.minTokenBalance(), newBalance);
    }

    function test_SetMinTokenBalance_RevertIf_Zero() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__InvalidTokenBalance.selector);
        paymaster.setMinTokenBalance(0);
    }

    function test_Pause() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);

        paymaster.pause();
        assertTrue(paymaster.paused());
    }

    function test_Unpause() public {
        paymaster.pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);

        paymaster.unpause();
        assertFalse(paymaster.paused());
    }

    function test_WithdrawETH() public {
        vm.deal(address(paymaster), 10 ether);
        uint256 balanceBefore = user2.balance;

        paymaster.withdrawETH(payable(user2), 5 ether);
        assertEq(user2.balance, balanceBefore + 5 ether);
    }

    function test_WithdrawETH_RevertIf_ZeroAddress() public {
        vm.deal(address(paymaster), 10 ether);
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        paymaster.withdrawETH(payable(address(0)), 1 ether);
    }

    function test_AddStake() public {
        MockEntryPoint ep = mockEntryPoint;
        vm.deal(address(this), 10 ether);

        paymaster.addStake{value: 1 ether}(86400);
        assertEq(ep.deposits(address(paymaster)), 1 ether);
    }

    function test_UnlockStake() public {
        vm.deal(address(this), 10 ether);
        paymaster.addStake{value: 1 ether}(86400);

        paymaster.unlockStake();
        MockEntryPoint ep = mockEntryPoint;
        assertTrue(ep.unlocked(address(paymaster)));
    }

    function test_WithdrawStake() public {
        vm.deal(address(this), 10 ether);
        paymaster.addStake{value: 1 ether}(86400);
        paymaster.unlockStake();

        uint256 balanceBefore = user2.balance;
        paymaster.withdrawStake(payable(user2));
        assertEq(user2.balance, balanceBefore + 1 ether);
    }

    // ============ View Function Tests ============
    function test_IsUserQualified_Success() public {
        (bool qualified, uint8 reason) = paymaster.isUserQualified(user1);
        assertTrue(qualified);
        assertEq(reason, 0);
    }

    function test_IsUserQualified_NoSBT() public {
        address userNoSBT = address(0x777);
        pnt.mint(userNoSBT, INITIAL_BALANCE);

        (bool qualified, uint8 reason) = paymaster.isUserQualified(userNoSBT);
        assertFalse(qualified);
        assertEq(reason, 1);
    }

    function test_IsUserQualified_InsufficientPNT() public {
        address userLowBalance = address(0x666);
        sbt.safeMint(userLowBalance);
        pnt.mint(userLowBalance, MIN_TOKEN_BALANCE - 1);

        (bool qualified, uint8 reason) = paymaster.isUserQualified(userLowBalance);
        assertFalse(qualified);
        assertEq(reason, 2);
    }

    function test_GetConfig() public view {
        (address _sbt, address _token, address _settlement, uint256 _minBalance, bool _paused) = paymaster.getConfig();
        assertEq(_sbt, address(sbt));
        assertEq(_token, address(pnt));
        assertEq(_settlement, address(mockSettlement));
        assertEq(_minBalance, MIN_TOKEN_BALANCE);
        assertFalse(_paused);
    }

    function test_ReceiveETH() public {
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        (bool success,) = address(paymaster).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(paymaster).balance, 1 ether);
    }

    // ============ Helper Functions ============
    function _createUserOp(address sender) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: abi.encodePacked(address(0), uint128(100000), uint128(100000)),
            signature: ""
        });
    }
}

contract MockEntryPoint {
    mapping(address => uint256) public deposits;
    mapping(address => bool) public unlocked;

    function getUserOpHash(PackedUserOperation calldata userOp) external pure returns (bytes32) {
        return keccak256(abi.encode(userOp.sender, userOp.nonce));
    }

    function addStake(uint32) external payable {
        deposits[msg.sender] += msg.value;
    }

    function unlockStake() external {
        unlocked[msg.sender] = true;
    }

    function withdrawStake(address payable withdrawAddress) external {
        uint256 amount = deposits[msg.sender];
        deposits[msg.sender] = 0;
        (bool success,) = withdrawAddress.call{value: amount}("");
        require(success);
    }

    receive() external payable {}
}

contract MockSettlement {
    address public lastUser;
    uint256 public lastAmount;

    function recordGasFee(address user, address, uint256 amount, bytes32) external returns (bytes32) {
        lastUser = user;
        lastAmount = amount;
        return keccak256(abi.encodePacked(msg.sender, block.timestamp));
    }
}
