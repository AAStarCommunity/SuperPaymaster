// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/interfaces/v3/IRegistryV3.sol";

/**
 * @title OneShotRegister
 * @notice Performs only the registerRole call to avoid RPC in-flight limits.
 * @dev Assumes GToken.approve has already been successfully executed.
 */
contract OneShotRegister is Script {
    struct CommunityRoleData {
        string name;
        string ensName;
        string website;
        string description;
        string logoURI;
        uint256 stakeAmount;
    }

    function run(address registryAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Match the data from 10_RegisterCommunity.s.sol
        uint256 stakeAmount = 10 ether;
        CommunityRoleData memory communityData = CommunityRoleData({
            name: "AAStar Community",
            ensName: "aastar.eth",
            website: "https://aastar.com",
            description: "The first community on the new SuperPaymaster V3 system.",
            logoURI: "ipfs://...",
            stakeAmount: stakeAmount
        });

        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

        vm.startBroadcast(deployerPrivateKey);

        IRegistryV3(registryAddr).registerRole(
            ROLE_COMMUNITY,
            deployer,
            abi.encode(communityData)
        );

        vm.stopBroadcast();

        console.log("Successfully registered", communityData.name, "in the Registry via One-Shot.");
    }
}
