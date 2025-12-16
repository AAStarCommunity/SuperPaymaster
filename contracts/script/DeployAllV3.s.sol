// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";
import "src/core/GTokenStaking.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import {IEntryPoint} from "account-abstraction-v7/interfaces/IEntryPoint.sol";

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

contract DeployAllV3 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("--- V3 Core Deployment ---");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        console.log("--------------------------");

        vm.startBroadcast(deployerPrivateKey);

        // 1. GToken (Governance Token)
        uint256 gTokenCap = 21_000_000 * 1e18;
        GToken gToken = new GToken(gTokenCap);
        console.log("GToken deployed to:", address(gToken));

        // 2. GTokenStaking (Handles all staking and burning logic)
        GTokenStaking gTokenStaking = new GTokenStaking(address(gToken), deployer);
        console.log("GTokenStaking deployed to:", address(gTokenStaking));

        // 3. MySBT (Identity Layer) - Deployed with placeholder for Registry
        MySBT mySBT = new MySBT(address(gToken), address(gTokenStaking), address(0), deployer);
        console.log("MySBT deployed to:", address(mySBT));

        // 4. Registry (The Core Brain) - Deployed with the real contract addresses
        Registry registry = new Registry(address(gToken), address(gTokenStaking), address(mySBT));
        console.log("Registry deployed to:", address(registry));

        // 5. SuperPaymasterV3 (Shared Paymaster Service)
        IEntryPoint entryPoint = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD
        MockERC20 aPNTs = new MockERC20("AAStar PNT A (Mock)", "aPNTs");
        console.log("aPNTs (Mock) deployed to:", address(aPNTs));

        SuperPaymasterV3 superPaymaster = new SuperPaymasterV3(
            entryPoint,
            deployer, // owner
            registry, // registry
            address(aPNTs), // aPNTs token
            ethUsdPriceFeed, // price feed
            deployer  // protocol treasury
        );
        console.log("SuperPaymasterV3 deployed to:", address(superPaymaster));

        // --- Wiring ---
        console.log("--- Wiring Contracts ---");
        mySBT.setRegistry(address(registry));
        console.log("Called mySBT.setRegistry()");
        gTokenStaking.setRegistry(address(registry));
        console.log("Called gTokenStaking.setRegistry()");
        
        // --- Post-Deployment Minting ---
        gToken.mint(deployer, 1_000_000 * 1e18);
        aPNTs.mint(deployer, 1_000_000 * 1e18);
        console.log("Minted initial supply of GToken and aPNTs to deployer.");

        vm.stopBroadcast();
        
        console.log("--- Deployment Complete ---");
    }
}
