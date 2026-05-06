// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/tokens/xPNTsToken.sol";
import "src/core/Registry.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/// @notice P0-11 (B2-N3 / B4-M2): All three price-setter functions now have
///         absolute MIN/MAX guards and a per-tx delta cap to limit the blast
///         radius of a mis-click or partially-compromised owner key.
///
///         Setters under test:
///           1. SuperPaymaster.setAPNTSPrice       (±10%, absolute [1e15, 1e21])
///           2. xPNTsToken.updateExchangeRate       (±20%, absolute [1e14, 1e22])
///           3. PaymasterBase.setCachedPrice        (±30%, absolute [100e8, 1e14])

// ─── Minimal mocks ────────────────────────────────────────────────────────────

contract MockEPBounds {
    function depositTo(address) external payable {}
}

contract MockOracleBounds {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockAPNTsBounds is ERC20 {
    constructor() ERC20("aPNTs", "aPNTs") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockRegistryBounds {
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
}

// ─── Test 1: SuperPaymaster.setAPNTSPrice ─────────────────────────────────────

contract PriceSetter_APNTS_Test is Test {
    using stdStorage for StdStorage;

    SuperPaymaster paymaster;
    address owner = address(0xABCD);

    // initialize() sets aPNTsPriceUSD = 0.02 ether = 2e16
    uint256 constant INIT_PRICE = 0.02 ether;
    uint256 constant MIN = 1e15;
    uint256 constant MAX = 1e21;

    function setUp() public {
        vm.warp(1_700_000_000);
        Registry registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        MockAPNTsBounds apnts = new MockAPNTsBounds();
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(new MockEPBounds())),
            registry,
            address(new MockOracleBounds()),
            owner,
            address(apnts),
            owner,
            3600
        );
        vm.prank(owner);
        paymaster.updatePrice();
    }

    // Helper: use stdstore to bypass delta and write aPNTsPriceUSD directly.
    function _writeApntsPrice(uint256 v) internal {
        stdstore.target(address(paymaster)).sig("aPNTsPriceUSD()").checked_write(v);
    }

    function test_SetAPNTSPrice_NominalUpdate() public {
        // 9% up from INIT_PRICE — within the ±10% window
        uint256 ok = INIT_PRICE * 10900 / 10000;
        vm.prank(owner);
        paymaster.setAPNTSPrice(ok);
        assertEq(paymaster.aPNTsPriceUSD(), ok);
    }

    function test_SetAPNTSPrice_RejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.setAPNTSPrice(0);
    }

    function test_SetAPNTSPrice_RejectsBelowMin() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.setAPNTSPrice(MIN - 1);
    }

    function test_SetAPNTSPrice_RejectsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.setAPNTSPrice(MAX + 1);
    }

    function test_SetAPNTSPrice_AcceptsExactMin_WhenUninit() public {
        // delta check skips when oldPrice == 0; so zero out first via stdstore
        _writeApntsPrice(0);
        vm.prank(owner);
        paymaster.setAPNTSPrice(MIN);
        assertEq(paymaster.aPNTsPriceUSD(), MIN);
    }

    function test_SetAPNTSPrice_AcceptsExactMax_WhenUninit() public {
        _writeApntsPrice(0);
        vm.prank(owner);
        paymaster.setAPNTSPrice(MAX);
        assertEq(paymaster.aPNTsPriceUSD(), MAX);
    }

    function test_SetAPNTSPrice_DeltaRejectedAbove() public {
        // 11.1% above INIT_PRICE — outside ±10%
        uint256 tooHigh = INIT_PRICE * 11100 / 10000;
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.setAPNTSPrice(tooHigh);
    }

    function test_SetAPNTSPrice_DeltaRejectedBelow() public {
        // 11% below INIT_PRICE — outside ±10%
        uint256 tooLow = INIT_PRICE * 8900 / 10000;
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.setAPNTSPrice(tooLow);
    }

    function test_SetAPNTSPrice_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        paymaster.setAPNTSPrice(INIT_PRICE);
    }
}

// ─── Test 2: xPNTsToken.updateExchangeRate ────────────────────────────────────

contract PriceSetter_ExchangeRate_Test is Test {
    xPNTsToken token;
    address admin = address(0x111);
    address factory = address(0x222); // treated as factory/owner

    uint256 constant MIN = 1e14;
    uint256 constant MAX = 1e22;
    uint256 constant DELTA_BPS = 2000; // 20%

    function setUp() public {
        address impl = address(new xPNTsToken());
        token = xPNTsToken(Clones.clone(impl));
        // initialize: factory = admin (cloneAndInit wires factory = caller)
        vm.prank(admin);
        token.initialize("TestPoints", "XP", admin, "Comm", "test.eth", 1e18);
    }

    function test_UpdateExchangeRate_NominalUpdate() public {
        // initial rate = 1e18; 19% up → within ±20% window
        uint256 ok = 1e18 * 11900 / 10000;
        vm.prank(admin);
        token.updateExchangeRate(ok);
        assertEq(token.exchangeRate(), ok);
    }

    function test_UpdateExchangeRate_RejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(xPNTsToken.ExchangeRateCannotBeZero.selector);
        token.updateExchangeRate(0);
    }

    function test_UpdateExchangeRate_RejectsBelowMin() public {
        vm.prank(admin);
        vm.expectRevert(xPNTsToken.ExchangeRateCannotBeZero.selector);
        token.updateExchangeRate(MIN - 1);
    }

    function test_UpdateExchangeRate_RejectsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(xPNTsToken.ExchangeRateCannotBeZero.selector);
        token.updateExchangeRate(MAX + 1);
    }

    function test_UpdateExchangeRate_AcceptsExactMin() public {
        // current rate = 1e18; MIN is far below delta band, so must first set
        // a low base near MIN (but within 20% of current 1e18 — impossible).
        // So just reset from 1e18 is the starting state; test the absolute
        // guard independently by deploying a fresh token with a lower init rate.
        address impl2 = address(new xPNTsToken());
        xPNTsToken t2 = xPNTsToken(Clones.clone(impl2));
        vm.prank(admin);
        t2.initialize("T2", "T2", admin, "C", "c.eth", MIN);
        // rate is exactly MIN — no-op update to same value should succeed
        vm.prank(admin);
        t2.updateExchangeRate(MIN);
        assertEq(t2.exchangeRate(), MIN);
    }

    function test_UpdateExchangeRate_DeltaRejectedAbove() public {
        uint256 base = 1e18;
        // 21% above base
        uint256 tooHigh = base * 12100 / 10000;
        vm.prank(admin);
        vm.expectRevert(xPNTsToken.ExchangeRateCannotBeZero.selector);
        token.updateExchangeRate(tooHigh);
    }

    function test_UpdateExchangeRate_DeltaRejectedBelow() public {
        uint256 base = 1e18;
        // 21% below base
        uint256 tooLow = base * 7900 / 10000;
        vm.prank(admin);
        vm.expectRevert(xPNTsToken.ExchangeRateCannotBeZero.selector);
        token.updateExchangeRate(tooLow);
    }

    function test_UpdateExchangeRate_DeltaAccepted() public {
        uint256 base = 1e18;
        // 19% up — within 20% window
        uint256 ok = base * 11900 / 10000;
        vm.prank(admin);
        token.updateExchangeRate(ok);
        assertEq(token.exchangeRate(), ok);
    }
}

// ─── Test 3: PaymasterBase.setCachedPrice ─────────────────────────────────────

contract PriceSetter_CachedPrice_Test is Test {
    Paymaster paymaster;
    address owner = address(0xABCD);

    uint256 constant MIN = 100e8;          // $100
    uint256 constant MAX = 1_000_000e8;    // $1M
    uint256 constant DELTA_BPS = 3000;     // 30%

    function setUp() public {
        vm.warp(1_700_000_000);
        Paymaster impl = new Paymaster(address(new MockRegistryBounds()));
        paymaster = Paymaster(payable(Clones.clone(address(impl))));
        paymaster.initialize(
            address(new MockEPBounds()),
            owner,
            owner,
            address(new MockOracleBounds()),
            200,
            10 ether,
            3600
        );
        // seed the cache so delta checks have a non-zero reference
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp));
    }

    function test_SetCachedPrice_RejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(0, uint48(block.timestamp));
    }

    function test_SetCachedPrice_RejectsBelowMin() public {
        // Must re-seed far-below to try to set a price that passes delta but
        // fails absolute check. Easiest: try directly from 2000e8 baseline
        // to something below MIN ($100) → both delta AND absolute would fire.
        // Use absolute check alone: set price = MIN - 1 directly (delta gap
        // from 2000e8 is massive, so absolute guard fires first).
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(MIN - 1, uint48(block.timestamp));
    }

    function test_SetCachedPrice_RejectsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(MAX + 1, uint48(block.timestamp));
    }

    function test_SetCachedPrice_RejectsFutureTimestamp() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp + 1));
    }

    function test_SetCachedPrice_DeltaRejectedAbove() public {
        // baseline 2000e8, 31% above = 2620e8 → outside 30% window
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(2620e8, uint48(block.timestamp));
    }

    function test_SetCachedPrice_DeltaRejectedBelow() public {
        // 31% below = 1380e8
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(1380e8, uint48(block.timestamp));
    }

    function test_SetCachedPrice_DeltaAccepted() public {
        // 29% up from 2000 = 2580e8
        vm.prank(owner);
        paymaster.setCachedPrice(2580e8, uint48(block.timestamp));
        (uint208 price,) = paymaster.cachedPrice();
        assertEq(price, 2580e8);
    }

    function test_SetCachedPrice_AcceptsExactMin_WhenUninit() public {
        // Fresh paymaster with no prior cache (price=0) should skip delta check
        Paymaster impl2 = new Paymaster(address(new MockRegistryBounds()));
        Paymaster fresh = Paymaster(payable(Clones.clone(address(impl2))));
        fresh.initialize(
            address(new MockEPBounds()),
            owner, owner,
            address(new MockOracleBounds()),
            200, 10 ether, 3600
        );
        vm.prank(owner);
        fresh.setCachedPrice(MIN, uint48(block.timestamp));
        (uint208 price,) = fresh.cachedPrice();
        assertEq(price, MIN);
    }

    function test_SetCachedPrice_OnlyOwner() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp));
    }
}
