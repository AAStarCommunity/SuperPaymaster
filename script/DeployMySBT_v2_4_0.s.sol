// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/tokens/MySBT_v2.4.0.sol";

/**
 * @title DeployMySBT_v2_4_0
 * @notice Deploy MySBT v2.4.0 with VERSION interface and NFT binding refactor
 */
contract DeployMySBT_v2_4_0 is Script {
    function run() external {
        address gtoken = vm.envAddress("GTOKEN");
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        address registry = vm.envAddress("REGISTRY");
        address dao = vm.envAddress("DAO_MULTISIG");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying MySBT v2.4.0 ===");
        console.log("GToken:", gtoken);
        console.log("GTokenStaking:", gtokenStaking);
        console.log("Registry:", registry);
        console.log("DAO Multisig:", dao);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        MySBT_v2_4_0 mysbt = new MySBT_v2_4_0(
            gtoken,
            gtokenStaking,
            registry,
            dao
        );

        console.log("MySBT v2.4.0 deployed:", address(mysbt));
        console.log("VERSION:", mysbt.VERSION());
        console.log("VERSION_CODE:", mysbt.VERSION_CODE());

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("Address:", address(mysbt));
    }
}
