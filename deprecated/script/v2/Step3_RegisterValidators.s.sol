// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/monitoring/DVTValidator.sol";
import "src/paymasters/v2/monitoring/BLSAggregator.sol";

/**
 * @title Step3_RegisterValidators
 * @notice Register DVT validators and BLS public keys
 * @dev This script registers initial validators for the monitoring system
 *
 * Prerequisites:
 * - DVTValidator and BLSAggregator must be deployed
 * - Deployer must be the owner
 *
 * Flow:
 * 1. Register validators in DVTValidator (max 13)
 * 2. Register BLS public keys in BLSAggregator
 * 3. Verify registration
 */
contract Step3_RegisterValidators is Script {
    // Deployed contract addresses
    DVTValidator public dvtValidator;
    BLSAggregator public blsAggregator;

    // Validator addresses (generate test accounts)
    address[] public validatorAddresses;

    // BLS public keys (48 bytes each - for testing)
    bytes[] public blsPublicKeys;

    // Node URIs
    string[] public nodeURIs;

    function setUp() public {
        // Load deployed contracts
        dvtValidator = DVTValidator(vm.envAddress("V2_DVT_VALIDATOR"));
        blsAggregator = BLSAggregator(vm.envAddress("V2_BLS_AGGREGATOR"));

        console.log("=== Step 3: Register DVT Validators ===");
        console.log("DVTValidator:", address(dvtValidator));
        console.log("BLSAggregator:", address(blsAggregator));
        console.log("");

        // Initialize validator data (register 7 validators to meet MIN_VALIDATORS threshold)
        _initializeValidatorData();
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Register validators in DVTValidator
        _registerValidatorsInDVT();

        // Step 2: Register BLS keys in BLSAggregator
        _registerBLSKeys();

        vm.stopBroadcast();

        // Step 3: Verify registration
        _verifyRegistration();

        console.log("\n=== Registration Complete ===");
    }

    function _initializeValidatorData() internal {
        console.log("Initializing validator data...");

        // Generate 7 test validator addresses
        for (uint256 i = 0; i < 7; i++) {
            // Use deterministic addresses for testing
            address validatorAddr = address(uint160(uint256(keccak256(abi.encodePacked("validator", i)))));
            validatorAddresses.push(validatorAddr);

            // Generate deterministic 48-byte BLS public key (placeholder for testing)
            // In production: use proper BLS12-381 key generation
            bytes memory blsKey = _generateTestBLSKey(i);
            blsPublicKeys.push(blsKey);

            // Node URI
            string memory nodeURI = string(abi.encodePacked("https://dvt-node-", vm.toString(i), ".example.com"));
            nodeURIs.push(nodeURI);

            console.log("Validator", i, ":", validatorAddr);
        }

        console.log("Initialized", validatorAddresses.length, "validators");
        console.log("");
    }

    function _registerValidatorsInDVT() internal {
        console.log("Step 1: Registering validators in DVTValidator...");

        for (uint256 i = 0; i < validatorAddresses.length; i++) {
            console.log("\nRegistering validator", i);
            console.log("  Address:", validatorAddresses[i]);
            console.log("  Node URI:", nodeURIs[i]);

            dvtValidator.registerValidator(
                validatorAddresses[i],
                blsPublicKeys[i],
                nodeURIs[i]
            );

            console.log("  [OK] Registered");
        }

        console.log("\n[OK] All validators registered in DVTValidator");
        console.log("");
    }

    function _registerBLSKeys() internal {
        console.log("Step 2: Registering BLS keys in BLSAggregator...");

        for (uint256 i = 0; i < validatorAddresses.length; i++) {
            console.log("\nRegistering BLS key for validator", i);
            console.log("  Address:", validatorAddresses[i]);

            blsAggregator.registerBLSPublicKey(
                validatorAddresses[i],
                blsPublicKeys[i]
            );

            console.log("  [OK] Registered");
        }

        console.log("\n[OK] All BLS keys registered in BLSAggregator");
        console.log("");
    }

    function _verifyRegistration() internal view {
        console.log("Step 3: Verifying registration...");
        console.log("");

        // Check validator count
        uint256 validatorCount = dvtValidator.validatorCount();
        console.log("Total validators registered:", validatorCount);
        console.log("Minimum required:", dvtValidator.MIN_VALIDATORS());

        require(validatorCount >= dvtValidator.MIN_VALIDATORS(), "Not enough validators");
        console.log("[OK] Meets minimum validator requirement");
        console.log("");

        // Verify each validator
        for (uint256 i = 0; i < validatorCount; i++) {
            DVTValidator.ValidatorInfo memory info = dvtValidator.getValidator(i);

            console.log("Validator", i, ":");
            console.log("  Address:", info.validatorAddress);
            console.log("  Active:", info.isActive);
            console.log("  Node URI:", info.nodeURI);

            require(info.isActive, "Validator not active");

            // Verify BLS key in aggregator
            BLSAggregator.BLSPublicKey memory blsKey = blsAggregator.getBLSPublicKey(info.validatorAddress);
            require(blsKey.isActive, "BLS key not active");
            require(blsKey.publicKey.length == 48, "Invalid BLS key length");

            console.log("  BLS Key Active:", blsKey.isActive);
            console.log("  [OK] Verified");
            console.log("");
        }

        console.log("[OK] All validators verified successfully");
    }

    /**
     * @notice Generate test BLS public key (48 bytes)
     * @dev For testing only - use proper BLS12-381 key generation in production
     * @param seed Seed for deterministic generation
     * @return key 48-byte BLS public key
     */
    function _generateTestBLSKey(uint256 seed) internal pure returns (bytes memory key) {
        // Generate deterministic 48 bytes for testing
        // In production: use proper BLS12-381 G1 point generation

        key = new bytes(48);

        // Fill with deterministic data
        bytes32 hash1 = keccak256(abi.encodePacked("bls_key_part1", seed));
        bytes32 hash2 = keccak256(abi.encodePacked("bls_key_part2", seed));

        // Copy first 32 bytes
        for (uint256 i = 0; i < 32; i++) {
            key[i] = hash1[i];
        }

        // Copy remaining 16 bytes
        for (uint256 i = 0; i < 16; i++) {
            key[32 + i] = hash2[i];
        }

        return key;
    }
}
