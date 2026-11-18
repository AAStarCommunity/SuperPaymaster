// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "./DeployLiveSafeFixture.sol";
import "./DeployLiveProduction.t.sol";

contract DeployLiveRunTest is DeployLiveSafeFixture {
    ProductionHarness h;
    function setUp() public {
        vm.setEnv("SP_COMMIT", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        vm.chainId(31337); vm.warp(10000);
        address sender = tx.origin;
        address safe = address(new Round6Safe());
        _installOfficialSafe(safe);
        vm.setEnv("GOVERNANCE_OWNER", vm.toString(safe));
        vm.setEnv("ENV", "round6-fixture");
        address ep = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        address feed = address(100); address factory = address(101); address impl = address(102);
        vm.etch(address(103), hex"00"); vm.etch(address(104), hex"00");
        vm.etch(ep, hex"00"); vm.etch(feed, hex"00"); vm.etch(factory, hex"00"); vm.etch(impl, hex"00");
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(feed, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), int256(2000e8), block.timestamp, block.timestamp, uint80(1)));
        vm.mockCall(factory, abi.encodeWithSignature("accountImplementation()"), abi.encode(impl));
        vm.mockCall(impl, abi.encodeWithSignature("entryPoint()"), abi.encode(ep));
        // Cryptography boundary only: this tests production orchestration, not PoP validity.
        vm.mockCall(address(0x0b), "", new bytes(128));
        vm.mockCall(address(0x0c), "", new bytes(128));
        vm.mockCall(address(0x0d), "", new bytes(256));
        vm.mockCall(address(0x11), "", new bytes(256));
        vm.mockCall(address(0x0f), "", abi.encode(uint256(1)));
        h = new ProductionHarness();
        h.configure(sender, safe, ep, feed, factory);
        string memory pins = "deployments/creation-pins.31337.json";
        vm.createDir("cache/deploylive-tests", true); vm.setEnv("CREATION_PINS", pins); vm.setEnv("DEPLOYLIVE_EVM_VERSION", "cancun");
    }
    function assertNoBroadcast(bytes memory expected) internal {
        vm.startStateDiffRecording();
        (bool ok, bytes memory reason) = address(h).call(abi.encodeCall(h.run, ()));
        VmSafe.AccountAccess[] memory records = vm.stopAndReturnStateDiff();
        uint256 broadcasts;
        for (uint256 i; i < records.length; ++i) {
            if (records[i].accessor == tx.origin && (records[i].kind == VmSafe.AccountAccessKind.Call || records[i].kind == VmSafe.AccountAccessKind.Create)) ++broadcasts;
        }
        emit log_named_uint("broadcast count", broadcasts);
        assertEq(broadcasts, 0, "preflight must precede every broadcast");
        assertFalse(ok);
        assertEq(reason, expected);
    }
    function test_ProductionCommitMissing() public {
        h.overrideCommit("");
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "STOP pop_request_commit"));
    }
    function test_ProductionCommitUppercase() public {
        h.overrideCommit("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "STOP pop_request_commit"));
    }
    function test_ProductionCommitShort() public {
        h.overrideCommit("abc");
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "STOP pop_request_commit"));
    }
    function test_Round9DelegatedPreflightBroadcastCountZero() public {
        vm.etch(tx.origin, abi.encodePacked(hex"ef0100", address(0x1234)));
        assertNoBroadcast(abi.encodeWithSignature("DeployerHasCode(address)", tx.origin));
    }
    function test_RunWrongInfrastructureBroadcastCountZero() public {
        vm.mockCall(address(100), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "DeployLive: feed decimals"));
    }
    function test_RunWrongPinsBroadcastCountZero() public {
        h.useBadCreationPin();
        assertNoBroadcast(abi.encodeWithSignature("Error(string)", "creation pin mismatch: Registry"));
    }
    function test_RunPriceInitializationMustPropagate() public {
        vm.mockCall(address(100), abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(1), int256(50e8), block.timestamp, block.timestamp, uint80(1)));
        vm.expectRevert(abi.encodeWithSignature("OracleError()"));
        h.run();
    }
}
