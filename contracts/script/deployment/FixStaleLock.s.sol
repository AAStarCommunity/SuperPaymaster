// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/core/GTokenStaking.sol";

interface IMySBT {
    function userToSBT(address user) external view returns (uint256);
    function burnSBT() external returns (uint256);
}

/**
 * @title FixStaleLock
 * @notice Rescues tokens from a stale lock in GTokenStaking and clears MySBT membership.
 */
contract FixStaleLock is Script {
    function run(address stakingAddr, address newRegistryAddr, address mysbtAddr) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        GTokenStaking staking = GTokenStaking(stakingAddr);
        IMySBT mysbt = IMySBT(mysbtAddr);
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Clear MySBT if exists (Already member fix)
        uint256 tokenId = mysbt.userToSBT(deployer);
        if (tokenId != 0) {
            console.log("Found existing MySBT token:", tokenId);
            // We need to set REGISTRY to address(0) or something if MySBT blocks it, 
            // but MySBT.burnSBT is usually public/msg.sender.
            // Note: MySBT.burnSBT calls staking.unlockStake.
            // So we MUST set REGISTRY to MySBT address on Staking first.
            address oldRegistry = staking.REGISTRY();
            staking.setRegistry(mysbtAddr);
            
            try mysbt.burnSBT() {
                console.log("MySBT burned successfully.");
            } catch {
                console.log("MySBT burn failed (maybe already clean or different version).");
            }
            staking.setRegistry(oldRegistry);
        }

        // 2. Check if lock still exists in Staking
        uint256 lockedAmount = staking.getLockedStake(deployer, ROLE_COMMUNITY);
        if (lockedAmount > 0) {
            console.log("Found stale lock for COMMUNITY:", lockedAmount);
            staking.setRegistry(deployer);
            staking.unlockAndTransfer(deployer, ROLE_COMMUNITY);
            console.log("Stale lock cleared.");
        }

        // 3. Set REGISTRY back to the new Registry V3.1
        staking.setRegistry(newRegistryAddr);
        console.log("GTokenStaking registry updated to:", newRegistryAddr);

        vm.stopBroadcast();
    }
}
