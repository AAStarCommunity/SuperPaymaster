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
    function getDepositInfo(address account) external view returns (DepositInfo memory info) {}
    function incrementNonce(uint192 key) external {}
    function fail(bytes memory context, uint256 actualGasCost, uint256 actualUserOpFeePerGas) external {} 
    function delegateAndRevert(address target, bytes calldata data) external {}
    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external {}
}

contract MockOracleV4 is AggregatorV3Interface {
    int256 public price;
    uint8 public decimalsVal = 8;
    constructor(int256 _price) { price = _price; }
    function setPrice(int256 _price) external { price = _price; }
    function decimals() external view returns (uint8) { return decimalsVal; }
    function description() external view returns (string memory) { return "Mock"; }
    function version() external view returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) { return (0, price, 0, block.timestamp, 0); }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { 
        return (1, price, block.timestamp, block.timestamp, 1); 
    }
}

contract MockXPNTsFactoryV4 {
    uint256 public price = 0.02 ether; // $0.02
    function getAPNTsPrice() external view returns (uint256) { return price; }
}

contract MockTokenV4 is ERC20 {
    address public FACTORY; // ✅ For token origin verification
    constructor() ERC20("Mock", "M") { 
        _mint(msg.sender, 10000 ether); 
        FACTORY = msg.sender; // Mock: factory is deployer
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
    function burnFrom(address account, uint256 amount) external { _spendAllowance(account, msg.sender, amount); _burn(account, amount); }
    function decimals() public view override returns (uint8) { return 18; }
    function exchangeRate() external pure returns (uint256) { return 1e18; }
    function getDebt(address) external pure returns (uint256) { return 0; }
    function setFactory(address _factory) external { FACTORY = _factory; } // ✅ For testing
}

// --- Test Suite ---

contract PaymasterV4Test is Test {
    Paymaster paymaster; // This will be the proxy
    PaymasterFactory pmFactory;
    Paymaster pmImpl;
    MockEntryPointV4 entryPoint;
    MockOracleV4 oracle;
    MockXPNTsFactoryV4 factory;
    MockTokenV4 token;
    
    address owner = address(1);
    address treasury = address(2);
    address user = address(0x1234);

    function setUp() public {
        vm.startPrank(owner);
        entryPoint = new MockEntryPointV4();
        oracle = new MockOracleV4(2000e8); // $2000
        factory = new MockXPNTsFactoryV4();
        token = new MockTokenV4();
        token.setFactory(address(factory)); // ✅ Set correct factory
        
        // 1. Deploy Factory
        pmFactory = new PaymasterFactory();
        
        // 2. Deploy Implementation (registry is immutable)
        pmImpl = new Paymaster(address(0x999)); // Mock registry address
        
        // 3. Register Implementation
        pmFactory.addImplementation("v4.0", address(pmImpl));
        
        // 4. Prepare Init Data
        bytes memory initData = abi.encodeWithSelector(
            Paymaster.initialize.selector,
            address(entryPoint),
            owner, // Owner (valid)
            treasury, // Treasury (valid)
            address(oracle),
            0, // Service fee rate
            5 ether, // Max gas cost cap
            0, // minTokenBalance
            address(factory),
            address(0), // initialGasToken
            3600 // Staleness Threshold
        );
        
        // 5. Deploy Proxy via Factory
        address proxyAddr = pmFactory.deployPaymaster("v4.0", initData);
        paymaster = Paymaster(payable(proxyAddr));
        
        // Use updated function names
        paymaster.addGasToken(address(token));
        
        vm.stopPrank();
        
        token.mint(user, 1000 ether);
        vm.prank(user);
        token.approve(address(paymaster), type(uint256).max);
    }
    
    function test_V4_Validate_Success() public {
        PackedUserOperation memory op;
        op.sender = user;
        op.initCode = hex"deadbeef"; // ✅ Add initCode for undeployed account
        
        bytes memory data = abi.encodePacked(address(token));
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(1000), uint128(1000), data);
        
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 valData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);
        
        assertEq(valData, 0, "Validation should pass");
        assertTrue(context.length > 0);
    }
    
    function test_V4_Fail_UnsupportedToken() public {
        PackedUserOperation memory op;
        op.sender = user;
        
        // Ensure user has no valid token balance to fallback to
        uint256 bal = token.balanceOf(user);
        vm.prank(user);
        token.transfer(owner, bal);
        
        address badToken = address(0xDead);
        bytes memory data = abi.encodePacked(badToken);
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(1000), uint128(1000), data);
        
        vm.prank(address(entryPoint));
        vm.expectRevert();
        paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);
    }
    
    function test_V4_Admin_Functions() public {
        vm.startPrank(owner);
        paymaster.pause();
        assertTrue(paymaster.paused());
        paymaster.unpause();
        assertFalse(paymaster.paused());
        
        paymaster.setServiceFeeRate(500); // 5%
        assertEq(paymaster.serviceFeeRate(), 500);
        
        paymaster.setMaxGasCostCap(1 ether);
        assertEq(paymaster.maxGasCostCap(), 1 ether);
        
        address t2 = address(0x888);
        paymaster.setTreasury(t2);
        assertEq(paymaster.treasury(), t2);
        
        paymaster.removeGasToken(address(token));
        assertFalse(paymaster.isGasTokenSupported(address(token)));
        
        vm.stopPrank();
    }
    
    function test_V4_Refund_Success() public {
        PackedUserOperation memory op;
        op.sender = user;
        op.initCode = hex"deadbeef"; // ✅ Add initCode for undeployed account
        
        // Setup: Pre-charged 1000 tokens
        uint256 preCharge = 1000;
        address gasToken = address(token);
        bytes memory data = abi.encodePacked(gasToken);
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(1000), uint128(1000), data);
        
        // 1. Validate (Escrow tokens)
        uint256 balBefore = token.balanceOf(user);
        
        // Expected amount based on Mock logic: 1000 * 2000 / 0.02 = 1e8
        uint256 expectedPreCharge = 100000000; 
        
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), preCharge);
        
        assertEq(token.balanceOf(user), balBefore - expectedPreCharge, "Pre-charge mismatch");
        assertEq(token.balanceOf(address(paymaster)), expectedPreCharge, "Escrow mismatch");
        
        // 2. PostOp (Actual cost is only 400)
        uint256 actualCost = 400;
        uint256 treasuryBalBefore = token.balanceOf(treasury);
        
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, context, actualCost, 0);
        
        // 3. Verify Refund
        uint256 expectedRefund = 60000000;
        assertEq(token.balanceOf(user), balBefore - expectedPreCharge + expectedRefund, "User refund mismatch");
        assertEq(token.balanceOf(treasury), treasuryBalBefore + (expectedPreCharge - expectedRefund), "Treasury payment mismatch");
        assertEq(token.balanceOf(address(paymaster)), 0, "Escrow not cleared");
    }

    function test_V4_Pricing_HybridModel_WithBuffer() public {
        // 1. Setup: Update Cache first
        // Oracle is $2000 (set in setUp)
        // We simulate a scenario where Cache is $2000, Realtime is $2000.
        // Validation should charge: Cost($2000) * 1.1 (Buffer)
        // PostOp should charge: Cost($2000)
        // Refund: Cost($2000) * 0.1
        
        // Mock logic in PaymasterV4 relies on `cachedPrice`. 
        // We need to trigger updatePrice() to populate it.
        vm.prank(owner); // updatePrice might be open or owner only? Abstract says external without modifier.
        paymaster.updatePrice();
        
        PackedUserOperation memory op;
        op.sender = user;
        op.initCode = hex"deadbeef"; 
        
        // Gas Cost Setup
        uint256 gasCost = 1000; // Wei
        
        // Paymaster Data
        address gasToken = address(token);
        bytes memory data = abi.encodePacked(gasToken);
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(gasCost), uint128(100), data);
        
        uint256 balBefore = token.balanceOf(user);
        
        // --- Step 1: Validation (Cache + Buffer) ---
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), gasCost);
        
        // Calculate Expected Pre-Charge
        // ETH Price = $2000
        // CostUSD = 1000 Wei * $2000 = 2,000,000 units (scaled)
        
        // Logic:
        // ethUsdPrice = 2000e8
        // decimals = 8
        // ethPriceUSD = 2000e8 * 1e18 / 1e8 = 2000e18
        // gasCostUSD = (1000 * 2000e18) / 1e18 = 2,000,000
        
        // Buffer = 10% (1000 BPS)
        // ServiceFee = 0 (set in setUp)
        // TotalRate = 10000 + 0 + 1000 = 11000
        // totalCostUSD = 2,000,000 * 11000 / 10000 = 2,200,000
        
        // aPNTsPrice = $0.02 (0.02e18)
        // aPNTsAmount = (2,200,000 * 1e18) / 0.02e18 = 110,000,000
        
        // xPNTs (1:1 rate) => 110,000,000
        uint256 expectedPreCharge = 110000000;
        
        assertEq(token.balanceOf(user), balBefore - expectedPreCharge, "Validation: Should charge Cost + Buffer");
        
        // --- Step 2: PostOp (Realtime - No Buffer) ---
        // PostOp re-calculates using Realtime price.
        // If Price hasn't changed ($2000), actual cost should be exactly 1.0x (no buffer).
        
        // totalRate for PostOp = 10000 + 0 (No Buffer!) = 10000
        // totalCostUSD = 2,000,000 * 10000 / 100000 = 2,000,000
        // FinalCost = (2,000,000 * 1e18)/0.02e18 = 100,000,000
        
        uint256 actualCostWei = gasCost;
        uint256 expectedFinalCost = 100000000;
        
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, context, actualCostWei, 0);
        
        // --- Step 3: Verify Refund ---
        // User should get back: 110,000,000 - 100,000,000 = 10,000,000 (The Buffer!)
        uint256 expectedBalance = balBefore - expectedFinalCost;
        assertEq(token.balanceOf(user), expectedBalance, "PostOp: Should refund buffer amount");
        assertEq(token.balanceOf(treasury), expectedFinalCost, "Treasury should receive exact cost");
        assertEq(token.balanceOf(address(paymaster)), 0, "Escrow should be empty");
    }
}
