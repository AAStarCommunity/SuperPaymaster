// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {BLSRegistrationTestHelper} from "../helpers/BLSRegistration.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/utils/BLS.sol";
import "src/interfaces/v3/IRegistry.sol";
import {GenuineBLS} from "../helpers/GenuineBLS.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";

// Minimal mock registry (same pattern as GenericDVTProposal.t.sol)
contract MockRegistryUnit is IRegistry {
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external
        override
    {}

    function hasRole(bytes32, address) external pure override returns (bool) {
        return true;
    }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}

    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(0, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }

    function getRoleUserCount(bytes32) external view override returns (uint256) {
        return 0;
    }

    function getUserRoles(address) external view override returns (bytes32[] memory) {
        return new bytes32[](0);
    }
    function registerRole(bytes32, address, bytes calldata) external override {}

    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) {
        return 0;
    }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}

    function getCreditLimit(address) external view override returns (uint256) {
        return 100 ether;
    }

    function isReputationSource(address) external pure override returns (bool) {
        return true;
    }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}

    function version() external view override returns (string memory) {
        return "MockRegistryUnit";
    }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}

    function getEffectiveStake(address, bytes32) external view override returns (uint256) {
        return 0;
    }
}

/**
 * @title BLSAggregatorUnitTest
 * @notice Unit tests for BLSAggregator admin functions and edge cases (P0-1).
 *         The new ABI takes a typed `BLS.G1Point` plus a 1-indexed slot — the
 *         old `bytes(48)` compressed-key API is gone, along with the ability
 *         for callers to inject pkAgg into proofs.
 */
contract BLSAggregatorUnitTest is BLSRegistrationTestHelper {
    BLSAggregator bls;
    bool internal realMode;
    mapping(bytes32 => mapping(address => BLS.G2Point)) internal pops;
    mapping(bytes32 => mapping(address => bool)) private popPrepared;
    MockRegistryUnit registry;

    address owner = address(1);
    address attacker = address(0x1337);
    address sp = address(0xAA);
    address dvt = address(0xBB);

    function setUp() public {
        realMode = MockedPrecompiles.praguePrecompilesAvailable();
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
        if (realMode) return;
        vm.etch(address(0x0b), hex"60806000f3"); // PUSH1 0x80 PUSH1 0 RETURN → 128 zero bytes
        // G1MUL must return 128 bytes of zeros (identity) to satisfy r*P == O.
        vm.etch(address(0x0c), hex"60806000f3"); // same bytecode → 128 zero bytes
        // CC-48 round-3: registerBLSPublicKey now verifies a proof-of-possession on the
        // owner path too, which walks hashToG2 (MAP_FP2_TO_G2 + G2ADD) and then the
        // pairing precompile. Stub all three so this unit suite keeps testing slot /
        // duplicate / validation bookkeeping rather than curve arithmetic; the genuine
        // pairing behaviour is covered under --evm-version prague in
        // contracts/test/paper7/RepCreditDomainReplay.t.sol.
        vm.etch(address(0x0d), hex"6101006000f3"); // G2ADD → 256 zero bytes
        vm.etch(address(0x10), hex"60806000f3");   // MAP_FP_TO_G1 → 128 zero bytes
        vm.etch(address(0x11), hex"6101006000f3"); // MAP_FP2_TO_G2 → 256 zero bytes
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
    }

    /// @dev Real modes use a genuine key and cached PoPs; Cancun retains stub keys.
    function _key(uint256 seed) internal returns (BLS.G1Point memory pk) {
        if (realMode) {
            pk = GenuineBLS.publicKey(seed);
        } else {
            pk.x_a = bytes32(uint256(0x01));
            pk.x_b = bytes32(seed);
            pk.y_a = bytes32(uint256(0x02));
            pk.y_b = bytes32(seed + 1);
        }
        // Prepare PoPs before prank/expectRevert so helper external calls
        // cannot consume the cheatcode intended for registration.
        address[3] memory validators = [address(0x42), address(0x43), address(0x55)];
        for (uint256 i = 0; i < validators.length; ++i) {
            _preparePop(pk, seed, validators[i]);
        }
    }

    function _preparePop(BLS.G1Point memory pk, uint256 seed, address validator) internal {
        bytes32 id = keccak256(abi.encode(pk));
        if (realMode) {
            pops[id][validator] = GenuineBLS.pop(bls, validator, seed);
        }
        popPrepared[id][validator] = true;
    }

    function _popFor(BLS.G1Point memory pk, address validator) internal view returns (BLS.G2Point memory) {
        bytes32 id = keccak256(abi.encode(pk));
        if (!popPrepared[id][validator]) {
            revert("BLSAggregatorUnit: PoP not prepared for validator; call _preparePop first");
        }
        return pops[id][validator];
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    /// @dev External wrapper so expectRevert can observe the helper's revert.
    function popForExternal(BLS.G1Point memory pk, address validator) external view returns (BLS.G2Point memory) {
        return _popFor(pk, validator);
    }

    function test_PopFor_UnpreparedValidator_Reverts() public {
        BLS.G1Point memory pk = _key(7);
        this.popForExternal(pk, address(0x42)); // prepared by _key: must not revert
        vm.expectRevert(bytes("BLSAggregatorUnit: PoP not prepared for validator; call _preparePop first"));
        this.popForExternal(pk, address(0x99));
    }

    /// @dev Returns the real BLS12-381 G1 generator point (uncompressed, EIP-2537).
    ///      Gx = 0x17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb
    ///      Gy = 0x08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1
    function _realG1Generator() internal returns (BLS.G1Point memory pk) {
        pk = GenuineBLS.g1Generator();
        // Cancun registers this generator without _key. Mark the same three
        // validators prepared so the empty stub PoP is explicit, not a miss.
        if (!realMode) {
            address[3] memory validators = [address(0x42), address(0x43), address(0x55)];
            for (uint256 i = 0; i < validators.length; ++i) {
                _preparePop(pk, 0, validators[i]);
            }
        }
    }

    // ========================================
    // registerBLSPublicKey
    // ========================================

    function test_RegisterBLSPublicKey_Success() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(owner);
        _registerKey(bls, dvt, address(0x42), pk, 1, _popFor(pk, address(0x42)));

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
        _registerKey(bls, dvt, address(0), pk, 1, _emptyPoP());
    }

    function test_RegisterBLSPublicKey_SlotZero_Reverts() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotOutOfRange.selector, uint8(0)));
        _registerKey(bls, dvt, address(0x42), pk, 0, _popFor(pk, address(0x42)));
    }

    function test_RegisterBLSPublicKey_SlotAboveMax_Reverts() public {
        BLS.G1Point memory pk = _key(0xAB);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotOutOfRange.selector, uint8(65)));
        _registerKey(bls, dvt, address(0x42), pk, 65, _popFor(pk, address(0x42)));
    }

    function test_RegisterBLSPublicKey_SlotCollision_Reverts() public {
        BLS.G1Point memory pk1 = _key(0x01);
        BLS.G1Point memory pk2 = _key(0x02);

        vm.startPrank(owner);
        _registerKey(bls, dvt, address(0x42), pk1, 3, _popFor(pk1, address(0x42)));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotAlreadyTaken.selector, uint8(3)));
        _registerKey(bls, dvt, address(0x43), pk2, 3, _popFor(pk2, address(0x43)));
        vm.stopPrank();
    }

    function test_RegisterBLSPublicKey_OnlyDVT_Reverts() public {
        BLS.G1Point memory pk = _key(1);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnauthorizedCaller.selector, attacker));
        bls.registerBLSPublicKey(address(0x42), pk, 1, _popFor(pk, address(0x42)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnauthorizedCaller.selector, owner));
        bls.registerBLSPublicKey(address(0x42), pk, 1, _popFor(pk, address(0x42)));
    }

    function test_RegisterBLSPublicKey_OverwritesExistingSameSlot() public {
        BLS.G1Point memory pk1 = _key(0x01);
        BLS.G1Point memory pk2 = _key(0x02);

        vm.startPrank(owner);
        _registerKey(bls, dvt, address(0x42), pk1, 5, _popFor(pk1, address(0x42)));
        _registerKey(bls, dvt, address(0x42), pk2, 5, _popFor(pk2, address(0x42)));
        vm.stopPrank();

        (BLS.G1Point memory stored, uint8 slot, bool active) = bls.getBLSPublicKey(address(0x42));
        assertEq(stored.x_b, pk2.x_b, "Key should be overwritten");
        assertEq(slot, 5);
        assertTrue(active);
    }

    function test_RegisterBLSPublicKey_ChangeSlotForSameValidator_Reverts() public {
        BLS.G1Point memory pk = _key(0x01);

        vm.startPrank(owner);
        _registerKey(bls, dvt, address(0x42), pk, 4, _popFor(pk, address(0x42)));
        // Switching slot for an already-active validator could leave a dangling
        // slot pointer — explicitly disallowed.
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotAlreadyTaken.selector, uint8(7)));
        _registerKey(bls, dvt, address(0x42), pk, 7, _popFor(pk, address(0x42)));
        vm.stopPrank();
    }

    function test_RevokeBLSPublicKey_FreesSlot() public {
        BLS.G1Point memory pk1 = _key(0x01);
        BLS.G1Point memory pk2 = _key(0x02);

        vm.startPrank(owner);
        _registerKey(bls, dvt, address(0x42), pk1, 8, _popFor(pk1, address(0x42)));
        bls.revokeBLSPublicKey(address(0x42));

        // After revoke, slot 8 is free for a fresh validator.
        _registerKey(bls, dvt, address(0x43), pk2, 8, _popFor(pk2, address(0x43)));
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
        vm.mockCall(dvt, abi.encodeWithSignature("nextProposalId()"), abi.encode(uint256(12)));
        vm.mockCall(newDVT, abi.encodeWithSignature("BLS_AGGREGATOR()"), abi.encode(address(bls)));
        vm.mockCall(newDVT, abi.encodeWithSignature("REGISTRY()"), abi.encode(address(registry)));
        vm.prank(owner);
        bls.setDVTValidator(newDVT);
        assertEq(bls.proposalFloor(), 12);
        assertEq(bls.DVT_VALIDATOR(), newDVT);
    }

    function test_SetDVTValidator_OnlyOwner_Reverts() public {
        address newDVT = address(0xDD);
        vm.mockCall(dvt, abi.encodeWithSignature("nextProposalId()"), abi.encode(uint256(12)));
        vm.mockCall(newDVT, abi.encodeWithSignature("BLS_AGGREGATOR()"), abi.encode(address(bls)));
        vm.mockCall(newDVT, abi.encodeWithSignature("REGISTRY()"), abi.encode(address(registry)));
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        bls.setDVTValidator(newDVT);
        assertEq(bls.DVT_VALIDATOR(), dvt);
        assertEq(bls.proposalFloor(), 0);

        vm.prank(owner);
        bls.setDVTValidator(newDVT);
        assertEq(bls.DVT_VALIDATOR(), newDVT);
        assertEq(bls.proposalFloor(), 12);
    }

    // ========================================
    // setMinThreshold edge cases
    // ========================================

    function test_SetMinThreshold_ExceedsMax_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidThreshold.selector);
        bls.setMinThreshold(65);
    }

    function test_SetMinThreshold_ExactMax_Success() public {
        vm.startPrank(owner);
        // Invariant: minThreshold <= defaultThreshold — raise default first
        bls.setDefaultThreshold(64);
        assertEq(bls.defaultThreshold(), 64);
        bls.setMinThreshold(64);
        assertEq(bls.minThreshold(), 64);
        vm.stopPrank();
    }

    // ========================================
    // setDefaultThreshold edge cases
    // ========================================

    function test_SetDefaultThreshold_ExceedsMax_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidThreshold.selector);
        bls.setDefaultThreshold(65);
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
        assertEq(bls.minThreshold(), 3); // generic path floor unchanged; slash floor is SLASH_THRESHOLD_FLOOR=2
        assertEq(bls.defaultThreshold(), 7);
        assertEq(bls.MAX_VALIDATORS(), 64);
        // Per-severity slash table bootstrap (N=3): WARNING 2, MINOR 3, MAJOR 3.
        assertEq(bls.slashThresholds(0), 2);
        assertEq(bls.slashThresholds(1), 3);
        assertEq(bls.slashThresholds(2), 3);
        assertEq(bls.slashPolicyAdmin(), owner); // initial admin = deployer
    }

    // ========================================
    // version()
    // ========================================

    function test_Version() public view {
        assertEq(keccak256(bytes(bls.version())), keccak256("BLSAggregator-4.14.0"));
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
        BLS.G1Point memory gen = realMode ? _key(1) : _realG1Generator();
        vm.prank(owner);
        _registerKey(bls, dvt, address(0x55), gen, 1, _popFor(gen, address(0x55)));

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
        _registerKey(bls, dvt, address(0x56), identity, 2, _emptyPoP());
    }

    /// @notice A point that is not on the BLS12-381 G1 curve must be rejected.
    ///         We simulate this by making the G1ADD precompile return false
    ///         (failed staticcall) for this specific call, as a real EVM node
    ///         would do for an off-curve point.
    function test_OffCurvePoint_Rejected_NotOnCurve() public {
        // Override G1ADD (0x0b) to revert, simulating an off-curve point rejection.
        // PUSH1 0 PUSH1 0 REVERT — always reverts, so staticcall returns false.
        if (realMode) vm.mockCallRevert(address(0x0b), "", "");
        else vm.etch(address(0x0b), hex"6000600060006000fd");

        BLS.G1Point memory badPoint;
        badPoint.x_a = bytes32(uint256(0xDEAD));
        badPoint.x_b = bytes32(uint256(0xBEEF));
        badPoint.y_a = bytes32(uint256(0xCAFE));
        badPoint.y_b = bytes32(uint256(0xBABE));

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKeyNotOnCurve.selector);
        _registerKey(bls, dvt, address(0x57), badPoint, 3, _emptyPoP());
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
        if (realMode) vm.mockCall(address(0x0b), "", new bytes(128));
        else vm.etch(address(0x0b), hex"60806000f3");
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
        _registerKey(bls, dvt, address(0x58), smallSubgroupPoint, 4, _emptyPoP());
    }
}
