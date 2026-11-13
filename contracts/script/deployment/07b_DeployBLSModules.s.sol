// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import {GovernanceOwnerGate} from "../checks/GovernanceOwnerGate.sol";
// BLSValidator standalone removed in P0-1 — Registry verifies via BLSAggregator.

contract DeployBLSModules is Script {
    function run(address registryAddr, address spAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");
        require(spAddr != address(0), "SP address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        DVTValidator dvt = new DVTValidator(registryAddr, 1);
        BLSAggregator aggregator = new BLSAggregator(registryAddr, spAddr, address(dvt));
        aggregator.setMinThreshold(3);

        dvt.setBLSAggregator(address(aggregator));

        // CC-48 round-6 HIGH-1: an EOA-owned aggregator on a live chain hands one hot key
        // an immediate, unannounced veto over every future guardian-slash accusation.
        address gov = GovernanceOwnerGate.declaredGovernanceOwner();
        if (gov != address(0)) {
            aggregator.transferOwnership(gov);
            dvt.transferOwnership(gov);
        }

        vm.stopBroadcast();

        GovernanceOwnerGate.requireGovernanceOwner(address(aggregator), aggregator.owner(), "BLSAggregator");
        require(dvt.owner() == aggregator.owner(), "DeployBLSModules: DVT owner != BLS owner");

        console.log("BLSAggregator deployed to:", address(aggregator));
        console.log("DVTValidator deployed to:", address(dvt));
    }
}
