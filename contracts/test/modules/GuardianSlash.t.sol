// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IGTokenStaking.sol";

/// @notice Verifier stub whose verdict is test-controlled.
contract MockVerifier {
    bool public ok = true;
    function set(bool v) external { ok = v; }
    function verify(uint256, uint8[] calldata, bytes calldata) external view returns (bool) { return ok; }
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
    constructor(IGTokenStaking s) { staking = s; }
    function GTOKEN_STAKING() external view returns (IGTokenStaking) { return staking; }
    fallback() external payable {}
}

/// @title  executeGuardianSlash tests (Protocol B stage-1 thin SP entry)
/// @notice Covers fail-closed, verifier gating, full-lock slash + auto-eject
///         precondition, replay guard, dedup/shape hardening, and 0-lock skip.
contract GuardianSlashTest is Test {
    using stdStorage for StdStorage;

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
        bls.setFraudProofVerifier(address(verifier));
    }

    function _bindSlot(uint8 slot, address guardian) internal {
        stdstore.target(address(bls)).sig("validatorAtSlot(uint8)").with_key(uint256(slot)).checked_write(guardian);
    }

    function _slots(uint8 a) internal pure returns (uint8[] memory s) {
        s = new uint8[](1);
        s[0] = a;
    }

    // ---- fail-closed ----

    function test_RevertWhen_VerifierNotSet() public {
        vm.expectRevert(BLSAggregator.FraudProofVerifierNotSet.selector);
        bls.executeGuardianSlash(1, _slots(1), "");
    }

    function test_SetFraudProofVerifier_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        bls.setFraudProofVerifier(address(verifier));
    }

    // ---- shape / verifier gating ----

    function test_RevertWhen_EmptySlots() public {
        _wireVerifier();
        vm.expectRevert(BLSAggregator.EmptyGuiltySlots.selector);
        bls.executeGuardianSlash(1, new uint8[](0), "");
    }

    function test_RevertWhen_TooManySlots() public {
        _wireVerifier();
        uint8[] memory many = new uint8[](14); // > MAX_VALIDATORS (13)
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "guiltySlots"));
        bls.executeGuardianSlash(1, many, "");
    }

    function test_RevertWhen_VerifyFalse() public {
        _wireVerifier();
        verifier.set(false);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(1)));
        bls.executeGuardianSlash(1, _slots(1), "");
    }

    function test_RevertWhen_DuplicateSlot() public {
        _wireVerifier();
        uint8[] memory dup = new uint8[](2);
        dup[0] = 1;
        dup[1] = 1;
        _bindSlot(1, guardian1);
        staking.setLock(guardian1, 60 ether);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "dup slot"));
        bls.executeGuardianSlash(1, dup, "");
    }

    function test_RevertWhen_UnknownSlot() public {
        _wireVerifier();
        // verify=true but slot 1 has no bound validator
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnknownValidatorSlot.selector, uint8(1)));
        bls.executeGuardianSlash(1, _slots(1), "");
    }

    // ---- happy path: full-lock slash → auto-eject precondition ----

    function test_SuccessSlashesFullLock() public {
        _wireVerifier();
        _bindSlot(1, guardian1);
        staking.setLock(guardian1, 60 ether);

        vm.expectEmit(true, true, true, true, address(bls));
        emit BLSAggregator.GuardianSlashed(1, 1, guardian1, 60 ether);
        bls.executeGuardianSlash(1, _slots(1), "");

        assertEq(staking.lastSlashed(), guardian1);
        assertEq(staking.lastPenalty(), 60 ether, "full lock slashed");
        assertEq(staking.lockAmt(guardian1), 0, "lock zeroed -> falls below minStake -> auto-eject");
        assertTrue(bls.consumedFraudProofs(1));
    }

    function test_SuccessMultipleSlots() public {
        _wireVerifier();
        _bindSlot(1, guardian1);
        _bindSlot(2, guardian2);
        staking.setLock(guardian1, 30 ether);
        staking.setLock(guardian2, 45 ether);
        uint8[] memory two = new uint8[](2);
        two[0] = 1;
        two[1] = 2;
        bls.executeGuardianSlash(7, two, "");
        assertEq(staking.slashCount(), 2);
        assertEq(staking.lockAmt(guardian1), 0);
        assertEq(staking.lockAmt(guardian2), 0);
    }

    // ---- replay guard ----

    function test_RevertWhen_Replay() public {
        _wireVerifier();
        _bindSlot(1, guardian1);
        staking.setLock(guardian1, 60 ether);
        bls.executeGuardianSlash(1, _slots(1), "");
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.FraudProofAlreadyUsed.selector, uint256(1)));
        bls.executeGuardianSlash(1, _slots(1), "");
    }

    // ---- 0-lock skip (already ejected guardian) ----

    function test_SkipsZeroLockSlot() public {
        _wireVerifier();
        _bindSlot(1, guardian1);
        staking.setLock(guardian1, 0); // already emptied
        bls.executeGuardianSlash(1, _slots(1), "");
        assertEq(staking.slashCount(), 0, "no slash call for 0-lock slot");
        assertTrue(bls.consumedFraudProofs(1), "proof still consumed (no re-execution)");
    }

    // ---- version bump ----

    function test_VersionBumped() public view {
        assertEq(keccak256(bytes(bls.version())), keccak256("BLSAggregator-4.2.0"));
    }
}
