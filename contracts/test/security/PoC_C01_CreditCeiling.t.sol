// C01 — Credit ceiling regression, migrated to SuperPaymaster 5.5.0 + xPNTs v2.
// Legacy: validatePaymasterUserOp had to enforce getCreditLimit before a zero-balance user could
// accumulate debt through postOp. 5.5.0 closes the same risk (and its same-bundle / ceiling
// overrun form, R1-4 / N-C1) structurally: debt can only come from consuming a CREDIT
// reservation that was admitted at validation under C-1
//     debts + creditReservedOf + a0 <= effectiveCreditCap(user)
// so the k-th op of a bundle that would overrun the ceiling is rejected at ITS validation.
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {IxPNTsTokenV2} from "src/tokens/v2/IxPNTsTokenV2.sol";

contract C01Registry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(address => uint256) public creditLimits;

    function setRole(bytes32 role, address account, bool value) external {
        roles[role][account] = value;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function setCreditLimit(address user, uint256 limit) external {
        creditLimits[user] = limit;
    }

    /// @dev GLOBAL tier (GlobalTierSource.tierOf -> Registry.getCreditLimit).
    function getCreditLimit(address user) external view returns (uint256) {
        return creditLimits[user];
    }
}

contract C01EntryPoint {}

contract C01PriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract C01APNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoC_C01_CreditCeiling_Test is Test {
    SuperPaymaster public paymaster;
    C01Registry public registry;
    C01EntryPoint public entryPoint;
    C01APNTs public apnts;
    xPNTsTokenV2 public xpnts;
    MockXPNTsFactory public mockFactory;

    address public owner = address(0xC0101);
    address public treasury = address(0xC0102);
    address public operator = address(0xC0103);
    address public user = address(0xC0104);

    bytes32 public constant C01_ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant C01_ROLE_COMMUNITY = keccak256("COMMUNITY");
    uint256 public constant MAX_COST = 1_000;
    uint8 internal constant MODE_CREDIT = 2;

    function setUp() public {
        vm.startPrank(owner);

        registry = new C01Registry();
        entryPoint = new C01EntryPoint();
        apnts = new C01APNTs();
        C01PriceFeed priceFeed = new C01PriceFeed();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();
        vm.stopPrank();

        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpnts = V2TokenDeployer.newToken(st, owner, operator, address(paymaster), 1e18);

        vm.startPrank(owner);
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator, address(xpnts));

        registry.setRole(C01_ROLE_PAYMASTER_SUPER, operator, true);
        registry.setRole(C01_ROLE_COMMUNITY, operator, true);
        registry.setCreditLimit(user, 0);

        apnts.mint(operator, 10_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);

        vm.startPrank(operator);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), treasury);
        paymaster.deposit(1_000 ether);
        vm.stopPrank();

        assertEq(xpnts.balanceOf(user), 0, "setup: user must have no xPNTs");
        assertEq(registry.getCreditLimit(user), 0, "setup: user credit ceiling must be zero");
        assertEq(xpnts.creditPolicy(), 0, "setup: v2 credit defaults OFF");
    }

    // ------------------------------------------------------------------
    // Legacy C01 scenario (migrated): zero-credit, zero-balance user.
    // ------------------------------------------------------------------

    function test_PoC_validateDoesNotEnforceCreditCeiling() public {
        uint128 operatorBefore = _operatorBalance();

        (, uint256 validationData) = _validate(bytes32("c01"));

        uint256 debt = xpnts.debts(user);
        uint256 creditLimit = registry.getCreditLimit(user);

        assertEq(uint160(validationData), 1, "zero-credit zero-balance user must be rejected");
        assertLe(debt, creditLimit, "debt must not exceed credit ceiling");
        assertEq(_operatorBalance(), operatorBefore, "operator balance must not be debited");
        assertEq(xpnts.creditReservedOf(user), 0, "no reservation written on the failure path (L-1)");
        (address f,) = paymaster.inflightOf(bytes32("c01"));
        assertEq(f, address(0), "no in-flight sponsorship for a rejected op");
    }

    /// @notice Same zero ceiling, but with credit switched ON (AUTO) and a user request on file:
    ///         the GLOBAL tier (Registry.getCreditLimit == 0) still caps effectiveCreditCap at 0.
    function test_C01_autoPolicy_zeroTier_rejected() public {
        _enableAutoCredit(1_000 ether);
        registry.setCreditLimit(user, 0);
        assertEq(xpnts.effectiveCreditCap(user), 0, "C-0: tier 0 -> cap 0");
        uint128 operatorBefore = _operatorBalance();

        (, uint256 validationData) = _validate(bytes32("c01-auto-0"));

        assertEq(uint160(validationData), 1, "AUTO with a zero tier must still reject");
        assertEq(xpnts.creditReservedOf(user), 0, "no reservation");
        assertEq(xpnts.debts(user), 0, "no debt");
        assertEq(_operatorBalance(), operatorBefore, "operator not debited");
    }

    /// @notice Positive control: inside the ceiling the op IS sponsored, on credit, and the
    ///         reservation equals the validation-time a0 (spec §10.3).
    function test_C01_withinCeiling_reservesA0_atValidation() public {
        _enableAutoCredit(1_000 ether);
        uint256 a0 = _expectedA0(MAX_COST);
        uint128 operatorBefore = _operatorBalance();

        (bytes memory ctx, uint256 vd) = _validate(bytes32("c01-ok"));
        assertEq(uint160(vd), 0, "within ceiling -> sponsored");
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        assertEq(c.mode, MODE_CREDIT, "mode CREDIT (no balance)");
        assertEq(c.a0, a0, "a0 matches spec 10.3");
        assertEq(xpnts.creditReservedOf(user), a0, "validation-time reservation == a0");
        assertEq(uint256(operatorBefore) - _operatorBalance(), a0, "operator a0 in flight");
        (address f, uint256 inflightA0) = paymaster.inflightOf(bytes32("c01-ok"));
        assertEq(f, operator);
        assertEq(inflightA0, a0);
    }

    // ------------------------------------------------------------------
    // T-R14-08 / C-1: N credit ops of one user in one bundle overrun the ceiling
    // ------------------------------------------------------------------

    /// @notice All validations below run in ONE transaction (one bundle): the per-op live
    ///         markers stay set, so reservations accumulate exactly as in handleOps. With a
    ///         ceiling of 2.5 x a0 the 3rd reservation must be rejected at its own validation.
    function test_C01_sameBundle_kthReservationRejected() public {
        uint256 a0 = _expectedA0(MAX_COST);
        _enableAutoCredit(1_000 ether);
        uint256 cap = 2 * a0 + a0 / 2;
        registry.setCreditLimit(user, cap);
        assertEq(xpnts.effectiveCreditCap(user), cap, "cap == tier (below request & ceiling)");
        uint128 operatorBefore = _operatorBalance();

        (, uint256 vd1) = _validate(keccak256("op1"));
        (, uint256 vd2) = _validate(keccak256("op2"));
        (bytes memory ctx3, uint256 vd3) = _validate(keccak256("op3"));

        assertEq(uint160(vd1), 0, "op1 admitted");
        assertEq(uint160(vd2), 0, "op2 admitted");
        assertEq(uint160(vd3), 1, "op3 (k-th) rejected: debts + reserved + a0 > cap");
        assertEq(ctx3.length, 0, "no context for the rejected op");

        assertEq(xpnts.creditReservedOf(user), 2 * a0, "only the admitted reservations are held");
        assertLe(xpnts.debts(user) + xpnts.creditReservedOf(user), cap, "C-1 invariant holds");
        assertEq(uint256(operatorBefore) - _operatorBalance(), 2 * a0, "operator debited only for admitted ops");
        assertEq(paymaster.getAvailableCredit(user, address(xpnts)), cap - 2 * a0, "SP view = cap - debts - reserved");
        (address f3,) = paymaster.inflightOf(keccak256("op3"));
        assertEq(f3, address(0), "rejected op holds no in-flight a0");
    }

    /// @notice Settled debt counts against the ceiling: after op1 settles (debt c1), the next
    ///         reservation is admitted at cap == debts + a0 and rejected at cap == debts + a0 - 1.
    function test_C01_settledDebtCountsAgainstCeiling_exactBoundary() public {
        uint256 a0 = _expectedA0(MAX_COST);
        _enableAutoCredit(1_000 ether);
        registry.setCreditLimit(user, 1_000 ether);

        (bytes memory ctx1, uint256 vd1) = _validate(keccak256("s1"));
        assertEq(uint160(vd1), 0, "op1 admitted");
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx1, MAX_COST, 0);
        uint256 debt1 = xpnts.debts(user);
        assertGt(debt1, 0, "op1 settled as debt");
        assertLe(debt1, a0, "C-2: debt <= admitted reservation");
        assertEq(xpnts.creditReservedOf(user), 0, "reservation consumed");

        // one below the boundary -> rejected
        registry.setCreditLimit(user, debt1 + a0 - 1);
        (, uint256 vdLow) = _validate(keccak256("s2"));
        assertEq(uint160(vdLow), 1, "debts + a0 > cap -> rejected");
        assertEq(xpnts.creditReservedOf(user), 0, "no reservation on failure");

        // exactly at the boundary -> admitted
        registry.setCreditLimit(user, debt1 + a0);
        (, uint256 vdEq) = _validate(keccak256("s3"));
        assertEq(uint160(vdEq), 0, "debts + a0 == cap -> admitted");
        assertEq(xpnts.debts(user) + xpnts.creditReservedOf(user), debt1 + a0, "exposure == cap, never above");
    }

    /// @notice I3: debt only grows by consuming an admitted reservation; N settled ops never push
    ///         debts above the ceiling that admitted them.
    function test_C01_sameBundle_settledDebtNeverExceedsCeiling() public {
        uint256 a0 = _expectedA0(MAX_COST);
        _enableAutoCredit(1_000 ether);
        uint256 cap = 3 * a0;
        registry.setCreditLimit(user, cap);

        bytes[] memory ctxs = new bytes[](5);
        uint256 admitted;
        for (uint256 i = 0; i < 5; i++) {
            (bytes memory ctx, uint256 vd) = _validate(keccak256(abi.encode("b", i)));
            if (uint160(vd) == 0) ctxs[admitted++] = ctx;
        }
        assertEq(admitted, 3, "exactly floor(cap / a0) ops admitted");
        for (uint256 i = 0; i < admitted; i++) {
            vm.prank(address(entryPoint));
            paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctxs[i], MAX_COST * 10, 0);
        }
        assertEq(xpnts.creditReservedOf(user), 0, "all reservations consumed");
        assertLe(xpnts.debts(user), cap, "settled debt never exceeds the admitting ceiling");
        assertEq(xpnts.debts(user), admitted * a0, "actual > maxCost: each charge capped at its a0");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _enableAutoCredit(uint256 requestCap) internal {
        vm.prank(owner); // communityOwner
        IxPNTsV2Admin(address(xpnts)).queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        IxPNTsV2Admin(address(xpnts)).executeCreditPolicy();
        paymaster.updatePrice(); // refresh price cache after the 48 h warp
        vm.prank(user);
        IxPNTsV2Admin(address(xpnts)).requestCredit(requestCap);
        registry.setCreditLimit(user, requestCap);
    }

    function _validate(bytes32 opHash) internal returns (bytes memory ctx, uint256 validationData) {
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = _paymasterData();
        vm.prank(address(paymaster.entryPoint()));
        (ctx, validationData) = paymaster.validatePaymasterUserOp(op, opHash, MAX_COST);
    }

    /// @dev Spec §10.3: a0 = ceil(ceil(maxCost * price * 1e18 / (10^dec * aPNTsPriceUSD)) * (BPS + fee + 10%) / BPS)
    function _expectedA0(uint256 maxCost) internal view returns (uint256) {
        (int256 price,,, uint8 dec) = paymaster.cachedPrice();
        uint256 aGas = Math.mulDiv(maxCost * uint256(price), 1e18, (10 ** uint256(dec)) * paymaster.aPNTsPriceUSD(), Math.Rounding.Ceil);
        return Math.mulDiv(aGas, 10_000 + paymaster.protocolFeeBPS() + 1_000, 10_000, Math.Rounding.Ceil);
    }

    function _paymasterData() internal view returns (bytes memory) {
        return V2TokenDeployer.pmd(address(paymaster), uint128(100000), uint128(200000), operator, type(uint256).max, address(xpnts), 0);
    }

    function _operatorBalance() internal view returns (uint128 balance) {
        (balance,,,,,,,,) = paymaster.operators(operator);
    }
}
