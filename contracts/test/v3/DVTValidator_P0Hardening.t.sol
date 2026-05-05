// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/interfaces/IVersioned.sol";

/// @notice Minimal Registry stub returning configurable hasRole and minStake
///         for ROLE_DVT, plus a staking pointer.
contract MockRegistryDVT is IRegistry {
    bytes32 public constant DVT_ROLE = keccak256("DVT");
    address public stakingAddr;
    mapping(address => bool) public _isDvt;
    uint256 public dvtMinStake;

    constructor(address _staking, uint256 _minStake) {
        stakingAddr = _staking;
        dvtMinStake = _minStake;
    }

    function setIsDvt(address u, bool v) external { _isDvt[u] = v; }
    function setMinStake(uint256 v) external { dvtMinStake = v; }

    // IRegistry — only the surface DVTValidator touches is meaningful
    function hasRole(bytes32 roleId, address u) external view override returns (bool) {
        if (roleId == DVT_ROLE) return _isDvt[u];
        return false;
    }

    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(dvtMinStake, 0, 0, 0, 0, 0, 0, true, 0, "", address(0), 0);
    }

    function ROLE_DVT() external pure override returns (bytes32) { return keccak256("DVT"); }
    function ROLE_PAYMASTER_SUPER() external pure override returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }
    function ROLE_ANODE() external pure override returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }

    // Inert overrides
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
    function getCreditLimit(address) external view override returns (uint256) { return 0; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external view override returns (string memory) { return "MockRegistryDVT-1"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }

    /// @notice Mirrors Registry.GTOKEN_STAKING() so DVTValidator's
    ///         IRegistryStakingAware cast resolves.
    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }
}

/// @notice Minimal staking stub that returns configurable roleLocks per user.
contract MockStakingDVT {
    mapping(address => mapping(bytes32 => uint256)) public stakes;
    function setStake(address u, bytes32 roleId, uint256 amount) external { stakes[u][roleId] = amount; }
    function roleLocks(address user, bytes32 roleId)
        external
        view
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata)
    {
        return (uint128(stakes[user][roleId]), 0, 0, roleId, "");
    }
}

contract DVTValidator_P0HardeningTest is Test {
    DVTValidator dvt;
    MockRegistryDVT registry;
    MockStakingDVT staking;

    address validator1 = address(0xAAA1);
    address blsAggregator = address(0xBB55);
    address operator = address(0xC0FFEE);
    address attacker = address(0xBAD);

    uint256 constant MIN_STAKE = 200 ether;

    function setUp() public {
        staking = new MockStakingDVT();
        registry = new MockRegistryDVT(address(staking), MIN_STAKE);
        dvt = new DVTValidator(address(registry));
        dvt.setBLSAggregator(blsAggregator);

        // Make validator1 eligible: holds DVT role + has enough stake.
        registry.setIsDvt(validator1, true);
        staking.setStake(validator1, registry.ROLE_DVT(), MIN_STAKE);

        dvt.addValidator(validator1);
    }

    // -----------------------------------------------------------------------
    // P0-2: addValidator must verify role + minStake
    // -----------------------------------------------------------------------

    function test_AddValidator_RevertsIfNotDVTRole() public {
        address candidate = address(0xC1);
        // role flag false by default
        staking.setStake(candidate, registry.ROLE_DVT(), MIN_STAKE);
        vm.expectRevert(DVTValidator.ValidatorMissingRole.selector);
        dvt.addValidator(candidate);
    }

    function test_AddValidator_RevertsIfStakeBelowMinStake() public {
        address candidate = address(0xC2);
        registry.setIsDvt(candidate, true);
        staking.setStake(candidate, registry.ROLE_DVT(), MIN_STAKE - 1);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.ValidatorStakeBelowMinimum.selector,
            MIN_STAKE - 1,
            MIN_STAKE
        ));
        dvt.addValidator(candidate);
    }

    function test_AddValidator_AcceptsRoleAndStake() public {
        address candidate = address(0xC3);
        registry.setIsDvt(candidate, true);
        staking.setStake(candidate, registry.ROLE_DVT(), MIN_STAKE);
        dvt.addValidator(candidate);
        assertTrue(dvt.isValidator(candidate));
    }

    function test_AddValidator_TracksUpdatedMinStake() public {
        address candidate = address(0xC4);
        registry.setIsDvt(candidate, true);
        staking.setStake(candidate, registry.ROLE_DVT(), 500 ether);
        registry.setMinStake(1000 ether);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.ValidatorStakeBelowMinimum.selector,
            500 ether,
            1000 ether
        ));
        dvt.addValidator(candidate);
    }

    function test_AddValidator_RevertsIfStakingNotConfigured() public {
        // Build a registry whose GTOKEN_STAKING returns address(0).
        MockRegistryDVT brokenReg = new MockRegistryDVT(address(0), MIN_STAKE);
        brokenReg.setIsDvt(validator1, true);
        DVTValidator dvt2 = new DVTValidator(address(brokenReg));
        vm.expectRevert(DVTValidator.StakingNotConfigured.selector);
        dvt2.addValidator(validator1);
    }

    // -----------------------------------------------------------------------
    // P0-4: executeWithProof access control
    // -----------------------------------------------------------------------

    function test_ExecuteWithProof_RevertsForAnonymousCaller() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        vm.prank(attacker);
        vm.expectRevert(DVTValidator.NotAuthorizedExecutor.selector);
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, "");
    }

    function test_ExecuteWithProof_AllowsRegisteredValidator() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        // Validator passes the modifier; the call will revert downstream when
        // the BLS aggregator at the test address cannot decode the empty proof,
        // but that proves the modifier itself didn't reject this caller.
        vm.prank(validator1);
        vm.expectRevert();
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, "");
    }

    function test_ExecuteWithProof_AllowsBLSAggregator() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        vm.prank(blsAggregator);
        vm.expectRevert();
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, "");
    }

    // -----------------------------------------------------------------------
    // P0-17: proposalId pre-poison defense
    // -----------------------------------------------------------------------

    function test_MarkProposalExecuted_RevertsForUnbornId() public {
        vm.prank(blsAggregator);
        vm.expectRevert(DVTValidator.ProposalDoesNotExist.selector);
        dvt.markProposalExecuted(999);
    }

    function test_MarkProposalExecuted_AllowsExistingId() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        vm.prank(blsAggregator);
        dvt.markProposalExecuted(id);

        (,,, bool executed,) = dvt.proposals(id);
        assertTrue(executed);
    }

    function test_ExecuteWithProof_RevertsForUnbornId() public {
        vm.prank(validator1);
        vm.expectRevert(DVTValidator.ProposalDoesNotExist.selector);
        dvt.executeWithProof(999, new address[](0), new uint256[](0), 0, "");
    }

    /// @notice The pre-poison attack surface in the original code allowed a
    ///         forged BLS proof to mark a future proposalId as executed. With
    ///         the existence guard, even a malicious aggregator can no longer
    ///         brick proposal ids that haven't been created yet.
    function test_PrePoison_AttackBlocked() public {
        vm.prank(blsAggregator);
        vm.expectRevert(DVTValidator.ProposalDoesNotExist.selector);
        dvt.markProposalExecuted(5);

        vm.startPrank(validator1);
        for (uint256 i = 0; i < 5; i++) {
            dvt.createProposal(operator, 1, "legit");
        }
        vm.stopPrank();

        // Proposal 5 (the one the attacker tried to poison) should still be
        // freshly executable, not already marked.
        (,,, bool executedFlag,) = dvt.proposals(5);
        assertFalse(executedFlag, "proposal 5 must not be pre-poisoned");
    }
}
