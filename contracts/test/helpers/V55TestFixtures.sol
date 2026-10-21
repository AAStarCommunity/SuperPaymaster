// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

// Shared SP 5.5.0 test fixtures (see V2TestFixtures.sol for why these live outside *.t.sol).

contract V55Registry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(address => uint256) public creditLimit;
    function setRole(bytes32 role, address a, bool v) external { roles[role][a] = v; }
    function hasRole(bytes32 role, address a) external view returns (bool) { return roles[role][a]; }
    function getCreditLimit(address u) external view returns (uint256) { return creditLimit[u]; }
    function setCreditLimit(address u, uint256 v) external { creditLimit[u] = v; }
}

contract V55PriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract V55APNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract V55Counter {
    uint256 public n;
    function inc() external { n += 1; }
}

interface IV2Ext {
    function mint(address to, uint256 amount) external;
    function queueCreditPolicy(uint8 p) external;
    function executeCreditPolicy() external;
    function requestCredit(uint256 maxCap) external;
}

