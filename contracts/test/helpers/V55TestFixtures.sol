// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "src/interfaces/v3/IRegistry.sol";

// Shared SP 5.5.0 test fixtures (see V2TestFixtures.sol for why these live outside *.t.sol).

contract V55Registry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(address => uint256) public creditLimit;
    mapping(bytes32 => uint256) public minStake;
    mapping(bytes32 => mapping(address => uint256)) public effectiveStake;
    function setRole(bytes32 role, address a, bool v) external {
        roles[role][a] = v;
        if (v && role == ROLE_PAYMASTER_SUPER) {
            if (minStake[role] == 0) minStake[role] = 1;
            effectiveStake[role][a] = minStake[role];
        }
    }
    function setStake(bytes32 role, address a, uint256 minimum, uint256 effective) external {
        minStake[role] = minimum;
        effectiveStake[role][a] = effective;
    }
    function hasRole(bytes32 role, address a) external view returns (bool) { return roles[role][a]; }
    function getRoleConfig(bytes32 role) external view returns (IRegistry.RoleConfig memory config) {
        config.minStake = minStake[role];
    }
    function getEffectiveStake(address a, bytes32 role) external view returns (uint256) {
        return effectiveStake[role][a];
    }
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

