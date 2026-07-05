// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

/**
 * @title BLSGasMeasurement
 * @notice Gas benchmark for Paper7 (CommunityFi) §5.4.3
 *         Tests BLSAggregator V4.1.0 using ISOLATED mode (mocked precompiles + registry)
 *         with analytical EIP-2537 correction.
 *
 * Sepolia v5.3.2 deployed contracts (2026-05-13):
 *   BLSAggregator : 0x12Ae250EF63adCEF487B5679b917011D508687AB  (BLSAggregator-4.1.0)
 *   DVTValidator  : 0x6b131ac781Adea7785d4DFfF612E5A26B37F0D0d
 *   Registry      : 0x3dfeBE636eDA211E0a783308Cf0CB31892686d67  (Registry-5.3.3)
 *   SuperPaymaster: 0x506962D17AEA6E7A15fd3479D8c4E2ABBBF91112  (SuperPaymaster-5.3.2)
 *   PaymasterV4   : 0x3e3ae35c545E5fc0E7746E67F21f5cf1230930A8
 *   GTokenAuth    : 0xbC17B6C319561bcA805981fC2846e4678f9114Cb  (EIP-3009)
 *   aPNTs         : 0x6859dC0b5ee1CcE829673161B7a3550CC4A25E48
 *
 * OP Mainnet (Isthmus active 2025-05-09, EIP-2537 live):
 *   BLSAggregator : 0x1C305372ecc5a36CBef1FA371392234bCD55eB19  (BLSAggregator-3.2.1)
 *
 * NOTE: Fork mode is NOT used for gas benchmarks because BLSAggregator._reconstructPkAgg
 * performs real-time REGISTRY.hasRole + staking.roleLocks checks for every signer slot,
 * and DVTValidator._requireActiveValidator has the same dependency. With no DVT validators
 * registered on-chain, fork mode would fail these security checks. ISOLATED mode with
 * mocked Registry + analytically-corrected EIP-2537 costs is the correct approach.
 *
 * Run: forge test --match-contract BLSGasMeasurement -vv
 * Parse: forge test --match-contract BLSGasMeasurement -vv 2>&1 | grep PAPER7
 */

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/utils/BLS.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";

// ---------------------------------------------------------------------------
// Mocks (replicate registry+staking without chain state dependencies)
// ---------------------------------------------------------------------------

contract MockRegistryGas is IRegistry {
    address public stakingAddr;

    function setStakingAddr(address s) external {
        stakingAddr = s;
    }

    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external
        override
    {}

    function hasRole(bytes32, address) external pure override returns (bool) {
        return true;
    }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}

    function getRoleConfig(bytes32) external pure override returns (RoleConfig memory) {
        return RoleConfig(0, 0, 0, 0, 0, 0, 0, false, 0, "dvt", address(0), 0);
    }

    function getRoleUserCount(bytes32) external pure override returns (uint256) {
        return 0;
    }

    function getUserRoles(address) external pure override returns (bytes32[] memory) {
        return new bytes32[](0);
    }
    function registerRole(bytes32, address, bytes calldata) external override {}

    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) {
        return 0;
    }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}

    function getCreditLimit(address) external pure override returns (uint256) {
        return 100 ether;
    }

    function isReputationSource(address) external pure override returns (bool) {
        return true;
    }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}

    function version() external pure override returns (string memory) {
        return "MockRegistry";
    }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}

    function getEffectiveStake(address, bytes32) external pure override returns (uint256) {
        return 0;
    }
}

contract MockStakingGas {
    function roleLocks(address, bytes32 roleId)
        external
        pure
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata)
    {
        return (type(uint128).max, 0, 0, roleId, "");
    }
}

contract MockSuperPaymasterGas {
    function queueSlash(address) external {}
    function executeSlashWithBLS(address, uint8, bytes calldata) external {}
}

// ---------------------------------------------------------------------------
// Benchmark contract
// ---------------------------------------------------------------------------

contract BLSGasMeasurement is Test {
    // EIP-2537 precompile gas (post-Pectra, used for analytical correction in ISOLATED mode)
    // Source: https://eips.ethereum.org/EIPS/eip-2537
    uint256 constant GAS_G1ADD = 500;
    uint256 constant GAS_MAP_FP2_TO_G2 = 110_000;
    uint256 constant GAS_G2ADD = 800;
    uint256 constant GAS_PAIRING_BASE = 115_000;
    uint256 constant GAS_PAIRING_PER = 23_000;

    BLSAggregator bls;
    DVTValidator dvt;
    MockRegistryGas mockReg;
    MockStakingGas mockStk;
    MockSuperPaymasterGas mockSp;

    address constant OWNER = address(0x1111);
    address constant VAL1 = address(uint160(0x1001));
    uint8 constant N = 13;

    function _stub(uint256 s) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(1));
        pk.x_b = bytes32(s);
        pk.y_a = bytes32(uint256(2));
        pk.y_b = bytes32(s + 1);
    }
    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function _mask(uint8 n) internal pure returns (uint256 m) {
        for (uint8 i = 0; i < n; i++) {
            m |= (1 << i);
        }
    }

    function _proof(uint8 n) internal pure returns (bytes memory) {
        BLS.G2Point memory sig;
        return abi.encode(_mask(n), abi.encode(sig));
    }

    function _aGas(uint8 n) internal pure returns (uint256) {
        return
            (n > 1 ? uint256(n - 1) * GAS_G1ADD : 0) + GAS_MAP_FP2_TO_G2 + GAS_G2ADD + GAS_PAIRING_BASE + 2
                * GAS_PAIRING_PER;
    }

    function setUp() public {
        // Stub precompile addresses so registerBLSPublicKey + verify pass
        vm.etch(address(0x0b), hex"60806000f3"); // G1ADD
        vm.etch(address(0x0c), hex"60806000f3"); // G1MUL
        vm.etch(address(0x0d), hex"6101006000f3"); // G2ADD
        vm.etch(address(0x11), hex"6101006000f3"); // MapFp2ToG2

        vm.startPrank(OWNER);
        mockReg = new MockRegistryGas();
        mockStk = new MockStakingGas();
        mockReg.setStakingAddr(address(mockStk));
        mockSp = new MockSuperPaymasterGas();
        dvt = new DVTValidator(address(mockReg));
        bls = new BLSAggregator(address(mockReg), address(mockSp), address(dvt));
        dvt.setBLSAggregator(address(bls));
        // minThreshold=3 so n=3 tests pass; defaultThreshold=3
        bls.setMinThreshold(3);
        bls.setDefaultThreshold(3);
        // Register N validators
        for (uint8 i = 1; i <= N; i++) {
            address v = address(uint160(0x1000 + i));
            dvt.addValidator(v);
            bls.registerBLSPublicKey(v, _stub(uint256(i)), i, _emptyPoP());
        }
        vm.stopPrank();
        console.log("[PAPER7_META] BLSAggregator", address(bls));
        console.log("[PAPER7_META] version", bls.version());
        console.log("[PAPER7_META] Sepolia_v5.3.2 BLSAggregator-4.1.0 @ 0x12Ae250EF63adCEF487B5679b917011D508687AB");
    }

    // T1: registerBLSPublicKey
    function test_Gas_01_RegisterBLSKey() public {
        MockRegistryGas r2 = new MockRegistryGas();
        MockStakingGas s2 = new MockStakingGas();
        r2.setStakingAddr(address(s2));
        MockSuperPaymasterGas sp2 = new MockSuperPaymasterGas();
        DVTValidator d2 = new DVTValidator(address(r2));
        vm.prank(OWNER);
        BLSAggregator b2 = new BLSAggregator(address(r2), address(sp2), address(d2));
        vm.prank(OWNER);
        uint256 g = gasleft();
        b2.registerBLSPublicKey(address(0xABCD), _stub(99), 1, _emptyPoP());
        console.log("[PAPER7_GAS] registerBLSPublicKey", g - gasleft());
    }

    // T2-T4: verify() n=3,7,13
    function test_Gas_02_Verify_n3() public {
        _verify(3);
    }

    function test_Gas_03_Verify_n7() public {
        _verify(7);
    }

    function test_Gas_04_Verify_n13() public {
        _verify(13);
    }

    function _verify(uint8 n) internal {
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        BLS.G2Point memory sig;
        uint256 g = gasleft();
        bool ok = bls.verify(keccak256("p7"), _mask(n), n, abi.encode(sig));
        uint256 used = g - gasleft();
        assertTrue(ok);
        string memory lbl = string.concat("[PAPER7_GAS] verify_n", vm.toString(uint256(n)));
        console.log(lbl, used);
        console.log(string.concat(lbl, "_corrected_eip2537"), used + _aGas(n));
    }

    // T5-T10: verifyAndExecute() via DVT flow
    function test_Gas_05_VaE_rep_n3_b10() public {
        _vae(3, false, 10);
    }

    function test_Gas_06_VaE_rep_n7_b10() public {
        _vae(7, false, 10);
    }

    function test_Gas_07_VaE_rep_n13_b10() public {
        _vae(13, false, 10);
    }

    function test_Gas_08_VaE_rep_n7_b50() public {
        _vae(7, false, 50);
    }

    function test_Gas_09_VaE_rep_n7_b100() public {
        _vae(7, false, 100);
    }

    function test_Gas_10_VaE_slash_n7_b10() public {
        _vae(7, true, 10);
    }

    function _vae(uint8 n, bool slash, uint256 bsz) internal {
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        address[] memory us = new address[](bsz);
        uint256[] memory sc = new uint256[](bsz);
        for (uint256 i = 0; i < bsz; i++) {
            us[i] = address(uint160(0x5000 + i));
            sc[i] = 100 + i;
        }
        vm.prank(VAL1);
        uint256 pid = dvt.createProposal(slash ? address(0xDEAD) : address(0), slash ? 1 : 0, "p7");
        bytes memory proof = _proof(n);
        vm.prank(VAL1);
        uint256 g = gasleft();
        dvt.executeWithProof(pid, us, sc, 1, proof);
        uint256 used = g - gasleft();
        string memory lbl = slash ? "vae_slash" : "vae_rep";
        string memory key = string.concat(lbl, "_n", vm.toString(uint256(n)), "_b", vm.toString(bsz));
        console.log(string.concat("[PAPER7_GAS] ", key), used);
        console.log(string.concat("[PAPER7_GAS] ", key, "_corrected_eip2537"), used + _aGas(n));
    }

    // T11: Daily cost scaling (Paper7 §5.4.4)
    function test_Gas_11_DailyCostScaling() public {
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        address[] memory u1 = new address[](1);
        uint256[] memory s1 = new uint256[](1);
        u1[0] = address(0x9001);
        s1[0] = 100;
        vm.prank(VAL1);
        uint256 pid1 = dvt.createProposal(address(0), 0, "d1");
        vm.prank(VAL1);
        uint256 g = gasleft();
        dvt.executeWithProof(pid1, u1, s1, 1, _proof(7));
        uint256 b1 = g - gasleft();

        address[] memory u100 = new address[](100);
        uint256[] memory s100 = new uint256[](100);
        for (uint256 i = 0; i < 100; i++) {
            u100[i] = address(uint160(0x9100 + i));
            s100[i] = 100 + i;
        }
        vm.prank(VAL1);
        uint256 pid2 = dvt.createProposal(address(0), 0, "d2");
        vm.prank(VAL1);
        g = gasleft();
        dvt.executeWithProof(pid2, u100, s100, 1, _proof(7));
        uint256 b100 = g - gasleft();

        uint256 tb1 = b1 + _aGas(7);
        uint256 tb100 = b100 + _aGas(7);
        console.log("[PAPER7_GAS] batch1_gas", tb1);
        console.log("[PAPER7_GAS] batch100_gas", tb100);
        console.log("[PAPER7_GAS] amortized_per_user_b1", tb1);
        console.log("[PAPER7_GAS] amortized_per_user_b100", tb100 / 100);
        console.log("[PAPER7_GAS] communityFi_1000_daily", 10 * tb100);
        console.log("[PAPER7_GAS] multisig_1000_daily", uint256(1_000 * 50_000));
        console.log("[PAPER7_GAS] reduction_factor", uint256(1_000 * 50_000) / (10 * tb100));
    }
}
