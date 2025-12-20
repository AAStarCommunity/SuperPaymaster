// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

contract DebugAbi is Test {
    function testAbiDecode() public pure {
        address comm = address(0x123);
        string memory meta = "some metadata";

        // Validate hypothesis: Registry encodes (address, string)
        bytes memory data = abi.encode(comm, meta);

        // MySBT tries to decode (address) first
        // If this reverts, that's the bug.
        // Uncomment to test the revert behavior logic manually or just run this.
        address decodedComm = abi.decode(data, (address));
        
        // This is what MySBT does next if length > 32
        // (address c, string memory m) = abi.decode(data, (address, string));
    }
}
