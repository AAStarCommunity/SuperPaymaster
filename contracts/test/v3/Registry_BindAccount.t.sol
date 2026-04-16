// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") { _mint(msg.sender, 1_000_000 ether); }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @title Registry_BindAccount_Test
 * @notice Regression + happy-path coverage for the self-sovereign `bindAccount`
 *         path that replaces the auto-populated `accountToUser` mapping.
 *
 *         Threat model (see docs/design/accountToUser-binding-auth.md):
 *         A rogue ROLE_COMMUNITY holder could previously call
 *         `safeMintForRole(ROLE_ENDUSER, victim, abi.encode({account: anySmartAccount, ...}))`
 *         and hijack the account binding for any address they liked. The new
 *         design requires the account itself (msg.sender) to call bindAccount.
 */
contract Registry_BindAccount_Test is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    MockGToken gtoken;

    address owner = address(0x1);
    address dao = address(0x2);
    address treasury = address(0x3);
    address user = address(0x100);
    address otherUser = address(0x101);
    address smartAccount = address(0x200);
    address otherAccount = address(0x201);
    address communityUser = address(0x300);
    address rogueCommunity = address(0x301);

    bytes32 constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    event AccountBound(address indexed account, address indexed user);

    function setUp() public {
        vm.startPrank(owner);
        gtoken = new MockGToken();
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

        // Configure COMMUNITY (ticket-only)
        IRegistry.RoleConfig memory cc = registry.getRoleConfig(ROLE_COMMUNITY);
        cc.minStake = 0;
        cc.ticketPrice = 1 ether;
        cc.isActive = true;
        cc.description = "Community";
        registry.configureRole(ROLE_COMMUNITY, cc);

        // Configure ENDUSER (ticket-only)
        IRegistry.RoleConfig memory ec = registry.getRoleConfig(ROLE_ENDUSER);
        ec.minStake = 0;
        ec.ticketPrice = 0.1 ether;
        ec.isActive = true;
        ec.description = "End User";
        registry.configureRole(ROLE_ENDUSER, ec);
        vm.stopPrank();

        // Fund and register two communities (legit + rogue)
        _registerCommunity(communityUser, "GoodDAO", "good.eth");
        _registerCommunity(rogueCommunity, "RogueDAO", "rogue.eth");

        // Register `user` as ENDUSER of communityUser
        gtoken.mint(user, 10 ether);
        vm.startPrank(user);
        gtoken.approve(address(staking), 0.1 ether);
        bytes memory roleData = abi.encode(Registry.EndUserRoleData({
            account: smartAccount,
            community: communityUser,
            avatarURI: "ipfs://avatar",
            ensName: "user.eth",
            stakeAmount: 0
        }));
        registry.registerRole(ROLE_ENDUSER, user, roleData);
        vm.stopPrank();
    }

    function _registerCommunity(address who, string memory name, string memory ensName) internal {
        gtoken.mint(who, 100 ether);
        vm.startPrank(who);
        gtoken.approve(address(staking), 1 ether);
        bytes memory data = abi.encode(Registry.CommunityRoleData({
            name: name,
            ensName: ensName,
            website: "https://example.com",
            description: "desc",
            logoURI: "ipfs://logo",
            stakeAmount: 0
        }));
        registry.registerRole(ROLE_COMMUNITY, who, data);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Registration does NOT auto-bind the account (this is the whole point)
    // ---------------------------------------------------------------------

    function test_Registration_DoesNotAutoBind() public view {
        // `smartAccount` was passed in EndUserRoleData at registration time
        // but the on-chain mapping must remain empty until the account itself
        // calls bindAccount().
        assertEq(registry.accountToUser(smartAccount), address(0));
    }

    // ---------------------------------------------------------------------
    // Happy path
    // ---------------------------------------------------------------------

    function test_BindAccount_HappyPath() public {
        vm.expectEmit(true, true, false, true);
        emit AccountBound(smartAccount, user);

        vm.prank(smartAccount);
        registry.bindAccount(user);

        assertEq(registry.accountToUser(smartAccount), user);
    }

    function test_BindAccount_Idempotent() public {
        vm.prank(smartAccount);
        registry.bindAccount(user);

        // Second call from the same account to the same user must be a no-op,
        // not a revert. No second event is expected (but we don't assert
        // absence — we just assert the mapping is unchanged).
        vm.prank(smartAccount);
        registry.bindAccount(user);
        assertEq(registry.accountToUser(smartAccount), user);
    }

    // ---------------------------------------------------------------------
    // Rejections
    // ---------------------------------------------------------------------

    function test_BindAccount_RevertsOnZeroUser() public {
        vm.prank(smartAccount);
        vm.expectRevert(Registry.InvalidParam.selector);
        registry.bindAccount(address(0));
    }

    function test_BindAccount_RevertsIfUserNotEndUser() public {
        // `otherUser` has not been registered as ENDUSER
        vm.prank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(
            Registry.RoleNotGranted.selector, ROLE_ENDUSER, otherUser
        ));
        registry.bindAccount(otherUser);
    }

    function test_BindAccount_RevertsOnOverwriteToDifferentUser() public {
        // Register a second ENDUSER
        gtoken.mint(otherUser, 10 ether);
        vm.startPrank(otherUser);
        gtoken.approve(address(staking), 0.1 ether);
        registry.registerRole(ROLE_ENDUSER, otherUser, abi.encode(Registry.EndUserRoleData({
            account: otherAccount,
            community: communityUser,
            avatarURI: "",
            ensName: "",
            stakeAmount: 0
        })));
        vm.stopPrank();

        // Account binds to `user` first
        vm.prank(smartAccount);
        registry.bindAccount(user);

        // Attempting to rebind to a different user must revert
        vm.prank(smartAccount);
        vm.expectRevert(Registry.InvalidParam.selector);
        registry.bindAccount(otherUser);

        // Original binding intact
        assertEq(registry.accountToUser(smartAccount), user);
    }

    // ---------------------------------------------------------------------
    // Regression: rogue community cannot hijack via safeMintForRole
    // ---------------------------------------------------------------------

    function test_RogueCommunity_CannotHijackBindingViaSafeMint() public {
        address victimAccount = address(0xDEAD);
        address victimUser = address(0xBEEF);

        // The rogue community calls safeMintForRole trying to claim that
        // `victimAccount` belongs to `victimUser`. This is permitted at the
        // SBT level (they can mint an ENDUSER SBT for anyone inside their
        // community, with the community paying ticketPrice) but MUST NOT
        // write accountToUser.
        vm.startPrank(rogueCommunity);
        gtoken.approve(address(staking), 0.1 ether);
        registry.safeMintForRole(ROLE_ENDUSER, victimUser, abi.encode(Registry.EndUserRoleData({
            account: victimAccount,
            community: rogueCommunity,
            avatarURI: "",
            ensName: "",
            stakeAmount: 0
        })));
        vm.stopPrank();

        // The critical invariant: accountToUser is still empty for victimAccount.
        assertEq(registry.accountToUser(victimAccount), address(0),
            "safeMintForRole must not auto-bind accountToUser");
    }
}
