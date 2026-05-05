// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
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
 * @notice Unit tests for BLSAggregator admin functions and edge cases
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

    // ========================================
    // registerBLSPublicKey
    // ========================================

    // Helper: mock EIP-2537 precompiles for a valid key (on-curve + in prime-order subgroup).
    // IMPORTANT: vm.mockCall returns raw bytes (not ABI-encoded). The contract reads
    // the precompile output directly via assembly mload, so we must return exactly 96
    // zero bytes — not abi.encode(bytes), which would prepend offset/length headers.
    function _mockValidKeyPrecompiles() internal {
        // Mock G1ADD (0x0b): on-curve check → success, returns 96 raw zero bytes (G1 identity)
        vm.mockCall(address(0x0b), "", new bytes(96));
        // Mock G1MUL (0x0c): subgroup check → returns 96 raw zero bytes (r*P = O means valid)
        vm.mockCall(address(0x0c), "", new bytes(96));
    }

    function test_RegisterBLSPublicKey_Success() public {
        bytes memory pubKey = new bytes(96);
        pubKey[0] = 0xAB;

        _mockValidKeyPrecompiles();

        vm.prank(owner);
        bls.registerBLSPublicKey(address(0x42), pubKey);

        (bytes memory stored, bool active) = bls.blsPublicKeys(address(0x42));
        assertTrue(active, "Key should be active");
        assertEq(stored.length, 96, "Key length should be 96");
        assertEq(stored[0], pubKey[0], "Key data should match");
    }

    function test_RegisterBLSPublicKey_InvalidLength_Reverts() public {
        // 48-byte (compressed) key is no longer accepted — must be 96-byte uncompressed
        bytes memory shortKey = new bytes(48);

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKey.selector);
        bls.registerBLSPublicKey(address(0x42), shortKey);
    }

    function test_RegisterBLSPublicKey_RevertsIfWrongLength() public {
        // 32-byte key is also rejected
        bytes memory shortKey = new bytes(32);

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKey.selector);
        bls.registerBLSPublicKey(address(0x42), shortKey);
    }

    function test_RegisterBLSPublicKey_RevertsOnIdentity() public {
        // All-zero (identity) point passes both G1ADD on-curve and r*P==O subgroup
        // checks but is cryptographically invalid. Must be rejected up-front.
        bytes memory zero = new bytes(96);

        // Even if precompiles would "succeed" for the identity, the explicit
        // pre-check should revert before any precompile call.
        _mockValidKeyPrecompiles();

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKey.selector);
        bls.registerBLSPublicKey(address(0x42), zero);
    }

    function test_RegisterBLSPublicKey_RevertsIfNotOnCurve() public {
        bytes memory badKey = new bytes(96);
        badKey[0] = 0xFF; // Not a valid curve point

        // Mock G1ADD (0x0b) to fail → point not on curve
        vm.mockCallRevert(address(0x0b), "", "");

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidBLSKey.selector);
        bls.registerBLSPublicKey(address(0x42), badKey);
    }

    function test_RegisterBLSPublicKey_RevertsIfSmallSubgroup() public {
        bytes memory smallGroupKey = new bytes(96);
        smallGroupKey[0] = 0x01;

        // Mock G1ADD (0x0b): on-curve check succeeds (raw 96-byte identity)
        vm.mockCall(address(0x0b), "", new bytes(96));
        // Mock G1MUL (0x0c): returns raw non-zero bytes → r*P != O, point is in a small subgroup
        bytes memory nonZero = new bytes(96);
        nonZero[0] = 0x01;
        vm.mockCall(address(0x0c), "", nonZero);

        vm.prank(owner);
        vm.expectRevert(BLSAggregator.BLSKeyNotInSubgroup.selector);
        bls.registerBLSPublicKey(address(0x42), smallGroupKey);
    }

    function test_RegisterBLSPublicKey_SuccessWithValidKey() public {
        bytes memory validKey = new bytes(96);
        validKey[1] = 0x42;

        _mockValidKeyPrecompiles();

        vm.prank(owner);
        bls.registerBLSPublicKey(address(0x55), validKey);

        (bytes memory stored, bool active) = bls.blsPublicKeys(address(0x55));
        assertTrue(active, "Key should be active");
        assertEq(stored.length, 96, "Stored key should be 96 bytes");
    }

    function test_RegisterBLSPublicKey_OnlyOwner_Reverts() public {
        bytes memory pubKey = new bytes(96);

        vm.prank(attacker);
        vm.expectRevert();
        bls.registerBLSPublicKey(address(0x42), pubKey);
    }

    function test_RegisterBLSPublicKey_OverwritesExisting() public {
        bytes memory key1 = new bytes(96);
        key1[0] = 0x01;
        bytes memory key2 = new bytes(96);
        key2[0] = 0x02;

        _mockValidKeyPrecompiles();

        vm.startPrank(owner);
        bls.registerBLSPublicKey(address(0x42), key1);
        bls.registerBLSPublicKey(address(0x42), key2);
        vm.stopPrank();

        (bytes memory stored,) = bls.blsPublicKeys(address(0x42));
        assertEq(stored[0], key2[0], "Key should be overwritten");
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
        assertEq(keccak256(bytes(bls.version())), keccak256("BLSAggregator-3.2.1"));
    }
}
