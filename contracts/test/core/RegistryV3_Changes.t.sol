// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/core/Registry.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/tokens/MySBT.sol";
import "../../src/tokens/GToken.sol";
import "../../src/interfaces/v3/IRegistry.sol";
import "../../src/interfaces/v3/IMySBT.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

// Mock MySBT to avoid complex dependencies but still verify deactivation
contract MockMySBT is IMySBT {
    address public lastDeactivatedUser;
    address public lastDeactivatedCommunity;

    function mintForRole(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function airdropMint(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function getUserSBT(address) external pure returns (uint256) { return 1; }
    function getSBTData(uint256) external pure returns (SBTData memory) {
        return SBTData(address(0), address(0), 0, 0);
    }
    function verifyCommunityMembership(address, address) external pure returns (bool) { return true; }
    function deactivateMembership(address user, address community) external override {
        lastDeactivatedUser = user;
        lastDeactivatedCommunity = community;
    }
    function deactivateAllMemberships(address /* user */) external override {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function burnSBT(address) external {}
}

// M-2 (#324): a SuperPaymaster that is up at register time (status=true succeeds) but reverts on
// the exit call (status=false), modelling an SP that became paused/faulty after the user registered.
// This exercises the exitRole non-fatal path without breaking the (intentionally fatal) register path.
contract RevertingSP {
    function updateSBTStatus(address, bool status) external pure {
        if (!status) revert("SP: updateSBTStatus down");
    }
}

contract RegistryV3_Changes_Test is Test {
    Registry registry;
    GTokenStaking staking;
    MockMySBT mockMySBT;
    GToken gtoken;
    
    address admin = address(0x1);
    address community = address(0x2);
    address user = address(0x3);
    address ReputationSource = address(0x4);
    
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    // Copy struct from Registry to ensure encoding match
    struct TestCommunityRoleData { string name; string ensName; uint256 stakeAmount; }
    
    function setUp() public {
        vm.startPrank(admin);
        gtoken = new GToken(1000000 ether);
        mockMySBT = new MockMySBT();

        registry = UUPSDeployHelper.deployRegistryProxy(admin, address(0), address(mockMySBT));
        staking = new GTokenStaking(address(gtoken), admin, address(registry));
        registry.setStaking(address(staking));
        vm.stopPrank();
    }

    function test_ExitRole_CommunityDeactivation() public {
        vm.prank(admin);
        gtoken.mint(community, 100 ether);

        vm.startPrank(community);
        gtoken.approve(address(staking), 100 ether);

        TestCommunityRoleData memory dataStruct = TestCommunityRoleData("TestCommunity", "test.eth", 30 ether);
        bytes memory data = abi.encode(dataStruct);

        registry.registerRole(ROLE_COMMUNITY, community, data);

        assertTrue(registry.hasRole(ROLE_COMMUNITY, community));
        assertEq(registry.getCommunityByName("TestCommunity"), community);
        assertEq(registry.getCommunityByENS("test.eth"), community);

        // COMMUNITY exit succeeds — cleanup name/ENS slots
        registry.exitRole(ROLE_COMMUNITY);

        // Role should be removed, name/ENS slots freed
        assertFalse(registry.hasRole(ROLE_COMMUNITY, community));
        assertEq(registry.getCommunityByName("TestCommunity"), address(0));
        assertEq(registry.getCommunityByENS("test.eth"), address(0));
        vm.stopPrank();
    }

    /// @dev M-2 (#324): a reverting SuperPaymaster.updateSBTStatus must NOT deadlock exitRole and
    ///      freeze the user's locked stake. exitRole succeeds, emits SBTStatusSyncFailed, releases stake.
    function test_ExitRole_NonFatal_When_UpdateSBTStatus_Reverts() public {
        RevertingSP badSP = new RevertingSP();
        vm.prank(admin);
        registry.setSuperPaymaster(address(badSP));

        vm.prank(admin);
        gtoken.mint(community, 100 ether);

        vm.startPrank(community);
        gtoken.approve(address(staking), 100 ether);
        TestCommunityRoleData memory dataStruct = TestCommunityRoleData("SyncTest", "sync.eth", 30 ether);
        registry.registerRole(ROLE_COMMUNITY, community, abi.encode(dataStruct));
        assertTrue(registry.hasRole(ROLE_COMMUNITY, community));

        // Pre-fix, exitRole reverts here ("SP: updateSBTStatus down") — deadlocking the exit and
        // freezing any locked stake. Post-fix, the SP revert is swallowed into SBTStatusSyncFailed
        // and exitRole completes (proving the withdrawal path is no longer held hostage by the SP).
        vm.expectEmit(true, true, false, false, address(registry));
        emit IRegistry.SBTStatusSyncFailed(community, ROLE_COMMUNITY);
        registry.exitRole(ROLE_COMMUNITY);

        // exitRole completed despite the SuperPaymaster revert; role fully removed.
        assertFalse(registry.hasRole(ROLE_COMMUNITY, community), "role removed despite SP revert");
        vm.stopPrank();
    }

    // NOTE: This test is skipped because Registry has an Anvil chainid check (31337)
    // that bypasses BLS verification for testing compatibility.
    // To test BLS verification failure, remove the Anvil check in Registry.sol first.
    function skip_test_BLS_PairingCheck_FailedVerification() public {
        // Set chainId to non-Anvil value to enforce BLS verification
        vm.chainId(1); // Mainnet chainId
        
        vm.prank(admin);
        registry.setReputationSource(ReputationSource, true);
        
        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory scores = new uint256[](1);
        scores[0] = 100;
        
        bytes memory badProof = abi.encode(
            new bytes(96), 
            new bytes(192), 
            new bytes(192), 
            uint256(0xF)    
        );

        vm.prank(ReputationSource);
        vm.expectRevert("BLS Verification Failed");
        registry.batchUpdateGlobalReputation(1, users, scores, 1, badProof);
        
        // Restore Anvil chainId
        vm.chainId(31337);
    }

    /// @notice L-C (#211): epoch=0 must revert InvalidParam BEFORE the proposalId is
    ///         marked executed — otherwise the proposalId is permanently burned (all
    ///         users skipped by `epoch <= lastReputationEpoch`, yet executedProposals set).
    function test_LC_Epoch0_Reverts_WithoutBurningProposalId() public {
        vm.startPrank(admin);
        registry.setReputationSource(ReputationSource, true);
        registry.setBLSAggregator(address(0xB15)); // non-zero: pass the BLSNotConfigured guard
        vm.stopPrank();

        address[] memory users = new address[](1);
        users[0] = user;
        uint256[] memory scores = new uint256[](1);
        scores[0] = 100;
        bytes memory proof = abi.encode(new bytes(96), new bytes(192), new bytes(192), uint256(0xF));

        // epoch=0 must revert InvalidParam. The guard (Registry.sol) sits at L405 —
        // BEFORE `executedProposals[proposalId] = true` (L409) — so the EVM revert rolls
        // back the whole call and the proposalId is never marked executed: it stays
        // resubmittable with a valid epoch. (Pre-fix, the proposalId was burned: marked
        // executed yet every user skipped by `epoch <= lastReputationEpoch`.)
        vm.prank(ReputationSource);
        vm.expectRevert(Registry.InvalidParam.selector);
        registry.batchUpdateGlobalReputation(7, users, scores, 0, proof);
    }

    function test_O1_Removal() public {
        // Use an operator role (KMS) to test O(1) removal, since non-operator roles cannot exit
        bytes32 ROLE_KMS = keccak256("KMS");
        address user1 = address(0x111);
        address user2 = address(0x222);
        address user3 = address(0x333);

        vm.startPrank(admin);
        gtoken.mint(user1, 200 ether);
        gtoken.mint(user2, 200 ether);
        gtoken.mint(user3, 200 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        gtoken.approve(address(staking), 200 ether);
        registry.registerRole(ROLE_KMS, user1, abi.encode(uint256(100 ether)));
        vm.stopPrank();

        vm.startPrank(user2);
        gtoken.approve(address(staking), 200 ether);
        registry.registerRole(ROLE_KMS, user2, abi.encode(uint256(100 ether)));
        vm.stopPrank();

        vm.startPrank(user3);
        gtoken.approve(address(staking), 200 ether);
        registry.registerRole(ROLE_KMS, user3, abi.encode(uint256(100 ether)));
        vm.stopPrank();

        uint256 countBefore = registry.getRoleUserCount(ROLE_KMS);

        vm.startPrank(admin);
        IRegistry.RoleConfig memory cfg2 = registry.getRoleConfig(ROLE_KMS);
        cfg2.roleLockDuration = 0;
        registry.configureRole(ROLE_KMS, cfg2);
        vm.stopPrank();

        vm.prank(user2);
        registry.exitRole(ROLE_KMS);

        assertEq(registry.getRoleUserCount(ROLE_KMS), countBefore - 1);
        assertFalse(registry.hasRole(ROLE_KMS, user2));
        assertTrue(registry.hasRole(ROLE_KMS, user1));
        assertTrue(registry.hasRole(ROLE_KMS, user3));
    }
}
