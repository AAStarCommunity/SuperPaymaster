// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GToken} from "src/tokens/GToken.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {Registry} from "src/core/Registry.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract PragueSwitchableEvidenceChecker {
    uint256 public mode;
    function setMode(uint256 value) external { mode = value; }
    function check(address, uint8, uint256, bytes calldata) external view returns (bool) {
        if (mode == 1) return false;
        if (mode == 2) revert("checker");
        if (mode == 3) {
            assembly ("memory-safe") { mstore(0, 1) return(31, 1) }
        }
        return true;
    }
}

import {DVTValidator} from "src/modules/monitoring/DVTValidator.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";
import {IRegistry} from "src/interfaces/v3/IRegistry.sol";
import {IGTokenStaking} from "src/interfaces/v3/IGTokenStaking.sol";
import {MockEvidenceCategory} from "src/mocks/MockEvidenceCategory.sol";

contract PragueEvidenceStakingStub {
    function roleLocks(address, bytes32 roleId)
        external
        pure
        returns (uint128, uint128, uint48, bytes32, bytes memory)
    {
        return (1, 0, 0, roleId, "");
    }
}

contract PragueEvidenceRegistryStub {
    IGTokenStaking private immutable _staking = IGTokenStaking(address(new PragueEvidenceStakingStub()));

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

contract PragueEvidenceSuperPaymasterStub {
    bool public queued;
    bool public executed;

    function queueSlash(address) external {
        queued = true;
    }

    function executeSlashWithBLS(address, uint8, bytes calldata) external {
        executed = true;
    }
}

/// @notice Prague-only counterpart to DVTValidatorEvidenceBLSOrderTest. Unlike
///         that Cancun fixture, every key, PoP, signature and pairing is real.
contract DVTValidatorEvidencePragueTest is Test {
    bytes32 private constant CATEGORY = keccak256("DVT.Evidence.Test.v1");
    bytes private constant BODY = "raw evidence body";
    address private constant OPERATOR = address(0xBEEF);
    uint8 private constant SLASH_LEVEL = 1;
    uint256 private constant MASK = 0x7;

    address[3] private validators = [address(0x101), address(0x102), address(0x103)];
    uint256[3] private secretScalars = [uint256(1), 2, 3];

    bool private pragueAvailable;
    Registry private registry;
    PragueSwitchableEvidenceChecker private checker;
    PragueEvidenceSuperPaymasterStub private superPaymaster;
    DVTValidator private dvt;
    BLSAggregator private bls;

    function setUp() public {
        pragueAvailable = _hasPraguePrecompiles();
        if (!pragueAvailable) return;

        GToken token = new GToken(21_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(0));
        GTokenStaking staking = new GTokenStaking(address(token), address(this), address(registry));
        MySBT sbt = new MySBT(address(token), address(staking), address(registry), address(this));
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));
        bytes32 role = keccak256("DVT");
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(role);
        for (uint256 i; i < validators.length; ++i) {
            uint256 amount = cfg.minStake + cfg.ticketPrice;
            token.mint(validators[i], amount);
            vm.startPrank(validators[i]);
            token.approve(address(staking), amount);
            registry.registerRole(role, validators[i], abi.encode(cfg.minStake));
            vm.stopPrank();
        }
        superPaymaster = new PragueEvidenceSuperPaymasterStub();

        bytes32[] memory categories = new bytes32[](1);
        categories[0] = CATEGORY;
        address[] memory checkers = new address[](1);
        checker = new PragueSwitchableEvidenceChecker();
        checkers[0] = address(checker);
        dvt = new DVTValidator(address(registry), 1, categories, checkers);
        bls = new BLSAggregator(address(registry), address(superPaymaster), address(dvt));
        dvt.setBLSAggregator(address(bls));
        bls.setMinThreshold(2);
        bls.setDefaultThreshold(3);
        registry.setBLSAggregator(address(bls));
        registry.setReputationSource(address(bls), true);
        registry.setCreditTier(1, 0);
        registry.setCreditPolicy(type(uint256).max, type(uint256).max);

        for (uint8 i = 0; i < validators.length; ++i) {
            address validator = validators[i];
            uint256 scalar = secretScalars[i];
            dvt.addValidator(validator);
            BLS.G1Point memory publicKey = _publicKey(scalar);
            dvt.registerBLSPublicKey(
                validator, publicKey, i + 1, _pop(bls, validator, publicKey, scalar)
            );
        }
    }

    function test_Prague_ExecuteValidEvidenceRejectsInvalidRealSignatureThenAcceptsValidSignature() public {
        _skipWithoutPrague();
        uint256 epoch = 9;
        bytes memory evidence = _evidence();
        bytes32 evidenceHash = _evidenceHash();

        vm.prank(validators[0]);
        uint256 proposalId = dvt.createProposal(OPERATOR, SLASH_LEVEL, "proof ordering", evidenceHash);
        bytes32 messageHash = _executeMessageHash(proposalId, epoch, evidenceHash);
        bytes memory invalidProof = _proof(keccak256(abi.encode(messageHash, "wrong message")));
        bytes memory validProof = _proof(messageHash);

        vm.prank(validators[0]);
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        dvt.executeWithProof(
            proposalId,
            new address[](0),
            new uint256[](0),
            epoch,
            evidence,
            invalidProof
        );

        vm.prank(validators[0]);
        dvt.executeWithProof(
            proposalId, new address[](0), new uint256[](0), epoch, evidence, validProof
        );

        (,,, bool executed,,) = dvt.proposals(proposalId);
        assertTrue(executed);
        assertTrue(bls.executedProposals(proposalId));
        assertTrue(superPaymaster.executed());
    }

    function test_Prague_QueueValidEvidenceRejectsInvalidRealSignatureThenAcceptsValidSignature() public {
        _skipWithoutPrague();
        uint256 epoch = 10;
        bytes memory evidence = _evidence();
        bytes32 messageHash = _queueMessageHash(epoch);
        bytes memory invalidProof = _proof(keccak256(abi.encode(messageHash, "wrong message")));
        bytes memory validProof = _proof(messageHash);

        vm.prank(validators[0]);
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        dvt.queueSlashWithProof(
            OPERATOR,
            SLASH_LEVEL,
            epoch,
            evidence,
            invalidProof
        );
        assertFalse(superPaymaster.queued());

        vm.prank(validators[0]);
        dvt.queueSlashWithProof(OPERATOR, SLASH_LEVEL, epoch, evidence, validProof);
        assertTrue(superPaymaster.queued());
        assertTrue(bls.usedSlashQueueHashes(messageHash));
    }

    function _emptyAllowlistDvt() internal {
        dvt = new DVTValidator(address(registry), dvt.nextProposalId(), new bytes32[](0), new address[](0));
        dvt.setBLSAggregator(address(bls));
        dvt.addValidator(validators[0]);
        bls.setDVTValidator(address(dvt));
    }

    function _reputationBatch() internal pure returns (address[] memory users, uint256[] memory scores) {
        users = new address[](1);
        scores = new uint256[](1);
        users[0] = address(0xCAFE);
        scores[0] = 25;
    }

    function test_Prague_R1_ReputationWithoutCategoriesUpdatesRegistry() public {
        _skipWithoutPrague();
        _emptyAllowlistDvt();
        assertEq(dvt.categoryCount(), 0);
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(address(0), 0, "reputation", bytes32(0));
        (address[] memory users, uint256[] memory scores) = _reputationBatch();
        bytes memory proof = _proof(keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_REPUTATION(), id, users, scores, uint256(9)
        )));
        vm.prank(validators[0]);
        dvt.executeWithProof(id, users, scores, 9, "", proof);
        assertEq(registry.globalReputation(users[0]), scores[0]);
        assertFalse(superPaymaster.executed());
        (,,, bool executed,,) = dvt.proposals(id);
        assertTrue(executed);
    }

    function test_Prague_S3_EmptyAllowlistRejectsQueueSlash() public {
        _skipWithoutPrague();
        _emptyAllowlistDvt();
        bytes memory validProof = _proof(_queueMessageHash(11));
        vm.prank(validators[0]);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, CATEGORY));
        dvt.queueSlashWithProof(OPERATOR, SLASH_LEVEL, 11, _evidence(), validProof);
        assertFalse(superPaymaster.queued());
    }

    function test_Prague_R2_ReputationRejectsEvidenceHash() public {
        _skipWithoutPrague();
        vm.prank(validators[0]);
        vm.expectRevert(DVTValidator.ReputationEvidenceHashNotZero.selector);
        dvt.createProposal(address(0), 0, "reputation", _evidenceHash());
    }

    function test_Prague_R3_ReputationRejectsRawEvidence() public {
        _skipWithoutPrague();
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(address(0), 0, "reputation", bytes32(0));
        (address[] memory users, uint256[] memory scores) = _reputationBatch();
        vm.prank(validators[0]);
        vm.expectRevert(DVTValidator.ReputationEvidenceNotEmpty.selector);
        dvt.executeWithProof(id, users, scores, 9, _evidence(), hex"badbad");
    }

    function test_Prague_S1_EmptyAllowlistRejectsSlashCreation() public {
        _skipWithoutPrague();
        _emptyAllowlistDvt();
        vm.prank(validators[0]);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, bytes32(0)));
        dvt.createProposal(OPERATOR, SLASH_LEVEL, "slash", _evidenceHash());
    }

    /// @dev S1 plus immutable categories make execution with zero categories
    /// unreachable through the public API. Test the reachable unknown-category
    /// execution on a deployment with a category instead, without forging storage.
    function test_Prague_S2_B_UnknownCategoryBeforeCheckerHashAndAggregator() public {
        _skipWithoutPrague();
        checker.setMode(2);
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(OPERATOR, SLASH_LEVEL, "slash", bytes32(uint256(1)));
        bytes32 unknown = keccak256("unknown");
        _expectExecutionError(id, abi.encode(unknown, BODY),
            abi.encodeWithSelector(DVTValidator.UnknownEvidenceCategory.selector, unknown));
    }

    function test_Prague_M1_ReputationRejectsEmptyBatch() public {
        _skipWithoutPrague();
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(address(0), 0, "reputation", bytes32(0));
        _expectExecutionError(id, "", abi.encodeWithSelector(DVTValidator.ProposalShapeMismatch.selector));
    }

    function test_Prague_M1_SlashRejectsUsersOrScores() public {
        _skipWithoutPrague();
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(OPERATOR, SLASH_LEVEL, "slash", _evidenceHash());
        (address[] memory users, uint256[] memory scores) = _reputationBatch();
        vm.prank(validators[0]);
        vm.expectRevert(DVTValidator.ProposalShapeMismatch.selector);
        dvt.executeWithProof(id, users, scores, 9, _evidence(), hex"badbad");
        vm.prank(validators[0]);
        vm.expectRevert(DVTValidator.ProposalShapeMismatch.selector);
        dvt.executeWithProof(id, new address[](0), scores, 9, _evidence(), hex"badbad");
    }

    function test_Prague_B_CheckerFalseBeforeHashAndAggregator() public {
        _checkerRejected(1);
    }

    function test_Prague_B_CheckerRevertBeforeHashAndAggregator() public {
        _checkerRejected(2);
    }

    function test_Prague_B_CheckerMalformedBeforeHashAndAggregator() public {
        _checkerRejected(3);
    }

    function _checkerRejected(uint256 mode) internal {
        _skipWithoutPrague();
        checker.setMode(mode);
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(OPERATOR, SLASH_LEVEL, "slash", bytes32(uint256(1)));
        _expectExecutionError(id, _evidence(), abi.encodeWithSelector(DVTValidator.EvidenceRejected.selector, CATEGORY));
    }

    function test_Prague_B_HashMismatchBeforeAggregator() public {
        _skipWithoutPrague();
        vm.prank(validators[0]);
        uint256 id = dvt.createProposal(OPERATOR, SLASH_LEVEL, "slash", bytes32(uint256(1)));
        _expectExecutionError(id, _evidence(), abi.encodeWithSelector(DVTValidator.EvidenceHashMismatch.selector));
    }

    function test_Prague_SlashRequiresNonzeroCommitment() public {
        _skipWithoutPrague();
        vm.prank(validators[0]);
        vm.expectRevert(DVTValidator.MissingEvidenceHash.selector);
        dvt.createProposal(OPERATOR, SLASH_LEVEL, "slash", bytes32(0));
    }

    function _expectExecutionError(uint256 id, bytes memory evidence, bytes memory expected) internal {
        // Use the authorized aggregator caller to bypass caller-liveness reads,
        // so this assertion excludes every aggregator call, including views.
        // An invalid proof would fail differently if forwarding were reached.
        vm.expectCall(address(bls), bytes(""), uint64(0));
        vm.prank(address(bls));
        vm.expectRevert(expected);
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 9, evidence, hex"badbad");
        (,,, bool executed,,) = dvt.proposals(id);
        assertFalse(executed);
        assertFalse(superPaymaster.executed());
    }

    function _executeMessageHash(uint256 proposalId, uint256 epoch, bytes32 evidenceHash)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                bls.domainSeparator(),
                bls.TAG_EXECUTE_SLASH(),
                proposalId,
                OPERATOR,
                SLASH_LEVEL,
                epoch,
                evidenceHash
            )
        );
    }

    function _queueMessageHash(uint256 epoch) internal view returns (bytes32) {
        return keccak256(
            abi.encode(bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), OPERATOR, SLASH_LEVEL, epoch)
        );
    }

    function _proof(bytes32 messageHash) internal view returns (bytes memory) {
        BLS.G2Point memory messagePoint = BLS.hashToG2(abi.encodePacked(messageHash));
        BLS.G2Point memory aggregateSignature;
        for (uint256 i = 0; i < validators.length; ++i) {
            BLS.G2Point memory partialSignature = _multiplyG2(messagePoint, secretScalars[i]);
            aggregateSignature = i == 0 ? partialSignature : BLS.add(aggregateSignature, partialSignature);
        }
        return abi.encode(MASK, abi.encode(aggregateSignature));
    }

    function _publicKey(uint256 scalar) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory points = new BLS.G1Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = _g1Generator();
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _pop(BLSAggregator aggregator, address validator, BLS.G1Point memory publicKey, uint256 scalar)
        internal
        view
        returns (BLS.G2Point memory)
    {
        return _multiplyG2(BLS.hashToG2(abi.encodePacked(aggregator.popDigest(validator, publicKey))), scalar);
    }

    function _multiplyG2(BLS.G2Point memory point, uint256 scalar) internal view returns (BLS.G2Point memory) {
        BLS.G2Point[] memory points = new BLS.G2Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = point;
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _g1Generator() internal pure returns (BLS.G1Point memory generator) {
        generator.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        generator.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        generator.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        generator.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }

    function _evidence() internal pure returns (bytes memory) {
        return abi.encode(CATEGORY, BODY);
    }

    function _evidenceHash() internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("SuperPaymaster.DVT.Evidence.v2"), CATEGORY, keccak256(BODY)));
    }

    function _hasPraguePrecompiles() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        return ok && result.length == 128;
    }

    function _skipWithoutPrague() internal {
        if (!pragueAvailable) vm.skip(true);
    }
}
