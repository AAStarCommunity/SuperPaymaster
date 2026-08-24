// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "src/core/Registry.sol";

interface ITimelockBatch {
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    function getMinDelay() external view returns (uint256);
}

/**
 * @title UpgradeRegistryTo560
 * @notice CC-48 MEDIUM-3: build the ONE governance batch that takes a live Registry
 *         proxy to 5.6.0. All three steps must land in a single transaction.
 *
 *   1. upgradeToAndCall(newImpl, "")
 *   2. setBLSAggregator(BLSAggregator 4.5.0)
 *   3. setCreditPolicy(perProposalCap, totalCap, exposureBaseline, true)
 *
 * Why atomic — each gap is a real, observable outage, not a theoretical one:
 *
 *   - Between (1) and (3) the new `maxTotalCreditExposure` slot reads 0, so EVERY
 *     proposal carrying positive uplift reverts. Fail-closed in the right direction,
 *     but it is a governance halt on the reputation path.
 *   - Between (1) and (2) the still-wired 4.3.x aggregator has no
 *     `consumeGuardianExit`, and BLSAggregator has no fallback, so Registry's call
 *     reverts: every ROLE_DVT `exitRole` fails and DVT stake is temporarily stuck.
 *   - Seeding `exposureBaseline` in the same batch is what stops the protocol-wide
 *     budget from starting at 0 and silently under-counting every pre-upgrade user.
 *
 * The script refuses to emit a non-atomic path: `owner` must be a contract (Safe /
 * TimelockController). That is the CC-48 MEDIUM-1 deployment gate — the fraud-proof
 * verifier now carries an in-contract rotation delay, and the owner of both Registry
 * and BLSAggregator must still sit behind governance, not a hot EOA.
 *
 * Env:
 *   REGISTRY_PROXY               live Registry ERC1967 proxy
 *   NEW_BLS_AGGREGATOR           BLSAggregator 4.5.0 (already deployed + wired)
 *   CREDIT_PER_PROPOSAL_CAP      aPNT wei, transaction-level guard
 *   CREDIT_TOTAL_CAP             aPNT wei, protocol-wide outstanding ceiling
 *   CREDIT_EXPOSURE_BASELINE     aPNT wei, sum of existing users' credit limits
 *                                (computed off-chain from GlobalReputationUpdated)
 *   TIMELOCK (optional)          if set, also print scheduleBatch/executeBatch calldata
 *   ALLOW_EOA_OWNER (optional)   escape hatch for local/anvil runs ONLY
 */
contract UpgradeRegistryTo560 is Script {
    function run() external {
        address proxy = vm.envAddress("REGISTRY_PROXY");
        address newAggregator = vm.envAddress("NEW_BLS_AGGREGATOR");
        uint256 perProposalCap = vm.envUint("CREDIT_PER_PROPOSAL_CAP");
        uint256 totalCap = vm.envUint("CREDIT_TOTAL_CAP");
        uint256 baseline = vm.envUint("CREDIT_EXPOSURE_BASELINE");

        Registry registry = Registry(proxy);
        address owner = registry.owner();

        console.log("Registry proxy      :", proxy);
        console.log("current version     :", registry.version());
        console.log("current owner       :", owner);

        // ---- governance gate (CC-48 MEDIUM-1) ----
        bool allowEoa = vm.envOr("ALLOW_EOA_OWNER", false);
        require(
            owner.code.length > 0 || allowEoa,
            "CC-48: Registry owner must be a Safe/TimelockController, not an EOA"
        );
        require(
            totalCap >= baseline,
            "CC-48: totalCap below the seeded baseline would freeze the reputation path on day one"
        );
        require(perProposalCap <= totalCap, "CC-48: per-proposal cap above the protocol ceiling is meaningless");
        require(totalCap > 0, "CC-48: zero protocol ceiling is fail-closed; set a real number");

        vm.startBroadcast();
        Registry newImpl = new Registry();
        vm.stopBroadcast();
        console.log("new Registry impl   :", address(newImpl));
        require(
            keccak256(bytes(newImpl.version())) == keccak256("Registry-5.6.0"),
            "CC-48: freshly built impl is not Registry-5.6.0"
        );

        address[] memory targets = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);

        targets[0] = proxy;
        payloads[0] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes(""));
        targets[1] = proxy;
        payloads[1] = abi.encodeCall(Registry.setBLSAggregator, (newAggregator));
        targets[2] = proxy;
        payloads[2] = abi.encodeCall(Registry.setCreditPolicy, (perProposalCap, totalCap, baseline, true));

        console.log("--- atomic governance batch (execute as ONE transaction) ---");
        for (uint256 i = 0; i < 3; i++) {
            console.log("target", i, targets[i]);
            console.logBytes(payloads[i]);
        }

        address timelock = vm.envOr("TIMELOCK", address(0));
        if (timelock != address(0)) {
            uint256 delay = ITimelockBatch(timelock).getMinDelay();
            console.log("--- TimelockController.scheduleBatch calldata (delay:", delay, ") ---");
            console.logBytes(
                abi.encodeCall(
                    ITimelockBatch.scheduleBatch,
                    (targets, values, payloads, bytes32(0), bytes32(uint256(0x5600)), delay)
                )
            );
            console.log("--- TimelockController.executeBatch calldata ---");
            console.logBytes(
                abi.encodeCall(
                    ITimelockBatch.executeBatch,
                    (targets, values, payloads, bytes32(0), bytes32(uint256(0x5600)))
                )
            );
        }

        console.log("--- post-execution assertions to run before declaring success ---");
        console.log("  registry.version()                       == Registry-5.6.0");
        console.log("  registry.blsAggregator()                 ==", newAggregator);
        console.log("  registry.maxTotalCreditExposure()        ==", totalCap);
        console.log("  registry.totalCreditExposure()           ==", baseline);
        console.log("  registry.owner()                         ==", owner);
    }
}
