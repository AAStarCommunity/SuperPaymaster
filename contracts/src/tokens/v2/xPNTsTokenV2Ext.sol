// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import { SignatureChecker } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/SignatureChecker.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import "../../interfaces/IERC1363.sol";
import { xPNTsV2Base } from "./xPNTsV2Base.sol";

/// @dev CC-28 view surface of the factory (unchanged from 3.x).
interface IxPNTsFactoryCapV2 {
    function aPNTsPriceUSD() external view returns (uint256);
    function industryScaleUSD(string calldata category) external view returns (uint256);
    function capRatioBps() external view returns (uint16);
    function tokenCategory(address token) external view returns (string memory);
    function SUPERPAYMASTER() external view returns (address);
}

/// @dev CC-28 view of SuperPaymaster's operator stake.
interface ISPStakeViewV2 {
    function operators(address operator) external view returns (
        uint128 aPNTsBalance, bool isConfigured, bool isPaused, address xPNTsToken,
        uint32 reputation, uint48 minTxInterval, address treasury, uint256 totalSpent, uint256 totalTxSponsored
    );
}

/**
 * @title xPNTsTokenV2Ext (EXTENSION)
 * @notice Administration, user settings, relayed actions and CC-28 views of xPNTs v2.
 * @dev    Reached ONLY via xPNTsTokenV2's fallback (DELEGATECALL): every function here runs
 *         against the clone's storage, `msg.sender` is the original caller, and `address(this)`
 *         is the clone. Nothing here may be called from a validation frame. Calling this
 *         contract directly only touches its own (unused) storage.
 */
contract xPNTsTokenV2Ext is xPNTsV2Base {
    uint256 public constant MAX_SINGLE_TX_LIMIT_CAP = 50_000 ether;
    uint256 public constant EXCHANGE_RATE_MIN = 1e14;
    uint256 public constant EXCHANGE_RATE_MAX = 1e22;
    uint256 public constant EXCHANGE_RATE_DELTA_BPS = 2000;
    uint256 public constant EXCHANGE_RATE_COOLDOWN = 1 hours;
    uint256 private constant BPS = 10_000;

    uint8 public constant ACT_RENEW = 1;          // (address spender)
    uint8 public constant ACT_SET_ALLOWANCE = 2;  // (address spender, uint256 cap)
    uint8 public constant ACT_SET_TOTAL = 3;      // (uint256 cap)
    uint8 public constant ACT_SET_MODE = 4;       // (uint8 mode)
    uint8 public constant ACT_DISABLE = 5;        // (address spender)
    uint8 public constant ACT_ENABLE = 6;         // (address spender)
    uint8 public constant ACT_REQUEST_CREDIT = 7; // (uint256 maxCap)
    uint8 public constant ACT_REVOKE_CREDIT = 8;  // ()

    bytes32 public constant ACTION_TYPEHASH =
        keccak256("V2Action(address user,uint8 kind,bytes params,uint256 nonce,uint256 deadline)");

    constructor(address protocolRegistry) xPNTsV2Base(protocolRegistry) {
        _disableInitializers();
    }

    // =====================================================================
    // User settings (R2) — direct, or relayed with a signature
    // =====================================================================

    function setAutoAllowance(address spender, uint256 capAPNTs) external { _setAllowance(msg.sender, spender, capAPNTs); }
    function setUserTotalCap(uint256 capAPNTs) external { _setTotal(msg.sender, capAPNTs); }
    function setRenewalMode(uint8 mode) external { _setMode(msg.sender, mode); }
    function disableSpenderForSelf(address spender) external { _setDisabled(msg.sender, spender, true); }
    function enableSpenderForSelf(address spender) external { _setDisabled(msg.sender, spender, false); }
    function requestCredit(uint256 maxCapAPNTs) external { _requestCredit(msg.sender, maxCapAPNTs); }
    function revokeCredit() external { _requestCredit(msg.sender, 0); }

    /// @notice E-4: disable `spender` first, then release this opHash's stale lock and/or credit
    ///         reservation. Reverts as a whole (disable included) if a record is still live.
    function releaseAndDisable(address spender, bytes32 opHash) external {
        _setDisabled(msg.sender, spender, true);
        _releaseLock(msg.sender, opHash);
        _releaseCredit(msg.sender, opHash);
    }

    /// @notice Relayed R2 action (D-13 recovery path). `sig` is verified with SignatureChecker
    ///         (EOA or ERC-1271) OUTSIDE any validation frame, so 1271 has no ERC-7562 constraint.
    function executeBySig(address user, uint8 kind, bytes calldata params, uint256 deadline, bytes calldata sig)
        external
    {
        if (block.timestamp > deadline) revert SignatureExpired();
        uint256 nonce = actionNonce[user]++;
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(ACTION_TYPEHASH, user, kind, keccak256(params), nonce, deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(user, digest, sig)) revert InvalidSignature();
        if (kind == ACT_RENEW) _renew(user, abi.decode(params, (address)));
        else if (kind == ACT_SET_ALLOWANCE) { (address s, uint256 c) = abi.decode(params, (address, uint256)); _setAllowance(user, s, c); }
        else if (kind == ACT_SET_TOTAL) _setTotal(user, abi.decode(params, (uint256)));
        else if (kind == ACT_SET_MODE) _setMode(user, abi.decode(params, (uint8)));
        else if (kind == ACT_DISABLE) _setDisabled(user, abi.decode(params, (address)), true);
        else if (kind == ACT_ENABLE) _setDisabled(user, abi.decode(params, (address)), false);
        else if (kind == ACT_REQUEST_CREDIT) _requestCredit(user, abi.decode(params, (uint256)));
        else if (kind == ACT_REVOKE_CREDIT) _requestCredit(user, 0);
        else revert UnknownAction(kind);
    }

    /// @notice EIP-712 digest a wallet signs for `executeBySig` (convenience for SDK/tests).
    function actionDigest(address user, uint8 kind, bytes calldata params, uint256 nonce, uint256 deadline)
        external view returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(ACTION_TYPEHASH, user, kind, keccak256(params), nonce, deadline)));
    }

    /// @dev A-8: the SP cap cannot go below the floor (emergency disable is a separate switch).
    function _setAllowance(address user, address spender, uint256 cap) internal {
        if (spender == address(0)) revert InvalidAddress(address(0));
        if (cap > PROTOCOL_MAX_CAP) revert AboveCeiling();
        if (spender == SUPERPAYMASTER_ADDRESS && cap < SP_CAP_FLOOR) revert BelowFloor();
        Allow storage a = _auto[spender][user];
        a.cap = uint120(cap);
        a.set = true;
        emit AutoAllowanceSet(user, spender, cap);
    }

    function _setTotal(address user, uint256 cap) internal {
        if (cap > PROTOCOL_MAX_CAP) revert AboveCeiling();
        if (cap < SP_CAP_FLOOR) revert BelowFloor();
        Allow storage b = _budget[user];
        b.cap = uint120(cap);
        b.set = true;
        emit UserTotalCapSet(user, cap);
    }

    function _setMode(address user, uint8 mode) internal {
        if (mode > MODE_ACCOUNT_ONLY) revert InvalidParam();
        renewalMode[user] = mode;
        emit RenewalModeSet(user, mode);
    }

    function _setDisabled(address user, address spender, bool disabled) internal {
        if (spender == address(0)) revert InvalidAddress(address(0));
        spenderDisabled[spender][user] = disabled;
        emit SpenderDisabledByUser(user, spender, disabled);
    }

    /// @dev R-12: a user-authorised AMOUNT bound to the current policy epoch; clears any prior
    ///      approval (§9 epoch rules). `maxCap == 0` revokes (affects new reservations only).
    function _requestCredit(address user, uint256 maxCap) internal {
        if (maxCap > PROTOCOL_CREDIT_CEILING) revert AboveCeiling();
        creditReq[user] = CreditReq(uint112(maxCap), 0, policyEpoch);
        emit CreditRequested(user, maxCap, policyEpoch);
    }

    // =====================================================================
    // Credit governance (C-3, C-5, MANUAL approval)
    // =====================================================================

    /// @notice MANUAL: approval is a CEILING (never a fixed amount) on a current-epoch request.
    function approveCredit(address user, uint256 capAPNTs) external onlyCommunityOwner {
        CreditReq storage r = creditReq[user];
        if (r.epoch != policyEpoch || r.requestedCap == 0) revert InvalidParam();
        uint256 c = capAPNTs > r.requestedCap ? r.requestedCap : capAPNTs;
        r.approvedCap = uint112(c);
        emit CreditApproved(user, c, policyEpoch);
    }

    function queueCreditPolicy(uint8 p) external onlyCommunityOwner {
        if (p > POLICY_AUTO || p == creditPolicy) revert InvalidParam(); // no-op switches rejected (§9)
        pendingPolicy = p;
        hasPendingPolicy = true;
        pendingPolicyEta = uint64(block.timestamp + TIMELOCK);
        emit CreditPolicyQueued(p, pendingPolicyEta);
    }

    function executeCreditPolicy() external {
        if (!hasPendingPolicy) revert NothingPending();
        if (block.timestamp < pendingPolicyEta) revert TimelockActive(pendingPolicyEta);
        creditPolicy = pendingPolicy;
        hasPendingPolicy = false;
        policyEpoch += 1; // C-3: every earlier request/approval becomes invalid
        emit CreditPolicyExecuted(creditPolicy, policyEpoch);
    }

    function cancelCreditPolicy() external onlyCommunityOwner {
        if (!hasPendingPolicy) revert NothingPending();
        hasPendingPolicy = false;
        emit CreditPolicyCancelled();
    }

    function queueTierSource(address s) external onlyCommunityOwner {
        if (s == address(0) || s == creditTierSource) revert InvalidParam();
        if (!PROTOCOL_REGISTRY.isApprovedImpl(PROTOCOL_REGISTRY.KIND_TIER_SOURCE(), s)) revert NotApproved(s);
        pendingTierSource = s;
        pendingTierSourceEta = uint64(block.timestamp + TIMELOCK);
        emit TierSourceQueued(s, pendingTierSourceEta);
    }

    function executeTierSource() external {
        address s = pendingTierSource;
        if (s == address(0)) revert NothingPending();
        if (block.timestamp < pendingTierSourceEta) revert TimelockActive(pendingTierSourceEta);
        if (!PROTOCOL_REGISTRY.isApprovedImpl(PROTOCOL_REGISTRY.KIND_TIER_SOURCE(), s)) revert NotApproved(s);
        creditTierSource = s;
        pendingTierSource = address(0);
        policyEpoch += 1; // §9: a source switch requires fresh user consent
        emit TierSourceExecuted(s, policyEpoch);
    }

    /// @notice User repays own debt by burning xPNTs (floor conversion; cannot over-repay).
    function repayDebt(uint256 amountXPNTs) external {
        uint256 currentDebt = debts[msg.sender];
        if (amountXPNTs == 0) return;
        if (currentDebt == 0) revert NoDebtToRepay();
        if (balanceOf(msg.sender) < amountXPNTs) revert BurnExceedsBalance();
        uint256 repaid = (amountXPNTs * 1e18) / _requireRate();
        if (repaid == 0) return;
        if (repaid > currentDebt) revert RepayExceedsDebt();
        debts[msg.sender] = currentDebt - repaid;
        _burn(msg.sender, amountXPNTs);
        emit DebtRepaid(msg.sender, repaid, debts[msg.sender]);
    }

    // =====================================================================
    // SP address state machine (§2.5, S-1 … S-7; S-0 is in the core initializer)
    // =====================================================================

    /// @notice S-1. Community priority: a factory proposal never overrides a community one,
    ///         and the factory cannot propose during an emergency.
    function proposeSP(address newSP) external {
        bool byFactory;
        if (msg.sender == communityOwner) {
            byFactory = false;
        } else if (msg.sender == FACTORY && FACTORY != address(0)) {
            if (emergencyDisabled) revert Unauthorized(msg.sender);
            if (pendingSP != address(0) && !pendingSPByFactory) revert Unauthorized(msg.sender);
            byFactory = true;
        } else {
            revert Unauthorized(msg.sender);
        }
        if (newSP == address(0) || newSP == SUPERPAYMASTER_ADDRESS || newSP == emergencyRevokedAddress) {
            revert InvalidAddress(newSP);
        }
        if (!PROTOCOL_REGISTRY.isApprovedSP(newSP)) revert NotApproved(newSP);
        pendingSP = newSP;
        pendingSPEta = uint64(block.timestamp + TIMELOCK);
        pendingSPByFactory = byFactory;
        emit SPProposed(newSP, pendingSPEta, byFactory);
    }

    /// @notice S-2.
    function cancelSP() external {
        address p = pendingSP;
        if (p == address(0)) revert NothingPending();
        if (msg.sender != communityOwner && !(msg.sender == FACTORY && pendingSPByFactory)) {
            revert Unauthorized(msg.sender);
        }
        pendingSP = address(0);
        emit SPProposalCancelled(p);
    }

    /// @notice S-3. During an emergency only a community-originated (≥48 h public) proposal
    ///         may activate; never auto-clears the emergency.
    function activateSP() external {
        address p = pendingSP;
        if (p == address(0)) revert NothingPending();
        if (block.timestamp < pendingSPEta) revert TimelockActive(pendingSPEta);
        if (p == emergencyRevokedAddress) revert InvalidAddress(p);
        if (emergencyDisabled && pendingSPByFactory) revert Unauthorized(msg.sender);
        if (!PROTOCOL_REGISTRY.isApprovedSP(p)) revert NotApproved(p);
        _setCurrentSP(p);
    }

    /// @notice S-4. Also cancels a factory-originated pending proposal.
    function emergencyRevokePaymaster() external onlyCommunityOwner {
        if (emergencyDisabled) return;
        emergencyDisabled = true;
        emergencyRevokedAddress = SUPERPAYMASTER_ADDRESS;
        if (pendingSP != address(0) && pendingSPByFactory) {
            emit SPProposalCancelled(pendingSP);
            pendingSP = address(0);
        }
        emit EmergencyDisabledSet(msg.sender);
    }

    /// @notice S-5a.
    function proposeStandby(address s) external onlyCommunityOwner {
        if (s == address(0) || s == SUPERPAYMASTER_ADDRESS || s == emergencyRevokedAddress) revert InvalidAddress(s);
        if (!PROTOCOL_REGISTRY.isApprovedSP(s)) revert NotApproved(s);
        pendingStandby = s;
        pendingStandbyEta = uint64(block.timestamp + TIMELOCK);
        emit StandbyProposed(s, pendingStandbyEta);
    }

    /// @notice S-5b. Designation grants NO privilege and does not mark historicalSP.
    function activateStandbyDesignation() external {
        address s = pendingStandby;
        if (s == address(0)) revert NothingPending();
        if (block.timestamp < pendingStandbyEta) revert TimelockActive(pendingStandbyEta);
        if (!PROTOCOL_REGISTRY.isApprovedSP(s)) revert NotApproved(s);
        standbySP = s;
        pendingStandby = address(0);
        pendingStandbyEta = 0;
        emit StandbyDesignated(s);
    }

    /// @notice S-6.
    function emergencySwitchToStandby() external onlyCommunityOwner {
        address s = standbySP;
        if (!emergencyDisabled) revert Unauthorized(msg.sender);
        if (s == address(0) || s == emergencyRevokedAddress) revert InvalidAddress(s);
        if (!PROTOCOL_REGISTRY.isApprovedSP(s)) revert NotApproved(s);
        standbySP = address(0);
        _setCurrentSP(s);
    }

    /// @notice S-7.
    function unsetEmergencyDisabled() external onlyCommunityOwner {
        if (!emergencyDisabled) return;
        if (SUPERPAYMASTER_ADDRESS == emergencyRevokedAddress) revert RecoveryNotComplete();
        emergencyDisabled = false;
        emit EmergencyDisabledCleared(msg.sender);
    }

    function _setCurrentSP(address sp) internal {
        address old = SUPERPAYMASTER_ADDRESS;
        SUPERPAYMASTER_ADDRESS = sp;
        historicalSP[sp] = true;
        pendingSP = address(0);
        emit SuperPaymasterAddressUpdated(old, sp);
    }

    // =====================================================================
    // Spender management (X4, X5, B-7)
    // =====================================================================

    function proposeSpender(address spender) external onlyCommunityOwner {
        if (spender == address(0) || spender == SUPERPAYMASTER_ADDRESS || historicalSP[spender]) {
            revert InvalidAddress(spender);
        }
        if (!PROTOCOL_REGISTRY.isApprovedImpl(PROTOCOL_REGISTRY.KIND_SPENDER(), spender)) revert NotApproved(spender);
        uint64 eta = uint64(block.timestamp + TIMELOCK);
        spenderActivatesAt[spender] = eta;
        emit SpenderProposed(spender, eta);
    }

    function activateSpender(address spender) external {
        uint64 eta = spenderActivatesAt[spender];
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TimelockActive(eta);
        if (historicalSP[spender]) revert InvalidAddress(spender);
        if (!PROTOCOL_REGISTRY.isApprovedImpl(PROTOCOL_REGISTRY.KIND_SPENDER(), spender)) revert NotApproved(spender);
        delete spenderActivatesAt[spender];
        autoApprovedSpenders[spender] = true; // B-7: a re-added spender's counters are kept
        emit AutoApprovedSpenderAdded(spender);
    }

    /// @notice Immediate removal (safe direction). Counters are kept (B-7).
    function removeAutoApprovedSpender(address spender) external onlyCommunityOwner {
        autoApprovedSpenders[spender] = false;
        delete spenderActivatesAt[spender];
        emit AutoApprovedSpenderRemoved(spender);
    }

    // =====================================================================
    // Community administration (retained from 3.x)
    // =====================================================================

    function mint(address to, uint256 amount) external {
        if (msg.sender != FACTORY && msg.sender != communityOwner) revert Unauthorized(msg.sender);
        if (to == address(0)) revert InvalidAddress(to);
        _mint(to, amount);
    }

    function updateExchangeRate(uint256 newRate) external {
        if (msg.sender != FACTORY && msg.sender != communityOwner) revert Unauthorized(msg.sender);
        if (newRate == 0) revert ExchangeRateCannotBeZero();
        if (newRate < EXCHANGE_RATE_MIN || newRate > EXCHANGE_RATE_MAX) {
            revert ExchangeRateOutOfRange(newRate, EXCHANGE_RATE_MIN, EXCHANGE_RATE_MAX);
        }
        if (exchangeRateUpdatedAt != 0 && block.timestamp < exchangeRateUpdatedAt + EXCHANGE_RATE_COOLDOWN) {
            revert ExchangeRateCooldownActive();
        }
        uint256 oldRate = exchangeRate;
        uint256 lower = oldRate * (BPS - EXCHANGE_RATE_DELTA_BPS) / BPS;
        uint256 upper = oldRate * (BPS + EXCHANGE_RATE_DELTA_BPS) / BPS;
        if (newRate < lower || newRate > upper) revert ExchangeRateDeltaTooLarge(newRate, oldRate, EXCHANGE_RATE_DELTA_BPS);
        exchangeRate = newRate;
        exchangeRateUpdatedAt = block.timestamp;
        emit ExchangeRateUpdated(oldRate, newRate);
    }

    function setMaxSingleTxLimit(uint256 newLimit) external onlyCommunityOwner {
        if (newLimit == 0 || newLimit > MAX_SINGLE_TX_LIMIT_CAP) revert InvalidParam();
        emit MaxSingleTxLimitUpdated(maxSingleTxLimit, newLimit);
        maxSingleTxLimit = newLimit;
    }

    function setSpenderDailyCap(uint256 newCap) external onlyCommunityOwner {
        if (newCap > type(uint128).max) revert InvalidParam();
        emit SpenderDailyCapUpdated(spenderDailyCapTokens, newCap);
        spenderDailyCapTokens = newCap;
    }

    function setSpenderDailyCapFor(address spender, uint256 newCap) external onlyCommunityOwner {
        if (spender == address(0)) revert InvalidAddress(spender);
        if (newCap > type(uint128).max) revert InvalidParam();
        emit SpenderDailyCapForUpdated(spender, spenderDailyCapOverride[spender], newCap);
        spenderDailyCapOverride[spender] = newCap;
    }

    function addApprovedFacilitator(address facilitator) external onlyCommunityOwner {
        if (facilitator == address(0) || facilitator == communityOwner) revert InvalidAddress(facilitator);
        approvedFacilitators[facilitator] = true;
        emit FacilitatorApproved(facilitator);
    }

    function removeApprovedFacilitator(address facilitator) external onlyCommunityOwner {
        approvedFacilitators[facilitator] = false;
        emit FacilitatorRemoved(facilitator);
    }

    function renounceFactory() external onlyCommunityOwner {
        FACTORY = address(0);
    }

    function transferCommunityOwnership(address newOwner) external onlyCommunityOwner {
        if (newOwner == address(0)) revert InvalidAddress(newOwner);
        emit CommunityOwnerUpdated(communityOwner, newOwner);
        communityOwner = newOwner;
    }

    function setIssuanceCap(uint256 newCap) external onlyCommunityOwner {
        emit IssuanceCapUpdated(issuanceCap, newCap);
        issuanceCap = newCap;
    }

    // =====================================================================
    // CC-28 over-issue model (reads `community`, not the transferable communityOwner)
    // =====================================================================

    function _categoryKey() internal view returns (string memory) {
        address f = FACTORY;
        if (f == address(0)) return "default";
        string memory c = IxPNTsFactoryCapV2(f).tokenCategory(address(this));
        return bytes(c).length == 0 ? "default" : c;
    }

    function issuedValueUSD() public view returns (uint256) {
        uint256 rate = exchangeRate;
        address f = FACTORY;
        if (rate == 0 || f == address(0) || totalSupply() == 0) return 0;
        return Math.mulDiv(totalSupply(), IxPNTsFactoryCapV2(f).aPNTsPriceUSD(), rate, Math.Rounding.Ceil);
    }

    function backingValueUSD() public view returns (uint256) {
        address f = FACTORY;
        if (f == address(0)) return 0;
        address sp = IxPNTsFactoryCapV2(f).SUPERPAYMASTER();
        if (sp == address(0)) return 0;
        (uint128 staked, bool isConfigured, , address linkedToken, , , , , ) = ISPStakeViewV2(sp).operators(community);
        if (!isConfigured || linkedToken != address(this) || staked == 0) return 0;
        return Math.mulDiv(uint256(staked), IxPNTsFactoryCapV2(f).aPNTsPriceUSD(), 1e18);
    }

    function effectiveCapUSD() public view returns (uint256) {
        address f = FACTORY;
        if (f == address(0)) return 0;
        IxPNTsFactoryCapV2 fc = IxPNTsFactoryCapV2(f);
        return Math.mulDiv(fc.industryScaleUSD(_categoryKey()), fc.capRatioBps(), 10_000) + backingValueUSD();
    }

    function isOverIssued() external view returns (bool) {
        if (issuanceCap != 0 && totalSupply() > issuanceCap) return true;
        if (FACTORY == address(0)) return totalSupply() > 0;
        return issuedValueUSD() > effectiveCapUSD();
    }

    // =====================================================================
    // ERC-1363 push transfer
    // =====================================================================

    function transferAndCall(address to, uint256 amount) external returns (bool) {
        return _transferAndCall(to, amount, "");
    }

    function transferAndCall(address to, uint256 amount, bytes calldata data) external returns (bool) {
        return _transferAndCall(to, amount, data);
    }

    function _transferAndCall(address to, uint256 amount, bytes memory data) internal returns (bool) {
        require(_reentrancyStatus != 2, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = 2;
        _transfer(msg.sender, to, amount);
        if (to.code.length != 0) {
            try IERC1363Receiver(to).onTransferReceived(msg.sender, msg.sender, amount, data) returns (bytes4 r) {
                require(r == IERC1363Receiver.onTransferReceived.selector, "ERC1363: transfer to non-receiver");
            } catch {
                revert("ERC1363: transfer to non-receiver");
            }
        }
        _reentrancyStatus = 1;
        return true;
    }

    function getMetadata() external view returns (
        string memory, string memory, string memory, string memory, address
    ) {
        return (name(), symbol(), communityName, communityENS, communityOwner);
    }
}
