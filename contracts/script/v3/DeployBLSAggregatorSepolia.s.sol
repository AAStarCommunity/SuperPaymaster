// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import "src/modules/monitoring/BLSAggregator.sol";

/// @notice Narrow views on the existing Sepolia Registry (sanity checks only).
interface IRegSepolia {
    function GTOKEN_STAKING() external view returns (address);
    function SUPER_PAYMASTER() external view returns (address);
}

interface IStakingSlasher {
    function setAuthorizedSlasher(address slasher, bool authorized) external;
    function authorizedSlashers(address) external view returns (bool);
}

/// @title  DeployBLSAggregatorSepolia — CC-89 Phase-2 testnet E2E
/// @notice Deploys BLSAggregator 4.9.0 (A' commitment + bounded guardian exit + CC-48
///         round-3 verifier pinning) to Sepolia,
///         pointing at the EXISTING registry / superPaymaster / dvtValidator, and
///         authorizes it as a GTokenStaking slasher (so executeGuardianSlash →
///         slashByDVT works). Does NOT rewire registry/dvt/sp — this is a dedicated
///         E2E aggregator, not a production replacement.
/// @dev    Run:
///           forge script contracts/script/v3/DeployBLSAggregatorSepolia.s.sol:DeployBLSAggregatorSepolia \
///             --rpc-url $SEPOLIA_RPC_URL --broadcast --private-key $PRIVATE_KEY_JASON
///         Post-deploy (separate steps — need DVT inputs, see CC-89):
///           1. DVT deploys OverIssueFraudProofVerifier(thisAggregator) → gives verifier addr,
///              and proves it domain-bound with contracts/test/helpers/
///              FraudProofVerifierConformance.sol (CC-48 round-3 MEDIUM-2). Until that
///              conformance run exists, leave the verifier UNSET (dormant).
///           2. registerBLSPublicKey(guardian, pubkey, slot, PoP) × 3   (DVT provides keys).
///              PoP is MANDATORY on this path too as of 4.7.0 — the owner can no longer
///              register a key it cannot prove the guardian holds.
///           3. proposeFraudProofVerifier(verifier), wait VERIFIER_ROTATION_DELAY,
///              applyFraudProofVerifier()
///           4. BLS_AGGREGATOR=<this> forge script contracts/script/checks/
///              ScanDuplicateBLSKeys.s.sol --rpc-url $SEPOLIA_RPC_URL
///              (duplicate / publicly-known-scalar / quorum-reachability gate)
///         Addresses are chain-verified as of 2026-08-15.
contract DeployBLSAggregatorSepolia is Script {
    address constant REGISTRY        = 0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71;
    address constant SUPER_PAYMASTER = 0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9;
    address constant DVT_VALIDATOR   = 0x568b1486BFE036e603eA11f0D03Dc47fa62c9E0e;
    address constant STAKING         = 0x472297B557c1d0F030f281a5Bb8A535f6c5AB65e;

    function run() external {
        // Hardcoded Sepolia addresses — fail closed on any other chain.
        require(block.chainid == 11155111, "not Sepolia (11155111)");
        uint256 pk = vm.envUint("PRIVATE_KEY_JASON");

        // Pre-flight sanity: the constants must match the live Registry wiring, else
        // _reconstructPkAgg (reads registry.GTOKEN_STAKING) and _executeSlash (calls
        // superPaymaster) would target the wrong contracts.
        require(IRegSepolia(REGISTRY).GTOKEN_STAKING() == STAKING, "staking mismatch");
        require(IRegSepolia(REGISTRY).SUPER_PAYMASTER() == SUPER_PAYMASTER, "sp mismatch");

        vm.startBroadcast(pk);

        BLSAggregator agg = new BLSAggregator(REGISTRY, SUPER_PAYMASTER, DVT_VALIDATOR);
        require(
            keccak256(bytes(agg.version())) == keccak256("BLSAggregator-4.9.0"),
            "unexpected version - build the A-prime branch"
        );

        // Authorize as GToken slasher so executeGuardianSlash → slashByDVT can slash
        // guilty guardians' ROLE_DVT locks. (Owner == jason == deployer.)
        IStakingSlasher(STAKING).setAuthorizedSlasher(address(agg), true);

        vm.stopBroadcast();

        require(IStakingSlasher(STAKING).authorizedSlashers(address(agg)), "slasher not set");

        console.log("BLSAggregator 4.9.0 (A' + exit gate + frozen verdict) deployed at:", address(agg));
        console.log("fraudProofVerifier:", agg.fraudProofVerifier(), "(unset -> dormant, fail-closed)");
        console.log("NEXT: give this address to DVT for OverIssueFraudProofVerifier deploy,");
        console.log("      then registerBLSPublicKey x3 (DVT keys) + proposeFraudProofVerifier(verifier)");
        console.log("      followed by applyFraudProofVerifier() after VERIFIER_ROTATION_DELAY.");
        console.log("CC-48 round-2: IFraudProofVerifier.verify takes a leading bytes32");
        console.log("      domainDigest = aggregator.fraudProofDigest(id, guiltyGuardians);");
        console.log("      selector 0x61077735. Verifiers built for 4.5.0 or earlier WILL NOT");
        console.log("      decode; DVT must rebuild AND prove domain binding (round-3 MEDIUM-2).");
        console.log("CC-48 round-4: queueGuardianSlash FREEZES the verdict - guardiansHash +");
        console.log("      fraudProofHash = keccak256(fraudProof). execute/retry re-check those");
        console.log("      two and never call the verifier again, so a rotation, a proxy");
        console.log("      implementation swap at the same address, or a selfdestruct cannot");
        console.log("      re-judge an open case. guardianSlashCases now returns 7 fields");
        console.log("      (guardiansHash, fraudProofHash, deadline, status, guardianCount,");
        console.log("      resolvedCount, verifier) - SDK/DVT decoders must follow. The");
        console.log("      executor MUST re-present the exact proof bytes (FraudProofMismatch).");
        console.log("aggregator domainSeparator:");
        console.logBytes32(agg.domainSeparator());
    }
}
