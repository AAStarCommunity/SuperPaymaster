// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";
import { IxPNTsTokenV2 } from "./IxPNTsTokenV2.sol";
import { xPNTsV2Base } from "./xPNTsV2Base.sol";

/**
 * @title xPNTsTokenV2 (CORE)
 * @notice Community gas token with a BOUNDED auto-allowance and validation-time escrow.
 * @dev    Holds ERC20 plus every function that can run inside an ERC-4337 validation frame
 *         (`tryLockForGas`, `tryReserveCredit` for the staked SuperPaymaster; `renewForSelf`
 *         for the account) and every settlement path. Everything else is served by
 *         `EXTENSION` through `fallback()` (DELEGATECALL, shared storage — see xPNTsV2Base).
 *
 *         ERC-7562: validation-frame functions WRITE only sender-associated slots (user is the
 *         innermost key), READ globals only from the staked paymaster frame (STO-033), never use
 *         TIMESTAMP/NUMBER, never touch `_reentrancyStatus`, and never DELEGATECALL.
 */
contract xPNTsTokenV2 is xPNTsV2Base, IVersioned {
    uint16 public constant BALANCE_MODE_VERSION = 1;

    /// @notice Administration / settings / views implementation (xPNTsTokenV2Ext).
    address public immutable EXTENSION;

    struct InitConfig {
        string name;
        string symbol;
        address communityOwner;
        address community;
        string communityName;
        string communityENS;
        uint256 exchangeRate;
        address superPaymaster;   // S-0 genesis SP (0 = none yet)
        address genesisSpender;   // A-10 ② optional (e.g. PaymasterV4), per-user default cap 0
        address tierSource;       // R4-H5 default credit tier source
    }

    constructor(address protocolRegistry, address extension) xPNTsV2Base(protocolRegistry) {
        if (extension == address(0)) revert InvalidAddress(address(0));
        EXTENSION = extension;
        _disableInitializers();
    }

    function version() external pure override returns (string memory) {
        return "XPNTs-4.0.0";
    }

    // ---------------------------------------------------------------------
    // Extension routing
    // ---------------------------------------------------------------------

    fallback() external {
        address ext = EXTENSION;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ---------------------------------------------------------------------
    // Initialisation (S-0, A-9, A-10, R4-H5)
    // ---------------------------------------------------------------------

    /// @notice Clone initializer, called once by the factory. A-9: the factory is NOT a spender.
    function initialize(InitConfig calldata c) external initializer {
        if (c.communityOwner == address(0) || c.community == address(0)) revert InvalidAddress(address(0));
        FACTORY = msg.sender;
        communityOwner = c.communityOwner;
        community = c.community;
        communityName = c.communityName;
        communityENS = c.communityENS;
        _tokenName = c.name;
        _tokenSymbol = c.symbol;
        uint256 rate = c.exchangeRate > 0 ? c.exchangeRate : 1 ether;
        if (rate < _RATE_MIN || rate > _RATE_MAX) revert ExchangeRateOutOfRange(rate, _RATE_MIN, _RATE_MAX);
        exchangeRate = rate;
        maxSingleTxLimit = 5_000 ether;
        spenderDailyCapTokens = 50_000 ether;

        if (c.superPaymaster != address(0)) {
            // S-0: effective immediately (no holders yet); never a spender (A-3).
            if (!PROTOCOL_REGISTRY.isApprovedSP(c.superPaymaster)) revert NotApproved(c.superPaymaster);
            SUPERPAYMASTER_ADDRESS = c.superPaymaster;
            historicalSP[c.superPaymaster] = true;
            emit SuperPaymasterAddressUpdated(address(0), c.superPaymaster);
        }
        if (c.genesisSpender != address(0)) {
            if (!PROTOCOL_REGISTRY.isApprovedImpl(PROTOCOL_REGISTRY.KIND_SPENDER(), c.genesisSpender)) {
                revert NotApproved(c.genesisSpender);
            }
            autoApprovedSpenders[c.genesisSpender] = true;
            emit AutoApprovedSpenderAdded(c.genesisSpender);
        }
        if (c.tierSource != address(0)) {
            if (!PROTOCOL_REGISTRY.isApprovedImpl(PROTOCOL_REGISTRY.KIND_TIER_SOURCE(), c.tierSource)) {
                revert NotApproved(c.tierSource);
            }
            creditTierSource = c.tierSource;
        }
    }

    // ---------------------------------------------------------------------
    // Allowance & third-party spending (A-2, A-3, B-7)
    // ---------------------------------------------------------------------

    /// @notice Explicit approval plus the remaining auto-allowance (live rate, rounded down).
    ///         B-7: saturating add. The live-rate figure is NOT a settlement promise: SP settles
    ///         at the lock-time ratio (D-12). SP (current or historical) can never pull: reads 0.
    function allowance(address owner, address spender) public view override returns (uint256) {
        if (spender == SUPERPAYMASTER_ADDRESS || historicalSP[spender]) return 0;
        uint256 e = super.allowance(owner, spender);
        if (!autoApprovedSpenders[spender] || emergencyDisabled || spenderDisabled[spender][owner]) return e;
        uint256 remX = (_remaining(spender, owner) * exchangeRate) / 1e18;
        unchecked {
            uint256 s = e + remX;
            return s < e ? type(uint256).max : s;
        }
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendV2(from, msg.sender, value, to);
        _transfer(from, to, value);
        return true;
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != from) _spendV2(from, msg.sender, amount, msg.sender);
        _burn(from, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @dev Explicit approval first; any remainder comes from the bounded auto-allowance (A-2),
    ///      enforcing the firewall, emergency stop, user disable, single-tx limit, per-(user,
    ///      spender) cap, per-user total, and the per-spender daily cap.
    function _spendV2(address owner, address spender, uint256 value, address to) internal {
        if (spender == SUPERPAYMASTER_ADDRESS || historicalSP[spender]) revert SPCannotTransfer(); // A-3
        uint256 e = super.allowance(owner, spender);
        if (e >= value) {
            if (e != type(uint256).max) _approve(owner, spender, e - value, false);
            return;
        }
        if (!autoApprovedSpenders[spender]) revert BurnExceedsAllowance();
        if (emergencyDisabled) revert EmergencyStop();
        if (spenderDisabled[spender][owner]) revert SpenderIsDisabled();
        if (to != spender) revert UnauthorizedRecipient();
        uint256 rest = value - e;
        if (e != 0) _approve(owner, spender, 0, false);
        uint256 a = Math.mulDiv(rest, 1e18, _requireRate(), Math.Rounding.Ceil);
        if (a > maxSingleTxLimit) revert SingleTxLimitExceeded();
        if (_remaining(spender, owner) < a) revert AutoAllowanceExceeded();
        _auto[spender][owner].used += uint128(a);
        _budget[owner].used += uint128(a);
        _checkAndConsumeRateLimit(spender, rest);
    }

    /// @dev P0-8 rolling 24 h cap for NON-SP spenders (never reached from a validation frame).
    function _checkAndConsumeRateLimit(address spender, uint256 amount) internal {
        SpenderRateLimit storage rl = spenderRateLimit[spender];
        if (rl.windowStart == 0 || block.timestamp >= uint256(rl.windowStart) + 1 days) {
            rl.windowStart = uint64(block.timestamp);
            rl.dailyBurnTotal = 0;
            emit SpenderRateLimitWindowReset(spender, rl.windowStart);
        }
        uint256 newTotal = uint256(rl.dailyBurnTotal) + amount;
        uint256 cap = spenderDailyCapOverride[spender];
        if (cap == 0) cap = spenderDailyCapTokens;
        if (newTotal > cap) {
            revert SpenderDailyCapExceeded(spender, amount, cap > rl.dailyBurnTotal ? cap - rl.dailyBurnTotal : 0);
        }
        rl.dailyBurnTotal = uint128(newTotal);
    }

    // ---------------------------------------------------------------------
    // Escrow — SuperPaymaster entry points (X3, L-*, A-5, E-*)
    // ---------------------------------------------------------------------

    /// @dev Pure decision shared by `tryLockForGas` and `previewLock` (dryRun/lens consistency).
    ///      Evaluates as if `spender` (the SP) were the caller. Reads only; never writes.
    function _lockDecision(address spender, address user, bytes32 opHash, uint256 reserveAPNTs, bool spRenew)
        internal view
        returns (IxPNTsTokenV2.LockResult r, uint256 x, uint256 usedA, uint256 usedB, uint256 locked)
    {
        if (emergencyDisabled) return (IxPNTsTokenV2.LockResult.EMERGENCY, 0, 0, 0, 0);
        if (spenderDisabled[spender][user]) return (IxPNTsTokenV2.LockResult.DISABLED, 0, 0, 0, 0);
        if (reserveAPNTs > maxSingleTxLimit) return (IxPNTsTokenV2.LockResult.SINGLE_TX_LIMIT, 0, 0, 0, 0);
        if (_locks[opHash][user].locker != address(0)) return (IxPNTsTokenV2.LockResult.CONFLICTING_LOCK, 0, 0, 0, 0);
        locked = lockedOf[user];
        if (spRenew) {
            if (renewalMode[user] != MODE_SP_K || autoRenewUsed[user] >= K
                || locked != 0 || creditReservedOf[user] != 0) {
                return (IxPNTsTokenV2.LockResult.INVALID_RENEWAL, 0, 0, 0, 0);
            }
        }
        usedA = spRenew ? 0 : _auto[spender][user].used;
        usedB = spRenew ? 0 : _budget[user].used;
        if (_remainingWith(spender, user, usedA, usedB) < reserveAPNTs) {
            return (IxPNTsTokenV2.LockResult.INSUFFICIENT, 0, 0, 0, 0);
        }
        x = Math.mulDiv(reserveAPNTs, exchangeRate, 1e18, Math.Rounding.Ceil);
        uint256 bal = balanceOf(user);
        if (bal < locked || bal - locked < x) return (IxPNTsTokenV2.LockResult.INSUFFICIENT, 0, 0, 0, 0);
        r = IxPNTsTokenV2.LockResult.OK;
    }

    /// @notice Read-only mirror of `tryLockForGas` for dryRun/lens (same code path).
    function previewLock(address spender, address user, bytes32 opHash, uint256 reserveAPNTs, bool spRenew)
        external view returns (IxPNTsTokenV2.LockResult r, uint256 x)
    {
        (r, x, , , ) = _lockDecision(spender, user, opHash, reserveAPNTs, spRenew);
    }

    /// @dev Validation phase. Returns a typed result; writes NOTHING unless it succeeds (L-1).
    ///      An SP-relayed renewal is precomputed and committed only on success (§9 A-5/L-1).
    function tryLockForGas(address user, bytes32 opHash, uint256 reserveAPNTs, bool spRenew)
        external returns (IxPNTsTokenV2.LockResult, uint256)
    {
        if (msg.sender != SUPERPAYMASTER_ADDRESS || msg.sender == address(0)) revert Unauthorized(msg.sender);
        (IxPNTsTokenV2.LockResult r, uint256 x, uint256 usedA, uint256 usedB, uint256 locked) =
            _lockDecision(msg.sender, user, opHash, reserveAPNTs, spRenew);
        if (r != IxPNTsTokenV2.LockResult.OK) return (r, 0);

        // ---- commit ----
        if (spRenew) {
            autoRenewUsed[user] += 1;
            emit AllowanceRenewed(user, msg.sender, true);
        }
        _auto[msg.sender][user].used = uint128(usedA + reserveAPNTs);
        _budget[user].used = uint128(usedB + reserveAPNTs);
        lockedOf[user] = locked + x;
        _locks[opHash][user] = LockRec(uint128(x), uint128(reserveAPNTs), msg.sender);
        _setLive(user, opHash, LOCK_SEED, true);
        emit LockCreated(user, opHash, msg.sender, x, reserveAPNTs);
        return (IxPNTsTokenV2.LockResult.OK, x);
    }

    /// @dev postOp. L-3: recorded locker only, inside the original transaction only, no
    ///      external calls, bounded gas, CEI. Cannot fail on balance: balance ≥ lockedOf ≥
    ///      xLocked ≥ xBurned (B-1 §10.1 ②). Proceeds during an emergency (E-2).
    function settleLocked(address user, bytes32 opHash, uint256 chargeAPNTs)
        external returns (uint256 xBurned)
    {
        LockRec memory r = _locks[opHash][user];
        if (r.locker == address(0)) revert NoLock();
        if (msg.sender != r.locker) revert Unauthorized(msg.sender);
        if (!_isLive(user, opHash, LOCK_SEED)) revert NotLive();

        uint256 charge = chargeAPNTs > r.aReserved ? r.aReserved : chargeAPNTs;
        xBurned = r.aReserved == 0 ? 0 : Math.mulDiv(charge, r.xLocked, r.aReserved, Math.Rounding.Ceil);
        if (xBurned > r.xLocked) xBurned = r.xLocked;

        delete _locks[opHash][user];
        lockedOf[user] -= r.xLocked;
        _setLive(user, opHash, LOCK_SEED, false);
        _refund(r.locker, user, r.aReserved - charge);
        usedOpHashes[opHash] = true;
        if (xBurned != 0) _burn(user, xBurned);
        emit LockSettled(user, opHash, xBurned, charge);
    }

    /// @notice L-4: after the original transaction, anyone may release a lock whose postOp never
    ///         settled it (a postOp revert rolls back the user's execution, §2.4). Full refund.
    function releaseStaleLock(address user, bytes32 opHash) external {
        _releaseLock(user, opHash);
    }

    /// @dev Pure decision shared by `tryReserveCredit` and `previewCredit`.
    function _creditDecision(address spender, address user, bytes32 opHash, uint256 aPNTs)
        internal view returns (IxPNTsTokenV2.CreditResult)
    {
        if (emergencyDisabled) return IxPNTsTokenV2.CreditResult.EMERGENCY;
        if (spenderDisabled[spender][user]) return IxPNTsTokenV2.CreditResult.DISABLED;
        if (aPNTs > maxSingleTxLimit) return IxPNTsTokenV2.CreditResult.SINGLE_TX_LIMIT;
        if (_creditRes[opHash][user].locker != address(0)) return IxPNTsTokenV2.CreditResult.CONFLICTING;
        uint256 cap = effectiveCreditCap(user);
        if (cap == 0) return IxPNTsTokenV2.CreditResult.NO_CREDIT;
        if (debts[user] + creditReservedOf[user] + aPNTs > cap) return IxPNTsTokenV2.CreditResult.EXCEEDS_CAP;
        return IxPNTsTokenV2.CreditResult.OK;
    }

    /// @notice Read-only mirror of `tryReserveCredit` for dryRun/lens (same code path).
    function previewCredit(address spender, address user, bytes32 opHash, uint256 aPNTs)
        external view returns (IxPNTsTokenV2.CreditResult)
    {
        return _creditDecision(spender, user, opHash, aPNTs);
    }

    /// @dev Validation phase. C-1: `debts + reserved + amount ≤ effectiveCreditCap`.
    function tryReserveCredit(address user, bytes32 opHash, uint256 aPNTs)
        external returns (IxPNTsTokenV2.CreditResult)
    {
        if (msg.sender != SUPERPAYMASTER_ADDRESS || msg.sender == address(0)) revert Unauthorized(msg.sender);
        IxPNTsTokenV2.CreditResult r = _creditDecision(msg.sender, user, opHash, aPNTs);
        if (r != IxPNTsTokenV2.CreditResult.OK) return r;
        creditReservedOf[user] += aPNTs;
        _creditRes[opHash][user] = CreditRes(uint128(aPNTs), msg.sender);
        _setLive(user, opHash, CREDIT_SEED, true);
        emit CreditReserved(user, opHash, msg.sender, aPNTs);
        return IxPNTsTokenV2.CreditResult.OK;
    }

    /// @dev C-2: consumes only the admitted reservation; never rereads policy or tier (C-4, I6-ii).
    function settleCredit(address user, bytes32 opHash, uint256 chargeAPNTs)
        external returns (uint256 debtAdded)
    {
        CreditRes memory r = _creditRes[opHash][user];
        if (r.locker == address(0)) revert NoLock();
        if (msg.sender != r.locker) revert Unauthorized(msg.sender);
        if (!_isLive(user, opHash, CREDIT_SEED)) revert NotLive();
        debtAdded = chargeAPNTs > r.amount ? r.amount : chargeAPNTs;
        delete _creditRes[opHash][user];
        creditReservedOf[user] -= r.amount;
        _setLive(user, opHash, CREDIT_SEED, false);
        usedOpHashes[opHash] = true;
        debts[user] += debtAdded;
        emit CreditSettled(user, opHash, debtAdded);
    }

    function releaseStaleCredit(address user, bytes32 opHash) external {
        _releaseCredit(user, opHash);
    }

    // ---------------------------------------------------------------------
    // Credit ceiling (C-0) — the single canonical computation
    // ---------------------------------------------------------------------

    function effectiveCreditCap(address user) public view returns (uint256) {
        uint8 p = creditPolicy;
        if (p == POLICY_OFF) return 0;
        address sp = SUPERPAYMASTER_ADDRESS;
        if (sp != address(0) && spenderDisabled[sp][user]) return 0;
        CreditReq memory r = creditReq[user];
        if (r.epoch != policyEpoch || r.requestedCap == 0) return 0;
        uint256 cap = r.requestedCap;
        if (cap > PROTOCOL_CREDIT_CEILING) cap = PROTOCOL_CREDIT_CEILING;
        uint256 tier = _tierOf(user);
        if (tier < cap) cap = tier;
        if (p == POLICY_MANUAL && r.approvedCap < cap) cap = r.approvedCap;
        return cap;
    }

    /// @dev STATICCALL with a gas cap; a revert or malformed return yields 0 (fail closed).
    function _tierOf(address user) internal view returns (uint256) {
        address src = creditTierSource;
        if (src == address(0)) return 0;
        (bool ok, bytes memory ret) = src.staticcall{gas: TIER_SOURCE_GAS}(
            abi.encodeWithSelector(bytes4(keccak256("tierOf(address,address)")), community, user)
        );
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256));
    }

    // ---------------------------------------------------------------------
    // Option A renewal (D-18) — callable from an account's validateUserOp
    // ---------------------------------------------------------------------

    /// @notice Touches ONLY slots keyed by msg.sender: `lockedOf`, `creditReservedOf`,
    ///         `_auto[spender][me]`, `_budget[me]`, `autoRenewUsed` (an unstaked account frame
    ///         has no STO-033 read privilege, so no global slot is read).
    function renewForSelf(address spender) external {
        _renew(msg.sender, spender);
    }

    // ---------------------------------------------------------------------
    // Views used by SP / wallets
    // ---------------------------------------------------------------------

    function autoAllowance(address user, address spender) external view returns (uint256 cap, uint256 used) {
        Allow memory a = _auto[spender][user];
        cap = a.set ? a.cap : _defaultCap(spender);
        used = a.used;
    }

    function userTotal(address user) external view returns (uint256 cap, uint256 used) {
        Allow memory b = _budget[user];
        cap = b.set ? b.cap : USER_TOTAL_DEFAULT;
        used = b.used;
    }

    function lockOf(bytes32 opHash, address user) external view returns (LockRec memory) {
        return _locks[opHash][user];
    }

    function creditReservationOf(bytes32 opHash, address user) external view returns (CreditRes memory) {
        return _creditRes[opHash][user];
    }
}
