// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";

/// @notice CC-28 over-issue model (DVT audit rule ③): xPNTsToken.isOverIssued() plus the
///         value model (issuedValueUSD / backingValueUSD / effectiveCapUSD) and the factory's
///         governance-set baseline (industryScaleUSD + capRatioBps).
contract XPNTsOverIssueTest is Test {
    xPNTsFactory factory;
    xPNTsToken token;

    address owner = address(0xA11CE);        // factory owner (governance)
    address mockSP = address(0x5B);          // SuperPaymaster (mocked operators())
    address mockRegistry = address(0x3E);
    address community = address(0xC0);        // community owner / token deployer

    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.prank(owner);
        factory = new xPNTsFactory(mockSP, mockRegistry);

        // community deploys its xPNTs (1:1 exchange rate)
        vm.mockCall(
            mockRegistry,
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, community),
            abi.encode(true)
        );
        vm.prank(community);
        token = xPNTsToken(factory.deployxPNTsToken("Comm", "CMM", "Comm", "comm.eth", 1e18, address(0)));

        _setStake(0); // default: no aPNTs backing
    }

    /// @dev Mock SuperPaymaster.operators(community) → aPNTsBalance = `staked`.
    function _setStake(uint128 staked) internal {
        vm.mockCall(
            mockSP,
            abi.encodeWithSelector(bytes4(keccak256("operators(address)")), community),
            abi.encode(staked, false, false, address(0), uint32(0), uint48(0), address(0), uint256(0), uint256(0))
        );
    }

    function _mint(uint256 xpntsAmount) internal {
        vm.prank(community);
        token.mint(community, xpntsAmount);
    }

    // ---------------------------------------------------------------------
    // Defaults & baseline
    // ---------------------------------------------------------------------

    function test_Defaults() public view {
        // $0.02 price, 1e18 rate → issuedValueUSD = supply * 0.02
        assertEq(factory.aPNTsPriceUSD(), 0.02 ether);
        assertEq(factory.capRatioBps(), 10_000);
        assertEq(factory.industryScaleUSD("default"), 10_000 ether);
        // empty category falls back to "default" baseline
        assertEq(token.effectiveCapUSD(), 10_000 ether);
        assertEq(token.issuedValueUSD(), 0);
        assertFalse(token.isOverIssued());
        assertEq(token.credibilityScore(), 100); // zero issuance is fully "backed"
    }

    // ---------------------------------------------------------------------
    // tier-2: value-based cap
    // ---------------------------------------------------------------------

    function test_WithinBaseline_NotOverIssued() public {
        _mint(100_000 ether); // issued = $2,000 < $10,000 baseline
        assertEq(token.issuedValueUSD(), 2_000 ether);
        assertFalse(token.isOverIssued());
    }

    function test_ExceedsBaseline_OverIssued() public {
        _mint(600_000 ether); // issued = $12,000 > $10,000 baseline, no stake
        assertEq(token.issuedValueUSD(), 12_000 ether);
        assertTrue(token.isOverIssued());
    }

    function test_StakeAmplifiesCap_AdditiveBacking() public {
        _mint(600_000 ether);          // issued = $12,000
        assertTrue(token.isOverIssued());
        _setStake(200_000 ether);      // backing = 200,000 * $0.02 = $4,000
        assertEq(token.backingValueUSD(), 4_000 ether);
        assertEq(token.effectiveCapUSD(), 14_000 ether); // 10,000 + 4,000
        assertFalse(token.isOverIssued());               // $12,000 < $14,000
    }

    // ---------------------------------------------------------------------
    // tier-1: absolute issuanceCap
    // ---------------------------------------------------------------------

    function test_IssuanceCap_HardStop() public {
        _mint(100_000 ether); // well within the value cap
        assertFalse(token.isOverIssued());
        vm.prank(community);
        token.setIssuanceCap(50_000 ether);
        assertTrue(token.isOverIssued()); // supply 100k > cap 50k, regardless of value
    }

    function test_IssuanceCap_ZeroDisables() public {
        _mint(100_000 ether);
        vm.prank(community);
        token.setIssuanceCap(0);
        assertFalse(token.isOverIssued());
    }

    function test_SetIssuanceCap_OnlyCommunityOwner() public {
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, address(this)));
        token.setIssuanceCap(1 ether);
    }

    // ---------------------------------------------------------------------
    // credibilityScore
    // ---------------------------------------------------------------------

    function test_CredibilityScore_PartialBacking() public {
        _mint(600_000 ether);      // issued = $12,000
        _setStake(200_000 ether);  // backing = $4,000
        assertEq(token.credibilityScore(), 33); // 4000/12000 = 33%
    }

    function test_CredibilityScore_CappedAt100() public {
        _mint(100_000 ether);       // issued = $2,000
        _setStake(500_000 ether);   // backing = $10,000 > issued
        assertEq(token.credibilityScore(), 100);
    }

    // ---------------------------------------------------------------------
    // category
    // ---------------------------------------------------------------------

    function test_Category_ChangesBaseline() public {
        vm.prank(community);
        token.setCategory("DeFi");
        assertEq(token.effectiveCapUSD(), 50_000 ether); // DeFi baseline
        _mint(600_000 ether); // $12,000 < $50,000
        assertFalse(token.isOverIssued());
    }

    function test_SetCategory_OnlyCommunityOwner() public {
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, address(this)));
        token.setCategory("DeFi");
    }

    // ---------------------------------------------------------------------
    // factory governance knobs
    // ---------------------------------------------------------------------

    function test_CapRatioBps_TightensBaseline() public {
        vm.prank(owner);
        factory.setCapRatioBps(5_000); // 50%
        assertEq(token.effectiveCapUSD(), 5_000 ether); // 10,000 * 0.5
        _mint(300_000 ether); // $6,000 > $5,000
        assertTrue(token.isOverIssued());
    }

    function test_SetCapRatioBps_Bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(xPNTsFactory.InvalidCapRatio.selector);
        factory.setCapRatioBps(0);
        vm.expectRevert(xPNTsFactory.InvalidCapRatio.selector);
        factory.setCapRatioBps(10_001);
        factory.setCapRatioBps(10_000); // boundary ok
        vm.stopPrank();
    }

    function test_SetIndustryScaleUSD_Governance() public {
        vm.prank(owner);
        factory.setIndustryScaleUSD("default", 1_000 ether);
        assertEq(token.effectiveCapUSD(), 1_000 ether);
    }

    function test_FactoryKnobs_OnlyOwner() public {
        vm.expectRevert();
        factory.setCapRatioBps(5_000);
        vm.expectRevert();
        factory.setIndustryScaleUSD("default", 1 ether);
    }
}
