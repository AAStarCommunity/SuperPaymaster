// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";
import { Initializable } from "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";

// --- Mocks ---

contract MockEntryPointV4 is IEntryPoint {
    function depositTo(address account) external payable {}
    function addStake(uint32 _unstakeDelaySec) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable withdrawAddress) external {}
    function getSenderAddress(bytes memory initCode) external {}
    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata opsPerAggregator, address payable beneficiary) external {}
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32) { return keccak256(abi.encode(userOp)); }
    function getNonce(address sender, uint192 key) external view returns (uint256 nonce) { return 0; }
    function balanceOf(address account) external view returns (uint256) { return 0; }
    function incrementNonce(uint192 key) external {}
    function fail(bytes memory context, uint256 actualGasCost, uint256 actualUserOpFeePerGas) external {} 
    function delegateAndRevert(address target, bytes calldata data) external {}
    function getDepositInfo(address account) external view returns (DepositInfo memory info) { return info; }
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {}
}

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 1e18);
    }
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
     function decimals() public pure override virtual returns (uint8) {
        return 18;
    }
}

contract MockUSDC is MockERC20 {
    constructor() MockERC20("USDC", "USDC") {}
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockOracle {
    int256 public price;
    uint8 public decimalsVal = 8;
    
    constructor(int256 _price) {
        price = _price;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, block.timestamp, 0);
    }
    
    function decimals() external view returns (uint8) {
        return decimalsVal;
    }
}

// Concrete implementation for testing abstract base
contract TestPaymasterV4 is PaymasterBase, Initializable {
    constructor() PaymasterBase() {}
    
    function initialize(
        address _entryPoint,
        address _owner,
        address _treasury,
        address _ethUsdPriceFeed,
        uint256 _serviceFeeRate,
        uint256 _maxGasCostCap,
        uint256 _priceStalenessThreshold
    ) external initializer {
        _initializePaymasterBase(
            _entryPoint,
            _owner,
            _treasury,
            _ethUsdPriceFeed,
            _serviceFeeRate,
            _maxGasCostCap,
            _priceStalenessThreshold
        );
    }
}

contract PaymasterV4Test is Test {
    TestPaymasterV4 paymaster;
    MockEntryPointV4 entryPoint;
    MockERC20 token;
    MockUSDC usdc;
    MockOracle ethOracle;
    
    address owner = address(1);
    address treasury = address(2);
    address user = address(3);
    
    uint256 constant SERVICE_FEE = 500; // 5%
    uint256 constant MAX_GAS_CAP = 0.1 ether;
    uint256 constant INITIAL_BALANCE = 100 ether;

    function setUp() public {
        vm.startPrank(owner);
        
        entryPoint = new MockEntryPointV4();
        token = new MockERC20("Test Token", "TEST");
        usdc = new MockUSDC();
        ethOracle = new MockOracle(3000 * 1e8); // ETH = $3000

        paymaster = new TestPaymasterV4();
        paymaster.initialize(
            address(entryPoint),
            owner,
            treasury,
            address(ethOracle),
            SERVICE_FEE,
            MAX_GAS_CAP,
            3600
        );
        
        // Setup Initial State
        paymaster.updatePrice(); // Cache Initial Price
        
        vm.stopPrank();
        
        // Fund User
        token.mint(user, INITIAL_BALANCE);
        usdc.mint(user, 1000 * 1e6); // $1000 USDC
    }
    
    // Helper to create UserOp with minimal payload
    function _createUserOp(address sender, address payToken) internal pure returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = 0;
        op.initCode = hex"";
        op.callData = hex"";
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(100000), uint128(100000)));
        op.preVerificationGas = 21000;
        op.gasFees = bytes32(abi.encodePacked(uint128(100), uint128(100))); // maxPriorityFee, maxFeePerGas
        
        op.paymasterAndData = abi.encodePacked(
            address(0x123), // Paymaster Addr (ignored by logic inside, usually self)
            uint256(0),     // Validation Data (32 bytes)
            payToken        // Token (20 bytes) -> Start at 20+32=52. End 72.
        );
    }

    function test_Initialize() public view {
        assertEq(paymaster.treasury(), treasury);
        assertEq(paymaster.serviceFeeRate(), SERVICE_FEE);
        assertEq(paymaster.version(), "PaymasterV4-4.3.0");
    }
    
    function test_DepositFor_Success() public {
        vm.startPrank(owner);
        paymaster.setTokenPrice(address(token), 1e8); // $1.00
        vm.stopPrank();

        uint256 depositAmount = 10 ether;
        vm.startPrank(user);
        token.approve(address(paymaster), depositAmount);
        paymaster.depositFor(user, address(token), depositAmount);
        vm.stopPrank();
        
        assertEq(paymaster.balances(user, address(token)), depositAmount);
    }
    
    function test_ValidateUserOp_Success() public {
        // 1. Setup Token Price ($1.00)
        vm.prank(owner);
        paymaster.setTokenPrice(address(token), 1e8);
        
        // 2. User Deposits
        uint256 depositAmount = 100 ether;
        vm.startPrank(user);
        token.approve(address(paymaster), depositAmount);
        paymaster.depositFor(user, address(token), depositAmount);
        vm.stopPrank();
        
        // 3. Create UserOp
        PackedUserOperation memory op = _createUserOp(user, address(token));
        
        // 4. Validate
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
        
        assertEq(validationData, 0); // Success
        
        // Verify balance deducted (Calculated cost)
        uint256 balanceAfter = paymaster.balances(user, address(token));
        assertTrue(balanceAfter < depositAmount);
    }
    
    function test_ValidateUserOp_RevertIf_InsufficientBalance() public {
        vm.prank(owner);
        paymaster.setTokenPrice(address(token), 1e8);
        
        // No deposit
        PackedUserOperation memory op = _createUserOp(user, address(token));
        
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterBase.Paymaster__InsufficientBalance.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }
    
    function test_ValidateUserOp_RevertIf_TokenNotSupported() public {
        PackedUserOperation memory op = _createUserOp(user, address(token));
        
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterBase.Paymaster__TokenNotSupported.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }
    
    function test_PostOp_Refund() public {
        // 1. Setup
        vm.prank(owner);
        paymaster.setTokenPrice(address(token), 1e8);
        
        uint256 depositAmount = 1000 ether;
        token.mint(user, depositAmount);
        vm.startPrank(user);
        token.approve(address(paymaster), depositAmount);
        paymaster.depositFor(user, address(token), depositAmount);
        vm.stopPrank();
        
        PackedUserOperation memory op = _createUserOp(user, address(token));
        
        // 2. Validate (High Max Cost)
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);
        
        uint256 balanceMid = paymaster.balances(user, address(token));
        
        // 3. PostOp (Low Actual Cost)
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, context, 0.001 ether, 0); // 1% of max
        
        uint256 balanceFinal = paymaster.balances(user, address(token));
        assertTrue(balanceFinal > balanceMid); // Refund received
    }
    
    function test_SupportUSDC_Decimals() public {
        // USDC has 6 decimals. Verify math handles it.
        vm.prank(owner);
        paymaster.setTokenPrice(address(usdc), 1e8); // $1.00
        assertEq(paymaster.tokenDecimals(address(usdc)), 6, "Decimals should be 6");
        
        uint256 depositAmount = 10000 * 1e6; // $10,000 USDC
        usdc.mint(user, depositAmount);
        vm.startPrank(user);
        usdc.approve(address(paymaster), depositAmount);
        paymaster.depositFor(user, address(usdc), depositAmount);
        vm.stopPrank();
        
        PackedUserOperation memory op = _createUserOp(user, address(usdc));
        
        uint256 maxCostEth = 0.01 ether; // $30 usd
        
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCostEth);
        
        (,address token, uint256 charged,) = abi.decode(context, (address, address, uint256, uint256));
        assertEq(token, address(usdc));
        
        // Allow slight rounding diff
        uint256 expected = 34500000;
        assertApproxEqAbs(charged, expected, 1000); // within small tolerance
    }
}
