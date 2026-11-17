// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";

/// @notice Positive control for the reputation-branch rehearsal: prints a correctly signed proof
///         for (ID, [TARGET_USER], [SCORE], EPOCH) from the first SIGNERS slots. Simulation only.
contract RehearseReputationProof is Script {
    function run() external view {
        BLSAggregator agg = BLSAggregator(vm.envAddress("AGG"));
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = vm.envAddress("TARGET_USER");
        scores[0] = vm.envUint("SCORE");
        bytes32 h = agg.reputationMessageHash(vm.envUint("ID"), users, scores, vm.envUint("EPOCH"));
        BLS.G2Point memory m = BLS.hashToG2(abi.encodePacked(h));
        uint256 signers = vm.envUint("SIGNERS");
        BLS.G2Point memory sig;
        for (uint256 i; i < signers; ++i) {
            BLS.G2Point[] memory p = new BLS.G2Point[](1);
            bytes32[] memory k = new bytes32[](1);
            p[0] = m;
            k[0] = bytes32(vm.envUint(string.concat("SK", vm.toString(i + 1))));
            BLS.G2Point memory part = BLS.msm(p, k);
            sig = i == 0 ? part : BLS.add(sig, part);
        }
        console.log("PROOF");
        console.logBytes(abi.encode((uint256(1) << signers) - 1, abi.encode(sig)));
    }
}
