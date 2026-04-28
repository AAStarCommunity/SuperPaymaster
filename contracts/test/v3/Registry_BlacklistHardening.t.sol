// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/mocks/MockBLSAggregator.sol";
import "src/interfaces/v3/IBLSAggregator.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract MockOracle is AggregatorV3Interface {
    function decimals() external pure returns (uint8) { return 8; }
    function description() external pure returns (string memory) { return "Mock"; }
    function version() external pure returns (uint256) { return 1; }
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
}

contract MockEP is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function balanceOf(address) external view returns (uint256) { return 0; }
    function getDepositInfo(address) external view returns (DepositInfo memory) { return DepositInfo(0, false, 0, 0, 0); }
    function withdrawTo(address payable, uint256) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function getUserOpHash(PackedUserOperation calldata) external pure returns (bytes32) { return bytes32(0); }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function incrementNonce(uint192) external {}
    function delegateAndRevert(address, bytes calldata) external {}
}

/**
 * @title Registry_BlacklistHardeningTest
 * @notice P0-3 (B6-C2 + Codex B-N4) regression tests.
 *
 * Pre-fix `Registry.updateOperatorBlacklist`:
 *  - Auth gate: `isReputationSource[msg.sender]` (broad, includes any address
 *    governance authorized as a reputation feed).
 *  - Proof was OPTIONAL — empty proof or unset blsValidator both bypassed
 *    BLS verification.
 *  - The signed message hash was `keccak256(abi.encode(operator, users,
 *    statuses))` — no chainid, no nonce. A legitimate proof from chain A
 *    could be replayed verbatim on chain B for the same operator address.
 *
 * Post-fix:
 *  - Caller MUST equal `blsAggregator` (set via `setBLSAggregator`).
 *  - `proof.length == 0` reverts with `BLSProofRequired()`.
 *  - Message hash binds `block.chainid` AND a monotonic `blacklistNonce`
 *    that increments on every successful call.
 *  - The proof wire format matches the rest of the aggregator-routed code:
 *    `abi.encode(uint256 signerMask, bytes sigG2)`.
 *
 * Verification strategy — `IBLSAggregator.verify` is declared `view` so
 * Registry calls it via STATICCALL. We can't write storage from inside the
 * mock, so we instead use `vm.expectCall(...)` to assert exact call data
 * (which encodes the messageHash, signerMask, threshold, sigBytes the
 * Registry committed to).
 */
contract Registry_BlacklistHardeningTest is Test {
    using Clones for address;

    Registry registry;
    SuperPaymaster paymaster;
    GTokenStaking staking;
    MySBT mysbt;
    GToken gtoken;
    xPNTsToken apnts;
    MockEP entryPoint;
    MockOracle priceFeed;

    MockBLSAggregator aggregator;

    address owner = address(0x1);
    address operator = address(0x300);
    address treasury = address(0x500);
    address user1 = address(0x600);
    address user2 = address(0x601);
    address attacker = address(0xDEAD);

    function setUp() public {
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(owner);

        gtoken = new GToken(1_000_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        staking = new GTokenStaking(address(gtoken), owner, address(registry));
        mysbt = new MySBT(address(gtoken), address(staking), address(registry), owner);
        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));

        entryPoint = new MockEP();
        priceFeed = new MockOracle();
        address impl = address(new xPNTsToken());
        apnts = xPNTsToken(impl.clone());
        apnts.initialize("APNTS", "APNTS", owner, "C", "ens", 1e18);

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint, IRegistry(address(registry)), address(priceFeed),
            owner, address(apnts), treasury, 3600
        );
        registry.setSuperPaymaster(address(paymaster));

        aggregator = new MockBLSAggregator();
        registry.setBLSAggregator(address(aggregator));

        // Spin up an operator with COMMUNITY + PAYMASTER_SUPER + a configured
        // entry inside SuperPaymaster so updateBlockedStatus has a target.
        gtoken.mint(operator, 10_000 ether);
        vm.stopPrank();

        vm.startPrank(operator);
        gtoken.approve(address(staking), 10_000 ether);
        Registry.CommunityRoleData memory cd = Registry.CommunityRoleData("Op", "op.eth", "", "", "", 100 ether);
        registry.registerRole(registry.ROLE_COMMUNITY(), operator, abi.encode(cd));
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), operator, abi.encode(uint256(100 ether)));
        paymaster.configureOperator(address(apnts), treasury, 1e18);
        vm.stopPrank();
    }

    function _users() internal view returns (address[] memory u) {
        u = new address[](2);
        u[0] = user1;
        u[1] = user2;
    }

    function _statuses(bool a, bool b) internal pure returns (bool[] memory s) {
        s = new bool[](2);
        s[0] = a;
        s[1] = b;
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(uint256(0x7F), new bytes(256));
    }

    function _expectedHash(uint256 chainid_, uint256 nonce, address[] memory u, bool[] memory s)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(chainid_, nonce, operator, u, s));
    }

    // ====================================
    // P0-3 #1 — caller restricted to BLS aggregator
    // ====================================

    function test_UpdateBlacklist_RevertsForNonAggregator() public {
        // Owner is NOT the aggregator — must revert.
        vm.prank(owner);
        vm.expectRevert(Registry.UnauthorizedSource.selector);
        registry.updateOperatorBlacklist(operator, _users(), _statuses(true, true), _proof());

        // Random attacker — must revert.
        vm.prank(attacker);
        vm.expectRevert(Registry.UnauthorizedSource.selector);
        registry.updateOperatorBlacklist(operator, _users(), _statuses(true, true), _proof());

        // Even a previously authorized reputation source must revert under the
        // new caller gate (P0-3 narrows this from isReputationSource to
        // strict-equality with blsAggregator).
        address oldRepSource = address(0xBEEF);
        vm.prank(owner);
        registry.setReputationSource(oldRepSource, true);

        vm.prank(oldRepSource);
        vm.expectRevert(Registry.UnauthorizedSource.selector);
        registry.updateOperatorBlacklist(operator, _users(), _statuses(true, true), _proof());
    }

    // ====================================
    // P0-3 #2 — proof is mandatory
    // ====================================

    function test_UpdateBlacklist_RevertsOnEmptyProof() public {
        vm.prank(address(aggregator));
        vm.expectRevert(Registry.BLSProofRequired.selector);
        registry.updateOperatorBlacklist(operator, _users(), _statuses(true, true), "");
    }

    // ====================================
    // P0-3 #3 — message hash includes block.chainid + blacklistNonce
    // ====================================

    function test_UpdateBlacklist_MessageIncludesChainIdAndNonce() public {
        address[] memory users = _users();
        bool[] memory statuses = _statuses(true, false);

        uint256 expectedNonce = registry.blacklistNonce() + 1;
        bytes32 expectedHash = _expectedHash(block.chainid, expectedNonce, users, statuses);

        // Decode the proof to mirror Registry's internal abi.decode call.
        (uint256 signerMask, bytes memory sigG2) = abi.decode(_proof(), (uint256, bytes));

        // vm.expectCall asserts the EXACT calldata Registry sends to verify(),
        // which includes the messageHash committed to chainid + nonce.
        vm.expectCall(
            address(aggregator),
            abi.encodeCall(
                IBLSAggregator.verify,
                (expectedHash, signerMask, aggregator.defaultThreshold(), sigG2)
            )
        );

        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());
    }

    // ====================================
    // P0-3 #4 — nonce is monotonic across calls
    // ====================================

    function test_UpdateBlacklist_NonceMonotonic() public {
        assertEq(registry.blacklistNonce(), 0, "Initial nonce must be 0");

        // First call → nonce becomes 1. Use vm.expectCall to assert the
        // committed hash matches nonce=1.
        address[] memory users = _users();
        bool[] memory statuses = _statuses(true, false);
        (uint256 signerMask, bytes memory sigG2) = abi.decode(_proof(), (uint256, bytes));

        bytes32 hash1 = _expectedHash(block.chainid, 1, users, statuses);
        vm.expectCall(
            address(aggregator),
            abi.encodeCall(IBLSAggregator.verify, (hash1, signerMask, aggregator.defaultThreshold(), sigG2))
        );
        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());
        assertEq(registry.blacklistNonce(), 1, "Nonce must increment to 1");

        // Second call with same args → nonce becomes 2 → fresh message hash.
        bytes32 hash2 = _expectedHash(block.chainid, 2, users, statuses);
        assertTrue(hash1 != hash2, "Same payload at different nonces must hash differently");

        vm.expectCall(
            address(aggregator),
            abi.encodeCall(IBLSAggregator.verify, (hash2, signerMask, aggregator.defaultThreshold(), sigG2))
        );
        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());
        assertEq(registry.blacklistNonce(), 2, "Nonce must increment to 2");
    }

    // ====================================
    // P0-3 #5 — cross-chain replay impossible
    // ====================================

    function test_UpdateBlacklist_RejectsCrossChainReplay() public {
        address[] memory users = _users();
        bool[] memory statuses = _statuses(true, true);

        // The attacker steals a signature valid for chain A's hash. We model
        // "chain A's hash" by computing it now (with the current chainid +
        // pending nonce). Then we switch to chain B and assert the hash that
        // Registry commits to is DIFFERENT — which is the structural reason
        // a chain-A signature cannot satisfy chain-B verification.
        uint256 chainA = block.chainid;
        uint256 nonceA = registry.blacklistNonce() + 1;
        bytes32 chainAHash = _expectedHash(chainA, nonceA, users, statuses);

        // Switch to chain B.
        uint256 chainB = chainA + 1;
        vm.chainId(chainB);

        // Decode proof for vm.expectCall.
        (uint256 signerMask, bytes memory sigG2) = abi.decode(_proof(), (uint256, bytes));

        // The hash Registry will commit on chain B (same nonce, different chainid).
        bytes32 chainBHash = _expectedHash(chainB, nonceA, users, statuses);
        assertTrue(chainBHash != chainAHash, "Cross-chain hashes must differ");

        // Registry on chain B must call verify() with chainBHash — NOT chainAHash.
        vm.expectCall(
            address(aggregator),
            abi.encodeCall(IBLSAggregator.verify, (chainBHash, signerMask, aggregator.defaultThreshold(), sigG2))
        );
        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());

        // Restore chain id to keep the test environment sane.
        vm.chainId(chainA);
    }

    // ====================================
    // P0-3 #6 — happy path still works (regression guard)
    // ====================================

    function test_UpdateBlacklist_HappyPath_PropagatesToPaymaster() public {
        // Register user1 with SBT so SuperPaymaster.updateBlockedStatus accepts.
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user1, true);

        address[] memory users = new address[](1);
        users[0] = user1;
        bool[] memory statuses = new bool[](1);
        statuses[0] = true;

        vm.prank(address(aggregator));
        registry.updateOperatorBlacklist(operator, users, statuses, _proof());

        (, bool blocked) = paymaster.userOpState(operator, user1);
        assertTrue(blocked, "User must be blacklisted in SuperPaymaster after success");
    }

    // ====================================
    // P0-3 #7 — verify() returning false halts the update
    // ====================================

    function test_UpdateBlacklist_RevertsWhenVerifyReturnsFalse() public {
        aggregator.setVerifyResult(false);

        vm.prank(address(aggregator));
        vm.expectRevert(Registry.BLSFailed.selector);
        registry.updateOperatorBlacklist(operator, _users(), _statuses(true, true), _proof());

        // Nonce must NOT advance on failure.
        // (Note: we increment BEFORE verify, so if verify reverts, the nonce
        // bump is rolled back with the rest of the tx state — assert that.)
        assertEq(registry.blacklistNonce(), 0, "Nonce must NOT advance on verify failure");
    }
}
