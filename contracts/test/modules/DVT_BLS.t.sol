// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/IVersioned.sol";
import "src/interfaces/v3/IGTokenStaking.sol";

import "src/utils/BLS.sol";

/// @notice Stand-in for GTokenStaking that always reports unlimited stake —
///         lets the mocked Registry advertise sufficient backing for every
///         test validator without modelling real stake accounting.
contract MockStakingPermissive {
    function roleLocks(address, bytes32 roleId)
        external
        pure
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata)
    {
        return (type(uint128).max, 0, 0, roleId, "");
    }
}

// Mocks
contract MockRegistryV3 is IRegistry {
    address public stakingAddr;

    function setStakingAddr(address s) external { stakingAddr = s; }

    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }

    // Stubs
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        // P0-2: minStake = 0 lets test validators pass the floor without
        // having to model stake accounting in the mock; the permissive
        // staking stub still advertises max balance.
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
    function version() external view override returns (string memory) { return "MockRegistryV3"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }

    /// @notice Mirrors Registry.GTOKEN_STAKING() so the IRegistryStakingAware
    ///         cast inside DVTValidator.addValidator can resolve.
    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }
}

contract MockSuperPaymaster {
    enum SlashLevel { WARNING, MINOR, MAJOR }
    // Mock the call signature
    // executeSlashWithBLS(address,SlashLevel,bytes)
    function executeSlashWithBLS(address operator, SlashLevel level, bytes calldata proof) external {}
}

contract DVTBLSTest is Test {
    DVTValidator dvt;
    BLSAggregator bls;
    MockRegistryV3 registry;
    MockSuperPaymaster sp;

    address owner = address(1);
    address op = address(2);

    uint256 constant THRESHOLD = 7;

    function _stubKey(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(seed);
        pk.x_b = bytes32(seed + 1);
        pk.y_a = bytes32(seed + 2);
        pk.y_b = bytes32(seed + 3);
    }

    function setUp() public {
        // Mock BLS precompiles BEFORE any registerBLSPublicKey call below —
        // _validateG1Point invokes G1ADD (0x0b) and G1MUL (0x0c) at register
        // time, so the etch must already be in place.
        // 0x0b (G1ADD): returns 128 bytes (0x80) — used by _reconstructPkAgg + on-curve check.
        vm.etch(address(0x0b), hex"60806000f3");
        // 0x0c (G1MUL): returns 128 bytes of zeros (identity) so the subgroup
        // check r*P == O passes for stub keys.
        vm.etch(address(0x0c), hex"60806000f3");
        // 0x10 (MapFpToG1): returns 128 bytes (0x80)
        vm.etch(address(0x10), hex"60806000f3");
        // 0x11 (MapFp2ToG2): returns 256 bytes (0x100)
        vm.etch(address(0x11), hex"6101006000f3");
        // 0x0d (G2ADD): returns 256 bytes (0x100)
        vm.etch(address(0x0d), hex"6101006000f3");

        vm.startPrank(owner);
        registry = new MockRegistryV3();
        // P0-2: provide a permissive staking stub so addValidator's stake gate
        // resolves; minStake on the mock RoleConfig is 0 so any reported
        // balance passes the floor.
        registry.setStakingAddr(address(new MockStakingPermissive()));
        sp = new MockSuperPaymaster();

        // Circular dependency handling
        dvt = new DVTValidator(address(registry));
        bls = new BLSAggregator(address(registry), address(sp), address(dvt));

        dvt.setBLSAggregator(address(bls));

        // Add validators (10) and register their BLS keys into deterministic slots.
        for(uint i=1; i<=10; i++) {
            address v = address(uint160(i+100)); // 101..110
            dvt.addValidator(v);
            // P0-1: register typed G1 key into slot i. The first 7 keys (slots 1..7)
            // form the default-threshold quorum used by tests below.
            bls.registerBLSPublicKey(v, _stubKey(uint256(i)), uint8(i));
        }

        vm.stopPrank();
    }

    /// @notice Build a P0-1 compliant proof: only (signerMask, sigG2). pkAgg
    ///         is reconstructed inside the contract from on-chain keys.
    function _proofForMask(uint256 signerMask) internal pure returns (bytes memory) {
        BLS.G2Point memory sig; // zeroed — pairing precompile is mocked
        return abi.encode(signerMask, abi.encode(sig));
    }

    function test_DVT_ProposalFlow() public {
        vm.startPrank(address(101)); // Validator 1
        uint256 id = dvt.createProposal(op, 1, "Bad Operator");
        assertEq(id, 1);
        vm.stopPrank();

        // ✅ Signatures now collected off-chain via DVT P2P protocol
        // Skip on-chain signProposal calls

        // P0-4: executeWithProof now restricted to BLS aggregator or registered
        // validators. Use Validator 1 to drive the call.
        vm.startPrank(address(101));

        // Mock BLS pairing as success
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        // 7 signers across slots 1..7 = bits 0..6 set = 0x7F.
        bytes memory mockProof = _proofForMask(0x7F);

        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, mockProof);
        vm.stopPrank();

        // Check proposal was executed
        (,,,bool executed,) = dvt.proposals(id);
        assertTrue(executed, "Proposal should be executed");
    }

    function test_BLS_ManualVerify() public {
        // P0-17: BLSAggregator now calls back into DVTValidator.markProposalExecuted
        // which requires the proposal to exist. Create it first via the legitimate
        // validator path so the callback can find a real proposal record.
        vm.prank(address(101)); // Validator 1
        uint256 id = dvt.createProposal(op, 1, "Bad Operator");

        // Mock BLS pairing as success — the test focuses on the access control
        // and proposal lifecycle, not on real pairing arithmetic.
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        bytes memory mockProof = _proofForMask(0x7F);

        vm.prank(address(dvt));

        bls.verifyAndExecute(
            id, op, 1,
            new address[](0), new uint256[](0), 123,
            mockProof
        );

        assertTrue(bls.executedProposals(id));
    }

    function test_Fail_NotValidator() public {
        // P0 follow-up: createProposal now goes through _requireActiveValidator
        // which reverts NotActiveValidator(v) for unregistered callers — the
        // old NotValidator() error is no longer reached on this path.
        vm.prank(address(0x999));
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.NotActiveValidator.selector,
            address(0x999)
        ));
        dvt.createProposal(op, 1, "fail");
    }
}
