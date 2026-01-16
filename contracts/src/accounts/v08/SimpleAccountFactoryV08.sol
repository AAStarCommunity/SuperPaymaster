// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import "account-abstraction-v8/accounts/SimpleAccountFactory.sol";
contract SimpleAccountFactoryV08 is SimpleAccountFactory {
    constructor(IEntryPoint entryPoint) SimpleAccountFactory(entryPoint) {}
}