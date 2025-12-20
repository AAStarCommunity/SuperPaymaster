// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/core/GTokenStaking.sol";

contract RegisterScenarioCommunities is Script {
    function run() external {
        uint256 deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerPK);
        
        // Addresses from local deployment (Update if fresh deploy changes these!)
        address registryAddr = 0x1c85638e118b37167e9298c2268758e058DdfDA0;
        address gtokenAddr = 0x46b142DD1E924FAb83eCc3c08e4D46E82f005e0E;
        address stakingAddr = 0xC9a43158891282A2B1475592D5719c001986Aaec;

        Registry registry = Registry(registryAddr);
        GToken gtoken = GToken(gtokenAddr);
        GTokenStaking staking = GTokenStaking(stakingAddr);

        vm.startBroadcast(deployerPK);

        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

        // --- 1. Register "BreadDAO" ---
        // PK: 0xea6c... matches Address: 0x2546BcD3c84621e976D8185a91A922aE77ECEc30 (Anvil #4 in some lists, or #3 in others)
        address breadAdmin = 0x2546BcD3c84621e976D8185a91A922aE77ECEc30; 
        uint256 breadPK = 0xea6c44ac03bff858b476bba40716402b03e41b8e97e276d1baec7c37d42484a0;
        vm.deal(breadAdmin, 100 ether);
        
        // Setup Bread Data
        Registry.CommunityRoleData memory breadData = Registry.CommunityRoleData({
            name: "BreadDAO",
            ensName: "bread.eth",
            website: "https://bread.dao",
            description: "Independent Baking Community",
            logoURI: "ipfs://bread",
            stakeAmount: 10 ether
        });

        // Fund Bread Admin with GTokens (Mint + Transfer from Deployer)
        gtoken.mint(breadAdmin, 100 ether);
        
        // Switch to BreadAdmin to Approve & Register
        vm.stopBroadcast();
        vm.startBroadcast(breadPK); // Anvil #3 (Bread)
        
        gtoken.approve(address(staking), 100 ether);
        
        try registry.registerRole(ROLE_COMMUNITY, breadAdmin, abi.encode(breadData)) {
            console.log("BreadDAO Registered");
        } catch Error(string memory reason) {
            console.log("BreadDAO Registration Failed:", reason);
        } catch {
            console.log("BreadDAO Registration Failed (Unknown)");
        }
        
        vm.stopBroadcast();


        // --- 2. Register "C-Community" ---
        vm.startBroadcast(deployerPK);
        address cAdmin = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // Anvil #2
        vm.deal(cAdmin, 100 ether);
        
        Registry.CommunityRoleData memory cData = Registry.CommunityRoleData({
            name: "C-Community",
            ensName: "c.eth",
            website: "https://c.com",
            description: "Shared SuperPaymaster Community",
            logoURI: "ipfs://c",
            stakeAmount: 10 ether
        });

        gtoken.mint(cAdmin, 100 ether);
        
        vm.stopBroadcast();
        vm.startBroadcast(0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a); // Anvil #2 (C)
        
        gtoken.approve(address(staking), 100 ether);
        
        try registry.registerRole(ROLE_COMMUNITY, cAdmin, abi.encode(cData)) {
            console.log("C-Community Registered");
        } catch {
             console.log("C-Community Registration Failed (Likely Exists)");
        }

        vm.stopBroadcast();
    }
}
