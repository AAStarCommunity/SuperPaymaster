// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/mocks/MockBLSAggregator.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @title Registry_BLSMockedPaths
/// @notice Exercises every revert path of `batchUpdateGlobalReputation` and
///         `updateOperatorBlacklist`, plus the no-op epoch-skip branch, by
///         driving the contract with `MockBLSAggregator`.
/// @dev    This is the CI-friendly substitute for "running a real DVT cluster":
///         the mock returns true (or false on demand) without computing real
///         BLS-12-381 pairings, so we can reach every branch of `_verifyBLS`
///         and the downstream consensus / replay / mismatch checks.
contract Registry_BLSMockedPaths is Test {
    Registry registry;
    MockBLSAggregator aggregator;

    address owner       = address(0x1);
    address dvtCaller   = address(0x10);  // whitelisted as reputation source
    address operator    = address(0x20);
    address user1       = address(0x100);
    address user2       = address(0x101);

    function setUp() public {
        vm.startPrank(owner);

        // Registry proxy with placeholder staking/sbt — we don't exercise those here.
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0xDEAD), address(0xBEEF));

        // BLS aggregator under test — always returns true unless we toggle it.
        aggregator = new MockBLSAggregator();
        registry.setBLSAggregator(address(aggregator));

        // Whitelist the DVT caller for batch reputation + blacklist routes.
        registry.setReputationSource(dvtCaller, true);

        // Wire SUPER_PAYMASTER to a harmless mock so updateOperatorBlacklist's
        // downstream call doesn't revert in unrelated code.
        MockSuperPaymasterStub spStub = new MockSuperPaymasterStub();
        registry.setSuperPaymaster(address(spStub));

        vm.stopPrank();
    }

    // ----------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------

    /// @dev Build a proof that satisfies _verifyBLS bit-count >= defaultThreshold (7).
    function _validProof() internal pure returns (bytes memory) {
        // signerMask 0x7F = 0b01111111 = 7 set bits = threshold
        return abi.encode(uint256(0x7F), new bytes(256));
    }

    function _proofBelowThreshold() internal pure returns (bytes memory) {
        // signerMask 0x07 = 3 set bits < threshold 7 → InsufficientConsensus
        return abi.encode(uint256(0x07), new bytes(256));
    }

    function _singleUser(address u) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = u;
    }

    function _singleScore(uint256 s) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = s;
    }

    // ================================================================
    // batchUpdateGlobalReputation — happy path
    // ================================================================

    function test_BatchUpdate_HappyPath_WritesScore() public {
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(
            1, _singleUser(user1), _singleScore(50), 1, _validProof()
        );
        assertEq(registry.globalReputation(user1), 50);
        // lastReputationEpoch is internal — verified indirectly by the
        // EpochSkip_SilentNoOp test below.
    }

    function test_BatchUpdate_HappyPath_MultiUserSameBatch() public {
        address[] memory users = new address[](2);
        users[0] = user1; users[1] = user2;
        uint256[] memory scores = new uint256[](2);
        scores[0] = 40; scores[1] = 75;

        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(7, users, scores, 5, _validProof());

        assertEq(registry.globalReputation(user1), 40);
        assertEq(registry.globalReputation(user2), 75);
    }

    /// @notice Score climb is clamped at +100 per epoch (anti-pump-and-dump).
    function test_BatchUpdate_ScoreIncreaseClampedAt100() public {
        vm.startPrank(dvtCaller);
        registry.batchUpdateGlobalReputation(1, _singleUser(user1), _singleScore(50), 1, _validProof());
        // Now try to jump from 50 → 500 in one epoch: should clamp to 150 (50+100).
        registry.batchUpdateGlobalReputation(2, _singleUser(user1), _singleScore(500), 2, _validProof());
        vm.stopPrank();
        assertEq(registry.globalReputation(user1), 150);
    }

    /// @notice Score drop is clamped at -100 per epoch.
    /// @dev    Need to ramp up first since the +100 clamp also applies on the way up.
    function test_BatchUpdate_ScoreDecreaseClampedAt100() public {
        vm.startPrank(dvtCaller);
        // Ramp 0 → 100 → 200 → 300 (each step +100, no clamp triggered)
        registry.batchUpdateGlobalReputation(1, _singleUser(user1), _singleScore(100), 1, _validProof());
        registry.batchUpdateGlobalReputation(2, _singleUser(user1), _singleScore(200), 2, _validProof());
        registry.batchUpdateGlobalReputation(3, _singleUser(user1), _singleScore(300), 3, _validProof());
        assertEq(registry.globalReputation(user1), 300, "ramp-up reached 300");

        // Now drop from 300 → 10 (diff -290 > 100) → clamp to 300-100 = 200
        registry.batchUpdateGlobalReputation(4, _singleUser(user1), _singleScore(10), 4, _validProof());
        vm.stopPrank();
        assertEq(registry.globalReputation(user1), 200, "decrease clamped at -100");
    }

    // ================================================================
    // batchUpdateGlobalReputation — revert paths
    // ================================================================

    function test_BatchUpdate_UnauthorizedSource_Reverts() public {
        vm.expectRevert(Registry.UnauthorizedSource.selector);
        // operator is NOT in reputationSource whitelist
        vm.prank(operator);
        registry.batchUpdateGlobalReputation(1, _singleUser(user1), _singleScore(10), 1, _validProof());
    }

    function test_BatchUpdate_LenMismatch_Reverts() public {
        address[] memory users = new address[](2);
        users[0] = user1; users[1] = user2;
        uint256[] memory scores = new uint256[](1);  // wrong length
        scores[0] = 10;

        vm.expectRevert(Registry.LenMismatch.selector);
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(1, users, scores, 1, _validProof());
    }

    function test_BatchUpdate_BatchTooLarge_Reverts() public {
        address[] memory users = new address[](201);
        uint256[] memory scores = new uint256[](201);
        for (uint256 i = 0; i < 201; i++) {
            users[i] = address(uint160(1000 + i));
            scores[i] = 1;
        }
        vm.expectRevert(Registry.BatchTooLarge.selector);
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(1, users, scores, 1, _validProof());
    }

    function test_BatchUpdate_EmptyProof_Reverts() public {
        vm.expectRevert(IRegistry.BLSProofRequired.selector);
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(1, _singleUser(user1), _singleScore(10), 1, "");
    }

    function test_BatchUpdate_BLSNotConfigured_Reverts() public {
        // Fresh registry with no aggregator wired
        Registry fresh = UUPSDeployHelper.deployRegistryProxy(owner, address(0xDEAD), address(0xBEEF));
        vm.prank(owner);
        fresh.setReputationSource(dvtCaller, true);

        vm.expectRevert(Registry.BLSNotConfigured.selector);
        vm.prank(dvtCaller);
        fresh.batchUpdateGlobalReputation(1, _singleUser(user1), _singleScore(10), 1, _validProof());
    }

    function test_BatchUpdate_InvalidProposalId_Reverts() public {
        vm.expectRevert(Registry.InvalidProposalId.selector);
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(0, _singleUser(user1), _singleScore(10), 1, _validProof());
    }

    function test_BatchUpdate_ProposalAlreadyExecuted_Reverts() public {
        // First call succeeds
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(42, _singleUser(user1), _singleScore(10), 1, _validProof());

        // Same proposalId again → revert
        vm.expectRevert(Registry.ProposalAlreadyExecuted.selector);
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(42, _singleUser(user1), _singleScore(10), 2, _validProof());
    }

    function test_BatchUpdate_InsufficientConsensus_Reverts() public {
        vm.expectRevert(Registry.InsufficientConsensus.selector);
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(
            1, _singleUser(user1), _singleScore(10), 1, _proofBelowThreshold()
        );
    }

    function test_BatchUpdate_BLSFailed_Reverts() public {
        // Toggle aggregator to reject all signatures
        aggregator.setVerifyResult(false);

        vm.expectRevert(Registry.BLSFailed.selector);
        vm.prank(dvtCaller);
        registry.batchUpdateGlobalReputation(
            1, _singleUser(user1), _singleScore(10), 1, _validProof()
        );
    }

    /// @notice Epoch <= lastReputationEpoch is a silent no-op (per-user skip),
    ///         NOT a revert. Verifies the inner-loop `continue` branch.
    function test_BatchUpdate_EpochSkip_SilentNoOp() public {
        vm.startPrank(dvtCaller);
        registry.batchUpdateGlobalReputation(1, _singleUser(user1), _singleScore(50), 10, _validProof());

        // Same epoch (10) — should be skipped silently
        registry.batchUpdateGlobalReputation(2, _singleUser(user1), _singleScore(999), 10, _validProof());
        assertEq(registry.globalReputation(user1), 50, "stale epoch skipped");

        // Lower epoch (9) — also skipped
        registry.batchUpdateGlobalReputation(3, _singleUser(user1), _singleScore(888), 9, _validProof());
        assertEq(registry.globalReputation(user1), 50, "older epoch skipped");
        vm.stopPrank();
    }

    // ================================================================
    // updateOperatorBlacklist (BLS path shared with batchUpdate)
    // ================================================================

    function test_UpdateBlacklist_HappyPath() public {
        address[] memory users = new address[](2);
        users[0] = user1; users[1] = user2;
        bool[] memory statuses = new bool[](2);
        statuses[0] = true; statuses[1] = false;

        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _validProof());
        // Just exercising the path — downstream SP stub absorbs the call.
        // Nonce should have advanced.
        assertEq(registry.blacklistNonce(), 1);
    }

    function test_UpdateBlacklist_NotAggregator_Reverts() public {
        address[] memory users = new address[](1); users[0] = user1;
        bool[] memory statuses = new bool[](1); statuses[0] = true;

        vm.expectRevert(Registry.UnauthorizedSource.selector);
        vm.prank(operator);
        registry.updateOperatorBlacklist(operator, users, statuses, _validProof());
    }

    function test_UpdateBlacklist_LenMismatch_Reverts() public {
        address[] memory users = new address[](2); users[0] = user1; users[1] = user2;
        bool[] memory statuses = new bool[](1); statuses[0] = true;

        vm.expectRevert(Registry.LenMismatch.selector);
        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _validProof());
    }

    function test_UpdateBlacklist_BatchTooLarge_Reverts() public {
        address[] memory users = new address[](201);
        bool[] memory statuses = new bool[](201);
        for (uint256 i = 0; i < 201; i++) {
            users[i] = address(uint160(2000 + i));
            statuses[i] = true;
        }
        vm.expectRevert(Registry.BatchTooLarge.selector);
        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _validProof());
    }

    function test_UpdateBlacklist_ZeroOperator_Reverts() public {
        address[] memory users = new address[](1); users[0] = user1;
        bool[] memory statuses = new bool[](1); statuses[0] = true;

        vm.expectRevert(Registry.InvalidParam.selector);
        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(address(0), users, statuses, _validProof());
    }

    function test_UpdateBlacklist_EmptyProof_Reverts() public {
        address[] memory users = new address[](1); users[0] = user1;
        bool[] memory statuses = new bool[](1); statuses[0] = true;

        vm.expectRevert(IRegistry.BLSProofRequired.selector);
        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, "");
    }

    function test_UpdateBlacklist_NonceMonotonic() public {
        address[] memory users = new address[](1); users[0] = user1;
        bool[] memory statuses = new bool[](1); statuses[0] = true;

        vm.startPrank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _validProof());
        registry.updateOperatorBlacklist(operator, users, statuses, _validProof());
        registry.updateOperatorBlacklist(operator, users, statuses, _validProof());
        vm.stopPrank();
        assertEq(registry.blacklistNonce(), 3);
    }
}

/// @dev Minimal stub for SuperPaymaster — only the call surface
///      updateOperatorBlacklist hits is needed.
contract MockSuperPaymasterStub {
    function updateBlockedStatus(address, address[] calldata, bool[] calldata) external {}
}
