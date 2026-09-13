// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { UpgradeViaTimelock, UpgradeRegistryD5b } from "../../script/v3/UpgradeViaTimelock.s.sol";

/// @notice `forge build` / `forge test` do not compile contracts/script (scripts/check-live-scripts-compile.sh
///         explains why). Importing the D5b upgrade scripts here makes every CI build type-check them;
///         their behaviour is rehearsed on anvil (docs/design/aoa-balance-mode/data/d5b/).
contract D5bScriptsCompileTest is Test {
    function test_d5b_upgrade_scripts_compile() public pure {
        assertTrue(UpgradeViaTimelock.run.selector != bytes4(0));
        assertTrue(UpgradeRegistryD5b.run.selector != bytes4(0));
    }
}
