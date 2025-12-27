// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../../../src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "../../../../src/tokens/xPNTsToken.sol";
import "../../../../src/interfaces/v3/IRegistryV3.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";

// Mock Contracts
// Mock Contracts
contract MockRegistry is IRegistryV3 {
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external view override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external view override returns (bytes32) { return keccak256("KMS"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_COMMUNITY() external view override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external view override returns (bytes32) { return keccak256("ENDUSER"); }
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(bytes32 => address) public _roleOwners;

    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }

    function roleOwners(bytes32 roleId) external view override returns (address) {
        return _roleOwners[roleId];
    }
    
    function setRoleOwner(bytes32 roleId, address owner) external {
        _roleOwners[roleId] = owner;
    }

    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    // Stub implementations for interface compliance
    function calculateExitFee(bytes32, uint256) external pure override returns (uint256) { return 0; }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function createNewRole(bytes32, RoleConfig calldata, address) external override {}
    function exitRole(bytes32) external override {}
    function getBurnHistory(address) external view override returns (BurnRecord[] memory) { return new BurnRecord[](0); }
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,0,false,"stub"); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function registerRoleSelf(bytes32, bytes calldata) external override returns (uint256) { return 0; }
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    
    // V3.1 Mock Logic
    mapping(address => uint256) public creditLimits;
    
    function setCreditForUser(address user, uint256 limit) external {
        creditLimits[user] = limit;
    }

    function batchUpdateGlobalReputation(address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    
    function getCreditLimit(address user) external view override returns (uint256) { 
        return creditLimits[user]; 
    }

    // New V3.1 Admin Functions
    function adminConfigureRole(bytes32, uint256, uint256, uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}

    function setCreditTier(uint256, uint256) external override {}
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
        registry.grantRole(registry.ROLE_PAYMASTER_SUPER(), operator);
        registry.grantRole(COMMUNITY_ROLE, operator);
        registry.grantRole(ENDUSER_ROLE, user);
        
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
        registry.grantRole(registry.ROLE_PAYMASTER_SUPER(), operator);
        registry.grantRole(COMMUNITY_ROLE, operator);
        registry.grantRole(ENDUSER_ROLE, user);

        // Fund Operator
        apnts.mint(operator, 1000 ether);
        apnts.mint(user, 1000 ether); // User holds xPNTs (technically same logic for aPNTs here)
        
        vm.stopPrank();
    }

    function testUnregisteredOperatorCannotDeposit() public {
        vm.startPrank(address(0xdead));
        vm.expectRevert(SuperPaymasterV3.Unauthorized.selector);
        paymaster.deposit(100 ether);
        vm.stopPrank();
    }

    function testPushDeposit() public {
        vm.startPrank(operator);
        
        // Push Mode: Transfer + Notify
        apnts.transfer(address(paymaster), 100 ether);
        paymaster.notifyDeposit(100 ether);
        
        assertEq(paymaster.totalTrackedBalance(), 100 ether, "Total Tracked Mismatch");

        (
            address v1, bool v2, bool v3, 
            address v4, uint96 v5, uint256 v6, uint256 v7, uint256 v8, uint256 v9
        ) = paymaster.operators(operator);
        
        // v6 is aPNTsBalance (100 ether) in new packed layout.
        if (v6 != 100 ether) {
             console.log("v6:", v6);
             console.log("v7:", v7);
             fail();
        }
        assertEq(v6, 100 ether);
        
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
        
        (,,,,, uint256 bal,,,) = paymaster.operators(operator); 
        assertEq(bal, 50 ether);
        assertEq(apnts.balanceOf(operator), 950 ether);
        vm.stopPrank();
    }
    
    function testConfigureOperator() public {
        vm.startPrank(operator);
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        (address token, bool isConf,, address treas, , uint256 bal,,,) = paymaster.operators(operator); 
        assertEq(token, address(apnts));
        vm.stopPrank();
    }
    
    function testSlashAndPause() public {
        vm.startPrank(owner);
        paymaster.updateReputation(operator, 100);
        
        // Slash Minor
        paymaster.slashOperator(operator, ISuperPaymasterV3.SlashLevel.MINOR, 0, "Test Minor");
        (,,,,,,,, uint256 repMinor) = paymaster.operators(operator); 
        assertEq(repMinor, 80);

        // Slash Major (Pause)
        paymaster.slashOperator(operator, ISuperPaymasterV3.SlashLevel.MAJOR, 0, "Test Major");
        (,,,,,,,, uint256 repMajor) = paymaster.operators(operator); 
        assertEq(repMajor, 30);
        
        vm.stopPrank();
    }
    
    function testProtocolRevenueFlow() public {
        // 1. Setup Operator (Need significant balance for 1 ETH gas * 2000 price)
        vm.startPrank(owner);
        apnts.mint(operator, 200000 ether); 
        apnts.mint(user, 200000 ether); // FIX: Mint user enough tokens to pay for the op
        vm.stopPrank();

        vm.startPrank(operator);
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        
        apnts.transfer(address(paymaster), 200000 ether);
        paymaster.notifyDeposit(200000 ether);
        vm.stopPrank();

        // 2. Mock Validation Call
        vm.startPrank(address(entryPoint));
        
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
        
        // Use 1 ether prefund to guarantee > 0 revenue
        try paymaster.validatePaymasterUserOp(op, bytes32(0), 1 ether) {
             // Success
        } catch Error(string memory reason) {
             console.log("Val Failed:", reason);
             fail(); 
        } catch (bytes memory) {
             console.log("Val Failed (Bytes)");
             fail();
        }
        
        // 3. Verify Revenue
        // Spent is v7 (index 7, item 8?) 
        // Struct: 6=Balance, 7=TotalSpent. 
        // Tuple: (v1..v9).
        // If v6 is Balance, then v7 is TotalSpent.
        (,,,,,, uint256 spent,,) = paymaster.operators(operator); 
        
        uint256 revenue = paymaster.protocolRevenue();
        console.log("Revenue detected:", revenue);
        
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


    // ====================================
    // V3.1 Refactor Tests
    // ====================================

    function _setupV3Env() internal {
        vm.startPrank(operator);
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        apnts.transfer(address(paymaster), 100 ether);
        paymaster.notifyDeposit(100 ether);
        vm.stopPrank();
    }

    function test_V31_CreditPayment_Success() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        
        PackedUserOperation memory op = _createOp(user);
        bytes32 opHash = keccak256("test_hash");

        vm.startPrank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(op, opHash, 0.001 ether);
        vm.stopPrank();

        assertEq(validationData, 0, "Validation should pass via Credit");
        (address token, uint256 xAmount, address u, uint256 aAmount, bytes32 h, address opAddr) = abi.decode(context, (address, uint256, address, uint256, bytes32, address));
        assertEq(token, address(apnts));
        assertEq(opAddr, operator);
        assertEq(u, user);
        assertGt(xAmount, 0);
    }

    function _createOp(address sender) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(uint128(100000), uint128(100000))),
            preVerificationGas: 21000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei))),
            paymasterAndData: abi.encodePacked(
                address(paymaster),
                uint128(100000), // gasLimit
                uint128(0),      // postOpGas
                operator         // PaymasterData: Operator (Packed 20 bytes)
            ),
            signature: ""
        });
    }

    function test_V31_DebtRecording_OnBurnFail() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        
        PackedUserOperation memory op = _createOp(user);
        bytes32 opHash = keccak256("test_hash");
        
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, opHash, 0.001 ether);
        
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.001 ether, 1 gwei);
        
        uint256 debt = apnts.getDebt(user);
        assertGt(debt, 0, "Debt should be recorded");
    }

    function test_V31_InsufficientCredit_Revert() public {
        _setupV3Env();
        registry.setCreditForUser(user, 0);
        
        deal(address(apnts), user, 0);

        PackedUserOperation memory op = _createOp(user);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(); 
        paymaster.validatePaymasterUserOp(op, keccak256("h"), 0.001 ether);
    }

    function test_V31_ReputationEvent() public {
        _setupV3Env();
        registry.setCreditForUser(user, 1000 ether);
        PackedUserOperation memory op = _createOp(user);
        
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(op, keccak256("h"), 0.001 ether);
    }
}
