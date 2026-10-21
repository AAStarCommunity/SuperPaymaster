// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @notice The SuperPaymaster-facing surface of xPNTs v2 (spec 03 §2.2).
/// @dev    SP holds exactly four privileged entry points on a v2 token. The 3.x
///         `burnFromWithOpHash` / `recordDebt` / `recordDebtWithOpHash` do not exist in v2.
interface IxPNTsTokenV2 {
    enum LockResult { OK, INSUFFICIENT, EMERGENCY, SINGLE_TX_LIMIT, INVALID_RENEWAL, CONFLICTING_LOCK, DISABLED }
    enum CreditResult { OK, NO_CREDIT, EXCEEDS_CAP, EMERGENCY, SINGLE_TX_LIMIT, CONFLICTING, DISABLED }

    function BALANCE_MODE_VERSION() external pure returns (uint16);
    function exchangeRate() external view returns (uint256);
    function maxSingleTxLimit() external view returns (uint256);
    function debts(address user) external view returns (uint256);
    function creditReservedOf(address user) external view returns (uint256);
    function effectiveCreditCap(address user) external view returns (uint256);

    function tryLockForGas(address user, bytes32 opHash, uint256 reserveAPNTs, bool spRenew)
        external returns (LockResult result, uint256 xLocked);
    function settleLocked(address user, bytes32 opHash, uint256 chargeAPNTs) external returns (uint256 xBurned);
    function tryReserveCredit(address user, bytes32 opHash, uint256 aPNTs) external returns (CreditResult result);
    function settleCredit(address user, bytes32 opHash, uint256 chargeAPNTs) external returns (uint256 debtAdded);

    // read-only mirrors used by SuperPaymaster.dryRunValidation (same code path as the writes)
    function previewLock(address spender, address user, bytes32 opHash, uint256 reserveAPNTs, bool spRenew)
        external view returns (LockResult result, uint256 xLocked);
    function previewCredit(address spender, address user, bytes32 opHash, uint256 aPNTs)
        external view returns (CreditResult result);
}
