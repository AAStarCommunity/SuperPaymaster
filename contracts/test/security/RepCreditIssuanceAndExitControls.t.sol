// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IMySBT.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract RepCreditMockSBT is IMySBT {
    function mintForRole(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function airdropMint(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function getUserSBT(address) external pure returns (uint256) { return 1; }
    function getSBTData(uint256) external pure returns (SBTData memory) {
        return SBTData(address(0), address(0), 0, 0);
    }
    function verifyCommunityMembership(address, address) external pure returns (bool) { return true; }
    function deactivateMembership(address, address) external pure {}
    function deactivateAllMemberships(address) external pure {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external pure {}
    function burnSBT(address) external pure {}
}

contract RepCreditMockBLS {
    function defaultThreshold() external pure returns (uint256) { return 2; }
    function verify(bytes32, uint256, uint256, bytes calldata) external pure returns (bool) { return true; }
}

contract RepCreditMockFraudVerifier {
    bool public valid = true;
    function setValid(bool value) external { valid = value; }
    function verify(uint256, address[] calldata, bytes calldata) external view returns (bool) { return valid; }
}

contract AggregateUpliftCapTest is Test {
    Registry registry;
    RepCreditMockBLS bls;
    address source = address(0x5150);
    address user1 = address(0xA1);
    address user2 = address(0xA2);

    function setUp() public {
        RepCreditMockSBT sbt = new RepCreditMockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
        bls = new RepCreditMockBLS();
        registry.setBLSAggregator(address(bls));
        registry.setReputationSource(source, true);
        registry.setCreditTier(1, 0);
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(uint256(3), bytes(""));
    }

    function _submit(uint256 id, address[] memory users, uint256[] memory scores, uint256 epoch) internal {
        vm.prank(source);
        registry.batchUpdateGlobalReputation(id, users, scores, epoch, _proof());
    }

    function _one(address user, uint256 score) internal pure returns (address[] memory users, uint256[] memory scores) {
        users = new address[](1);
        scores = new uint256[](1);
        users[0] = user;
        scores[0] = score;
    }

    function test_ExactCapAccepted() public {
        registry.setCreditPolicy(600 ether, type(uint256).max, 0, false);
        (address[] memory users, uint256[] memory scores) = _one(user1, 100);
        _submit(1, users, scores, 1);
        assertEq(registry.globalReputation(user1), 100);
        assertEq(registry.getCreditLimit(user1), 600 ether);
    }

    function test_AttackBatchAboveCapAtomicallyRevertsAndCanRetry() public {
        registry.setCreditPolicy(600 ether, type(uint256).max, 0, false);
        address[] memory users = new address[](2);
        uint256[] memory scores = new uint256[](2);
        users[0] = user1;
        users[1] = user2;
        scores[0] = 100;
        scores[1] = 100;

        vm.prank(source);
        vm.expectRevert(abi.encodeWithSelector(Registry.AggregateCreditUpliftExceeded.selector, 1200 ether, 600 ether));
        registry.batchUpdateGlobalReputation(2, users, scores, 2, _proof());
        assertEq(registry.globalReputation(user1), 0, "first write rolled back");
        assertEq(registry.globalReputation(user2), 0, "second write rolled back");

        registry.setCreditPolicy(1200 ether, type(uint256).max, 0, false);
        _submit(2, users, scores, 2);
        assertEq(registry.globalReputation(user1), 100, "proposal id remained retryable");
        assertEq(registry.globalReputation(user2), 100);
    }

    function test_ZeroCapFailsClosedForPositiveUpliftButAllowsDecrease() public {
        registry.setCreditPolicy(600 ether, type(uint256).max, 0, false);
        (address[] memory users, uint256[] memory scores) = _one(user1, 100);
        _submit(3, users, scores, 1);

        registry.setCreditPolicy(0, type(uint256).max, 0, false);
        scores[0] = 0;
        _submit(4, users, scores, 2);
        assertEq(registry.globalReputation(user1), 0, "risk-reducing update remains live");

        scores[0] = 100;
        vm.prank(source);
        vm.expectRevert(abi.encodeWithSelector(Registry.AggregateCreditUpliftExceeded.selector, 600 ether, 0));
        registry.batchUpdateGlobalReputation(5, users, scores, 3, _proof());
    }

    function test_DuplicateAndStaleEntriesCannotInflateAccounting() public {
        registry.setCreditPolicy(600 ether, type(uint256).max, 0, false);
        address[] memory duplicates = new address[](2);
        uint256[] memory scores = new uint256[](2);
        duplicates[0] = user1;
        duplicates[1] = user1;
        scores[0] = 100;
        scores[1] = 100;
        _submit(6, duplicates, scores, 10);
        assertEq(registry.getCreditLimit(user1), 600 ether);

        address[] memory mixed = new address[](2);
        mixed[0] = user1;
        mixed[1] = user2;
        _submit(7, mixed, scores, 9);
        assertEq(registry.globalReputation(user1), 100, "stale entry skipped");
        assertEq(registry.globalReputation(user2), 100, "only fresh uplift counted");
    }
}

contract PendingGuardianExitFreezeTest is Test {
    Registry registry;
    GTokenStaking staking;
    GToken gtoken;
    BLSAggregator bls;
    RepCreditMockFraudVerifier verifier;
    address guardian = address(0x6001);

    function setUp() public {
        RepCreditMockSBT sbt = new RepCreditMockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
        gtoken = new GToken(1_000_000 ether);
        staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        registry.setStaking(address(staking));
        bls = new BLSAggregator(address(registry), address(0x5050), address(0xD57));
        verifier = new RepCreditMockFraudVerifier();
        registry.setBLSAggregator(address(bls));
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();
        staking.setAuthorizedSlasher(address(bls), true);

        IRegistry.RoleConfig memory dvtConfig = registry.getRoleConfig(ROLE_DVT);
        dvtConfig.roleLockDuration = 0;
        registry.configureRole(ROLE_DVT, dvtConfig);
        gtoken.mint(guardian, 100 ether);
        vm.prank(guardian);
        gtoken.approve(address(staking), 100 ether);
        vm.prank(guardian);
        registry.registerRole(ROLE_DVT, guardian, abi.encode(uint256(30 ether)));
    }

    function _guardians() internal view returns (address[] memory guardians) {
        guardians = new address[](1);
        guardians[0] = guardian;
    }

    function _prepareExit() internal {
        vm.prank(guardian);
        bls.requestGuardianExit();
        vm.warp(block.timestamp + bls.GUARDIAN_EXIT_DELAY());
    }

    function test_InstantExitWithoutPublicNoticeReverts() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitNotRequested.selector, guardian));
        registry.exitRole(ROLE_DVT);
    }

    function test_PendingCaseFreezesExitThenSlashReleasesCase() public {
        address[] memory guardians = _guardians();
        _prepareExit();
        bls.queueGuardianSlash(1, guardians, hex"01");
        assertEq(bls.pendingGuardianSlashCount(guardian), 1);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitBlockedBySlash.selector, guardian, 1));
        registry.exitRole(ROLE_DVT);

        bls.executeGuardianSlash(1, guardians, hex"01");
        assertEq(bls.pendingGuardianSlashCount(guardian), 0);
        assertEq(staking.getLockedStake(guardian, ROLE_DVT), 0, "full DVT lock slashed");
        vm.prank(guardian);
        registry.exitRole(ROLE_DVT);
        assertFalse(registry.hasRole(ROLE_DVT, guardian));
    }

    function test_InvalidProofCannotFreezeExit() public {
        verifier.setValid(false);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(2)));
        bls.queueGuardianSlash(2, _guardians(), hex"02");
        assertEq(bls.pendingGuardianSlashCount(guardian), 0);
    }

    function test_ConcurrentCasesRemainFrozenUntilAllResolved() public {
        address[] memory guardians = _guardians();
        vm.prank(guardian);
        bls.requestGuardianExit();
        bls.queueGuardianSlash(3, guardians, hex"03");
        vm.warp(block.timestamp + 1 days);
        bls.queueGuardianSlash(4, guardians, hex"04");
        assertEq(bls.pendingGuardianSlashCount(guardian), 2);

        // Case 3's deadline is one full GUARDIAN_SLASH_CASE_WINDOW after it was
        // queued, i.e. one day before case 4's.
        vm.warp(block.timestamp + bls.GUARDIAN_SLASH_CASE_WINDOW() - 1 days + 1);
        bls.expireGuardianSlashCase(3, guardians);
        assertEq(bls.pendingGuardianSlashCount(guardian), 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitBlockedBySlash.selector, guardian, 1));
        registry.exitRole(ROLE_DVT);

        bls.executeGuardianSlash(4, guardians, hex"04");
        assertEq(bls.pendingGuardianSlashCount(guardian), 0);
    }

    /// CC-48 HIGH-2: expiry is still permissionless, but it no longer hands the
    /// accused guardian a ready-to-use exit. GUARDIAN_SLASH_CASE_WINDOW now strictly
    /// outlasts GUARDIAN_EXIT_DELAY + GUARDIAN_EXIT_WINDOW, so the notice filed at
    /// queue time is already dead by the time the case expires and the guardian has
    /// to serve a fresh notice.
    function test_ExpiredCaseReleasesFreezeButNotAReadyExit() public {
        address[] memory guardians = _guardians();
        vm.prank(guardian);
        bls.requestGuardianExit();
        (, uint64 expiresAtRaw) = bls.guardianExitRequests(guardian);
        uint256 noticeExpiry = uint256(expiresAtRaw);
        bls.queueGuardianSlash(5, guardians, hex"05");

        vm.warp(block.timestamp + bls.GUARDIAN_SLASH_CASE_WINDOW() + 1);
        vm.prank(address(0xB0B));
        bls.expireGuardianSlashCase(5, guardians);
        assertEq(bls.pendingGuardianSlashCount(guardian), 0);

        // The old notice expired while the case was still open.
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.GuardianExitRequestExpired.selector, guardian, noticeExpiry)
        );
        registry.exitRole(ROLE_DVT);

        // Clearing it costs a cooldown, and leaving costs another full notice.
        vm.prank(guardian);
        bls.cancelGuardianExit();
        vm.warp(block.timestamp + bls.GUARDIAN_EXIT_COOLDOWN());
        vm.prank(guardian);
        bls.requestGuardianExit();
        vm.warp(block.timestamp + bls.GUARDIAN_EXIT_DELAY());
        vm.prank(guardian);
        registry.exitRole(ROLE_DVT);
        assertFalse(registry.hasRole(ROLE_DVT, guardian));
    }
}
