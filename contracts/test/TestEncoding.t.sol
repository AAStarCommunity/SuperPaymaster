// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/core/Registry.sol";

contract TestEncoding is Test {
    function testCommunityRoleDataEncoding() public {
        // Test 1: What deploy script uses
        Registry.CommunityRoleData memory data1 = Registry.CommunityRoleData({
            name: "Local Operator",
            ensName: "local.eth",
            website: "http://localhost",
            description: "Local Test Hub",
            logoURI: "",
            stakeAmount: 30 ether
        });
        
        bytes memory encoded1 = abi.encode(data1);
        console.log("=== SOLIDITY abi.encode(struct) ===");
        console.log("Length:", encoded1.length);
        console.logBytes(encoded1);
        
        // Test 2: What test should use (similar values)
        Registry.CommunityRoleData memory data2 = Registry.CommunityRoleData({
            name: "TestCommunity",
            ensName: "test.eth",
            website: "http://test.com",
            description: "Test Community",
            logoURI: "http://logo.png",
            stakeAmount: 0
        });
        
        bytes memory encoded2 = abi.encode(data2);
        console.log("\n=== SOLIDITY abi.encode(struct) Test Data ===");
        console.log("Length:", encoded2.length);
        console.logBytes(encoded2);
        
        // Test 3: Try decoding
        Registry.CommunityRoleData memory decoded = abi.decode(encoded2, (Registry.CommunityRoleData));
        console.log("\n=== DECODED ===");
        console.log("Name:", decoded.name);
        console.log("EnsName:", decoded.ensName);
        console.log("Website:", decoded.website);
    }
}
