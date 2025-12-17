// SPDX-License-Identifier: MIT
// 10_1_RegisterBreadCommunity.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";

contract Deploy10_1_RegisterBreadCommunity is Script {
    struct CommunityRoleData {
        string name;
        string ensName;
        string website;
        string description;
        string logoURI;
        uint256 stakeAmount;
    }

    function run(
        address registryAddr,
        address gTokenAddr,
        address gTokenStakingAddr
    ) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");
        require(gTokenAddr != address(0), "GToken address cannot be zero.");
        require(gTokenStakingAddr != address(0), "GTokenStaking address cannot be zero.");

        // 1. Setup Keys
        uint256 jasonKey = vm.envUint("PRIVATE_KEY");
        address jason = vm.addr(jasonKey);
        
        uint256 anniKey = vm.envUint("PRIVATE_KEY_ANNI");
        address anni = vm.addr(anniKey);

        console.log("---------------------------------------");
        console.log("Registering Bread Community (Anni)");
        console.log("Funder (Jason):", jason);
        console.log("Registrant (Anni):", anni);

        uint256 stakeAmount = 11 * 1e18; 
        uint256 fundAmount = 100 * 1e18; // Give Anni enough tokens
        uint256 approveAmount = 10000000 * 1e18; // Mega Approval

        // 2. Jason funds Anni with GTokens
        vm.startBroadcast(jasonKey);
        GToken(gTokenAddr).transfer(anni, fundAmount);
        console.log("Jason transferred", fundAmount/1e18, "GTokens to Anni.");
        vm.stopBroadcast();

        // 3. Anni registers herself
        vm.startBroadcast(anniKey);

        // Anni Approves Staking Contract
        GToken(gTokenAddr).approve(gTokenStakingAddr, approveAmount);
        console.log("Anni Approved GTokenStaking to spend", approveAmount / 1e18, "GToken.");

        // Prepare Data
        CommunityRoleData memory communityData = CommunityRoleData({
            name: "BreadCommunity",
            ensName: "breadcommunity.eth",
            website: "https://bread.com",
            description: "A community for bread lovers.",
            logoURI: "ipfs://bread...",
            stakeAmount: stakeAmount
        });

        // Register
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        IRegistryV3(registryAddr).registerRole(
            ROLE_COMMUNITY,
            anni, 
            abi.encode(communityData)
        );

        vm.stopBroadcast();
        console.log("Successfully registered BreadCommunity (Owner: Anni).");
    }
}
