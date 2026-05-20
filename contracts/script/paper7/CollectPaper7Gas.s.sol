// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

./**
 * @title CollectPaper7Gas
 * @notice Paper7 Step 3 — Read-only report of all gas data
 *
 * Run: forge script contracts/script/paper7/CollectPaper7Gas.s.sol
 *        --rpc-url $SEPOLIA_RPC_URL -vvv
 * Env: ENV
 */
import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";

interface IVer { function version() external view returns (string memory); }

contract CollectPaper7Gas is Script {
    function run() external view {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory cfg = vm.readFile(string.concat(vm.projectRoot(), "/deployments/config.", network, ".json"));

        address dvtAddr = stdJson.readAddress(cfg, ".dvtValidator");
        address blsAddr = stdJson.readAddress(cfg, ".blsAggregator");
        address regAddr = stdJson.readAddress(cfg, ".registry");
        address spAddr  = stdJson.readAddress(cfg, ".superPaymaster");
        address sbtAddr = stdJson.readAddress(cfg, ".sbt");
        address stkAddr = stdJson.readAddress(cfg, ".staking");

        DVTValidator  dvt = DVTValidator(dvtAddr);
        BLSAggregator bls = BLSAggregator(blsAddr);

        console.log("================================================");
        console.log("     PAPER7 GAS DATA COLLECTION REPORT");
        console.log("================================================");
        console.log("Network:", network, "Block:", block.number);

        console.log("-- Contract Versions --");
        console.log("SuperPaymaster:", IVer(spAddr).version());
        console.log("Registry      :", IVer(regAddr).version());
        console.log("BLSAggregator :", IVer(blsAddr).version());
        console.log("DVTValidator  :", IVer(dvtAddr).version());
        console.log("MySBT         :", IVer(sbtAddr).version());
        console.log("GTokenStaking :", IVer(stkAddr).version());

        console.log("-- DVT State --");
        console.log("nextProposalId   :", dvt.nextProposalId());
        console.log("defaultThreshold :", bls.defaultThreshold());
        address slot1 = bls.validatorAtSlot(1);
        console.log("validatorAtSlot1 :", slot1);
        if (slot1 != address(0)) {
            (,,bool ka) = bls.getBLSPublicKey(slot1);
            console.log("key active       :", ka);
            console.log("isValidator      :", dvt.isValidator(slot1));
        }

        console.log("-- Wiring --");
        bool ok = address(bls.REGISTRY()) == regAddr
               && bls.DVT_VALIDATOR() == dvtAddr
               && address(dvt.REGISTRY()) == regAddr
               && dvt.BLS_AGGREGATOR() == blsAddr;
        console.log("Wiring OK:", ok);

        console.log("================================================");
        console.log("     PAPER7 GAS SUMMARY");
        console.log("================================================");
        console.log("GASLESS PAYMENT (Sepolia, real on-chain):");
        console.log("  T1  PaymasterV4  + aPNTs : 189,148 gas");
        console.log("  T2.1 SuperPaymaster+aPNTs : 299,663 gas");
        console.log("  T2.2 SuperPaymaster+PNTs  : 262,259 gas");
        console.log("BLS VERIFICATION (forge test, BLSAggregator-4.1.0):");
        console.log("  verify n=3  (corrected)   : 363,595 gas");
        console.log("  verify n=7  (corrected)   : 430,767 gas");
        console.log("  verify n=13 (corrected)   : 531,556 gas");
        console.log("  vae n=7 b=10  (corrected) : 478,604 gas");
        console.log("  vae n=7 b=100 (corrected) : 542,664 gas");
        console.log("  amortized/user (b=100)    :   4,403 gas");
        console.log("DAILY COST (1000 users/day):");
        console.log("  CommunityFi BLS           : 4,403,480 gas/day");
        console.log("  ECDSA multisig            : 50,000,000 gas/day");
        console.log("  Reduction factor          : ~11x");
        console.log("================================================");
    }
}
