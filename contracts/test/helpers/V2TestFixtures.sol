// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

// Shared xPNTs v2 test fixtures. Kept OUT of any *.t.sol file on purpose: a test file that
// imports another test file drags that file's Test contract into every compiler profile the
// importer needs (e.g. `registry-size`), and forge then runs the imported suite twice under
// two artifact names — which made the suite count flap between 123 and 124 (DSR D3 Low-2).

/// @dev Registry stub: COMMUNITY role for everyone; configurable credit tier.
contract MockRegistryV2 {
    mapping(address => uint256) public creditLimit;
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
    function getCreditLimit(address u) external view returns (uint256) { return creditLimit[u]; }
    function setCreditLimit(address u, uint256 v) external { creditLimit[u] = v; }
}

/// @dev Stand-in for a spender implementation (e.g. an x402 facilitator or PaymasterV4 impl).
contract DummySpender {
    function pull(address token, address from, uint256 amt) external {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), amt));
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}

/// @dev The xPNTs v2 extension is only reachable through the core's fallback; this interface
///      lets tests call it with types.
interface IExt {
    function setAutoAllowance(address spender, uint256 capAPNTs) external;
    function setUserTotalCap(uint256 capAPNTs) external;
    function setRenewalMode(uint8 mode) external;
    function disableSpenderForSelf(address spender) external;
    function enableSpenderForSelf(address spender) external;
    function requestCredit(uint256 maxCap) external;
    function revokeCredit() external;
    function releaseAndDisable(address spender, bytes32 opHash) external;
    function approveCredit(address user, uint256 cap) external;
    function queueCreditPolicy(uint8 p) external;
    function executeCreditPolicy() external;
    function proposeSP(address sp) external;
    function cancelSP() external;
    function activateSP() external;
    function emergencyRevokePaymaster() external;
    function unsetEmergencyDisabled() external;
    function proposeStandby(address s) external;
    function activateStandbyDesignation() external;
    function emergencySwitchToStandby() external;
    function proposeSpender(address s) external;
    function activateSpender(address s) external;
    function removeAutoApprovedSpender(address s) external;
    function mint(address to, uint256 amount) external;
    function repayDebt(uint256 amountXPNTs) external;
    function executeBySig(address user, uint8 kind, bytes calldata params, uint256 deadline, bytes calldata sig) external;
    function actionDigest(address user, uint8 kind, bytes calldata params, uint256 nonce, uint256 deadline) external view returns (bytes32);
}

