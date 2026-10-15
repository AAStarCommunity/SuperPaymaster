// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {DeployAPNTsCapped} from "../../script/v3/DeployAPNTsCapped.s.sol";

contract DeployAPNTsCappedHarness is DeployAPNTsCapped {
    // Supply genuine constructor/grant/revoke logs from the local EVM in place of RPC history.
    function _readTimelockRoleLogs(address) internal override returns (Vm.Log[] memory) {
        return vm.getRecordedLogs();
    }

    function checkTimelock(address timelock, address deployer) external {
        _checkTimelock(timelock, deployer);
    }
}

/// @dev Exercise the real chunking/depth/constructor-control path, substituting only RPC IO.
contract TimelockHistoryScanHarness is DeployAPNTsCapped {
    bytes private recorded;
    uint256 private creationBlock;
    uint256 private scanFrom;
    uint256 public batches;

    function setHistory(Vm.Log[] memory logs, uint256 createdAt) external {
        recorded = abi.encode(logs);
        creationBlock = createdAt;
        scanFrom = createdAt;
    }

    function checkTimelock(address timelock, address deployer) external {
        _checkTimelock(timelock, deployer);
    }

    function setScanFrom(uint256 height) external {
        scanFrom = height;
    }

    function _timelockDeploymentBlock() internal view override returns (uint256) {
        return scanFrom;
    }

    function _historicalCode(address, uint256 height) internal view override returns (bytes memory) {
        if (height >= creationBlock) return hex"01";
        return hex"";
    }

    function _timelockLogBatch(uint256 start, uint256 end, address)
        internal
        override
        returns (Vm.EthGetLogs[] memory out)
    {
        ++batches;
        Vm.Log[] memory logs = abi.decode(recorded, (VmSafe.Log[]));
        if (creationBlock < start || creationBlock > end) return new Vm.EthGetLogs[](0);
        out = new Vm.EthGetLogs[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            out[i].emitter = logs[i].emitter;
            out[i].topics = logs[i].topics;
            out[i].data = logs[i].data;
            out[i].blockNumber = uint64(creationBlock);
            out[i].logIndex = i;
        }
    }
}

contract DeployAPNTsCappedTest is Test {
    address constant SAFE = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;
    address constant DEPLOYER = address(0xD001);
    address constant EXTRA = address(0xBAD);
    DeployAPNTsCappedHarness checker;

    function setUp() public {
        checker = new DeployAPNTsCappedHarness();
    }

    function _timelock(address admin, bool extraExecutor) internal returns (TimelockController tl) {
        vm.recordLogs();
        address[] memory proposers = new address[](1);
        proposers[0] = SAFE;
        address[] memory executors = new address[](extraExecutor ? 2 : 1);
        executors[0] = SAFE;
        if (extraExecutor) executors[1] = EXTRA;
        tl = new TimelockController(172800, proposers, executors, admin);
    }

    function test_correctTimelock_passes() public {
        checker.checkTimelock(address(_timelock(address(0), false)), DEPLOYER);
    }

    function test_unlistedAdmin_rejected() public {
        TimelockController tl = _timelock(EXTRA, false);
        vm.expectRevert("timelock: unexpected role holder");
        checker.checkTimelock(address(tl), DEPLOYER);
    }

    function test_unlistedExecutor_rejected() public {
        TimelockController tl = _timelock(address(0), true);
        vm.expectRevert("timelock: unexpected role holder");
        checker.checkTimelock(address(tl), DEPLOYER);
    }

    function test_revokedExtraRoles_passes() public {
        TimelockController tl = _timelock(EXTRA, true);
        vm.startPrank(EXTRA);
        tl.revokeRole(tl.EXECUTOR_ROLE(), EXTRA);
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), EXTRA);
        vm.stopPrank();
        checker.checkTimelock(address(tl), DEPLOYER);
    }

    function test_postDeploymentUnlistedProposer_rejected() public {
        TimelockController tl = _timelock(EXTRA, false);
        vm.startPrank(EXTRA);
        tl.grantRole(tl.PROPOSER_ROLE(), EXTRA);
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), EXTRA);
        vm.stopPrank();
        vm.expectRevert("timelock: unexpected role holder");
        checker.checkTimelock(address(tl), DEPLOYER);
    }

    function test_missingHistory_rejected() public {
        TimelockController tl = _timelock(address(0), false);
        vm.getRecordedLogs();
        vm.recordLogs();
        vm.expectRevert("timelock: history must establish all four exclusive roles");
        checker.checkTimelock(address(tl), DEPLOYER);
    }

    function _scanner(Vm.Log[] memory logs) internal returns (TimelockHistoryScanHarness scanner) {
        scanner = new TimelockHistoryScanHarness();
        scanner.setHistory(logs, block.number);
    }

    function test_historyScanner_chunkedHistory_passes() public {
        TimelockController tl = _timelock(address(0), false);
        TimelockHistoryScanHarness scanner = _scanner(vm.getRecordedLogs());
        vm.roll(block.number + 20_001);
        scanner.checkTimelock(address(tl), DEPLOYER);
        assertEq(scanner.batches(), 3);
    }

    function test_historyScanner_unlistedAdmin_rejected() public {
        TimelockController tl = _timelock(EXTRA, false);
        TimelockHistoryScanHarness scanner = _scanner(vm.getRecordedLogs());
        vm.expectRevert("timelock: unexpected role holder");
        scanner.checkTimelock(address(tl), DEPLOYER);
    }

    function test_historyScanner_missingConstructorGrant_rejected() public {
        TimelockController tl = _timelock(address(0), false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log[] memory truncated = new Vm.Log[](logs.length - 1);
        for (uint256 i = 1; i < logs.length; ++i) {
            truncated[i - 1] = logs[i];
        }
        TimelockHistoryScanHarness scanner = _scanner(truncated);
        vm.expectRevert("timelock: constructor grants missing from history");
        scanner.checkTimelock(address(tl), DEPLOYER);
    }

    function test_historyScanner_lateStart_rejected() public {
        TimelockController tl = _timelock(address(0), false);
        TimelockHistoryScanHarness scanner = _scanner(vm.getRecordedLogs());
        vm.roll(block.number + 1);
        scanner.setScanFrom(vm.getBlockNumber());
        vm.expectRevert("timelock: deployment block depth probe failed");
        scanner.checkTimelock(address(tl), DEPLOYER);
    }

    function test_historyScanner_historyStateMismatch_rejected() public {
        TimelockController tl = _timelock(EXTRA, true);
        Vm.Log[] memory stale = vm.getRecordedLogs();
        vm.startPrank(EXTRA);
        tl.revokeRole(tl.EXECUTOR_ROLE(), EXTRA);
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), EXTRA);
        vm.stopPrank();
        TimelockHistoryScanHarness scanner = _scanner(stale);
        vm.expectRevert("timelock: history != live role state");
        scanner.checkTimelock(address(tl), DEPLOYER);
    }
}
