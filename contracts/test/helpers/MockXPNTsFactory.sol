// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

contract MockXPNTsFactory {
    mapping(address => address) private _tokens;
    function setToken(address op, address token) external { _tokens[op] = token; }
    function getTokenAddress(address op) external view returns (address) { return _tokens[op]; }
    function isXPNTs(address t) external pure returns (bool) { return t != address(0); }
}
