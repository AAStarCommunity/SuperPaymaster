// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/mocks/TestSBT.sol";

contract DeployTestSBT is Script {
    function run() external {
        vm.startBroadcast();

        TestSBT testSBT = new TestSBT();
        console.log("TestSBT deployed at:", address(testSBT));

        // Mint to test account
        address testAccount = 0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce;
        uint256 tokenId = testSBT.mint(testAccount);
        console.log("Minted Token ID", tokenId, "to", testAccount);

        vm.stopBroadcast();
    }
}
