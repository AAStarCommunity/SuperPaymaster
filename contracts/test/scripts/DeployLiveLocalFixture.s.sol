// SPDX-License-Identifier: MIT
// REHEARSAL ONLY - never use for deploy day. Deterministic public test scalars.
pragma solidity 0.8.33;
import "forge-std/Script.sol";
import {DeployLiveInputs} from "../../script/v3/DeployLiveInputs.sol";
import {GenuineBLS} from "../helpers/GenuineBLS.sol";

contract LocalDeployFeed {
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, block.timestamp, block.timestamp, 1);
    }
}
contract LocalDeployAccount {
    function entryPoint() external pure returns (address) { return 0x0000000071727De22E5E9d8BAf0edAc6f37da032; }
}
contract LocalDeployFactory {
    function accountImplementation() external pure returns (address) { return address(102); }
}
contract LocalExternalToken {
    function balanceOf(address) external pure returns (uint256) { return 0; }
}
contract DeployLiveLocalBundle is Script {
    function run() external {
        require(block.chainid == 31337, "local only");
        address sender = vm.envAddress("DEPLOYER_ADDRESS");
        uint64 nonce = vm.getNonce(sender);
        address registry = vm.computeCreateAddress(sender, nonce + 1);
        address aggregator = vm.computeCreateAddress(sender, nonce + 29);
        bytes32 domain = keccak256(abi.encode(keccak256("SuperPaymaster.BLSConsensus.v1"), block.chainid, aggregator, registry));
        DeployLiveInputs.GuardianInput[] memory gs = new DeployLiveInputs.GuardianInput[](3);
        for (uint256 i; i < 3; ++i) {
            gs[i].account = address(uint160(300 + i));
            gs[i].key = GenuineBLS.publicKey(i + 1);
            bytes32 digest = keccak256(abi.encode(domain, keccak256("SuperPaymaster.BLS.PoP.v1"), gs[i].account,
                gs[i].key.x_a, gs[i].key.x_b, gs[i].key.y_a, gs[i].key.y_b));
            gs[i].pop = GenuineBLS.signature(abi.encodePacked(digest), i + 1);
        }
        vm.writeFile(string.concat(vm.envString("DEPLOYLIVE_LOCAL_EVIDENCE"), "/guardians.txt"), vm.toString(abi.encode(gs)));
    }
}
