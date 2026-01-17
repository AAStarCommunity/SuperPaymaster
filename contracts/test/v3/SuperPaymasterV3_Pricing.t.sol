// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

// --- Mocks ---

contract MockEntryPointV3 is IEntryPoint {
    function depositTo(address) external payable {}
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

contract MockPriceFeedV3 {
    int256 public price = 2000 * 1e8;
    
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1); // $2000
    }
    function decimals() external pure returns (uint8) {
        return 8;
    }
    // Helper to change price
    function setPrice(int256 _price) external {
        price = _price;
    }
}

contract MockAPNTsV3 is ERC20 {
    constructor() ERC20("AAStar Points", "aPNTs") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockGTokenV3 is ERC20 {
    constructor() ERC20("GToken", "GT") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockXPNTsTokenV3 is ERC20 {
    address public FACTORY;
    uint256 public exchangeRateVal = 1e18; // 1:1

    constructor() ERC20("Mock", "M") { 
        FACTORY = msg.sender;
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function exchangeRate() external view returns (uint256) { return exchangeRateVal; }
    function getDebt(address) external pure returns (uint256) { return 0; }
    function recordDebt(address user, uint256 debt) external {}
}


contract MockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
    
    function setRole(bytes32 role, address account, bool val) external {
        roles[role][account] = val;
    }
    
    function getCreditLimit(address) external pure returns (uint256) {
        return 1000 ether;
    }
    
    // Stub other interface methods if needed by SuperPaymaster
    function setRoleLockDuration(bytes32, uint256) external {}
    function setRoleOwner(bytes32, address) external {}
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    
    // Stubs for other IRegistry methods
    function registerRole(bytes32, address, bytes calldata) external {}
    function registerRoleSelf(bytes32, bytes calldata) external returns (uint256) { return 0; }
    function exitRole(bytes32) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function adminConfigureRole(bytes32, uint256, uint256, uint256, uint256) external {}
    function createNewRole(bytes32, IRegistry.RoleConfig calldata, address) external {}
    function setStaking(address) external {}
    function setMySBT(address) external {}
    function setSuperPaymaster(address) external {}
    function setBLSAggregator(address) external {}
    function setBLSValidator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function setLevelThreshold(uint256, uint256) external {}
    function addLevelThreshold(uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function calculateExitFee(bytes32, uint256) external view returns (uint256) { return 0; }
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external view returns (uint256) { return 0; }
    
    // View constants / getters
    function version() external pure returns (string memory) { return "Mock"; }
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_KMS() external pure returns (bytes32) { return keccak256("KMS"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
    function isReputationSource(address) external view returns (bool) { return false; }
    function roleOwners(bytes32) external view returns (address) { return address(0); }
}

contract SuperPaymasterV3_Pricing_Test is Test {
    using stdStorage for StdStorage;
    
    SuperPaymaster public paymaster;
    MockRegistry public registry;
    MockGTokenV3 public gtoken;
    MockEntryPointV3 public entryPoint;
    MockPriceFeedV3 public priceFeed;
    MockAPNTsV3 public apnts;
    MockXPNTsTokenV3 public xpntsToken;
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public operator1 = address(0x3);
    address public user1 = address(0x5);
    
    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    
    function setUp() public {
        vm.startPrank(owner);
        
        gtoken = new MockGTokenV3();
        entryPoint = new MockEntryPointV3();
        priceFeed = new MockPriceFeedV3();
        apnts = new MockAPNTsV3();
        xpntsToken = new MockXPNTsTokenV3();
        
        // Mock Registry
        registry = new MockRegistry();
        
        // Deploy SuperPaymaster
        paymaster = new SuperPaymaster(
            IEntryPoint(address(entryPoint)), 
            owner, 
            IRegistry(address(registry)), 
            address(apnts), 
            address(priceFeed), 
            treasury, 
            3600
        );
        
        // 1. Initialize Cache
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice(); // Cache = $2000
        
        // 2. Setup Roles (Via Mock)
        // Use constants from Registry to ensure perfect match
        registry.setRole(registry.ROLE_PAYMASTER_SUPER(), operator1, true);
        registry.setRole(registry.ROLE_COMMUNITY(), operator1, true);
        
        // Debug Verification
        require(registry.hasRole(registry.ROLE_PAYMASTER_SUPER(), operator1), "Debug: Role Set Failed");
        require(address(paymaster.REGISTRY()) == address(registry), "Debug: Registry Mismatch");
        
        // 3. Fund Operator
        apnts.mint(operator1, 10000 ether);
        
        vm.stopPrank(); // End Owner Prank
        
        // 4. Mock Registry Update (SBT check) - Must be called by Registry
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user1, true); 
        
        // 5. Operator Config
        vm.startPrank(operator1);
        apnts.approve(address(paymaster), type(uint256).max);
        
        // configure first usually
        paymaster.configureOperator(address(xpntsToken), address(0x999), 1 ether);
        paymaster.deposit(5000 ether); 
        vm.stopPrank();
    }

    function test_V3_Pricing_HybridModel_WithBuffer() public {
        // --- Scenario ---
        // Cache Price: $2000 (Set in setUp)
        // Realtime Price: $2000 (Unchanged)
        // Validation Buffer: 10%
        
        // Gas Cost Setup
        uint256 maxCost = 1000; // Wei
        
        PackedUserOperation memory op;
        op.sender = user1;
        // op.paymasterAndData structure for V3:
        // [paymaster(20)] [gasLimits(32)] [operator(20)] [maxRate(32)] ...
        // We construct it manually or just use raw bytes if pure unit test? 
        // validatePaymasterUserOp uses _extractOperator logic.
        // It slices userOp.paymasterAndData[52:72].
        
        bytes memory paymasterAndData = abi.encodePacked(
            address(paymaster), // 20 bytes
            uint256(1000),      // 32 bytes (gasLimits placeholder not strictly parsed here but needed for offset)
            operator1           // 20 bytes (The Operator!)
        );
        // Padding for maxRate? offset 72. 20+32+20 = 72. Perfect.
        // Add maxRate
        paymasterAndData = abi.encodePacked(paymasterAndData, type(uint256).max);
        
        op.paymasterAndData = paymasterAndData;
        
        
        // --- Step 1: Validation (Cache + Buffer) ---
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 valData) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
        
        assertEq(uint160(valData), 0, "Validation should pass");
        
        // Check Operator Balance Deduction
        // Calculation:
        // CostUSD = 1000 * 2000e18 / 1e8 = 20,000,000e10 = 2e7 * 1e10? No.
        // (1000 * 2000e8 * 1e18) / (1e8 * 0.02e18)
        // = (1000 * 2000) / 0.02 = 2,000,000 / 0.02 = 100,000,000
        
        // Buffer = 1.1x => 110,000,000 aPNTs
        
        uint256 expectedPreCharge = 120000000;
        (uint128 balAfter,,,,,,,,,) = paymaster.operators(operator1);
        
        // Initial Deposit: 5000 ether (5000 * 1e18)
        // We charged 1.1 * 1e8 roughly.
        assertEq(5000 ether - balAfter, expectedPreCharge, "Operator balance should reduce by Cost + Buffer");
        
        // --- Step 2: PostOp (Realtime - No Buffer) ---
        // Actual Cost = 1.0x (No Buffer, Price same)
        // Protocol Fee = 10% (Set in contract default)
        
        // We deducted 1.1x Cost.
        // Actual Charge Logic in PostOp:
        // 1. Calculate ActualAPNTs = 100,000,000 (Based on Realtime $2000)
        // 2. Add Protocol Fee (10%) = 100,000,000 * 1.1 = 110,000,000
        
        // Wait! Protocol Fee is 1000 BPS (10%).
        // So Final Charge = Actual * 1.1.
        
        // Check my math:
        // Validation with Buffer = Cost * 1.1
        // PostOp with Fee = Cost * 1.1
        // They are EXACTLY EQUAL if buffer == fee and price is stable.
        
        // So Refund should be 0.
        // Revenue should be 110,000,000.
        
        uint256 actualCostWei = maxCost;
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCostWei, 0);
        
        (uint128 balFinal,,,,,,,,,) = paymaster.operators(operator1);
        
        assertEq(balFinal, balAfter + 10000000, "Refund expected (Buffer was pre-charged but not in final)");
        assertEq(paymaster.protocolRevenue(), 110000000, "Protocol Revenue should be Cost + Fee");
    }

    function test_V3_Pricing_Refund_When_Gas_Low() public {
        // --- Scenario ---
        // Gas Used is HALF of Max.
        // Validation charged MAX * 1.1
        // PostOp charges HALF * 1.1
        // Refund should be huge.
        
        uint256 maxCost = 1000;
        uint256 actualCost = 500;
        
        // Setup UserOp (Same as above)
        bytes memory paymasterAndData = abi.encodePacked(
            address(paymaster), // 20 bytes
            uint256(1000),      // 32 bytes
            operator1,          // 20 bytes
            type(uint256).max   // 32 bytes (maxRate)
        );
        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = paymasterAndData;
        
        // 1. Validate
        vm.prank(address(entryPoint));
        (bytes memory context, ) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
        
        (uint128 balAfterVal,,,,,,,,,) = paymaster.operators(operator1);
        uint256 preCharge = 120000000; // Based on 1000 gas
        assertEq(5000 ether - balAfterVal, preCharge);
        
        // 2. PostOp
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, actualCost, 0);
        
        // 3. Verify
        // Actual Cost Base = 50,000,000
        // With Fee (1.1x) = 55,000,000
        // Refund = 120,000,000 - 55,000,000 = 65,000,000
        
        (uint128 balFinal,,,,,,,,,) = paymaster.operators(operator1);
        assertEq(balFinal, balAfterVal + 65000000, "Should refund unused gas cost + buffer part");
    }
}
