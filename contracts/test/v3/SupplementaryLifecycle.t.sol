// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/ISuperPaymaster.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

// ============================================
// Mocks
// ============================================

contract MockGTokenSL is ERC20 {
    constructor() ERC20("GToken", "GT") { _mint(msg.sender, 1_000_000 ether); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(uint256 amount) external { _burn(msg.sender, amount); }
}

contract MockEntryPointSL {
    mapping(address => uint256) public balanceOf;
    function depositTo(address account) external payable { balanceOf[account] += msg.value; }
    function withdrawTo(address payable, uint256) external {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
}

contract MockPriceFeedSL {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

// V2 for upgradeToAndCall + reinitializer testing
contract RegistryV2Reinit is Registry {
    uint256 public migrationFlag;

    function version() external pure override returns (string memory) {
        return "Registry-5.0.0-test";
    }

    function reinitializeV2(uint256 _flag) external reinitializer(2) {
        migrationFlag = _flag;
    }
}

contract SuperPaymasterV2Reinit is SuperPaymaster {
    uint256 public migrationFlag;

    constructor(
        IEntryPoint _ep, IRegistry _reg, address _feed
    ) SuperPaymaster(_ep, _reg, _feed) {}

    function version() external pure override returns (string memory) {
        return "SuperPaymaster-5.0.0-test";
    }

    function reinitializeV2(uint256 _flag) external reinitializer(2) {
        migrationFlag = _flag;
    }
}

// ============================================
// Test Suite
// ============================================

contract SupplementaryLifecycleTest is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    MockGTokenSL gtoken;
    MockEntryPointSL entryPoint;
    MockPriceFeedSL priceFeed;
    SuperPaymaster superPaymaster;

    address owner = address(0xAA);
    address dao = address(0xAA); // same as owner for test convenience
    address treasury = address(0xBB);
    address communityUser = address(0x100);
    address endUser = address(0x200);
    address operator = address(0x300);

    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new MockGTokenSL();
        entryPoint = new MockEntryPointSL();
        priceFeed = new MockPriceFeedSL();

        // Scheme B deployment
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);

        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

        // Deploy SuperPaymaster proxy
        superPaymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(0), // no aPNTs for now
            treasury,
            3600
        );
        registry.setSuperPaymaster(address(superPaymaster));

        // Fund test accounts
        gtoken.mint(communityUser, 10_000 ether);
        gtoken.mint(endUser, 1_000 ether);
        gtoken.mint(operator, 10_000 ether);

        vm.stopPrank();
    }

    // ====================================
    // D.1#3: Registry Role Registration Lifecycle
    // ====================================

    function _registerCommunity(address user, string memory name) internal {
        vm.startPrank(user);
        gtoken.approve(address(staking), 100 ether);
        bytes memory roleData = abi.encode(
            Registry.CommunityRoleData({
                name: name,
                ensName: string.concat(name, ".eth"),
                website: "https://test.com",
                description: "Test Community",
                logoURI: "ipfs://logo",
                stakeAmount: 30 ether
            })
        );
        registry.registerRole(ROLE_COMMUNITY, user, roleData);
        vm.stopPrank();
    }

    function test_RoleLifecycle_RegisterCommunityThenExit() public {
        _registerCommunity(communityUser, "TestDAO");

        // Verify registration
        assertTrue(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertEq(staking.getLockedStake(communityUser, ROLE_COMMUNITY), 30 ether);
        assertEq(registry.communityByName("TestDAO"), communityUser);
        assertTrue(sbt.userToSBT(communityUser) != 0, "SBT should be minted");

        // Warp past lock duration (30 days default)
        vm.warp(block.timestamp + 31 days);

        // Exit role
        uint256 balBefore = gtoken.balanceOf(communityUser);
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // Verify cleanup
        assertFalse(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertEq(staking.getLockedStake(communityUser, ROLE_COMMUNITY), 0);
        assertEq(registry.communityByName("TestDAO"), address(0), "Community name should be cleared");
        assertTrue(gtoken.balanceOf(communityUser) > balBefore, "Should receive refund");
    }

    function test_RoleLifecycle_SuperPaymasterRole() public {
        // Must have COMMUNITY first
        _registerCommunity(communityUser, "SuperDAO");

        // Register as PAYMASTER_SUPER
        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        assertTrue(registry.hasRole(ROLE_PAYMASTER_SUPER, communityUser));
        assertEq(staking.getLockedStake(communityUser, ROLE_PAYMASTER_SUPER), 50 ether);

        // User should have 2 roles
        bytes32[] memory roles = registry.getUserRoles(communityUser);
        assertEq(roles.length, 2);
    }

    function test_RoleLifecycle_ExitWithLockDuration_Reverts() public {
        _registerCommunity(communityUser, "LockedDAO");

        // Try to exit immediately (lock = 30 days)
        vm.prank(communityUser);
        vm.expectRevert(Registry.LockNotMet.selector);
        registry.exitRole(ROLE_COMMUNITY);
    }

    function test_RoleLifecycle_MultipleRoles_ExitOne_KeepSBT() public {
        _registerCommunity(communityUser, "MultiDAO");

        // Add PAYMASTER_SUPER role
        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        uint256 sbtId = sbt.userToSBT(communityUser);
        assertTrue(sbtId != 0);

        // Exit COMMUNITY only (warp past lock)
        vm.warp(block.timestamp + 31 days);
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // SBT should still exist (user still has PAYMASTER_SUPER role)
        assertFalse(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertTrue(registry.hasRole(ROLE_PAYMASTER_SUPER, communityUser));
        assertTrue(sbt.userToSBT(communityUser) != 0, "SBT should remain for remaining role");
    }

    function test_RoleLifecycle_ExitAllRoles_BurnSBT() public {
        _registerCommunity(communityUser, "BurnDAO");

        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);

        // Exit all roles
        vm.startPrank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);
        registry.exitRole(ROLE_PAYMASTER_SUPER);
        vm.stopPrank();

        // SBT should be burned
        assertFalse(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertFalse(registry.hasRole(ROLE_PAYMASTER_SUPER, communityUser));
        assertEq(sbt.userToSBT(communityUser), 0, "SBT should be burned after all roles exit");
        assertFalse(superPaymaster.sbtHolders(communityUser), "SBT status should be false in SuperPaymaster");
    }

    function test_RoleLifecycle_SafeMintForRole() public {
        // ENDUSER safeMintForRole requires caller to be a registered COMMUNITY
        _registerCommunity(communityUser, "SafeMintDAO");

        // communityUser (registered community) pays stake for endUser
        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);

        bytes memory endUserData = abi.encode(
            Registry.EndUserRoleData({
                account: endUser,
                community: communityUser,
                avatarURI: "ipfs://avatar",
                ensName: "testuser.eth",
                stakeAmount: 0
            })
        );
        registry.safeMintForRole(ROLE_ENDUSER, endUser, endUserData);
        vm.stopPrank();

        assertTrue(registry.hasRole(ROLE_ENDUSER, endUser));
        assertTrue(superPaymaster.sbtHolders(endUser), "SBT status should be true in SuperPaymaster");
    }

    function test_RoleLifecycle_DynamicRoleManagement() public {
        // Create a new custom role via configureRole
        bytes32 ROLE_CUSTOM = keccak256("CUSTOM_ROLE");
        vm.startPrank(owner);
        IRegistry.RoleConfig memory customConfig = IRegistry.RoleConfig({
            minStake: 10 ether,
            entryBurn: 1 ether,
            slashThreshold: 5,
            slashBase: 1,
            slashInc: 1,
            slashMax: 5,
            exitFeePercent: 500,
            isActive: true,
            minExitFee: 0.5 ether,
            description: "Custom Role",
            owner: owner,
            roleLockDuration: 7 days
        });
        registry.configureRole(ROLE_CUSTOM, customConfig);
        vm.stopPrank();

        // Verify role is configured
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(ROLE_CUSTOM);
        assertTrue(cfg.isActive);
        assertEq(cfg.minStake, 10 ether);
        assertEq(cfg.roleLockDuration, 7 days);
    }

    // ====================================
    // D.1#4: Staking Exit Flow
    // ====================================

    function test_StakingExit_UnlockAndTransfer_WithExitFee() public {
        _registerCommunity(communityUser, "ExitFeeDAO");

        uint256 stakedAmount = staking.getLockedStake(communityUser, ROLE_COMMUNITY);
        assertEq(stakedAmount, 30 ether);

        // Preview exit fee
        (uint256 fee, uint256 netAmount) = staking.previewExitFee(communityUser, ROLE_COMMUNITY);
        assertTrue(fee > 0, "Exit fee should be non-zero");
        assertEq(fee + netAmount, stakedAmount, "Fee + net should equal staked");

        // Warp and exit
        vm.warp(block.timestamp + 31 days);
        uint256 treasuryBefore = gtoken.balanceOf(treasury);
        uint256 userBefore = gtoken.balanceOf(communityUser);

        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // Verify fee went to treasury
        assertEq(gtoken.balanceOf(treasury) - treasuryBefore, fee, "Treasury should receive exit fee");
        assertEq(gtoken.balanceOf(communityUser) - userBefore, netAmount, "User should receive net amount");
    }

    function test_StakingExit_SlashThenExit() public {
        _registerCommunity(communityUser, "SlashDAO");

        // Authorize owner as slasher for testing
        vm.prank(owner);
        staking.setAuthorizedSlasher(owner, true);

        uint256 stakeBefore = staking.getLockedStake(communityUser, ROLE_COMMUNITY);

        // Slash 5 ether
        vm.prank(owner);
        staking.slash(communityUser, 5 ether, "test slash");

        uint256 stakeAfter = staking.getLockedStake(communityUser, ROLE_COMMUNITY);
        assertEq(stakeBefore - stakeAfter, 5 ether, "Stake should be reduced by slash amount");

        // Warp and exit
        vm.warp(block.timestamp + 31 days);
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        assertEq(staking.getLockedStake(communityUser, ROLE_COMMUNITY), 0);
    }

    function test_StakingExit_ViewFunctions() public {
        _registerCommunity(communityUser, "ViewDAO");

        // totalStaked
        uint256 total = staking.totalStaked();
        assertTrue(total >= 30 ether, "Total staked should include community stake");

        // stakes(user)
        (uint256 amount, uint256 slashedAmount, uint256 stakedAt, uint256 unstakeRequestedAt) = staking.stakes(communityUser);
        assertEq(amount, 30 ether);
        assertEq(slashedAmount, 0);
        assertTrue(stakedAt > 0);

        // getLockedStake
        assertEq(staking.getLockedStake(communityUser, ROLE_COMMUNITY), 30 ether);

        // REGISTRY / GTOKEN / treasury
        assertEq(address(staking.REGISTRY()), address(registry));
        assertEq(address(staking.GTOKEN()), address(gtoken));
        assertEq(staking.treasury(), treasury);
    }

    // ====================================
    // D.1#5: MySBT Burn Lifecycle
    // ====================================

    function test_MySBT_MintOnRegistration() public {
        _registerCommunity(communityUser, "SBT_DAO");

        uint256 tokenId = sbt.userToSBT(communityUser);
        assertTrue(tokenId != 0, "SBT should be minted on role registration");
        assertEq(sbt.ownerOf(tokenId), communityUser);
    }

    function test_MySBT_BurnOnAllRolesExit() public {
        _registerCommunity(communityUser, "BurnSBT_DAO");
        uint256 tokenId = sbt.userToSBT(communityUser);
        assertTrue(tokenId != 0);

        vm.warp(block.timestamp + 31 days);
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        assertEq(sbt.userToSBT(communityUser), 0, "SBT mapping should be cleared");
        vm.expectRevert();
        sbt.ownerOf(tokenId); // Should revert as token is burned
    }

    function test_MySBT_DeactivateMembership_OnCommunityExit() public {
        _registerCommunity(communityUser, "DeactDAO");

        // Verify membership is active
        uint256 tokenId = sbt.userToSBT(communityUser);
        assertTrue(sbt.verifyCommunityMembership(communityUser, communityUser));

        vm.warp(block.timestamp + 31 days);
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // Membership should be deactivated and SBT burned
        assertEq(sbt.userToSBT(communityUser), 0);
    }

    function test_MySBT_MetadataFields() public {
        _registerCommunity(communityUser, "MetaDAO");

        uint256 tokenId = sbt.userToSBT(communityUser);
        assertTrue(tokenId != 0);

        // Verify community memberships exist
        MySBT.CommunityMembership[] memory memberships = sbt.getMemberships(tokenId);
        assertTrue(memberships.length > 0, "Should have at least one membership");
        assertTrue(memberships[0].isActive, "First membership should be active");
    }

    // ====================================
    // D.1#7: upgradeToAndCall + reinitializer
    // ====================================

    function test_RegistryUpgrade_WithReinitializer() public {
        vm.startPrank(owner);

        // Deploy V2 with reinitializer
        RegistryV2Reinit newImpl = new RegistryV2Reinit();

        // upgradeToAndCall with reinitializeV2
        bytes memory initData = abi.encodeCall(RegistryV2Reinit.reinitializeV2, (42));
        registry.upgradeToAndCall(address(newImpl), initData);

        // Verify migration data was set
        assertEq(RegistryV2Reinit(address(registry)).migrationFlag(), 42);

        // Verify existing state preserved
        assertEq(registry.owner(), owner);
        assertEq(address(registry.GTOKEN_STAKING()), address(staking));
        assertEq(address(registry.MYSBT()), address(sbt));
        assertEq(keccak256(bytes(registry.version())), keccak256("Registry-5.0.0-test"));

        vm.stopPrank();
    }

    function test_RegistryUpgrade_ReinitializerCannotRunTwice() public {
        vm.startPrank(owner);

        RegistryV2Reinit newImpl = new RegistryV2Reinit();
        bytes memory initData = abi.encodeCall(RegistryV2Reinit.reinitializeV2, (42));
        registry.upgradeToAndCall(address(newImpl), initData);

        // Try to call reinitializeV2 again — should revert
        vm.expectRevert();
        RegistryV2Reinit(address(registry)).reinitializeV2(99);

        vm.stopPrank();
    }

    function test_SuperPaymasterUpgrade_WithReinitializer() public {
        vm.startPrank(owner);

        SuperPaymasterV2Reinit newImpl = new SuperPaymasterV2Reinit(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed)
        );
        bytes memory initData = abi.encodeCall(SuperPaymasterV2Reinit.reinitializeV2, (99));
        superPaymaster.upgradeToAndCall(address(newImpl), initData);

        assertEq(SuperPaymasterV2Reinit(payable(address(superPaymaster))).migrationFlag(), 99);
        assertEq(keccak256(bytes(superPaymaster.version())), keccak256("SuperPaymaster-5.0.0-test"));
        assertEq(superPaymaster.owner(), owner);

        vm.stopPrank();
    }

    // ====================================
    // D.1#8: updateBlockedStatus End-to-End
    // ====================================

    function test_UpdateBlockedStatus_ViaRegistry() public {
        // Setup: register communityUser as community + paymaster_super
        _registerCommunity(communityUser, "BlockDAO");

        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        // Registry.updateBlockedStatusBLS -> SuperPaymaster.updateBlockedStatus
        address[] memory users = new address[](2);
        users[0] = address(0x999);
        users[1] = address(0x888);
        bool[] memory statuses = new bool[](2);
        statuses[0] = true;
        statuses[1] = true;

        vm.prank(owner);
        registry.updateOperatorBlacklist(communityUser, users, statuses, "");

        // Verify blocked status in SuperPaymaster
        (,bool isBlocked0) = superPaymaster.userOpState(communityUser, users[0]);
        (,bool isBlocked1) = superPaymaster.userOpState(communityUser, users[1]);
        assertTrue(isBlocked0, "User 0 should be blocked");
        assertTrue(isBlocked1, "User 1 should be blocked");

        // Unblock
        statuses[0] = false;
        statuses[1] = false;
        vm.prank(owner);
        registry.updateOperatorBlacklist(communityUser, users, statuses, "");

        (,isBlocked0) = superPaymaster.userOpState(communityUser, users[0]);
        (,isBlocked1) = superPaymaster.userOpState(communityUser, users[1]);
        assertFalse(isBlocked0, "User 0 should be unblocked");
        assertFalse(isBlocked1, "User 1 should be unblocked");
    }

    function test_UpdateBlockedStatus_OnlyRegistry() public {
        // Direct call to SuperPaymaster should revert
        address[] memory users = new address[](1);
        users[0] = address(0x999);
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        superPaymaster.updateBlockedStatus(communityUser, users, statuses);
    }

    function test_UpdateSBTStatus_OnlyRegistry() public {
        // Direct call should revert
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        superPaymaster.updateSBTStatus(endUser, true);
    }

    function test_SBTStatus_SyncedOnRegistration() public {
        // Before registration
        assertFalse(superPaymaster.sbtHolders(communityUser));

        // Register
        _registerCommunity(communityUser, "SyncDAO");

        // After registration — sbtHolders should be true
        assertTrue(superPaymaster.sbtHolders(communityUser), "SBT status should sync on registration");
    }

    function test_SBTStatus_ClearedOnAllRolesExit() public {
        _registerCommunity(communityUser, "ClearDAO");
        assertTrue(superPaymaster.sbtHolders(communityUser));

        vm.warp(block.timestamp + 31 days);
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        assertFalse(superPaymaster.sbtHolders(communityUser), "SBT status should be cleared on exit");
    }
}
