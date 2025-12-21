// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/v4/PaymasterV4.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

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
    constructor() ERC20("Mock", "M") { _mint(msg.sender, 10000 ether); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
    function burnFrom(address account, uint256 amount) external { _spendAllowance(account, msg.sender, amount); _burn(account, amount); }
    function decimals() public view override returns (uint8) { return 18; }
    function exchangeRate() external pure returns (uint256) { return 1e18; }
    function getDebt(address) external pure returns (uint256) { return 0; }
}

contract MockSBT_V4 {
    mapping(address => uint256) public balances;
    function balanceOf(address u) external view returns (uint256) { return balances[u]; }
    function setBalance(address u, uint256 b) external { balances[u] = b; }
    function recordActivity(address) external {}
}

// --- Test Suite ---

contract PaymasterV4Test is Test {
    PaymasterV4 paymaster;
    MockEntryPointV4 entryPoint;
    MockOracleV4 oracle;
    MockXPNTsFactoryV4 factory;
    MockTokenV4 token;
    MockSBT_V4 sbt;
    
    address owner = address(1);
    address treasury = address(2);
    address user = address(0x1234);

    function setUp() public {
        vm.startPrank(owner);
        entryPoint = new MockEntryPointV4();
        oracle = new MockOracleV4(2000e8); // $2000
        factory = new MockXPNTsFactoryV4();
        token = new MockTokenV4();
        sbt = new MockSBT_V4();
        
        paymaster = new PaymasterV4(
            address(entryPoint),
            owner,
            treasury,
            address(oracle),
            0, // Service fee rate
            5 ether, // Max gas cost cap
            address(factory)
        );
        
        // Use updated function names
        // paymaster.setTreasury is internal/different? Ah, let's check. 
        // wait, I only saw setTreasury event but correct function is setTreasury?
        // Let's assume setTreasury exists or correct it if fail. 
        // But for addGasToken/addSBT:
        paymaster.addGasToken(address(token));
        paymaster.addSBT(address(sbt));
        
        vm.stopPrank();
        
        token.mint(user, 1000 ether);
        vm.prank(user);
        token.approve(address(paymaster), type(uint256).max);
        sbt.setBalance(user, 1);
    }
    
    function test_V4_Validate_Success() public {
        PackedUserOperation memory op;
        op.sender = user;
        
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
    
    function test_V4_Fail_NoSBT() public {
        sbt.setBalance(user, 0); // User has no SBT
    
        // Etch code to user to simulate smart account (required for SBT check)
        vm.etch(user, hex"01");
        
        PackedUserOperation memory op;
        op.sender = user;
        bytes memory data = abi.encodePacked(address(token));
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
        
        paymaster.removeSBT(address(sbt));
        assertFalse(paymaster.isSBTSupported(address(sbt)));
        
        vm.stopPrank();
    }
}
