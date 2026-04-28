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
    }

    function _key(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(0x01));
        pk.x_b = bytes32(seed);
        pk.y_a = bytes32(uint256(0x02));
        pk.y_b = bytes32(seed + 1);
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
        assertEq(keccak256(bytes(bls.version())), keccak256("BLSAggregator-4.0.0"));
    }
}
