// SPDX-License-Identifier: Apache-2.0
// 11_ConfigureOperator.s.sol
pragma solidity ^0.8.26;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

/**
 * @notice Configure the deployer (a registered COMMUNITY + PAYMASTER_SUPER) as an SP operator.
 * @dev    D5.2 (SuperPaymaster 5.5.0). `configureOperator(token, treasury)` — the exchange rate is
 *         read from the token at runtime (the old third argument no longer exists, so the previous
 *         version did not compile). The token MUST be the caller's xPNTs v2 token issued by the
 *         factory SP is wired to (`SP.xpntsFactory()` = xPNTsFactoryV2); SP probes
 *         BALANCE_MODE_VERSION and reverts InvalidXPNTsToken otherwise. Pass that v2 token, NOT
 *         the protocol aPNTs.
 */
contract Deploy11_ConfigureOperator is Script {
    function run(address superPaymasterAddr, address xpntsV2TokenAddr) external {
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");
        require(xpntsV2TokenAddr != address(0), "operator token address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        SuperPaymaster sp = SuperPaymaster(payable(superPaymasterAddr));
        _preflight(sp, xpntsV2TokenAddr, deployer);
        console.log("Configuring Operator in SuperPaymaster with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);
        sp.configureOperator(xpntsV2TokenAddr, deployer); // treasury = deployer
        vm.stopBroadcast();

        (, bool cfg,, address tok,,, address treasury,,) = sp.operators(deployer);
        require(cfg && tok == xpntsV2TokenAddr && treasury == deployer, "11 read-back: operator config");
        console.log("Successfully configured deployer as an operator in SuperPaymaster.");
    }

    function _preflight(SuperPaymaster sp, address token, address operator) internal view {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("BALANCE_MODE_VERSION()"));
        require(ok && ret.length == 32 && abi.decode(ret, (uint16)) == 1, "11: token is not an xPNTs v2 token");
        (bool ok2, bytes memory ret2) =
            sp.xpntsFactory().staticcall(abi.encodeWithSignature("getTokenAddress(address)", operator));
        require(ok2 && abi.decode(ret2, (address)) == token, "11: token was not issued to this operator by SP's factory");
    }
}
