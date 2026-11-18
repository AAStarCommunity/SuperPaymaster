// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import {TimelockController} from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import {TimelockHandoverBootstrap} from "../../script/v3/TimelockHandoverBootstrap.sol";
import {DeployLive} from "../../script/v3/DeployLive.s.sol";
contract Round6Safe {
    function getThreshold() external pure returns (uint256) { return 2; }
    function getOwners() external pure returns (address[] memory a) {
        a = new address[](2); a[0] = address(91); a[1] = address(92);
    }
}

interface IMintProbe { function mint(address to, uint256 amount) external; function balanceOf(address account) external view returns (uint256); }

contract ProductionHarness is DeployLive {
    bool stopForTest;
    function stopBeforeH() external { stopForTest = true; }
    function configure(address sender, address safe, address ep, address feed, address factory) external {
        deployer = sender; safeInput = safe; entryPointAddr = ep; priceFeedAddr = feed; simpleAccountFactory = factory;
    }
    function _addressInput(string memory k) internal view override returns (address) {
        bytes32 h = keccak256(bytes(k));
        if (h == keccak256("GOVERNANCE_OWNER")) return safeInput;
        if (h == keccak256("GUARDIAN_ADDRESS")) return address(202);
        if (h == keccak256("SP_GUARDIAN")) return address(203);
        if (h == keccak256("GENESIS_AASTAR_OPERATOR")) return address(204);
        return address(0);
    }
    function _inputSet(string memory) internal pure override returns (bool) { return false; }
    function _stringInput(string memory k) internal pure override returns (string memory) {
        bytes32 h = keccak256(bytes(k));
        if (h == keccak256("GOVERNOR_ADDRESS")) return "";
        if (h == keccak256("X402_OWNER") || h == keccak256("DEPLOYER_GTOKEN_RECIPIENT")) return "safe";
        return "timelock";
    }
    function _uintInput(string memory k) internal view override returns (uint256) {
        bytes32 h = keccak256(bytes(k));
        if (h == keccak256("DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP")) return stopForTest ? 1 : 0;
        if (h == keccak256("DEPLOYLIVE_REHEARSAL")) return 1;
        if (h == keccak256("APNTS_CAP")) return 1_000_000 ether;
        if (h == keccak256("GUARDIAN_N")) return 3;
        return 2;
    }
    function _guardiansInput() internal pure override returns (bytes memory) {
        GuardianInput[] memory gs = new GuardianInput[](3);
        for (uint256 i; i < 3; ++i) { gs[i].account = address(uint160(300 + i)); gs[i].key.x_b = bytes32(i + 1); }
        return abi.encode(gs);
    }
    function makePins(string memory path) external {
        string[24] memory names = _pinnedNames();
        for (uint256 i; i < names.length; ++i) vm.serializeBytes32("production-pins", names[i], keccak256(vm.getCode(_defaultArtifact(names[i]))));
        vm.writeFile(path, vm.serializeBytes32("production-pins", "TimelockHandoverBootstrap", keccak256(type(TimelockHandoverBootstrap).creationCode)));
    }
    function failedCreate(address externalGToken, address externalAPNTs) external {
        vm.store(address(registry), 0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00, bytes32(0));
        require(vm.getNonce(deployer) == bootstrapNonce, "failure: storage write nonce");
        vm.startBroadcast(deployer);
        vm.expectRevert();
        new TimelockHandoverBootstrap(TimelockController(payable(timelockControllerAddr)), _twoStepTargets(), safeInput);
        vm.stopBroadcast();
        require(bootstrapAddr.code.length == 0, "failure: H has code");
        address[27] memory all = [address(registry), registryImplAddr, address(superPaymaster), spImplAddr,
            superPaymaster.EXTENSION(), address(gtoken), address(staking), address(mysbt), address(apnts),
            address(xpntsFactory), xpntsFactory.implementation(), v55.factory, v55.impl, v55.ext, v55.tierSource,
            v55.lens, v55.aoaRegistry, address(repSystem), address(aggregator), address(dvt), address(microPaymentCh),
            address(pmFactory), address(pmV4Impl), x402FacilitatorAddr, policyRegistryAddr, timelockControllerAddr, bootstrapAddr];
        for (uint256 i; i < all.length; ++i) {
            require(all[i].balance == 0, "failure: ETH residue");
            require(IMintProbe(externalGToken).balanceOf(all[i]) == 0 && IMintProbe(externalAPNTs).balanceOf(all[i]) == 0,
                "failure: pre-existing token residue");
            console2.log("ABANDONED contract", all[i]);
            console2.log("ETH / prior GToken / prior APNTs", uint256(0), uint256(0), uint256(0));
            console2.log("own GToken / own APNTs", gtoken.balanceOf(all[i]), apnts.balanceOf(all[i]));
        }

        TimelockController t = TimelockController(payable(timelockControllerAddr));
        bytes32[3] memory roles = [t.PROPOSER_ROLE(), t.EXECUTOR_ROLE(), t.CANCELLER_ROLE()];
        for (uint256 i; i < roles.length; ++i) {
            require(t.hasRole(roles[i], bootstrapAddr) && !t.hasRole(roles[i], safeInput) && !t.hasRole(roles[i], deployer), "failure: authority");
        }
        require(registry.hasRole(keccak256("COMMUNITY"), genesisInput) && registry.hasRole(keccak256("PAYMASTER_SUPER"), genesisInput), "failure: genesis registrations");
        for (uint256 i; i < guardiansInput.length; ++i) require(registry.hasRole(keccak256("DVT"), guardiansInput[i].account), "failure: guardian registration");
    }
    function verifyRound6() external view {
        require(aggregator.owner() == safeInput && dvt.owner() == safeInput, "round6: Safe owners");
        require(Ownable(x402FacilitatorAddr).owner() == safeInput, "round6: X402 owner");
        require(gtoken.balanceOf(deployer) == 0, "round6: residue");
        require(gtoken.balanceOf(safeInput) == 2059 ether, "round6: recipient");
        require(gtoken.totalSupply() == 2199 ether, "round6: minted supply");
        require(staking.getLockedStake(address(204), keccak256("PAYMASTER_SUPER")) == 50 ether, "round6: genesis stake");
        for (uint256 i; i < 3; ++i) require(staking.getLockedStake(address(uint160(300 + i)), keccak256("DVT")) == 30 ether, "round6: DVT stake");
        _assertHandover();
    }
}

contract DeployLiveProductionTest is Test {
    function test_ProductionPathN3() public {
        vm.chainId(987654); vm.warp(10000);
        address sender = tx.origin;
        address safe = address(new Round6Safe());
        vm.setEnv("GOVERNANCE_OWNER", vm.toString(safe));
        vm.setEnv("ENV", "round6-fixture");
        address ep = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
        address feed = address(100); address factory = address(101); address impl = address(102);
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
        ProductionHarness h = new ProductionHarness();
        h.configure(sender, safe, ep, feed, factory);
        string memory pins = "script/rehearsal/evidence/round6/production-pins.json";
        h.makePins(pins); vm.setEnv("CREATION_PINS", pins); vm.setEnv("DEPLOYLIVE_EVM_VERSION", "cancun");
        vm.startStateDiffRecording();
        h.run();
        VmSafe.AccountAccess[] memory records = vm.stopAndReturnStateDiff();
        string memory config = vm.readFile("deployments/config.round6-fixture.json");
        address bootstrap = vm.parseJsonAddress(config, ".handoverBootstrap");
        address tl = vm.parseJsonAddress(config, ".timelockController");
        uint256 distance; bool sawTL; bool sawH; uint256 transactions;
        string memory journal = "[";
        for (uint256 i; i < records.length; ++i) {
            VmSafe.AccountAccess memory record = records[i];
            if (record.accessor != sender || (record.kind != VmSafe.AccountAccessKind.Call && record.kind != VmSafe.AccountAccessKind.Create)) continue;
            if (record.account == bootstrap && record.kind == VmSafe.AccountAccessKind.Create) { sawH = true; break; }
            assertEq(record.value, 0, "pre-H broadcast value");
            if (transactions++ > 0) journal = string.concat(journal, ",");
            journal = string.concat(journal, '{"to":"', vm.toString(record.account), '","value":', vm.toString(record.value), '}');
            if (record.account == tl && record.kind == VmSafe.AccountAccessKind.Create) sawTL = true;
            if (sawTL) ++distance;
        }
        assertTrue(sawTL && sawH, "complete TL-to-H record required");
        assertEq(distance, 22, "derived call-list distance");
        assertEq(vm.parseJsonUint(config, ".observedBootstrapNonce"), vm.parseJsonUint(config, ".handoverBootstrapNonce"));
        vm.writeFile("script/rehearsal/evidence/round6/production-transactions.json", string.concat(journal, "]"));
        emit log_named_uint("pre-H zero-value transactions", transactions);
        emit log_named_uint("TL-to-H observed distance", distance);
        h.verifyRound6();
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", sender));
        IMintProbe(vm.parseJsonAddress(config, ".gToken")).mint(sender, 1);
        vm.writeFile("script/rehearsal/evidence/round6/config.success.json", config);
        vm.chainId(31337);
        ProductionHarness failed = new ProductionHarness();
        failed.configure(sender, safe, ep, feed, factory); failed.stopBeforeH();
        failed.run(); failed.failedCreate(vm.parseJsonAddress(config, ".gToken"), vm.parseJsonAddress(config, ".aPNTs"));
        vm.writeFile("script/rehearsal/evidence/round6/config.abandoned.json", vm.readFile("deployments/config.round6-fixture.json"));
        vm.removeFile("deployments/config.round6-fixture.json");
    }
}
