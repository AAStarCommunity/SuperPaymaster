// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";

/// @notice Stake stub whose per-validator amount can be toggled — lets us
///         simulate post-registration exits / partial unlocks / slashes
///         without modelling the full GTokenStaking lifecycle.
contract MockStakingToggleable {
    mapping(address => uint128) public lockedAmount;

    /// @dev Default minStake on the mock RoleConfig is 100 (see MockRegistryToggleable),
    ///      so an amount of 200 passes the floor and 0 fails it.
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

/// @notice Mock Registry whose hasRole(ROLE_DVT, v) and getRoleConfig.minStake
///         can be toggled per-test to drive the new live-liveness paths.
contract MockRegistryToggleable is IRegistry {
    address public stakingAddr;
    mapping(address => bool) public dvtRoleHolders;
    uint256 public minStake;

    constructor() {
        // Default: any test validator we register also gets ROLE_DVT.
        // Tests can override per-validator via setHasDvtRole.
        minStake = 100; // chosen so MockStakingToggleable.setLocked(v, 200) passes
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
    function version() external view override returns (string memory) { return "MockRegistryToggleable"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

contract MockSP {
    enum SlashLevel { WARNING, MINOR, MAJOR }
    function executeSlashWithBLS(address, SlashLevel, bytes calldata) external {}
}

/**
 * @title DVTValidatorLivenessTest
 * @notice Regression tests for the P0 follow-up real-time liveness gate
 *         (`_requireActiveValidator`) and the new revocation paths
 *         (`pruneValidator`, `removeValidator`).
 *
 * Attack model the original P0-1 fix missed:
 *   1. Owner registers V via `addValidator` — V passes the role+stake check.
 *   2. V silently exits ROLE_DVT (Registry.exitRole) → stake is unlocked +
 *      transferred out, ROLE_DVT revoked. Local `isValidator[V]` is unchanged.
 *   3. V keeps minting proposals & driving executeWithProof with no economic
 *      backing. Combined with the original BLS forgery (P0-1) this makes the
 *      consensus layer un-stake-gated.
 *
 * The new gate re-validates against Registry+Staking on every call — so the
 * three tests below cover the three independent failure modes.
 */
contract DVTValidatorLivenessTest is Test {
    DVTValidator dvt;
    BLSAggregator bls;
    MockRegistryToggleable registry;
    MockStakingToggleable staking;
    MockSP sp;

    address owner = address(0xA1);
    address validator1 = address(0xB1);
    address validator2 = address(0xB2);
    address operator = address(0xC1);
    address randomUser = address(0xD1);

    function setUp() public {
        vm.startPrank(owner);
        registry = new MockRegistryToggleable();
        staking = new MockStakingToggleable();
        registry.setStakingAddr(address(staking));
        sp = new MockSP();

        dvt = new DVTValidator(address(registry));
        bls = new BLSAggregator(address(registry), address(sp), address(dvt));
        dvt.setBLSAggregator(address(bls));

        // Pre-load both validators with ROLE_DVT + sufficient stake so
        // addValidator succeeds; tests then mutate role/stake to trigger
        // the live-liveness checks.
        registry.setHasDvtRole(validator1, true);
        registry.setHasDvtRole(validator2, true);
        staking.setLocked(validator1, 200);
        staking.setLocked(validator2, 200);

        dvt.addValidator(validator1);
        dvt.addValidator(validator2);
        vm.stopPrank();
    }

    // ====================================
    // _requireActiveValidator on createProposal
    // ====================================

    function test_CreateProposal_RevertsWhen_StakeWithdrawn() public {
        // Simulate exitRole-triggered unlock: stake drops to zero while the
        // local `isValidator` flag is still true (it would only be cleared by
        // pruneValidator / removeValidator).
        vm.prank(owner);
        staking.setLocked(validator1, 0);

        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.ValidatorStakeBelowMinimum.selector,
            uint256(0),
            uint256(100)
        ));
        dvt.createProposal(operator, 1, "post-exit attempt");
    }

    function test_CreateProposal_RevertsWhen_RoleRevoked() public {
        // Stake is still parked, but Registry has explicitly revoked ROLE_DVT.
        vm.prank(owner);
        registry.setHasDvtRole(validator1, false);

        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.ValidatorRoleRevoked.selector,
            validator1
        ));
        dvt.createProposal(operator, 1, "no role");
    }

    function test_CreateProposal_RevertsWhen_NotInLocalSet() public {
        // randomUser was never added — should hit the cheap local check first.
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.NotActiveValidator.selector,
            randomUser
        ));
        dvt.createProposal(operator, 1, "outsider");
    }

    function test_CreateProposal_Succeeds_WhenStillEligible() public {
        // Sanity: the gate does not break the happy path.
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "still eligible");
        assertEq(id, 1);
    }

    // ====================================
    // _requireActiveValidator on executeWithProof
    // ====================================

    function test_ExecuteWithProof_RevertsWhen_RoleRevoked() public {
        // Validator1 creates a proposal while still eligible.
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "to be executed");

        // Then loses ROLE_DVT.
        vm.prank(owner);
        registry.setHasDvtRole(validator1, false);

        // Now their executeWithProof must revert. We don't even need to
        // construct a real proof — the liveness gate fires first.
        bytes memory dummyProof = abi.encode(uint256(0x01), abi.encode(BLS.G2Point(0,0,0,0,0,0,0,0)));
        vm.prank(validator1);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.ValidatorRoleRevoked.selector,
            validator1
        ));
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, dummyProof);
    }

    function test_ExecuteWithProof_BLSAggregatorBypassesLivenessGate() public {
        // The BLS aggregator path is exempt from the per-caller liveness gate
        // because it does its own per-slot validation in _reconstructPkAgg.
        // This test confirms that calling executeWithProof from BLS_AGGREGATOR
        // does NOT revert with NotActiveValidator even when the BLS aggregator
        // is not itself a validator.
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "via aggregator");

        // BLS_AGGREGATOR has never been registered as a validator; without the
        // exemption this would revert NotActiveValidator. We expect a different
        // failure later in the pipeline (the BLS pairing precompile is unmocked).
        // We only need to confirm the early gate doesn't fire.
        bytes memory dummyProof = abi.encode(uint256(0x7F), abi.encode(BLS.G2Point(0,0,0,0,0,0,0,0)));
        vm.prank(address(bls));
        // Will revert later (pairing precompile) — but NOT with NotActiveValidator.
        try dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, dummyProof) {
            // Either path is acceptable for this test — we only assert the
            // liveness gate didn't fire.
        } catch (bytes memory reason) {
            bytes4 sel;
            assembly { sel := mload(add(reason, 0x20)) }
            assertTrue(
                sel != DVTValidator.NotActiveValidator.selector,
                "BLS aggregator must bypass NotActiveValidator gate"
            );
            assertTrue(
                sel != DVTValidator.ValidatorRoleRevoked.selector,
                "BLS aggregator must bypass ValidatorRoleRevoked gate"
            );
            assertTrue(
                sel != DVTValidator.ValidatorStakeBelowMinimum.selector,
                "BLS aggregator must bypass ValidatorStakeBelowMinimum gate"
            );
        }
    }

    // ====================================
    // pruneValidator (permissionless)
    // ====================================

    function test_PruneValidator_Permissionless_WhenStakeWithdrawn() public {
        // Drop stake so validator1 is no longer eligible.
        staking.setLocked(validator1, 0);

        // Anyone (not owner, not validator) can prune.
        vm.expectEmit(true, false, false, true, address(dvt));
        emit DVTValidator.ValidatorPruned(validator1, true, 0);
        vm.prank(randomUser);
        dvt.pruneValidator(validator1);

        assertFalse(dvt.isValidator(validator1), "Validator should be pruned");
    }

    function test_PruneValidator_Permissionless_WhenRoleRevoked() public {
        registry.setHasDvtRole(validator2, false);

        vm.expectEmit(true, false, false, true, address(dvt));
        emit DVTValidator.ValidatorPruned(validator2, false, 200);
        vm.prank(randomUser);
        dvt.pruneValidator(validator2);

        assertFalse(dvt.isValidator(validator2));
    }

    function test_PruneValidator_RevertsWhen_StillEligible() public {
        // Both role and stake are intact → pruning must revert.
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.ValidatorStillEligible.selector,
            validator1
        ));
        dvt.pruneValidator(validator1);
    }

    function test_PruneValidator_RevertsWhen_NotAValidator() public {
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.NotActiveValidator.selector,
            randomUser
        ));
        dvt.pruneValidator(randomUser);
    }

    // ====================================
    // removeValidator (owner-only)
    // ====================================

    function test_RemoveValidator_OnlyOwner() public {
        // Non-owner is blocked even if they're a registered validator —
        // governance gate is on the contract owner alone.
        vm.prank(validator2);
        vm.expectRevert();
        dvt.removeValidator(validator1);

        // Owner succeeds and emits the right event.
        vm.expectEmit(true, false, false, true, address(dvt));
        emit DVTValidator.ValidatorRemoved(validator1);
        vm.prank(owner);
        dvt.removeValidator(validator1);

        assertFalse(dvt.isValidator(validator1));
    }

    function test_RemoveValidator_RevertsWhen_NotAValidator() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            DVTValidator.NotActiveValidator.selector,
            randomUser
        ));
        dvt.removeValidator(randomUser);
    }
}
