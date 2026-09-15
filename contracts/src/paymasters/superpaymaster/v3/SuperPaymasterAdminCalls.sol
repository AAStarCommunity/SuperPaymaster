// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import { SuperPaymaster } from "./SuperPaymaster.sol";
import { SuperPaymasterAdmin } from "./SuperPaymasterAdmin.sol";
import { SuperPaymasterStorage } from "./SuperPaymasterStorage.sol";
import "../../../interfaces/ISuperPaymaster.sol";

/**
 * @title SuperPaymasterAdminCalls
 * @notice Solidity-side typing sugar for the D5b split: `using SuperPaymasterAdminCalls for SuperPaymaster;`
 *         lets code holding a `SuperPaymaster` reference call the functions served by the
 *         SuperPaymasterAdmin extension (`sp.setGuardian(x)`, `sp.gasParams()`, …) exactly as before
 *         the split. Every wrapper is an ordinary external call to the SAME address — the proxy —
 *         whose core fallback routes it to the extension; nothing here changes routing or adds
 *         authority. (Off-chain callers use the merged ABI `abis/SuperPaymaster.full.json`.)
 * @dev    Internal functions only: this library is never deployed. `vm.prank` / `vm.expectRevert`
 *         apply to the external call inside the wrapper as they would to a direct call.
 */
library SuperPaymasterAdminCalls {
    function _x(SuperPaymaster sp) private pure returns (SuperPaymasterAdmin) {
        return SuperPaymasterAdmin(address(sp));
    }

    // --- GOV-2 ---
    function setGuardian(SuperPaymaster sp, address g) internal { _x(sp).setGuardian(g); }
    function setOperatorPaused(SuperPaymaster sp, address operator, bool isPaused) internal { _x(sp).setOperatorPaused(operator, isPaused); }
    function setGlobalPaused(SuperPaymaster sp, bool isPaused) internal { _x(sp).setGlobalPaused(isPaused); }

    // --- operators ---
    function configureOperator(SuperPaymaster sp, address token, address treasury_) internal { _x(sp).configureOperator(token, treasury_); }
    function setOperatorLimits(SuperPaymaster sp, uint48 minTxInterval) internal { _x(sp).setOperatorLimits(minTxInterval); }
    function updateBlockedStatus(SuperPaymaster sp, address operator, address[] memory users, bool[] memory statuses) internal {
        _x(sp).updateBlockedStatus(operator, users, statuses);
    }
    function updateSBTStatus(SuperPaymaster sp, address user, bool status) internal { _x(sp).updateSBTStatus(user, status); }

    // --- aPNTs token swap ---
    function APNTS_TOKEN_TIMELOCK(SuperPaymaster sp) internal view returns (uint256) { return _x(sp).APNTS_TOKEN_TIMELOCK(); }
    function setAPNTsToken(SuperPaymaster sp, address t) internal { _x(sp).setAPNTsToken(t); }
    function cancelAPNTsTokenChange(SuperPaymaster sp) internal { _x(sp).cancelAPNTsTokenChange(); }
    function executeAPNTsTokenChange(SuperPaymaster sp) internal { _x(sp).executeAPNTsTokenChange(); }

    // --- owner parameters ---
    function setAPNTSPrice(SuperPaymaster sp, uint256 p) internal { _x(sp).setAPNTSPrice(p); }
    function setProtocolFee(SuperPaymaster sp, uint256 bps) internal { _x(sp).setProtocolFee(bps); }
    function setTreasury(SuperPaymaster sp, address t) internal { _x(sp).setTreasury(t); }
    function setXPNTsFactory(SuperPaymaster sp, address f) internal { _x(sp).setXPNTsFactory(f); }
    function setAgentRegistries(SuperPaymaster sp, address identity, address reputation) internal { _x(sp).setAgentRegistries(identity, reputation); }
    function withdrawProtocolRevenue(SuperPaymaster sp, address to, uint256 amount) internal { _x(sp).withdrawProtocolRevenue(to, amount); }

    // --- GOV-5 gas parameters ---
    function queueGasParams(SuperPaymaster sp, uint32 minPostOpGas, uint32 settleGasBound, uint32 cWrap, uint32 cPostop) internal {
        _x(sp).queueGasParams(minPostOpGas, settleGasBound, cWrap, cPostop);
    }
    function executeGasParams(SuperPaymaster sp) internal { _x(sp).executeGasParams(); }
    function cancelGasParams(SuperPaymaster sp) internal { _x(sp).cancelGasParams(); }
    function gasParams(SuperPaymaster sp) internal view
        returns (SuperPaymasterStorage.GasParams memory current, SuperPaymasterStorage.PendingGasParams memory pending)
    {
        return _x(sp).gasParams();
    }

    // --- price oracle ---
    function EMERGENCY_TIMELOCK(SuperPaymaster sp) internal view returns (uint256) { return _x(sp).EMERGENCY_TIMELOCK(); }
    function isChainlinkStale(SuperPaymaster sp) internal view returns (bool) { return _x(sp).isChainlinkStale(); }
    function priceValidUntil(SuperPaymaster sp) internal view returns (uint48) { return _x(sp).priceValidUntil(); }
    function emergencySetPrice(SuperPaymaster sp, int256 p) internal { _x(sp).emergencySetPrice(p); }
    function cancelEmergencyPrice(SuperPaymaster sp) internal { _x(sp).cancelEmergencyPrice(); }
    function executeEmergencyPrice(SuperPaymaster sp) internal { _x(sp).executeEmergencyPrice(); }
    function updatePriceDVT(SuperPaymaster sp, int256 price, uint256 updatedAt, bytes memory proof, uint8 chainlinkRecovered) internal {
        _x(sp).updatePriceDVT(price, updatedAt, proof, chainlinkRecovered);
    }
    function updatePrice(SuperPaymaster sp) internal { _x(sp).updatePrice(); }

    // --- credit view ---
    function getAvailableCredit(SuperPaymaster sp, address user, address token) internal view returns (uint256) {
        return _x(sp).getAvailableCredit(user, token);
    }

    // --- slash / reputation / BLS ---
    function queueSlash(SuperPaymaster sp, address operator) internal { _x(sp).queueSlash(operator); }
    function primeBlsSlashCooldown(SuperPaymaster sp) internal { _x(sp).primeBlsSlashCooldown(); }
    function cancelSlash(SuperPaymaster sp, address operator) internal { _x(sp).cancelSlash(operator); }
    function isSlashPending(SuperPaymaster sp, address operator) internal view returns (bool) { return _x(sp).isSlashPending(operator); }
    function slashOperator(SuperPaymaster sp, address operator, ISuperPaymaster.SlashLevel level, uint256 penalty, string memory reason) internal {
        _x(sp).slashOperator(operator, level, penalty, reason);
    }
    function updateReputation(SuperPaymaster sp, address operator, uint256 score) internal { _x(sp).updateReputation(operator, score); }
    function executeSlashWithBLS(SuperPaymaster sp, address operator, ISuperPaymaster.SlashLevel level, bytes memory proof) internal {
        _x(sp).executeSlashWithBLS(operator, level, proof);
    }
    function initBLSAggregator(SuperPaymaster sp, address bls) internal { _x(sp).initBLSAggregator(bls); }
    function queueBLSAggregator(SuperPaymaster sp, address bls) internal { _x(sp).queueBLSAggregator(bls); }
    function applyBLSAggregator(SuperPaymaster sp) internal { _x(sp).applyBLSAggregator(); }
    function getSlashHistory(SuperPaymaster sp, address operator) internal view returns (ISuperPaymaster.SlashRecord[] memory) {
        return _x(sp).getSlashHistory(operator);
    }
    function getSlashCount(SuperPaymaster sp, address operator) internal view returns (uint256) { return _x(sp).getSlashCount(operator); }
    function getLatestSlash(SuperPaymaster sp, address operator) internal view returns (ISuperPaymaster.SlashRecord memory) {
        return _x(sp).getLatestSlash(operator);
    }
}
