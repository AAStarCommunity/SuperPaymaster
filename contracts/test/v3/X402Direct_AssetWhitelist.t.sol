// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/X402Facilitator.sol";
import "src/core/Registry.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";
import "src/interfaces/IxPNTsFactory.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @notice P0-12a (B2-N4): `settleX402PaymentDirect` previously called
///         `IERC20(asset).safeTransferFrom(from, ...)` for any caller-supplied
///         asset. A user who had done a standard infinite `approve` for USDC
///         (legitimate x402 EIP-3009 pattern) could be drained by a
///         compromised facilitator via the Direct path. Defense: gate Direct
///         on `xpntsFactory.isXPNTs(asset)`. xPNTs tokens carry the
///         autoApproved firewall + MAX_SINGLE_TX_LIMIT; arbitrary ERC20s do
///         not, hence Direct must refuse them.
///
/// @dev v5.4 god-split phase 1: retargeted from SuperPaymaster to the standalone
///      X402Facilitator. The xPNTs auto-allowance now points at X402Facilitator
///      (factory.setSuperPaymasterAddress(x402)), so the Direct-path transferFrom
///      pulls into the facilitator.
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

    X402Facilitator x402;
    Registry registry;
    xPNTsFactory factory;
    MockUSDC usdc;
    MockAPNTs apnts;

    address owner = address(0xA11CE);
    address operator = address(0xB0B);
    address community = address(0xC0FFEE); // separate communityOwner (P0-12b: cannot self-add)
    address payee = address(0xCAFE);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy core
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0xDEAD), address(0xBEEF));
        usdc = new MockUSDC();
        apnts = new MockAPNTs();

        // Deploy factory first (SUPERPAYMASTER unset), then the facilitator, then point
        // the factory's auto-approved settler at the facilitator. xPNTs deployed AFTER
        // this grant the transferFrom auto-allowance to X402Facilitator — the deploy-time
        // firewall re-point that the split requires.
        factory = new xPNTsFactory(address(0), address(registry));
        x402 = new X402Facilitator(registry, IxPNTsFactory(address(factory)));
        factory.setSuperPaymasterAddress(address(x402));

        // Operator gets PAYMASTER_SUPER role (acts as facilitator that calls settle).
        // Community gets COMMUNITY role (deploys xPNTs and owns it).
        // P0-12b: communityOwner cannot self-add as facilitator → separate addresses.
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_PAYMASTER_SUPER).with_key(operator).checked_write(true);
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_COMMUNITY).with_key(community).checked_write(true);

        vm.stopPrank();
    }

    /// @dev `community` deploys an xPNTs via the factory (becomes communityOwner),
    ///      then approves `operator` as facilitator. P0-12b prevents self-add,
    ///      so the two addresses must be distinct.
    function _deployXPNTsForOperator() internal returns (xPNTsToken token) {
        vm.prank(community);
        address tokenAddr = factory.deployxPNTsToken("OpPNTs", "oPNTs", "OpCommunity", "op.eth", 1 ether, address(0));
        token = xPNTsToken(tokenAddr);

        // P0-12b: communityOwner approves operator as facilitator.
        vm.prank(community);
        token.addApprovedFacilitator(operator);
    }

    function _signX402Direct(
        uint256 privateKey,
        address from,
        address to,
        address asset,
        uint256 amount,
        uint256 maxFee,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("X402Facilitator"),
                keccak256("1"),
                block.chainid,
                address(x402)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "X402PaymentAuthorization(address from,address to,address asset,uint256 amount,uint256 maxFee,uint256 validBefore,bytes32 nonce)"
                ),
                from,
                to,
                asset,
                amount,
                maxFee,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // -----------------------------------------------------------------------
    // Asset whitelist enforcement
    // -----------------------------------------------------------------------

    function test_SettleDirect_RejectsNonXPNTsAsset() public {
        // Victim previously did `approve(facilitator, MAX)` for USDC. Even
        // though the operator is registered, Direct must refuse USDC.
        uint256 victimKey = 0xDEFEA7;
        address victim = vm.addr(victimKey);
        uint256 amount = 100e6;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(1));
        bytes memory signature =
            _signX402Direct(victimKey, victim, payee, address(usdc), amount, maxFee, validBefore, nonce);
        usdc.mint(victim, 1_000_000e6);
        vm.prank(victim);
        usdc.approve(address(x402), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(X402Facilitator.InvalidXPNTsToken.selector);
        x402.settleX402PaymentDirect(victim, payee, address(usdc), amount, maxFee, validBefore, nonce, signature);

        // And the victim's balance is untouched — direct path bailed out
        // before transfer.
        assertEq(usdc.balanceOf(victim), 1_000_000e6, "USDC must not move");
    }

    function test_SettleDirect_RejectsAPNTsAsset() public {
        // aPNTs is the protocol token, NOT a factory-deployed xPNTs. It must
        // not flow through Direct either — Direct is reserved for community
        // xPNTs which carry the firewall.
        uint256 victimKey = 0xDEFEA8;
        address victim = vm.addr(victimKey);
        uint256 amount = 100 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(2));
        bytes memory signature =
            _signX402Direct(victimKey, victim, payee, address(apnts), amount, maxFee, validBefore, nonce);
        apnts.mint(victim, 1000 ether);
        vm.prank(victim);
        apnts.approve(address(x402), type(uint256).max);

        vm.prank(operator);
        vm.expectRevert(X402Facilitator.InvalidXPNTsToken.selector);
        x402.settleX402PaymentDirect(victim, payee, address(apnts), amount, maxFee, validBefore, nonce, signature);
    }

    function test_SettleDirect_AcceptsXPNTsAsset() public {
        xPNTsToken token = _deployXPNTsForOperator();

        uint256 userKey = 0xFEED;
        address user = vm.addr(userKey);
        uint256 amount = 50 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(3));
        bytes memory signature =
            _signX402Direct(userKey, user, payee, address(token), amount, maxFee, validBefore, nonce);
        vm.prank(community); // mint via communityOwner
        token.mint(user, 100 ether);

        vm.prank(operator);
        bytes32 sid = x402.settleX402PaymentDirect(
            user, payee, address(token), amount, maxFee, validBefore, nonce, signature
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

    /// @notice v5.4 god-split phase 1: the legacy "factory unset" test was removed.
    ///         SuperPaymaster held `xpntsFactory` in MUTABLE storage (settable to
    ///         address(0)), so it needed a runtime InvalidConfiguration guard. In
    ///         X402Facilitator the factory is an IMMUTABLE constructor argument that
    ///         the constructor rejects when zero, so the "factory unset" state is
    ///         unreachable and no longer testable via stdstore.

    // -----------------------------------------------------------------------
    // Nonce consumption behavior
    // -----------------------------------------------------------------------

    /// @notice Documents nonce behavior when settleX402PaymentDirect reverts
    ///         with InvalidXPNTsToken.
    ///
    /// @dev EVM revert semantics: when settleX402PaymentDirect reverts (for any
    ///      reason), ALL state changes within that call — including the nonce
    ///      write in _validateX402AndComputeFee — are rolled back. Therefore
    ///      the nonce is NOT consumed on an InvalidXPNTsToken failure, and the
    ///      same (asset, from, nonce) triple may be reused with a corrected call.
    ///
    ///      The code comment in _validateX402AndComputeFee ("nonce is consumed
    ///      before asset whitelist check") describes the *execution order* within
    ///      the call frame, not the observable persistent result. Because the
    ///      outer call reverts, the nonce write never lands on-chain.
    ///
    ///      Practical implication: a caller that submitted with a non-xPNTs asset
    ///      by mistake may retry with the same nonce value, but MUST use a valid
    ///      xPNTs asset on the retry. Retrying with the same wrong asset will
    ///      keep reverting with InvalidXPNTsToken (not NonceAlreadyUsed).
    function test_SettleDirect_NonceConsumed_OnAssetWhitelistFailure() public {
        uint256 victimKey = 0xDEFEAA;
        address victim = vm.addr(victimKey);
        uint256 amount = 100e6;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        usdc.mint(victim, 1_000_000e6);
        vm.prank(victim);
        usdc.approve(address(x402), type(uint256).max);

        bytes32 nonce = bytes32(uint256(999));
        bytes32 key = x402.x402NonceKey(address(usdc), victim, nonce);
        bytes memory signature =
            _signX402Direct(victimKey, victim, payee, address(usdc), amount, maxFee, validBefore, nonce);

        // Pre-condition: nonce is fresh.
        assertFalse(x402.x402SettlementNonces(key), "nonce must start unused");

        // First call: reverts with InvalidXPNTsToken. Because the entire call
        // reverts, the nonce write in _validateX402AndComputeFee is rolled back.
        vm.prank(operator);
        vm.expectRevert(X402Facilitator.InvalidXPNTsToken.selector);
        x402.settleX402PaymentDirect(victim, payee, address(usdc), amount, maxFee, validBefore, nonce, signature);

        // Nonce is still free — the revert cancelled the storage write.
        assertFalse(x402.x402SettlementNonces(key), "nonce must NOT be consumed after revert");

        // Victim's USDC balance is untouched — no transfer occurred.
        assertEq(usdc.balanceOf(victim), 1_000_000e6, "USDC must not move on failed call");

        // Second call with same nonce and still-wrong asset: reverts again with
        // InvalidXPNTsToken (not NonceAlreadyUsed) — confirming nonce was free.
        vm.prank(operator);
        vm.expectRevert(X402Facilitator.InvalidXPNTsToken.selector);
        x402.settleX402PaymentDirect(victim, payee, address(usdc), amount, maxFee, validBefore, nonce, signature);

        // Nonce remains free after two failed calls.
        assertFalse(x402.x402SettlementNonces(key), "nonce must still be unused after second revert");
    }

    /// @notice Confirms that nonce IS durably consumed on a successful call,
    ///         and that a replay with the same nonce is rejected with NonceAlreadyUsed.
    function test_SettleDirect_NonceConsumed_OnSuccess() public {
        xPNTsToken token = _deployXPNTsForOperator();

        uint256 userKey = 0xFEED2;
        address user = vm.addr(userKey);
        uint256 amount = 50 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        vm.prank(community);
        token.mint(user, 200 ether);

        bytes32 nonce = bytes32(uint256(777));
        bytes32 key = x402.x402NonceKey(address(token), user, nonce);
        bytes memory signature =
            _signX402Direct(userKey, user, payee, address(token), amount, maxFee, validBefore, nonce);

        assertFalse(x402.x402SettlementNonces(key), "nonce must start unused");

        // Successful settlement — nonce is durably consumed.
        vm.prank(operator);
        x402.settleX402PaymentDirect(user, payee, address(token), amount, maxFee, validBefore, nonce, signature);

        assertTrue(x402.x402SettlementNonces(key), "nonce must be consumed after successful settle");

        // Replay with the same nonce must revert with NonceAlreadyUsed.
        vm.prank(operator);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402PaymentDirect(user, payee, address(token), amount, maxFee, validBefore, nonce, signature);
    }
}
