// SPDX-License-Identifier: Apache-2.0
// 08b_WireUpToken.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsToken.sol";

/// @dev xPNTs v2 SP state machine (spec 03 §2.5), served by the token's extension.
interface IxPNTsV2Wire {
    function BALANCE_MODE_VERSION() external view returns (uint16);
    function SUPERPAYMASTER_ADDRESS() external view returns (address);
    function pendingSP() external view returns (address);
    function pendingSPEta() external view returns (uint64);
    function proposeSP(address newSP) external;
    function activateSP() external;
}

/**
 * @notice Bind a token to a SuperPaymaster.
 * @dev    D5.2 (SuperPaymaster 5.5.0). Two token families, two very different operations:
 *
 *         - xPNTs v2 (an SP OPERATOR token): SP is NEVER a spender (A-3) — the token only records
 *           which SP may lock/settle. A token issued by xPNTsFactoryV2 already has its genesis SP
 *           (S-0) and needs nothing here. Changing it is the 48 h state machine: the first run
 *           `proposeSP(sp)` (community owner), a run after the ETA `activateSP()`. Both require
 *           the SP proxy to be approved in AOAProtocolRegistry. `setSuperPaymasterAddress` /
 *           `addAutoApprovedSpender` do not exist on v2.
 *         - 3.x xPNTsToken: only the protocol aPNTs (SP's APNTS_TOKEN, the operator DEPOSIT
 *           asset) is still a 3.x token that SP touches. It keeps the 3.x binding so operators can
 *           `deposit` into SP. SP 5.5.0 never burns through it (burnFromWithOpHash is gone from
 *           SP), so the old "auto-approve SP for burnFromWithOpHash" step is not repeated.
 *
 *         Every branch reads back the state it claims.
 */
contract Deploy08b_WireUpToken is Script {
    function run(address tokenAddr, address superPaymasterAddr) external {
        require(tokenAddr != address(0), "token address cannot be zero.");
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");

        uint256 pk = vm.envUint("PRIVATE_KEY");

        (bool isV2Probe, bytes memory ret) = tokenAddr.staticcall(abi.encodeWithSignature("BALANCE_MODE_VERSION()"));
        bool isV2 = isV2Probe && ret.length == 32 && abi.decode(ret, (uint16)) == 1;

        if (isV2) {
            IxPNTsV2Wire t = IxPNTsV2Wire(tokenAddr);
            if (t.SUPERPAYMASTER_ADDRESS() == superPaymasterAddr) {
                console.log("v2 token already bound to SP (genesis or activated):", tokenAddr);
                return;
            }
            vm.startBroadcast(pk);
            if (t.pendingSP() != superPaymasterAddr) {
                t.proposeSP(superPaymasterAddr);
                console.log("v2 token: proposeSP queued; re-run after ETA to activate:", uint256(t.pendingSPEta()));
            } else if (block.timestamp >= t.pendingSPEta()) {
                t.activateSP();
                console.log("v2 token: activateSP executed");
            } else {
                console.log("v2 token: proposal pending until", uint256(t.pendingSPEta()));
            }
            vm.stopBroadcast();
            require(
                t.SUPERPAYMASTER_ADDRESS() == superPaymasterAddr || t.pendingSP() == superPaymasterAddr,
                "08b read-back: SP neither active nor pending on v2 token"
            );
            return;
        }

        // 3.x token (the protocol aPNTs deposit asset)
        vm.startBroadcast(pk);
        if (xPNTsToken(tokenAddr).SUPERPAYMASTER_ADDRESS() != superPaymasterAddr) {
            xPNTsToken(tokenAddr).setSuperPaymasterAddress(superPaymasterAddr);
        }
        vm.stopBroadcast();
        require(xPNTsToken(tokenAddr).SUPERPAYMASTER_ADDRESS() == superPaymasterAddr, "08b read-back: 3.x SP binding");
        console.log("3.x token (aPNTs deposit asset) bound to SuperPaymaster:", tokenAddr);
    }
}
