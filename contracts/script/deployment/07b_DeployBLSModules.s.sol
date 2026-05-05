// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
// BLSValidator standalone removed in P0-1 — Registry verifies via BLSAggregator.

contract DeployBLSModules is Script {
    function run(address registryAddr, address spAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");
        require(spAddr != address(0), "SP address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        BLSAggregator aggregator = new BLSAggregator(registryAddr, spAddr, address(0));
        aggregator.setMinThreshold(3);

        DVTValidator dvt = new DVTValidator(registryAddr);
        dvt.setBLSAggregator(address(aggregator));

        vm.stopBroadcast();

        console.log("BLSAggregator deployed to:", address(aggregator));
        console.log("DVTValidator deployed to:", address(dvt));
    }
}
