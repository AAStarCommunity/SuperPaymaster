// SPDX-License-Identifier: Apache-2.0
// 11_1_ConfigureBreadOperator.s.sol
pragma solidity ^0.8.26;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

/**
 * @notice Anni (Bread community owner) configures her SP operator.
 * @dev    D5.2 (SuperPaymaster 5.5.0): two-argument `configureOperator(token, treasury)`; the token
 *         must be Anni's xPNTs v2 token issued by SP's factory (xPNTsFactoryV2) — a 3.x bPNTs is
 *         rejected with InvalidXPNTsToken. The previous three-argument call did not compile.
 */
contract Deploy11_1_ConfigureBreadOperator is Script {
    function run(address superPaymasterAddr, address bPNTsV2TokenAddr) external {
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");
        require(bPNTsV2TokenAddr != address(0), "bPNTs token address cannot be zero.");

        uint256 anniPrivateKey = vm.envUint("PRIVATE_KEY_ANNI");
        address anniAddr = vm.addr(anniPrivateKey);
        SuperPaymaster sp = SuperPaymaster(payable(superPaymasterAddr));

        (bool ok, bytes memory ret) = bPNTsV2TokenAddr.staticcall(abi.encodeWithSignature("BALANCE_MODE_VERSION()"));
        require(ok && ret.length == 32 && abi.decode(ret, (uint16)) == 1, "11_1: bPNTs is not an xPNTs v2 token");
        (bool ok2, bytes memory ret2) =
            sp.xpntsFactory().staticcall(abi.encodeWithSignature("getTokenAddress(address)", anniAddr));
        require(ok2 && abi.decode(ret2, (address)) == bPNTsV2TokenAddr, "11_1: bPNTs not issued to Anni by SP's factory");

        console.log("Configuring Bread Operator in SuperPaymaster with account:", anniAddr);
        vm.startBroadcast(anniPrivateKey);
        sp.configureOperator(bPNTsV2TokenAddr, anniAddr); // treasury = Anni; rate read from the token
        vm.stopBroadcast();

        (, bool cfg,, address tok,,, address treasury,,) = sp.operators(anniAddr);
        require(cfg && tok == bPNTsV2TokenAddr && treasury == anniAddr, "11_1 read-back: operator config");
        console.log("Successfully configured BreadCommunity Operator (Anni) in SuperPaymaster.");
    }
}
