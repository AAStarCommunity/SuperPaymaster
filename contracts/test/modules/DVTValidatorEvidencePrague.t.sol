// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
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
    PragueEvidenceRegistryStub private registry;
    PragueEvidenceSuperPaymasterStub private superPaymaster;
    DVTValidator private dvt;
    BLSAggregator private bls;

    function setUp() public {
        pragueAvailable = _hasPraguePrecompiles();
        if (!pragueAvailable) return;

        registry = new PragueEvidenceRegistryStub();
        superPaymaster = new PragueEvidenceSuperPaymasterStub();

        bytes32[] memory categories = new bytes32[](1);
        categories[0] = CATEGORY;
        address[] memory checkers = new address[](1);
        checkers[0] = address(new MockEvidenceCategory());
        dvt = new DVTValidator(address(registry), 1, categories, checkers);
        bls = new BLSAggregator(address(registry), address(superPaymaster), address(dvt));
        dvt.setBLSAggregator(address(bls));

        for (uint8 i = 0; i < validators.length; ++i) {
            address validator = validators[i];
            uint256 scalar = secretScalars[i];
            dvt.addValidator(validator);
            BLS.G1Point memory publicKey = _publicKey(scalar);
            bls.registerBLSPublicKey(
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
