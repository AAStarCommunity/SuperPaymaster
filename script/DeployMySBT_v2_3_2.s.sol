// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/tokens/MySBT_v2.3.2.sol";

/**
 * @title DeployMySBT_v2_3_2
 * @notice Deploy MySBT v2.3.2 with burn fix (transfer to dead address)
 */
contract DeployMySBT_v2_3_2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gtoken = vm.envAddress("GTOKEN");
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        address registry = vm.envAddress("REGISTRY");
        address dao = vm.envAddress("DAO_MULTISIG");

        console.log("=== Deploy MySBT v2.3.2 ===");
        console.log("GToken:", gtoken);
        console.log("GTokenStaking:", gtokenStaking);
        console.log("Registry:", registry);
        console.log("DAO:", dao);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        MySBT_v2_3_2 mysbt = new MySBT_v2_3_2(gtoken, gtokenStaking, registry, dao);

        vm.stopBroadcast();

        console.log("MySBT v2.3.2 deployed:", address(mysbt));
    }
}
