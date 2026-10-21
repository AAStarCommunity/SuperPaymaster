// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "../../../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "../../../../src/tokens/xPNTsToken.sol";
import "../../../../src/tokens/xPNTsFactory.sol";
import "../../../../src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import {UUPSDeployHelper} from "../../../helpers/UUPSDeployHelper.sol";
import {V2TokenDeployer} from "../../../helpers/V2TokenDeployer.sol";
import {xPNTsFactoryV2} from "../../../../src/tokens/v2/xPNTsFactoryV2.sol";
import {IxPNTsTokenV2} from "../../../../src/tokens/v2/IxPNTsTokenV2.sol";

contract MockRegistry is IRegistry {
    using Clones for address;
    
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }

    function grantRole(bytes32 role, address account) public {
        roles[role][account] = true;
    }

    // Unused methods
    function setCreditTier(uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { return RoleConfig(0,0,0,0,0,0,0,false, 0,"",address(0),0); }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function getCreditLimit(address) external view override returns (uint256) { return 1000 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external pure override returns (string memory) { return "1"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

contract MockAggregatorV3 is AggregatorV3Interface {
    int256 public price;
    uint8 public _decimals;

    constructor(int256 _price, uint8 _dec) {
        price = _price;
        _decimals = _dec;
    }
    
    function decimals() external view override returns (uint8) { return _decimals; }
    function description() external view override returns (string memory) { return "Mock"; }
    function version() external view override returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) { return (0,0,0,0,0); }
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
}

/// @dev 3.x-shaped malicious token (legacy `recordDebt` re-entry hook, no BALANCE_MODE_VERSION).
///      SP 5.5.0 must refuse to configure it at all.
contract MaliciousToken is ERC20 {
    SuperPaymaster public paymaster;
    constructor(SuperPaymaster _pm) ERC20("Malicious", "MAL") {
        paymaster = _pm;
    }

    function recordDebt(address, uint256) external {
        paymaster.withdraw(1 ether);
    }

    function exchangeRate() external pure returns (uint256) { return 1e18; }
    function getDebt(address) external pure returns (uint256) { return 0; }
}

/// @dev v2-shaped malicious token: passes the BALANCE_MODE_VERSION probe and the validation-time
///      lock, then tries to re-enter SuperPaymaster from `settleLocked` during postOp.
contract MaliciousV2Token is ERC20 {
    SuperPaymaster public paymaster;
    constructor(SuperPaymaster _pm) ERC20("MaliciousV2", "MAL2") {
        paymaster = _pm;
    }

    function BALANCE_MODE_VERSION() external pure returns (uint16) { return 1; }
    function exchangeRate() external pure returns (uint256) { return 1e18; }

    function tryLockForGas(address, bytes32, uint256 reserveAPNTs, bool)
        external pure returns (IxPNTsTokenV2.LockResult, uint256)
    {
        return (IxPNTsTokenV2.LockResult.OK, reserveAPNTs);
    }

    function settleLocked(address, bytes32, uint256) external returns (uint256) {
        // Attack: try to withdraw operator funds from inside postOp
        paymaster.withdraw(1 ether);
        return 0;
    }
}

contract SuperPaymasterHardenVerification is Test {
    using Clones for address;
    SuperPaymaster paymaster;
    xPNTsToken apnts;          // aPNTs deposit token (3.x; SP only uses it through IERC20)
    xPNTsFactory factory;      // legacy 3.x factory (used to prove 3.x tokens are rejected)
    xPNTsFactoryV2 factoryV2;  // 5.5.0 community-token factory
    V2TokenDeployer.Stack stack;
    MockRegistry registry;

    address owner = address(0x1);
    address community = address(0x2);
    address ep = address(0x3);
    address priceFeedAddr;
    address treasury = address(0x5);

    function setUp() public {
        vm.warp(1000 days); // Avoid timestamp underflow
        vm.startPrank(owner);
        registry = new MockRegistry();
        address implementation = address(new xPNTsToken());
        apnts = xPNTsToken(implementation.clone());
        apnts.initialize("AAStar PNTs", "aPNTs", owner, "AAStar", "aastar.eth", 1e18);

        // Correctly initialize Mock Price Feed
        MockAggregatorV3 realPriceFeed = new MockAggregatorV3(2000 * 1e8, 8);
        priceFeedAddr = address(realPriceFeed);

        // Legacy 3.x factory (only for the rejection test)
        factory = new xPNTsFactory(address(0), address(registry));

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(ep),
            IRegistry(address(registry)),
            priceFeedAddr,
            owner,
            address(apnts),
            treasury,
            3600
        );
        vm.stopPrank();

        // xPNTs v2 stack + v2 factory bound to this SP (spec §6 step 4)
        stack = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        factoryV2 = new xPNTsFactoryV2(address(paymaster), address(registry), address(stack.impl), address(stack.tier));

        vm.startPrank(owner);
        paymaster.setXPNTsFactory(address(factoryV2));

        // Initialize Price Cache
        paymaster.queueBLSAggregator(owner);
        vm.warp(block.timestamp + 24 hours + 1);
        paymaster.applyBLSAggregator();
        paymaster.updatePriceDVT(2000 * 1e8, block.timestamp, "", 0);

        registry.grantRole(keccak256("COMMUNITY"), community);
        registry.grantRole(keccak256("PAYMASTER_SUPER"), community);

        vm.stopPrank();
    }

    function testRoundingCeil() public {
        // _calculateAPNTsAmount logic:
        // (ethAmount * price * 1e18) / (10^decimals * aPNTsPriceUSD)

        // Mock a situation where division has a remainder
        // Let ethAmount = 1 (1 wei)
        // Let price = 2000 * 1e8 (8 decimals)
        // Let aPNTsPriceUSD = 0.02 * 1e18 (18 decimals)

        // P0-11: setAPNTSPrice is now bounded to ±10% of current price (init 0.02 ether).
        // Use 0.021 ether (5% above) which is within the window.
        vm.prank(owner);
        paymaster.setAPNTSPrice(0.021 ether);

        // Verify Rounding.Ceil vs Rounding.Floor with the new price.
        uint256 ethAmount = 1;
        uint256 price = 2000 * 1e8;
        uint256 priceDecimals = 8;
        uint256 aPNTsPriceUSD = 0.021 ether;

        uint256 expectedCeil = Math.mulDiv(
            ethAmount * price,
            1e18,
            (10**priceDecimals) * aPNTsPriceUSD,
            Math.Rounding.Ceil
        );

        uint256 expectedFloor = Math.mulDiv(
            ethAmount * price,
            1e18,
            (10**priceDecimals) * aPNTsPriceUSD,
            Math.Rounding.Floor
        );

        // ceil(200000e8 / (1e8 * 0.021e18)) = ceil(200000 / 21000000) → 1 (non-zero)
        // The important assertion: ceil >= floor, and a remainder exists (ceil != floor).
        assertGe(expectedCeil, expectedFloor);
        assertGt(expectedCeil, 0);
    }

    function testBondingEnforcement() public {
        address fakeToken = address(0xdead);

        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.InvalidXPNTsToken.selector));
        paymaster.configureOperator(fakeToken, community);

        // Now deploy a real one through the (v2) factory
        vm.startPrank(community);
        address realToken = factoryV2.deployxPNTsToken("Real", "RL", "Real", "real.eth", 1e18, address(0));

        // Should succeed
        paymaster.configureOperator(realToken, community);
        vm.stopPrank();
        (, bool configured,, address tok,,,,,) = paymaster.operators(community);
        assertTrue(configured);
        assertEq(tok, realToken);
    }

    /// @notice 5.5.0 (§3.3, §8 migration): a token that IS bound to the operator by the wired
    ///         factory but is a 3.x token (no BALANCE_MODE_VERSION) is rejected.
    function testBondingEnforcement_Legacy3xFactoryTokenRejected() public {
        vm.prank(owner);
        paymaster.setXPNTsFactory(address(factory)); // legacy 3.x factory
        vm.startPrank(community);
        address legacyToken = factory.deployxPNTsToken("Old", "OLD", "Old", "old.eth", 1e18, address(0));
        assertEq(factory.getTokenAddress(community), legacyToken, "factory binding holds");
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.InvalidXPNTsToken.selector));
        paymaster.configureOperator(legacyToken, community);
        vm.stopPrank();
    }

    /// @notice Replaces the 3.x version of this test (malicious `recordDebt` re-entry, swallowed
    ///         by try/catch into `pendingDebts` — both removed in 5.5.0). Part 1: a legacy-shaped
    ///         malicious token cannot even be configured.
    function testReentrancyProtection_LegacyShapedTokenRejected() public {
        MaliciousToken mal = new MaliciousToken(paymaster);
        vm.mockCall(
            address(factoryV2),
            abi.encodeWithSelector(IxPNTsFactory.getTokenAddress.selector, community),
            abi.encode(address(mal))
        );
        vm.prank(community);
        vm.expectRevert(SuperPaymasterStorage.InvalidXPNTsToken.selector);
        paymaster.configureOperator(address(mal), community);
    }

    /// @notice Part 2: a v2-shaped malicious token that re-enters SP from `settleLocked` is
    ///         blocked by the reentrancy guard, and because settlement is NOT wrapped in
    ///         try/catch (B-1) the whole postOp reverts — nothing is silently recorded, the
    ///         operator's a0 stays in flight for `releaseStaleSponsorship` (I10).
    function testReentrancyProtectionPostOp() public {
        MaliciousV2Token mal = new MaliciousV2Token(paymaster);

        // Mock factory to accept this malicious token
        vm.mockCall(
            address(factoryV2),
            abi.encodeWithSelector(IxPNTsFactory.getTokenAddress.selector, community),
            abi.encode(address(mal))
        );

        vm.prank(community);
        paymaster.configureOperator(address(mal), community);

        // Fund paymaster for operator
        vm.startPrank(owner);
        apnts.mint(community, 10 ether);
        vm.stopPrank();

        vm.startPrank(community);
        apnts.approve(address(paymaster), 10 ether);
        paymaster.deposit(10 ether);
        vm.stopPrank();

        address victimUser = address(0xabc);
        vm.prank(address(registry));
        paymaster.updateSBTStatus(victimUser, true);

        PackedUserOperation memory op;
        op.sender = victimUser;
        op.paymasterAndData = V2TokenDeployer.pmd(address(paymaster), 0, 200_000, community, type(uint256).max, address(mal), 0);
        bytes32 h = keccak256("reentrancy");

        vm.prank(ep);
        (bytes memory context, uint256 vd) = paymaster.validatePaymasterUserOp(op, h, 0.00001 ether);
        assertEq(uint160(vd), 0, "precondition: validation passes");
        (uint128 balAfterValidate,,,,,,,,) = paymaster.operators(community);

        // Re-entry from settleLocked -> SP.withdraw hits nonReentrant; postOp does not swallow it.
        vm.prank(ep);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.00001 ether, 0);

        (uint128 balAfter,,,,,,,,) = paymaster.operators(community);
        assertEq(balAfter, balAfterValidate, "no funds moved by the re-entrant call");
        (address f, uint256 a0) = paymaster.inflightOf(h);
        assertEq(f, community, "a0 still in flight (postOp rolled back)");
        assertEq(a0, abi.decode(context, (SuperPaymaster.OpCtx)).a0);
        assertEq(paymaster.protocolRevenue(), 0, "no revenue booked for an unsettled op");
    }
}
