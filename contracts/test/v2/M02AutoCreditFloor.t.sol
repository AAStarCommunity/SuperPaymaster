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
}
