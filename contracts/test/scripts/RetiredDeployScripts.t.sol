// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DeployNewBLSModules} from "../../script/v3/DeployNewBLSModules.s.sol";
import {DeployV54} from "../../script/v3/DeployV54.s.sol";

/// @notice Both scripts deployed with a plain `new` from a runs=200-compiled file; from 5.5.0
///         their run() must refuse instead of shipping registry-size bytecode.
contract RetiredDeployScriptsTest is Test {
    function test_DeployNewBLSModulesRunReverts() public {
        DeployNewBLSModules s = new DeployNewBLSModules();
        vm.expectRevert(bytes("DeployNewBLSModules: retired since 5.5.0 (ships runs=200 bytecode); use DeployLive/UpgradeLive"));
        s.run();
    }

    function test_DeployV54RunReverts() public {
        DeployV54 s = new DeployV54();
        vm.expectRevert(bytes("DeployV54: retired since 5.5.0 (ships runs=200 bytecode); use DeployLive/UpgradeLive"));
        s.run();
    }
}
