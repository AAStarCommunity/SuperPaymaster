// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/X402Facilitator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/IxPNTsFactory.sol";
import "src/interfaces/v3/IERC3009.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";

// ====================================
// Mock Contracts
// ====================================

/// @dev Minimal Registry stand-in: X402Facilitator only ever calls
///      `hasRole(ROLE_PAYMASTER_SUPER, caller)`, so a tiny role map suffices.
///      Cast to IRegistry at the constructor call-site.
contract MockRoleRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function setRole(bytes32 role, address who, bool ok) external {
        roles[role][who] = ok;
    }

    function hasRole(bytes32 role, address who) external view returns (bool) {
        return roles[role][who];
    }
}

/// @dev Mock ERC-3009 token (USDC-like) with transferWithAuthorization
contract MockERC3009Token is ERC20, IERC3009 {
    using ECDSA for bytes32;

    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    constructor() ERC20("USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _authDigest(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name())),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
    }

    function receiveAuthorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
    }

    function transferWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external override {
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = authorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external override {
        // EIP-3009 receive semantics: only the payee may submit the authorization.
        require(msg.sender == to, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = receiveAuthorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        _transfer(from, to, value);
    }
}

/// @dev M-1: deflationary / fee-on-transfer EIP-3009 token. Verifies the payer's
///      authorization exactly like MockERC3009Token, but skims 1% on transfer so the
///      recipient (`to`, i.e. the X402Facilitator) receives LESS than `value`. This
///      violates the EIP-3009 path's amount==received assumption and must be rejected
///      by the contract's balance-delta check (X402AmountMismatch).
contract MockDeflationaryERC3009Token is ERC20, IERC3009 {
    using ECDSA for bytes32;

    uint256 public constant SKIM_BPS = 100; // 1%
    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    constructor() ERC20("Deflationary USDC", "dUSDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _authDigest(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name())),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
    }

    function receiveAuthorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
    }

    function transferWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external override {
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = authorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        // Skim 1%: recipient receives value - fee, the rest is burned. The X402Facilitator
        // (the `to`) therefore sees a short balance delta.
        uint256 skim = (value * SKIM_BPS) / 10000;
        _transfer(from, to, value - skim);
        _burn(from, skim);
    }

    function receiveWithAuthorization(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external override {
        // EIP-3009 receive semantics: only the payee may submit the authorization.
        require(msg.sender == to, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");
        bytes32 digest = receiveAuthorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");
        authorizationUsed[from][nonce] = true;
        // Skim 1%: recipient receives value - fee, the rest is burned. The X402Facilitator
        // (the `to`) therefore sees a short balance delta.
        uint256 skim = (value * SKIM_BPS) / 10000;
        _transfer(from, to, value - skim);
        _burn(from, skim);
    }
}

/// @dev Mock xPNTs-like token (auto-approves the X402Facilitator settler)
contract MockDirectToken is ERC20 {
    address public settler;
    /// @dev P0-12b: X402Facilitator.settleX402PaymentDirect consults this.
    mapping(address => bool) public approvedFacilitators;

    constructor(address _settler) ERC20("xPNTs", "xPNTs") {
        settler = _settler;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    function allowance(address owner_, address spender) public view override returns (uint256) {
        if (spender == settler) return type(uint256).max;
        return super.allowance(owner_, spender);
    }

    function setApprovedFacilitator(address f, bool ok) external {
        approvedFacilitators[f] = ok;
    }
}

/// @dev Mock factory for P0-12a — only purpose is to whitelist xPNTs tokens
///      for `settleX402PaymentDirect`. Cast to IxPNTsFactory at the call-site.
contract MockXPNTsFactory {
    mapping(address => bool) public isXPNTs;
    function setXPNTs(address token, bool ok) external { isXPNTs[token] = ok; }
    function getAPNTsPrice() external pure returns (uint256) { return 0.02 ether; }
    function getTokenAddress(address) external pure returns (address) { return address(0); }
    function hasToken(address) external pure returns (bool) { return false; }
}

// ====================================
// Test Contract
// ====================================

/// @notice v5.4 god-split phase 1: these x402 settlement tests were moved verbatim from
///         SuperPaymasterV5Features.t.sol and retargeted from SuperPaymaster to the
///         standalone X402Facilitator contract. All M-1 / P0-13 assertions are preserved.
contract X402Facilitator_Test is Test {
    using stdStorage for StdStorage;

    X402Facilitator public x402;
    MockRoleRegistry public registry;
    MockERC3009Token public usdc;
    MockDirectToken public xpnts;
    MockXPNTsFactory public mockFactory;

    address public owner = address(0x1);
    address public operator1 = address(0x3);
    address public user1 = address(0x5);
    address public payee = address(0x6);

    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    function setUp() public {
        vm.startPrank(owner);

        registry = new MockRoleRegistry();
        usdc = new MockERC3009Token();
        mockFactory = new MockXPNTsFactory();

        // Deployer (owner) becomes Ownable owner of the facilitator.
        x402 = new X402Facilitator(IRegistry(address(registry)), IxPNTsFactory(address(mockFactory)));

        // Deploy mock xPNTs that auto-approve the X402Facilitator (the settler).
        xpnts = new MockDirectToken(address(x402));

        // P0-12a: settleX402PaymentDirect requires asset to be a registered xPNTs.
        mockFactory.setXPNTs(address(xpnts), true);

        // P0-12b: facilitator (operator1) must be approved by the xPNTs.
        xpnts.setApprovedFacilitator(operator1, true);

        // operator1 holds the PAYMASTER_SUPER role.
        registry.setRole(ROLE_PAYMASTER_SUPER, operator1, true);

        // Default facilitator fee.
        x402.setFacilitatorFeeBPS(30); // 0.3%

        vm.stopPrank();
    }

    function _signEIP3009(
        uint256 privateKey,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        // The contract calls receiveWithAuthorization, so the payer signs the
        // ReceiveWithAuthorization digest (msg.sender == to is the X402Facilitator).
        bytes32 digest = usdc.receiveAuthorizationDigest(from, to, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
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

    // ====================================
    // settleX402Payment (EIP-3009) Tests
    // ====================================

    function test_SettleEIP3009_Success() public {
        uint256 amount = 1000e6;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(1));
        // M-1: maxFee is bound into the EIP-3009 nonce. fee = amount*100/10000 = 10e6 <= maxFee.
        uint256 maxFee = amount;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        bytes memory signature = _signEIP3009(payerKey, payer, address(x402), amount, validAfter, validBefore, nonce);

        usdc.mint(payer, amount);

        vm.prank(owner);
        x402.setOperatorFacilitatorFee(operator1, 100); // 1%

        vm.prank(operator1);
        bytes32 settlementId = x402.settleX402Payment(
            payer, payee, address(usdc), amount, maxFee,
            validAfter, validBefore, salt, signature
        );

        uint256 fee = (amount * 100) / 10000;
        assertEq(usdc.balanceOf(payee), amount - fee);
        assertEq(x402.facilitatorEarnings(operator1, address(usdc)), fee);
        assertTrue(settlementId != bytes32(0));
    }

    function test_SettleEIP3009_Replay() public {
        uint256 amount = 100e6;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, amount * 2);

        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(42));
        uint256 maxFee = amount;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        bytes memory signature = _signEIP3009(payerKey, payer, address(x402), amount, validAfter, validBefore, nonce);

        vm.prank(operator1);
        x402.settleX402Payment(payer, payee, address(usdc), amount, maxFee, validAfter, validBefore, salt, signature);

        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402Payment(payer, payee, address(usdc), amount, maxFee, validAfter, validBefore, salt, signature);
    }

    function test_SettleEIP3009_Unauthorized() public {
        // Role check (_requireSuperOperatorRole) runs before fee>maxFee / transfer,
        // so maxFee value is irrelevant; Unauthorized is still the first revert reached.
        vm.prank(user1);
        vm.expectRevert(X402Facilitator.Unauthorized.selector);
        x402.settleX402Payment(address(0x10), payee, address(usdc), 100e6, 100e6, 0, block.timestamp + 1 hours, bytes32(uint256(77)), "");
    }

    // ====================================
    // M-1: maxFee cap on the EIP-3009 settle path
    // ====================================

    /// @notice M-1: when the computed facilitator fee exceeds the payer-approved
    ///         maxFee, the settle must revert X402FeeExceedsMax (before the transfer).
    function test_M1_EIP3009_FeeExceedsMaxFee_Reverts() public {
        uint256 amount = 1000e6;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(0x1A1)); // arbitrary salt
        // Operator charges 5% → fee = 50e6, but payer caps maxFee at 1e6 (< fee).
        uint256 maxFee = 1e6;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        bytes memory signature = _signEIP3009(payerKey, payer, address(x402), amount, validAfter, validBefore, nonce);
        usdc.mint(payer, amount);

        vm.prank(owner);
        x402.setOperatorFacilitatorFee(operator1, 500); // 5%

        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.X402FeeExceedsMax.selector);
        x402.settleX402Payment(payer, payee, address(usdc), amount, maxFee, validAfter, validBefore, salt, signature);
    }

    /// @notice M-1: maxFee is committed into the EIP-3009 nonce. If an operator submits
    ///         a maxFee (Y) different from the one the payer signed over (X), the contract
    ///         recomputes the nonce with Y and the payer's signature no longer recovers
    ///         `from` → the token's transferWithAuthorization reverts "bad signature".
    function test_M1_EIP3009_MaxFeeBoundIntoNonce() public {
        uint256 amount = 1000e6;
        uint256 payerKey = 0x11;
        address payer = vm.addr(payerKey);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(0xBEE5));
        // Payer authorizes maxFee = X. Both X and Y exceed the 0.3% fee (3e6) so the
        // fee>maxFee guard passes and execution reaches the EIP-3009 transfer.
        uint256 signedMaxFee = 500e6; // X
        uint256 submittedMaxFee = 1000e6; // Y != X — operator tries to grab a higher cap
        bytes32 signedNonce = keccak256(abi.encode(payee, signedMaxFee, salt));
        bytes memory signature = _signEIP3009(payerKey, payer, address(x402), amount, validAfter, validBefore, signedNonce);
        usdc.mint(payer, amount);

        vm.prank(operator1);
        vm.expectRevert("bad signature");
        x402.settleX402Payment(payer, payee, address(usdc), amount, submittedMaxFee, validAfter, validBefore, salt, signature);
    }

    /// @notice M-1: a fee-on-transfer / deflationary EIP-3009 asset delivers less than
    ///         `amount` to the X402Facilitator. Paying out `amount - fee` would overdraw
    ///         other settlements' reserves, so the balance-delta check must revert
    ///         X402AmountMismatch.
    function test_M1_EIP3009_FeeOnTransfer_Reverts() public {
        MockDeflationaryERC3009Token feeToken = new MockDeflationaryERC3009Token();

        uint256 amount = 1000e6;
        uint256 payerKey = 0x12;
        address payer = vm.addr(payerKey);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(0xDEF1));
        uint256 maxFee = amount; // fee (3e6 at 0.3%) <= maxFee, so fee check passes
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        // Sign over the deflationary token's own EIP-712 domain (receive variant).
        bytes32 digest = feeToken.receiveAuthorizationDigest(payer, address(x402), amount, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        feeToken.mint(payer, amount);

        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.X402AmountMismatch.selector);
        x402.settleX402Payment(payer, payee, address(feeToken), amount, maxFee, validAfter, validBefore, salt, signature);
    }

    /// @notice M-1 (front-run grief): the settle path uses EIP-3009 receiveWithAuthorization,
    ///         which the token enforces with `msg.sender == to`. An attacker who observes the
    ///         payer's valid signature cannot replay it directly on the token to pull funds
    ///         into the X402Facilitator outside of a settlement — the token reverts because the
    ///         attacker is not the payee (`to` == the X402Facilitator).
    function test_M1_EIP3009_FrontRunReceiveBlocked() public {
        uint256 amount = 1000e6;
        uint256 payerKey = 0x13;
        address payer = vm.addr(payerKey);
        address attacker = address(0xBAD);
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(0xF00D));
        uint256 maxFee = amount;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        // Payer signs a valid receive authorization with to == the X402Facilitator.
        bytes memory signature =
            _signEIP3009(payerKey, payer, address(x402), amount, validAfter, validBefore, nonce);
        usdc.mint(payer, amount);

        // Attacker tries to submit the receive authorization directly on the token.
        vm.prank(attacker);
        vm.expectRevert("caller must be the payee");
        usdc.receiveWithAuthorization(
            payer, address(x402), amount, validAfter, validBefore, nonce, signature
        );
    }

    // ====================================
    // settleX402PaymentDirect (xPNTs) Tests
    // ====================================

    function test_SettleDirect_Success() public {
        uint256 amount = 500 ether;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        uint256 maxFee = (amount * 200) / 10000;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(1));
        bytes memory signature = _signX402Direct(payerKey, payer, payee, address(xpnts), amount, maxFee, validBefore, nonce);
        xpnts.mint(payer, amount);

        vm.prank(owner);
        x402.setOperatorFacilitatorFee(operator1, 200); // 2%

        vm.prank(operator1);
        bytes32 settlementId = x402.settleX402PaymentDirect(
            payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature
        );

        uint256 fee = (amount * 200) / 10000;
        assertEq(xpnts.balanceOf(payee), amount - fee);
        assertEq(x402.facilitatorEarnings(operator1, address(xpnts)), fee);
        assertTrue(settlementId != bytes32(0));
    }

    function test_SettleDirect_Replay() public {
        uint256 amount = 100 ether;
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        xpnts.mint(payer, amount * 2);
        uint256 maxFee = (amount * 30) / 10000;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(99));
        bytes memory signature = _signX402Direct(payerKey, payer, payee, address(xpnts), amount, maxFee, validBefore, nonce);

        vm.prank(operator1);
        x402.settleX402PaymentDirect(payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature);

        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402PaymentDirect(payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature);
    }

    function test_SettleDirect_Unauthorized() public {
        uint256 payerKey = 0x10;
        address payer = vm.addr(payerKey);
        uint256 amount = 100 ether;
        uint256 maxFee = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(77));
        bytes memory signature = _signX402Direct(payerKey, payer, payee, address(xpnts), amount, maxFee, validBefore, nonce);

        vm.prank(user1);
        vm.expectRevert(X402Facilitator.Unauthorized.selector);
        x402.settleX402PaymentDirect(payer, payee, address(xpnts), amount, maxFee, validBefore, nonce, signature);
    }

    // ====================================
    // P0-13: per-(asset, from, nonce) replay-protection
    // ====================================

    /// @notice The same nonce on different assets must be independent. Pre-V5.4
    ///         the global nonce mapping let an anonymous attacker pre-burn a
    ///         victim's nonce by submitting a dummy settlement on a junk asset.
    function test_Nonce_PerAssetIsolation() public {
        bytes32 salt = bytes32(uint256(0xCAFE));
        // EIP-3009 path now derives its nonce as keccak256(to, maxFee, salt). Use the
        // same effective nonce value on the direct path so "same nonce" is preserved.
        uint256 eipMaxFee = 100e6;
        bytes32 nonce = keccak256(abi.encode(payee, eipMaxFee, salt));
        uint256 payerKey = 0x40;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 100e6);
        xpnts.mint(payer, 100 ether);
        bytes memory eip3009Sig =
            _signEIP3009(payerKey, payer, address(x402), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce);

        // Burn nonce on USDC.
        vm.prank(operator1);
        x402.settleX402Payment(payer, payee, address(usdc), 100e6, eipMaxFee, 0, block.timestamp + 1 hours, salt, eip3009Sig);

        // Same nonce, same payer, different asset must still be available.
        vm.prank(operator1);
        bytes32 sid = x402.settleX402PaymentDirect(
            payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce, directSig
        );
        assertTrue(sid != bytes32(0), "same nonce on different asset must succeed");
    }

    /// @notice Same nonce, same asset, different `from` must also be independent.
    function test_Nonce_PerPayerIsolation() public {
        bytes32 salt = bytes32(uint256(0xBEEF));
        uint256 maxFee = 100e6;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        uint256 payerAKey = 0x50;
        uint256 payerBKey = 0x51;
        address payerA = vm.addr(payerAKey);
        address payerB = vm.addr(payerBKey);
        usdc.mint(payerA, 100e6);
        usdc.mint(payerB, 100e6);
        bytes memory sigA =
            _signEIP3009(payerAKey, payerA, address(x402), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory sigB =
            _signEIP3009(payerBKey, payerB, address(x402), 100e6, 0, block.timestamp + 1 hours, nonce);

        vm.prank(operator1);
        x402.settleX402Payment(payerA, payee, address(usdc), 100e6, maxFee, 0, block.timestamp + 1 hours, salt, sigA);

        vm.prank(operator1);
        bytes32 sid =
            x402.settleX402Payment(payerB, payee, address(usdc), 100e6, maxFee, 0, block.timestamp + 1 hours, salt, sigB);
        assertTrue(sid != bytes32(0), "same nonce on different payer must succeed");
    }

    /// @notice Replay on the exact (asset, from, nonce) triple must still revert.
    function test_Nonce_TripleReplayBlocked() public {
        bytes32 salt = bytes32(uint256(0xDEAD));
        uint256 maxFee = 100e6;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        uint256 payerKey = 0x60;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 200e6);
        bytes memory signature =
            _signEIP3009(payerKey, payer, address(x402), 100e6, 0, block.timestamp + 1 hours, nonce);

        vm.prank(operator1);
        x402.settleX402Payment(payer, payee, address(usdc), 100e6, maxFee, 0, block.timestamp + 1 hours, salt, signature);

        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402Payment(payer, payee, address(usdc), 100e6, maxFee, 0, block.timestamp + 1 hours, salt, signature);
    }

    /// @notice The public helper `x402NonceKey` must agree with what the
    ///         contract writes internally — SDKs depend on this.
    function test_Nonce_PublicKeyMatchesStorage() public {
        bytes32 salt = bytes32(uint256(0xBABE));
        uint256 maxFee = 100e6;
        // The contract derives the effective nonce as keccak256(to, maxFee, salt);
        // x402NonceKey must be computed over that same nonce for the assertion to hold.
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        uint256 payerKey = 0x70;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 100e6);
        bytes memory signature =
            _signEIP3009(payerKey, payer, address(x402), 100e6, 0, block.timestamp + 1 hours, nonce);

        bytes32 key = x402.x402NonceKey(address(usdc), payer, nonce);
        assertFalse(x402.x402SettlementNonces(key), "key should be unused before settle");

        vm.prank(operator1);
        x402.settleX402Payment(payer, payee, address(usdc), 100e6, maxFee, 0, block.timestamp + 1 hours, salt, signature);

        assertTrue(x402.x402SettlementNonces(key), "key should be set after settle");
    }

    /// @notice EIP-3009 path and Direct path share the SAME (asset, from, nonce)
    ///         nonce namespace inside X402Facilitator. A nonce consumed by
    ///         settleX402Payment must be rejected by settleX402PaymentDirect and
    ///         vice-versa.
    function test_Nonce_CrossPath_EIP3009ThenDirectBlocked() public {
        bytes32 salt = bytes32(uint256(0xC0FFEE));
        // EIP-3009 path consumes nonce keccak256(to, maxFee, salt); the direct path must
        // reference that exact nonce value for the cross-path block to be exercised.
        uint256 eipMaxFee = 100e6;
        bytes32 nonce = keccak256(abi.encode(payee, eipMaxFee, salt));
        uint256 payerKey = 0x80;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 200e6);
        bytes memory eip3009Sig =
            _signEIP3009(payerKey, payer, address(x402), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, nonce);

        // Step 1: consume nonce via EIP-3009 path (USDC).
        vm.prank(operator1);
        x402.settleX402Payment(payer, payee, address(usdc), 100e6, eipMaxFee, 0, block.timestamp + 1 hours, salt, eip3009Sig);

        // Step 2: same nonce, same payer, same asset via Direct path must revert.
        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402PaymentDirect(
            payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, nonce, directSig
        );
    }

    /// @notice Inverse cross-path check: Direct consumed nonce must be rejected
    ///         by the EIP-3009 path for the same (asset, from, nonce) triple.
    function test_Nonce_CrossPath_DirectThenEIP3009Blocked() public {
        bytes32 salt = bytes32(uint256(0xDECAF));
        // EIP-3009 path derives nonce keccak256(to, maxFee, salt). The direct path
        // consumes that exact nonce value first so the cross-path block is exercised.
        uint256 eipMaxFee = 100 ether;
        bytes32 nonce = keccak256(abi.encode(payee, eipMaxFee, salt));
        uint256 payerKey = 0x81;
        address payer = vm.addr(payerKey);
        xpnts.mint(payer, 200 ether);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce);

        // Step 1: consume nonce via Direct path (xPNTs).
        vm.prank(operator1);
        x402.settleX402PaymentDirect(
            payer, payee, address(xpnts), 100 ether, 0.3 ether, block.timestamp + 1 hours, nonce, directSig
        );

        // Step 2: same nonce, same payer, same asset via EIP-3009 path must revert.
        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402Payment(payer, payee, address(xpnts), 100 ether, eipMaxFee, 0, block.timestamp + 1 hours, salt, "");
    }

    /// @notice Pre-upgrade (pre-P0-13) settlements were keyed by the raw nonce
    ///         bytes32 alone. This test simulates that state by writing the legacy
    ///         slot directly, then verifying the new code refuses to reuse the nonce.
    function test_Nonce_LegacyRawNonceReplayBlocked() public {
        bytes32 salt = bytes32(uint256(0xABCDEF));
        // The contract derives the EIP-3009 effective nonce as keccak256(to, maxFee, salt).
        // Pre-seed that exact value as the legacy raw-nonce slot so the legacy guard fires.
        uint256 maxFee = 100e6;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        bytes32 directNonce = bytes32(uint256(0xABCDF0));
        uint256 payerKey = 0x82;
        address payer = vm.addr(payerKey);
        usdc.mint(payer, 100e6);
        bytes memory eip3009Sig =
            _signEIP3009(payerKey, payer, address(x402), 100e6, 0, block.timestamp + 1 hours, nonce);
        bytes memory directSig =
            _signX402Direct(payerKey, payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, directNonce);

        // Simulate a pre-P0-13 settlement: write the raw nonce as the mapping key.
        // This is exactly what the old code wrote: x402SettlementNonces[nonce] = true.
        stdstore
            .target(address(x402))
            .sig("x402SettlementNonces(bytes32)")
            .with_key(nonce)
            .checked_write(true);
        stdstore
            .target(address(x402))
            .sig("x402SettlementNonces(bytes32)")
            .with_key(directNonce)
            .checked_write(true);

        // Both settle paths must now revert even though the NEW triple-key slot is clear.
        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402Payment(payer, payee, address(usdc), 100e6, maxFee, 0, block.timestamp + 1 hours, salt, eip3009Sig);

        vm.prank(operator1);
        vm.expectRevert(X402Facilitator.NonceAlreadyUsed.selector);
        x402.settleX402PaymentDirect(
            payer, payee, address(usdc), 100e6, 0, block.timestamp + 1 hours, directNonce, directSig
        );
    }

    // ====================================
    // Facilitator Fee Admin Tests
    // ====================================

    function test_SetFacilitatorFeeBPS() public {
        vm.prank(owner);
        x402.setFacilitatorFeeBPS(100);
        assertEq(x402.facilitatorFeeBPS(), 100);
    }

    function test_SetFacilitatorFeeBPS_ExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(X402Facilitator.InvalidFee.selector);
        x402.setFacilitatorFeeBPS(501); // > 500
    }

    function test_SetFacilitatorFeeBPS_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        x402.setFacilitatorFeeBPS(100);
    }

    function test_SetOperatorFacilitatorFee() public {
        vm.prank(owner);
        x402.setOperatorFacilitatorFee(operator1, 200);
        assertEq(x402.operatorFacilitatorFees(operator1), 200);
    }

    function test_SetOperatorFacilitatorFee_ExceedsMax() public {
        vm.prank(owner);
        vm.expectRevert(X402Facilitator.InvalidFee.selector);
        x402.setOperatorFacilitatorFee(operator1, 501);
    }

    function test_GetEffectiveFacilitatorFee_OverrideTakesPrecedence() public {
        // Global default set to 30 in setUp; override to 200 for operator1.
        vm.prank(owner);
        x402.setOperatorFacilitatorFee(operator1, 200);
        assertEq(x402.getEffectiveFacilitatorFee(operator1), 200);
        // operator with no override falls back to the global default.
        assertEq(x402.getEffectiveFacilitatorFee(user1), 30);
    }

    function test_WithdrawFacilitatorEarnings_NoBalance() public {
        vm.prank(operator1);
        vm.expectRevert(abi.encodeWithSelector(X402Facilitator.InsufficientBalance.selector, 0, 1));
        x402.withdrawFacilitatorEarnings(address(usdc));
    }

    function test_WithdrawFacilitatorEarnings_Success() public {
        // Run a settlement that accrues a fee, then withdraw it.
        uint256 amount = 1000e6;
        uint256 payerKey = 0x90;
        address payer = vm.addr(payerKey);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 salt = bytes32(uint256(0xFEE));
        uint256 maxFee = amount;
        bytes32 nonce = keccak256(abi.encode(payee, maxFee, salt));
        bytes memory signature = _signEIP3009(payerKey, payer, address(x402), amount, 0, validBefore, nonce);
        usdc.mint(payer, amount);

        vm.prank(owner);
        x402.setOperatorFacilitatorFee(operator1, 100); // 1%

        vm.prank(operator1);
        x402.settleX402Payment(payer, payee, address(usdc), amount, maxFee, 0, validBefore, salt, signature);

        uint256 fee = (amount * 100) / 10000;
        assertEq(x402.facilitatorEarnings(operator1, address(usdc)), fee);

        vm.prank(operator1);
        x402.withdrawFacilitatorEarnings(address(usdc));
        assertEq(usdc.balanceOf(operator1), fee);
        assertEq(x402.facilitatorEarnings(operator1, address(usdc)), 0);
    }

    function test_Version() public {
        assertEq(x402.version(), "X402Facilitator-1.0.0");
    }
}
