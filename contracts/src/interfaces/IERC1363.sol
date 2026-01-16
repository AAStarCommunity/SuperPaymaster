// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC1363Receiver {
    /**
     * @notice Handle the receipt of ERC1363 tokens
     * @param operator address The address which called `transferAndCall` or `transferFromAndCall` function
     * @param from address The address which are token transferred from
     * @param value uint256 The amount of tokens transferred
     * @param data bytes Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)"))`
     */
    function onTransferReceived(
        address operator,
        address from,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);
}
