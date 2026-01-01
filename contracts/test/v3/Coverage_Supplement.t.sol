// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "src/interfaces/v3/IMySBTV3.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";
import "src/modules/validators/BLSValidator.sol";

// --- Mocks ---

contract MockGToken is ERC20 {
    constructor() ERC20("MockGToken", "mGT") {
        _mint(msg.sender, 1000000 ether);
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}

contract MockSBT is IMySBTV3 {
    function mint(address to, uint256 id, uint256 amount, bytes memory data) external {}
    function burn(address from, uint256 id, uint256 amount) external {}
    function mintForRole(address to, bytes32 role, bytes calldata data) external returns (uint256, bool) { return (1, true); }
    function airdropMint(address to, bytes32 role, bytes calldata data) external returns (uint256, bool) { return (2, true); }
    function deactivateMembership(address user, address community) external {}
    function setRegistry(address) external {}
    function updateScore(address, uint256) external {}
    function getScore(address) external view returns (uint256) { return 0; }
    function getUserSBT(address user) external view returns (uint256 tokenId) { return 0; }
    function recordActivity(address user) external {}
    function verifyCommunityMembership(address user, address community) external view returns (bool) { return true; }

    function balanceOf(address account, uint256 id) external view returns (uint256) { return 0; }
    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids) external view returns (uint256[] memory) { return new uint256[](accounts.length); }
    function setApprovalForAll(address operator, bool approved) external {}
    function isApprovedForAll(address account, address operator) external view returns (bool) { return false; }
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external {}
    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external {}
    function supportsInterface(bytes4 interfaceId) external view returns (bool) { return true; }
}

contract MockEntryPoint is IEntryPoint {
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

contract MockOracle is AggregatorV3Interface {
    int256 public price;
    constructor(int256 _price) { price = _price; }
    function setPrice(int256 _price) external { price = _price; }
    function decimals() external view returns (uint8) { return 8; }
    function description() external view returns (string memory) { return "Mock"; }
    function version() external view returns (uint256) { return 1; }
    function getRoundData(uint80 _roundId) external view returns (uint80, int256, uint256, uint256, uint80) { return (0, price, 0, block.timestamp, 0); }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) { 
        return (1, price, block.timestamp, block.timestamp, 1); 
    }
}

contract MockXPNTs {
    function burnFromWithOpHash(address from, uint256 amount, bytes32 userOpHash) external {} 
    function exchangeRate() external view returns (uint256) { return 1e18; }
    function getDebt(address user) external view returns (uint256) { return 0; }
    function recordDebt(address user, uint256 amount) external {}
}

// --- Test Suite ---

contract CoverageSupplementTest is Test {
    Registry registry;
    GTokenStaking staking;
    SuperPaymasterV3 paymaster;
    
    MockGToken gtoken;
    MockSBT sbt;
    MockEntryPoint entryPoint;
    MockOracle oracle;
    MockXPNTs xpnts;
    
    address owner = address(1);
    address treasury = address(2);
    address user = address(0x100);
    address community = address(0x200);
    address operator = address(0x300);
    
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    function setUp() public {
        vm.startPrank(owner);
        gtoken = new MockGToken();
        sbt = new MockSBT();
        entryPoint = new MockEntryPoint();
        oracle = new MockOracle(2000e8); // $2000 ETH
        xpnts = new MockXPNTs();
        
        staking = new GTokenStaking(address(gtoken), treasury);
        registry = new Registry(address(gtoken), address(staking), address(sbt));
        staking.setRegistry(address(registry));
        
        // Config Roles for basic testing
        IRegistryV3.RoleConfig memory commConfig = IRegistryV3.RoleConfig(10 ether, 1 ether, 10, 2, 1, 10, 500, 1 ether, true, "Comm");
        registry.configureRole(ROLE_COMMUNITY, commConfig);
        
        IRegistryV3.RoleConfig memory userConfig = IRegistryV3.RoleConfig(1 ether, 0.1 ether, 5, 2, 1, 10, 1000, 0.1 ether, true, "User");
        registry.configureRole(ROLE_ENDUSER, userConfig);

        IRegistryV3.RoleConfig memory pmConfig = IRegistryV3.RoleConfig(10 ether, 1 ether, 10, 2, 1, 10, 500, 1 ether, true, "Paymaster");
        registry.configureRole(ROLE_PAYMASTER_SUPER, pmConfig);
        
        // Paymaster Setup
        paymaster = new SuperPaymasterV3(
            entryPoint,
            owner,
            registry,
            address(gtoken), // APNTS
            address(oracle),
            treasury
        );
        
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Set BLS Validator
        BLSValidator validator = new BLSValidator();
        registry.setBLSValidator(address(validator));

        vm.stopPrank();
        
        // Fund users
        gtoken.mint(user, 1000 ether);
        gtoken.mint(community, 1000 ether);
        gtoken.mint(operator, 1000 ether);
    }
    
    function _dummyProof() internal pure returns (bytes memory) {
        return abi.encode(new bytes(96), new bytes(192), new bytes(192), uint256(0xF));
    }
    
    // --- Registry Tests ---
    
    function test_Registry_BatchUpdate_Strategies() public {
        vm.startPrank(owner);
        registry.setReputationSource(owner, true);
        
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory scores = new uint256[](1);
        
        // Mock BLS
        vm.mockCall(address(0x11), "", abi.encode(uint256(1)));

        // 1. Initial Set
        scores[0] = 50;
        registry.batchUpdateGlobalReputation(users, scores, 1, _dummyProof());
        assertEq(registry.globalReputation(user), 50);
        
        // 2. Increase > maxChange (100) -> Cap at +100
        scores[0] = 500; // Target 500
        registry.batchUpdateGlobalReputation(users, scores, 2, _dummyProof());
        assertEq(registry.globalReputation(user), 150); // 50 + 100 maxChange
        
        // 3. Decrease > maxChange (100) -> Cap at -100
        scores[0] = 10; // Target 10
        registry.batchUpdateGlobalReputation(users, scores, 3, _dummyProof());
        assertEq(registry.globalReputation(user), 50); // 150 - 100 maxChange
        
        // 4. Stale Epoch (Should ignore)
        scores[0] = 999;
        registry.batchUpdateGlobalReputation(users, scores, 2, _dummyProof()); // Epoch 2 <= Last 3
        assertEq(registry.globalReputation(user), 50); // Unchanged
        
        // 5. Length Mismatch check
        uint256[] memory badScores = new uint256[](2);
        vm.expectRevert("Length mismatch");
        registry.batchUpdateGlobalReputation(users, badScores, 4, _dummyProof());
        
        // 6. Unauthorized
        vm.stopPrank();
        vm.startPrank(user);
        vm.expectRevert("Unauthorized Reputation Source");
        registry.batchUpdateGlobalReputation(users, scores, 5, _dummyProof());
        vm.stopPrank();
    }
    
    function test_Registry_RegisterRoleSelf() public {
        vm.startPrank(community);
        gtoken.approve(address(staking), 100 ether);
        
        bytes memory data = abi.encode(Registry.CommunityRoleData("Comm1", "e1", "w1", "d1", "l1", 10 ether));
        registry.registerRoleSelf(ROLE_COMMUNITY, data);
        
        assertTrue(registry.hasRole(ROLE_COMMUNITY, community));
        vm.stopPrank();
    }
    
    function test_Registry_SafeMintForRole_Logic() public {
        // Register community first
        test_Registry_RegisterRoleSelf();
        
        vm.startPrank(community);
        // Mint for user
        gtoken.mint(community, 100 ether); // Extra funds for burning
        gtoken.approve(address(staking), 100 ether);
        
        bytes memory userData = abi.encode(Registry.EndUserRoleData(address(1), community, "Av", "Ens", 1 ether));
        
        registry.safeMintForRole(ROLE_ENDUSER, user, userData);
        
        assertTrue(registry.hasRole(ROLE_ENDUSER, user));
        vm.stopPrank();
    }
    
    function test_Registry_NamingCollisions() public {
        vm.startPrank(community);
        gtoken.approve(address(staking), 100 ether);
        bytes memory data = abi.encode(Registry.CommunityRoleData("UniqueName", "", "", "", "", 10 ether));
        registry.registerRole(ROLE_COMMUNITY, community, data);
        vm.stopPrank();
        
        // Try second community with same name
        address comm2 = address(0x201);
        gtoken.mint(comm2, 100 ether);
        vm.startPrank(comm2);
        gtoken.approve(address(staking), 100 ether);
        
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidParameter.selector, "Name taken"));
        registry.registerRole(ROLE_COMMUNITY, comm2, data);
        
        // Try empty name
        bytes memory emptyData = abi.encode(Registry.CommunityRoleData("", "", "", "", "", 10 ether));
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidParameter.selector, "Name required"));
        registry.registerRole(ROLE_COMMUNITY, comm2, emptyData);
        vm.stopPrank();
    }
    
    function test_Registry_InvalidEndUserCommunity() public {
        vm.startPrank(user);
        gtoken.approve(address(staking), 100 ether);
        // Point to non-existent community
        bytes memory data = abi.encode(Registry.EndUserRoleData(address(1), address(0xDead), "", "", 1 ether));
        
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidParameter.selector, "Invalid community"));
        registry.registerRole(ROLE_ENDUSER, user, data);
        vm.stopPrank();
    }
    
    // --- GTokenStaking Tests ---
    
    function test_Staking_ExitFee_Advanced() public {
        // Register user
        vm.startPrank(user);
        gtoken.approve(address(staking), 100 ether);
        // Register generic/Custom role manually to avoid Registry checks?
        // Let's use Registry normally.
        // Setup: Admin sets 50% exit fee for ENDUSER
        vm.stopPrank();
        vm.startPrank(owner);
        registry.adminConfigureRole(ROLE_ENDUSER, 1 ether, 0.1 ether, 2000, 0.1 ether); // 20% fee
        vm.stopPrank();
        
        // User joins
        vm.startPrank(user);
        // Need community first for EndUser? Yes.
        // Shortcut: Use KMS role for simpler testing logic if needed, but EndUser is fine if we mock community check.
        // Actually, let's use KMS role.
        IRegistryV3.RoleConfig memory kmsConfig = IRegistryV3.RoleConfig(10 ether, 1 ether, 10, 2, 1, 10, 2000, 1 ether, true, "KMS");
        vm.stopPrank();
        vm.startPrank(owner);
        registry.configureRole(registry.ROLE_KMS(), kmsConfig);
        vm.stopPrank();
        
        vm.startPrank(user);
        bytes memory data = abi.encode(uint256(10 ether));
        registry.registerRole(registry.ROLE_KMS(), user, data);
        
        // Exit
        uint256 balBefore = gtoken.balanceOf(user);
        bytes32 kmsRole = registry.ROLE_KMS();
        vm.stopPrank();
        vm.prank(owner);
        registry.setRoleLockDuration(kmsRole, 0);
        vm.startPrank(user);
        registry.exitRole(kmsRole);
        uint256 balAfter = gtoken.balanceOf(user);
        
        // 10 ether stake. 20% fee = 2 ether.
        // Refund should be 8 ether.
        assertEq(balAfter - balBefore, 8 ether);
        vm.stopPrank();
    }
    
    function test_Staking_Slash_Logic() public {
        // Enable slasher
        vm.startPrank(owner);
        staking.setAuthorizedSlasher(owner, true);
        vm.stopPrank();
        
        // User stake
        vm.startPrank(user);
        gtoken.approve(address(staking), 100 ether);
        // Mock simple role
        bytes32 TEST_ROLE = keccak256("TEST");
        vm.stopPrank();
        vm.startPrank(owner);
        registry.createNewRole(TEST_ROLE, IRegistryV3.RoleConfig(10 ether, 0, 0,0,0,0, 0, 0, true, "Test"), owner);
        vm.stopPrank();
        
        vm.startPrank(user);
        registry.registerRole(TEST_ROLE, user, abi.encode(uint256(10 ether)));
        vm.stopPrank();
        
        // Slash amount = 3 ether
        vm.startPrank(owner);
        staking.slash(user, 3 ether, "Reason");
        
        // Verify info
        IGTokenStakingV3.StakeInfo memory info = staking.getStakeInfo(user, TEST_ROLE);
        assertEq(info.slashedAmount, 3 ether);
        assertEq(info.amount, 7 ether); // 10 - 3
        
        // Slash > Available (Try to slash 8 more, total 11 > 10)
        // Should cap at 7 (already reduced from 10 to 7)
        uint256 slashed = staking.slash(user, 8 ether, "Overflow");
        assertEq(slashed, 7 ether);
        
        info = staking.getStakeInfo(user, TEST_ROLE);
        assertEq(info.slashedAmount, 10 ether); 
        assertEq(info.amount, 0 ether); 
        
        // Unlock
        vm.stopPrank();
        vm.startPrank(user);
        // Expect 0 refund as all slashed
        uint256 balBefore = gtoken.balanceOf(user);
        registry.exitRole(TEST_ROLE);
        uint256 balAfter = gtoken.balanceOf(user);
        assertEq(balAfter - balBefore, 0);
        vm.stopPrank();
    }
    
    // --- SuperPaymasterV3 Tests ---
    
    function test_Paymaster_Validation_Failures() public {
        // Setup userOp
        PackedUserOperation memory op;
        op.sender = user;
        // Construct paymasterAndData: [paymaster(20)] [gasLimits(32)] [operator(20)]
        bytes memory pmData = abi.encodePacked(address(paymaster), uint128(100), uint128(100), address(operator));
        op.paymasterAndData = pmData;
        
        // 1. Operator Not Registered
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 valData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);
        // Validation data failure (sig fail = true)
        // ValidationData: (sigFailed << 160)
        assertEq(valData & 1, 1, "Should fail sig");
        
        // Register Operator
        vm.startPrank(operator);
        gtoken.approve(address(staking), 100 ether);
        bytes memory opData = abi.encode(Registry.CommunityRoleData("Op", "", "", "", "", 10 ether));
        registry.registerRole(ROLE_COMMUNITY, operator, opData);
        // Also register as SuperPaymaster
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), operator, abi.encode(uint256(50 ether)));
        // Config Operator
        paymaster.configureOperator(address(xpnts), treasury, 1e18);
        vm.stopPrank();
        
        // 2. User Not Verified
        // User has no role
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);
        assertEq(valData & 1, 1, "Should fail sig (user unverified)");
        
        // Register User
        vm.startPrank(user);
        gtoken.approve(address(staking), 100 ether);
        bytes memory uData = abi.encode(Registry.EndUserRoleData(address(123), operator, "", "", 1 ether));
        registry.registerRole(ROLE_ENDUSER, user, uData);
        vm.stopPrank();
        
        // 3. Operator Config: Low Balance
        // Operator hasn't deposited aPNTs
        // BasePaymaster checks deposit for Paymaster, checking operator balance within Paymaster
        
        // Deposit aPNTs for Operator
        // Use notifyDeposit to simulate
        // Need to change APNTS to MockToken first to use notifyDeposit easily or assume setup
        vm.prank(owner);
        paymaster.setAPNTsToken(address(gtoken)); // Reuse mockGToken as aPNTs
        
        vm.startPrank(operator);
        gtoken.mint(operator, 1000 ether);
        gtoken.approve(address(paymaster), 1000 ether);
        paymaster.depositFor(operator, 100 ether);
        vm.stopPrank();
        
        // Now success
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);
        assertEq(valData, 0, "Should succeed");
        
        // 4. Paused Operator
        vm.prank(owner);
        paymaster.setOperatorPaused(operator, true);
        
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, bytes32(0), 1000);
        assertEq(valData & 1, 1, "Should fail paused");
        
        vm.prank(owner);
        paymaster.setOperatorPaused(operator, false);
    }
    
    function test_Paymaster_PostOp_Revert() public {
        // Setup a valid context
        address token = address(xpnts);
        uint256 xPNTsAmount = 100;
        address u = user;
        uint256 aPNTsAmount = 100;
        
        // V3.3 layout: (token, estimatedXPNTs, user, initialAPNTs, userOpHash, operator)
        bytes memory context = abi.encode(token, xPNTsAmount, u, aPNTsAmount, bytes32(0), operator);
        
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode(uint8(PostOpMode.opReverted)), context, 1000, 1000);
        
        // Call with empty context (should return)
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode(uint8(PostOpMode.opSucceeded)), "", 1000, 1000);
    }
    
    /*
    function test_Paymaster_Deposit_NotRegistered() public {
        vm.startPrank(user); // User is not operator
        gtoken.approve(address(paymaster), 100 ether);
        vm.expectRevert(SuperPaymasterV3.Unauthorized.selector);
        paymaster.addStake{value: 1 ether}(1000);
        
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // 5. Configure Operator (Must be done by operator)
        vm.stopPrank();
        vm.startPrank(operator);
        paymaster.depositFor(user, 10 ether);
        vm.stopPrank();
    }
    */
    
    function test_Paymaster_DepositFor_Refill() public {
        vm.startPrank(operator);
        // Setup Operator
        gtoken.approve(address(staking), 100 ether);
        // Step 1: Register as Community
        registry.registerRole(ROLE_COMMUNITY, operator, abi.encode(Registry.CommunityRoleData("Op2", "", "", "", "", 10 ether)));
        // Step 2: Register as Paymaster Super
        registry.registerRole(ROLE_PAYMASTER_SUPER, operator, "");
        vm.startPrank(operator);
        
        // Deposit For
        gtoken.mint(operator, 1000 ether);
        gtoken.approve(address(paymaster), 1000 ether);
        paymaster.depositFor(operator, 100 ether);
        
        // Verify
        (uint128 bal,,,,,,,,,) = paymaster.operators(operator);
        assertEq(bal, 100 ether);
        vm.stopPrank();
    }
}
