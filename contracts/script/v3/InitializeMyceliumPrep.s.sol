// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";

/**
 * @title InitializeMyceliumPrep
 * @notice Deployer-signed prerequisite for InitializeMycelium.
 *         Grants ROLE_COMMUNITY + ROLE_PAYMASTER_AOA to Anni and mints GToken
 *         for her staking deposit. Run as DEPLOYER_ACCOUNT before InitializeMycelium.
 *
 *   source .env.op-mainnet
 *   forge script contracts/script/v3/InitializeMyceliumPrep.s.sol:InitializeMyceliumPrep \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast --slow -vv
 */
contract InitializeMyceliumPrep is Script {
    bytes32 constant ROLE_COMMUNITY     = keccak256("COMMUNITY");
    bytes32 constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");

    function run() external {
        string memory network  = vm.envOr("ENV", string("op-mainnet"));
        string memory cfgPath  = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory json     = vm.readFile(cfgPath);

        address anniAddr    = vm.envAddress("ANNI_ADDRESS");
        address registryAddr = vm.parseJsonAddress(json, ".registry");
        address stakingAddr  = vm.parseJsonAddress(json, ".staking");
        address gTokenAddr   = vm.parseJsonAddress(json, ".gToken");

        Registry registry = Registry(registryAddr);
        GToken gtoken     = GToken(gTokenAddr);

        vm.startBroadcast();

        // Mint GToken to deployer for staking on Anni's behalf (deployer pays)
        // In production, deployer must already hold enough GToken.
        // 50 ether for COMMUNITY stake + 50 ether for PAYMASTER_AOA = 100 ether buffer.
        console.log("[InitializeMyceliumPrep] Deployer GToken balance:", gtoken.balanceOf(msg.sender));

        if (!registry.hasRole(ROLE_COMMUNITY, anniAddr)) {
            console.log("[InitializeMyceliumPrep] Registering Mycelium as COMMUNITY for Anni...");
            gtoken.approve(stakingAddr, 50 ether);
            Registry.CommunityRoleData memory mycData = Registry.CommunityRoleData({
                name: "Mycelium Community",
                ensName: "mushroom.box",
                stakeAmount: 30 ether
            });
            registry.safeMintForRole(ROLE_COMMUNITY, anniAddr, abi.encode(mycData));
            console.log("  Mycelium COMMUNITY registered for Anni");
        } else {
            console.log("[InitializeMyceliumPrep] Anni already has ROLE_COMMUNITY, skip");
        }

        if (!registry.hasRole(ROLE_PAYMASTER_AOA, anniAddr)) {
            console.log("[InitializeMyceliumPrep] Granting ROLE_PAYMASTER_AOA to Anni...");
            gtoken.approve(stakingAddr, 50 ether);
            registry.registerRole(ROLE_PAYMASTER_AOA, anniAddr, "");
            console.log("  ROLE_PAYMASTER_AOA granted to Anni");
        } else {
            console.log("[InitializeMyceliumPrep] Anni already has ROLE_PAYMASTER_AOA, skip");
        }

        console.log("[InitializeMyceliumPrep] Done. Anni is ready to run InitializeMycelium.s.sol");
        vm.stopBroadcast();
    }
}
