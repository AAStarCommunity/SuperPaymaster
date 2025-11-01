// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/core/GToken.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title MintAndStakeGToken
 * @notice Mint GToken to deployer accounts and stake for community registration
 */
contract MintAndStakeGToken is Script {
    function run() external {
        address gtoken = vm.envAddress("GTOKEN");
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        address registry = vm.envAddress("REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address deployer1 = vm.addr(deployerPrivateKey);
        address deployer2 = vm.addr(vm.envUint("PRIVATE_KEY_DEPLOYER2"));

        GToken gtokenContract = GToken(gtoken);
        GTokenStaking stakingContract = GTokenStaking(gtokenStaking);

        console.log("=== Minting and Staking GToken ===");
        console.log("GToken:", gtoken);
        console.log("GTokenStaking:", gtokenStaking);
        console.log("Registry:", registry);
        console.log();

        // Mint 100 GToken to each deployer (owner operation)
        vm.startBroadcast(deployerPrivateKey);

        console.log("Minting 100 GToken to deployer1:", deployer1);
        gtokenContract.mint(deployer1, 100 ether);

        console.log("Minting 100 GToken to deployer2:", deployer2);
        gtokenContract.mint(deployer2, 100 ether);

        console.log();
        console.log("Approving and staking for deployer1...");
        gtokenContract.approve(address(stakingContract), 100 ether);
        stakingContract.stake(100 ether);

        vm.stopBroadcast();

        console.log();
        console.log("Approving and staking for deployer2...");
        uint256 deployer2PrivateKey = vm.envUint("PRIVATE_KEY_DEPLOYER2");
        vm.startBroadcast(deployer2PrivateKey);

        gtokenContract.approve(address(stakingContract), 100 ether);
        stakingContract.stake(100 ether);

        vm.stopBroadcast();

        console.log();
        console.log("=== Mint and Stake Complete ===");
    }
}
