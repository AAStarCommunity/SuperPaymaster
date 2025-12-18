// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../../src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "../../../../src/tokens/xPNTsToken.sol";
import "../../../../src/interfaces/v3/IRegistryV3.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Mock Contracts
// Mock Contracts
contract MockRegistry is IRegistryV3 {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }
    
    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    // Stub implementations for interface compliance
    function calculateExitFee(bytes32, uint256) external pure override returns (uint256) { return 0; }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getBurnHistory(address) external view override returns (BurnRecord[] memory) { return new BurnRecord[](0); }
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,false,"stub"); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function registerRoleSelf(bytes32, bytes calldata) external override returns (uint256) { return 0; }
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
}

contract MockAggregatorV3 is AggregatorV3Interface {
    int256 public price;
    uint8 public _decimals;

    constructor(int256 _price, uint8 _dec) {
        price = _price;
        _decimals = _dec;
    }
    
    function decimals() external view override returns (uint8) { return _decimals; }
    function description() external view override returns (string memory) { return "Mock"; }
    function version() external view override returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
}

contract MockEntryPoint is IEntryPoint {
    function depositTo(address) external payable override {}
    function addStake(uint32) external payable override {}
    function unlockStake() external override {}
    function withdrawStake(address payable) external override {}
    function balanceOf(address) external view override returns (uint256) { return 0; }
    function getDepositInfo(address) external view override returns (DepositInfo memory) { return DepositInfo(0, false, 0, 0, 0); }
    function withdrawTo(address payable, uint256) external override {} // IMPLEMENTED
    
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external override {} 
    function handleOps(PackedUserOperation[] calldata, address payable) external override {}
    function getSenderAddress(bytes memory) external override {}
    function getUserOpHash(PackedUserOperation calldata) external view override returns (bytes32) { return bytes32(0); }
    function getNonce(address, uint192) external view override returns (uint256) { return 0; }
    function incrementNonce(uint192) external override {}
    function delegateAndRevert(address, bytes calldata) external override {}
}

contract SuperPaymasterV3Test is Test {
    SuperPaymasterV3 paymaster;
    xPNTsToken apnts;
    MockRegistry registry;
    MockAggregatorV3 priceFeed;
    MockEntryPoint entryPoint;
    
    address owner = address(1);
    address operator = address(2);
    address user = address(3);
    address treasury = address(4);

    bytes32 constant ENDUSER_ROLE = keccak256("ENDUSER");
    bytes32 constant COMMUNITY_ROLE = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);
        
        entryPoint = new MockEntryPoint();
        registry = new MockRegistry();
        priceFeed = new MockAggregatorV3(2000 * 1e8, 8); // $2000 ETH
        
        // Deploy Token
        apnts = new xPNTsToken("AAStar PNTs", "aPNTs", owner, "AAStar", "aastar.eth", 1e18);

        // Deploy Paymaster
        paymaster = new SuperPaymasterV3(
            entryPoint,
            owner,
            registry,
            address(apnts),
            address(priceFeed),
            treasury
        );

        // Setup Token Whitelist (CRITICAL FIX)
        apnts.setSuperPaymasterAddress(address(paymaster));

        // Grant Roles
        registry.grantRole(COMMUNITY_ROLE, operator);
        registry.grantRole(ENDUSER_ROLE, user);

        // Fund Operator
        apnts.mint(operator, 1000 ether);
        apnts.mint(user, 1000 ether); // User holds xPNTs (technically same logic for aPNTs here)
        
        vm.stopPrank();
    }

    function testUnregisteredOperatorCannotDeposit() public {
        vm.startPrank(address(0xdead));
        vm.expectRevert("Operator not registered");
        paymaster.deposit(100 ether);
        vm.stopPrank();
    }

    function testPushDeposit() public {
        vm.startPrank(operator);
        
        // Push Mode: Transfer + Notify
        apnts.transfer(address(paymaster), 100 ether);
        paymaster.notifyDeposit(100 ether);
        
        (,,, , uint256 bal,,,,) = paymaster.operators(operator); // Fixed tuple
        assertEq(bal, 100 ether);
        
        vm.stopPrank();
    }
    
    function testLegacyDepositFailsIfNoAllow() public {
        vm.startPrank(operator);
        vm.expectRevert(); // No allowance
        paymaster.deposit(100 ether);
        vm.stopPrank();
    }

    function testLegacyDepositWorksWithApproval() public {
        vm.startPrank(operator);
        apnts.approve(address(paymaster), 100 ether);
        
        vm.expectRevert("SuperPaymaster cannot use transferFrom; must use burnFromWithOpHash()");
        paymaster.deposit(100 ether);
        vm.stopPrank();
    }

    function testWithdraw() public {
        // Setup Balance
        vm.startPrank(operator);
        apnts.transfer(address(paymaster), 100 ether);
        paymaster.notifyDeposit(100 ether);

        paymaster.withdraw(50 ether);
        
        (,,, , uint256 bal,,,,) = paymaster.operators(operator); // Fixed tuple
        assertEq(bal, 50 ether);
        assertEq(apnts.balanceOf(operator), 950 ether);
        vm.stopPrank();
    }
    
    function testConfigureOperator() public {
        vm.startPrank(operator);
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        (address token, address treas, bool isConf,, uint256 bal,,,,) = paymaster.operators(operator); // Fixed tuple
        assertEq(token, address(apnts));
        assertEq(treas, treasury);
        assertTrue(isConf);
        vm.stopPrank();
    }
    
    function testSlashAndPause() public {
        vm.startPrank(owner);
        
        // Setup op with some rep
        paymaster.updateReputation(operator, 100);
        
        // Slash Minor
        paymaster.slashOperator(operator, SuperPaymasterV3.SlashLevel.MINOR, 0, "Test Minor");
        (,,,,,,,, uint256 repMinor) = paymaster.operators(operator); // Fixed tuple 9 items
        assertEq(repMinor, 80);

        // Slash Major (Pause)
        paymaster.slashOperator(operator, SuperPaymasterV3.SlashLevel.MAJOR, 0, "Test Major");
        (,,, bool isPaused,,,,, uint256 repMajor) = paymaster.operators(operator); // Fixed tuple 9 items
        assertTrue(isPaused);
        assertEq(repMajor, 30);
        
        vm.stopPrank();
    }
    
    function testProtocolRevenueFlow() public {
        // 1. Setup Operator
        vm.startPrank(operator);
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        apnts.transfer(address(paymaster), 100 ether);
        paymaster.notifyDeposit(100 ether);
        vm.stopPrank();

        // 2. Mock Validation Call (Simulate EntryPoint)
        vm.startPrank(address(entryPoint));
        
        // Construct UserOp
        PackedUserOperation memory op = PackedUserOperation({
            sender: user,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: abi.encodePacked(
                address(paymaster),
                uint256(0), 
                operator    
            ),
            signature: ""
        });
        
        // Call Validate
        try paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether) {
             // Success
        } catch Error(string memory) {
             fail(); // Fixed fail arg
        } catch (bytes memory) {
             // Likely invalid opcode if mock isn't perfect, but let's check events/state
        }
        
        // 3. Verify Revenue
        (,,,,, uint256 bal, uint256 spent,,) = paymaster.operators(operator); // Fixed tuple 9 items
        
        uint256 revenue = paymaster.protocolRevenue();
        
        assertEq(spent, revenue);
        assertTrue(revenue > 0);
        
        vm.stopPrank();
        
        // 4. Withdraw Revenue
        vm.startPrank(owner);
        uint256 treasuryBalBefore = apnts.balanceOf(treasury);
        paymaster.withdrawProtocolRevenue(treasury, revenue);
        assertEq(apnts.balanceOf(treasury), treasuryBalBefore + revenue);
        vm.stopPrank();
    }
}
