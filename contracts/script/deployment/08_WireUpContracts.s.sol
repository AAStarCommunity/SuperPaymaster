// SPDX-License-Identifier: MIT
// 08_WireUpContracts.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/MySBT.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";

contract Deploy08_WireUpContracts is Script {
    function run(
        address factoryAddr,
        address superPaymasterAddr,
        address apntsTokenAddr,
        address mySBTAddr,
        address gTokenStakingAddr,
        address registryAddr
    ) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Wiring all contracts with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Set the SuperPaymaster address in the Factory
        xPNTsFactory(factoryAddr).setSuperPaymasterAddress(superPaymasterAddr);
        console.log("Factory wired with SuperPaymaster.");

        // Set the SuperPaymaster address in the Token (for burnFromWithOpHash)
        xPNTsToken(apntsTokenAddr).setSuperPaymasterAddress(superPaymasterAddr);
        console.log("aPNTs token wired with SuperPaymaster.");

        // Set the Registry address in MySBT and GTokenStaking
        MySBT(mySBTAddr).setRegistry(registryAddr);
        console.log("MySBT wired with Registry.");
        GTokenStaking(gTokenStakingAddr).setRegistry(registryAddr);
        console.log("GTokenStaking wired with Registry.");

        vm.stopBroadcast();

        console.log("All contracts wired up successfully.");
    }
}
