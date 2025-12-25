// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
import "account-abstraction/interfaces/IEntryPoint.sol";
import "account-abstraction/accounts/SimpleAccount.sol" as BaseSimpleAccount;

contract SimpleAccount is BaseSimpleAccount.SimpleAccount {
    constructor(IEntryPoint entryPoint) BaseSimpleAccount.SimpleAccount(entryPoint) {}
}