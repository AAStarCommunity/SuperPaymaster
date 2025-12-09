// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/v3/core/Registry.sol";

contract DebugTest is Test {
    function test_DecodeRoleData() public pure {
        // Test if we can encode and decode CommunityRoleData
        Registry.CommunityRoleData memory data = Registry.CommunityRoleData({
            name: "TestDAO",
            ensName: "",
            website: "",
            description: "",
            logoURI: "",
            stakeAmount: 30 ether
        });
        
        bytes memory encoded = abi.encode(data);
        Registry.CommunityRoleData memory decoded = abi.decode(encoded, (Registry.CommunityRoleData));
        
        assertEq(decoded.name, "TestDAO");
        assertEq(decoded.stakeAmount, 30 ether);
    }
    
    function test_ConvertToSBTFormat() public pure {
        address user = address(0x200);
        bytes memory sbtData = abi.encode(user, "");
        
        (address decoded, string memory meta) = abi.decode(sbtData, (address, string));
        assertEq(decoded, user);
        assertEq(bytes(meta).length, 0);
    }
}
