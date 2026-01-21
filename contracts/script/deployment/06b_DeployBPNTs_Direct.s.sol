// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/tokens/xPNTsToken.sol";

contract Deploy06b_BPNTs_Direct is Script {
    using Clones for address;
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying bPNTs (Direct) with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Direct deployment bypassing Factory (using clone pattern for safety)
        address xPNTsImpl = address(new xPNTsToken());
        xPNTsToken bpnts = xPNTsToken(xPNTsImpl.clone());
        bpnts.initialize(
            "AAStar PNT B",
            "bPNTs",
            deployer, // Owner
            "AAStar Community B",
            "aastar-b.eth",
            1e18 // 1:1
        );

        vm.stopBroadcast();

        console.log("bPNTs deployed to:", address(bpnts));
    }
}
