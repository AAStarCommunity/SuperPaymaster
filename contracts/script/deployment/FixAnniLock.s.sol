// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/core/GTokenStaking.sol";

/**
 * @title ClearAnniLock
 * @notice Jason (Owner) rescues Anni's stale stake to allow community registration.
 */
contract ClearAnniLock is Script {
    function run(address stakingAddr, address registryAddr, address anniAddr) external {
        uint256 jasonKey = vm.envUint("PRIVATE_KEY");
        address jason = vm.addr(jasonKey);
        
        GTokenStaking staking = GTokenStaking(stakingAddr);
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

        console.log("Cleaning up lock for Anni:", anniAddr);
        
        vm.startBroadcast(jasonKey);

        // 1. Check if lock exists
        uint256 locked = staking.getLockedStake(anniAddr, ROLE_COMMUNITY);
        if (locked > 0) {
            console.log("Found stale lock for Anni:", locked);
            
            // 2. Temporarily set Registry to Jason
            address oldReg = staking.REGISTRY();
            staking.setRegistry(jason);
            
            // 3. Force unlock for Anni
            staking.unlockAndTransfer(anniAddr, ROLE_COMMUNITY);
            console.log("Stale lock cleared for Anni.");
            
            // 4. Restore Registry
            staking.setRegistry(registryAddr);
        } else {
            console.log("No stale lock found for Anni.");
        }

        vm.stopBroadcast();
    }
}
