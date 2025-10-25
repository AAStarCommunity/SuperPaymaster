// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/Registry.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";
import "../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../src/paymasters/v2/tokens/xPNTsFactory.sol";
import "../src/paymasters/v2/tokens/MySBTWithNFTBinding.sol";
import "../src/paymasters/v2/tokens/MySBTFactory.sol";
import "../src/paymasters/v2/monitoring/DVTValidator.sol";
import "../src/paymasters/v2/monitoring/BLSAggregator.sol";

/**
 * @title DeploySuperPaymasterV2
 * @notice Complete deployment script for SuperPaymaster v2.0 system
 * @dev Deploys all contracts in correct order with proper initialization
 *
 * Deployment Order:
 * 1. Mock GToken (if not exists)
 * 2. GTokenStaking
 * 3. Registry
 * 4. SuperPaymasterV2
 * 5. xPNTsFactory
 * 6. MySBT
 * 7. DVTValidator
 * 8. BLSAggregator
 *
 * Usage:
 * forge script script/DeploySuperPaymasterV2.s.sol:DeploySuperPaymasterV2 \
 *   --rpc-url $RPC_URL \
 *   --private-key $PRIVATE_KEY \
 *   --broadcast \
 *   --verify
 */
contract DeploySuperPaymasterV2 is Script {

    // ====================================
    // Configuration
    // ====================================

    /// @notice EntryPoint v0.7 address (Sepolia)
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    /// @notice Mock GToken address (deploy if not exists)
    address public GTOKEN;

    // ====================================
    // Deployment State
    // ====================================

    GTokenStaking public gtokenStaking;
    Registry public registry;
    SuperPaymasterV2 public superPaymaster;
    xPNTsFactory public xpntsFactory;
    MySBTFactory public mysbtFactory;
    MySBTWithNFTBinding public mysbt;
    DVTValidator public dvtValidator;
    BLSAggregator public blsAggregator;

    // ====================================
    // Main Deployment
    // ====================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== SuperPaymaster v2.0 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy or use existing GToken
        _deployGToken();

        // Step 2: Deploy GTokenStaking
        _deployGTokenStaking();

        // Step 3: Deploy Registry
        _deployRegistry();

        // Step 4: Deploy SuperPaymasterV2
        _deploySuperPaymaster();

        // Step 5: Deploy xPNTsFactory
        _deployXPNTsFactory();

        // Step 6: Deploy MySBTFactory
        _deployMySBTFactory();

        // Step 7: Deploy MySBT
        _deployMySBT();

        // Step 8: Deploy DVTValidator
        _deployDVTValidator();

        // Step 9: Deploy BLSAggregator
        _deployBLSAggregator();

        // Step 10: Initialize connections
        _initializeConnections();

        vm.stopBroadcast();

        // Print summary
        _printDeploymentSummary();
    }

    // ====================================
    // Deployment Functions
    // ====================================

    function _deployGToken() internal {
        console.log("Step 1: Deploying GToken (Mock)...");

        // Check if GToken exists from environment
        try vm.envAddress("GTOKEN_ADDRESS") returns (address existingGToken) {
            GTOKEN = existingGToken;
            console.log("Using existing GToken:", GTOKEN);

            // CRITICAL SAFETY CHECK: Verify it's a production GToken
            // Production GToken MUST have cap() and owner() functions
            (bool hasCapSuccess,) = GTOKEN.call(abi.encodeWithSignature("cap()"));
            (bool hasOwnerSuccess,) = GTOKEN.call(abi.encodeWithSignature("owner()"));

            require(hasCapSuccess, "SAFETY: GToken must have cap() function");
            require(hasOwnerSuccess, "SAFETY: GToken must have owner() function");

            console.log("Safety checks passed: cap() and owner() verified");
        } catch {
            // CRITICAL: GTOKEN_ADDRESS environment variable must be set
            revert(
                "SAFETY: GTOKEN_ADDRESS environment variable is required! Never deploy MockERC20 to public networks."
            );
        }

        console.log("");
    }

    function _deployGTokenStaking() internal {
        console.log("Step 2: Deploying GTokenStaking...");

        gtokenStaking = new GTokenStaking(GTOKEN);

        console.log("GTokenStaking deployed:", address(gtokenStaking));
        console.log("MIN_STAKE:", gtokenStaking.MIN_STAKE() / 1e18, "GT");
        console.log("UNSTAKE_DELAY:", gtokenStaking.UNSTAKE_DELAY() / 1 days, "days");
        console.log("Treasury:", gtokenStaking.treasury());
        console.log("");
    }

    function _deployRegistry() internal {
        console.log("Step 3: Deploying Registry...");

        registry = new Registry(address(gtokenStaking));

        console.log("Registry deployed:", address(registry));
        console.log("");
    }

    function _deploySuperPaymaster() internal {
        console.log("Step 4: Deploying SuperPaymasterV2...");

        superPaymaster = new SuperPaymasterV2(
            address(gtokenStaking),
            address(registry)
        );

        console.log("SuperPaymasterV2 deployed:", address(superPaymaster));
        console.log("minOperatorStake:", superPaymaster.minOperatorStake() / 1e18, "sGT");
        console.log("minAPNTsBalance:", superPaymaster.minAPNTsBalance() / 1e18, "aPNTs");
        console.log("");
    }

    function _deployXPNTsFactory() internal {
        console.log("Step 5: Deploying xPNTsFactory...");

        xpntsFactory = new xPNTsFactory(
            address(superPaymaster),
            address(registry)
        );

        console.log("xPNTsFactory deployed:", address(xpntsFactory));
        console.log("DEFAULT_SAFETY_FACTOR:", xpntsFactory.DEFAULT_SAFETY_FACTOR() / 1e18);
        console.log("MIN_SUGGESTED_AMOUNT:", xpntsFactory.MIN_SUGGESTED_AMOUNT() / 1e18, "aPNTs");
        console.log("");
    }

    function _deployMySBTFactory() internal {
        console.log("Step 6: Deploying MySBTFactory...");

        mysbtFactory = new MySBTFactory(GTOKEN, address(gtokenStaking));

        console.log("MySBTFactory deployed:", address(mysbtFactory));
        console.log("DEFAULT_MIN_LOCK:", mysbtFactory.DEFAULT_MIN_LOCK() / 1e18, "sGT");
        console.log("DEFAULT_MINT_FEE:", mysbtFactory.DEFAULT_MINT_FEE() / 1e18, "GT");
        console.log("");
    }

    function _deployMySBT() internal {
        console.log("Step 7: Deploying MySBTWithNFTBinding...");

        mysbt = new MySBTWithNFTBinding(
            GTOKEN,
            address(gtokenStaking)
        );

        console.log("MySBTWithNFTBinding deployed:", address(mysbt));
        console.log("minLockAmount:", mysbt.minLockAmount() / 1e18, "sGT");
        console.log("mintFee:", mysbt.mintFee() / 1e18, "GT");
        console.log("creator:", mysbt.creator());
        console.log("");
    }

    function _deployDVTValidator() internal {
        console.log("Step 8: Deploying DVTValidator...");

        dvtValidator = new DVTValidator(address(superPaymaster));

        console.log("DVTValidator deployed:", address(dvtValidator));
        console.log("MIN_VALIDATORS:", dvtValidator.MIN_VALIDATORS());
        console.log("PROPOSAL_EXPIRATION:", dvtValidator.PROPOSAL_EXPIRATION() / 1 hours, "hours");
        console.log("");
    }

    function _deployBLSAggregator() internal {
        console.log("Step 9: Deploying BLSAggregator...");

        blsAggregator = new BLSAggregator(
            address(superPaymaster),
            address(dvtValidator)
        );

        console.log("BLSAggregator deployed:", address(blsAggregator));
        console.log("THRESHOLD:", blsAggregator.THRESHOLD());
        console.log("MAX_VALIDATORS:", blsAggregator.MAX_VALIDATORS());
        console.log("");
    }

    function _initializeConnections() internal {
        console.log("Step 10: Initializing connections...");

        // Set MySBT in SuperPaymaster
        mysbt.setSuperPaymaster(address(superPaymaster));
        console.log("MySBT.setSuperPaymaster:", address(superPaymaster));

        // Set DVT Aggregator in SuperPaymaster
        superPaymaster.setDVTAggregator(address(blsAggregator));
        console.log("SuperPaymaster.setDVTAggregator:", address(blsAggregator));

        // Set EntryPoint in SuperPaymaster
        superPaymaster.setEntryPoint(ENTRYPOINT_V07);
        console.log("SuperPaymaster.setEntryPoint:", ENTRYPOINT_V07);

        // Set BLS Aggregator in DVT Validator
        dvtValidator.setBLSAggregator(address(blsAggregator));
        console.log("DVTValidator.setBLSAggregator:", address(blsAggregator));

        // ====================================
        // Configure Lock System and Exit Fees
        // ====================================

        // Set treasury for exit fees (use deployer for now, transfer to multisig later)
        gtokenStaking.setTreasury(msg.sender);
        console.log("GTokenStaking.setTreasury:", msg.sender);

        // Configure MySBT locker (flat 0.1 sGT exit fee)
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);

        gtokenStaking.configureLocker(
            address(mysbt),
            true,                    // authorized
            0.1 ether,              // baseExitFee: 0.1 sGT
            emptyTiers,             // no time tiers
            emptyFees,              // no tiered fees
            address(0)              // use default treasury
        );
        console.log("Configured MySBT locker: flat 0.1 sGT exit fee");

        // Configure SuperPaymaster locker (tiered exit fees based on operating time)
        uint256[] memory spTiers = new uint256[](3);
        spTiers[0] = 90 days;
        spTiers[1] = 180 days;
        spTiers[2] = 365 days;

        uint256[] memory spFees = new uint256[](4);
        spFees[0] = 15 ether;   // < 90 days: 15 sGT
        spFees[1] = 10 ether;   // 90-180 days: 10 sGT
        spFees[2] = 7 ether;    // 180-365 days: 7 sGT
        spFees[3] = 5 ether;    // >= 365 days: 5 sGT

        gtokenStaking.configureLocker(
            address(superPaymaster),
            true,                    // authorized
            0,                       // baseExitFee not used
            spTiers,                // time tiers
            spFees,                 // tiered fees
            address(0)              // use default treasury
        );
        console.log("Configured SuperPaymaster locker: tiered exit fees (5-15 sGT)");

        // Authorize SuperPaymaster and Registry as slashers in GTokenStaking
        gtokenStaking.authorizeSlasher(address(superPaymaster), true);
        gtokenStaking.authorizeSlasher(address(registry), true);
        console.log("GTokenStaking authorized slashers:");
        console.log("  - SuperPaymaster:", address(superPaymaster));
        console.log("  - Registry:", address(registry));

        console.log("");
    }

    // ====================================
    // Summary
    // ====================================

    function _printDeploymentSummary() internal view {
        console.log("=== Deployment Summary ===");
        console.log("");
        console.log("Core Contracts:");
        console.log("  GToken:", GTOKEN);
        console.log("  GTokenStaking:", address(gtokenStaking));
        console.log("  Registry:", address(registry));
        console.log("  SuperPaymasterV2:", address(superPaymaster));
        console.log("");
        console.log("Token System:");
        console.log("  xPNTsFactory:", address(xpntsFactory));
        console.log("  MySBTFactory:", address(mysbtFactory));
        console.log("  MySBT:", address(mysbt));
        console.log("");
        console.log("Monitoring System:");
        console.log("  DVTValidator:", address(dvtValidator));
        console.log("  BLSAggregator:", address(blsAggregator));
        console.log("");
        console.log("EntryPoint:");
        console.log("  EntryPoint v0.7:", ENTRYPOINT_V07);
        console.log("");
        console.log("Deployment complete!");
        console.log("");
        console.log("Next steps:");
        console.log("1. Register DVT validators (dvtValidator.registerValidator)");
        console.log("2. Register BLS public keys (blsAggregator.registerBLSPublicKey)");
        console.log("3. Register communities (registry.registerCommunity)");
        console.log("4. Test operator registration (superPaymaster.registerOperator)");
    }
}
