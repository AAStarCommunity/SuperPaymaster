// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsToken.sol";

/**
 * @title Deploy08b_WireUpTokenMulti
 * @notice Wires any community token to SuperPaymaster using a specified private key.
 */
contract Deploy08b_WireUpTokenMulti is Script {
    function run(address apntsTokenAddr, address superPaymasterAddr, string memory privateKeyEnv) external {
        require(apntsTokenAddr != address(0), "aPNTs token address cannot be zero.");
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint(privateKeyEnv);
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Wiring token", apntsTokenAddr, "with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Set the SuperPaymaster address in the Token
        xPNTsToken(apntsTokenAddr).setSuperPaymasterAddress(superPaymasterAddr);

        // Manually add the SuperPaymaster to the auto-approved list
        xPNTsToken(apntsTokenAddr).addAutoApprovedSpender(superPaymasterAddr);

        vm.stopBroadcast();
        console.log("Token at", apntsTokenAddr, "is now fully wired with SuperPaymaster.");
    }
}
