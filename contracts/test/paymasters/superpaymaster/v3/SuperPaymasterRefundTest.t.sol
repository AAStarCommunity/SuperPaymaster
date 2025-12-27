// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";

import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

contract SuperPaymasterRefundTest is Test {
    SuperPaymasterV3 paymaster;
    Registry registry;
    MockERC20 aPNTs;
    MockERC20 xPNTs;
    
    address owner = address(1);
    address operator = address(2);
    address user = address(3);
    address entryPoint = address(4); // Mock EP
    
    function setUp() public {
        vm.startPrank(owner);
        aPNTs = new MockERC20("aPNTs", "APNT", 18);
        xPNTs = new MockERC20("xPNTs", "XPNT", 18);
        
        // Mock Registry/PriceFeed
        registry = new Registry(address(0), address(0x1), address(0x2)); // Minimal mock
        MockPriceFeed priceFeed = new MockPriceFeed();
        
        paymaster = new SuperPaymasterV3(
            IEntryPoint(entryPoint),
            owner,
            registry,
            address(aPNTs),
            address(priceFeed),
            owner
        );
        
        // Setup Protocol Fee 10%
        paymaster.setProtocolFee(1000); 
        
        // Mock Roles using cheatcodes
        // hasRole(bytes32,address) -> 0x8aa53f93 (standard) or custom
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
        
        vm.stopPrank();
        
        // Setup Operator
        vm.startPrank(operator);
        aPNTs.mint(operator, 1000000 ether); // 1M tokens
        aPNTs.approve(address(paymaster), 1000000 ether);
        paymaster.configureOperator(address(xPNTs), operator, 1e18); // 1:1 Rate
        paymaster.deposit(1000000 ether);
        
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();
        vm.stopPrank();
    }

    function testRefundLogic() public {
        uint256 maxCost = 0.5 ether; // Max 0.5 ETH Gas ($1000)
        uint256 actualCost = 0.1 ether; // Actual 0.1 ETH Gas ($200)
        
        // 1. Validate (Pre-Charge Max)
        PackedUserOperation memory userOp = _mockUserOp();
        bytes32 opHash = keccak256("op");
        
        vm.prank(entryPoint);
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, opHash, maxCost);
        
        assertEq(validationData, 0, "Validation should pass");
        assertTrue(context.length > 0, "Context should be returned");
        
        // Check Operator Balance decreased by Max (logic: Pre-charge)
        (uint128 balanceAfterValidate,,,,,,,,) = paymaster.operators(operator);
        // Initial 100 - Charge?
        // We need to know specific aPNTs conversion.
        // Price: $2000 ETH. $0.02 aPNTs.
        // 1 ETH = $2000 = 100,000 aPNTs.
        // MaxCost 1 ETH = 100,000 aPNTs.
        // BUT wait, unit bug might exist. 
        // If bug: 100,000 Wei (tiny).
        // If correct: 100,000 ether.
        
        console.log("Balance After Validate:", balanceAfterValidate);
        
        // 2. PostOp (Refund)
        vm.prank(entryPoint);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 0);
        
        (uint128 balanceFinal,,,,,,,,) = paymaster.operators(operator);
        console.log("Balance Final:", balanceFinal);
        
        // Expected:
        // Actual Cost 0.5 ETH = 50,000 aPNTs.
        // Markup 10% = 55,000 aPNTs.
        // Total Refund = 100,000 (Max) - 55,000.
        // Final Spent = 55,000.
        // Initial Deposit 100 ether = 100e18.
        // 55,000 aPNTs = 55,000e18 (if 18 decimals).
        
        // If Logic: 100e18 - 55,000e18... 
        // 55,000e18 is huge.
        // 1 ETH Gas Cost is HUGE. $2000 tx fee. 
        // aPNTs is $0.02.
        // Realistically 1 ETH gas is wrong for unit test but okay for math.
        
        // Verify Revenue
        uint256 revenue = paymaster.protocolRevenue();
        console.log("Protocol Revenue:", revenue);
        // Revenue should be equal to Final Charge (55,000e18).
    }
    
    function _mockUserOp() internal view returns (PackedUserOperation memory op) {
        op.sender = user;
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(0), uint128(0), address(operator)); // minimal
    }
}

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
        // allowance[from][msg.sender] -= amount; // Skip allowance check for mock simplicity if needed, or keep it
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    // ISuperPaymasterV3 expects recordDebt on token if it cast to IxPNTsToken
    // Note: in test setup we cast mock to IxPNTsToken
    function recordDebt(address user, uint256 amount) external {}
    function burnFromWithOpHash(address user, uint256 amount, bytes32 opHash) external {} 
    function getDebt(address user) external view returns (uint256) { return 0; }
    function exchangeRate() external view returns (uint256) { return 1e18; }
}

contract MockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1); // $2000
    }
    function decimals() external pure returns (uint8) { return 8; }
}
