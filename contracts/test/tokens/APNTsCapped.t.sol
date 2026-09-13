// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { APNTsCapped } from "src/tokens/APNTsCapped.sol";
import { IERC1363Receiver } from "src/interfaces/IERC1363.sol";
import { TimelockController } from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";

// Unit tests only. This file deliberately imports nothing that reaches Registry.sol, so it is
// compiled under profile.default (runs 500) — the same APNTsCapped build that DeployAPNTsCapped
// ships. The SuperPaymaster integration lives in APNTsCappedSPIntegration.t.sol.

/// @dev ERC-1363 receiver stub with a configurable answer.
contract APNTsReceiverStub is IERC1363Receiver {
    uint8 public mode; // 0 = accept, 1 = wrong selector, 2 = revert
    address public lastOperator;
    address public lastFrom;
    uint256 public lastValue;
    bytes public lastData;

    error StubRejects();

    function setMode(uint8 m) external { mode = m; }

    function onTransferReceived(address operator, address from, uint256 value, bytes calldata data)
        external returns (bytes4)
    {
        if (mode == 2) revert StubRejects();
        lastOperator = operator;
        lastFrom = from;
        lastValue = value;
        lastData = data;
        return mode == 1 ? bytes4(0xdeadbeef) : IERC1363Receiver.onTransferReceived.selector;
    }
}

/**
 * @title APNTsCappedTest — GOV-4 (b) unit tests (apnts-capped-design.md §3: cap / raise / lower /
 *        roles / Ownable2Step), owner = a REAL OZ TimelockController with a 48h delay whose
 *        proposer/canceller/executor is the governance multisig.
 */
contract APNTsCappedTest is Test {
    uint256 constant DELAY = 48 hours;
    uint256 constant CAP = 1_000_000 ether;
    address constant MULTISIG = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;

    // Roles are held by DISTINCT addresses here so every role check is separable
    // (production gives minter and capGuardian to the same multisig).
    address minter = makeAddr("minter");
    address guardian = makeAddr("guardian");
    address alice = makeAddr("alice");
    address rando = makeAddr("rando");
    address deployer; // == address(this)

    TimelockController timelock;
    APNTsCapped token;

    bytes32 constant SALT = keccak256("APNTsCappedTest");

    function setUp() public {
        deployer = address(this);
        address[] memory ms = new address[](1);
        ms[0] = MULTISIG;
        timelock = new TimelockController(DELAY, ms, ms, address(0));
        token = new APNTsCapped("AAStar PNTs", "aPNTs", CAP, deployer, minter, guardian);
        // Ownable2Step handover exactly as the deploy script does it.
        token.transferOwnership(address(timelock));
        _timelockCall(abi.encodeWithSelector(token.acceptOwnership.selector));
        assertEq(token.owner(), address(timelock), "setUp: timelock owns the token");
        assertEq(token.pendingOwner(), address(0), "setUp: no pending owner");
    }

    // ---------------- helpers ----------------

    function _schedule(bytes memory data) internal {
        vm.prank(MULTISIG);
        timelock.schedule(address(token), 0, data, bytes32(0), SALT, DELAY);
    }

    function _execute(bytes memory data) internal {
        vm.prank(MULTISIG);
        timelock.execute(address(token), 0, data, bytes32(0), SALT);
    }

    /// @dev schedule -> wait 48h -> execute (a full governance round).
    function _timelockCall(bytes memory data) internal {
        _schedule(data);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _execute(data);
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    /// @dev Named negative check: `caller` calling `data` on the token must fail with exactly
    ///      `expected` revert data. Used by the mutation-gated assertions so a surviving mutant
    ///      reports THIS name, not a generic "call did not revert".
    function _mustRevert(address caller, bytes memory data, bytes memory expected, string memory name) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, name);
        assertEq(ret, expected, string.concat(name, " [revert data]"));
    }

    // ================= deployment / views =================

    function test_views_and_version() public view {
        assertEq(token.name(), "AAStar PNTs");
        assertEq(token.symbol(), "aPNTs");
        assertEq(token.decimals(), 18);
        assertEq(token.version(), "APNTsCapped-1.0.0");
        assertEq(token.cap(), CAP);
        assertEq(token.issuanceCap(), CAP, "issuanceCap() == cap");
        assertEq(token.minter(), minter);
        assertEq(token.capGuardian(), guardian);
        assertEq(token.totalSupply(), 0);
        assertFalse(token.isOverIssued());
    }

    function test_constructor_rejects_zero_cap_and_zero_roles() public {
        vm.expectRevert(APNTsCapped.ZeroCap.selector);
        new APNTsCapped("a", "a", 0, deployer, minter, guardian);
        vm.expectRevert(APNTsCapped.ZeroAddress.selector);
        new APNTsCapped("a", "a", CAP, deployer, address(0), guardian);
        vm.expectRevert(APNTsCapped.ZeroAddress.selector);
        new APNTsCapped("a", "a", CAP, deployer, minter, address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new APNTsCapped("a", "a", CAP, address(0), minter, guardian);
    }

    // ================= cap =================

    function test_cap_mint_exactly_cap_succeeds() public {
        _mint(alice, CAP);
        assertEq(token.totalSupply(), CAP, "cap: mint up to exactly cap succeeds");
        assertEq(token.balanceOf(alice), CAP);
    }

    function test_cap_mint_one_wei_over_reverts() public {
        _mint(alice, CAP - 5);
        _mustRevert(minter, abi.encodeCall(APNTsCapped.mint, (alice, 6)), // lands at CAP + 1
            abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, CAP - 5, 6, CAP),
            "CAP-1: mint to cap + 1 wei is rejected with CapExceeded");
        assertEq(token.totalSupply(), CAP - 5, "CAP-1: supply unchanged by the rejected mint");
        _mint(alice, 5); // positive control: exactly up to cap still works
        assertEq(token.totalSupply(), CAP);
    }

    function test_cap_single_mint_one_wei_over_reverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, 0, CAP + 1, CAP));
        token.mint(alice, CAP + 1);
    }

    function test_cap_huge_amount_reverts_without_overflow() public {
        _mint(alice, 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, 1, type(uint256).max, CAP));
        token.mint(alice, type(uint256).max);
    }

    function test_cap_burn_frees_room() public {
        _mint(alice, CAP);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, CAP, 1, CAP));
        token.mint(alice, 1);

        vm.prank(alice);
        token.burn(100 ether);
        assertEq(token.totalSupply(), CAP - 100 ether);
        _mint(rando, 100 ether);
        assertEq(token.totalSupply(), CAP, "burn frees exactly the burned room");
    }

    function test_mint_emits_Minted() public {
        _mint(alice, 10 ether);
        vm.expectEmit(true, false, false, true, address(token));
        emit APNTsCapped.Minted(alice, 5 ether, 15 ether, CAP);
        _mint(alice, 5 ether);
    }

    function testFuzz_supply_never_exceeds_cap(uint256 a, uint256 b, uint256 burnAmt) public {
        a = bound(a, 0, CAP);
        _mint(alice, a);
        burnAmt = bound(burnAmt, 0, a);
        vm.prank(alice);
        token.burn(burnAmt);
        uint256 supply = token.totalSupply();
        vm.prank(minter);
        if (b > CAP - supply) {
            vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, supply, b, CAP));
            token.mint(alice, b);
        } else {
            token.mint(alice, b);
        }
        assertLe(token.totalSupply(), token.cap(), "fuzz: totalSupply <= cap");
    }

    // ================= raiseCap =================

    function test_raiseCap_non_owner_reverts() public {
        address[5] memory callers = [deployer, MULTISIG, guardian, minter, rando];
        for (uint256 i; i < callers.length; i++) {
            _mustRevert(callers[i], abi.encodeCall(APNTsCapped.raiseCap, (CAP * 2)),
                abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]),
                "RAISE-1: raiseCap by a non-owner (deployer/multisig/guardian/minter/other) is rejected");
        }
        assertEq(token.cap(), CAP, "RAISE-1: cap unchanged");
        vm.prank(address(timelock)); // positive control: the owner can
        token.raiseCap(CAP * 2);
        assertEq(token.cap(), CAP * 2);
    }

    function test_raiseCap_timelock_48h() public {
        bytes memory data = abi.encodeCall(APNTsCapped.raiseCap, (CAP * 2));
        _schedule(data);

        // Before the delay: execution reverts (OZ TimelockUnexpectedOperationState).
        vm.warp(vm.getBlockTimestamp() + DELAY - 1);
        bytes32 id = timelock.hashOperation(address(token), 0, data, bytes32(0), SALT);
        vm.prank(MULTISIG);
        (bool ok, bytes memory ret) = address(timelock).call(
            abi.encodeCall(TimelockController.execute, (address(token), 0, data, bytes32(0), SALT)));
        assertFalse(ok, "RAISE-2: timelock execution 1 s before 48h reverts");
        assertEq(ret, abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector,
            id, bytes32(1 << uint8(TimelockController.OperationState.Ready))), "RAISE-2: reverts because not Ready");
        assertEq(token.cap(), CAP, "RAISE-2: cap unchanged before 48h");

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(false, false, false, true, address(token));
        emit APNTsCapped.CapRaised(CAP, CAP * 2);
        _execute(data);
        assertEq(token.cap(), CAP * 2, "raiseCap via timelock after 48h takes effect");
        _mint(alice, CAP + 1); // the new room is usable
    }

    function test_raiseCap_only_multisig_can_propose() public {
        bytes memory data = abi.encodeCall(APNTsCapped.raiseCap, (CAP * 2));
        vm.prank(rando);
        vm.expectRevert(); // AccessControlUnauthorizedAccount(rando, PROPOSER_ROLE)
        timelock.schedule(address(token), 0, data, bytes32(0), SALT, DELAY);
        vm.prank(MULTISIG);
        vm.expectRevert(); // TimelockInsufficientDelay
        timelock.schedule(address(token), 0, data, bytes32(0), SALT, DELAY - 1);
    }

    function test_raiseCap_not_above_reverts() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapNotRaised.selector, CAP, CAP));
        token.raiseCap(CAP);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapNotRaised.selector, CAP, CAP - 1));
        token.raiseCap(CAP - 1);
        assertEq(token.cap(), CAP, "raiseCap: newCap <= cap is rejected");
    }

    function test_raiseCap_through_timelock_rejects_lower_value() public {
        bytes memory data = abi.encodeCall(APNTsCapped.raiseCap, (CAP - 1));
        _schedule(data);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.prank(MULTISIG);
        vm.expectRevert(); // TimelockController bubbles CapNotRaised
        timelock.execute(address(token), 0, data, bytes32(0), SALT);
        assertEq(token.cap(), CAP);
    }

    // ================= lowerCap =================

    function test_lowerCap_guardian_immediate() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit APNTsCapped.CapLowered(CAP, CAP / 2, guardian);
        vm.prank(guardian);
        token.lowerCap(CAP / 2);
        assertEq(token.cap(), CAP / 2, "lowerCap: guardian lowers immediately (same block)");
    }

    function test_lowerCap_owner_via_timelock() public {
        _timelockCall(abi.encodeCall(APNTsCapped.lowerCap, (CAP / 4)));
        assertEq(token.cap(), CAP / 4, "lowerCap: owner may lower too");
    }

    function test_lowerCap_non_guardian_reverts() public {
        address[4] memory callers = [deployer, MULTISIG, minter, rando];
        for (uint256 i; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(APNTsCapped.NotCapGuardian.selector, callers[i]));
            token.lowerCap(CAP / 2);
        }
        assertEq(token.cap(), CAP, "lowerCap: non-guardian, non-owner rejected");
    }

    function test_lowerCap_not_below_reverts() public {
        _mustRevert(guardian, abi.encodeCall(APNTsCapped.lowerCap, (CAP + 1)),
            abi.encodeWithSelector(APNTsCapped.CapNotLowered.selector, CAP, CAP + 1),
            "LOWER-1: lowerCap cannot RAISE the cap (guardian, newCap > cap)");
        _mustRevert(address(timelock), abi.encodeCall(APNTsCapped.lowerCap, (CAP * 10)),
            abi.encodeWithSelector(APNTsCapped.CapNotLowered.selector, CAP, CAP * 10),
            "LOWER-1: lowerCap cannot RAISE the cap (owner, bypassing the timelock delay)");
        _mustRevert(guardian, abi.encodeCall(APNTsCapped.lowerCap, (CAP)),
            abi.encodeWithSelector(APNTsCapped.CapNotLowered.selector, CAP, CAP),
            "LOWER-2: lowerCap with newCap == cap is rejected");
        assertEq(token.cap(), CAP, "LOWER-1: cap unchanged");
        vm.prank(guardian); // positive control: a real lowering works
        token.lowerCap(CAP - 1);
        assertEq(token.cap(), CAP - 1);
    }

    function test_lowerCap_below_supply_blocks_mint_and_flags_overissued() public {
        _mint(alice, 500 ether);
        assertFalse(token.isOverIssued());
        vm.prank(guardian);
        token.lowerCap(100 ether);
        assertTrue(token.isOverIssued(), "isOverIssued: true after lowering below supply");
        assertEq(token.issuanceCap(), 100 ether);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, 500 ether, 1, 100 ether));
        token.mint(alice, 1);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, 500 ether, 0 + 100 ether, 100 ether));
        token.mint(alice, 100 ether);

        // existing balances untouched and still transferable
        vm.prank(alice);
        token.transfer(rando, 1 ether);
        assertEq(token.balanceOf(alice), 499 ether);

        // lowering to 0 is allowed and freezes minting entirely
        vm.prank(guardian);
        token.lowerCap(0);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, 500 ether, 1, 0));
        token.mint(alice, 1);
    }

    // ================= minter =================

    function test_only_minter_mints() public {
        address[5] memory callers = [address(timelock), guardian, deployer, MULTISIG, rando];
        string[5] memory who = ["owner (timelock)", "capGuardian", "deployer", "multisig (not minter here)", "other"];
        for (uint256 i; i < callers.length; i++) {
            _mustRevert(callers[i], abi.encodeCall(APNTsCapped.mint, (callers[i], 1)),
                abi.encodeWithSelector(APNTsCapped.NotMinter.selector, callers[i]),
                string.concat("MINT-1: mint by a non-minter is rejected: ", who[i]));
        }
        assertEq(token.totalSupply(), 0, "MINT-1: nothing minted by non-minters");
        _mint(alice, 1); // positive control: the minter can
        assertEq(token.totalSupply(), 1);
    }

    function test_setMinter_and_setCapGuardian_owner_only() public {
        address m2 = makeAddr("m2");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        token.setMinter(m2);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        token.setCapGuardian(rando);

        vm.prank(address(timelock));
        vm.expectRevert(APNTsCapped.ZeroAddress.selector);
        token.setMinter(address(0));
        vm.prank(address(timelock));
        vm.expectRevert(APNTsCapped.ZeroAddress.selector);
        token.setCapGuardian(address(0));

        bytes memory setM = abi.encodeCall(APNTsCapped.setMinter, (m2));
        _schedule(setM);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectEmit(true, true, false, false, address(token));
        emit APNTsCapped.MinterSet(minter, m2);
        _execute(setM);
        assertEq(token.minter(), m2);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.NotMinter.selector, minter));
        token.mint(alice, 1); // the old minter lost the role
        vm.prank(m2);
        token.mint(alice, 1);

        vm.prank(address(timelock));
        vm.expectEmit(true, true, false, false, address(token));
        emit APNTsCapped.CapGuardianSet(guardian, rando);
        token.setCapGuardian(rando);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.NotCapGuardian.selector, guardian));
        token.lowerCap(1);
    }

    // ================= Ownable2Step / renounce =================

    function test_ownable2step_pending_owner_has_no_power_before_accept() public {
        APNTsCapped t = new APNTsCapped("AAStar PNTs", "aPNTs", CAP, deployer, minter, guardian);
        address newOwner = makeAddr("newOwner");
        t.transferOwnership(newOwner);
        assertEq(t.owner(), deployer, "2step: owner unchanged until accept");
        assertEq(t.pendingOwner(), newOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        t.raiseCap(CAP + 1);
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        t.setMinter(newOwner);

        t.raiseCap(CAP + 1); // old owner still effective before accept
        assertEq(t.cap(), CAP + 1);

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        t.acceptOwnership();

        vm.prank(newOwner);
        t.acceptOwnership();
        assertEq(t.owner(), newOwner);
        assertEq(t.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, deployer));
        t.raiseCap(CAP + 2);
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(address(timelock));
        vm.expectRevert(APNTsCapped.RenounceDisabled.selector);
        token.renounceOwnership();
        vm.prank(rando);
        vm.expectRevert(APNTsCapped.RenounceDisabled.selector);
        token.renounceOwnership();
        assertEq(token.owner(), address(timelock), "renounce is disabled");
    }

    // ================= transferAndCall / permit =================

    function test_transferAndCall_calls_receiver_with_operator_from() public {
        APNTsReceiverStub r = new APNTsReceiverStub();
        _mint(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transferAndCall(address(r), 3 ether, hex"c0ffee"));
        assertEq(r.lastOperator(), alice);
        assertEq(r.lastFrom(), alice);
        assertEq(r.lastValue(), 3 ether);
        assertEq(r.lastData(), hex"c0ffee");
        assertEq(token.balanceOf(address(r)), 3 ether);

        vm.prank(alice);
        token.transferAndCall(address(r), 1 ether); // 2-arg overload passes empty data
        assertEq(r.lastData().length, 0);
        assertEq(token.balanceOf(address(r)), 4 ether);
    }

    function test_transferAndCall_rejections() public {
        APNTsReceiverStub r = new APNTsReceiverStub();
        _mint(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.ReceiverNotContract.selector, rando));
        token.transferAndCall(rando, 1 ether);

        r.setMode(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.ReceiverRejected.selector, address(r), bytes4(0xdeadbeef)));
        token.transferAndCall(address(r), 1 ether);

        r.setMode(2);
        vm.prank(alice);
        vm.expectRevert(APNTsReceiverStub.StubRejects.selector); // bubbled, not swallowed
        token.transferAndCall(address(r), 1 ether);

        assertEq(token.balanceOf(alice), 10 ether, "rejected push transfers roll back");
    }

    function test_permit() public {
        uint256 pk = 0xA11CE;
        address holder = vm.addr(pk);
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            holder, rando, 7 ether, token.nonces(holder), deadline
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toTypedDataHash(token.DOMAIN_SEPARATOR(), structHash));
        token.permit(holder, rando, 7 ether, deadline, v, r, s);
        assertEq(token.allowance(holder, rando), 7 ether);
    }
}
