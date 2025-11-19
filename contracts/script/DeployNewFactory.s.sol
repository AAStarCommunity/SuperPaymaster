// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/tokens/xPNTsFactory.sol";

/**
 * @notice Deploy new xPNTsFactory with SuperPaymaster V2.1
 */
contract DeployNewFactory is Script {
    address constant SUPER_PAYMASTER_V21 = 0xD6aa17587737C59cbb82986Afbac88Db75771857;
    address constant REGISTRY = 0x87Ef801bc3c8478Ff700198c0F910C049A8F4a16;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("SuperPaymaster V2.1:", SUPER_PAYMASTER_V21);
        console.log("Registry:", REGISTRY);

        vm.startBroadcast(deployerPrivateKey);

        xPNTsFactory factory = new xPNTsFactory(SUPER_PAYMASTER_V21, REGISTRY);

        console.log("xPNTsFactory deployed at:", address(factory));
        console.log("Factory SUPERPAYMASTER:", factory.SUPERPAYMASTER());
        console.log("Factory REGISTRY:", factory.REGISTRY());
        console.log("Factory owner:", factory.owner());

        vm.stopBroadcast();
    }
}
