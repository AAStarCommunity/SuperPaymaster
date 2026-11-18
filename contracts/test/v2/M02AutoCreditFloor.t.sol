// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { Registry } from "src/core/Registry.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { IExt } from "../helpers/V2TestFixtures.sol";

contract M02BLSAggregator {
    function defaultThreshold() external pure returns (uint256) { return 2; }
    function verify(bytes32, uint256, uint256, bytes calldata) external pure returns (bool) { return true; }
}

contract M02AutoCreditFloorTest is Test {
    Registry internal registry;
    GlobalTierSource internal tierSource;
    xPNTsTokenV2 internal token;

    address internal reputationSource = address(0x5150);
    uint256 internal nextProposal = 1;

    function setUp() public {
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(0));
        registry.setBLSAggregator(address(new M02BLSAggregator()));
        registry.setReputationSource(reputationSource, true);
        registry.setCreditPolicy(type(uint256).max, type(uint256).max);

        tierSource = new GlobalTierSource(address(registry));
        AOAProtocolRegistry protocolRegistry = new AOAProtocolRegistry(address(this));
        protocolRegistry.bootstrapApprove(protocolRegistry.KIND_TIER_SOURCE(), address(tierSource).codehash);
        protocolRegistry.seal();

        xPNTsTokenV2Ext extension = new xPNTsTokenV2Ext(address(protocolRegistry));
        xPNTsTokenV2 implementation = new xPNTsTokenV2(address(protocolRegistry), address(extension));
        token = xPNTsTokenV2(Clones.clone(address(implementation)));
        token.initialize(xPNTsTokenV2.InitConfig({
            name: "M02",
            symbol: "M02",
            communityOwner: address(this),
            community: address(this),
            communityName: "M02",
            communityENS: "m02.eth",
            exchangeRate: 1 ether,
            superPaymaster: address(0),
            genesisSpender: address(0),
            tierSource: address(tierSource)
        }));
    }

    function _setPolicy(uint8 policy) internal {
        IExt(address(token)).queueCreditPolicy(policy);
        vm.warp(block.timestamp + 48 hours);
        IExt(address(token)).executeCreditPolicy();
    }

    function _request(address user, uint256 cap) internal {
        vm.prank(user);
        IExt(address(token)).requestCredit(cap);
    }

    function _promote(address user, uint256 targetReputation) internal {
        uint256 score = registry.globalReputation(user);
        while (score < targetReputation) {
            uint256 next = targetReputation - score > 100 ? score + 100 : targetReputation;
            address[] memory users = new address[](1);
            uint256[] memory scores = new uint256[](1);
            users[0] = user;
            scores[0] = next;
            uint256 proposal = nextProposal++;
            vm.prank(reputationSource);
            registry.batchUpdateGlobalReputation(
                proposal, users, scores, proposal, abi.encode(uint256(3), bytes(""))
            );
            score = next;
        }
    }

    function test_AUTO_uses_exact_realRegistry_aboveFloor_tiers() public {
        uint256[6] memory tiers = [
            registry.creditTierConfig(1),
            registry.creditTierConfig(2),
            registry.creditTierConfig(3),
            registry.creditTierConfig(4),
            registry.creditTierConfig(5),
            registry.creditTierConfig(6)
        ];
        assertEq(tiers[0], 100 ether);
        assertEq(tiers[1], 100 ether);
        assertEq(tiers[2], 300 ether);
        assertEq(tiers[3], 600 ether);
        assertEq(tiers[4], 1_000 ether);
        assertEq(tiers[5], 2_000 ether);
        assertEq(tierSource.creditFloor(), tiers[0]);
        assertEq(tierSource.version(), "GlobalTierSource-1.0.1");

        _setPolicy(2);
        uint256[6] memory reputations = [uint256(0), 13, 34, 89, 233, 610];
        uint256[6] memory expected = [uint256(0), 0, 200 ether, 500 ether, 900 ether, 1_900 ether];
        for (uint256 i; i < 6; i++) {
            address user = address(uint160(0xA000 + i));
            _promote(user, reputations[i]);
            _request(user, token.PROTOCOL_CREDIT_CEILING());
            assertEq(registry.getCreditLimit(user), tiers[i], "real Registry tier mismatch");
            assertEq(token.effectiveCreditCap(user), expected[i], "AUTO above-floor tier mismatch");
        }

        address level3 = address(0xB003);
        _promote(level3, 34);
        _request(level3, 150 ether);
        assertEq(token.effectiveCreditCap(level3), 150 ether, "requestedCap still binds");
        assertEq(expected[1], 0, "L2 is explicitly zero because tier2 equals the floor");
    }

    function test_AUTO_zeroReputation_sybils_get_zero_MANUAL_keeps_full_tier() public {
        uint256 sybilCount = 8;
        _setPolicy(2);
        for (uint256 i; i < sybilCount; i++) {
            address sybil = address(uint160(0xD000 + i));
            _request(sybil, 100 ether);
            assertEq(registry.globalReputation(sybil), 0);
            assertEq(registry.getCreditLimit(sybil), 100 ether);
            assertEq(token.effectiveCreditCap(sybil), 0, "AUTO Sybil received floor credit");
        }

        _setPolicy(1);
        for (uint256 i; i < sybilCount; i++) {
            address sybil = address(uint160(0xD000 + i));
            _request(sybil, 100 ether);
            IExt(address(token)).approveCredit(sybil, 100 ether);
            assertEq(token.effectiveCreditCap(sybil), 100 ether, "MANUAL must keep full tierOf");
        }
    }

    function _medium1Schedule() internal {
        uint256[] memory thresholds = new uint256[](5);
        thresholds[0] = 0;
        thresholds[1] = 34;
        thresholds[2] = 89;
        thresholds[3] = 233;
        thresholds[4] = 610;
        registry.setLevelThresholds(thresholds);
        registry.setCreditTier(2, 200 ether);
        registry.seedCreditPopulation(new address[](0), 0, true);
    }

    function test_Medium1_zeroReputation_floor_and_promoted_credit() public {
        _medium1Schedule();
        _setPolicy(2);
        address user = address(0xA001);
        _request(user, token.PROTOCOL_CREDIT_CEILING());
        assertEq(registry.getCreditLimit(user), 200 ether);
        assertEq(tierSource.creditFloor(), 200 ether);
        assertEq(token.effectiveCreditCap(user), 0);
        _promote(user, 89);
        assertEq(registry.getCreditLimit(user), 600 ether);
        assertEq(token.effectiveCreditCap(user), 400 ether);
    }

    function test_defaultThresholds_distinct_tier2_keeps_tier1_floor() public {
        registry.setCreditTier(2, 200 ether);
        assertEq(tierSource.creditFloor(), 100 ether);
        assertEq(tierSource.creditFloor(), registry.getCreditLimit(address(0xA001)));
    }

    function test_thresholds_reject_duplicate_zero_and_descending() public {
        uint256[] memory thresholds = new uint256[](3);
        thresholds[2] = 34;
        vm.expectRevert(Registry.ThreshNotAscending.selector);
        registry.setLevelThresholds(thresholds);
        thresholds[0] = 13;
        thresholds[1] = 12;
        vm.expectRevert(Registry.ThreshNotAscending.selector);
        registry.setLevelThresholds(thresholds);
        thresholds[1] = 13;
        vm.expectRevert(Registry.ThreshNotAscending.selector);
        registry.setLevelThresholds(thresholds);
    }

    /// Empty schedule: every address is at level 1, so the exact AUTO credit is tier1 - tier1 = 0.
    /// creditFloor reverts (the generated getter reverts out of bounds) and the token yields AUTO 0.
    function test_empty_schedule_floor_reverts_and_AUTO_is_zero() public {
        registry.setLevelThresholds(new uint256[](0));
        vm.expectRevert();
        tierSource.creditFloor();
        _setPolicy(2);
        address promoted = address(0xA0E1);
        _promote(promoted, 610);
        _request(promoted, token.PROTOCOL_CREDIT_CEILING());
        assertEq(registry.getCreditLimit(promoted), registry.creditTierConfig(1), "empty schedule: level 1");
        assertEq(token.effectiveCreditCap(promoted), 0, "AUTO is exactly 0 on an empty schedule");
    }

    function test_threshold_panic_propagates() public {
        bytes memory panic = abi.encodeWithSignature("Panic(uint256)", 0x11);
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("levelThresholds(uint256)", 0), panic);
        vm.expectRevert(panic);
        tierSource.creditFloor();
    }

    function test_other_threshold_failure_propagates() public {
        bytes memory failure = abi.encodeWithSignature("Error(string)", "threshold unavailable");
        vm.mockCallRevert(address(registry), abi.encodeWithSignature("levelThresholds(uint256)", 0), failure);
        vm.expectRevert(failure);
        tierSource.creditFloor();
    }

    function testFuzz_floor_matches_zeroReputation(uint256 seed, uint8 length, bool zeroFirst, bool equalTiers) public {
        uint256 n = bound(uint256(length), 0, 6);
        // Collapse the active schedule first, then clear old tiers bottom-up and populate
        // arbitrary monotone prices bottom-up, including zeros and equal adjacent tiers.
        registry.setLevelThresholds(new uint256[](0));
        for (uint256 level = 1; level <= 7; level++) registry.setCreditTier(level, 0);
        uint256 price = seed % 8 == 0 ? 0 : (seed % 8 == 1 ? type(uint256).max : seed / 2);
        for (uint256 level = 1; level <= 7; level++) {
            if (level > 1 && !(level == 2 && equalTiers)) {
                uint256 room = (type(uint256).max - price) / 8;
                price += uint256(keccak256(abi.encode(seed, level, "price"))) % (room + 1);
            }
            registry.setCreditTier(level, price);
        }
        uint256[] memory thresholds = new uint256[](n);
        if (n > 0) {
            thresholds[0] = zeroFirst ? 0 : 1 + seed % 1_000_000;
            for (uint256 j = 1; j < n; j++) {
                thresholds[j] = thresholds[j - 1] + 1 + uint256(keccak256(abi.encode(seed, j))) % 1_000_000;
            }
        }
        registry.setLevelThresholds(thresholds);
        address user = address(0xA001);
        assertEq(registry.globalReputation(user), 0);
        if (n == 0) {
            // Empty schedule: creditFloor reverts and the exact AUTO credit (tier1 - tier1) is 0.
            vm.expectRevert();
            tierSource.creditFloor();
            _setPolicy(2);
            _request(user, token.PROTOCOL_CREDIT_CEILING());
            assertEq(token.effectiveCreditCap(user), 0, "AUTO for reputation 0 must be 0");
            return;
        }
        assertEq(tierSource.creditFloor(), registry.getCreditLimit(user));
        // End to end: under AUTO a reputation-0 address gets 0 on every valid schedule.
        _setPolicy(2);
        _request(user, token.PROTOCOL_CREDIT_CEILING());
        assertEq(token.effectiveCreditCap(user), 0, "AUTO for reputation 0 must be 0");
    }

    function test_Medium1_AUTO_exposure_is_bounded_by_Registry_ledger() public {
        _medium1Schedule();
        _setPolicy(2);
        uint256[6] memory reputations = [uint256(0), 0, 34, 89, 233, 610];
        uint256 total;
        for (uint256 i; i < reputations.length; i++) {
            address user = address(uint160(0xE000 + i));
            _promote(user, reputations[i]);
            _request(user, token.PROTOCOL_CREDIT_CEILING());
            total += token.effectiveCreditCap(user);
        }
        assertEq(total, 3_100 ether);
        assertEq(registry.totalCreditExposure(), 3_500 ether);
        assertLe(total, registry.totalCreditExposure(), "AUTO must not exceed booked exposure");
    }

    /// 5.5.0 has no reputation producer: every address stays at reputation 0 (level 1). Under that
    /// premise AUTO grants 0 to every address, and credit exists only through MANUAL, where the cap
    /// is min(requested, approvedCap, level-1 tier); inputs above PROTOCOL_CREDIT_CEILING are refused.
    function testFuzz_noProducer_AUTO_zero_MANUAL_min(address user, uint256 requested, uint256 approved) public {
        vm.assume(user != address(0) && user != address(this));
        // requestCredit refuses a request above PROTOCOL_CREDIT_CEILING (pinned below);
        // approveCredit clamps the approval to the request.
        requested = bound(requested, 1, token.PROTOCOL_CREDIT_CEILING());
        approved = bound(approved, 0, 10 * token.PROTOCOL_CREDIT_CEILING());
        assertEq(registry.globalReputation(user), 0);
        uint256 tier = registry.getCreditLimit(user);
        assertEq(tier, registry.creditTierConfig(1), "reputation 0 is level 1");
        assertGt(tier, 0, "control: level-1 tier is non-zero, so AUTO=0 comes from the floor");

        _setPolicy(2);
        _request(user, requested);
        assertEq(token.effectiveCreditCap(user), 0, "AUTO without a producer grants nothing");

        _setPolicy(1);
        _request(user, requested);
        IExt(address(token)).approveCredit(user, approved);
        uint256 expected = requested;
        if (approved < expected) expected = approved;
        if (tier < expected) expected = tier;
        assertEq(token.effectiveCreditCap(user), expected, "MANUAL = min(requested, approved, tier)");

        uint256 ceiling = token.PROTOCOL_CREDIT_CEILING();
        vm.prank(user);
        vm.expectRevert(bytes4(keccak256("AboveCeiling()")));
        IExt(address(token)).requestCredit(ceiling + 1);
    }
}
