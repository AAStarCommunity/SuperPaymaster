// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// This is a mock ERC20 token for testing purposes, specifically for aPNTs.
contract MockERC20 is Script {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "ERC20: mint to the zero address");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract Deploy05_MockAPNTs is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying Mock aPNTs with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        MockERC20 aPNTs = new MockERC20("AAStar PNT A (Mock)", "aPNTs");

        vm.stopBroadcast();

        console.log("aPNTs (Mock) deployed to:", address(aPNTs));
    }
}