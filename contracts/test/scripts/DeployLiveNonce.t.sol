// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "forge-std/Test.sol";
import "../../script/v3/DeployLive.s.sol";

contract NonceStub {
    function setTreasury(address) external {}
    function setGuardian(address) external {}
    function setDAOMultisig(address) external {}
    address public delegateSender;
    uint256 public transfers;
    function delegateOnNomination(address sender) external { delegateSender = sender; }
    function transferOwnership(address) external {
        if (++transfers == 2 && delegateSender != address(0)) {
            Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).etch(
                delegateSender, abi.encodePacked(hex"ef0100", address(0x1234)));
        }
    }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
    function getRoleConfig(bytes32) external pure returns (IRegistry.RoleConfig memory cfg) { return cfg; }
    fallback() external {}
}
contract NonceHarness is DeployLive {
    function subjectsForTest() external returns (address[] memory) {
        deployer = address(1); bootstrapAddr = address(2); governorInput = address(3);
        guardianInput = address(4); spGuardianInput = address(5); genesisInput = address(6);
        for (uint256 i; i < 3; ++i) {
            GuardianInput memory g; g.account = address(uint160(i + 7)); guardiansInput.push(g);
        }
        return _handoverSubjects();
    }
    function prepare(address sender, address stub) external {
        deployer = sender; safeInput = address(91); gtokenRecipient = address(92);
        superPaymaster = SuperPaymaster(stub); staking = GTokenStaking(stub);
        mysbt = MySBT(stub); gtoken = GTokenAuthorization(stub); registry = Registry(stub);
        for (uint256 i; i < 5; ++i) ownerChoices[i] = "safe";
    }
    function handover(uint64 expectedNonce, address expectedAddress) external {
        vm.startBroadcast(deployer);
        _handoverProduction(expectedNonce, expectedAddress);
        vm.stopBroadcast();
    }
    function _uintInput(string memory key) internal pure override returns (uint256) { return keccak256(bytes(key)) == keccak256("DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP") ? 0 : 1; }
}
contract DeployLiveNonceTest is Test {
    function test_Round9DelegatedBeforeTL() public {
        vm.chainId(31337);
        address sender = address(0xD00D);
        NonceHarness h = new NonceHarness(); h.prepare(sender, address(new NonceStub()));
        uint64 nonce = vm.getNonce(sender) + 4;
        vm.etch(sender, abi.encodePacked(hex"ef0100", address(0x1234)));
        vm.expectRevert(abi.encodeWithSignature("DeployerHasCode(address)", sender));
        h.handover(nonce, vm.computeCreateAddress(sender, nonce));
    }
    function test_Round9DelegatedBeforeH() public {
        vm.chainId(31337);
        address sender = address(0xD00D);
        NonceStub stub = new NonceStub(); stub.delegateOnNomination(sender);
        NonceHarness h = new NonceHarness(); h.prepare(sender, address(stub));
        uint64 nonce = vm.getNonce(sender) + 4;
        vm.expectRevert(abi.encodeWithSignature("DeployerHasCode(address)", sender));
        h.handover(nonce, vm.computeCreateAddress(sender, nonce));
    }
    function test_SubjectSlotsHaveNoUnassignedEntry() public {
        NonceHarness h = new NonceHarness();
        address[] memory subjects = h.subjectsForTest();
        assertEq(subjects.length, 9, "subjects length");
        for (uint256 i; i < subjects.length; ++i) assertEq(subjects[i], address(uint160(i + 1)), "subject assignment");
    }
    function assertNoTimelockCreate(address sender) internal {
        VmSafe.AccountAccess[] memory records = vm.stopAndReturnStateDiff();
        for (uint256 i; i < records.length; ++i) {
            assertFalse(records[i].accessor == sender && records[i].kind == VmSafe.AccountAccessKind.Create,
                "CREATE attempted before nonce/address validation");
        }
    }
    function test_Round6bWrongPredictionRejectedBeforeTimelockCreate() public {
        vm.chainId(31337);
        address sender = address(0xD00D); address stub = address(new NonceStub());
        NonceHarness h = new NonceHarness(); h.prepare(sender, stub);
        uint64 expectedNonce = vm.getNonce(sender) + 4;
        address actual = vm.computeCreateAddress(sender, expectedNonce);
        vm.startStateDiffRecording();
        vm.expectRevert("handover: predicted timelock before CREATE"); h.handover(expectedNonce, address(999));
        assertNoTimelockCreate(sender);
        assertEq(actual.code.length, 0);
    }
    function test_Round6bExtraTransactionRejectedBeforeTimelockCreate() public {
        vm.chainId(31337);
        address sender = address(0xD00D); address stub = address(new NonceStub());
        NonceHarness h = new NonceHarness(); h.prepare(sender, stub);
        uint64 expectedNonce = vm.getNonce(sender) + 4;
        address expectedAddress = vm.computeCreateAddress(sender, expectedNonce);
        vm.broadcast(sender);
        (bool ok,) = stub.call(""); assertTrue(ok);
        address driftedAddress = vm.computeCreateAddress(sender, expectedNonce + 1);
        vm.startStateDiffRecording();
        vm.expectRevert("handover: timelock nonce"); h.handover(expectedNonce, expectedAddress);
        assertNoTimelockCreate(sender);
        assertEq(expectedAddress.code.length, 0);
        assertEq(driftedAddress.code.length, 0);
    }
}
