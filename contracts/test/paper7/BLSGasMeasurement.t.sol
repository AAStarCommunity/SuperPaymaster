// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GToken} from "src/tokens/GToken.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {Registry} from "src/core/Registry.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {DVTValidator} from "src/modules/monitoring/DVTValidator.sol";
import {BLS} from "src/utils/BLS.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/**
 * @title RepCreditPragueE2E
 * @notice Real EIP-2537 gate for the RepCredit evidence pipeline.
 * @dev This test uses no precompile code injection, call stubbing, or analytical
 *      gas correction. Public keys and signatures are generated with Prague
 *      G1/G2 MSM precompiles, then verified by the production BLSAggregator.
 *      The DVT reputation path performs the intended first verification in
 *      BLSAggregator and the independent second verification in Registry.
 *
 * Run:
 *   forge test --evm-version prague --match-contract RepCreditPragueE2E -vv
 *
 * The default Cancun suite skips these tests because EIP-2537 is unavailable.
 * Transaction-receipt gas measurements are collected by the SDK orchestrator;
 * Foundry gasleft values are not used as manuscript evidence.
 */
contract RepCreditPragueE2E is Test {
    uint256 internal constant VALIDATOR_COUNT = 13;
    uint256 internal constant DVT_STAKE = 30 ether;
    bytes32 internal constant ROLE_DVT = keccak256("DVT");

    bool internal pragueAvailable;
    GToken internal gtoken;
    GTokenStaking internal staking;
    MySBT internal sbt;
    Registry internal registry;
    DVTValidator internal dvt;
    BLSAggregator internal aggregator;

    address[VALIDATOR_COUNT] internal validators;
    uint256[VALIDATOR_COUNT] internal secretScalars;

    function setUp() public {
        pragueAvailable = _hasPraguePrecompiles();
        if (!pragueAvailable) return;

        vm.warp(1_800_000_000);
        gtoken = new GToken(21_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(0));
        staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), address(this));
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

        dvt = new DVTValidator(address(registry));
        aggregator = new BLSAggregator(address(registry), address(0xBEEF), address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        registry.setBLSAggregator(address(aggregator));
        registry.setReputationSource(address(aggregator), true);
        registry.setCreditTier(1, 0);
        registry.setCreditPolicy(type(uint256).max, type(uint256).max, 0, false);
        aggregator.setMinThreshold(3);
        aggregator.setDefaultThreshold(3);

        for (uint256 i = 0; i < VALIDATOR_COUNT; ++i) {
            address validator = address(uint160(0x1000 + i));
            uint256 scalar = i + 1;
            validators[i] = validator;
            secretScalars[i] = scalar;

            gtoken.mint(validator, 40 ether);
            vm.startPrank(validator);
            gtoken.approve(address(staking), 40 ether);
            registry.registerRole(ROLE_DVT, validator, abi.encode(DVT_STAKE));
            vm.stopPrank();

            dvt.addValidator(validator);
            BLS.G2Point memory emptyPoP;
            aggregator.registerBLSPublicKey(validator, _publicKey(scalar), uint8(i + 1), emptyPoP);
        }
    }

    function test_Prague_DirectRegistryAndDVTUpdateRealState() public {
        _skipWithoutPrague();
        address directUser = address(0xCAFE);
        address dvtUser = address(0xD00D);

        (address[] memory directUsers, uint256[] memory directScores) = _batch(directUser, 50, 1);
        uint256 directProposalId = 9_001;
        uint256 directEpoch = 1;
        bytes32 directHash = _reputationHash(directProposalId, directUsers, directScores, directEpoch, block.chainid);
        registry.batchUpdateGlobalReputation(
            directProposalId, directUsers, directScores, directEpoch, _proof(directHash, 3)
        );
        assertEq(registry.globalReputation(directUser), 50);

        assertEq(registry.getCreditLimit(dvtUser), 0, "fresh user must start with zero credit");
        (address[] memory dvtUsers, uint256[] memory dvtScores) = _batch(dvtUser, 100, 1);
        uint256 dvtProposalId = _createDVTProposal();
        uint256 dvtEpoch = 2;
        bytes32 dvtHash = _reputationHash(dvtProposalId, dvtUsers, dvtScores, dvtEpoch, block.chainid);
        bytes memory dvtProof = _proof(dvtHash, 3);

        vm.prank(validators[0]);
        dvt.executeWithProof(dvtProposalId, dvtUsers, dvtScores, dvtEpoch, dvtProof);

        assertEq(registry.globalReputation(dvtUser), 100);
        assertGt(registry.getCreditLimit(dvtUser), 0, "verified contribution must unlock bounded credit");
        (,,, bool executed,,) = dvt.proposals(dvtProposalId);
        assertTrue(executed);
        assertTrue(aggregator.executedProposals(dvtProposalId));
    }

    function test_Prague_RejectsBelowThreshold() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xA11CE), 100, 1);
        uint256 proposalId = _createDVTProposal();
        bytes32 messageHash = _reputationHash(proposalId, users, scores, 1, block.chainid);
        bytes memory proof = _proof(messageHash, 2);

        vm.prank(validators[0]);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidSignatureCount.selector, uint256(2), uint256(3)));
        dvt.executeWithProof(proposalId, users, scores, 1, proof);
    }

    function test_Prague_RejectsBadSignatureAndWrongChain() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xBAD), 100, 1);
        uint256 proposalId = _createDVTProposal();
        bytes memory unrelatedProof = _proof(keccak256("unrelated"), 3);

        vm.prank(validators[0]);
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        dvt.executeWithProof(proposalId, users, scores, 1, unrelatedProof);

        bytes32 wrongChainHash = _reputationHash(proposalId, users, scores, 1, block.chainid + 1);
        bytes memory wrongChainProof = _proof(wrongChainHash, 3);
        vm.prank(validators[0]);
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        dvt.executeWithProof(proposalId, users, scores, 1, wrongChainProof);
    }

    function test_Prague_RejectsMalformedSignature() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xBAD5), 100, 1);
        uint256 proposalId = _createDVTProposal();
        bytes memory malformedProof = abi.encode(_mask(3), hex"1234");

        vm.prank(validators[0]);
        vm.expectRevert();
        dvt.executeWithProof(proposalId, users, scores, 1, malformedProof);
    }

    function test_Prague_RejectsReplay() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xB0B), 100, 1);
        uint256 proposalId = _createDVTProposal();
        bytes32 messageHash = _reputationHash(proposalId, users, scores, 1, block.chainid);
        bytes memory proof = _proof(messageHash, 3);

        vm.prank(validators[0]);
        dvt.executeWithProof(proposalId, users, scores, 1, proof);

        vm.prank(validators[0]);
        vm.expectRevert(DVTValidator.ProposalExecutedAlready.selector);
        dvt.executeWithProof(proposalId, users, scores, 1, proof);
    }

    function test_Prague_RejectsExitedValidatorAtVerificationTime() public {
        _skipWithoutPrague();
        vm.warp(block.timestamp + 31 days);
        vm.prank(validators[0]);
        aggregator.requestGuardianExit();
        vm.warp(block.timestamp + aggregator.GUARDIAN_EXIT_DELAY());
        vm.prank(validators[0]);
        registry.exitRole(ROLE_DVT);

        (address[] memory users, uint256[] memory scores) = _batch(address(0xE17), 100, 1);
        uint256 proposalId = _createDVTProposalFrom(validators[1]);
        bytes32 messageHash = _reputationHash(proposalId, users, scores, 1, block.chainid);
        bytes memory proof = _proof(messageHash, 3);

        vm.prank(validators[1]);
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.SlotValidatorRoleRevoked.selector, uint8(1), validators[0])
        );
        dvt.executeWithProof(proposalId, users, scores, 1, proof);
    }

    function _hasPraguePrecompiles() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        return ok && result.length == 128;
    }

    function _skipWithoutPrague() internal {
        if (!pragueAvailable) vm.skip(true);
    }

    function _createDVTProposal() internal returns (uint256) {
        return _createDVTProposalFrom(validators[0]);
    }

    function _createDVTProposalFrom(address proposer) internal returns (uint256 proposalId) {
        vm.prank(proposer);
        proposalId = dvt.createProposal(address(0), 0, "repcredit-contribution");
    }

    function _batch(address firstUser, uint256 firstScore, uint256 size)
        internal
        pure
        returns (address[] memory users, uint256[] memory scores)
    {
        users = new address[](size);
        scores = new uint256[](size);
        for (uint256 i = 0; i < size; ++i) {
            users[i] = address(uint160(firstUser) + uint160(i));
            scores[i] = firstScore + i;
        }
    }

    /// @dev CC-48 round-2 schema: keccak256(abi.encode(domainSeparator, TAG_REPUTATION,
    ///      proposalId, users, scores, epoch)) with
    ///      domainSeparator = keccak256(abi.encode(DOMAIN_NAME, chainid, aggregator, registry)).
    ///      Reconstructed field-by-field here (not read off the aggregator) so the test
    ///      would catch a silent schema drift in the contract.
    function _reputationHash(
        uint256 proposalId,
        address[] memory users,
        uint256[] memory scores,
        uint256 epoch,
        uint256 chainId
    ) internal view returns (bytes32) {
        return _reputationHashFor(address(aggregator), address(registry), proposalId, users, scores, epoch, chainId);
    }

    function _reputationHashFor(
        address agg,
        address reg,
        uint256 proposalId,
        address[] memory users,
        uint256[] memory scores,
        uint256 epoch,
        uint256 chainId
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(keccak256("SuperPaymaster.BLSConsensus.v1"), chainId, agg, reg)
        );
        return keccak256(
            abi.encode(domain, keccak256("SuperPaymaster.BLS.Reputation.v1"), proposalId, users, scores, epoch)
        );
    }

    function _proof(bytes32 messageHash, uint256 signerCount) internal view returns (bytes memory) {
        BLS.G2Point memory aggregateSignature;
        BLS.G2Point memory messagePoint = BLS.hashToG2(abi.encodePacked(messageHash));
        for (uint256 i = 0; i < signerCount; ++i) {
            BLS.G2Point memory partialSignature = _multiplyG2(messagePoint, secretScalars[i]);
            aggregateSignature = i == 0 ? partialSignature : BLS.add(aggregateSignature, partialSignature);
        }
        return abi.encode(_mask(signerCount), abi.encode(aggregateSignature));
    }

    function _publicKey(uint256 scalar) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory points = new BLS.G1Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = _g1Generator();
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _multiplyG2(BLS.G2Point memory point, uint256 scalar) internal view returns (BLS.G2Point memory) {
        BLS.G2Point[] memory points = new BLS.G2Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = point;
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _mask(uint256 signerCount) internal pure returns (uint256) {
        return (uint256(1) << signerCount) - 1;
    }

    function _g1Generator() internal pure returns (BLS.G1Point memory generator) {
        generator.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        generator.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        generator.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        generator.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }
}
