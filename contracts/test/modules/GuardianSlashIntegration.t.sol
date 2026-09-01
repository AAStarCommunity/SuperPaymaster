// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";

/// @notice Minimal Registry stub: supplies only the staking pointer BLSAggregator
///         needs + the sync callback GTokenStaking makes. Real GTokenStaking is the
///         component under test here (authorization gate + real stake accounting) —
///         Registry's full registration flow is out of scope for this boundary test.
contract MiniRegistry {
    address public staking;
    mapping(address => uint256) public pending;

    function setStaking(address s) external {
        staking = s;
    }

    function GTOKEN_STAKING() external view returns (address) {
        return staking;
    }

    function setGuardianSlashPending(address guardian, bool value) external {
        if (value) pending[guardian]++;
        else pending[guardian]--;
    }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    fallback() external {}
}

contract IntgVerifier {
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @title  executeGuardianSlash — REAL GTokenStaking integration (pr-daemon §三)
/// @notice Crosses the contract boundary the unit-test mock could not: proves the
///         authorizedSlashers gate is real, that a real ROLE_DVT lock is zeroed, and
///         that a real exit between proof and execute is handled (skip, no id burn).
contract GuardianSlashIntegrationTest is Test {
    GToken gtoken;
    GTokenStaking staking;
    MiniRegistry registry;
    BLSAggregator bls;
    IntgVerifier verifier;

    address treasury = address(0x3);
    address guardian = address(0x6001);
    bytes32 constant ROLE_DVT = keccak256("DVT");

    function setUp() public {
        gtoken = new GToken(21_000_000 ether);
        registry = new MiniRegistry();
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        registry.setStaking(address(staking));
        bls = new BLSAggregator(address(registry), address(0x5050), address(0xD57));
        verifier = new IntgVerifier();
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        // Give the guardian a real ROLE_DVT lock via the onlyRegistry entry point.
        gtoken.mint(guardian, 100 ether);
        vm.prank(guardian);
        gtoken.approve(address(staking), 100 ether);
        vm.prank(address(registry));
        staking.lockStakeWithTicket(guardian, ROLE_DVT, 30 ether, 0, guardian);
    }

    function _one(address a) internal pure returns (address[] memory s) {
        s = new address[](1);
        s[0] = a;
    }

    function _lockedDvt(address g) internal view returns (uint256) {
        (uint128 a,,,,) = staking.roleLocks(g, ROLE_DVT);
        return uint256(a);
    }

    // §三-a: the authorizedSlashers gate is REAL (mock could not prove this).
    //        CC-48 HIGH-2 changed the FAILURE SHAPE, not the gate: a staking-side
    //        revert no longer takes the whole batch down. The guardian is left
    //        unresolved and frozen, the case stays pending, and the call is
    //        retryable once governance authorizes the aggregator.
    function test_Integration_UnauthorizedAggregator_SlashFailsButCaseSurvives() public {
        bls.queueGuardianSlash(1, _one(guardian), "");

        vm.expectEmit(true, true, false, false);
        emit BLSAggregator.GuardianSlashFailed(1, guardian);
        bls.executeGuardianSlash(1, _one(guardian), "");

        assertEq(_lockedDvt(guardian), 30 ether, "nothing slashed");
        assertFalse(bls.guardianSlashed(1, guardian));
        assertFalse(bls.guardianCaseResolved(1, guardian), "not settled");
        assertEq(bls.pendingGuardianSlashCount(guardian), 1, "still frozen");
        (,,, uint8 status,,,) = bls.guardianSlashCases(1);
        assertEq(status, 1, "case still pending, not burned");

        // Governance fixes the authorization; the same case now executes.
        staking.setAuthorizedSlasher(address(bls), true);
        bls.executeGuardianSlash(1, _one(guardian), "");
        // 30% of what was left, not all of it. This assertion read `== 0` until
        // `guardianSlashBps` landed: the path used to hand slashByDVT the entire remaining
        // lock, so it could not express a partial slash at all.
        assertEq(
            _lockedDvt(guardian),
            30 ether - (30 ether * uint256(bls.guardianSlashBps())) / 10000,
            "retry slashed the real lock, by guardianSlashBps"
        );
        assertEq(bls.pendingGuardianSlashCount(guardian), 0);
    }

    // §三-b: authorized path zeroes a REAL ROLE_DVT lock (→ falls below minStake → auto-eject).
    function test_Integration_RealSlashZerosLock() public {
        staking.setAuthorizedSlasher(address(bls), true);
        assertEq(_lockedDvt(guardian), 30 ether);
        bls.queueGuardianSlash(1, _one(guardian), "");
        bls.executeGuardianSlash(1, _one(guardian), "");
        assertEq(
            _lockedDvt(guardian),
            30 ether - (30 ether * uint256(bls.guardianSlashBps())) / 10000,
            "real ROLE_DVT lock cut by guardianSlashBps (was: zeroed)"
        );
        assertTrue(bls.guardianSlashed(1, guardian));
    }

    // §三-c: proof-vs-execute exit race — guardian exits (real unlockAndTransfer)
    //         before the slash lands → skip, and critically NO id is burned.
    function test_Integration_ExitBeforeExecute_Skips() public {
        staking.setAuthorizedSlasher(address(bls), true);
        vm.prank(address(registry));
        staking.unlockAndTransfer(guardian, ROLE_DVT); // guardian exited
        assertEq(_lockedDvt(guardian), 0, "exited");

        bls.queueGuardianSlash(1, _one(guardian), "");
        bls.executeGuardianSlash(1, _one(guardian), "");
        assertFalse(bls.guardianSlashed(1, guardian), "exited guardian not consumed");
    }
}
