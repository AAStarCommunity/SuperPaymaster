// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";

contract ConfigureMyTaskRoles is Script {
    bytes32 internal constant ROLE_JURY = keccak256("JURY");
    bytes32 internal constant ROLE_PUBLISHER = keccak256("PUBLISHER");
    bytes32 internal constant ROLE_TASKER = keccak256("TASKER");
    bytes32 internal constant ROLE_SUPPLIER = keccak256("SUPPLIER");

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address registryAddr = vm.envAddress("REGISTRY_ADDRESS");
        address roleOwner = vm.envAddress("MYTASK_ROLE_OWNER");

        Registry registry = Registry(registryAddr);

        console.log("=== Configure MyTask Roles ===");
        console.log("Deployer:", deployer);
        console.log("Registry:", registryAddr);
        console.log("RoleOwner:", roleOwner);

        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 0.3 ether,
            entryBurn: 0.05 ether,
            slashThreshold: 0,
            slashBase: 0,
            slashInc: 0,
            slashMax: 0,
            exitFeePercent: 1000,
            minExitFee: 0.05 ether,
            isActive: true,
            description: "MyTask Role",
            owner: roleOwner,
            roleLockDuration: 7 days
        });

        vm.startBroadcast(deployerPrivateKey);
        _upsertRole(registry, ROLE_JURY, config, roleOwner);
        _upsertRole(registry, ROLE_PUBLISHER, config, roleOwner);
        _upsertRole(registry, ROLE_TASKER, config, roleOwner);
        _upsertRole(registry, ROLE_SUPPLIER, config, roleOwner);
        vm.stopBroadcast();
    }

    function _upsertRole(Registry registry, bytes32 roleId, IRegistry.RoleConfig memory config, address roleOwner)
        internal
    {
        address currentOwner = registry.roleOwners(roleId);
        if (currentOwner == address(0)) {
            registry.createNewRole(roleId, config, roleOwner);
            return;
        }

        if (currentOwner != roleOwner) {
            registry.setRoleOwner(roleId, roleOwner);
        }

        registry.configureRole(roleId, config);
    }
}

