// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureMySBTLocker
 * @notice Configure MySBT v2.3.1 as authorized locker in GTokenStaking
 */
contract ConfigureMySBTLocker is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        address mysbtAddress = vm.envAddress("MYSBT");

        console.log("=== Configure MySBT as Locker ===");
        console.log("GTokenStaking:", gtokenStaking);
        console.log("MySBT:", mysbtAddress);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking staking = GTokenStaking(gtokenStaking);

        // Configure MySBT as locker
        // authorized=true, baseExitFee=0.1 ether, timeTiers=[], tierFees=[], feeRecipient=0x0
        staking.configureLocker(
            mysbtAddress,
            true,      // authorized
            0.1 ether, // baseExitFee (0.1 stGT exit fee goes to treasury)
            new uint256[](0),  // timeTiers (no time-based tiers)
            new uint256[](0),  // tierFees (no tier fees)
            address(0)  // feeRecipient (use default treasury)
        );

        vm.stopBroadcast();

        console.log("[OK] MySBT configured as authorized locker");
    }
}
