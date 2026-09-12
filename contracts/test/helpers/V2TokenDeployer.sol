// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";

/// @dev Minimal typed view of the xPNTs v2 extension (reached through the token's fallback).
interface IxPNTsV2Admin {
    function mint(address to, uint256 amount) external;
    function updateExchangeRate(uint256 newRate) external;
    function setMaxSingleTxLimit(uint256 newLimit) external;
    function queueCreditPolicy(uint8 p) external;
    function executeCreditPolicy() external;
    function requestCredit(uint256 maxCap) external;
    function approveCredit(address user, uint256 cap) external;
    function setAutoAllowance(address spender, uint256 capAPNTs) external;
    function setUserTotalCap(uint256 capAPNTs) external;
    function disableSpenderForSelf(address spender) external;
    function emergencyRevokePaymaster() external;
    function proposeSP(address sp) external;
    function activateSP() external;
    function repayDebt(uint256 amountXPNTs) external;
}

/**
 * @title V2TokenDeployer
 * @notice Test helper: deploy the xPNTs v2 stack and create v2 community tokens that are
 *         accepted by SuperPaymaster 5.5.0 (`configureOperator` probes BALANCE_MODE_VERSION).
 * @dev    Call from a test contract. The calling contract becomes:
 *           - owner of the AOAProtocolRegistry (it bootstraps approvals, then may seal),
 *           - FACTORY of every token created by `newToken` (so it can `mint` directly).
 *         Usage:
 *           V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(sp), address(registry));
 *           xPNTsTokenV2 tok = V2TokenDeployer.newToken(st, communityOwner, community, address(sp), 1e18);
 *           IxPNTsV2Admin(address(tok)).mint(user, 1000 ether);   // as FACTORY (the test contract)
 *           mockFactory.setToken(community, address(tok));         // SP.configureOperator factory binding
 */
library V2TokenDeployer {
    struct Stack {
        AOAProtocolRegistry aoa;
        xPNTsTokenV2Ext ext;
        xPNTsTokenV2 impl;
        GlobalTierSource tier;
    }

    /// @param sp       SuperPaymaster proxy to approve as an SP (address(0) to skip)
    /// @param registry Registry (or mock) exposing getCreditLimit(user) for the GLOBAL tier source
    function deployStack(address sp, address registry) internal returns (Stack memory st) {
        st.aoa = new AOAProtocolRegistry(address(this));
        st.tier = new GlobalTierSource(registry);
        if (sp != address(0)) st.aoa.bootstrapApprove(st.aoa.KIND_SP(), st.aoa.spKey(sp));
        st.aoa.bootstrapApprove(st.aoa.KIND_TIER_SOURCE(), address(st.tier).codehash);
        st.ext = new xPNTsTokenV2Ext(address(st.aoa));
        st.impl = new xPNTsTokenV2(address(st.aoa), address(st.ext));
    }

    /// @notice Approve an additional SP address (only before `seal`).
    function approveSP(Stack memory st, address sp) internal {
        st.aoa.bootstrapApprove(st.aoa.KIND_SP(), st.aoa.spKey(sp));
    }

    /// @notice Create a v2 token clone. `sp` becomes its genesis SuperPaymaster (S-0).
    function newToken(Stack memory st, address communityOwner, address community, address sp, uint256 rate)
        internal returns (xPNTsTokenV2 tok)
    {
        tok = xPNTsTokenV2(Clones.clone(address(st.impl)));
        tok.initialize(xPNTsTokenV2.InitConfig({
            name: "Community Points",
            symbol: "xPNT",
            communityOwner: communityOwner,
            community: community,
            communityName: "Community",
            communityENS: "community.eth",
            exchangeRate: rate,
            superPaymaster: sp,
            genesisSpender: address(0),
            tierSource: address(st.tier)
        }));
    }

    /// @notice paymasterAndData for SP 5.5.0: [pm 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
    function pmd(address sp, uint128 verifGas, uint128 postOpGas, address operator, uint256 maxRate, address token, uint8 flags)
        internal pure returns (bytes memory)
    {
        return abi.encodePacked(sp, verifGas, postOpGas, operator, maxRate, token, flags);
    }
}
