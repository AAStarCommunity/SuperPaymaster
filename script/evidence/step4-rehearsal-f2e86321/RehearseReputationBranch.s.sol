// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {DVTValidator} from "src/modules/monitoring/DVTValidator.sol";
import {Registry} from "src/core/Registry.sol";
import {GToken} from "src/tokens/GToken.sol";
import {BLS} from "src/utils/BLS.sol";
import {BLSKeyScanLib} from "../checks/BLSKeyScanLib.sol";

/// @title  RehearseReputationBranch — real-key reputation consensus on a DeployLive-built fork
/// @notice FORK-ONLY rehearsal (refuses anything but an anvil fork whose aggregator matches
///         the config): registers three guardians with fresh BLS keys (ROLE_DVT stake, DVT
///         admission, real PoP), sets thresholds to the declared inputs, then drives ONE
///         reputation proposal through the production DVT path (createProposal →
///         executeWithProof → BLSAggregator.verifyAndExecute → Registry re-verification).
/// @dev    Run with `--evm-version prague --unlocked` after impersonating GOVERNANCE (the
///         aggregator/DVT owner). Secrets SK1..SK3 are throwaway scalars generated for this
///         run only; they are read from env and never written anywhere by this script.
contract RehearseReputationBranch is Script {
    bytes32 constant ROLE_DVT = keccak256("DVT");
    uint256 constant N = 3;

    BLSAggregator agg;
    DVTValidator dvt;
    Registry registry;
    GToken gtoken;
    address deployer;
    address governance;
    address target;
    uint256 minT;
    uint256 defT;
    address[N] v;
    uint256[N] sk;

    function run() external {
        agg = BLSAggregator(vm.envAddress("AGG"));
        dvt = DVTValidator(vm.envAddress("DVT"));
        registry = Registry(vm.envAddress("REGISTRY"));
        gtoken = GToken(vm.envAddress("GTOKEN"));
        deployer = vm.envAddress("DEPLOYER");
        governance = vm.envAddress("GOVERNANCE");
        target = vm.envAddress("TARGET_USER");
        minT = vm.envUint("MIN_THRESHOLD");
        defT = vm.envUint("DEFAULT_THRESHOLD");
        require(agg.owner() == governance && dvt.owner() == governance, "owner != GOVERNANCE");
        require(address(dvt.BLS_AGGREGATOR()) == address(agg) && agg.DVT_VALIDATOR() == address(dvt), "pairing");
        for (uint256 i; i < N; ++i) {
            v[i] = vm.envAddress(string.concat("V", vm.toString(i + 1)));
            sk[i] = vm.envUint(string.concat("SK", vm.toString(i + 1)));
        }
        _stake();
        _admitAndBind();
        uint256 id = _propose();
        _executeAndReadBack(id);
    }

    /// 1. Stake: GToken from its owner, ROLE_DVT registration by each guardian.
    function _stake() internal {
        Registry.RoleConfig memory cfg = registry.getRoleConfig(ROLE_DVT);
        uint256 need = cfg.minStake + cfg.ticketPrice;
        vm.startBroadcast(deployer);
        for (uint256 i; i < N; ++i) gtoken.mint(v[i], need);
        vm.stopBroadcast();
        for (uint256 i; i < N; ++i) {
            vm.startBroadcast(v[i]);
            gtoken.approve(address(registry.GTOKEN_STAKING()), need);
            registry.registerRole(ROLE_DVT, v[i], abi.encode(cfg.minStake));
            vm.stopBroadcast();
        }
    }

    /// 2. Governance: admit, bind keys (real PoP), then thresholds -- the A10 -> A11 order.
    function _admitAndBind() internal {
        for (uint256 i; i < N; ++i) {
            BLS.G1Point memory pk = _publicKey(sk[i]);
            require(!BLSKeyScanLib.isWeakScalarKey(pk), "weak key");
            BLS.G2Point memory pop = _pop(v[i], pk, sk[i]);
            vm.startBroadcast(governance);
            dvt.addValidator(v[i]);
            dvt.registerBLSPublicKey(v[i], pk, uint8(i + 1), pop);
            vm.stopBroadcast();
        }
        vm.startBroadcast(governance);
        agg.setMinThreshold(minT);
        agg.setDefaultThreshold(defT);
        vm.stopBroadcast();
    }

    /// 3. Production path: guardian 1 opens a reputation-only proposal.
    function _propose() internal returns (uint256 id) {
        vm.startBroadcast(v[0]);
        id = dvt.createProposal(address(0), 0, "rc8 reputation-branch rehearsal", bytes32(0));
        vm.stopBroadcast();
    }

    /// 4. Guardian 1 executes with an aggregate signature from the first `defT` slots; readback.
    function _executeAndReadBack(uint256 id) internal {
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = target;
        scores[0] = 50;
        bytes32 h = agg.reputationMessageHash(id, users, scores, 1);
        bytes memory proof = _proof(h, defT);
        vm.startBroadcast(v[0]);
        dvt.executeWithProof(id, users, scores, 1, "", proof);
        vm.stopBroadcast();

        require(registry.globalReputation(target) == 50, "score");
        require(agg.executedProposals(id), "aggregator executed");
        require(agg.minThreshold() == minT && agg.defaultThreshold() == defT, "thresholds");
        for (uint256 i; i < N; ++i) require(agg.validatorAtSlot(uint8(i + 1)) == v[i], "slot");
        BLSKeyScanLib.requireHealthy(address(agg), BLSKeyScanLib.maxRequiredThreshold(address(agg)));
        console.log("REHEARSAL proposalId", id);
        console.log("REHEARSAL messageHash");
        console.logBytes32(h);
        console.log("REHEARSAL globalReputation(target)", registry.globalReputation(target));
    }

    function _pop(address validator, BLS.G1Point memory pk, uint256 s)
        internal
        view
        returns (BLS.G2Point memory)
    {
        return _mulG2(BLS.hashToG2(abi.encodePacked(agg.popDigest(validator, pk))), s);
    }

    function _proof(bytes32 h, uint256 signers) internal view returns (bytes memory) {
        BLS.G2Point memory m = BLS.hashToG2(abi.encodePacked(h));
        BLS.G2Point memory sig;
        for (uint256 i; i < signers; ++i) {
            BLS.G2Point memory part = _mulG2(m, sk[i]);
            sig = i == 0 ? part : BLS.add(sig, part);
        }
        return abi.encode((uint256(1) << signers) - 1, abi.encode(sig));
    }

    function _publicKey(uint256 s) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory p = new BLS.G1Point[](1);
        bytes32[] memory k = new bytes32[](1);
        p[0].x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        p[0].x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        p[0].y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        p[0].y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
        k[0] = bytes32(s);
        return BLS.msm(p, k);
    }

    function _mulG2(BLS.G2Point memory point, uint256 s) internal view returns (BLS.G2Point memory) {
        BLS.G2Point[] memory p = new BLS.G2Point[](1);
        bytes32[] memory k = new bytes32[](1);
        p[0] = point;
        k[0] = bytes32(s);
        return BLS.msm(p, k);
    }
}
