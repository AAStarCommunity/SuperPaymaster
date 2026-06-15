// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import "src/interfaces/v3/IRegistry.sol";
import "../../../interfaces/IxPNTsToken.sol";
import "../../../interfaces/IxPNTsFactory.sol";
import "../../../interfaces/v3/IERC3009.sol";

/**
 * @title X402Facilitator
 * @notice Standalone x402 settlement layer extracted from SuperPaymaster (v5.4 god-split
 *         phase 1). Settles agent-to-service micropayments via two paths:
 *           - settleX402Payment:       EIP-3009 `receiveWithAuthorization` (USDC-native).
 *           - settleX402PaymentDirect: `transferFrom` over community xPNTs (auto-allowance).
 *
 * @dev This contract has ZERO SuperPaymaster-storage dependency. It only reads/calls
 *      external contracts:
 *        - Registry.hasRole(ROLE_PAYMASTER_SUPER, caller) — operator/facilitator gate.
 *        - XPNTS_FACTORY.isXPNTs(asset)                   — Direct-path asset whitelist.
 *        - IxPNTsToken(asset).approvedFacilitators(caller) — community facilitator gate.
 *        - ERC-3009 / ERC-20 token transfers.
 *      Because it lifts out cleanly there is no callback into SuperPaymaster.
 *
 * @dev Non-upgradeable (REDEPLOY release — no UUPS storage-compat constraint). Owns its
 *      own copy of the four x402 storage vars that previously lived in SuperPaymaster.
 */
contract X402Facilitator is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ====================================
    // Immutables
    // ====================================

    /// @notice Registry used for the ROLE_PAYMASTER_SUPER operator gate.
    IRegistry public immutable REGISTRY;
    /// @notice xPNTs factory used by the Direct path to whitelist assets (P0-12a).
    IxPNTsFactory public immutable XPNTS_FACTORY;

    // ====================================
    // Constants
    // ====================================

    uint256 internal constant BPS_DENOMINATOR = 10000;

    // x402 Constants
    uint256 internal constant MAX_FACILITATOR_FEE = 500; // 5% hardcap

    /// @dev EIP-712 typehash for a payer's x402 payment authorization (C-02/C-03).
    bytes32 private constant X402_AUTH_TYPEHASH = keccak256(
        "X402PaymentAuthorization(address from,address to,address asset,uint256 amount,uint256 maxFee,uint256 validBefore,bytes32 nonce)"
    );

    // ====================================
    // Storage (the 4 x402 vars moved verbatim from SuperPaymaster)
    // ====================================

    // x402 Facilitator Fees
    uint256 public facilitatorFeeBPS; // Default fee (e.g. 30 = 0.3%)
    mapping(address => uint256) public operatorFacilitatorFees; // Per-operator override
    /// @notice x402 settlement nonces, keyed by keccak256(asset, from, nonce).
    /// @dev    P0-13: keyed by the (asset, from, nonce) triple to isolate each payer's
    ///         nonce space per asset and prevent anonymous nonce pre-burn.
    mapping(bytes32 => bool) public x402SettlementNonces;
    mapping(address => mapping(address => uint256)) public facilitatorEarnings; // operator => asset => amount

    // ====================================
    // Events
    // ====================================

    event FacilitatorFeeUpdated(uint256 oldFee, uint256 newFee);
    event FacilitatorEarningsWithdrawn(address indexed operator, address indexed asset, uint256 amount);
    event X402PaymentSettled(address indexed from, address indexed to, address asset, uint256 amount, uint256 fee, bytes32 nonce);

    // ====================================
    // Errors
    // ====================================

    error Unauthorized();
    error InvalidConfiguration();
    error InsufficientBalance(uint256 available, uint256 required);
    error InvalidXPNTsToken();
    error NonceAlreadyUsed();
    error InvalidFee();
    error InvalidX402Signature();
    error X402AuthExpired();
    error X402FeeExceedsMax();
    // M-1: EIP-3009 path received less than `amount` (fee-on-transfer / deflationary asset)
    error X402AmountMismatch();

    // ====================================
    // Constructor
    // ====================================

    constructor(IRegistry registry, IxPNTsFactory factory) Ownable(msg.sender) {
        if (address(registry) == address(0) || address(factory) == address(0)) revert InvalidConfiguration();
        REGISTRY = registry;
        XPNTS_FACTORY = factory;
    }

    function version() external pure returns (string memory) {
        return "X402Facilitator-1.0.0";
    }

    // ====================================
    // Role gate
    // ====================================

    /// @dev Reverts with Unauthorized if caller is not a registered ROLE_PAYMASTER_SUPER member.
    function _requireSuperOperatorRole() internal view {
        if (!REGISTRY.hasRole(keccak256("PAYMASTER_SUPER"), msg.sender)) revert Unauthorized();
    }

    // ====================================
    // Admin Setters
    // ====================================

    /// @notice Set default facilitator fee BPS (Owner only)
    function setFacilitatorFeeBPS(uint256 _fee) external onlyOwner {
        if (_fee > MAX_FACILITATOR_FEE) revert InvalidFee();
        uint256 oldFee = facilitatorFeeBPS;
        facilitatorFeeBPS = _fee;
        emit FacilitatorFeeUpdated(oldFee, _fee);
    }

    /// @notice Set per-operator facilitator fee override (Owner only)
    function setOperatorFacilitatorFee(address operator, uint256 _fee) external onlyOwner {
        if (_fee > MAX_FACILITATOR_FEE) revert InvalidFee();
        operatorFacilitatorFees[operator] = _fee;
    }

    /// @notice P1-39: Returns the effective facilitator fee for an operator.
    /// @dev Per-operator override takes precedence over the global default.
    function getEffectiveFacilitatorFee(address operator) external view returns (uint256) {
        uint256 override_ = operatorFacilitatorFees[operator];
        return override_ != 0 ? override_ : facilitatorFeeBPS;
    }

    /// @notice Withdraw accumulated facilitator earnings
    function withdrawFacilitatorEarnings(address asset) external nonReentrant {
        uint256 amount = facilitatorEarnings[msg.sender][asset];
        if (amount == 0) revert InsufficientBalance(0, 1);
        delete facilitatorEarnings[msg.sender][asset];
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit FacilitatorEarningsWithdrawn(msg.sender, asset, amount);
    }

    // ====================================
    // x402 Payment Settlement
    // ====================================

    /// @notice Compose the per-(asset, from, nonce) replay-protection key.
    /// @dev    P0-13: must match exactly what the EIP-3009 / direct callers
    ///         submit on-chain. Keep this function `pure` so off-chain SDKs can
    ///         mirror the encoding via the contract ABI.
    function x402NonceKey(address asset, address from, bytes32 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(asset, from, nonce));
    }

    /// @notice Shared validation and fee logic for both x402 settle paths.
    function _validateX402AndComputeFee(
        address asset, address from, uint256 amount, bytes32 nonce
    ) internal returns (uint256 fee) {
        _requireSuperOperatorRole();

        // Guard against replay of settlements made BEFORE the P0-13 upgrade.
        // Pre-V5.4 the mapping was keyed by the raw nonce bytes32 value alone;
        // if that slot is already set the nonce was consumed under the old scheme
        // and must not be reused under the new triple-key scheme.
        if (x402SettlementNonces[nonce]) revert NonceAlreadyUsed();

        bytes32 key = x402NonceKey(asset, from, nonce);
        if (x402SettlementNonces[key]) revert NonceAlreadyUsed();
        x402SettlementNonces[key] = true;

        uint256 effectiveFeeBPS = operatorFacilitatorFees[msg.sender];
        if (effectiveFeeBPS == 0) effectiveFeeBPS = facilitatorFeeBPS;
        fee = (amount * effectiveFeeBPS) / BPS_DENOMINATOR;
        if (fee > 0) facilitatorEarnings[msg.sender][asset] += fee;
    }

    /// @dev Domain separator bound to THIS contract. Recomputed each call so it stays
    ///      correct across chain forks. (Non-upgradeable: address(this) is stable.)
    function _x402DomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("X402Facilitator"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    /// @dev C-02/C-03: require the payer (`from`) to have signed an EIP-712 authorization
    ///      binding the exact recipient, asset, amount, fee cap, expiry and nonce. Without
    ///      it a community-approved facilitator could pull any holder's xPNTs (auto-allowance)
    ///      to a caller-chosen recipient with no payer consent. SignatureCheckerLib accepts
    ///      both EOA and ERC-1271 (AirAccount passkey / smart-account) signatures.
    function _verifyX402Auth(
        address from, address to, address asset, uint256 amount,
        uint256 maxFee, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(abi.encode(
            X402_AUTH_TYPEHASH, from, to, asset, amount, maxFee, validBefore, nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _x402DomainSeparator(), structHash));
        if (!SignatureCheckerLib.isValidSignatureNowCalldata(from, digest, signature)) {
            revert InvalidX402Signature();
        }
    }

    /// @notice Settle x402 payment via EIP-3009 receiveWithAuthorization (USDC native path)
    /// @dev    C-03 + M-1: both the final recipient `to` AND the payer-approved fee cap
    ///         `maxFee` are bound into the EIP-3009 nonce
    ///         (`nonce = keccak256(to, maxFee, salt)`). The payer signs the EIP-3009
    ///         authorization over that nonce, so an operator that swaps `to` OR raises
    ///         `maxFee` produces a different nonce and the EIP-3009 signature no longer
    ///         recovers `from` — the transfer reverts. This reuses the payer's existing
    ///         token-level signature; no second signature. Without the `maxFee` binding the
    ///         payer's EIP-3009 signature only authorizes moving `amount` and places no cap
    ///         on the operator's facilitator fee (up to MAX_FACILITATOR_FEE), which the
    ///         payer never consented to (M-1).
    /// @dev    M-1: the path assumes the contract receives exactly `amount`. A fee-on-transfer
    ///         / deflationary asset delivers less, so paying out `amount - fee` would overpay
    ///         `to` from other settlements' reserves. We measure the actual delta and revert
    ///         if it is short. EIP-3009 stablecoins (USDC) are not deflationary, so this only
    ///         rejects assets that violate the path's amount==received assumption.
    /// @dev    M-1 (front-run grief): we use `receiveWithAuthorization`, NOT
    ///         `transferWithAuthorization`. The EIP-3009 spec requires the token to enforce
    ///         `msg.sender == to` for the receive variant, so only this contract (the `to`)
    ///         can submit the authorization. With the transfer variant, anyone who observes
    ///         the payer's signature could call the token directly to pull `amount` into this
    ///         contract outside of a settlement, burning the token-side nonce and leaving the
    ///         funds stranded (the real settle would then revert). The receive variant closes
    ///         that grief vector. EIP-3009's two variants share a nonce namespace but sign
    ///         distinct typehashes (Transfer- vs ReceiveWithAuthorization); since the payer
    ///         signs ONLY the receive typehash, the same signature cannot be replayed against
    ///         `transferWithAuthorization` to burn the nonce (recovery would yield a different
    ///         signer), so both nonce-burning paths are closed.
    /// @dev    settlementId uses abi.encode (fixed-size fields) for a collision-free id.
    function settleX402Payment(
        address from, address to, address asset, uint256 amount, uint256 maxFee,
        uint256 validAfter, uint256 validBefore, bytes32 salt, bytes calldata signature
    ) external nonReentrant returns (bytes32 settlementId) {
        bytes32 nonce = keccak256(abi.encode(to, maxFee, salt));
        uint256 fee = _validateX402AndComputeFee(asset, from, amount, nonce);
        if (fee > maxFee) revert X402FeeExceedsMax();
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IERC3009(asset).receiveWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, signature);
        if (IERC20(asset).balanceOf(address(this)) - balBefore < amount) revert X402AmountMismatch();
        settlementId = _payoutX402(from, to, asset, amount, fee, nonce);
    }

    /// @dev Shared x402 payout tail for both settle paths: push `amount - fee` to the
    ///      final recipient, emit the settlement event, and derive the collision-free id.
    function _payoutX402(
        address from, address to, address asset, uint256 amount, uint256 fee, bytes32 nonce
    ) internal returns (bytes32) {
        IERC20(asset).safeTransfer(to, amount - fee);
        emit X402PaymentSettled(from, to, asset, amount, fee, nonce);
        return keccak256(abi.encode(from, to, asset, amount, nonce));
    }

    /// @notice Settle x402 payment via direct transferFrom (xPNTs only)
    /// @dev    Direct path is restricted to xPNTs tokens registered in
    ///         `XPNTS_FACTORY` AND to facilitators explicitly approved by the
    ///         community that owns the xPNTs. Without these gates:
    ///         - any ERC20 the payer ever did `approve(facilitator, MAX)` on
    ///           (e.g. USDC for x402 standard payments) could be drained by
    ///           a compromised facilitator (xPNTs carry an in-contract
    ///           firewall + per-tx cap; arbitrary ERC20s do not);
    ///         - any single global facilitator compromise would blast across
    ///           every community's xPNTs.
    ///         For non-xPNTs settlement use `settleX402Payment` (EIP-3009).
    /// @dev    settlementId uses abi.encode (not encodePacked), matching the
    ///         x402NonceKey encoding to avoid hash-collision with variable-length types.
    /// @dev    P0-12a: enforce `XPNTS_FACTORY.isXPNTs(asset)` gate.
    /// @dev    P0-12b (D4): enforce community-side `approvedFacilitators`
    ///         whitelist on the xPNTs token. Community owner toggles via
    ///         `xPNTsToken.add/removeApprovedFacilitator`. AAStar's default
    ///         facilitator is NOT auto-approved at deploy — each community
    ///         decides explicitly.
    /// @dev    Nonce and asset whitelist: _validateX402AndComputeFee writes the
    ///         nonce before the isXPNTs check executes. However, if the call
    ///         reverts (e.g. InvalidXPNTsToken), EVM revert semantics roll back
    ///         the nonce write — so the nonce is NOT consumed on failure.
    function settleX402PaymentDirect(
        address from, address to, address asset, uint256 amount,
        uint256 maxFee, uint256 validBefore, bytes32 nonce, bytes calldata signature
    ) external nonReentrant returns (bytes32 settlementId) {
        // C-02/C-03: the payer must have signed this exact (from,to,asset,amount,maxFee,nonce).
        // xPNTs carry no token-level authorization (the facilitator holds an auto-allowance over
        // every holder), so the consent gate lives here at the facilitator level.
        if (block.timestamp > validBefore) revert X402AuthExpired();
        _verifyX402Auth(from, to, asset, amount, maxFee, validBefore, nonce, signature);

        // Validate fee/nonce/role. The signature is checked first so an attacker cannot
        // pre-burn a victim's nonce without a valid payer authorization.
        uint256 fee = _validateX402AndComputeFee(asset, from, amount, nonce);
        if (fee > maxFee) revert X402FeeExceedsMax();

        // P0-12a: Direct settle is xPNTs-only. Reject any asset that is not
        // a token deployed by the configured xPNTs factory.
        if (!XPNTS_FACTORY.isXPNTs(asset)) revert InvalidXPNTsToken();

        // P0-12b: facilitator must be explicitly approved by THIS community's
        // xPNTs. `_validateX402AndComputeFee` already established msg.sender
        // has ROLE_PAYMASTER_SUPER; this per-token whitelist narrows the
        // trust surface from "any global facilitator" to "this community's
        // choice". Distinct from `autoApprovedSpenders` (transferFrom
        // firewall): this gates settle-call invocation, not allowance.
        if (!IxPNTsToken(asset).approvedFacilitators(msg.sender)) {
            revert Unauthorized();
        }

        // C-02: `from` is not arbitrary — it must have signed the X402PaymentAuthorization
        // verified by _verifyX402Auth above, so the signature IS its authorization.
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        settlementId = _payoutX402(from, to, asset, amount, fee, nonce);
    }
}
