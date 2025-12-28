// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregatorV3.sol";
import "src/modules/monitoring/DVTValidatorV3.sol";
import "src/modules/validators/BLSValidator.sol";

contract DeployBLSModules is Script {
    function run(address registryAddr, address spAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");
        require(spAddr != address(0), "SP address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        BLSAggregatorV3 aggregator = new BLSAggregatorV3(registryAddr, spAddr, address(0));
        aggregator.setThreshold(3);

        DVTValidatorV3 dvt = new DVTValidatorV3(registryAddr);
        dvt.setBLSAggregator(address(aggregator));

        BLSValidator blsValidator = new BLSValidator();

        vm.stopBroadcast();

        console.log("BLSAggregatorV3 deployed to:", address(aggregator));
        console.log("DVTValidatorV3 deployed to:", address(dvt));
        console.log("BLSValidator deployed to:", address(blsValidator));
    }
}
