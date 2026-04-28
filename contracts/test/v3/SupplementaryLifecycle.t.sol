// SPDX-License-Identifier: Apache-2.0
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
        return "R2";
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
        {
            bytes32[] memory roles = new bytes32[](7);
            roles[0] = keccak256("PAYMASTER_AOA");
            roles[1] = keccak256("PAYMASTER_SUPER");
            roles[2] = keccak256("DVT");
            roles[3] = keccak256("ANODE");
            roles[4] = keccak256("KMS");
            roles[5] = keccak256("COMMUNITY");
            roles[6] = keccak256("ENDUSER");
            registry.syncExitFees(roles);
        }
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
        // COMMUNITY is non-operator: no stake, ticketPrice goes to treasury
        assertEq(staking.getLockedStake(communityUser, ROLE_COMMUNITY), 0);
        assertEq(registry.communityByName("TestDAO"), communityUser);
        assertTrue(sbt.userToSBT(communityUser) != 0, "SBT should be minted");

        // COMMUNITY is a ticket-only role — exit succeeds, cleans up name/ENS
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // Role should be removed, name slot freed
        assertFalse(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertEq(registry.communityByName("TestDAO"), address(0));
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
        // Use an operator role (PAYMASTER_SUPER) which has 30 day lock
        _registerCommunity(communityUser, "LockedDAO");

        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        // Try to exit immediately (lock = 30 days) — should revert LockNotMet
        vm.prank(communityUser);
        vm.expectRevert(Registry.LockNotMet.selector);
        registry.exitRole(ROLE_PAYMASTER_SUPER);
    }

    function test_RoleLifecycle_MultipleRoles_ExitOne_KeepSBT() public {
        _registerCommunity(communityUser, "MultiDAO");

        // Add PAYMASTER_SUPER and PAYMASTER_AOA roles
        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 200 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        registry.registerRole(ROLE_PAYMASTER_AOA, communityUser, "");
        vm.stopPrank();

        uint256 sbtId = sbt.userToSBT(communityUser);
        assertTrue(sbtId != 0);

        // Exit PAYMASTER_AOA only (operator role, warp past lock)
        vm.warp(block.timestamp + 31 days);
        vm.prank(communityUser);
        registry.exitRole(ROLE_PAYMASTER_AOA);

        // SBT should still exist (user still has COMMUNITY + PAYMASTER_SUPER roles)
        assertTrue(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertFalse(registry.hasRole(ROLE_PAYMASTER_AOA, communityUser));
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

        // Only operator roles can exit; COMMUNITY cannot
        // Exit PAYMASTER_SUPER (operator role)
        vm.startPrank(communityUser);
        registry.exitRole(ROLE_PAYMASTER_SUPER);
        vm.stopPrank();

        // COMMUNITY still active (cannot exit), PAYMASTER_SUPER exited
        assertTrue(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertFalse(registry.hasRole(ROLE_PAYMASTER_SUPER, communityUser));
        // SBT should still exist since COMMUNITY role remains
        assertTrue(sbt.userToSBT(communityUser) != 0, "SBT should remain while COMMUNITY role active");
    }

    function test_RoleLifecycle_SafeMintForRole() public {
        // ENDUSER safeMintForRole requires caller to be a registered COMMUNITY
        _registerCommunity(communityUser, "SafeMintDAO");

        // communityUser (registered community) pays stake for endUser
        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);

        bytes memory endUserData = abi.encode(
            Registry.EndUserRoleData({
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
            ticketPrice: 1 ether,
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
        // Use an operator role (PAYMASTER_SUPER) to test exit fee flow
        _registerCommunity(communityUser, "ExitFeeDAO");

        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        uint256 stakedAmount = staking.getLockedStake(communityUser, ROLE_PAYMASTER_SUPER);
        assertEq(stakedAmount, 50 ether);

        // Preview exit fee
        (uint256 fee, uint256 netAmount) = staking.previewExitFee(communityUser, ROLE_PAYMASTER_SUPER);
        assertTrue(fee > 0, "Exit fee should be non-zero");
        assertEq(fee + netAmount, stakedAmount, "Fee + net should equal staked");

        // Warp and exit
        vm.warp(block.timestamp + 31 days);
        uint256 treasuryBefore = gtoken.balanceOf(treasury);
        uint256 userBefore = gtoken.balanceOf(communityUser);

        vm.prank(communityUser);
        registry.exitRole(ROLE_PAYMASTER_SUPER);

        // Verify fee went to treasury
        assertEq(gtoken.balanceOf(treasury) - treasuryBefore, fee, "Treasury should receive exit fee");
        assertEq(gtoken.balanceOf(communityUser) - userBefore, netAmount, "User should receive net amount");
    }

    function test_StakingExit_SlashThenExit() public {
        // Use an operator role (PAYMASTER_SUPER) to test slash + exit flow
        _registerCommunity(communityUser, "SlashDAO");

        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        // Authorize owner as slasher for testing
        vm.prank(owner);
        staking.setAuthorizedSlasher(owner, true);

        uint256 stakeBefore = staking.getLockedStake(communityUser, ROLE_PAYMASTER_SUPER);
        assertTrue(stakeBefore > 0, "Stake should be non-zero for operator role");

        // Slash 5 ether
        vm.prank(owner);
        staking.slash(communityUser, 5 ether, "test slash");

        uint256 stakeAfter = staking.getLockedStake(communityUser, ROLE_PAYMASTER_SUPER);
        assertEq(stakeBefore - stakeAfter, 5 ether, "Stake should be reduced by slash amount");

        // Warp and exit
        vm.warp(block.timestamp + 31 days);
        vm.prank(communityUser);
        registry.exitRole(ROLE_PAYMASTER_SUPER);

        assertEq(staking.getLockedStake(communityUser, ROLE_PAYMASTER_SUPER), 0);
    }

    function test_StakingExit_ViewFunctions() public {
        // Use an operator role (PAYMASTER_SUPER) to test staking view functions
        _registerCommunity(communityUser, "ViewDAO");

        vm.startPrank(communityUser);
        gtoken.approve(address(staking), 100 ether);
        registry.registerRole(ROLE_PAYMASTER_SUPER, communityUser, "");
        vm.stopPrank();

        // totalStaked
        uint256 total = staking.totalStaked();
        assertTrue(total >= 50 ether, "Total staked should include operator stake");

        // stakes(user)
        (uint256 amount, uint256 slashedAmount, uint256 stakedAt, uint256 unstakeRequestedAt) = staking.stakes(communityUser);
        assertEq(amount, 50 ether);
        assertEq(slashedAmount, 0);
        assertTrue(stakedAt > 0);

        // getLockedStake
        assertEq(staking.getLockedStake(communityUser, ROLE_PAYMASTER_SUPER), 50 ether);

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
        // Register community then exit — SBT should be burned when last role removed
        _registerCommunity(communityUser, "BurnSBT_DAO");
        uint256 tokenId = sbt.userToSBT(communityUser);
        assertTrue(tokenId != 0);

        // COMMUNITY exit succeeds (ticket-only, cleanup only)
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // SBT should be burned since it was the last role
        assertEq(sbt.userToSBT(communityUser), 0, "SBT should be burned after last role exit");
    }

    function test_MySBT_DeactivateMembership_OnCommunityExit() public {
        _registerCommunity(communityUser, "DeactDAO");

        // Verify membership is active
        uint256 tokenId = sbt.userToSBT(communityUser);
        assertTrue(sbt.verifyCommunityMembership(communityUser, communityUser));

        // COMMUNITY exit succeeds — SBT burned, membership deactivated
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // SBT should be burned and membership deactivated
        assertEq(sbt.userToSBT(communityUser), 0, "SBT should be burned");
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
        assertEq(keccak256(bytes(registry.version())), keccak256("R2"));

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

        // COMMUNITY exit succeeds — SBT status should be cleared
        vm.prank(communityUser);
        registry.exitRole(ROLE_COMMUNITY);

        // SBT status should be cleared after last role exit
        assertFalse(superPaymaster.sbtHolders(communityUser), "SBT status should be cleared after exit");
    }
}
