// SPDX-License-Identifier: MIT
// 06_DeployMockCommunityToken.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsFactory.sol";

contract Deploy06_MockCommunityToken is Script {
    function run(address factoryAddr) external {
        require(factoryAddr != address(0), "Factory address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying Mock Community Token via Factory with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // As the deployer, we call the factory to create a token for our "mock community"
        // This token will serve as the main aPNTs token for the SuperPaymaster
        address mockToken = xPNTsFactory(factoryAddr).deployxPNTsToken(
            "AAStar PNT",
            "aPNTs",
            "AAStar Community",
            "aastar.eth",
            1e18, // 1:1 exchange rate
            address(0) // No AOA paymaster
        );

        vm.stopBroadcast();

        console.log("Mock Community Token (aPNTs) deployed to:", mockToken);
    }
}
