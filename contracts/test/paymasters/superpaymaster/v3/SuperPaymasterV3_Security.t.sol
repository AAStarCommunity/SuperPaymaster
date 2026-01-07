// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../../../src/interfaces/v3/IRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";


// --- Mocks ---

contract MockRegistrySec {
    mapping(bytes32 => mapping(address => bool)) public roles;
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }


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

    mapping(address => uint256) public debts;
    function setDebt(address u, uint256 d) external { debts[u] = d; }
    function getDebt(address u) external view returns (uint256) { return debts[u]; }
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
    MockERC20Sec token;
    MockAggregatorV3Sec oracle;

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

        // 1. Deploy Paymaster
        paymaster = new SuperPaymaster(
            IEntryPoint(address(entryPoint)),
            owner,
            IRegistry(address(registry)),
            address(token), // Use token as aPNTs for simplicity
            address(oracle),
            treasury,
            3600
        );
        
        // Update Price Cache
        paymaster.updatePrice();

        // 3. Grant roles
        registry.grantRole(registry.ROLE_PAYMASTER_SUPER(), operator);
        registry.grantRole(registry.ROLE_COMMUNITY(), operator);

        // 4. Configure Operator (Deposit & Setup)
        token.transfer(operator, 100 ether);
        vm.startPrank(operator);
        token.approve(address(paymaster), 100 ether);
        paymaster.deposit(100 ether);
        paymaster.configureOperator(address(token), treasury, 1e18); // 1.0 margin
        vm.stopPrank();

        // 5. Setup User Credit (Decentralized Mode)
        registry.setCreditLimit(user, 1000 ether);
    }

    function testSetOperatorLimits() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60); // 1 minute interval
        
        // Verify storage (Tuple unpacking based on latest V3 structure)
        // (,,,, address token, uint32 rep, uint48 minTx,...)
        (,,,,, , uint48 minTx,,,) = paymaster.operators(operator);
        assertEq(minTx, 60);
    }

    function testRateLimiting_AllowSameBlock() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60); 

        (PackedUserOperation memory userOp, bytes32 opHash) = _createSafeUserOp(user, operatorKey);
        
        // Tx 1: Time T
        vm.warp(1700001000);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, opHash, 100000);
        assertEq(valData, 0, "First tx valid");

        // Tx 2: Time T (Same Block) - Should Pass
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(userOp, opHash, 100000);
        assertEq(valData, 0, "Second tx in same block valid");
    }

    function testRateLimiting_RevertTooSoon() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60); 

        (PackedUserOperation memory userOp, bytes32 opHash) = _createSafeUserOp(user, operatorKey);
        
        // Tx 1: Time 1000
        vm.warp(1700001000);
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(userOp, opHash, 100000);

        // Tx 2: Time 1030 (Delta 30 < 60) - Should Fail
        vm.warp(1700001030);
        vm.prank(address(entryPoint));
        (, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, opHash, 100000);
        
        assertTrue(valData != 0, "Tx too soon should be invalid");
    }
    
    function testRateLimiting_AllowAfterInterval() public {
        vm.prank(operator);
        paymaster.setOperatorLimits(60); 

        (PackedUserOperation memory userOp, bytes32 opHash) = _createSafeUserOp(user, operatorKey);
        
        // Tx 1: Time 1000
        vm.warp(1700001000);
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(userOp, opHash, 100000);

        // Tx 2: Time 1061 (Delta 61 > 60) - Pass
        vm.warp(1700001061);
        vm.prank(address(entryPoint));
        (, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, opHash, 100000);
        assertEq(valData, 0, "Tx after interval should be valid");
    }

    function testUpdateBlockedStatus() public {
        address[] memory users = new address[](1);
        users[0] = user;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        // Must be called by Registry
        vm.prank(address(registry));
        paymaster.updateBlockedStatus(operator, users, statuses);

        assertTrue(paymaster.blockedUsers(operator, user));
    }

    function testBlocklist_DenyUser() public {
        // Block user
        vm.prank(address(registry));
        address[] memory users = new address[](1);
        users[0] = user;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;
        paymaster.updateBlockedStatus(operator, users, statuses);

        (PackedUserOperation memory userOp, bytes32 opHash) = _createSafeUserOp(user, operatorKey);
        
        vm.prank(address(entryPoint));
        (, uint256 valData) = paymaster.validatePaymasterUserOp(userOp, opHash, 100000);
        assertTrue(valData != 0, "Blocked user should be rejected");
    }



    // --- Helper ---
    function _createSafeUserOp(address sender, uint256 signerKey) internal view returns (PackedUserOperation memory op, bytes32 hash) {
        op.sender = sender;
        op.nonce = 0;
        op.initCode = "";
        op.callData = "";
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(100000), uint128(100000)));
        op.preVerificationGas = 50000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        
        address opAddr = vm.addr(signerKey);

        // V3.2.1 Layout (No Sig): [PM(20)][Gas(32)][Op(20)][Rate(32)]
        bytes memory pmData = abi.encodePacked(
            address(paymaster),
            bytes32(0), // gas limits padding/placeholder
            opAddr,     // operator
            type(uint256).max // maxRate
        );
        
        op.paymasterAndData = pmData;
        
        hash = keccak256(abi.encode(
            op.sender, 
            op.nonce, 
            keccak256(op.initCode), 
            keccak256(op.callData), 
            op.accountGasLimits, 
            op.preVerificationGas, 
            op.gasFees, 
            keccak256(pmData)
        ));
        
        // No Signature
        op.signature = "0x";
    }
}
