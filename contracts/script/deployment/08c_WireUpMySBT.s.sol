// SPDX-License-Identifier: MIT
// 08c_WireUpMySBT.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/MySBT.sol";

contract Deploy08c_WireUpMySBT is Script {
    function run(address mySBTAddr, address registryAddr) external {
        require(mySBTAddr != address(0), "MySBT address cannot be zero.");
        require(registryAddr != address(0), "Registry address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MySBT(mySBTAddr).setRegistry(registryAddr);

        vm.stopBroadcast();
        console.log("MySBT at", mySBTAddr, "is now wired with Registry at", registryAddr);
    }
}
