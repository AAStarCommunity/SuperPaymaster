// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/paymasters/v3/PaymasterV3.sol";
import "../test/mocks/MockSBT.sol";
import "../test/mocks/MockPNT.sol";

import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

/// @title PaymasterV3 Test Suite
/// @notice Comprehensive tests for PaymasterV3 contract (isolated from Settlement to avoid version conflicts)
contract PaymasterV3Test is Test {
    PaymasterV3 public paymaster;
    MockSBT public sbt;
    MockPNT public pnt;
    
    // Mock contracts
    address public mockEntryPoint;
    address public mockSettlement;
    
    // Test accounts
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    // Constants
    uint256 public constant MIN_TOKEN_BALANCE = 1e18; // 1 PNT
    uint256 public constant INITIAL_BALANCE = 100e18; // 100 PNT
    
    event GasRecorded(
        address indexed user,
        address indexed token,
        uint256 amount,
        bytes32 indexed recordKey
    );
    
    function setUp() public {
        // Deploy mock contracts
        mockEntryPoint = address(new MockEntryPoint());
        mockSettlement = address(new MockSettlement());
        
        // Deploy core contracts
        sbt = new MockSBT();
        pnt = new MockPNT();
        
        // Deploy PaymasterV3 (6 params: entryPoint, owner, sbtContract, gasToken, settlement, minBalance)
        paymaster = new PaymasterV3(
            mockEntryPoint,
            owner,
            address(sbt),
            address(pnt),
            mockSettlement,
            MIN_TOKEN_BALANCE
        );
        
        // Setup: Mint SBT and PNT to users (use safeMint with auto-increment)
        sbt.safeMint(user1);
        sbt.safeMint(user2);
        pnt.mint(user1, INITIAL_BALANCE);
        pnt.mint(user2, INITIAL_BALANCE);
    }
    
    /*//////////////////////////////////////////////////////////////
                        VALIDATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_ValidatePaymasterUserOp_Success() public {
        // Setup user with SBT and PNT
        PackedUserOperation memory userOp = _createUserOp(user1);
        
        // Simulate EntryPoint calling validatePaymasterUserOp
        vm.prank(mockEntryPoint);
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0
        );
        
        // Verify
        assertEq(validationData, 0, "Should return valid");
        assertGt(context.length, 0, "Should return context");
    }
    
    function test_ValidatePaymasterUserOp_RevertIf_NoSBT() public {
        // Create user without SBT
        address userNoSBT = address(0x999);
        pnt.mint(userNoSBT, INITIAL_BALANCE);
        
        PackedUserOperation memory userOp = _createUserOp(userNoSBT);
        
        // Should revert
        vm.prank(mockEntryPoint);
        vm.expectRevert(PaymasterV3.PaymasterV3__NoSBT.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }
    
    function test_ValidatePaymasterUserOp_RevertIf_InsufficientPNT() public {
        // Create user with SBT but insufficient PNT
        address userNoPNT = address(0x888);
        sbt.safeMint(userNoPNT);
        // No PNT minted
        
        PackedUserOperation memory userOp = _createUserOp(userNoPNT);
        
        // Should revert
        vm.prank(mockEntryPoint);
        vm.expectRevert(PaymasterV3.PaymasterV3__InsufficientPNT.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }
    
    function test_ValidatePaymasterUserOp_RevertIf_NotEntryPoint() public {
        PackedUserOperation memory userOp = _createUserOp(user1);
        
        // Should revert when not called by EntryPoint
        vm.prank(user1);
        vm.expectRevert(); // onlyEntryPoint modifier
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                        POST-OP TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_PostOp_CallsSettlement() public {
        // Setup
        uint256 actualGasCost = 0.001 ether;
        bytes32 userOpHash = keccak256("test-userop");
        
        // Create context
        bytes memory context = abi.encode(user1, address(pnt), userOpHash);
        
        // Expected recordKey
        bytes32 expectedKey = keccak256(abi.encodePacked(address(paymaster), userOpHash));
        
        // Expect event from PaymasterV3
        vm.expectEmit(true, true, true, true);
        emit GasRecorded(user1, address(pnt), actualGasCost, expectedKey);
        
        // Execute postOp
        vm.prank(mockEntryPoint);
        paymaster.postOp(
            PostOpMode.opSucceeded,
            context,
            actualGasCost,
            0 // gasPriceUserOp (not used)
        );
        
        // Verify MockSettlement was called
        MockSettlement settlement = MockSettlement(mockSettlement);
        assertEq(settlement.lastUser(), user1, "Wrong user recorded");
        assertEq(settlement.lastToken(), address(pnt), "Wrong token recorded");
        assertEq(settlement.lastAmount(), actualGasCost, "Wrong amount recorded");
        assertEq(settlement.lastUserOpHash(), userOpHash, "Wrong userOpHash recorded");
    }
    
    /*//////////////////////////////////////////////////////////////
                        ADMIN TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_SetSBTContract() public {
        address newSBT = address(0x123);
        
        paymaster.setSBTContract(newSBT);
        assertEq(paymaster.sbtContract(), newSBT);
    }
    
    function test_SetSBTContract_RevertIf_ZeroAddress() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        paymaster.setSBTContract(address(0));
    }
    
    function test_SetSBTContract_RevertIf_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert(); // Ownable: caller is not the owner
        paymaster.setSBTContract(address(0x123));
    }
    
    function test_SetGasToken() public {
        address newToken = address(0x456);
        
        paymaster.setGasToken(newToken);
        assertEq(paymaster.gasToken(), newToken);
    }
    
    function test_SetGasToken_RevertIf_ZeroAddress() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        paymaster.setGasToken(address(0));
    }
    
    function test_SetMinTokenBalance() public {
        uint256 newMin = 5e18;
        
        paymaster.setMinTokenBalance(newMin);
        assertEq(paymaster.minTokenBalance(), newMin);
    }
    
    function test_SetSettlementContract() public {
        address newSettlement = address(0x789);
        
        paymaster.setSettlementContract(newSettlement);
        assertEq(paymaster.settlementContract(), newSettlement);
    }
    
    function test_SetSettlementContract_RevertIf_ZeroAddress() public {
        vm.expectRevert(PaymasterV3.PaymasterV3__ZeroAddress.selector);
        paymaster.setSettlementContract(address(0));
    }
    
    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_Pause_Unpause() public {
        // Pause
        paymaster.pause();
        assertTrue(paymaster.paused());
        
        // Unpause
        paymaster.unpause();
        assertFalse(paymaster.paused());
    }
    
    function test_ValidatePaymasterUserOp_RevertIf_Paused() public {
        paymaster.pause();
        
        PackedUserOperation memory userOp = _createUserOp(user1);
        
        vm.prank(mockEntryPoint);
        vm.expectRevert(); // Pausable: paused
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }
    
    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_FullFlow_ValidateAndPostOp() public {
        // Step 1: Validate
        PackedUserOperation memory userOp = _createUserOp(user1);
        
        vm.prank(mockEntryPoint);
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0
        );
        
        assertEq(validationData, 0, "Validation failed");
        
        // Step 2: PostOp
        uint256 actualGasCost = 0.002 ether;
        
        vm.prank(mockEntryPoint);
        paymaster.postOp(
            PostOpMode.opSucceeded,
            context,
            actualGasCost,
            0
        );
        
        // Verify settlement was called
        MockSettlement settlement = MockSettlement(mockSettlement);
        assertEq(settlement.lastAmount(), actualGasCost, "Wrong gas cost recorded");
    }
    
    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function _createUserOp(address sender) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(uint256(100000) << 128 | uint256(100000)),
            preVerificationGas: 21000,
            gasFees: bytes32(uint256(1 gwei) << 128 | uint256(1 gwei)),
            paymasterAndData: abi.encodePacked(
                address(0), // paymaster address (will be replaced)
                uint128(100000), // verificationGasLimit
                uint128(100000)  // postOpGasLimit
            ),
            signature: ""
        });
    }
}

/*//////////////////////////////////////////////////////////////
                        MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockEntryPoint {
    // Minimal EntryPoint mock for testing
    function getUserOpHash(PackedUserOperation calldata userOp) external pure returns (bytes32) {
        return keccak256(abi.encode(userOp.sender, userOp.nonce));
    }
}

/// @notice Mock Settlement contract for testing (avoids version conflicts)
contract MockSettlement {
    address public lastPaymaster;
    address public lastUser;
    address public lastToken;
    uint256 public lastAmount;
    bytes32 public lastUserOpHash;
    
    function recordGasFee(
        address user,
        address token,
        uint256 amount,
        bytes32 userOpHash
    ) external returns (bytes32) {
        lastPaymaster = msg.sender;
        lastUser = user;
        lastToken = token;
        lastAmount = amount;
        lastUserOpHash = userOpHash;
        
        return keccak256(abi.encodePacked(msg.sender, userOpHash));
    }
}
