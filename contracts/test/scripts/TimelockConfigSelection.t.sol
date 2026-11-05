// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {D5bUpgradeChecks} from "../../script/v3/UpgradeViaTimelock.s.sol";
import {UpgradeLive} from "../../script/v3/UpgradeLive.s.sol";

contract TimelockSelectionHarness is D5bUpgradeChecks {}

contract TimelockConfigSelectionTest is Test {
    TimelockSelectionHarness selector;
    string migrated;

    function setUp() public {
        selector = new TimelockSelectionHarness();
        migrated = vm.readFile("deployments/config.sepolia.json");
    }

    function test_negative_migratedConfigRequiresExplicitTimelock() public {
        vm.expectRevert("TIMELOCK required after migration: A3a is Safe-only; EOA cannot schedule/execute");
        selector.selectTimelock(migrated, address(0));
    }

    function test_explicitCanonicalTimelock_passes() public view {
        address canonical = vm.parseJsonAddress(migrated, ".timelockController");
        assertEq(selector.selectTimelock(migrated, canonical), canonical);
    }

    function test_explicitLegacyTimelock_preserved() public view {
        address legacy = vm.parseJsonAddress(migrated, ".timelockControllerLegacy");
        assertEq(selector.selectTimelock(migrated, legacy), legacy);
    }

    function test_unmigratedLocalConfig_preserved() public view {
        assertEq(selector.selectTimelock('{"timelockController":"0x0000000000000000000000000000000000000001"}', address(0)), address(1));
    }

    function test_negative_upgradeLiveRejectsMigratedConfigBeforeBroadcast() public {
        vm.setEnv("ENV", "sepolia");
        UpgradeLive upgrade = new UpgradeLive();
        vm.expectRevert("UpgradeLive: migrated timelock config; use reviewed Safe upgrade/deployment flow");
        upgrade.run();
    }
}
