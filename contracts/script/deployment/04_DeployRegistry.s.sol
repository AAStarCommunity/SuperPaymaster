// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";

contract Deploy04_Registry is Script {
    // !!! PASTE ADDRESSES HERE !!!
    address constant GTOKEN_ADDR = 0x5F7Dee075b79B955EB2f25CC0b373319855992fe;
    address constant GTOKEN_STAKING_ADDR = 0xa9389A731D5ccd801fFCCFd7CC19d7DD5A03f6Bf;
    address constant MYSBT_ADDR = 0xc8379abd11b358E2cE63457515954C0E2D0B5420;

    function run() external {
        require(GTOKEN_ADDR != address(0), "GToken address cannot be zero.");
        require(GTOKEN_STAKING_ADDR != address(0), "GTokenStaking address cannot be zero.");
        require(MYSBT_ADDR != address(0), "MySBT address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying Registry with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        Registry registry = new Registry(gTokenAddr, gTokenStakingAddr, mySBTAddr);

        vm.stopBroadcast();

        console.log("✅ Registry deployed to:", address(registry));
    }
}
