// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
import "forge-std/Test.sol";
contract CheckPrecompile is Test {
    function test_precompile_0x0b() public view {
        uint256 sz;
        assembly { sz := extcodesize(0x0b) }
        console.log("extcodesize(0x0b):", sz);
        (bool ok, bytes memory ret) = address(0x0b).staticcall("");
        console.log("staticcall(empty) ok:", ok, "retlen:", ret.length);
        uint256 chainId;
        assembly { chainId := chainid() }
        console.log("chainId:", chainId);
    }
}
