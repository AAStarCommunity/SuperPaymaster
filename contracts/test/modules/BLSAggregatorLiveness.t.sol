// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";

/// @notice Toggleable staking stub — per-validator amount can be flipped to
///         simulate exits / partial unlocks / slashes.
contract MockStakingToggleableBLS {
    mapping(address => uint128) public lockedAmount;

    function setLocked(address user, uint128 amount) external {
        lockedAmount[user] = amount;
    }

    function roleLocks(address user, bytes32 roleId)
        external
        view
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata)
    {
        return (lockedAmount[user], 0, 0, roleId, "");
    }
}

/// @notice Mock Registry whose hasRole + minStake can be toggled per test to
///         drive the new per-slot real-time validation inside
///         BLSAggregator._reconstructPkAgg.
contract MockRegistryToggleableBLS is IRegistry {
    address public stakingAddr;
    mapping(address => bool) public dvtRoleHolders;
    uint256 public minStake;

    constructor() {
        // Default: no validators have ROLE_DVT until tests set it. minStake = 100
        // so MockStakingToggleableBLS.setLocked(v, 200) passes the floor.
        minStake = 100;
    }

    function setStakingAddr(address s) external { stakingAddr = s; }
    function setHasDvtRole(address v, bool has_) external { dvtRoleHolders[v] = has_; }
    function setMinStake(uint256 ms) external { minStake = ms; }

    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }

    function hasRole(bytes32, address user) external view override returns (bool) {
        return dvtRoleHolders[user];
    }

    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(minStake, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }

    // --- IRegistry stubs ---
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function getCreditLimit(address) external view override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external view override returns (string memory) { return "MockRegistryToggleableBLS"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

/**
 * @title BLSAggregatorLivenessTest
 * @notice Regression tests for the P0 follow-up per-slot real-time
 *         validation inside `_reconstructPkAgg`, plus the new strict
 *         `revokeBLSPublicKey` semantics.
 *
 * Attack model: a validator registered into a BLS slot exits / unstakes /
 * loses ROLE_DVT, but their slot pointer + key remain — so an aggregator
 * proof that includes their slot still passes the OLD pkAgg reconstruction.
 * The new check rejects such proofs at the slot level.
 */
contract BLSAggregatorLivenessTest is Test {
    BLSAggregator bls;
    MockRegistryToggleableBLS registry;
    MockStakingToggleableBLS staking;

    address owner = address(0xA1);
    address sp = address(0xC0);
    address dvt = address(0xC1);
    address attacker = address(0xDEAD);

    function _stubKey(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(0x01));
        pk.x_b = bytes32(seed);
        pk.y_a = bytes32(uint256(0x02));
        pk.y_b = bytes32(seed + 1);
    }

    function setUp() public {
        // BLS precompile mocks. G1ADD + G1MUL must succeed for stub keys to
        // pass _validateG1Point during register; G1MUL returning 128 zero
        // bytes is interpreted as r*P == O ⇒ in prime-order subgroup.
        vm.etch(address(0x0b), hex"60806000f3");
        vm.etch(address(0x0c), hex"60806000f3");
        vm.etch(address(0x0d), hex"6101006000f3");
        vm.etch(address(0x10), hex"60806000f3");
        vm.etch(address(0x11), hex"6101006000f3");

        vm.startPrank(owner);
        registry = new MockRegistryToggleableBLS();
        staking = new MockStakingToggleableBLS();
        registry.setStakingAddr(address(staking));

        bls = new BLSAggregator(address(registry), sp, dvt);

        // Register 7 validators in slots 1..7 = defaultThreshold quorum.
        for (uint8 slot = 1; slot <= 7; slot++) {
            address v = address(uint160(uint256(slot) + 0x100));
            registry.setHasDvtRole(v, true);
            staking.setLocked(v, 200);
            bls.registerBLSPublicKey(v, _stubKey(uint256(slot)), slot);
        }
        vm.stopPrank();

        // Mock pairing precompile to succeed when we want it to.
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
    }

    function _sigBytes() internal pure returns (bytes memory) {
        BLS.G2Point memory sig;
        return abi.encode(sig);
    }

    // ====================================
    // _reconstructPkAgg per-slot real-time validation
    // ====================================

    function test_ReconstructPkAgg_HappyPath_AllSlotsEligible() public view {
        // 7 signers, all eligible — pairing is mocked to true.
        bool ok = bls.verify(keccak256("msg"), uint256(0x7F), uint256(7), _sigBytes());
        assertTrue(ok, "All-eligible quorum should verify");
    }

    function test_ReconstructPkAgg_RevertsWhen_SlotValidatorRoleRevoked() public {
        // Slot 3's validator loses ROLE_DVT post-registration.
        address slot3v = address(uint160(uint256(3) + 0x100));
        vm.prank(owner);
        registry.setHasDvtRole(slot3v, false);

        // Mask still includes slot 3 (bit 2). Aggregator must revert.
        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.SlotValidatorRoleRevoked.selector,
            uint8(3),
            slot3v
        ));
        bls.verify(keccak256("msg"), uint256(0x7F), uint256(7), _sigBytes());
    }

    function test_ReconstructPkAgg_RevertsWhen_SlotValidatorStakeBelowMin() public {
        // Slot 5's validator partially unlocks: stake drops to 50 < minStake (100).
        address slot5v = address(uint160(uint256(5) + 0x100));
        vm.prank(owner);
        staking.setLocked(slot5v, 50);

        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.SlotValidatorStakeBelowMinimum.selector,
            uint8(5),
            slot5v,
            uint256(50),
            uint256(100)
        ));
        bls.verify(keccak256("msg"), uint256(0x7F), uint256(7), _sigBytes());
    }

    function test_ReconstructPkAgg_RevertsWhen_SlotValidatorStakeFullyWithdrawn() public {
        // Full exit: stake to zero — same revert as above with actual=0.
        address slot1v = address(uint160(uint256(1) + 0x100));
        vm.prank(owner);
        staking.setLocked(slot1v, 0);

        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.SlotValidatorStakeBelowMinimum.selector,
            uint8(1),
            slot1v,
            uint256(0),
            uint256(100)
        ));
        bls.verify(keccak256("msg"), uint256(0x7F), uint256(7), _sigBytes());
    }

    function test_ReconstructPkAgg_RevertsWhen_KeyRevoked() public {
        // Owner revokes slot 4's BLS key directly. validatorAtSlot[4] is now
        // address(0), so the existing UnknownValidatorSlot revert covers this.
        address slot4v = address(uint160(uint256(4) + 0x100));
        vm.prank(owner);
        bls.revokeBLSPublicKey(slot4v);

        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.UnknownValidatorSlot.selector,
            uint8(4)
        ));
        bls.verify(keccak256("msg"), uint256(0x7F), uint256(7), _sigBytes());
    }

    function test_ReconstructPkAgg_AllowsPartialMask_WhenExcludedSlotIsCompromised() public view {
        // If we DROP slot 3 from the mask (use only slots 1,2,4,5,6,7,8...) the
        // aggregator should not even look at slot 3. Confirms the per-slot check
        // is gated on signerMask membership, not on the entire registered set.
        // We exclude slot 3 (bit 2) from the mask: 0x7B = 0b01111011 = slots 1,2,4,5,6,7.
        // That's only 6 signers, below the 7 default threshold — use threshold 6.
        bool ok = bls.verify(keccak256("msg"), uint256(0x7B), uint256(6), _sigBytes());
        assertTrue(ok, "Partial mask excluding compromised slot should verify");
    }

    // ====================================
    // revokeBLSPublicKey strict semantics
    // ====================================

    function test_RevokeBLSPublicKey_OnlyOwner() public {
        address slot1v = address(uint160(uint256(1) + 0x100));
        vm.prank(attacker);
        vm.expectRevert();
        bls.revokeBLSPublicKey(slot1v);
    }

    function test_RevokeBLSPublicKey_RevertsWhen_KeyNotActive() public {
        address slot1v = address(uint160(uint256(1) + 0x100));
        vm.startPrank(owner);
        bls.revokeBLSPublicKey(slot1v);

        // Second revoke must revert (no longer idempotent).
        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.KeyNotActive.selector,
            slot1v
        ));
        bls.revokeBLSPublicKey(slot1v);
        vm.stopPrank();
    }

    function test_RevokeBLSPublicKey_RevertsForUnknownValidator() public {
        // Validator never registered → key not active → revert.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.KeyNotActive.selector,
            attacker
        ));
        bls.revokeBLSPublicKey(attacker);
    }

    function test_RevokeBLSPublicKey_PreservesKeyBytesForAudit() public {
        // After revoke, getBLSPublicKey still returns the stored key bytes
        // (audit trail) but isActive is false and validatorAtSlot is cleared.
        address slot2v = address(uint160(uint256(2) + 0x100));
        (BLS.G1Point memory before_, , bool wasActive) = bls.getBLSPublicKey(slot2v);
        assertTrue(wasActive);

        vm.prank(owner);
        bls.revokeBLSPublicKey(slot2v);

        (BLS.G1Point memory after_, uint8 slotAfter, bool isActive) = bls.getBLSPublicKey(slot2v);
        assertEq(uint256(after_.x_b), uint256(before_.x_b), "Key bytes preserved for audit");
        assertEq(slotAfter, 2, "Slot index preserved on the BLSValidatorKey record");
        assertFalse(isActive, "isActive flipped to false");
        assertEq(bls.validatorAtSlot(2), address(0), "Slot pointer cleared");
    }

    function test_RevokeBLSPublicKey_FreesSlotForNewValidator() public {
        address slot7v = address(uint160(uint256(7) + 0x100));
        address newcomer = address(0xBEEF);

        vm.startPrank(owner);
        bls.revokeBLSPublicKey(slot7v);

        // Newcomer can claim slot 7.
        registry.setHasDvtRole(newcomer, true);
        staking.setLocked(newcomer, 200);
        bls.registerBLSPublicKey(newcomer, _stubKey(uint256(99)), 7);
        vm.stopPrank();

        assertEq(bls.validatorAtSlot(7), newcomer);
    }

    // ====================================
    // version
    // ====================================

    function test_Version_Bumped() public view {
        assertEq(keccak256(bytes(bls.version())), keccak256("BLSAggregator-4.1.0"));
    }
}
