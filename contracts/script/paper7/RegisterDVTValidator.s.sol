// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/**
 * @title RegisterDVTValidator
 * @notice Paper7 Step 1 — Register deployer as DVT validator on Sepolia/Mainnet
 *
 * Steps:
 *   1. GToken.approve(staking, 33 GT)
 *   2. Registry.safeMintForRole(ROLE_DVT, validator, ...) -- 30 GT stake
 *   3. DVTValidator.addValidator(validator)
 *   4. BLSAggregator.setMinThreshold(1) + setDefaultThreshold(1)
 *   5. BLSAggregator.registerBLSPublicKey(validator, <env-supplied key>, slot=1, <env PoP>)
 *
 * CC-48 round-3 — TWO breaking changes to this script, both deliberate:
 *   - It used to register the BLS12-381 G1 GENERATOR, i.e. the public key for secret
 *     scalar 1. That key's secret is public knowledge; a validator set holding it has no
 *     security at all, and it is exactly the state the RepCredit experiment stack was
 *     found in. The key is now supplied by env and REFUSED if its scalar is in the
 *     publicly-scannable range.
 *   - Proof-of-possession is now mandatory on the owner path too, so a PoP must be
 *     supplied. Generate it off-chain as sk * H_pop(bls.popDigest(validator, pk)) — it is
 *     bound to (domain, chain, aggregator, validator, key) and does not transfer.
 *
 * Run (Sepolia):
 *   forge script contracts/script/paper7/RegisterDVTValidator.s.sol  *     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
 *
 * Env: PRIVATE_KEY, ENV (sepolia|optimism)
 *      BLS_PUBKEY   128-byte uncompressed G1 point (x_a‖x_b‖y_a‖y_b)
 *      BLS_POP      256-byte G2 proof-of-possession over popDigest(validator, pubkey)
 * Optional: DVT_VALIDATOR_ADDR, BLS_AGGREGATOR_ADDR, REGISTRY_ADDR, GTOKEN_ADDR, STAKING_ADDR
 *
 * Requires an EIP-2537 (Prague) RPC: both the weak-key screen and the on-chain PoP
 * verification use the BLS12-381 precompiles.
 */
import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import {BLSKeyScanLib} from "../checks/BLSKeyScanLib.sol";

contract RegisterDVTValidator is Script {
    /// @dev The validator's REAL public key, supplied as 128 raw bytes. There is no
    ///      default on purpose: the previous default was the G1 generator (scalar 1).
    function _pubkeyFromEnv() internal view returns (BLS.G1Point memory p) {
        bytes memory raw = vm.envBytes("BLS_PUBKEY");
        require(raw.length == 128, "BLS_PUBKEY must be 128 bytes (x_a|x_b|y_a|y_b)");
        (p.x_a, p.x_b, p.y_a, p.y_b) = abi.decode(raw, (bytes32, bytes32, bytes32, bytes32));
    }

    /// @dev PoP = sk * H_pop(bls.popDigest(validator, pubkey)), 256 raw bytes of G2.
    function _popFromEnv() internal view returns (BLS.G2Point memory pop) {
        bytes memory raw = vm.envBytes("BLS_POP");
        require(raw.length == 256, "BLS_POP must be 256 bytes of uncompressed G2");
        (pop.x_c0_a, pop.x_c0_b, pop.x_c1_a, pop.x_c1_b, pop.y_c0_a, pop.y_c0_b, pop.y_c1_a, pop.y_c1_b) =
            abi.decode(raw, (bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, bytes32));
    }

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory cfg = vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", network, ".json"));

        address dvtAddr = vm.envOr("DVT_VALIDATOR_ADDR", stdJson.readAddress(cfg, ".dvtValidator"));
        address blsAddr = vm.envOr("BLS_AGGREGATOR_ADDR", stdJson.readAddress(cfg, ".blsAggregator"));
        address regAddr = vm.envOr("REGISTRY_ADDR", stdJson.readAddress(cfg, ".registry"));
        address gtAddr = vm.envOr("GTOKEN_ADDR", stdJson.readAddress(cfg, ".gToken"));
        address stkAddr = vm.envOr("STAKING_ADDR", stdJson.readAddress(cfg, ".staking"));

        DVTValidator dvt = DVTValidator(dvtAddr);
        BLSAggregator bls = BLSAggregator(blsAddr);
        Registry reg = Registry(regAddr);
        IERC20 gt = IERC20(gtAddr);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address v = vm.addr(pk);

        console.log("=== RegisterDVTValidator ===");
        console.log("network:", network, "validator:", v);

        require(bls.owner() == v, "Not BLS owner");
        require(dvt.owner() == v, "Not DVT owner");
        require(gt.balanceOf(v) >= 33 ether, "Need >= 33 GT");

        bool hasDVT = reg.hasRole(ROLE_DVT, v);
        bool hasVal = dvt.isValidator(v);
        (,, bool keyActive) = bls.getBLSPublicKey(v);

        vm.startBroadcast(pk);

        if (!hasDVT) {
            console.log("[1] approve + safeMintForRole(DVT)...");
            gt.approve(stkAddr, 33 ether);
            reg.safeMintForRole(ROLE_DVT, v, abi.encode(uint256(30 ether)));
            console.log("    DVT role granted");
        } else {
            console.log("[1-2] already has DVT role");
        }

        if (!hasVal) {
            console.log("[3] addValidator...");
            dvt.addValidator(v);
            console.log("    validator added");
        } else {
            console.log("[3] already validator");
        }

        // minThreshold floor is 2 (contract enforced), chain value is 3.
        // For paper7 gas measurement, defaultThreshold just needs to be >= minThreshold.
        // executeWithProof uses zero BLS sig (expected revert), threshold doesn't affect gas.
        uint256 curMin = bls.minThreshold();
        uint256 curDef = bls.defaultThreshold();
        if (curDef > curMin) {
            console.log("[4] setDefaultThreshold to minThreshold...");
            bls.setDefaultThreshold(curMin);
            console.log("    defaultThreshold set to", curMin);
        } else {
            console.log("[4] threshold already at minimum, skip");
        }

        if (!keyActive) {
            BLS.G1Point memory pubkey = _pubkeyFromEnv();
            require(
                !BLSKeyScanLib.isWeakScalarKey(pubkey),
                "CC-48: BLS_PUBKEY derives from a publicly-known scalar; generate a real key"
            );
            console.log("[5] registerBLSPublicKey(slot=1, env key + PoP)...");
            bls.registerBLSPublicKey(v, pubkey, 1, _popFromEnv());
            console.log("    BLS key registered");
        } else {
            console.log("[5] BLS key already registered");
        }

        vm.stopBroadcast();

        console.log("=== Verification ===");
        console.log("hasRole(DVT):", reg.hasRole(ROLE_DVT, v));
        console.log("isValidator:", dvt.isValidator(v));
        console.log("defaultThreshold:", bls.defaultThreshold());
        (,, bool ka2) = bls.getBLSPublicKey(v);
        console.log("BLS key active:", ka2);
        console.log("Done. Run MockDVTExecution.s.sol next.");
    }
}
