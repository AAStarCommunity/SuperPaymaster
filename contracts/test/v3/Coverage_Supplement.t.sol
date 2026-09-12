// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/core/GTokenStaking.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "src/interfaces/v3/IMySBT.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";
import "src/mocks/MockBLSAggregator.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";

// --- Mocks ---

contract MockGToken is ERC20 {
    constructor() ERC20("MockGToken", "mGT") {
        _mint(msg.sender, 1000000 ether);
    }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}

contract MockSBT is IMySBT {
    function mintForRole(address to, bytes32 role, bytes calldata data) external returns (uint256, bool) { return (1, true); }
    function airdropMint(address to, bytes32 role, bytes calldata data) external returns (uint256, bool) { return (2, true); }
    function getUserSBT(address user) external view returns (uint256 tokenId) { return 0; }
    function getSBTData(uint256) external pure returns (SBTData memory) {
        return SBTData(address(0), address(0), 0, 0);
    }
    function verifyCommunityMembership(address user, address community) external view returns (bool) { return true; }
    function deactivateMembership(address user, address community) external {}
    function deactivateAllMemberships(address) external {}
    function burnSBT(address user) external {}
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

// --- Test Suite ---

contract CoverageSupplementTest is Test {
    Registry registry;
    GTokenStaking staking;
    SuperPaymaster paymaster;

    MockGToken gtoken;
    MockSBT sbt;
    MockEntryPoint entryPoint;
    MockOracle oracle;
    /// @dev SP 5.5.0: operator community token = xPNTs v2 (balance mode). The legacy MockXPNTs
    ///      (burnFromWithOpHash/recordDebt stubs) is gone: those selectors no longer exist in v2.
    xPNTsTokenV2 xpnts;
    MockXPNTsFactory mockFactory;

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

        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(sbt));
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        registry.setStaking(address(staking));
        
        // Config Roles for basic testing (preserve owner from initialize)
        IRegistry.RoleConfig memory commConfig = IRegistry.RoleConfig(10 ether, 1 ether, 10, 2, 1, 10, 500, true, 1 ether, "Comm", owner, 0);
        registry.configureRole(ROLE_COMMUNITY, commConfig);

        IRegistry.RoleConfig memory userConfig = IRegistry.RoleConfig(1 ether, 0.1 ether, 5, 2, 1, 10, 1000, true, 0.1 ether, "User", owner, 0);
        registry.configureRole(ROLE_ENDUSER, userConfig);

        IRegistry.RoleConfig memory pmConfig = IRegistry.RoleConfig(10 ether, 1 ether, 10, 2, 1, 10, 500, true, 1 ether, "Paymaster", owner, 0);
        registry.configureRole(ROLE_PAYMASTER_SUPER, pmConfig);
        
        // Paymaster Setup via UUPS proxy
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint,
            IRegistry(address(registry)),
            address(oracle),
            owner,
            address(gtoken), // APNTS
            treasury,
            3600
        );
        
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // P0-1: Registry now verifies BLS via aggregator. Permissive mock
        // returns true so the rest of this suite isn't blocked on real pairing.
        MockBLSAggregator aggregator = new MockBLSAggregator();
        registry.setBLSAggregator(address(aggregator));

        // Deploy mock factory and register operator token (P1-4 fix)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));

        vm.stopPrank();

        // SP 5.5.0: v2 token for the operator (outside the prank: the test contract owns the
        // protocol-registry bootstrap and becomes the token FACTORY, so it can mint).
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpnts = V2TokenDeployer.newToken(st, operator, operator, address(paymaster), 1e18);
        mockFactory.setToken(operator, address(xpnts));

        // Fund users
        gtoken.mint(user, 1000 ether);
        gtoken.mint(community, 1000 ether);
        gtoken.mint(operator, 1000 ether);
    }

    function _dummyProof() internal pure returns (bytes memory) {
        // Match the new (signerMask, sigG2) ABI used by Registry post-P0-1.
        return abi.encode(uint256(0x7F), new bytes(256));
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
        registry.batchUpdateGlobalReputation(1, users, scores, 1, _dummyProof());
        assertEq(registry.globalReputation(user), 50);
        
        // 2. Increase > maxChange (100) -> Cap at +100
        scores[0] = 500; // Target 500
        registry.batchUpdateGlobalReputation(2, users, scores, 2, _dummyProof());
        assertEq(registry.globalReputation(user), 150); // 50 + 100 maxChange
        
        // 3. Decrease > maxChange (100) -> Cap at -100
        scores[0] = 10; // Target 10
        registry.batchUpdateGlobalReputation(3, users, scores, 3, _dummyProof());
        assertEq(registry.globalReputation(user), 50); // 150 - 100 maxChange
        
        // 4. Stale Epoch (Should ignore)
        scores[0] = 999;
        registry.batchUpdateGlobalReputation(10, users, scores, 2, _dummyProof()); // Epoch 2 <= Last 3
        assertEq(registry.globalReputation(user), 50); // Unchanged
        
        // 5. Length Mismatch check
        uint256[] memory badScores = new uint256[](2);
        vm.expectRevert(Registry.LenMismatch.selector);
        registry.batchUpdateGlobalReputation(4, users, badScores, 4, _dummyProof());
        
        // 6. Unauthorized
        vm.stopPrank();
        vm.startPrank(user);
        vm.expectRevert(Registry.UnauthorizedSource.selector);
        registry.batchUpdateGlobalReputation(5, users, scores, 5, _dummyProof());
        vm.stopPrank();
    }
    
    function test_Registry_RegisterRoleSelf() public {
        vm.startPrank(community);
        gtoken.approve(address(staking), 100 ether);
        
        bytes memory data = abi.encode(Registry.CommunityRoleData("Comm1", "e1", 10 ether));
        registry.registerRole(ROLE_COMMUNITY, community, data);
        
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
        
        bytes memory userData = abi.encode(Registry.EndUserRoleData(community, 1 ether));
        
        registry.safeMintForRole(ROLE_ENDUSER, user, userData);
        
        assertTrue(registry.hasRole(ROLE_ENDUSER, user));
        vm.stopPrank();
    }
    
    function test_Registry_NamingCollisions() public {
        vm.startPrank(community);
        gtoken.approve(address(staking), 100 ether);
        bytes memory data = abi.encode(Registry.CommunityRoleData("UniqueName", "", 10 ether));
        registry.registerRole(ROLE_COMMUNITY, community, data);
        vm.stopPrank();
        
        // Try second community with same name
        address comm2 = address(0x201);
        gtoken.mint(comm2, 100 ether);
        vm.startPrank(comm2);
        gtoken.approve(address(staking), 100 ether);
        
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidParam.selector, "Name taken"));
        registry.registerRole(ROLE_COMMUNITY, comm2, data);
        
        // Try empty name
        bytes memory emptyData = abi.encode(Registry.CommunityRoleData("", "", 10 ether));
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidParam.selector, "Name required"));
        registry.registerRole(ROLE_COMMUNITY, comm2, emptyData);
        vm.stopPrank();
    }
    
    function test_Registry_InvalidEndUserCommunity() public {
        vm.startPrank(user);
        gtoken.approve(address(staking), 100 ether);
        // Point to non-existent community
        bytes memory data = abi.encode(Registry.EndUserRoleData(address(0xDead), 1 ether));
        
        vm.expectRevert(abi.encodeWithSelector(Registry.InvalidParam.selector, "Invalid community"));
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
        IRegistry.RoleConfig memory currentConfig = registry.getRoleConfig(ROLE_ENDUSER);
        currentConfig.minStake = 1 ether;
        currentConfig.ticketPrice = 0.1 ether;
        currentConfig.exitFeePercent = 2000; // 20% fee
        currentConfig.minExitFee = 0.1 ether;
        registry.configureRole(ROLE_ENDUSER, currentConfig);
        vm.stopPrank();
        
        // User joins
        vm.startPrank(user);
        // Need community first for EndUser? Yes.
        // Shortcut: Use KMS role for simpler testing logic if needed, but EndUser is fine if we mock community check.
        // Actually, let's use KMS role.
        IRegistry.RoleConfig memory kmsConfig = IRegistry.RoleConfig(10 ether, 1 ether, 10, 2, 1, 10, 2000, true, 1 ether, "KMS", owner, 0);
        vm.stopPrank();
        vm.startPrank(owner);
        registry.configureRole(keccak256("KMS"), kmsConfig);
        vm.stopPrank();
        
        vm.startPrank(user);
        bytes memory data = abi.encode(uint256(10 ether));
        registry.registerRole(keccak256("KMS"), user, data);
        
        // Exit
        uint256 balBefore = gtoken.balanceOf(user);
        bytes32 kmsRole = keccak256("KMS");
        vm.stopPrank();
        vm.startPrank(owner);
        IRegistry.RoleConfig memory kmsCfg = registry.getRoleConfig(kmsRole);
        kmsCfg.roleLockDuration = 0;
        registry.configureRole(kmsRole, kmsCfg);
        vm.stopPrank();
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
        registry.configureRole(TEST_ROLE, IRegistry.RoleConfig(10 ether, 0, 0,0,0,0, 0, true, 0, "Test", owner, 0));
        vm.stopPrank();
        
        vm.startPrank(user);
        registry.registerRole(TEST_ROLE, user, abi.encode(uint256(10 ether)));
        vm.stopPrank();
        
        // Slash amount = 3 ether
        vm.startPrank(owner);
        staking.slash(user, 3 ether, "Reason");
        
        // Verify info
        IGTokenStaking.StakeInfo memory info = staking.getStakeInfo(user, TEST_ROLE);
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
    
    // --- SuperPaymaster Tests ---
    
    function _pmd() internal view returns (bytes memory) {
        // SP 5.5.0 layout: [pm 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
        return V2TokenDeployer.pmd(address(paymaster), uint128(100), uint128(200000), operator, type(uint256).max, address(xpnts), 0);
    }

    function _registerAndConfigureOperator() internal {
        vm.startPrank(operator);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_COMMUNITY, operator, abi.encode(Registry.CommunityRoleData("Op", "", 10 ether)));
        registry.registerRole(keccak256("PAYMASTER_SUPER"), operator, abi.encode(uint256(50 ether)));
        paymaster.configureOperator(address(xpnts), treasury);
        vm.stopPrank();
    }

    function test_Paymaster_Validation_Failures() public {
        // Setup userOp
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _pmd();

        // 1. Operator Not Registered
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 valData) = paymaster.validatePaymasterUserOp(op, keccak256("v1"), 1000);
        // Validation data failure (sig fail = true)
        assertEq(valData & 1, 1, "Should fail sig");

        // Register + configure operator (5.5.0: configureOperator requires an xPNTs v2 token)
        _registerAndConfigureOperator();

        // Sync SBT Status for Operator
        vm.prank(address(registry));
        paymaster.updateSBTStatus(operator, true);

        // 2. User Not Verified
        // User has no role
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, keccak256("v2"), 1000);
        assertEq(valData & 1, 1, "Should fail sig (user unverified)");

        // Sync SBT status for User
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);

        // Register User in Registry
        vm.startPrank(user);
        gtoken.approve(address(staking), 100 ether);
        bytes memory uData = abi.encode(Registry.EndUserRoleData(operator, 1 ether));
        registry.registerRole(ROLE_ENDUSER, user, uData);
        vm.stopPrank();

        // 5.5.0: the legacy `setCreditTier(1, ...)` precondition is gone -- the SP no longer
        // consults the Registry credit tier in validation (`_creditExceeded` removed). The user
        // pays from escrowed xPNTs v2 instead, so fund the user.
        IxPNTsV2Admin(address(xpnts)).mint(user, 1000 ether);

        // 3. Operator Config: Low Balance -- operator has not deposited aPNTs yet (asserted now;
        //    the pre-5.5.0 version of this step had no assertion). APNTS_TOKEN is already the
        //    mock gToken from initialize, so no setAPNTsToken (now a 7-day queue, P0-9) is needed.
        assertEq(paymaster.APNTS_TOKEN(), address(gtoken));
        vm.prank(address(entryPoint));
        // D3-M: low-level call so an insolvent operator that makes validation REVERT (e.g. an
        // unchecked debit underflow) is a named failure, not an anonymous panic.
        (bool vOk, bytes memory vRet) =
            address(paymaster).call(abi.encodeCall(paymaster.validatePaymasterUserOp, (op, keccak256("v3"), 1000)));
        assertTrue(vOk, "insolvent operator must fail closed (sigFail), not revert");
        (ctx, valData) = abi.decode(vRet, (bytes, uint256));
        assertEq(valData & 1, 1, "Should fail sig (operator has no aPNTs deposit)");
        assertEq(xpnts.lockedOf(user), 0, "solvency is checked BEFORE touching the token");

        vm.startPrank(operator);
        gtoken.mint(operator, 1000 ether);
        gtoken.approve(address(paymaster), 1000 ether);
        paymaster.depositFor(operator, 100 ether);
        vm.stopPrank();

        // 3b. R-2: an unfunded user with credit OFF (the v2 default) is NOT sponsored.
        uint256 snap = vm.snapshot();
        vm.prank(user);
        xpnts.transfer(address(0xdead), 1000 ether);
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, keccak256("v3b"), 1000);
        assertEq(valData & 1, 1, "Should fail sig (no xPNTs, credit OFF)");
        assertEq(xpnts.creditReservedOf(user), 0, "no credit fallback when policy is OFF");
        assertTrue(vm.revertTo(snap), "snapshot restored");

        // Now success (BALANCE mode: user xPNTs escrowed at validation)
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, keccak256("v4"), 1000);
        assertEq(uint160(valData), 0, "Should succeed");
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        assertEq(c.mode, 1, "BALANCE mode");
        assertEq(xpnts.lockedOf(user), c.a0, "escrow == a0 at rate 1:1");

        // 4. Paused Operator
        vm.prank(owner);
        paymaster.setOperatorPaused(operator, true);

        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, keccak256("v5"), 1000);
        assertEq(valData & 1, 1, "Should fail paused");

        vm.prank(owner);
        paymaster.setOperatorPaused(operator, false);

        // Control: the same op validates again once unpaused (the pause was the only cause).
        vm.prank(address(entryPoint));
        (ctx, valData) = paymaster.validatePaymasterUserOp(op, keccak256("v6"), 1000);
        assertEq(uint160(valData), 0, "Should succeed after unpause");
    }

    /// @notice 5.5.0 postOp. The pre-5.5.0 test fed a V3.3 6-field context in opReverted mode to a
    ///         mock token (burnFromWithOpHash stub) and only asserted "no revert". Migrated to:
    ///         (a) T-R14-04 / I8 -- a real validation context settled in opReverted mode: the user
    ///             still pays for gas (xPNTs burned), the escrow is cleared, the in-flight a0 is
    ///             resolved and the operator is refunded exactly a0 - charge (R10-M1b);
    ///         (b) a legacy V3.3 context is no longer silently accepted (OpCtx decode reverts);
    ///         (c) an empty context still returns (unchanged).
    function test_Paymaster_PostOp_Revert() public {
        _registerAndConfigureOperator();
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);
        IxPNTsV2Admin(address(xpnts)).mint(user, 1000 ether);
        vm.startPrank(operator);
        gtoken.mint(operator, 1000 ether);
        gtoken.approve(address(paymaster), 1000 ether);
        paymaster.depositFor(operator, 1000 ether);
        vm.stopPrank();

        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _pmd();
        bytes32 h = keccak256("postop-reverted");

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 vd) = paymaster.validatePaymasterUserOp(op, h, 0.001 ether);
        assertEq(uint160(vd), 0, "validation ok");
        (uint128 opMid,,,,,,,,) = paymaster.operators(operator);
        uint256 userBefore = xpnts.balanceOf(user);
        uint256 revBefore = paymaster.protocolRevenue();

        // (a) opReverted still settles.
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode(uint8(PostOpMode.opReverted)), context, 1e12, 1 gwei);
        uint256 burned = userBefore - xpnts.balanceOf(user);
        assertGt(burned, 0, "user pays for gas even when execution reverted (T-R14-04)");
        assertEq(xpnts.lockedOf(user), 0, "escrow cleared");
        assertEq(xpnts.debts(user), 0, "balance mode creates no debt");
        (address f, uint256 a0) = paymaster.inflightOf(h);
        assertEq(f, address(0), "in-flight cleared");
        assertEq(a0, 0);
        uint256 charge = paymaster.protocolRevenue() - revBefore;
        assertEq(burned, charge, "rate 1:1: burned xPNTs == aPNTs charge");
        SuperPaymaster.OpCtx memory c = abi.decode(context, (SuperPaymaster.OpCtx));
        (uint128 opAfter,,,,,,,,) = paymaster.operators(operator);
        assertEq(uint256(opAfter) - uint256(opMid), c.a0 - charge, "operator refunded a0 - charge");

        // (b) legacy V3.3 layout (token, estimatedXPNTs, user, initialAPNTs, userOpHash, operator)
        bytes memory legacy = abi.encode(address(xpnts), uint256(100), user, uint256(100), bytes32(0), operator);
        vm.prank(address(entryPoint));
        vm.expectRevert(bytes("")); // abi.decode of a 6-word blob as the 11-word OpCtx: empty revert data
        paymaster.postOp(IPaymaster.PostOpMode(uint8(PostOpMode.opReverted)), legacy, 1000, 1000);

        // (c) Call with empty context (should return)
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode(uint8(PostOpMode.opSucceeded)), "", 1000, 1000);
    }
    
    /*
    function test_Paymaster_Deposit_NotRegistered() public {
        vm.startPrank(user); // User is not operator
        gtoken.approve(address(paymaster), 100 ether);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
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
        registry.registerRole(ROLE_COMMUNITY, operator, abi.encode(Registry.CommunityRoleData("Op2", "", 10 ether)));
        // Step 2: Register as Paymaster Super
        registry.registerRole(ROLE_PAYMASTER_SUPER, operator, "");
        vm.startPrank(operator);
        
        // Deposit For
        gtoken.mint(operator, 1000 ether);
        gtoken.approve(address(paymaster), 1000 ether);
        paymaster.depositFor(operator, 100 ether);
        
        // Verify
        (uint128 bal,,,,,,,,) = paymaster.operators(operator);
        assertEq(bal, 100 ether);
        vm.stopPrank();
    }
}
