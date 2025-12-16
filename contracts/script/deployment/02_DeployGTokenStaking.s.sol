// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/GTokenStaking.sol";

contract Deploy02_GTokenStaking is Script {
    function run(address gTokenAddr) external {
        require(gTokenAddr != address(0), "GToken address cannot be zero. Please pass it as an argument.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying GTokenStaking with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking gTokenStaking = new GTokenStaking(GTOKEN_ADDR, deployer);

        vm.stopBroadcast();

        console.log("✅ GTokenStaking deployed to:", address(gTokenStaking));
    }
}
opBroadcast();

        console.log("✅ GTokenStaking deployed to:", address(gTokenStaking));
    }
}
