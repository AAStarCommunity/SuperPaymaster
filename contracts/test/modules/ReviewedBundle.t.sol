// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";

contract ReviewedBundle is Test {
    function test_Review_PublishedBytecodeRejectsDirectOwnerRegistration() public {
        bytes memory code = abi.encodePacked(vm.parseJsonBytes(vm.readFile("abis/BLSAggregator.json"), ".bytecode"),
            abi.encode(address(0xA), address(0xB), address(0xC)));
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        assertTrue(deployed != address(0), "published bytecode must deploy");
        BLSAggregator packaged = BLSAggregator(deployed);
        assertEq(packaged.version(), "BLSAggregator-4.14.0");
        BLS.G1Point memory key;
        BLS.G2Point memory pop;
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnauthorizedCaller.selector, address(this)));
        packaged.registerBLSPublicKey(address(101), key, 1, pop);
        (,, bool active) = packaged.getBLSPublicKey(address(101));
        assertFalse(active, "published bundle enforces the source DVT-only boundary");
    }
}
