// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/utils/BLS.sol";
import "src/interfaces/v3/IRegistry.sol";

// Minimal mock registry (same pattern as GenericDVTProposal.t.sol)
contract MockRegistryUnit is IRegistry {
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(0,0,0,0,0,0,0,false, 0,"stub",address(0),0);
    }
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
    function version() external view override returns (string memory) { return "MockRegistryUnit"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

/**
 * @title BLSAggregatorUnitTest
 * @notice Unit tests for BLSAggregator admin functions and edge cases (P0-1).
 *         The new ABI takes a typed `BLS.G1Point` plus a 1-indexed slot — the
 *         old `bytes(48)` compressed-key API is gone, along with the ability
 *         for callers to inject pkAgg into proofs.
 */
contract BLSAggregatorUnitTest is Test {
    BLSAggregator bls;
    MockRegistryUnit registry;

    address owner = address(1);
    address attacker = address(0x1337);
    address sp = address(0xAA);
    address dvt = address(0xBB);

    function setUp() public {
        vm.startPrank(owner);
        registry = new MockRegistryUnit();
        bls = new BLSAggregator(address(registry), sp, dvt);
        vm.stopPrank();

        // Mock EIP-2537 G1ADD (0x0b) and G1MUL (0x0c) precompiles so that
        // stub keys produced by _key() pass the default on-curve + subgroup
        // validation in registerBLSPublicKey. Individual tests that want to
        // exercise rejection paths override these mocks with vm.mockCallRevert
        // or a custom etch before calling register.
        //
        // G1ADD returns 128 bytes of zeros (identity) — a valid G1 point.
        vm.etch(address(0x0b), hex"60806000f3"); // PUSH1 0x80 PUSH1 0 RETURN → 128 zero bytes
        // G1MUL must return 128 bytes of zeros (identity) to satisfy r*P == O.
        vm.etch(address(0x0c), hex"60806000f3"); // same bytecode → 128 zero bytes
    }

    /// @dev Returns a stub BLS.G1Point. Not a real curve point — callers must
    ///      ensure the precompile mocks are in place so validation passes.
    function _key(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(0x01));
        pk.x_b = bytes32(seed);
        pk.y_a = bytes32(uint256(0x02));
        pk.y_b = bytes32(seed + 1);
    }

    /// @dev Returns the real BLS12-381 G1 generator point (uncompressed, EIP-2537).
    ///      Gx = 0x17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb
    ///      Gy = 0x08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1
    function _realG1Generator() internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        pk.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        pk.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        pk.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }

    // ========================================
    // registerBLSPublicKey
    // ========================================

    function test_RegisterBLSPublicKey_Success() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(owner);
        bls.registerBLSPublicKey(address(0x42), pk, 1);

        (BLS.G1Point memory stored, uint8 slot, bool active) = bls.getBLSPublicKey(address(0x42));
        assertTrue(active, "Key should be active");
        assertEq(slot, 1, "Slot should match");
        assertEq(stored.x_b, pk.x_b, "x_b should match");
        assertEq(bls.validatorAtSlot(1), address(0x42), "validatorAtSlot mapping should be populated");
    }

    function test_RegisterBLSPublicKey_ZeroValidator_Reverts() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidAddress.selector, address(0)));
        bls.registerBLSPublicKey(address(0), pk, 1);
    }

    function test_RegisterBLSPublicKey_SlotZero_Reverts() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotOutOfRange.selector, uint8(0)));
        bls.registerBLSPublicKey(address(0x42), pk, 0);
    }

    function test_RegisterBLSPublicKey_SlotAboveMax_Reverts() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotOutOfRange.selector, uint8(14)));
        bls.registerBLSPublicKey(address(0x42), pk, 14);
    }

    function test_RegisterBLSPublicKey_SlotCollision_Reverts() public {
        BLS.G1Point memory pk1 = _key(0x01);
        BLS.G1Point memory pk2 = _key(0x02);

        vm.startPrank(owner);
        bls.registerBLSPublicKey(address(0x42), pk1, 3);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotAlreadyTaken.selector, uint8(3)));
        bls.registerBLSPublicKey(address(0x43), pk2, 3);
        vm.stopPrank();
    }

    function test_RegisterBLSPublicKey_OnlyOwner_Reverts() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(attacker);
        vm.expectRevert();
        bls.registerBLSPublicKey(address(0x42), pk, 1);
    }

    function test_RegisterBLSPublicKey_OverwritesExistingSameSlot() public {
        BLS.G1Point memory pk1 = _key(0x01);
        BLS.G1Point memory pk2 = _key(0x02);

        vm.startPrank(owner);
        bls.registerBLSPublicKey(address(0x42), pk1, 5);
        bls.registerBLSPublicKey(address(0x42), pk2, 5);
        vm.stopPrank();

        (BLS.G1Point memory stored, uint8 slot, bool active) = bls.getBLSPublicKey(address(0x42));
        assertEq(stored.x_b, pk2.x_b, "Key should be overwritten");
        assertEq(slot, 5);
        assertTrue(active);
    }

    function test_RegisterBLSPublicKey_ChangeSlotForSameValidator_Reverts() public {
        BLS.G1Point memory pk = _key(0x01);

        vm.startPrank(owner);
        bls.registerBLSPublicKey(address(0x42), pk, 4);
        // Switching slot for an already-active validator could leave a dangling
        // slot pointer — explicitly disallowed.
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotAlreadyTaken.selector, uint8(7)));
        bls.registerBLSPublicKey(address(0x42), pk, 7);
        vm.stopPrank();
    }

    function test_RevokeBLSPublicKey_FreesSlot() public {
        BLS.G1Point memory pk1 = _key(0x01);
        BLS.G1Point memory pk2 = _key(0x02);

        vm.startPrank(owner);
        bls.registerBLSPublicKey(address(0x42), pk1, 8);
        bls.revokeBLSPublicKey(address(0x42));

        // After revoke, slot 8 is free for a fresh validator.
        bls.registerBLSPublicKey(address(0x43), pk2, 8);
        vm.stopPrank();

        (, uint8 slot, bool active) = bls.getBLSPublicKey(address(0x43));
        assertEq(slot, 8);
        assertTrue(active);
    }

    // ========================================
    // setSuperPaymaster
    // ========================================

    function test_SetSuperPaymaster_Success() public {
        address newSP = address(0xCC);
        vm.prank(owner);
        bls.setSuperPaymaster(newSP);
        assertEq(bls.SUPERPAYMASTER(), newSP);
    }

    function test_SetSuperPaymaster_OnlyOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        bls.setSuperPaymaster(address(0xCC));
    }

    // ========================================
    // setDVTValidator
    // ========================================

    function test_SetDVTValidator_Success() public {
        address newDVT = address(0xDD);
        vm.prank(owner);
        bls.setDVTValidator(newDVT);
        assertEq(bls.DVT_VALIDATOR(), newDVT);
    }

    function test_SetDVTValidator_OnlyOwner_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        bls.setDVTValidator(address(0xDD));
    }

    // ========================================
    // setMinThreshold edge cases
    // ========================================

    function test_SetMinThreshold_ExceedsMax_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold > Max"));
        bls.setMinThreshold(14);
    }

    function test_SetMinThreshold_ExactMax_Success() public {
        vm.startPrank(owner);
        // Invariant: minThreshold <= defaultThreshold — raise default first
        bls.setDefaultThreshold(13);
        assertEq(bls.defaultThreshold(), 13);
        bls.setMinThreshold(13);
        assertEq(bls.minThreshold(), 13);
        vm.stopPrank();
    }

    // ========================================
    // setDefaultThreshold edge cases
    // ========================================

    function test_SetDefaultThreshold_ExceedsMax_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold > Max"));
        bls.setDefaultThreshold(14);
    }

    // ========================================
    // Constructor validation
    // ========================================

    function test_Constructor_ZeroRegistry_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidAddress.selector, address(0)));
        new BLSAggregator(address(0), sp, dvt);
    }

    /// @notice B6-N3: constructor must reject zero _superPaymaster
    function test_Constructor_ZeroSuperPaymaster_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidAddress.selector, address(0)));
        new BLSAggregator(address(registry), address(0), dvt);
    }

    /// @notice B6-N3: constructor must reject zero _dvtValidator
    function test_Constructor_ZeroDVTValidator_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidAddress.selector, address(0)));
        new BLSAggregator(address(registry), sp, address(0));
    }

    function test_Constructor_InitialState() public view {
        assertEq(bls.SUPERPAYMASTER(), sp);
        assertEq(bls.DVT_VALIDATOR(), dvt);
        assertEq(bls.minThreshold(), 3);
        assertEq(bls.defaultThreshold(), 7);
        assertEq(bls.MAX_VALIDATORS(), 13);
    }

    // ========================================
    // version()
    // ========================================

    function test_Version() public view {
        assertEq(keccak256(bytes(bls.version())), keccak256("BLSAggregator-4.1.0"));
    }

    // ========================================
    // _validateG1Point — on-curve + subgroup
    // ========================================

    /// @notice A valid G1 point (real generator) must register successfully
    ///         when the precompiles confirm it's on-curve and in the subgroup.
    ///         Here the precompile mocks installed in setUp() make G1ADD succeed
    ///         and G1MUL return 128 zero bytes (identity) — exactly the expected
    ///         response for a prime-order subgroup member.
    function test_ValidG1Point_Registers_Successfully() public {
        BLS.G1Point memory gen = _realG1Generator();
        vm.prank(owner);
        bls.registerBLSPublicKey(address(0x55), gen, 1);

        (, uint8 slot, bool active) = bls.getBLSPublicKey(address(0x55));
        assertTrue(active, "Generator should be registered");
        assertEq(slot, 1);
    }

    /// @notice The identity point (all-zero coordinates) must be rejected
    ///         before any precompile is called.
    function test_IdentityPoint_Rejected_NotOnCurve() public {
        BLS.G1Point memory identity; // zero-initialized

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKeyNotOnCurve.selector);
        bls.registerBLSPublicKey(address(0x56), identity, 2);
    }

    /// @notice A point that is not on the BLS12-381 G1 curve must be rejected.
    ///         We simulate this by making the G1ADD precompile return false
    ///         (failed staticcall) for this specific call, as a real EVM node
    ///         would do for an off-curve point.
    function test_OffCurvePoint_Rejected_NotOnCurve() public {
        // Override G1ADD (0x0b) to revert, simulating an off-curve point rejection.
        // PUSH1 0 PUSH1 0 REVERT — always reverts, so staticcall returns false.
        vm.etch(address(0x0b), hex"6000600060006000fd");

        BLS.G1Point memory badPoint;
        badPoint.x_a = bytes32(uint256(0xDEAD));
        badPoint.x_b = bytes32(uint256(0xBEEF));
        badPoint.y_a = bytes32(uint256(0xCAFE));
        badPoint.y_b = bytes32(uint256(0xBABE));

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKeyNotOnCurve.selector);
        bls.registerBLSPublicKey(address(0x57), badPoint, 3);
    }

    /// @notice A small-subgroup point (on the G1 curve but not in the prime-order
    ///         subgroup) must be rejected. We simulate this by making G1ADD succeed
    ///         (point appears to be on-curve) but making G1MUL return a non-zero
    ///         result (r*P != O, so P is not in the prime-order subgroup).
    function test_SmallSubgroupPoint_Rejected_NotInSubgroup() public {
        // G1ADD (0x0b) returns 128 zero bytes → point appears on-curve. (setUp mock)
        // Override G1MUL (0x0c) to return 128 non-zero bytes → r*P != O.
        // We deploy a tiny bytecode that returns 128 bytes of 0xFF.
        // PUSH1 0xFF, MSTORE8 at offset 0, then repeat to fill 128 bytes is complex;
        // instead we store 0xFF in slot 0 and return 128 bytes starting at memory 0.
        // Simplest: store a non-zero word, return 128 bytes from offset 0.
        // Bytecode: PUSH32 <nonzero> PUSH1 0 MSTORE PUSH1 0x80 PUSH1 0 RETURN
        // = 7f <32 bytes> 60 00 52 60 80 60 00 f3
        bytes memory mulReturnNonZero = abi.encodePacked(
            hex"7f",
            bytes32(uint256(0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF)),
            hex"6000526080600060006080600052f3"
        );
        // Simpler approach: just use vm.mockCall to return non-zero result.
        vm.clearMockedCalls();
        // Restore G1ADD mock (setUp was cleared).
        vm.etch(address(0x0b), hex"60806000f3");
        // Make G1MUL return 128 non-zero bytes.
        bytes memory nonZeroResult = new bytes(128);
        nonZeroResult[0] = 0xAB; // non-zero → r*P != O → not in subgroup
        vm.mockCall(address(0x0c), "", nonZeroResult);

        BLS.G1Point memory smallSubgroupPoint;
        smallSubgroupPoint.x_a = bytes32(uint256(0x1111));
        smallSubgroupPoint.x_b = bytes32(uint256(0x2222));
        smallSubgroupPoint.y_a = bytes32(uint256(0x3333));
        smallSubgroupPoint.y_b = bytes32(uint256(0x4444));

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKeyNotInSubgroup.selector);
        bls.registerBLSPublicKey(address(0x58), smallSubgroupPoint, 4);
    }
}
