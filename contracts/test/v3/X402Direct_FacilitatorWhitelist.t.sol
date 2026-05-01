// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @notice P0-12b (D4): each xPNTs token now carries a community-controlled
///         `approvedFacilitators` whitelist. Without this, a single global
///         facilitator compromise blasts across every community's xPNTs;
///         with it, a community can yank a compromised facilitator instantly
///         without redeploying or upgrading SuperPaymaster. The whitelist is
///         orthogonal to `autoApprovedSpenders` (which is the ERC20
///         transferFrom firewall) — `approvedFacilitators` gates the
///         settle-call invocation, not allowance.
contract MockEntryPoint {
    function depositTo(address) external payable {}
}

contract MockOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNTs") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract X402Direct_FacilitatorWhitelistTest is Test {
    using stdStorage for StdStorage;

    SuperPaymaster paymaster;
    Registry registry;
    xPNTsFactory factory;
    MockAPNTs apnts;

    address owner = address(0xA11CE);
    address community = address(0xC0FFEE); // also xPNTs communityOwner
    address operator = address(0xB0B);     // facilitator with PAYMASTER_SUPER role
    address otherOp  = address(0xB0B2);    // a different operator (also PAYMASTER_SUPER)
    address payee = address(0xCAFE);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    xPNTsToken token;

    function setUp() public {
        vm.startPrank(owner);

        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0xDEAD), address(0xBEEF));
        apnts = new MockAPNTs();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(new MockEntryPoint())),
            registry,
            address(new MockOracle()),
            owner,
            address(apnts),
            owner,
            3600
        );

        factory = new xPNTsFactory(address(paymaster), address(registry));
        paymaster.setXPNTsFactory(address(factory));

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Grant `community` ROLE_COMMUNITY (so it can deploy via factory).
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_COMMUNITY).with_key(community).checked_write(true);

        // Grant operator + otherOp ROLE_PAYMASTER_SUPER (global facilitator
        // role at the SP layer; the per-token whitelist narrows further).
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_PAYMASTER_SUPER).with_key(operator).checked_write(true);
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_PAYMASTER_SUPER).with_key(otherOp).checked_write(true);

        vm.stopPrank();

        // Community deploys its xPNTs.
        vm.prank(community);
        address tokenAddr = factory.deployxPNTsToken("CPNTs", "cP", "C", "c.eth", 1 ether, address(0));
        token = xPNTsToken(tokenAddr);

        // For settle-time `safeTransferFrom` to land we still need the SP to
        // be allowed to move funds; the autoApproved spender added by the
        // factory at deploy time covers that.
    }

    // -----------------------------------------------------------------------
    // settleX402PaymentDirect facilitator gate
    // -----------------------------------------------------------------------

    function test_SettleDirect_RevertsForUnapprovedFacilitator() public {
        // operator has PAYMASTER_SUPER role but is NOT in approvedFacilitators
        // → must revert.
        address user = address(0x1234);
        vm.prank(community); // community owner can mint
        token.mint(user, 100 ether);

        // Operator-as-facilitator must also be auto-approved spender so that
        // transferFrom would succeed if reached. We add it to isolate the
        // facilitator gate.
        vm.prank(community);
        token.addAutoApprovedSpender(operator);

        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402PaymentDirect(user, payee, address(token), 50 ether, bytes32(uint256(1)));

        // Balance untouched — gate fired before transfer.
        assertEq(token.balanceOf(user), 100 ether);
    }

    function test_SettleDirect_AllowsApprovedFacilitator() public {
        address user = address(0x1234);
        vm.prank(community);
        token.mint(user, 100 ether);

        // Community explicitly approves operator as facilitator.
        vm.prank(community);
        token.addApprovedFacilitator(operator);
        vm.prank(community);
        token.addAutoApprovedSpender(operator);

        vm.prank(operator);
        bytes32 sid = paymaster.settleX402PaymentDirect(
            user, payee, address(token), 50 ether, bytes32(uint256(2))
        );
        assertTrue(sid != bytes32(0));
        assertEq(token.balanceOf(payee), 50 ether);
    }

    /// @notice Different communities → different whitelists. Approving op
    ///         in community A does NOT grant access to community B's xPNTs.
    function test_SettleDirect_PerCommunityIsolation() public {
        // Set up a second community with its own xPNTs.
        address communityB = address(0xC0FFEE2);
        vm.prank(owner);
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_COMMUNITY).with_key(communityB).checked_write(true);

        vm.prank(communityB);
        address tokenBAddr = factory.deployxPNTsToken("BPNTs", "bP", "B", "b.eth", 1 ether, address(0));
        xPNTsToken tokenB = xPNTsToken(tokenBAddr);

        // Approve `operator` only on community A's xPNTs.
        vm.prank(community);
        token.addApprovedFacilitator(operator);
        vm.prank(community);
        token.addAutoApprovedSpender(operator);

        // Try to use that approval against community B's xPNTs → must fail.
        address user = address(0xDEAD);
        vm.prank(communityB);
        tokenB.mint(user, 100 ether);
        vm.prank(communityB);
        tokenB.addAutoApprovedSpender(operator); // even with allowance fine, the gate must catch.

        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402PaymentDirect(user, payee, address(tokenB), 10 ether, bytes32(uint256(3)));
    }

    // -----------------------------------------------------------------------
    // Access control on add/remove
    // -----------------------------------------------------------------------

    function test_AddApprovedFacilitator_OnlyCommunity() public {
        // Owner of SP cannot add — must be xPNTs communityOwner.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, owner));
        token.addApprovedFacilitator(operator);

        // Random address cannot add either.
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, address(0xBAD)));
        token.addApprovedFacilitator(operator);

        // Community owner can.
        vm.prank(community);
        token.addApprovedFacilitator(operator);
        assertTrue(token.approvedFacilitators(operator));
    }

    function test_AddApprovedFacilitator_RevertsZeroAddress() public {
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.InvalidAddress.selector, address(0)));
        token.addApprovedFacilitator(address(0));
    }

    /// @notice communityOwner cannot add themselves as facilitator —
    ///         doing so would let them exploit the auto-approved allowance
    ///         they administer (conflict of interest / separation of duties).
    function test_AddApprovedFacilitator_RevertsIfCommunityOwner() public {
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, community));
        token.addApprovedFacilitator(community);

        // Confirm the entry was NOT added to the whitelist.
        assertFalse(token.approvedFacilitators(community));
    }

    function test_AddApprovedFacilitator_EmitsEvent() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit FacilitatorApproved(operator);
        vm.prank(community);
        token.addApprovedFacilitator(operator);
    }

    function test_RemoveApprovedFacilitator_RevokesAccess() public {
        address user = address(0x1234);
        vm.prank(community);
        token.mint(user, 100 ether);
        vm.prank(community);
        token.addApprovedFacilitator(operator);
        vm.prank(community);
        token.addAutoApprovedSpender(operator);

        // Works once.
        vm.prank(operator);
        paymaster.settleX402PaymentDirect(user, payee, address(token), 10 ether, bytes32(uint256(4)));
        assertTrue(token.approvedFacilitators(operator));

        // Community revokes.
        vm.prank(community);
        token.removeApprovedFacilitator(operator);
        assertFalse(token.approvedFacilitators(operator));

        // Subsequent settle must revert immediately, even with the same
        // allowance + autoApproved spender state.
        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.Unauthorized.selector);
        paymaster.settleX402PaymentDirect(user, payee, address(token), 10 ether, bytes32(uint256(5)));
    }

    function test_RemoveApprovedFacilitator_OnlyCommunity() public {
        vm.prank(community);
        token.addApprovedFacilitator(operator);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, operator));
        token.removeApprovedFacilitator(operator);

        // Approval still standing.
        assertTrue(token.approvedFacilitators(operator));
    }

    function test_DefaultEmptyApprovedFacilitators() public {
        // Per D4: factory does NOT auto-add AAStar (or any) facilitator on
        // deployment. New community xPNTs must explicitly add facilitators.
        assertFalse(token.approvedFacilitators(owner), "owner should not be auto-approved");
        assertFalse(token.approvedFacilitators(operator), "operator should not be auto-approved");
        assertFalse(token.approvedFacilitators(address(paymaster)), "SP should not be auto-approved");
    }

    // Local copy so test can vm.expectEmit it (event lives on the token).
    event FacilitatorApproved(address indexed facilitator);
}
