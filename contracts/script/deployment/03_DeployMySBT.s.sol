// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/MySBT.sol";

contract Deploy03_MySBT is Script {
    // !!! PASTE ADDRESSES HERE !!!
    address constant GTOKEN_ADDR = 0x5F7Dee075b79B955EB2f25CC0b373319855992fe;
    address constant GTOKEN_STAKING_ADDR = 0xa9389A731D5ccd801fFCCFd7CC19d7DD5A03f6Bf;

    function run() external {
        require(GTOKEN_ADDR != address(0), "GToken address cannot be zero.");
        require(GTOKEN_STAKING_ADDR != address(0), "GTokenStaking address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying MySBT with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // We pass address(0) for the registry, as it will be wired up in a later step.
        MySBT mySBT = new MySBT(gTokenAddr, gTokenStakingAddr, address(0), deployer);

        vm.stopBroadcast();

        console.log("✅ MySBT deployed to:", address(mySBT));
    }
}
