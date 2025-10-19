// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/src/GToken.sol";

contract DeployGToken is Script {
    function run() external returns (address) {
        // vm.startBroadcast()会自动使用您在命令行中通过 --private-key 传入的私钥
        vm.startBroadcast();

        GovernanceToken gToken = new GovernanceToken();

        vm.stopBroadcast();

        console.log("GovernanceToken (GToken) deployed to:", address(gToken));
        return address(gToken);
    }
}
