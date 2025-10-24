// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "./SimpleAccountV2.sol";
import "./interfaces/IEntryPoint.sol";

/**
 * Factory for creating SimpleAccountV2 instances
 * Creates accounts that support personal_sign (MetaMask signMessage)
 * without requiring eth_sign to be enabled
 */
contract SimpleAccountFactoryV2 {
    SimpleAccountV2 public immutable accountImplementation;

    constructor(IEntryPoint _entryPoint) {
        accountImplementation = new SimpleAccountV2(_entryPoint);
    }

    /**
     * create an account, and return its address.
     * returns the address even if the account is already deployed.
     */
    function createAccount(address owner, uint256 salt) public returns (SimpleAccountV2 ret) {
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return SimpleAccountV2(payable(addr));
        }
        ret = SimpleAccountV2(
            payable(
                new ERC1967Proxy{salt: bytes32(salt)}(
                    address(accountImplementation),
                    abi.encodeCall(SimpleAccountV2.initialize, (owner))
                )
            )
        );
    }

    /**
     * calculate the counterfactual address of this account as it would be returned by createAccount()
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(address(accountImplementation), abi.encodeCall(SimpleAccountV2.initialize, (owner)))
                )
            )
        );
    }
}
