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

    /// @dev Mock canonical-SP.operators(community) → configured & linked to THIS token, stake set.
    function _setStake(uint128 staked) internal {
        _setStakeOn(mockSP, staked, true, address(token));
    }

    /// @dev Full control of the operators() tuple, for spoof-resistance tests.
    function _setStakeOn(address sp, uint128 staked, bool isConfigured, address linkedToken) internal {
        vm.mockCall(
            sp,
            abi.encodeWithSelector(bytes4(keccak256("operators(address)")), community),
            abi.encode(staked, isConfigured, false, linkedToken, uint32(0), uint48(0), address(0), uint256(0), uint256(0))
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
    // H-1: backing is spoof-resistant (canonical SP + link verification)
    // ---------------------------------------------------------------------

    function test_Backing_IgnoresCommunityMutableSP() public {
        _mint(600_000 ether); // over the $10k baseline, no backing
        assertTrue(token.isOverIssued());
        // Attacker deploys a fake SP that reports a huge stake and points the token at it.
        address fakeSP = address(0xBEEF);
        vm.mockCall(
            fakeSP,
            abi.encodeWithSelector(bytes4(keccak256("operators(address)")), community),
            abi.encode(uint128(10_000_000 ether), true, false, address(token), uint32(0), uint48(0), address(0), uint256(0), uint256(0))
        );
        vm.prank(community);
        token.setSuperPaymasterAddress(fakeSP);
        // backing still reads the CANONICAL factory SP, not the community-set one → still over-issued.
        assertEq(token.backingValueUSD(), 0);
        assertTrue(token.isOverIssued());
    }

    function test_Backing_RequiresConfiguredAndLinked() public {
        _mint(600_000 ether);
        // stake present but operator not configured → not counted
        _setStakeOn(mockSP, 500_000 ether, false, address(token));
        assertEq(token.backingValueUSD(), 0);
        // configured but linked to a DIFFERENT token → not counted (can't borrow others' stake)
        _setStakeOn(mockSP, 500_000 ether, true, address(0xDEAD));
        assertEq(token.backingValueUSD(), 0);
        // configured AND linked to this token → counted
        _setStakeOn(mockSP, 500_000 ether, true, address(token));
        assertEq(token.backingValueUSD(), 10_000 ether);
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

    function test_Category_GovernanceAssigned_ChangesBaseline() public {
        vm.prank(owner); // H-3: category is governance-assigned, NOT community-selected
        factory.setTokenCategory(address(token), "DeFi");
        assertEq(token.effectiveCapUSD(), 50_000 ether); // DeFi baseline
        _mint(600_000 ether); // $12,000 < $50,000
        assertFalse(token.isOverIssued());
    }

    function test_SetTokenCategory_OnlyGovernance() public {
        // community cannot self-select a higher-baseline category
        vm.prank(community);
        vm.expectRevert();
        factory.setTokenCategory(address(token), "DeFi");
    }

    function test_Category_EmptyFallsBackToDefault() public {
        assertEq(token.effectiveCapUSD(), 10_000 ether); // never assigned → "default"
        vm.prank(owner);
        factory.setTokenCategory(address(token), ""); // explicit reset
        assertEq(token.effectiveCapUSD(), 10_000 ether);
    }

    // L-1: setTokenCategory only accepts tokens this factory deployed
    function test_SetTokenCategory_RejectsNonFactoryToken() public {
        vm.prank(owner);
        vm.expectRevert(xPNTsFactory.NotFactoryToken.selector);
        factory.setTokenCategory(address(0xABCD), "DeFi");
    }

    // L-2: a non-empty category must be seeded first — a typo can't force 100% coverage
    function test_SetTokenCategory_RejectsUnseededCategory() public {
        vm.prank(owner);
        vm.expectRevert(xPNTsFactory.CategoryNotSeeded.selector);
        factory.setTokenCategory(address(token), "DeFo"); // typo of DeFi, never seeded
    }

    function test_SetTokenCategory_AllowsSeededCategory() public {
        vm.startPrank(owner);
        factory.setIndustryScaleUSD("Infra", 30_000 ether); // seed first
        factory.setTokenCategory(address(token), "Infra");
        vm.stopPrank();
        assertEq(token.effectiveCapUSD(), 30_000 ether);
    }

    // L-2 behavior: a DELIBERATELY zero-baseline category → cap is backing-only (documented).
    function test_ZeroBaselineCategory_RequiresFullStakeBacking() public {
        vm.startPrank(owner);
        factory.setIndustryScaleUSD("Strict", 1); // seed non-zero so assignment is allowed
        factory.setTokenCategory(address(token), "Strict");
        factory.setIndustryScaleUSD("Strict", 0); // governance then deliberately zeroes it
        vm.stopPrank();
        _mint(100_000 ether); // $2,000 issued, no backing
        assertEq(token.effectiveCapUSD(), 0); // baseline 0 + backing 0
        assertTrue(token.isOverIssued());      // must fully stake-back or be flagged
        _setStake(200_000 ether);              // $4,000 backing > $2,000 issued
        assertEq(token.effectiveCapUSD(), 4_000 ether);
        assertFalse(token.isOverIssued());
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

    function test_SetIndustryScaleUSD_BoundedToPreventOverflow() public {
        uint256 tooBig = factory.MAX_INDUSTRY_SCALE_USD() + 1;
        vm.prank(owner);
        vm.expectRevert(xPNTsFactory.InvalidParameters.selector);
        factory.setIndustryScaleUSD("default", tooBig);
    }

    // ---------------------------------------------------------------------
    // M-1: renounceFactory must NOT make the auditor's isOverIssued() revert
    // ---------------------------------------------------------------------

    function test_RenounceFactory_ConservativelyFlags_NoCleanEscape() public {
        _mint(600_000 ether);
        assertTrue(token.isOverIssued()); // tier-2 active
        vm.prank(community);
        token.renounceFactory();
        // views must not revert; tier-2 is unverifiable without a factory
        assertEq(token.effectiveCapUSD(), 0);
        assertEq(token.issuedValueUSD(), 0);
        // renounce must NOT be a clean escape: any live issuance is conservatively flagged.
        assertTrue(token.isOverIssued());
        assertEq(token.credibilityScore(), 0); // unverifiable backing → worst score
    }

    function test_RenounceFactory_ZeroSupply_NotFlagged() public {
        vm.prank(community);
        token.renounceFactory();
        assertFalse(token.isOverIssued()); // nothing issued → nothing to flag
        assertEq(token.credibilityScore(), 100);
    }

    function test_FactoryKnobs_OnlyOwner() public {
        vm.expectRevert();
        factory.setCapRatioBps(5_000);
        vm.expectRevert();
        factory.setIndustryScaleUSD("default", 1 ether);
    }
}
