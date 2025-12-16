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
contract MockERC20_Optimized is Script {
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


contract DeployAllV3_Optimized is Script {

    function _preBroadcast() internal returns (uint256 deployerPrivateKey, address deployer) {
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);
        vm.startBroadcast(deployerPrivateKey);
    }

    function deployGToken() external returns (GToken) {
        (, address deployer) = _preBroadcast();
        uint256 gTokenCap = 21_000_000 * 1e18;
        GToken gToken = new GToken(gTokenCap);
        console.log("GToken deployed to:", address(gToken));
        vm.stopBroadcast();
        return gToken;
    }

    function deployGTokenStaking(address gTokenAddr) external returns (GTokenStaking) {
        (, address deployer) = _preBroadcast();
        GTokenStaking gTokenStaking = new GTokenStaking(gTokenAddr, deployer);
        console.log("GTokenStaking deployed to:", address(gTokenStaking));
        vm.stopBroadcast();
        return gTokenStaking;
    }

    function deployMySBT(address gTokenAddr, address gTokenStakingAddr) external returns (MySBT) {
        (, address deployer) = _preBroadcast();
        // Use address(0) as placeholder for Registry, it will be wired later
        MySBT mySBT = new MySBT(gTokenAddr, gTokenStakingAddr, address(0), deployer);
        console.log("MySBT deployed to:", address(mySBT));
        vm.stopBroadcast();
        return mySBT;
    }

    function deployRegistry(address gTokenAddr, address gTokenStakingAddr, address mySBTAddr) external returns (Registry) {
        _preBroadcast();
        Registry registry = new Registry(gTokenAddr, gTokenStakingAddr, mySBTAddr);
        console.log("Registry deployed to:", address(registry));
        vm.stopBroadcast();
        return registry;
    }

    function deployMockAPNTs() external returns (address) {
        _preBroadcast();
        MockERC20_Optimized aPNTs = new MockERC20_Optimized("AAStar PNT A (Mock)", "aPNTs");
        console.log("aPNTs (Mock) deployed to:", address(aPNTs));
        vm.stopBroadcast();
        return address(aPNTs);
    }

    function deploySuperPaymaster(address registryAddr, address aPNTsAddr) external returns (SuperPaymasterV3) {
        (, address deployer) = _preBroadcast();
        IEntryPoint entryPoint = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address ethUsdPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Sepolia ETH/USD

        SuperPaymasterV3 superPaymaster = new SuperPaymasterV3(
            entryPoint,
            deployer, // owner
            Registry(registryAddr), // registry
            aPNTsAddr, // aPNTs token
            ethUsdPriceFeed, // price feed
            deployer  // protocol treasury
        );
        console.log("SuperPaymasterV3 deployed to:", address(superPaymaster));
        vm.stopBroadcast();
        return superPaymaster;
    }

    function wireUpContracts(address mySBTAddr, address gTokenStakingAddr, address registryAddr) external {
        _preBroadcast();
        MySBT(mySBTAddr).setRegistry(registryAddr);
        console.log("Called mySBT.setRegistry()");
        GTokenStaking(gTokenStakingAddr).setRegistry(registryAddr);
        console.log("Called gTokenStaking.setRegistry()");
        vm.stopBroadcast();
    }

    function mintInitialTokens(address gTokenAddr, address aPNTsAddr) external {
        (uint256 deployerPrivateKey, address deployer) = _preBroadcast();
        GToken(gTokenAddr).mint(deployer, 1_000_000 * 1e18);
        MockERC20_Optimized(aPNTsAddr).mint(deployer, 1_000_000 * 1e18);
        console.log("Minted initial supply of GToken and aPNTs to deployer.");
        vm.stopBroadcast();
    }
}
