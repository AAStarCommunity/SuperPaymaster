// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/core/Registry.sol";

contract GenerateEncoding is Script {
    function run() public {
        // Generate the same data as our test
        Registry.CommunityRoleData memory data = Registry.CommunityRoleData({
            name: "TestCommunity",
            ensName: "test.eth",
            website: "http://test.com",
            description: "Test Community",
            logoURI: "http://logo.png",
            stakeAmount: 0
        });
        
        bytes memory encoded = abi.encode(data);
        console.log("=== Solidity abi.encode(struct CommunityRoleData) ===");
        console.log("Length:", encoded.length);
        console.logBytes(encoded);
    }
}
