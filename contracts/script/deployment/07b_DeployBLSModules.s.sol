// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/validators/BLSValidator.sol";

contract DeployBLSModules is Script {
    function run(address registryAddr, address spAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");
        require(spAddr != address(0), "SP address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        BLSAggregator aggregator = new BLSAggregator(registryAddr, spAddr, address(0));
        aggregator.setThreshold(3);

        DVTValidator dvt = new DVTValidator(registryAddr);
        dvt.setBLSAggregator(address(aggregator));

        BLSValidator blsValidator = new BLSValidator();

        vm.stopBroadcast();

        console.log("BLSAggregator deployed to:", address(aggregator));
        console.log("DVTValidator deployed to:", address(dvt));
        console.log("BLSValidator deployed to:", address(blsValidator));
    }
}
