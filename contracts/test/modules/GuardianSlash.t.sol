// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IGTokenStaking.sol";

/// @notice Verifier stub whose verdict is test-controlled.
contract MockVerifier {
    bool public ok = true;
    function set(bool v) external { ok = v; }
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external view returns (bool) { return ok; }
}

/// @notice Minimal GTokenStaking stub exposing only roleLocks + slashByDVT.
contract MockStaking {
    mapping(address => uint128) public lockAmt;
    address public lastSlashed;
    uint256 public lastPenalty;
    uint256 public slashCount;

    function setLock(address u, uint128 a) external { lockAmt[u] = a; }

    function roleLocks(address user, bytes32)
        external
        view
        returns (uint128, uint128, uint48, bytes32, bytes memory)
    {
        return (lockAmt[user], 0, 0, bytes32(0), "");
    }

    function slashByDVT(address operator, bytes32, uint256 penalty, string calldata) external {
        require(lockAmt[operator] >= penalty, "InsufficientStake");
        lockAmt[operator] -= uint128(penalty);
        lastSlashed = operator;
        lastPenalty = penalty;
        slashCount++;
    }
}

/// @notice Registry stub returning the mock staking pointer.
contract MockRegistry {
    IGTokenStaking public immutable staking;
    mapping(address => uint256) public pending;
    constructor(IGTokenStaking s) { staking = s; }
    function GTOKEN_STAKING() external view returns (IGTokenStaking) { return staking; }
    function setGuardianSlashPending(address guardian, bool value) external {
        if (value) pending[guardian]++;
        else pending[guardian]--;
    }
    fallback() external payable {}
}

/// @title  executeGuardianSlash tests (Protocol B stage-1 thin SP entry)
/// @notice Covers fail-closed, verifier gating, full-lock slash + auto-eject
///         precondition, replay guard, dedup/shape hardening, 0-lock skip, and
///         address-binding (not slot) so slot reuse can never slash the wrong party.
contract GuardianSlashTest is Test {
    BLSAggregator bls;
    MockRegistry registry;
    MockStaking staking;
    MockVerifier verifier;

    address owner = address(0x0BEE);
    address sp = address(0x5050);
    address dvt = address(0xD57);
    address guardian1 = address(0x6001);
    address guardian2 = address(0x6002);
    address attacker = address(0xBAD);

    function setUp() public {
        staking = new MockStaking();
        registry = new MockRegistry(IGTokenStaking(address(staking)));
        verifier = new MockVerifier();
        vm.prank(owner);
        bls = new BLSAggregator(address(registry), sp, dvt);
    }

    function _wireVerifier() internal {
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();
    }

    function _one(address a) internal pure returns (address[] memory s) {
        s = new address[](1);
        s[0] = a;
    }

    function _queueAndExecute(uint256 id, address[] memory guardians) internal {
        bls.queueGuardianSlash(id, guardians, "");
        bls.executeGuardianSlash(id, guardians, "");
    }

    // ---- fail-closed ----

    function test_RevertWhen_VerifierNotSet() public {
        vm.expectRevert(BLSAggregator.FraudProofVerifierNotSet.selector);
        bls.queueGuardianSlash(1, _one(guardian1), "");
    }

    function test_ProposeFraudProofVerifier_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bls.proposeFraudProofVerifier(address(verifier));
    }

    /// CC-48 MEDIUM-1: rotation cannot be applied before the delay matures.
    function test_ApplyFraudProofVerifier_RequiresDelay() public {
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier));
        vm.expectRevert();
        bls.applyFraudProofVerifier();
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();
        assertEq(bls.fraudProofVerifier(), address(verifier));
    }

    // ---- shape / verifier gating ----

    function test_RevertWhen_EmptyGuardians() public {
        _wireVerifier();
        vm.expectRevert(BLSAggregator.EmptyGuiltyGuardians.selector);
        bls.queueGuardianSlash(1, new address[](0), "");
    }

    function test_RevertWhen_TooManyGuardians() public {
        _wireVerifier();
        address[] memory many = new address[](14); // > MAX_VALIDATORS (13)
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "guiltyGuardians"));
        bls.queueGuardianSlash(1, many, "");
    }

    function test_RevertWhen_VerifyFalse() public {
        _wireVerifier();
        verifier.set(false);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(1)));
        bls.queueGuardianSlash(1, _one(guardian1), "");
    }

    function test_RevertWhen_DuplicateGuardian() public {
        _wireVerifier();
        address[] memory dup = new address[](2);
        dup[0] = guardian1;
        dup[1] = guardian1;
        staking.setLock(guardian1, 60 ether);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "dup guardian"));
        bls.queueGuardianSlash(1, dup, "");
    }

    function test_RevertWhen_ZeroAddress() public {
        _wireVerifier();
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidTarget.selector, address(0)));
        bls.queueGuardianSlash(1, _one(address(0)), "");
    }

    // ---- happy path: full-lock slash → auto-eject precondition ----

    function test_SuccessSlashesFullLock() public {
        _wireVerifier();
        staking.setLock(guardian1, 60 ether);
        bls.queueGuardianSlash(1, _one(guardian1), "");

        vm.expectEmit(true, true, false, true, address(bls));
        emit BLSAggregator.GuardianSlashed(1, guardian1, 60 ether);
        bls.executeGuardianSlash(1, _one(guardian1), "");

        assertEq(staking.lastSlashed(), guardian1);
        assertEq(staking.lastPenalty(), 60 ether, "full lock slashed");
        assertEq(staking.lockAmt(guardian1), 0, "lock zeroed -> falls below minStake -> auto-eject");
        assertTrue(bls.guardianSlashed(1, guardian1));
    }

    function test_SuccessMultipleGuardians() public {
        _wireVerifier();
        staking.setLock(guardian1, 30 ether);
        staking.setLock(guardian2, 45 ether);
        address[] memory two = new address[](2);
        two[0] = guardian1;
        two[1] = guardian2;
        _queueAndExecute(7, two);
        assertEq(staking.slashCount(), 2);
        assertEq(staking.lockAmt(guardian1), 0);
        assertEq(staking.lockAmt(guardian2), 0);
    }

    // ---- per-(proof,guardian) idempotency (replaces global-id replay) ----

    function test_ResolvedCaseCannotReplay() public {
        _wireVerifier();
        staking.setLock(guardian1, 60 ether);
        _queueAndExecute(1, _one(guardian1));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianSlashCaseNotPending.selector, uint256(1)));
        bls.executeGuardianSlash(1, _one(guardian1), "");
        assertEq(staking.slashCount(), 1, "no double-slash");
        assertTrue(bls.guardianSlashed(1, guardian1));
    }

    // ---- 0-lock skip: exited guardian is NOT consumed, emits skip event ----

    function test_SkipsZeroLock() public {
        _wireVerifier();
        staking.setLock(guardian1, 0); // already emptied / exited
        bls.queueGuardianSlash(1, _one(guardian1), "");
        vm.expectEmit(true, true, false, false, address(bls));
        emit BLSAggregator.GuardianSlashSkipped(1, guardian1);
        bls.executeGuardianSlash(1, _one(guardian1), "");
        assertEq(staking.slashCount(), 0, "no slash call for 0-lock guardian");
        assertFalse(bls.guardianSlashed(1, guardian1), "0-lock guardian NOT consumed");
    }

    // ---- pr-daemon blocking: an exited guardian must NOT burn the proof for colluders ----

    function test_ExitedGuardianDoesNotShieldColluder() public {
        _wireVerifier();
        staking.setLock(guardian1, 0);        // exited co-signer (griefing bait)
        staking.setLock(guardian2, 60 ether); // still-staked colluder

        address[] memory two = new address[](2);
        two[0] = guardian1;
        two[1] = guardian2;
        _queueAndExecute(1, two);
        assertEq(staking.slashCount(), 1, "colluder slashed despite exited co-signer");
        assertFalse(bls.guardianSlashed(1, guardian1), "no id burned by exited guardian");
        assertEq(staking.lockAmt(guardian2), 0);
        assertTrue(bls.guardianSlashed(1, guardian2));
    }

    // ---- version bump ----

    function test_VersionBumped() public view {
        assertEq(keccak256(bytes(bls.version())), keccak256("BLSAggregator-4.8.0"));
    }
}
