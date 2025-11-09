// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/tokens/MySBT_v2.4.3.sol";

/**
 * @title Deploy MySBT v2.4.3
 * @notice Deploys MySBT v2.4.3 with fixed mintWithAutoStake logic
 *
 * Usage:
 *   forge script script/DeployMySBT_v2_4_3.s.sol:DeployMySBT_v2_4_3 \
 *     --rpc-url sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployMySBT_v2_4_3 is Script {
    // Sepolia addresses
    address constant GTOKEN = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
    address constant GTOKEN_STAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0;
    address constant REGISTRY = 0xf384c592D5258c91805128291c5D4c069DD30CA6;
    address constant DAO_MULTISIG = 0x411BD567E46C0781248dbB6a9211891C032885e5;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("====================================");
        console.log("Deploying MySBT v2.4.3");
        console.log("====================================");
        console.log("Deployer:", deployer);
        console.log("GToken:", GTOKEN);
        console.log("GTokenStaking:", GTOKEN_STAKING);
        console.log("Registry:", REGISTRY);
        console.log("DAO Multisig:", DAO_MULTISIG);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        MySBT_v2_4_3 mySBT = new MySBT_v2_4_3(
            GTOKEN,
            GTOKEN_STAKING,
            REGISTRY,
            DAO_MULTISIG
        );

        vm.stopBroadcast();

        console.log("");
        console.log("====================================");
        console.log("Deployment Complete!");
        console.log("====================================");
        console.log("MySBT v2.4.3:", address(mySBT));
        console.log("VERSION:", mySBT.VERSION());
        console.log("VERSION_CODE:", mySBT.VERSION_CODE());
        console.log("minLockAmount:", mySBT.minLockAmount() / 1e18, "GT");
        console.log("mintFee:", mySBT.mintFee() / 1e18, "GT");
        console.log("");
        console.log("Next Steps:");
        console.log("1. Register MySBT as locker in GTokenStaking");
        console.log("2. Test with TEST-USER5 account");
        console.log("3. Update shared-config with new address");
    }
}
