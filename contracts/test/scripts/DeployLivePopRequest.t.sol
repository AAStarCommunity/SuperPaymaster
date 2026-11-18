// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "./DeployLiveRun.t.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";

contract PopRequestHarness is ProductionHarness {
    string requestPath;
    string requestCommit;
    function request(string memory path, string memory commit) external { requestPath = path; requestCommit = commit; }
    function _popRequestPath() internal view override returns (string memory) { return requestPath; }
    function _popRequestCommit() internal view override returns (string memory) { return requestCommit; }
}
contract PopBroadcastHarness is PopRequestHarness {
    function _popBroadcastContext() internal pure override returns (bool) { return true; }
}
contract PopWithoutGuardiansHarness is PopRequestHarness {
    function _guardiansInput() internal pure override returns (bytes memory) { revert("GUARDIANS must not be read"); }
}

contract DeployLivePopRequestTest is DeployLiveRunTest {
    string constant REQUEST = "cache/dlpop/request.json";
    function prepareRequest() internal {
        vm.createDir("cache/dlpop", true);
        h = new PopRequestHarness();
        h.configure(tx.origin, vm.envAddress("GOVERNANCE_OWNER"), 0x0000000071727De22E5E9d8BAf0edAc6f37da032, address(100), address(101));
        PopRequestHarness(address(h)).request(REQUEST, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        vm.roll(123);
        vm.setBlockhash(122, bytes32(uint256(456)));
    }
    function test_PopRequestRoundTrip() public {
        prepareRequest();
        uint64 nonce = vm.getNonce(tx.origin);
        uint256 snapshot = vm.snapshot();
        h.run();
        string memory request = vm.readFile(REQUEST);
        assertEq(vm.parseJsonKeys(request, ".").length, 6);
        assertEq(vm.parseJsonKeys(request, ".addresses").length, 3);
        assertEq(vm.parseJsonKeys(request, ".pin").length, 3);
        assertEq(vm.parseJsonKeys(request, ".pin.senders").length, 1);
        assertEq(vm.parseJsonKeys(request, ".pin.senders.deployer").length, 2);
        assertEq(vm.parseJsonString(request, ".schema"), "deploylive-pop-request/1");
        assertEq(vm.parseJsonString(request, ".spCommit"), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assertEq(vm.parseJsonUint(request, ".chainId"), 31337);
        assertEq(vm.parseJsonUint(request, ".guardianCount"), 3);
        // pin.block and pin.blockHash name the same (parent) block.
        assertEq(vm.parseJsonUint(request, ".pin.block"), 122);
        assertEq(vm.parseJsonBytes32(request, ".pin.blockHash"), bytes32(uint256(456)));
        assertEq(vm.parseJsonUint(request, ".pin.senders.deployer.nonce"), nonce);
        assertEq(vm.parseJsonAddress(request, ".pin.senders.deployer.address"), tx.origin);
        address agg = vm.parseJsonAddress(request, ".addresses.BLSAggregator");
        address dvtAddr = vm.parseJsonAddress(request, ".addresses.DVTValidator");
        address regAddr = vm.parseJsonAddress(request, ".addresses.Registry");
        assertTrue(agg != dvtAddr && agg != regAddr && dvtAddr != regAddr, "three distinct addresses");
        assertEq(BLSAggregator(agg).validatorAtSlot(1), address(0));
        vm.revertTo(snapshot);
        PopRequestHarness(address(h)).request("", vm.envString("SP_COMMIT"));
        h.run();
        string memory config = vm.readFile("cache/deploylive-tests/config.round6-fixture.json");
        assertEq(agg, vm.parseJsonAddress(config, ".blsAggregator"));
        assertEq(vm.parseJsonAddress(request, ".addresses.DVTValidator"), vm.parseJsonAddress(config, ".dvtValidator"));
        assertEq(vm.parseJsonAddress(request, ".addresses.Registry"), vm.parseJsonAddress(config, ".registry"));
    }
    function test_PopRequestWithoutGuardians() public {
        prepareRequest();
        h = new PopWithoutGuardiansHarness();
        PopRequestHarness(address(h)).request(REQUEST, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        h.configure(tx.origin, vm.envAddress("GOVERNANCE_OWNER"), 0x0000000071727De22E5E9d8BAf0edAc6f37da032, address(100), address(101));
        h.run();
        assertEq(vm.parseJsonUint(vm.readFile(REQUEST), ".guardianCount"), 3);
    }
    function test_PopRequestBroadcastRefused() public {
        prepareRequest();
        h = new PopBroadcastHarness();
        PopRequestHarness(address(h)).request(REQUEST, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "STOP pop_request_broadcast"));
    }
    function test_PopCommitMissing() public {
        prepareRequest(); PopRequestHarness(address(h)).request(REQUEST, "");
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "STOP pop_request_commit"));
    }
    function test_PopCommitUppercase() public {
        prepareRequest(); PopRequestHarness(address(h)).request(REQUEST, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "STOP pop_request_commit"));
    }
    function test_PopCommitNonHex() public {
        prepareRequest(); PopRequestHarness(address(h)).request(REQUEST, "gggggggggggggggggggggggggggggggggggggggg");
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "STOP pop_request_commit"));
    }
}
