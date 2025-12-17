// SPDX-License-Identifier: MIT
// 10_RegisterCommunity.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";

contract Deploy10_RegisterCommunity is Script {
    // This struct must match the one in Registry.sol
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

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Registering Deployer as a Community with account:", deployer);

        // The minimum stake for a community is defined in the Registry contract.
        // We will approve a large amount to cover any logic (stake + fees).
        uint256 stakeAmount = 11 * 1e18; // Actual stake needed
        uint256 approveAmount = 100000 * 1e18; // Large approval as requested

        vm.startBroadcast(deployerPrivateKey);

        // 1. Approve the GTokenStaking contract to spend our GToken
        GToken(gTokenAddr).approve(gTokenStakingAddr, approveAmount);
        console.log("Approved GTokenStaking to spend", approveAmount / 1e18, "GToken.");

        // 2. Prepare the community data
        CommunityRoleData memory communityData = CommunityRoleData({
            name: "AAStar Community",
            ensName: "aastar.eth",
            website: "https://aastar.com",
            description: "The first community on the new SuperPaymaster V3 system.",
            logoURI: "ipfs://...",
            stakeAmount: stakeAmount
        });

        // 3. Call registerRole on the Registry
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        IRegistryV3(registryAddr).registerRole(
            ROLE_COMMUNITY,
            deployer,
            abi.encode(communityData)
        );

        vm.stopBroadcast();

        console.log("Successfully registered", communityData.name, "in the Registry.");
    }
}
