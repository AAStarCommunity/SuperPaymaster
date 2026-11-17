// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IBLSAggregator.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/mocks/MockEvidenceCategory.sol";
import "src/utils/BLS.sol";

contract EvidenceStakingStub {
    function roleLocks(address, bytes32 roleId)
        external
        pure
        returns (uint128, uint128, uint48, bytes32, bytes memory)
    {
        return (1, 0, 0, roleId, "");
    }
}

contract EvidenceRegistryStub {
    IGTokenStaking private immutable _staking = IGTokenStaking(address(new EvidenceStakingStub()));

    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return _staking;
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return true;
    }

    function getRoleConfig(bytes32) external pure returns (IRegistry.RoleConfig memory) {
        return IRegistry.RoleConfig(0, 0, 0, 0, 0, 0, 0, false, 0, "", address(0), 0);
    }

    function markProposalExecuted(uint256) external {}
}

contract CapturingEvidenceAggregator {
    function suspended(address) external pure returns (bool) { return false; }
    function proposalFloor() external pure returns (uint256) { return 0; }
    function DVT_VALIDATOR() external view returns (address) { return msg.sender; }
    bool public executeCalled;
    bool public queueCalled;
    bytes32 public capturedEvidenceHash;

    function queueSlashWithConsensus(address, uint8, uint256, bytes calldata) external {
        queueCalled = true;
    }

    function verifyAndExecute(
        uint256,
        address,
        uint8,
        address[] calldata,
        uint256[] calldata,
        uint256,
        bytes32 evidenceHash,
        bytes calldata
    ) external {
        executeCalled = true;
        capturedEvidenceHash = evidenceHash;
    }
}

contract RevertingEvidenceChecker is IEvidenceCategory {
    function check(address, uint8, uint256, bytes calldata) external pure override returns (bool) {
        revert("checker reverted");
    }
}

contract MalformedEvidenceChecker is IEvidenceCategory {
    function check(address, uint8, uint256, bytes calldata) external pure override returns (bool) {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(31, 1)
        }
    }
}

contract DVTValidatorEvidenceTest is Test {
    bytes32 private constant CATEGORY = keccak256("DVT.Evidence.Test.v1");
    bytes32 private constant OTHER_CATEGORY = keccak256("DVT.Evidence.Other.v1");
    bytes private constant BODY = "raw evidence body";

    EvidenceRegistryStub private registry;
    MockEvidenceCategory private checker;
    CapturingEvidenceAggregator private aggregator;
    DVTValidator private dvt;

    function setUp() public {
        registry = new EvidenceRegistryStub();
        checker = new MockEvidenceCategory();
        aggregator = new CapturingEvidenceAggregator();
        dvt = _deployOne(CATEGORY, address(checker));
        dvt.setBLSAggregator(address(aggregator));
        dvt.addValidator(address(this));
    }

    function test_ConstructorRevertsOnLengthMismatch() public {
        bytes32[] memory categories = new bytes32[](1);
        vm.expectRevert(DVTValidator.EvidenceConfigLengthMismatch.selector);
        new DVTValidator(address(registry), 1, categories, new address[](0));
    }

    function test_ConstructorRevertsOnZeroCategory() public {
        vm.expectRevert(DVTValidator.ZeroEvidenceCategory.selector);
        _deployOne(bytes32(0), address(checker));
    }

    function test_ConstructorRevertsOnZeroChecker() public {
        vm.expectRevert(DVTValidator.ZeroEvidenceChecker.selector);
        _deployOne(CATEGORY, address(0));
    }

    function test_ConstructorRevertsOnDuplicateCategory() public {
        bytes32[] memory categories = new bytes32[](2);
        categories[0] = CATEGORY;
        categories[1] = CATEGORY;
        address[] memory checkers = new address[](2);
        checkers[0] = address(checker);
        checkers[1] = address(checker);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.DuplicateEvidenceCategory.selector, CATEGORY));
        new DVTValidator(address(registry), 1, categories, checkers);
    }

    function test_UnknownCategoryRevertsOnQueue() public {
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, OTHER_CATEGORY));
        dvt.queueSlashWithProof(address(0xBEEF), 1, 9, _evidence(OTHER_CATEGORY), "");
    }

    function test_ExecuteOrder_UnknownCategoryBeforeHashAndBLS() public {
        uint256 id = dvt.createProposal(address(0xBEEF), 1, "unknown", bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, OTHER_CATEGORY));
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 9, _evidence(OTHER_CATEGORY), hex"badbad");
        assertFalse(aggregator.executeCalled());
    }

    function test_ExecuteOrder_CheckerBeforeHashAndBLS() public {
        checker.setAccepted(false);
        uint256 id = dvt.createProposal(address(0xBEEF), 1, "rejected", bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.EvidenceRejected.selector, CATEGORY));
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 9, _evidence(CATEGORY), hex"badbad");
        assertFalse(aggregator.executeCalled());
    }

    function test_CheckerFalseRevertsEvidenceRejected() public {
        checker.setAccepted(false);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.EvidenceRejected.selector, CATEGORY));
        dvt.queueSlashWithProof(address(0xBEEF), 1, 9, _evidence(CATEGORY), "");
    }

    function test_RevertingCheckerBecomesEvidenceRejected() public {
        DVTValidator revertingDvt = _deployOne(CATEGORY, address(new RevertingEvidenceChecker()));
        revertingDvt.setBLSAggregator(address(aggregator));
        revertingDvt.addValidator(address(this));
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.EvidenceRejected.selector, CATEGORY));
        revertingDvt.queueSlashWithProof(address(0xBEEF), 1, 9, _evidence(CATEGORY), "");
    }

    function test_MalformedCheckerReturnBecomesEvidenceRejected() public {
        DVTValidator malformedDvt = _deployOne(CATEGORY, address(new MalformedEvidenceChecker()));
        malformedDvt.setBLSAggregator(address(aggregator));
        malformedDvt.addValidator(address(this));
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.EvidenceRejected.selector, CATEGORY));
        malformedDvt.queueSlashWithProof(address(0xBEEF), 1, 9, _evidence(CATEGORY), "");
    }

    function test_ExecuteOrder_HashBeforeBLS() public {
        uint256 id = dvt.createProposal(address(0xBEEF), 1, "mismatch", bytes32(uint256(1)));
        vm.expectRevert(DVTValidator.EvidenceHashMismatch.selector);
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 9, _evidence(CATEGORY), hex"badbad");
        assertFalse(aggregator.executeCalled());
    }

    function test_QueueOrder_UnknownCategoryBeforeAggregator() public {
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, OTHER_CATEGORY));
        dvt.queueSlashWithProof(address(0xBEEF), 1, 9, _evidence(OTHER_CATEGORY), hex"badbad");
        assertFalse(aggregator.queueCalled());
    }

    function test_QueueOrder_CheckerBeforeAggregator() public {
        checker.setAccepted(false);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.EvidenceRejected.selector, CATEGORY));
        dvt.queueSlashWithProof(address(0xBEEF), 1, 9, _evidence(CATEGORY), hex"badbad");
        assertFalse(aggregator.queueCalled());
    }

    function test_PassingCheckerReachesAggregatorWithComputedHash() public {
        bytes32 expectedHash = _evidenceHash(CATEGORY);
        uint256 id = dvt.createProposal(address(0xBEEF), 1, "accepted", expectedHash);
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 9, _evidence(CATEGORY), hex"1234");
        assertTrue(aggregator.executeCalled());
        assertEq(aggregator.capturedEvidenceHash(), expectedHash);

        dvt.queueSlashWithProof(address(0xBEEF), 1, 10, _evidence(CATEGORY), hex"5678");
        assertTrue(aggregator.queueCalled());
    }

    function test_EmptyAllowlistRejectsBothPathsAndReportsZeroCategories() public {
        DVTValidator empty = new DVTValidator(address(registry), 1, new bytes32[](0), new address[](0));
        empty.setBLSAggregator(address(aggregator));
        empty.addValidator(address(this));
        assertEq(empty.categoryCount(), 0);

        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, CATEGORY));
        empty.queueSlashWithProof(address(0xBEEF), 1, 9, _evidence(CATEGORY), "");

        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, bytes32(0)));
        empty.createProposal(address(0xBEEF), 1, "empty", _evidenceHash(CATEGORY));
    }

    function test_CategoryViewsAndAdmission() public {
        assertEq(dvt.version(), "DVTValidator-0.9.0");
        assertEq(dvt.categoryCount(), 1);
        assertEq(dvt.categoryAt(0), CATEGORY);
        assertEq(dvt.checkerOf(CATEGORY), address(checker));
        assertTrue(dvt.isValidator(address(this)));
    }

    function _deployOne(bytes32 category, address checkerAddress) internal returns (DVTValidator deployed) {
        bytes32[] memory categories = new bytes32[](1);
        categories[0] = category;
        address[] memory checkers = new address[](1);
        checkers[0] = checkerAddress;
        deployed = new DVTValidator(address(registry), 1, categories, checkers);
    }

    function _evidence(bytes32 category) internal pure returns (bytes memory) {
        return abi.encode(category, BODY);
    }

    function _evidenceHash(bytes32 category) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("SuperPaymaster.DVT.Evidence.v2"), category, keccak256(BODY)));
    }
}

// The BLS-order case (evidence valid, signature invalid -> aggregator reverts) runs with real
// keys under Prague in DVTValidatorEvidencePrague.t.sol; the mocked-precompile copy was removed.
