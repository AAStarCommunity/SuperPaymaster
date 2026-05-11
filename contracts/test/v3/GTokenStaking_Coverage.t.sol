// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/core/GTokenStaking.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/**
 * @title GTokenStaking_Coverage
 * @notice Branch coverage tests for GTokenStaking.sol
 * @dev Covers: multi-role slash proportional deduction (C1), rounding dust (C2),
 *      exitRole with multiple active locks (C3), topUpStake cap revert (C4),
 *      unlockAndTransfer edge cases (C5), getEffectiveStake combinations (C6),
 *      and access-control error paths.
 */
contract GTokenStaking_Coverage is Test {
    using stdStorage for StdStorage;

    GTokenStaking staking;
    Registry registry;
    GToken gtoken;
    MySBT sbt;

    address owner     = address(0x1);
    address dao       = address(0x2);
    address treasury  = address(0x3);
    address operator  = address(0x10);
    address operator2 = address(0x11);
    address slasher   = address(0x20);

    bytes32 constant ROLE_COMMUNITY      = keccak256("COMMUNITY");
    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_DVT            = keccak256("DVT");

    // Minimum stake amounts required by Registry defaults:
    //   ROLE_COMMUNITY:       0 stake, 30 ether ticket
    //   ROLE_PAYMASTER_SUPER: 50 ether stake, 5 ether ticket
    //   ROLE_DVT:             30 ether stake, 3 ether ticket

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new GToken(21_000_000 ether);

        // Deploy Registry proxy (no staking/mysbt yet)
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));

        // Deploy staking with registry address
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));

        // Deploy MySBT (needs gtoken, staking, registry, dao)
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);

        // Wire staking and MySBT into registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

        // Authorize slasher
        staking.setAuthorizedSlasher(slasher, true);

        // Fund operators
        gtoken.mint(operator,  1_000_000 ether);
        gtoken.mint(operator2, 1_000_000 ether);

        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // Helper: register operator with COMMUNITY + PAYMASTER_SUPER roles
    // Uses a unique community name per operator address to avoid name collision.
    // ----------------------------------------------------------------
    function _registerCommunityAndPaymaster(address op, uint256 paymasterStake) internal {
        vm.startPrank(op);
        gtoken.approve(address(staking), paymasterStake + 100 ether); // community ticket + paymaster stake+ticket

        // Use op address as unique suffix to avoid communityByName collision
        string memory communityName = string(abi.encodePacked("Comm-", toHexString(uint160(op))));

        // Register COMMUNITY (ticket-only)
        bytes memory commData = abi.encode(
            Registry.CommunityRoleData({
                name: communityName,
                ensName: "",
                stakeAmount: 30 ether
            })
        );
        registry.registerRole(ROLE_COMMUNITY, op, commData);

        // Register PAYMASTER_SUPER (stake + ticket)
        bytes memory roleData = abi.encode(paymasterStake);
        registry.registerRole(ROLE_PAYMASTER_SUPER, op, roleData);

        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // Helper: register operator with DVT role
    // Requires COMMUNITY role first (PAYMASTER_SUPER requires COMMUNITY).
    // DVT also requires COMMUNITY role per Registry checks.
    // ----------------------------------------------------------------
    function _registerDVT(address op, uint256 dvtStake) internal {
        vm.startPrank(op);
        gtoken.approve(address(staking), dvtStake + 10 ether);
        bytes memory roleData = abi.encode(dvtStake);
        registry.registerRole(ROLE_DVT, op, roleData);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // Helper: uint160 → hex string (for unique community names)
    // ----------------------------------------------------------------
    function toHexString(uint160 value) internal pure returns (string memory) {
        bytes16 hexAlphabet = "0123456789abcdef";
        bytes memory result = new bytes(40);
        for (uint256 i = 40; i > 0; i--) {
            result[i - 1] = hexAlphabet[value & 0xf];
            value >>= 4;
        }
        return string(result);
    }

    // ====================================
    // C1: slash() with multiple role locks — proportional deduction
    // ====================================

    /// @notice C1a: slash across two role locks — amounts reduced proportionally
    function test_Slash_MultipleRoles_ProportionalDeduction() public {
        // Register operator with PAYMASTER_SUPER (50 GT) and also check DVT (30 GT)
        // We need to set up two role locks manually using lockStakeWithTicket via Registry
        _registerCommunityAndPaymaster(operator, 50 ether);

        // Also register DVT
        _registerDVT(operator, 30 ether);

        // Total locked across roles: 50 GT (PAYMASTER_SUPER) + 30 GT (DVT)
        uint256 lockPS = staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER);
        uint256 lockDVT = staking.getLockedStake(operator, ROLE_DVT);
        assertEq(lockPS, 50 ether, "Expected 50 GT in PAYMASTER_SUPER lock");
        assertEq(lockDVT, 30 ether, "Expected 30 GT in DVT lock");

        uint256 totalBeforeSlash = lockPS + lockDVT; // 80 ether

        // Slash 40 GT (50% of total)
        uint256 slashAmount = 40 ether;
        vm.prank(slasher);
        uint256 actualSlashed = staking.slash(operator, slashAmount, "test slash");
        assertEq(actualSlashed, slashAmount, "Full slash amount applied");

        // Both roles should be reduced proportionally by ~50%
        uint256 newLockPS  = staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER);
        uint256 newLockDVT = staking.getLockedStake(operator, ROLE_DVT);

        // PAYMASTER_SUPER: 50 * 40 / 80 = 25 GT deducted → 25 GT remaining
        uint256 expectedPS  = lockPS  - (lockPS  * slashAmount / totalBeforeSlash);
        // DVT: 30 * 40 / 80 = 15 GT deducted → 15 GT remaining
        uint256 expectedDVT = lockDVT - (lockDVT * slashAmount / totalBeforeSlash);

        assertEq(newLockPS,  expectedPS,  "PAYMASTER_SUPER proportional deduction");
        assertEq(newLockDVT, expectedDVT, "DVT proportional deduction");

        // Total remaining = expectedPS + expectedDVT = 40 GT
        assertEq(newLockPS + newLockDVT, totalBeforeSlash - slashAmount, "Total correctly reduced");
    }

    /// @notice C1b: slash more than available — capped at available balance
    function test_Slash_ExceedsAvailable_CappedAtBalance() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        uint256 available = staking.balanceOf(operator); // 50 GT

        // Try to slash 100 GT (more than available)
        vm.prank(slasher);
        uint256 actualSlashed = staking.slash(operator, 100 ether, "over-slash");

        assertEq(actualSlashed, available, "Slash capped at available balance");
        assertEq(staking.balanceOf(operator), 0, "Balance drained to zero");
    }

    // ====================================
    // C2: slash() rounding dust
    // ====================================

    /// @notice C2: odd-number slash causes rounding — sum of proportional deductions may != slashAmount
    ///         The contract uses floor division, so residual dust stays in role locks.
    function test_Slash_RoundingDust_SumMayNotEqualSlash() public {
        // 3 unequal role locks to maximise rounding dust:
        // We simulate two role locks of different sizes
        _registerCommunityAndPaymaster(operator, 50 ether);
        _registerDVT(operator, 30 ether);

        // Slash an amount that does NOT divide evenly: 7 ether across 80 ether total
        uint256 slashAmount = 7 ether;
        uint256 totalBefore = staking.balanceOf(operator); // 80 GT

        vm.prank(slasher);
        uint256 actualSlashed = staking.slash(operator, slashAmount, "rounding test");
        assertEq(actualSlashed, slashAmount);

        uint256 lockPS  = staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER);
        uint256 lockDVT = staking.getLockedStake(operator, ROLE_DVT);

        // Floor: PS deduct = 50*7/80 = 4 (floor), DVT deduct = 30*7/80 = 2 (floor)
        // Sum of deductions = 6, but we slashed 7 → dust = 1
        // The operator's actual balance decreases by slashAmount (not by sum of lock deductions)
        assertEq(staking.balanceOf(operator), totalBefore - slashAmount, "Balance correctly reduced");

        // Each lock's deduction uses floor division
        uint256 psDeduct  = 50 ether * slashAmount / totalBefore;  // 4.375 → 4 ether (floor)
        uint256 dvtDeduct = 30 ether * slashAmount / totalBefore;  // 2.625 → 2 ether (floor)

        assertEq(lockPS,  50 ether - psDeduct,  "PS lock floor-divided");
        assertEq(lockDVT, 30 ether - dvtDeduct, "DVT lock floor-divided");

        // Document: sum of lock deductions may be less than slashAmount due to rounding
        // Dust remains effectively in the locks but the user's balance is correctly reduced
        uint256 sumDeductions = psDeduct + dvtDeduct;
        assertTrue(sumDeductions <= slashAmount, "Sum of deductions <= slashAmount (dust present)");
    }

    // ====================================
    // C3: exitRole with multiple active locks
    // ====================================

    /// @notice C3a: operator with two role locks — exit PAYMASTER_SUPER leaves DVT intact
    function test_UnlockAndTransfer_WithMultipleLocks_OnlyTargetExited() public {
        _registerCommunityAndPaymaster(operator, 50 ether);
        _registerDVT(operator, 30 ether);

        uint256 totalBefore = staking.balanceOf(operator); // 80 GT

        // Warp past PAYMASTER_SUPER lock duration (30 days)
        vm.warp(block.timestamp + 30 days + 1);

        // Exit PAYMASTER_SUPER via Registry.exitRole
        vm.prank(operator);
        registry.exitRole(ROLE_PAYMASTER_SUPER);

        // PAYMASTER_SUPER lock removed
        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 0, "PS lock cleared");

        // DVT lock unaffected
        assertEq(staking.getLockedStake(operator, ROLE_DVT), 30 ether, "DVT lock intact");

        // Operator's total balance reduced by 50 GT (minus exit fee if any)
        // Default exit fee for PAYMASTER_SUPER is 10% per Registry init
        // exitFee = 50 * 1000 / 10000 = 5 GT
        uint256 remaining = staking.balanceOf(operator);
        assertEq(remaining, 30 ether, "Only DVT stake remains");
    }

    /// @notice C3b: exitRole for a role with no lock should revert
    function test_UnlockAndTransfer_NoLock_Reverts() public {
        // operator has no stake at all
        vm.expectRevert(GTokenStaking.NoLockFound.selector);
        vm.prank(address(registry));
        staking.unlockAndTransfer(operator, ROLE_PAYMASTER_SUPER);
    }

    // ====================================
    // C4: topUpStake cap revert
    // ====================================

    /// @notice C4a: topUpStake when totalStaked + newAmount would exceed MAX_TOTAL_STAKE
    /// @dev Uses vm.store to force totalStaked near MAX without minting extra tokens
    ///      (GToken has a 21M cap that equals initial supply — no headroom for large mints).
    function test_TopUpStake_ExceedsGlobalCap_Reverts() public {
        // Register operator with normal stake first
        _registerCommunityAndPaymaster(operator, 50 ether);

        // Force totalStaked to MAX_TOTAL_STAKE - 1 wei using stdstore (layout-safe)
        // so any topUp (even 1 ether) will push it over the cap
        uint256 almostCap = staking.MAX_TOTAL_STAKE() - 1;
        stdstore.target(address(staking)).sig("totalStaked()").checked_write(almostCap);
        assertEq(staking.totalStaked(), almostCap, "totalStaked forced near cap");

        // Approve top-up tokens
        vm.startPrank(operator);
        gtoken.approve(address(staking), 100 ether);
        vm.stopPrank();

        // topUpStake with 1 ether now exceeds MAX_TOTAL_STAKE
        vm.expectRevert(GTokenStaking.TotalStakeExceedsCap.selector);
        vm.prank(address(registry));
        staking.topUpStake(operator, ROLE_PAYMASTER_SUPER, 1 ether, operator);
    }

    /// @notice C4b: topUpStake for role with no existing lock should revert
    function test_TopUpStake_NoExistingLock_Reverts() public {
        vm.expectRevert(GTokenStaking.RoleNotLocked.selector);
        vm.prank(address(registry));
        staking.topUpStake(operator, ROLE_PAYMASTER_SUPER, 10 ether, operator);
    }

    /// @notice C4c: topUpStake success path
    function test_TopUpStake_Success() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        uint256 lockBefore = staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER);
        assertEq(lockBefore, 50 ether);

        // topUpStake via Registry (simulate top-up via registerRole with higher amount)
        // We call topUpStake directly as registry
        vm.startPrank(operator);
        gtoken.approve(address(staking), 20 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        staking.topUpStake(operator, ROLE_PAYMASTER_SUPER, 20 ether, operator);

        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 70 ether, "Lock increased by 20 GT");
        assertEq(staking.balanceOf(operator), 70 ether, "Balance updated");
    }

    // ====================================
    // C5: unlockAndTransfer edge cases
    // ====================================

    /// @notice C5a: unlockAndTransfer with exit fee set — operator receives net amount
    function test_UnlockAndTransfer_WithExitFee() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        // Set a 10% exit fee for PAYMASTER_SUPER (1000 BPS)
        vm.prank(owner);
        staking.setRoleExitFee(ROLE_PAYMASTER_SUPER, 1000, 0);

        uint256 balBefore = gtoken.balanceOf(operator);

        // Warp past lock duration (30 days)
        vm.warp(block.timestamp + 30 days + 1);

        // Exit via Registry
        vm.prank(operator);
        registry.exitRole(ROLE_PAYMASTER_SUPER);

        uint256 balAfter = gtoken.balanceOf(operator);
        uint256 received = balAfter - balBefore;

        // 50 GT * 10% = 5 GT fee → operator gets 45 GT
        assertEq(received, 45 ether, "Operator received 45 GT after 10% exit fee");

        // Treasury received exit fee
        // (treasury started with 30 ether ticket from community registration)
        // After unlock: gets additional 5 GT exit fee
        // We can't easily check treasury balance delta here, but we verify state
        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 0, "Lock cleared");
    }

    /// @notice C5b: unlockAndTransfer — after unlock, balance cleared properly
    function test_UnlockAndTransfer_ZeroBalanceAfterFullExit() public {
        _registerCommunityAndPaymaster(operator, 50 ether);
        // No DVT lock — only PAYMASTER_SUPER

        // Warp past lock duration (30 days)
        vm.warp(block.timestamp + 30 days + 1);

        // Exit PAYMASTER_SUPER
        vm.prank(operator);
        registry.exitRole(ROLE_PAYMASTER_SUPER);

        assertEq(staking.balanceOf(operator), 0, "Balance zero after full exit");
        assertEq(staking.totalStaked(), 0, "Total staked zero");
    }

    /// @notice C5c: unlockAndTransfer is onlyRegistry
    function test_UnlockAndTransfer_OnlyRegistry_Reverts() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.expectRevert(GTokenStaking.OnlyRegistry.selector);
        vm.prank(operator);
        staking.unlockAndTransfer(operator, ROLE_PAYMASTER_SUPER);
    }

    // ====================================
    // C6: getEffectiveStake (via Registry) with various combinations
    // ====================================

    /// @notice C6a: no stake — getEffectiveStake returns 0
    function test_GetLockedStake_NoStake_Zero() public view {
        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 0);
    }

    /// @notice C6b: after registration, getLockedStake matches registered amount
    function test_GetLockedStake_AfterRegistration() public {
        _registerCommunityAndPaymaster(operator, 50 ether);
        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 50 ether);
    }

    /// @notice C6c: after slash, getLockedStake reflects reduced amount
    function test_GetLockedStake_AfterSlash() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.prank(slasher);
        staking.slash(operator, 20 ether, "partial slash");

        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 30 ether);
    }

    /// @notice C6d: getEffectiveStake via Registry reads from Staking directly
    function test_GetEffectiveStake_ViaRegistry_AfterSlash() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        assertEq(registry.getEffectiveStake(operator, ROLE_PAYMASTER_SUPER), 50 ether);

        vm.prank(slasher);
        staking.slash(operator, 10 ether, "slash");

        // Registry.getEffectiveStake reads from staking — always fresh
        assertEq(registry.getEffectiveStake(operator, ROLE_PAYMASTER_SUPER), 40 ether);
    }

    /// @notice C6e: getUserRoleLocks returns all active role locks
    function test_GetUserRoleLocks_MultipleRoles() public {
        _registerCommunityAndPaymaster(operator, 50 ether);
        _registerDVT(operator, 30 ether);

        IGTokenStaking.RoleLock[] memory locks = staking.getUserRoleLocks(operator);
        assertEq(locks.length, 2, "Two role locks");

        // Verify amounts (order may vary)
        bool foundPS  = false;
        bool foundDVT = false;
        for (uint256 i = 0; i < locks.length; i++) {
            if (locks[i].roleId == ROLE_PAYMASTER_SUPER) {
                assertEq(locks[i].amount, 50 ether);
                foundPS = true;
            } else if (locks[i].roleId == ROLE_DVT) {
                assertEq(locks[i].amount, 30 ether);
                foundDVT = true;
            }
        }
        assertTrue(foundPS,  "PAYMASTER_SUPER lock found");
        assertTrue(foundDVT, "DVT lock found");
    }

    // ====================================
    // C7: Access control error paths
    // ====================================

    /// @notice C7a: lockStakeWithTicket onlyRegistry — non-registry reverts
    function test_LockStakeWithTicket_NonRegistry_Reverts() public {
        vm.expectRevert(GTokenStaking.OnlyRegistry.selector);
        vm.prank(operator);
        staking.lockStakeWithTicket(operator, ROLE_PAYMASTER_SUPER, 50 ether, 5 ether, operator);
    }

    /// @notice C7b: topUpStake onlyRegistry — non-registry reverts
    function test_TopUpStake_NonRegistry_Reverts() public {
        vm.expectRevert(GTokenStaking.OnlyRegistry.selector);
        vm.prank(operator);
        staking.topUpStake(operator, ROLE_PAYMASTER_SUPER, 10 ether, operator);
    }

    /// @notice C7c: slash onlyRegistryOrAuthorized — random caller reverts
    function test_Slash_Unauthorized_Reverts() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.expectRevert(GTokenStaking.OnlyRegistryOrAuthorized.selector);
        vm.prank(address(0xDEAD));
        staking.slash(operator, 10 ether, "unauthorized");
    }

    /// @notice C7d: slash by Registry itself is allowed
    function test_Slash_ByRegistry_Allowed() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.prank(address(registry));
        uint256 slashed = staking.slash(operator, 10 ether, "registry slash");
        assertEq(slashed, 10 ether);
    }

    /// @notice C7e: setRoleExitFee fee too high (> 2000 BPS) reverts
    function test_SetRoleExitFee_TooHigh_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(GTokenStaking.FeeTooHigh.selector);
        staking.setRoleExitFee(ROLE_PAYMASTER_SUPER, 2001, 0);
    }

    /// @notice C7f: setTreasury with zero address reverts
    function test_SetTreasury_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(GTokenStaking.InvalidAddress.selector);
        staking.setTreasury(address(0));
    }

    /// @notice C7g: setTreasury by non-owner reverts
    function test_SetTreasury_NonOwner_Reverts() public {
        vm.prank(operator);
        vm.expectRevert();
        staking.setTreasury(address(0x5));
    }

    // ====================================
    // C8: slashByDVT path coverage
    // ====================================

    /// @notice C8a: slashByDVT reduces role lock and syncs Registry
    function test_SlashByDVT_ReducesRoleLock_AndSyncsRegistry() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.prank(slasher);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 20 ether, "dvt slash");

        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 30 ether);
        assertEq(registry.getRoleStake(ROLE_PAYMASTER_SUPER, operator), 30 ether);
    }

    /// @notice C8b: slashByDVT to zero — removes role from userActiveRoles
    function test_SlashByDVT_ToZero_ClearsLock() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.prank(slasher);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 50 ether, "full slash");

        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 0);
        assertFalse(staking.hasRoleLock(operator, ROLE_PAYMASTER_SUPER));
    }

    /// @notice C8c: slashByDVT exceeds lock amount — reverts with InsufficientStake
    function test_SlashByDVT_ExceedsLock_Reverts() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.expectRevert(GTokenStaking.InsufficientStake.selector);
        vm.prank(slasher);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 60 ether, "over-slash");
    }

    /// @notice C8d: slashByDVT by unauthorized caller reverts
    function test_SlashByDVT_Unauthorized_Reverts() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.expectRevert(GTokenStaking.NotAuthorizedSlasher.selector);
        vm.prank(address(0xDEAD));
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 10 ether, "unauthorized");
    }

    // ====================================
    // C9: previewExitFee and minFee logic
    // ====================================

    /// @notice C9a: previewExitFee with minFee higher than percent-based fee
    function test_PreviewExitFee_MinFeeApplied() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        // Set 1% fee but minFee = 10 GT (higher than 0.5 GT from 1% of 50 GT)
        vm.prank(owner);
        staking.setRoleExitFee(ROLE_PAYMASTER_SUPER, 100, 10 ether); // 1% = 0.5 GT, minFee = 10 GT

        (uint256 fee, uint256 net) = staking.previewExitFee(operator, ROLE_PAYMASTER_SUPER);

        assertEq(fee, 10 ether, "minFee kicks in");
        assertEq(net, 40 ether, "net = 50 - 10");
    }

    /// @notice C9b: previewExitFee where fee exceeds amount (capped at amount)
    function test_PreviewExitFee_FeeExceedsAmount_CappedAtAmount() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        // Set minFee higher than stake
        vm.prank(owner);
        staking.setRoleExitFee(ROLE_PAYMASTER_SUPER, 100, 100 ether); // minFee = 100 GT > 50 GT stake

        (uint256 fee, uint256 net) = staking.previewExitFee(operator, ROLE_PAYMASTER_SUPER);

        assertEq(fee, 50 ether, "Fee capped at stake amount");
        assertEq(net, 0, "Net is zero when fee >= stake");
    }

    // ====================================
    // C10: lockStakeWithTicket — RoleAlreadyLocked
    // ====================================

    /// @notice C10: attempting to re-lock a role that already has a stake must revert
    function test_LockStakeWithTicket_RoleAlreadyLocked_Reverts() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        // Attempt to lock the same role again directly (bypassing Registry top-up path)
        vm.startPrank(operator);
        gtoken.approve(address(staking), 60 ether);
        vm.stopPrank();

        vm.expectRevert(GTokenStaking.RoleAlreadyLocked.selector);
        vm.prank(address(registry));
        staking.lockStakeWithTicket(operator, ROLE_PAYMASTER_SUPER, 50 ether, 5 ether, operator);
    }

    // ====================================
    // C11: hasRoleLock / balanceOf view coverage
    // ====================================

    function test_HasRoleLock_TrueAfterLock() public {
        _registerCommunityAndPaymaster(operator, 50 ether);
        assertTrue(staking.hasRoleLock(operator, ROLE_PAYMASTER_SUPER));
    }

    function test_HasRoleLock_FalseBeforeLock() public view {
        assertFalse(staking.hasRoleLock(operator, ROLE_PAYMASTER_SUPER));
    }

    function test_BalanceOf_ReflectsLock() public {
        _registerCommunityAndPaymaster(operator, 50 ether);
        assertEq(staking.balanceOf(operator), 50 ether);
    }

    function test_BalanceOf_ZeroForNoStake() public view {
        assertEq(staking.balanceOf(operator), 0);
    }

    function test_TotalStaked_AggregatesAllOperators() public {
        _registerCommunityAndPaymaster(operator,  50 ether);
        _registerCommunityAndPaymaster(operator2, 80 ether);

        assertEq(staking.totalStaked(), 130 ether, "Total = 50 + 80");
    }

    // ====================================
    // C12: getStakeInfo
    // ====================================

    function test_GetStakeInfo_ReturnsRoleLockView() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        IGTokenStaking.StakeInfo memory info = staking.getStakeInfo(operator, ROLE_PAYMASTER_SUPER);

        assertEq(info.amount, 50 ether, "Lock amount");
        assertEq(info.slashedAmount, 0, "No slash yet");
        assertGt(info.stakedAt, 0, "Staked timestamp set");
    }

    function test_GetStakeInfo_AfterSlash() public {
        _registerCommunityAndPaymaster(operator, 50 ether);

        vm.prank(slasher);
        staking.slash(operator, 10 ether, "test");

        IGTokenStaking.StakeInfo memory info = staking.getStakeInfo(operator, ROLE_PAYMASTER_SUPER);
        // Lock is reduced proportionally; slashedAmount tracks cumulative
        assertEq(info.slashedAmount, 10 ether, "Cumulative slashed");
    }
}
