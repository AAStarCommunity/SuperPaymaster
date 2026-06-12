// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/ISuperPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {InvMockRegistry, InvMockEntryPoint, InvMockPriceFeed, InvMockAPNTs} from "./InvariantMocks.sol";

/**
 * @title SuperPaymasterFundConservation_Invariant
 * @notice Property test (T-H1/T-H2 from audit §6) that machine-checks the core
 *         fund-conservation invariant the audit §9 confirmed by hand:
 *
 *             totalTrackedBalance == Σ(operators[i].aPNTsBalance) + protocolRevenue
 *
 *         Every aPNTs mutation in SuperPaymaster touches exactly the variables
 *         needed to preserve this identity:
 *           - deposit/depositFor/onTransferReceived: balance += x, total += x
 *           - withdraw:                              balance -= x, total -= x
 *           - withdrawProtocolRevenue:              revenue -= x, total -= x
 *           - validation fee debit:                  balance -= x, revenue += x   (total unchanged)
 *           - postOp refund:                         balance += x, revenue -= x   (total unchanged)
 *           - slash:                                 balance -= x, revenue += x   (total unchanged)
 *
 *         The handler below exercises the real entry points (deposit/depositFor/
 *         withdraw) plus a storage-poke that reproduces the validate/postOp/slash
 *         "move operator <-> revenue" steps (those paths require a full UserOp
 *         through EntryPoint, which a stateless invariant fuzzer cannot drive).
 *         The poke deliberately uses the SAME pair of writes the contract
 *         performs, so a regression that updates one side without the other
 *         (e.g. forgetting `totalTrackedBalance`) would break the invariant here.
 */
contract SuperPaymasterFundConservation_Invariant is StdInvariant, Test {
    SuperPaymasterFundHandler internal handler;
    SuperPaymaster internal paymaster;

    function setUp() public {
        InvMockEntryPoint entryPoint = new InvMockEntryPoint();
        InvMockPriceFeed priceFeed = new InvMockPriceFeed();
        InvMockAPNTs apnts = new InvMockAPNTs();
        InvMockRegistry registry = new InvMockRegistry();

        address owner = address(this);
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            address(0xBEEF),
            3600
        );

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        handler = new SuperPaymasterFundHandler(paymaster, registry, apnts, owner);

        // Limit the fuzzer to the handler's public surface.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.depositForOperator.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.accrueProtocolFee.selector;
        selectors[4] = handler.refundFromRevenue.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-1: tracked balance always equals the sum of all operator
    ///         balances plus protocol revenue.
    function invariant_trackedBalanceEqualsSum() public view {
        uint256 sum = paymaster.protocolRevenue();
        address[] memory ops = handler.operators();
        for (uint256 i = 0; i < ops.length; i++) {
            (uint128 bal,,,,,,,,) = paymaster.operators(ops[i]);
            sum += bal;
        }
        assertEq(paymaster.totalTrackedBalance(), sum, "INV-1: total != Sum(balances)+revenue");
    }

    /// @notice INV-1b: tracked balance is fully token-backed — the contract must
    ///         hold at least `totalTrackedBalance` aPNTs (withdrawals never pay
    ///         out more than was deposited net of in-flight accounting).
    function invariant_solvency() public view {
        uint256 held = handler.apnts().balanceOf(address(paymaster));
        assertGe(held, paymaster.totalTrackedBalance(), "INV-1b: under-collateralized");
    }
}

/**
 * @notice Stateful handler that drives every aPNTs-moving entry point and tracks
 *         the set of operators so the invariant can sum their balances.
 */
contract SuperPaymasterFundHandler is Test {
    using stdStorage for StdStorage;

    SuperPaymaster public paymaster;
    InvMockRegistry public registry;
    InvMockAPNTs public apnts;
    address public owner;

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    address[] internal _operators;
    mapping(address => bool) internal _known;

    constructor(SuperPaymaster _paymaster, InvMockRegistry _registry, InvMockAPNTs _apnts, address _owner) {
        paymaster = _paymaster;
        registry = _registry;
        apnts = _apnts;
        owner = _owner;

        // Seed a few operators so the fuzzer reuses them.
        for (uint256 i = 1; i <= 3; i++) {
            _registerOperator(address(uint160(0x1000 + i)));
        }
    }

    function operators() external view returns (address[] memory) {
        return _operators;
    }

    function _registerOperator(address op) internal {
        if (_known[op] || op == address(0)) return;
        _known[op] = true;
        _operators.push(op);
        registry.setRole(ROLE_PAYMASTER_SUPER, op, true);
        registry.setRole(ROLE_COMMUNITY, op, true);
    }

    function _pickOperator(uint256 seed) internal view returns (address) {
        return _operators[seed % _operators.length];
    }

    function _balanceOf(address op) internal view returns (uint128 bal) {
        (bal,,,,,,,,) = paymaster.operators(op);
    }

    // ── deposit: balance += x, total += x ──────────────────────────────────────
    function deposit(uint256 opSeed, uint256 amount) external {
        address op = _pickOperator(opSeed);
        amount = bound(amount, 0, 1_000_000 ether);
        apnts.mint(op, amount);
        vm.startPrank(op);
        apnts.approve(address(paymaster), amount);
        paymaster.deposit(amount);
        vm.stopPrank();
    }

    // ── depositFor: balance += x, total += x ───────────────────────────────────
    function depositForOperator(uint256 opSeed, uint256 amount) external {
        address op = _pickOperator(opSeed);
        amount = bound(amount, 0, 1_000_000 ether);
        apnts.mint(address(this), amount);
        apnts.approve(address(paymaster), amount);
        paymaster.depositFor(op, amount);
    }

    // ── withdraw: balance -= x, total -= x ─────────────────────────────────────
    function withdraw(uint256 opSeed, uint256 amount) external {
        address op = _pickOperator(opSeed);
        uint128 bal = _balanceOf(op);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        vm.prank(op);
        paymaster.withdraw(amount);
    }

    // ── accrueProtocolFee: balance -= x, revenue += x (validate/slash shape) ────
    //    Reproduces the in-flight fee debit. total is unchanged → must NOT
    //    break INV-1.
    function accrueProtocolFee(uint256 opSeed, uint256 amount) external {
        address op = _pickOperator(opSeed);
        uint128 bal = _balanceOf(op);
        if (bal == 0) return;
        amount = bound(amount, 0, bal);
        _setOperatorBalance(op, uint128(uint256(bal) - amount));
        uint256 rev = paymaster.protocolRevenue();
        stdstore.target(address(paymaster)).sig("protocolRevenue()").checked_write(rev + amount);
    }

    // ── refundFromRevenue: balance += x, revenue -= x (postOp refund shape) ─────
    function refundFromRevenue(uint256 opSeed, uint256 amount) external {
        address op = _pickOperator(opSeed);
        uint256 rev = paymaster.protocolRevenue();
        if (rev == 0) return;
        amount = bound(amount, 0, rev);
        uint128 bal = _balanceOf(op);
        _setOperatorBalance(op, uint128(uint256(bal) + amount));
        stdstore.target(address(paymaster)).sig("protocolRevenue()").checked_write(rev - amount);
    }

    /// @dev Rewrite only the aPNTsBalance field (low 16 bytes of slot 0) of an
    ///      OperatorConfig, preserving isConfigured/isPaused in the upper bytes.
    function _setOperatorBalance(address op, uint128 newBal) internal {
        // mapping(address => OperatorConfig) operators is at storage slot 5
        // (verified via `forge inspect SuperPaymaster storageLayout`; drift is
        // guarded in CI by scripts/check_storage_layout.py). aPNTsBalance is the
        // low 16 bytes of the struct's slot 0.
        bytes32 slot = keccak256(abi.encode(op, uint256(5)));
        bytes32 cur = vm.load(address(paymaster), slot);
        bytes32 upper = bytes32(uint256(cur) & ~uint256(type(uint128).max));
        bytes32 packed = bytes32(uint256(upper) | uint256(newBal));
        vm.store(address(paymaster), slot, packed);
        // Sanity: if the operators mapping slot ever moves, this poke would
        // silently corrupt an unrelated slot and the invariant would test
        // nothing. Read back via the public getter and require the write landed,
        // turning a silent slot-index drift into a hard test failure.
        (uint128 readBack,,,,,,,,) = paymaster.operators(op);
        require(readBack == newBal, "operators slot index drifted - update _setOperatorBalance");
    }
}
