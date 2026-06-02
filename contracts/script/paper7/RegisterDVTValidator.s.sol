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
 *   5. BLSAggregator.registerBLSPublicKey(validator, G1_GENERATOR, slot=1)
 *
 * Run (Sepolia):
 *   forge script contracts/script/paper7/RegisterDVTValidator.s.sol  *     --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
 *
 * Env: PRIVATE_KEY, ENV (sepolia|optimism)
 * Optional: DVT_VALIDATOR_ADDR, BLS_AGGREGATOR_ADDR, REGISTRY_ADDR, GTOKEN_ADDR, STAKING_ADDR
 */
import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

contract RegisterDVTValidator is Script {
    // BLS12-381 G1 generator (EIP-2537 uncompressed, 4x bytes32)
    function _g1Gen() internal pure returns (BLS.G1Point memory p) {
        p.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        p.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        p.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        p.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

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
            console.log("[5] registerBLSPublicKey(slot=1, G1_GEN)...");
            bls.registerBLSPublicKey(v, _g1Gen(), 1, _emptyPoP());
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
