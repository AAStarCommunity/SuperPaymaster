// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import {GovernanceOwnerGate} from "../checks/GovernanceOwnerGate.sol";

/// @notice Redeploy the two non-upgradeable BLS modules after the slash-consensus
///         unification (PR #329). Order matters: DVTValidator first, because the
///         hardened BLSAggregator constructor now rejects a zero dvtValidator.
contract DeployNewBLSModules is Script {
    address constant REGISTRY = 0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71;
    address constant SUPERPAYMASTER = 0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        DVTValidator dvt = new DVTValidator(REGISTRY);
        BLSAggregator bls = new BLSAggregator(REGISTRY, SUPERPAYMASTER, address(dvt));
        dvt.setBLSAggregator(address(bls));

        // CC-48 round-6 HIGH-1: this script targets a LIVE chain by construction (the
        // Registry/SP addresses above are hard-coded Sepolia). Hand the aggregator's
        // disarm authority to governance before the broadcast ends.
        address gov = GovernanceOwnerGate.declaredGovernanceOwner();
        if (gov != address(0)) bls.transferOwnership(gov);

        vm.stopBroadcast();

        GovernanceOwnerGate.requireGovernanceOwner(address(bls), bls.owner(), "BLSAggregator");

        console.log("DVTValidator:", address(dvt));
        console.log("BLSAggregator:", address(bls));
    }
}
