// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import "account-abstraction-v8/accounts/SimpleAccount.sol";
contract SimpleAccountV08 is SimpleAccount {
    constructor(IEntryPoint entryPoint) SimpleAccount(entryPoint) {}
}