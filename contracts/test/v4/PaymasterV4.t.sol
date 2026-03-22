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

contract MockUSDT is MockERC20 {
    constructor() MockERC20("USDT", "USDT") {}
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

    function _getPaymasterDataOffset() internal pure override returns (uint256) {
        return 52;
    }
}

contract PaymasterV4Test is Test {
    TestPaymasterV4 paymaster;
    MockEntryPointV4 entryPoint;
    MockERC20 token;
    MockUSDC usdc;
    MockUSDT usdt;
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
        usdt = new MockUSDT();
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
        usdt.mint(user, 1000 * 1e6); // $1000 USDT
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
        assertEq(paymaster.version(), "PaymasterV4-4.3.1");
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
        
        // Verify validUntil is set (Not 0 anymore)
        uint48 validUntil = uint48(validationData >> 160);
        uint48 validAfter = uint48(validationData >> (160 + 48));
        address authorizer = address(uint160(validationData));
        
        assertTrue(validUntil > block.timestamp, "ValidUntil should be in future");
        assertEq(validAfter, 0, "ValidAfter should be 0");
        assertEq(authorizer, address(0), "Authorizer should be 0");
        
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
        
        (,address decodedToken, uint256 charged) = abi.decode(context, (address, address, uint256));
        assertEq(decodedToken, address(usdc));
        
        // Allow slight rounding diff
        uint256 expected = 34500000;
        assertApproxEqAbs(charged, expected, 1000); // within small tolerance
    }

    // =============================================
    // USDT Stablecoin Tests
    // =============================================

    function test_SupportUSDT_DepositAndValidate() public {
        // USDT also has 6 decimals, same as USDC
        vm.prank(owner);
        paymaster.setTokenPrice(address(usdt), 1e8); // $1.00
        assertEq(paymaster.tokenDecimals(address(usdt)), 6, "USDT decimals should be 6");

        uint256 depositAmount = 5000 * 1e6; // $5000 USDT
        usdt.mint(user, depositAmount);
        vm.startPrank(user);
        usdt.approve(address(paymaster), depositAmount);
        paymaster.depositFor(user, address(usdt), depositAmount);
        vm.stopPrank();

        assertEq(paymaster.balances(user, address(usdt)), depositAmount);

        // Validate a UserOp paying with USDT
        PackedUserOperation memory op = _createUserOp(user, address(usdt));
        uint256 maxCostEth = 0.01 ether; // ~$30

        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCostEth);

        (, address decodedToken, uint256 charged) = abi.decode(context, (address, address, uint256));
        assertEq(decodedToken, address(usdt));
        // Same expected as USDC ($1 token, 6 decimals)
        assertApproxEqAbs(charged, 34500000, 1000);
    }

    function test_USDT_FullFlow_ValidateAndPostOp() public {
        // Full lifecycle: deposit → validate → postOp with refund
        vm.prank(owner);
        paymaster.setTokenPrice(address(usdt), 1e8);

        uint256 depositAmount = 10000 * 1e6; // $10,000 USDT
        usdt.mint(user, depositAmount);
        vm.startPrank(user);
        usdt.approve(address(paymaster), depositAmount);
        paymaster.depositFor(user, address(usdt), depositAmount);
        vm.stopPrank();

        // Validate with high maxCost
        PackedUserOperation memory op = _createUserOp(user, address(usdt));
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);

        uint256 balAfterValidate = paymaster.balances(user, address(usdt));

        // PostOp with low actual gas cost → should refund
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, context, 0.001 ether, 0);

        uint256 balAfterPostOp = paymaster.balances(user, address(usdt));
        assertTrue(balAfterPostOp > balAfterValidate, "Should receive refund");
    }

    // =============================================
    // Token Management Tests (add/remove/list)
    // =============================================

    function test_GetSupportedTokens_Empty() public view {
        address[] memory tokens = paymaster.getSupportedTokens();
        assertEq(tokens.length, 0);
    }

    function test_SetTokenPrice_AddsToList() public {
        vm.startPrank(owner);
        paymaster.setTokenPrice(address(usdc), 1e8);
        paymaster.setTokenPrice(address(usdt), 1e8);
        paymaster.setTokenPrice(address(token), 2e8); // $2.00 custom token
        vm.stopPrank();

        address[] memory tokens = paymaster.getSupportedTokens();
        assertEq(tokens.length, 3);
        assertTrue(paymaster.isTokenSupported(address(usdc)));
        assertTrue(paymaster.isTokenSupported(address(usdt)));
        assertTrue(paymaster.isTokenSupported(address(token)));
    }

    function test_SetTokenPrice_UpdateDoesNotDuplicate() public {
        vm.startPrank(owner);
        paymaster.setTokenPrice(address(usdc), 1e8);
        paymaster.setTokenPrice(address(usdc), 1.01e8); // Update price
        vm.stopPrank();

        address[] memory tokens = paymaster.getSupportedTokens();
        assertEq(tokens.length, 1, "Should not duplicate on price update");
        assertEq(paymaster.tokenPrices(address(usdc)), 1.01e8);
    }

    function test_RemoveToken() public {
        vm.startPrank(owner);
        paymaster.setTokenPrice(address(usdc), 1e8);
        paymaster.setTokenPrice(address(usdt), 1e8);
        paymaster.setTokenPrice(address(token), 2e8);

        // Remove USDC (first element)
        paymaster.removeToken(address(usdc));
        vm.stopPrank();

        address[] memory tokens = paymaster.getSupportedTokens();
        assertEq(tokens.length, 2);
        assertFalse(paymaster.isTokenSupported(address(usdc)));
        assertTrue(paymaster.isTokenSupported(address(usdt)));
        assertTrue(paymaster.isTokenSupported(address(token)));

        // Verify price and decimals cleared
        assertEq(paymaster.tokenPrices(address(usdc)), 0);
        assertEq(paymaster.tokenDecimals(address(usdc)), 0);
    }

    function test_RemoveToken_RevertIfNotInList() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__TokenNotInList.selector);
        paymaster.removeToken(address(usdc));
    }

    function test_RemoveToken_DepositReverts() public {
        vm.startPrank(owner);
        paymaster.setTokenPrice(address(usdc), 1e8);
        paymaster.removeToken(address(usdc));
        vm.stopPrank();

        // Deposit should fail after token removed
        vm.startPrank(user);
        usdc.approve(address(paymaster), 100e6);
        vm.expectRevert(PaymasterBase.Paymaster__TokenNotSupported.selector);
        paymaster.depositFor(user, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_GetSupportedTokensInfo() public {
        vm.startPrank(owner);
        paymaster.setTokenPrice(address(usdc), 1e8);   // $1, 6 dec
        paymaster.setTokenPrice(address(token), 2e8);   // $2, 18 dec
        vm.stopPrank();

        (address[] memory tokens, uint256[] memory prices, uint8[] memory decs) =
            paymaster.getSupportedTokensInfo();

        assertEq(tokens.length, 2);
        assertEq(prices[0], 1e8);
        assertEq(decs[0], 6);
        assertEq(prices[1], 2e8);
        assertEq(decs[1], 18);
    }

    function test_MaxTokensReached() public {
        vm.startPrank(owner);
        // Add MAX_GAS_TOKENS (10) tokens
        for (uint256 i = 1; i <= 10; i++) {
            MockERC20 t = new MockERC20("T", "T");
            paymaster.setTokenPrice(address(t), 1e8);
        }
        // 11th should revert
        MockERC20 extra = new MockERC20("Extra", "EX");
        vm.expectRevert(PaymasterBase.Paymaster__MaxTokensReached.selector);
        paymaster.setTokenPrice(address(extra), 1e8);
        vm.stopPrank();
    }
}
