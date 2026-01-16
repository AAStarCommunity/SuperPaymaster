// SPDX-License-Identifier: MIT
// 08a_WireUpFactory.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsFactory.sol";

contract Deploy08a_WireUpFactory is Script {
    function run(address factoryAddr, address superPaymasterAddr) external {
        require(factoryAddr != address(0), "Factory address cannot be zero.");
        require(superPaymasterAddr != address(0), "SuperPaymaster address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        xPNTsFactory(factoryAddr).setSuperPaymasterAddress(superPaymasterAddr);

        vm.stopBroadcast();
        console.log("Factory at", factoryAddr, "is now wired with SuperPaymaster at", superPaymasterAddr);
    }
}
