// SPDX-License-Identifier: MIT
// REHEARSAL ONLY - never use for deploy day. Untracked acceptance helper; scalars come from env, never logged.
pragma solidity 0.8.33;
import "forge-std/Script.sol";
import {DeployLiveInputs} from "../../../script/v3/DeployLiveInputs.sol";
import {GenuineBLS} from "../../helpers/GenuineBLS.sol";

contract AcceptancePoP is Script {
    function run() external {
        address sender = vm.envAddress("DEPLOYER_ADDRESS");
        uint64 nonce = vm.getNonce(sender);
        address registry = vm.computeCreateAddress(sender, nonce + 1);
        address aggregator = vm.computeCreateAddress(sender, nonce + 29);
        bytes32 domain = keccak256(abi.encode(keccak256("SuperPaymaster.BLSConsensus.v1"), block.chainid, aggregator, registry));
        address[] memory accounts = vm.envAddress("ACC_GUARDIAN_ACCOUNTS", ",");
        DeployLiveInputs.GuardianInput[] memory gs = new DeployLiveInputs.GuardianInput[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) {
            uint256 sk = vm.envUint(string.concat("ACC_BLS_SK_", vm.toString(i)));
            gs[i].account = accounts[i];
            gs[i].key = GenuineBLS.publicKey(sk);
            bytes32 digest = keccak256(abi.encode(domain, keccak256("SuperPaymaster.BLS.PoP.v1"), gs[i].account,
                gs[i].key.x_a, gs[i].key.x_b, gs[i].key.y_a, gs[i].key.y_b));
            gs[i].pop = GenuineBLS.signature(abi.encodePacked(digest), sk);
        }
        console.log("chainid", block.chainid);
        console.log("deployer nonce", uint256(nonce));
        console.log("predicted registry", registry);
        console.log("predicted aggregator", aggregator);
        vm.writeFile(vm.envString("ACC_GUARDIANS_OUT"), vm.toString(abi.encode(gs)));
    }
}
