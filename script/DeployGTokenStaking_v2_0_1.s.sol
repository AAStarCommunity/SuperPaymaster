// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/core/GTokenStaking_v2_0_1.sol";

/**
 * @title Deploy GTokenStaking v2.0.1
 * @notice Deploy GTokenStaking v2.0.1 (with stakeFor functionality)
 * @dev Usage:
 *   forge script script/DeployGTokenStaking_v2_0_1.s.sol:DeployGTokenStaking_v2_0_1 \
 *     --rpc-url sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployGTokenStaking_v2_0_1 is Script {
    // Sepolia network configuration
    address constant GTOKEN = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc; // GToken v2.0.0
    address constant DAO_MULTISIG = 0x5CE2B92c395837c97C7992716883f0146fbe5887; // Correct checksum

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("Deploying GTokenStaking v2.0.1");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("GToken:", GTOKEN);
        console.log("DAO Multisig:", DAO_MULTISIG);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy GTokenStaking v2.0.1
        GTokenStaking gtokenStaking = new GTokenStaking(GTOKEN);

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Deployment Summary");
        console.log("========================================");
        console.log("GTokenStaking v2.0.1:", address(gtokenStaking));
        console.log("VERSION:", gtokenStaking.VERSION());
        console.log("VERSION_CODE:", gtokenStaking.VERSION_CODE());
        console.log("");
        console.log("Next Steps:");
        console.log("1. Use DAO multisig to approve GTokenStaking v2.0.1 in GToken contract");
        console.log("2. Configure MySBT v2.4.1 as authorized locker");
        console.log("3. Deploy MySBT v2.4.1");
        console.log("4. Update shared-config");
        console.log("");
    }
}
