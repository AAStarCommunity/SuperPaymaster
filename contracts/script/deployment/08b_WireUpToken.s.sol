// SPDX-License-Identifier: MIT
// 08b_WireUpToken.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsToken.sol";

contract Deploy08b_WireUpToken is Script {
    function run(address apntsTokenAddr, address superPaymasterAddr) external {
        require(apntsTokenAddr != address(0), "aPNTs token address cannot be zero.");
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Set the SuperPaymaster address in the Token (for burnFromWithOpHash)
        xPNTsToken(apntsTokenAddr).setSuperPaymasterAddress(superPaymasterAddr);

        // Manually add the SuperPaymaster to the auto-approved list for our mock token
        xPNTsToken(apntsTokenAddr).addAutoApprovedSpender(superPaymasterAddr);

        vm.stopBroadcast();
        console.log("aPNTs token at", apntsTokenAddr, "is now fully wired with SuperPaymaster.");
    }
}
