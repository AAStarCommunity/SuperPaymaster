// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";

/// @dev Same shape as SuperPaymaster.GasParams / PendingGasParams (exp/params).
struct LensGasParams { uint32 minPostOpGas; uint32 settleGasBound; uint32 cWrap; uint32 cPostop; }
struct LensPendingGasParams { uint32 minPostOpGas; uint32 settleGasBound; uint32 cWrap; uint32 cPostop; uint64 eta; }

interface ISPLensView {
    function gasParams() external view returns (LensGasParams memory current, LensPendingGasParams memory pending);
    function version() external view returns (string memory);
    function entryPoint() external view returns (IEntryPoint);
    function operators(address operator) external view returns (
        uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken,
        uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored
    );
    function userOpState(address operator, address user) external view returns (uint48 lastTimestamp, bool isBlocked);
    function isEligibleForSponsorship(address user) external view returns (bool);
    function cachedPrice() external view returns (int256 price, uint256 updatedAt, uint80 roundId, uint8 decimals);
    function priceStalenessThreshold() external view returns (uint256);
    function protocolFeeBPS() external view returns (uint256);
    function aPNTsPriceUSD() external view returns (uint256);
}

/**
 * @title SuperPaymasterLens
 * @notice Off-chain diagnostic mirror of `SuperPaymaster.validatePaymasterUserOp` (5.5.0), moved
 *         out of SP for EIP-170 (spec F1 / §5). Distinguishes the rejection paths that validation
 *         reports as an opaque SIG_FAILURE.
 * @dev    Stateless, non-upgradeable. It copies SP's internal constants, so it is bound to ONE SP
 *         version: on any other version it answers (false, VERSION_MISMATCH) instead of guessing.
 *         The user-side decision is NOT re-implemented here — it calls the token's `previewLock` /
 *         `previewCredit`, which share their decision code with `tryLockForGas` / `tryReserveCredit`.
 *         Kept in lock-step with validation by the D-layer consistency test.
 */
contract SuperPaymasterLens is IVersioned {
    bytes32 public constant EXPECTED_SP_VERSION = keccak256("SuperPaymaster-5.5.0");

    // --- copies of SuperPaymaster 5.5.0 internal constants ---
    uint256 internal constant PAYMASTER_DATA_OFFSET = 52;
    uint256 internal constant POSTOP_GAS_OFFSET = 36;
    uint256 internal constant RATE_OFFSET = 72;
    uint256 internal constant TOKEN_OFFSET = 104;
    uint256 internal constant FLAGS_OFFSET = 124;
    // exp/params: MIN_POST_OP_GAS is read from SP (`gasParams()`), not copied.
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant VALIDATION_BUFFER_BPS = 1000;
    uint8 internal constant FLAG_SP_RENEW = 1;
    uint8 internal constant FLAG_ACCOUNT_RENEW = 2;

    bytes32 public constant DRYRUN_OK                       = bytes32(0);
    bytes32 public constant DRYRUN_VERSION_MISMATCH         = bytes32("VERSION_MISMATCH");
    bytes32 public constant DRYRUN_OPERATOR_NOT_CONFIGURED  = bytes32("OPERATOR_NOT_CONFIGURED");
    bytes32 public constant DRYRUN_OPERATOR_PAUSED          = bytes32("OPERATOR_PAUSED");
    bytes32 public constant DRYRUN_USER_NOT_ELIGIBLE        = bytes32("USER_NOT_ELIGIBLE");
    bytes32 public constant DRYRUN_USER_BLOCKED             = bytes32("USER_BLOCKED");
    bytes32 public constant DRYRUN_RATE_LIMITED             = bytes32("RATE_LIMITED");
    bytes32 public constant DRYRUN_POSTOP_GAS_TOO_LOW       = bytes32("POSTOP_GAS_TOO_LOW");
    bytes32 public constant DRYRUN_TOKEN_MISMATCH           = bytes32("TOKEN_MISMATCH");
    bytes32 public constant DRYRUN_RATE_COMMITMENT_VIOLATED = bytes32("RATE_COMMITMENT_VIOLATED");
    bytes32 public constant DRYRUN_STALE_PRICE              = bytes32("STALE_PRICE");
    bytes32 public constant DRYRUN_INSUFFICIENT_BALANCE     = bytes32("INSUFFICIENT_BALANCE");
    /// @dev low byte carries the IxPNTsTokenV2.LockResult / CreditResult value
    bytes32 public constant DRYRUN_LOCK_REJECTED            = bytes32("LOCK_REJECTED");
    bytes32 public constant DRYRUN_CREDIT_REJECTED          = bytes32("CREDIT_REJECTED");
    /// @dev D5b GOV-2: global sponsorship stop (`paused()`), checked by validation before anything else.
    bytes32 public constant DRYRUN_SPONSORSHIP_PAUSED       = bytes32("SPONSORSHIP_PAUSED");

    function version() external pure override returns (string memory) {
        return "SuperPaymasterLens-1.2.0";
    }

    /// @dev D5b: `paused()` is an extension selector, reached through SP's fallback (D5b-design §2.3).
    ///      A pre-D5b 5.5.0 core has neither the selector nor a fallback → the staticcall fails and the
    ///      lens reports "not paused", which is exactly what that implementation's validation does.
    function _globallyPaused(address sp) private view returns (bool) {
        (bool ok, bytes memory ret) = sp.staticcall(abi.encodeWithSignature("paused()"));
        return ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    function _minPostOpGas(ISPLensView s) private view returns (uint256) {
        (LensGasParams memory g, ) = s.gasParams();
        return g.minPostOpGas;
    }

    /// @notice Would `sp.validatePaymasterUserOp(userOp, hash, maxCost)` sponsor this op, and if
    ///         not, why. Hard failures take precedence over the soft rate limit.
    function dryRunValidation(address sp, PackedUserOperation calldata userOp, uint256 maxCost)
        external view returns (bool ok, bytes32 reasonCode)
    {
        ISPLensView s = ISPLensView(sp);
        if (keccak256(bytes(s.version())) != EXPECTED_SP_VERSION) return (false, DRYRUN_VERSION_MISMATCH);
        if (_globallyPaused(sp)) return (false, DRYRUN_SPONSORSHIP_PAUSED);

        bytes calldata pmd = userOp.paymasterAndData;
        address operator = pmd.length < 72 ? address(0) : address(bytes20(pmd[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET + 20]));
        (uint128 opBalance, bool isConfigured, bool isPaused, address xToken, , uint48 minTxInterval, , , ) = s.operators(operator);
        if (!isConfigured) return (false, DRYRUN_OPERATOR_NOT_CONFIGURED);
        if (isPaused) return (false, DRYRUN_OPERATOR_PAUSED);
        if (!s.isEligibleForSponsorship(userOp.sender)) return (false, DRYRUN_USER_NOT_ELIGIBLE);
        if (pmd.length >= POSTOP_GAS_OFFSET + 16
            && uint128(bytes16(pmd[POSTOP_GAS_OFFSET:POSTOP_GAS_OFFSET + 16])) < _minPostOpGas(s)) {
            return (false, DRYRUN_POSTOP_GAS_TOO_LOW);
        }
        (uint48 lastTime, bool blocked) = s.userOpState(operator, userOp.sender);
        if (blocked) return (false, DRYRUN_USER_BLOCKED);
        bool rateLimited = minTxInterval > 0 && lastTime != 0
            && block.timestamp < uint256(lastTime) + uint256(minTxInterval);

        if (pmd.length < TOKEN_OFFSET + 20) return (false, DRYRUN_TOKEN_MISMATCH);
        if (address(bytes20(pmd[TOKEN_OFFSET:TOKEN_OFFSET + 20])) != xToken) return (false, DRYRUN_TOKEN_MISMATCH);
        uint8 flags = pmd.length > FLAGS_OFFSET ? uint8(pmd[FLAGS_OFFSET]) : 0;
        if (flags & (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW) == (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW)) {
            return (false, DRYRUN_TOKEN_MISMATCH);
        }
        if (IxPNTsTokenV2(xToken).exchangeRate() > abi.decode(pmd[RATE_OFFSET:RATE_OFFSET + 32], (uint256))) {
            return (false, DRYRUN_RATE_COMMITMENT_VIOLATED);
        }

        (int256 price, uint256 updatedAt, , uint8 decimals) = s.cachedPrice();
        if (updatedAt == 0 || price <= 0 || block.timestamp > updatedAt + s.priceStalenessThreshold()) {
            return (false, DRYRUN_STALE_PRICE);
        }
        uint256 a0 = Math.mulDiv(maxCost * uint256(price), 1e18, (10 ** uint256(decimals)) * s.aPNTsPriceUSD(), Math.Rounding.Ceil);
        a0 = Math.mulDiv(a0, BPS_DENOMINATOR + s.protocolFeeBPS() + VALIDATION_BUFFER_BPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
        if (uint256(opBalance) < a0) return (false, DRYRUN_INSUFFICIENT_BALANCE);

        bytes32 opHash = s.entryPoint().getUserOpHash(userOp);
        (IxPNTsTokenV2.LockResult lr, ) = IxPNTsTokenV2(xToken).previewLock(sp, userOp.sender, opHash, a0, flags & FLAG_SP_RENEW != 0);
        if (lr != IxPNTsTokenV2.LockResult.OK) {
            if (lr != IxPNTsTokenV2.LockResult.INSUFFICIENT) {
                return (false, DRYRUN_LOCK_REJECTED | bytes32(uint256(uint8(lr))));
            }
            IxPNTsTokenV2.CreditResult cr = IxPNTsTokenV2(xToken).previewCredit(sp, userOp.sender, opHash, a0);
            if (cr != IxPNTsTokenV2.CreditResult.OK) {
                return (false, DRYRUN_CREDIT_REJECTED | bytes32(uint256(uint8(cr))));
            }
        }

        if (rateLimited) return (false, DRYRUN_RATE_LIMITED);
        return (true, DRYRUN_OK);
    }
}
