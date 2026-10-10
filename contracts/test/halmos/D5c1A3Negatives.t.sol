// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsV2Base } from "src/tokens/v2/xPNTsV2Base.sol";
import { V2TokenDeployer, IxPNTsV2Admin } from "../helpers/V2TokenDeployer.sol";
import { MockRegistryV2, DummySpender, IExt } from "../helpers/V2TestFixtures.sol";

/**
 * @title D5c-1 A-3 named negative controls (DSR CC-125 d030f6e8 item 1a).
 * @notice Spec 03 §2.3 A-3 / A-10 ①②: the SuperPaymaster (current or historical) is NEVER a
 *         spender. Two named negative controls on the exact v5.5.0-rc.2 source:
 *   NEG-1  `initialize` with `genesisSpender == superPaymaster` is REJECTED with
 *          `InvalidAddress(sp)` (xPNTsTokenV2.initialize). A positive control with a different,
 *          approved genesis spender shows the revert is caused by the equality alone.
 *   NEG-2  an address that is auto-approved as a spender and LATER becomes the SP (rotation via
 *          proposeSP + activateSP after the 48 h timelock) is REMOVED from autoApprovedSpenders in
 *          the same call (`AutoApprovedSpenderRemoved` before `SuperPaymasterAddressUpdated`), its
 *          allowance reads 0 even with an explicit unlimited approval, and transferFrom / burn(from)
 *          revert `SPCannotTransfer` — also after it is rotated OUT again (historicalSP is sticky),
 *          and it cannot be re-added as a spender. Two entry paths into "auto-approved":
 *          the genesis spender (A-10 ②) and proposeSpender + activateSpender (X4).
 */
contract D5c1A3NegativesTest is Test {
    address internal sp = address(0x5B);
    address internal owner_ = address(0xC0);
    address internal community = address(0xC1);
    address internal user = address(0xB0B);
    MockRegistryV2 internal registry;
    V2TokenDeployer.Stack internal st;

    function setUp() public {
        registry = new MockRegistryV2();
        st = V2TokenDeployer.deployStack(sp, address(registry));
    }

    function _cfg(address superPaymaster, address genesisSpender) internal view returns (xPNTsTokenV2.InitConfig memory) {
        return xPNTsTokenV2.InitConfig({
            name: "Community Points",
            symbol: "xPNT",
            communityOwner: owner_,
            community: community,
            communityName: "Community",
            communityENS: "community.eth",
            exchangeRate: 1 ether,
            superPaymaster: superPaymaster,
            genesisSpender: genesisSpender,
            tierSource: address(st.tier)
        });
    }

    /// A spender contract approved BOTH as a spender implementation (codehash) and as an SP
    /// (address key) — the only way an auto-approved spender can later become the SP.
    function _dualApproved() internal returns (DummySpender x) {
        x = new DummySpender();
        st.aoa.bootstrapApprove(st.aoa.KIND_SPENDER(), address(x).codehash);
        V2TokenDeployer.approveSP(st, address(x));
        assertTrue(st.aoa.isApprovedSP(address(x)), "fixture: x is an approved SP");
        assertTrue(st.aoa.isApprovedImpl(st.aoa.KIND_SPENDER(), address(x)), "fixture: x is an approved spender impl");
    }

    // ============================================================ NEG-1

    function test_D5c1_A3_NEG1_initializeRejectsGenesisSpenderEqualToSP() public {
        // make `sp` ALSO an approved spender implementation, so the ONLY reason left to reject is A-3
        DummySpender x = _dualApproved();
        xPNTsTokenV2 tok = xPNTsTokenV2(Clones.clone(address(st.impl)));
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, address(x)));
        tok.initialize(_cfg(address(x), address(x)));
        // the clone stays uninitialised: nothing was written
        assertEq(tok.SUPERPAYMASTER_ADDRESS(), address(0), "NEG-1: no SP written");
        assertFalse(tok.autoApprovedSpenders(address(x)), "NEG-1: SP not auto-approved");
        assertFalse(tok.historicalSP(address(x)), "NEG-1: no historicalSP written");
    }

    /// Positive control for NEG-1: the same initialisation with a DIFFERENT approved spender succeeds.
    function test_D5c1_A3_NEG1_control_distinctGenesisSpenderAccepted() public {
        DummySpender x = _dualApproved();
        xPNTsTokenV2 tok = xPNTsTokenV2(Clones.clone(address(st.impl)));
        tok.initialize(_cfg(sp, address(x)));
        assertEq(tok.SUPERPAYMASTER_ADDRESS(), sp);
        assertTrue(tok.autoApprovedSpenders(address(x)), "control: genesis spender auto-approved");
        assertFalse(tok.autoApprovedSpenders(sp), "control: genesis SP is not a spender (A-10 1)");
        assertTrue(tok.historicalSP(sp));
    }

    // ============================================================ NEG-2

    function test_D5c1_A3_NEG2_genesisSpenderBecomingSPIsRemoved() public {
        DummySpender x = _dualApproved();
        xPNTsTokenV2 tok = xPNTsTokenV2(Clones.clone(address(st.impl)));
        tok.initialize(_cfg(sp, address(x)));   // x = auto-approved FUTURE SP
        _rotateAndCheck(tok, x);
    }

    function test_D5c1_A3_NEG2_activatedSpenderBecomingSPIsRemoved() public {
        DummySpender x = _dualApproved();
        xPNTsTokenV2 tok = V2TokenDeployer.newToken(st, owner_, community, sp, 1 ether);
        vm.prank(owner_);
        IExt(address(tok)).proposeSpender(address(x));
        vm.warp(block.timestamp + 48 hours);
        IExt(address(tok)).activateSpender(address(x));
        _rotateAndCheck(tok, x);
    }

    function _rotateAndCheck(xPNTsTokenV2 tok, DummySpender x) internal {
        IxPNTsV2Admin(address(tok)).mint(user, 1_000 ether); // test contract = FACTORY
        assertTrue(tok.autoApprovedSpenders(address(x)), "pre: x auto-approved");
        assertFalse(tok.historicalSP(address(x)), "pre: x not historical SP");

        // the user opens an auto-allowance AND an unlimited explicit approval for x
        vm.startPrank(user);
        IExt(address(tok)).setAutoAllowance(address(x), 100 ether);
        tok.approve(address(x), type(uint256).max);
        vm.stopPrank();
        assertGt(tok.allowance(user, address(x)), 0, "pre: x has allowance");
        // pre-rotation x CAN pull (shows the later revert is caused by the rotation)
        x.pull(address(tok), user, 1 ether);
        assertEq(tok.balanceOf(address(x)), 1 ether, "pre: x pulled 1");

        // ---- rotation: x becomes the current SP
        vm.prank(owner_);
        IExt(address(tok)).proposeSP(address(x));
        vm.warp(block.timestamp + 48 hours);
        vm.recordLogs();
        vm.expectEmit(true, false, false, true, address(tok));
        emit xPNTsV2Base.AutoApprovedSpenderRemoved(address(x));
        vm.expectEmit(true, true, false, true, address(tok));
        emit xPNTsV2Base.SuperPaymasterAddressUpdated(sp, address(x));
        IExt(address(tok)).activateSP();
        // the recorded logs also contain the two template emits of this test contract: keep the token's
        Vm.Log[] memory all = vm.getRecordedLogs();
        bytes32[] memory t = new bytes32[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; ++i) if (all[i].emitter == address(tok)) t[n++] = all[i].topics[0];
        assertEq(n, 2, "activateSP: the token emits exactly Removed + Updated");
        assertEq(t[0], xPNTsV2Base.AutoApprovedSpenderRemoved.selector, "first token log: spender removed");
        assertEq(t[1], xPNTsV2Base.SuperPaymasterAddressUpdated.selector, "second token log: SP updated");

        _assertBanned(tok, x, "as current SP");
        assertEq(tok.SUPERPAYMASTER_ADDRESS(), address(x));

        // ---- rotate x OUT again: the ban is sticky (historicalSP), x is not re-added
        address y = address(0x5C);
        V2TokenDeployer.approveSP(st, y);
        vm.prank(owner_);
        IExt(address(tok)).proposeSP(y);
        vm.warp(block.timestamp + 48 hours);
        IExt(address(tok)).activateSP();
        assertEq(tok.SUPERPAYMASTER_ADDRESS(), y);
        _assertBanned(tok, x, "as historical SP");

        // x can never be re-added as a spender
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, address(x)));
        IExt(address(tok)).proposeSpender(address(x));
        // the ORIGINAL genesis SP stays banned too
        vm.prank(user);
        tok.approve(sp, type(uint256).max);
        vm.prank(sp);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.transferFrom(user, sp, 1);
    }

    function _assertBanned(xPNTsTokenV2 tok, DummySpender x, string memory when) internal {
        uint256 bal = tok.balanceOf(user);
        uint256 supply = tok.totalSupply();
        assertFalse(tok.autoApprovedSpenders(address(x)), string.concat("removed from autoApprovedSpenders ", when));
        assertTrue(tok.historicalSP(address(x)), string.concat("historicalSP ", when));
        assertEq(tok.allowance(user, address(x)), 0, string.concat("allowance reads 0 ", when));
        // the explicit approval is still stored (ERC20 slot) but unusable
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        x.pull(address(tok), user, 1 ether);              // transferFrom(user -> x) via the spender contract
        vm.startPrank(address(x));
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.transferFrom(user, address(0xDEAD), 1 ether);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.burn(user, 1 ether);
        vm.stopPrank();
        assertEq(tok.balanceOf(user), bal, string.concat("user balance untouched ", when));
        assertEq(tok.totalSupply(), supply, string.concat("supply untouched ", when));
    }
}
