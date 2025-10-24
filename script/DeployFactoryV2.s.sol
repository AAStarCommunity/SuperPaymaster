// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/accounts/SimpleAccountFactoryV2.sol";
import "../src/accounts/SimpleAccountV2.sol";
import "../contracts/src/interfaces/IEntryPoint.sol";

contract DeployFactoryV2 is Script {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SimpleAccountFactoryV2
        SimpleAccountFactoryV2 factory = new SimpleAccountFactoryV2(IEntryPoint(ENTRYPOINT_V07));

        // Get implementation address
        address implAddress = address(factory.accountImplementation());

        console.log("=== SimpleAccountFactoryV2 Deployment ===");
        console.log("Factory Address:", address(factory));
        console.log("Implementation Address:", implAddress);
        console.log("EntryPoint:", ENTRYPOINT_V07);

        // Verify implementation version
        SimpleAccountV2 impl = SimpleAccountV2(payable(implAddress));
        string memory version = impl.version();
        console.log("Implementation Version:", version);

        vm.stopBroadcast();
    }
}
