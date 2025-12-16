// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/GToken.sol";
import "contracts/script/deployment/05_DeployMockAPNTs.s.sol"; // To get MockERC20 contract

contract Deploy08_MintInitialTokens is Script {
    // !!! PASTE ADDRESSES HERE !!!
    address constant GTOKEN_ADDR = 0x5F7Dee075b79B955EB2f25CC0b373319855992fe;
    address constant APNTS_ADDR = 0xDF58096a3854153deF74ea07Ac461aD48014fb6E;

    function run() external {
        require(GTOKEN_ADDR != address(0), "GToken address cannot be zero.");
        require(APNTS_ADDR != address(0), "aPNTs address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Minting initial tokens to account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        GToken(gTokenAddr).mint(deployer, 1_000_000 * 1e18);
        MockERC20(aPNTsAddr).mint(deployer, 1_000_000 * 1e18);

        vm.stopBroadcast();

        console.log("✅ Initial tokens minted successfully.");
    }
}
