// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/tokens/MySBT_v2.4.1.sol";

/**
 * @title Deploy MySBT v2.4.1
 * @notice Deploy MySBT v2.4.1 with mintWithAutoStake functionality
 */
contract DeployMySBT_v2_4_1 is Script {
    // Sepolia network configuration
    address constant GTOKEN = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
    address constant GTOKEN_STAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0; // v2.0.1
    address constant REGISTRY = 0xf384c592D5258c91805128291c5D4c069DD30CA6; // v2.1.4
    address constant DAO_MULTISIG = 0x5CE2B92c395837c97C7992716883f0146fbe5887;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("Deploying MySBT v2.4.1");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("GToken:", GTOKEN);
        console.log("GTokenStaking:", GTOKEN_STAKING);
        console.log("Registry:", REGISTRY);
        console.log("DAO Multisig:", DAO_MULTISIG);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MySBT v2.4.1
        MySBT_v2_4_1 mysbt = new MySBT_v2_4_1(
            GTOKEN,
            GTOKEN_STAKING,
            REGISTRY,
            DAO_MULTISIG
        );

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("MySBT v2.4.1:", address(mysbt));
        console.log("VERSION:", mysbt.VERSION());
        console.log("VERSION_CODE:", mysbt.VERSION_CODE());
        console.log("");
        console.log("Next Steps:");
        console.log("1. Configure this MySBT as authorized locker in GTokenStaking");
        console.log("2. Update shared-config with new address");
        console.log("3. Publish shared-config to npm");
        console.log("4. Update faucet to use new MySBT");
        console.log("");
    }
}
