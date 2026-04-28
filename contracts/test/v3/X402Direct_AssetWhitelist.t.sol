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

/// @notice P0-12a (B2-N4): `settleX402PaymentDirect` previously called
///         `IERC20(asset).safeTransferFrom(from, ...)` for any caller-supplied
///         asset. A user who had done a standard infinite `approve` for USDC
///         (legitimate x402 EIP-3009 pattern) could be drained by a
///         compromised facilitator via the Direct path. Defense: gate Direct
///         on `xpntsFactory.isXPNTs(asset)`. xPNTs tokens carry the
///         autoApproved firewall + MAX_SINGLE_TX_LIMIT; arbitrary ERC20s do
///         not, hence Direct must refuse them.
contract MockEntryPoint {
    function depositTo(address) external payable {}
}

contract MockOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNTs") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract X402Direct_AssetWhitelistTest is Test {
    using stdStorage for StdStorage;

    SuperPaymaster paymaster;
    Registry registry;
    xPNTsFactory factory;
    MockUSDC usdc;
    MockAPNTs apnts;

    address owner = address(0xA11CE);
    address operator = address(0xB0B);
    address payee = address(0xCAFE);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy core
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0xDEAD), address(0xBEEF));
        usdc = new MockUSDC();
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

        // Deploy factory and wire it into SP
        factory = new xPNTsFactory(address(paymaster), address(registry));
        paymaster.setXPNTsFactory(address(factory));

        // Refresh price cache
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Operator gets PAYMASTER_SUPER + COMMUNITY roles (so it can act as facilitator)
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_PAYMASTER_SUPER).with_key(operator).checked_write(true);
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_COMMUNITY).with_key(operator).checked_write(true);

        vm.stopPrank();
    }

    /// @dev Have `operator` deploy an xPNTs via the factory (registers it in
    ///      the isXPNTs whitelist) and mint balance + auto-approve facilitator.
    function _deployXPNTsForOperator() internal returns (xPNTsToken token) {
        vm.prank(operator);
        address tokenAddr = factory.deployxPNTsToken("OpPNTs", "oPNTs", "OpCommunity", "op.eth", 1 ether, address(0));
        token = xPNTsToken(tokenAddr);

        // Add operator (the facilitator) to autoApprovedSpenders so transferFrom passes
        vm.prank(operator); // operator is the communityOwner of this token
        token.addAutoApprovedSpender(operator);
    }

    // -----------------------------------------------------------------------
    // Asset whitelist enforcement
    // -----------------------------------------------------------------------

    function test_SettleDirect_RejectsNonXPNTsAsset() public {
        // Victim previously did `approve(facilitator, MAX)` for USDC. Even
        // though the operator is registered, Direct must refuse USDC.
        address victim = address(0xDEFEA7);
        usdc.mint(victim, 1_000_000e6);
        vm.prank(victim);
        usdc.approve(address(paymaster), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.InvalidXPNTsToken.selector);
        paymaster.settleX402PaymentDirect(victim, payee, address(usdc), 100e6, bytes32(uint256(1)));

        // And the victim's balance is untouched — direct path bailed out
        // before transfer.
        assertEq(usdc.balanceOf(victim), 1_000_000e6, "USDC must not move");
    }

    function test_SettleDirect_RejectsAPNTsAsset() public {
        // aPNTs is the protocol token, NOT a factory-deployed xPNTs. It must
        // not flow through Direct either — Direct is reserved for community
        // xPNTs which carry the firewall.
        address victim = address(0xDEFEA8);
        apnts.mint(victim, 1000 ether);
        vm.prank(victim);
        apnts.approve(address(paymaster), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.InvalidXPNTsToken.selector);
        paymaster.settleX402PaymentDirect(victim, payee, address(apnts), 100 ether, bytes32(uint256(2)));
    }

    function test_SettleDirect_AcceptsXPNTsAsset() public {
        xPNTsToken token = _deployXPNTsForOperator();

        address user = address(0xFEED);
        vm.prank(operator); // mint via communityOwner
        token.mint(user, 100 ether);

        vm.prank(operator);
        bytes32 sid = paymaster.settleX402PaymentDirect(
            user, payee, address(token), 50 ether, bytes32(uint256(3))
        );
        assertTrue(sid != bytes32(0), "settle must succeed for whitelisted xPNTs");
        assertEq(token.balanceOf(payee), 50 ether, "payee receives funds (no fee configured)");
    }

    // -----------------------------------------------------------------------
    // Factory-side bookkeeping invariant
    // -----------------------------------------------------------------------

    function test_Factory_IsXPNTsTrueAfterDeploy() public {
        xPNTsToken token = _deployXPNTsForOperator();
        assertTrue(factory.isXPNTs(address(token)), "factory must record deployed token");
    }

    function test_Factory_IsXPNTsFalseForArbitraryToken() public {
        assertFalse(factory.isXPNTs(address(usdc)), "USDC was not deployed by factory");
        assertFalse(factory.isXPNTs(address(apnts)), "aPNTs was not deployed by factory");
        assertFalse(factory.isXPNTs(address(0xC0DE)), "junk address is not xPNTs");
    }

    /// @notice If owner forgot to wire the factory, Direct must fail closed
    ///         (cannot whitelist anything → reject all).
    function test_SettleDirect_RevertsWhenFactoryUnset() public {
        vm.prank(owner);
        paymaster.setXPNTsFactory(address(0));

        address victim = address(0xDEFEA9);
        usdc.mint(victim, 1000e6);
        vm.prank(victim);
        usdc.approve(address(paymaster), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.settleX402PaymentDirect(victim, payee, address(usdc), 100e6, bytes32(uint256(4)));
    }
}
