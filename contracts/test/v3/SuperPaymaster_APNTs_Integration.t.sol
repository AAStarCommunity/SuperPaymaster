// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";

/**
 * @title SuperPaymaster_APNTs_Integration
 * @notice Integration tests for unified aPNTs accounting, migrated to SuperPaymaster 5.5.0 +
 *         xPNTs v2 (spec docs/design/aoa-balance-mode/03-final-spec.md).
 *
 *  Key behaviour tested:
 *  1. configureOperator(xPNTsToken, treasury) — 2-arg, no exchangeRate param; v2 token only
 *  2. Credit path (AUTO policy + user request): postOp settles the aPNTs charge as debt
 *     (settleCredit, C-2); with credit OFF an empty account is NOT sponsored (R-2 / I3)
 *  3. Balance path at non-1:1 rate: the escrow burns xPNTs = ceil(charge * x0 / a0)
 *  4. getAvailableCredit = max(0, effectiveCreditCap - debts - reserved) (R4-H4)
 *  5. Protocol fee adds markup in aPNTs; debtAPNTs > aPNTsCost
 *  6. validatePaymasterUserOp reads live exchangeRate() from the token against maxRate
 *
 *  Numbers (price $2000/ETH, aPNTs $0.02, MAX_COST = 1e6 wei, fee 10%, validation buffer 10%):
 *    calc(MAX_COST) = 1e11 aPNTs;  a0 = ceil(1e11 * 1.2) = 1.2e11;
 *    charge (actualUserOpFeePerGas = 0 -> bufWei = 0) = ceil(1e11 * 1.1) = 1.1e11.
 */
contract SuperPaymaster_APNTs_Integration_Test is Test {
    using stdStorage for StdStorage;

    SuperPaymaster      public sp;
    xPNTsTokenV2        public xpnts;
    SPMockEntryPoint    public ep;
    SPMockPriceFeed     public priceFeed;
    SPMockAPNTs         public apnts;
    SPMockRegistry      public registry;
    MockXPNTsFactory    public mockFactory;

    address owner    = address(0xF1);
    address treasury = address(0xF2);
    address operator = address(0xF3);
    address user     = address(0xF5);

    // 1_000_000 wei gas cost -> 1e11 aPNTs at $2000 ETH / $0.02 aPNTs
    uint256 constant MAX_COST = 1_000_000;
    uint256 constant A_GAS    = 1e11;    // calc(MAX_COST)
    uint256 constant A0       = 1.2e11;  // ceil(A_GAS * (BPS + fee + buffer) / BPS)
    uint256 constant CHARGE   = 1.1e11;  // ceil(A_GAS * (BPS + fee) / BPS)

    // operators() field indices (9-tuple, exchangeRate removed in v5.3.3)
    // 0:aPNTsBalance 1:isConfigured 2:isPaused 3:xPNTsToken 4:reputation
    // 5:minTxInterval 6:treasury 7:totalSpent 8:totalTxSponsored

    function setUp() public {
        vm.startPrank(owner);

        ep        = new SPMockEntryPoint();
        priceFeed = new SPMockPriceFeed();   // $2000/ETH, 8 decimals
        apnts     = new SPMockAPNTs();
        registry  = new SPMockRegistry();

        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(ep)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );
        vm.warp(block.timestamp + 2 hours);
        sp.updatePrice();

        mockFactory = new MockXPNTsFactory();
        sp.setXPNTsFactory(address(mockFactory));

        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);

        apnts.mint(operator, 100_000 ether);
        vm.stopPrank();

        // Real xPNTs v2 token (clone), rate 1e18, genesis SP = sp, community owner = operator.
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(sp), address(registry));
        xpnts = V2TokenDeployer.newToken(st, operator, operator, address(sp), 1e18);
        mockFactory.setToken(operator, address(xpnts));

        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);

        vm.startPrank(operator);
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(xpnts), treasury); // 2-arg (no exchangeRate)
        sp.deposit(10_000 ether);
        vm.stopPrank();
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _setXPNTsRate(uint256 rate) internal {
        stdstore.target(address(xpnts)).sig("exchangeRate()").checked_write(rate);
    }

    function _buildPaymasterData(uint256 maxRate) internal view returns (bytes memory) {
        return V2TokenDeployer.pmd(address(sp), 100000, 200000, operator, maxRate, address(xpnts), 0);
    }

    function _op(address sender, uint256 maxRate) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.paymasterAndData = _buildPaymasterData(maxRate);
    }

    function _runValidate(uint256 maxRate) internal returns (bytes memory ctx) {
        vm.prank(address(ep));
        (ctx,) = sp.validatePaymasterUserOp(_op(user, maxRate), bytes32(uint256(1)), MAX_COST);
    }

    /// @dev AUTO credit policy (queue -> 48 h -> execute, C-3), then each user files a
    ///      current-epoch request (spec §0 D-20: AUTO users sign requestCredit once).
    function _enableAutoCredit(address[] memory users, uint256 requestCap) internal {
        vm.prank(operator); // communityOwner
        IxPNTsV2Admin(address(xpnts)).queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        IxPNTsV2Admin(address(xpnts)).executeCreditPolicy();
        sp.updatePrice(); // keep the price cache fresh after the warp
        for (uint256 i; i < users.length; i++) {
            vm.prank(users[i]);
            IxPNTsV2Admin(address(xpnts)).requestCredit(requestCap);
        }
    }

    function _one(address a) internal pure returns (address[] memory u) {
        u = new address[](1);
        u[0] = a;
    }

    function _getAPNTsBalance(address who) internal view returns (uint128 bal) {
        (bal,,,,,,,,) = sp.operators(who);
    }

    function _getIsConfigured(address who) internal view returns (bool configured) {
        (, configured,,,,,,,) = sp.operators(who);
    }

    function _getXPNTsToken(address who) internal view returns (address tok) {
        (,,,tok,,,,,) = sp.operators(who);
    }

    // ─── 1. configureOperator 2-arg signature ─────────────────────────────────

    function test_ConfigureOperator_NoExchangeRateParam_Configured() public view {
        assertTrue(_getIsConfigured(operator), "operator must be configured after 2-arg configureOperator");
    }

    function test_ConfigureOperator_StoredToken_Correct() public view {
        assertEq(_getXPNTsToken(operator), address(xpnts), "xPNTsToken address must be stored");
    }

    function test_ConfigureOperator_NoStoredExchangeRate_LiveRateUsed() public {
        // In v5.3.3+, no exchangeRate field in OperatorConfig.
        // Validate with a rate commitment and verify the live token rate is used.
        IxPNTsV2Admin(address(xpnts)).mint(user, 5_000 ether); // only the rate can fail below
        _setXPNTsRate(2e18);
        // maxRate = 1e18 < live rate 2e18 → validation fails
        vm.prank(address(ep));
        (, uint256 vd) = sp.validatePaymasterUserOp(_op(user, 1e18), bytes32(uint256(99)), MAX_COST);
        assertEq(vd & 1, 1, "validate must fail: live rate 2e18 > maxRate 1e18");
    }

    // ─── 2. getAvailableCredit = max(0, effectiveCreditCap - debts - reserved) ─

    /// @notice C-0: credit defaults OFF in v2 -> effectiveCreditCap == 0 -> no available credit,
    ///         even though the Registry tier (10_000 aPNTs) is non-zero.
    function test_GetAvailableCredit_PolicyOff_IsZero() public {
        assertGt(registry.getCreditLimit(user), 0, "tier is non-zero (control)");
        // D3-M: a current-epoch request is on file as well, so the OFF policy is the ONLY reason
        // the cap is 0 (without the OFF gate it would be min(request, CEILING, tier) > 0).
        vm.prank(user);
        IxPNTsV2Admin(address(xpnts)).requestCredit(20_000 ether);
        assertEq(xpnts.effectiveCreditCap(user), 0, "OFF -> cap 0");
        assertEq(sp.getAvailableCredit(user, address(xpnts)), 0, "OFF -> no available credit");
    }

    /// @notice AUTO + request above the tier: cap = min(requested, CEILING, tier) = tier.
    function test_GetAvailableCredit_NoDebt_EqualsCreditLimit() public {
        _enableAutoCredit(_one(user), 20_000 ether);
        uint256 credit = sp.getAvailableCredit(user, address(xpnts));
        uint256 limit  = registry.getCreditLimit(user);
        assertEq(xpnts.effectiveCreditCap(user), limit, "tier binds the effective cap");
        assertEq(credit, limit, "no debt: available credit must equal limit");
    }

    function test_GetAvailableCredit_AfterDebt_DecreasedByDebt() public {
        _enableAutoCredit(_one(user), 20_000 ether);
        uint256 limit = registry.getCreditLimit(user);

        bytes memory ctx = _runValidate(type(uint256).max);
        // in flight: the validation-time reservation already counts against the headroom
        assertEq(xpnts.creditReservedOf(user), A0, "reservation = a0");
        assertEq(sp.getAvailableCredit(user, address(xpnts)), limit - A0, "reserved counts (R4-H4)");

        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        uint256 debt   = xpnts.debts(user);
        uint256 credit = sp.getAvailableCredit(user, address(xpnts));
        assertEq(debt, CHARGE, "debt == charge");
        assertEq(xpnts.creditReservedOf(user), 0, "reservation consumed");
        assertEq(credit, limit - debt, "credit must equal limit minus aPNTs debt");
    }

    // ─── 3. postOp: credit path records charge in aPNTs ──────────────────────

    /// @notice CREDIT mode (user has no xPNTs, AUTO + request): debt is recorded in aPNTs,
    ///         independent of the xPNTs exchange rate (rate 2e18 here, debt still == CHARGE).
    function test_PostOp_DebtPath_RecordsAPNTs() public {
        assertEq(xpnts.balanceOf(user), 0); // no xPNTs → INSUFFICIENT → credit fallback
        _enableAutoCredit(_one(user), 20_000 ether);
        _setXPNTsRate(2e18);
        bytes memory ctx = _runValidate(type(uint256).max);

        vm.expectEmit(true, true, false, true, address(sp));
        emit ISuperPaymaster.TransactionSponsored(operator, user, A_GAS, CHARGE);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);
        assertEq(xpnts.debts(user), CHARGE, "debt must be recorded in aPNTs (not xPNTs)");
    }

    /// @notice R-2 / I3 / T-R14-06: with credit OFF (v2 default) an empty account is NOT
    ///         sponsored and no debt can arise. Replaces the removed 5.4 unconditional
    ///         debt fallback (_recordDebt).
    function test_PostOp_NoCreditPolicy_EmptyUser_NotSponsored() public {
        // D3-M: request on file + non-zero tier, so the OFF policy is the only thing that can
        // refuse the credit fallback (otherwise a missing request would mask it).
        vm.prank(user);
        IxPNTsV2Admin(address(xpnts)).requestCredit(20_000 ether);
        uint128 opBefore = _getAPNTsBalance(operator);
        vm.prank(address(ep));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(_op(user, type(uint256).max), bytes32(uint256(1)), MAX_COST);
        assertEq(vd & 1, 1, "credit OFF + no balance -> sigFail");
        assertEq(ctx.length, 0, "no context -> no postOp settlement");
        assertEq(xpnts.debts(user), 0, "no debt");
        assertEq(xpnts.creditReservedOf(user), 0, "no reservation (L-1)");
        assertEq(_getAPNTsBalance(operator), opBefore, "operator not debited");
    }

    // Debt is proportional to gas cost; doubling gas → doubles debt
    // Uses two separate users to avoid needing to reset state. Both reserve against a maxCost
    // large enough that neither charge hits the a0 cap, so the ratio is exact.
    function test_PostOp_DebtPath_ProportionalToGas() public {
        address user2 = address(0xF6);
        vm.prank(address(registry));
        sp.updateSBTStatus(user2, true);
        address[] memory us = new address[](2);
        us[0] = user; us[1] = user2;
        _enableAutoCredit(us, 20_000 ether);

        // user — 1x gas cost
        vm.prank(address(ep));
        (bytes memory ctx1,) = sp.validatePaymasterUserOp(_op(user, type(uint256).max), bytes32(uint256(1)), MAX_COST * 4);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, MAX_COST, 0);
        uint256 debt1 = xpnts.debts(user);

        // user2 — 2x gas cost (different opHash via different sender)
        vm.prank(address(ep));
        (bytes memory ctx2,) = sp.validatePaymasterUserOp(_op(user2, type(uint256).max), bytes32(uint256(10)), MAX_COST * 4);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx2, MAX_COST * 2, 0);
        uint256 debt2 = xpnts.debts(user2);

        assertEq(debt1, CHARGE, "1x gas -> 1.1e11");
        assertEq(debt2, 2 * debt1, "double gas cost must produce double aPNTs debt");
    }

    // ─── 4. postOp balance path at non-1:1 rate ─────────────────────────────

    function test_PostOp_BurnPath_HighRate_BurnsMoreXPNTs() public {
        _setXPNTsRate(2e18); // 1 aPNT = 2 xPNTs

        IxPNTsV2Admin(address(xpnts)).mint(user, 5_000 ether); // give user enough xPNTs (as FACTORY)

        uint256 balBefore = xpnts.balanceOf(user);
        uint256 revBefore = sp.protocolRevenue();
        bytes memory ctx = _runValidate(type(uint256).max);
        assertEq(xpnts.lockedOf(user), 2 * A0, "x0 = ceil(a0 * 2e18 / 1e18)");
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0);

        uint256 burned = balBefore - xpnts.balanceOf(user);
        uint256 charge = sp.protocolRevenue() - revBefore;
        uint256 debt   = xpnts.debts(user);

        assertEq(charge, CHARGE, "aPNTs charge");
        // xc = min(x0, ceil(c * x0 / a0)) = ceil(1.1e11 * 2.4e11 / 1.2e11) = 2.2e11
        assertEq(burned, 2 * charge, "burned xPNTs == 2x the aPNTs charge at rate 2e18");
        assertEq(debt, 0, "no debt when burn path succeeds");
        assertEq(xpnts.lockedOf(user), 0, "escrow cleared");
    }

    // ─── 5. Protocol fee: debtAPNTs increases with fee ────────────────────────

    // Compare 0% fee vs 10% fee for same gas cost using two fresh users.
    function test_PostOp_HigherFee_IncreasesDebt() public {
        address userA = address(0xFA);
        address userB = address(0xFB);
        vm.prank(address(registry)); sp.updateSBTStatus(userA, true);
        vm.prank(address(registry)); sp.updateSBTStatus(userB, true);
        address[] memory us = new address[](2);
        us[0] = userA; us[1] = userB;
        _enableAutoCredit(us, 20_000 ether);

        // userA: 0% fee
        vm.prank(owner);
        sp.setProtocolFee(0);

        vm.prank(address(ep));
        (bytes memory ctxA,) = sp.validatePaymasterUserOp(_op(userA, type(uint256).max), bytes32(uint256(30)), MAX_COST);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctxA, MAX_COST, 0);
        uint256 debtZeroFee = xpnts.debts(userA);

        // userB: 10% fee
        vm.prank(owner);
        sp.setProtocolFee(1000);

        vm.prank(address(ep));
        (bytes memory ctxB,) = sp.validatePaymasterUserOp(_op(userB, type(uint256).max), bytes32(uint256(31)), MAX_COST);
        vm.prank(address(ep));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctxB, MAX_COST, 0);
        uint256 debtTenPctFee = xpnts.debts(userB);

        assertEq(debtZeroFee, A_GAS, "0% fee: debt == aGas");
        assertEq(debtTenPctFee, CHARGE, "10% fee: debt == ceil(aGas * 1.1)");
        assertGt(debtTenPctFee, debtZeroFee, "10% fee must produce higher aPNTs debt than 0% fee");
    }

    // ─── 6. validatePaymasterUserOp uses live rate ───────────────────────────

    function test_Validate_LiveRate_Exceeds_MaxRate_Fails() public {
        IxPNTsV2Admin(address(xpnts)).mint(user, 5_000 ether); // only the rate can fail below
        _setXPNTsRate(2e18);
        vm.prank(address(ep));
        (, uint256 vd) = sp.validatePaymasterUserOp(_op(user, 1e18), bytes32(uint256(2)), MAX_COST); // maxRate too low
        assertEq(vd & 1, 1, "SIG_VALIDATION_FAILED when live rate > maxRate");
        assertEq(xpnts.lockedOf(user), 0, "nothing escrowed on a rate rejection");
    }

    function test_Validate_LiveRate_Within_MaxRate_Succeeds() public {
        IxPNTsV2Admin(address(xpnts)).mint(user, 5_000 ether);
        _setXPNTsRate(1e18);
        vm.prank(address(ep));
        (, uint256 vd) = sp.validatePaymasterUserOp(_op(user, 2e18), bytes32(uint256(3)), MAX_COST); // maxRate >= live rate
        assertEq(vd & 1, 0, "validation must succeed when live rate <= maxRate");
        assertEq(xpnts.lockedOf(user), A0, "balance mode: x0 escrowed at 1:1");
    }

    // ─── 7. Deposit/withdraw accounting ─────────────────────────────────────

    function test_Deposit_IncreasesAPNTsBalance() public {
        uint128 before = _getAPNTsBalance(operator);
        vm.prank(operator);
        sp.deposit(1_000 ether);
        assertEq(_getAPNTsBalance(operator) - before, 1_000 ether, "deposit must increase aPNTsBalance");
    }

    function test_Withdraw_DecreasesAPNTsBalance() public {
        uint128 before = _getAPNTsBalance(operator);
        vm.prank(operator);
        sp.withdraw(500 ether);
        assertEq(before - _getAPNTsBalance(operator), 500 ether, "withdraw must decrease aPNTsBalance");
    }
}

// ─── Minimal mocks ────────────────────────────────────────────────────────────

contract SPMockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32) {
        return keccak256(abi.encode(op, block.chainid));
    }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function getDepositInfo(address) external pure returns (DepositInfo memory) {}
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract SPMockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract SPMockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract SPMockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) private _roles;

    function hasRole(bytes32 role, address account) external view returns (bool) { return _roles[role][account]; }
    function setRole(bytes32 role, address account, bool val) external { _roles[role][account] = val; }
    function getCreditLimit(address) external pure returns (uint256) { return 10_000 ether; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function markProposalExecuted(uint256) external override {}
    function registerRole(bytes32, address, bytes calldata) external {}
    function exitRole(bytes32) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function setStaking(address) external {}
    function setMySBT(address) external {}
    function setSuperPaymaster(address) external {}
    function queueBLSAggregator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external view returns (uint256) { return 0; }
    function version() external pure returns (string memory) { return "Mock"; }
    function isReputationSource(address) external view returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}
