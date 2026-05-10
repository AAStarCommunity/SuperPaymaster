// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "src/core/Registry.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

/**
 * @title RegisterEnduser
 * @notice Register AA accounts as ENDUSER in Registry (sets SBT holder status)
 * @dev Must be called by a registered Community (e.g., Anni)
 *      Reads addresses from deployments/config.<ENV>.json
 */
contract RegisterEnduser is Script {
    function run() external {
        string memory network = vm.envString("ENV");
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory json = vm.readFile(configPath);

        address registryAddr = stdJson.readAddress(json, ".registry");
        address gtokenAddr = stdJson.readAddress(json, ".gToken");
        address stakingAddr = stdJson.readAddress(json, ".staking");
        address superPaymasterAddr = stdJson.readAddress(json, ".superPaymaster");

        Registry registry = Registry(registryAddr);
        bytes32 roleEnduser = registry.ROLE_ENDUSER();

        // AA accounts from environment
        address aaA = vm.envAddress("TEST_AA_ACCOUNT_ADDRESS_A");
        address aaB = vm.envAddress("TEST_AA_ACCOUNT_ADDRESS_B");
        address aaC = vm.envAddress("TEST_AA_ACCOUNT_ADDRESS_C");
        address anni = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9;

        address[] memory aaAccounts = new address[](3);
        aaAccounts[0] = aaA;
        aaAccounts[1] = aaB;
        aaAccounts[2] = aaC;

        // Broadcast with caller's key (must be a registered Community)
        vm.startBroadcast();
        console.log("Broadcaster:", msg.sender);

        // Approve staking for GToken (3 accounts x 0.3 GToken = 0.9, with margin)
        IERC20(gtokenAddr).approve(stakingAddr, 2 ether);

        for (uint i = 0; i < aaAccounts.length; i++) {
            if (registry.hasRole(roleEnduser, aaAccounts[i])) {
                console.log("Already registered:", aaAccounts[i]);
                continue;
            }

            Registry.EndUserRoleData memory data = Registry.EndUserRoleData({
                community: anni,
                avatarURI: "",
                ensName: "",
                stakeAmount: 0.3 ether
            });

            console.log("Registering ENDUSER:", aaAccounts[i]);
            registry.safeMintForRole(roleEnduser, aaAccounts[i], abi.encode(data));
            console.log("  Registered + SBT set");
        }

        // Update SuperPaymaster cached price
        SuperPaymaster sp = SuperPaymaster(payable(superPaymasterAddr));
        console.log("Updating cached price...");
        sp.updatePrice();
        console.log("  Price updated");

        vm.stopBroadcast();

        // Verify SBT status
        for (uint i = 0; i < aaAccounts.length; i++) {
            bool hasSBT = sp.sbtHolders(aaAccounts[i]);
            console.log("SBT status for", aaAccounts[i], ":", hasSBT);
        }
    }
}
