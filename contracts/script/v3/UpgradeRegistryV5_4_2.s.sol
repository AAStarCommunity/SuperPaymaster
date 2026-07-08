// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/core/Registry.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeRegistryV5_4_2
 * @notice UUPS upgrade: Registry 5.4.1 -> 5.4.2 (#324 M-2 non-fatal updateSBTStatus).
 *
 * Change: pure EIP-170 compression — the setRoleExitFee encode+call+SyncFailed sequence was
 * deduplicated into _safeSetRoleExitFee (25,019 -> 23,621 runtime). This also finally lands the
 * P0-2/P0-3 CEI unchecked-call guards on-chain (the deployed 5.4.0 predates them because that fix
 * pushed Registry over EIP-170 and was never deployable). No new storage, no reinitializer.
 *
 * onlyOwner, no timelock. Idempotent (skips if already at target).
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeRegistryV5_4_2.s.sol:UpgradeRegistryV5_4_2 \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
 */
contract UpgradeRegistryV5_4_2 is Script {
    string constant TARGET = "Registry-5.4.2";

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registryProxy = vm.parseJsonAddress(config, ".registry");
        Registry reg = Registry(registryProxy);

        console.log("=== UUPS Upgrade: Registry v5.4.1 (#210) ===");
        console.log("  Registry proxy:", registryProxy);

        // Snapshot for storage-integrity guard.
        string memory before = reg.version();
        address ownerBefore   = reg.owner();
        address stakingBefore = address(reg.GTOKEN_STAKING());
        address sbtBefore      = address(reg.MYSBT());
        address spBefore       = reg.SUPER_PAYMASTER();
        address blsAggBefore   = reg.blsAggregator();
        console.log("  Registry before:", before);

        address newImpl;
        vm.startBroadcast();
        if (keccak256(bytes(before)) != keccak256(bytes(TARGET))) {
            newImpl = address(new Registry());
            console.log("  New Registry impl:", newImpl);
            UUPSUpgradeable(registryProxy).upgradeToAndCall(newImpl, "");
            console.log("  Registry upgradeToAndCall executed");
        } else {
            console.log("  Registry already at target - skipping");
            bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
            newImpl = address(uint160(uint256(vm.load(registryProxy, slot))));
        }
        vm.stopBroadcast();

        // Post-upgrade verification (revert on any drift).
        require(keccak256(bytes(reg.version())) == keccak256(bytes(TARGET)), "V: version mismatch");
        require(reg.owner() == ownerBefore,                       "V: owner drifted");
        require(address(reg.GTOKEN_STAKING()) == stakingBefore,   "V: GTOKEN_STAKING drifted");
        require(address(reg.MYSBT()) == sbtBefore,                 "V: MYSBT drifted");
        require(reg.SUPER_PAYMASTER() == spBefore,                 "V: SUPER_PAYMASTER drifted");
        require(reg.blsAggregator() == blsAggBefore,               "V: blsAggregator drifted");
        console.log("  Verified: version + storage integrity (staking/sbt/sp/blsAggregator)");

        string memory srcHash    = vm.envOr("SRC_HASH",    vm.parseJsonString(config, ".srcHash"));
        string memory updateTime = vm.envOr("DEPLOY_TIME", vm.parseJsonString(config, ".updateTime"));
        vm.writeJson(vm.toString(newImpl), configPath, ".registryImpl");
        vm.writeJson(srcHash,              configPath, ".srcHash");
        vm.writeJson(updateTime,           configPath, ".updateTime");
        _ensureTrailingNewline(configPath);

        console.log("  Config patched: registryImpl =", newImpl);
        console.log("=== Registry upgrade successful! ===");
    }

    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
